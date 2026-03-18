use std::{
    collections::{hash_map::Entry, HashMap},
    ffi::c_void,
    mem::MaybeUninit,
    ptr,
    ptr::NonNull,
    sync::atomic::{AtomicU32, Ordering},
};

use objc2::{rc::Retained, AnyThread};
use objc2_app_kit::{NSApplicationActivationPolicy, NSRunningApplication};
use objc2_core_audio::{
    AudioDeviceCreateIOProcID, AudioDeviceDestroyIOProcID, AudioDeviceIOProcID, AudioDeviceStart,
    AudioDeviceStop, AudioHardwareCreateAggregateDevice, AudioHardwareCreateProcessTap,
    AudioHardwareDestroyAggregateDevice, AudioHardwareDestroyProcessTap, AudioObjectGetPropertyData,
    AudioObjectGetPropertyDataSize, AudioObjectID, AudioObjectPropertyAddress,
    AudioObjectPropertySelector, AudioObjectSetPropertyData, CATapDescription, CATapMuteBehavior,
    kAudioAggregateDeviceIsPrivateKey, kAudioAggregateDeviceNameKey, kAudioAggregateDeviceTapAutoStartKey,
    kAudioAggregateDeviceTapListKey, kAudioAggregateDeviceUIDKey, kAudioDevicePropertyScopeOutput,
    kAudioDevicePropertyStreamConfiguration, kAudioHardwarePropertyDefaultOutputDevice,
    kAudioHardwarePropertyDevices, kAudioHardwarePropertyProcessIsAudible,
    kAudioHardwarePropertyProcessObjectList, kAudioObjectPropertyElementMain, kAudioObjectPropertyName,
    kAudioObjectPropertyScopeGlobal, kAudioObjectSystemObject, kAudioProcessPropertyIsRunningOutput,
    kAudioProcessPropertyPID, kAudioSubTapDriftCompensationKey, kAudioSubTapUIDKey, kAudioTapPropertyFormat,
};
use objc2_core_audio_types::{
    AudioBuffer, AudioBufferList, AudioStreamBasicDescription, AudioTimeStamp, kAudioFormatFlagIsFloat,
    kAudioFormatFlagIsSignedInteger, kAudioFormatLinearPCM,
};
use objc2_core_foundation::CFDictionary;
use objc2_foundation::{NSArray, NSDictionary, NSNumber, NSObject, NSString};

use crate::models::{
    AppAudioSession, AudioOutputDevice, AudioOutputSnapshot, MixerSnapshot, PlatformSupport, SessionSupport,
};

use super::{now_stamp, MixerBackend};

pub fn build_backend() -> MacosMixerBackend {
    let (snapshot, process_objects) = discover_state().unwrap_or_else(state_from_error);

    MacosMixerBackend {
        snapshot,
        process_objects,
        tap_sessions: HashMap::new(),
    }
}

pub struct MacosMixerBackend {
    snapshot: MixerSnapshot,
    process_objects: HashMap<String, Vec<AudioObjectID>>,
    tap_sessions: HashMap<String, Vec<MacosTapSession>>,
}

struct MacosTapSession {
    tap_id: AudioObjectID,
    aggregate_device_id: AudioObjectID,
    io_proc_id: AudioDeviceIOProcID,
    io_state: Box<TapIoState>,
}

struct TapIoState {
    format: AudioStreamBasicDescription,
    gain_bits: AtomicU32,
}

impl TapIoState {
    fn new(format: AudioStreamBasicDescription, gain: f32) -> Self {
        Self {
            format,
            gain_bits: AtomicU32::new(gain.to_bits()),
        }
    }

    fn gain(&self) -> f32 {
        f32::from_bits(self.gain_bits.load(Ordering::Relaxed))
    }

    fn set_gain(&self, gain: f32) {
        self.gain_bits.store(gain.clamp(0.0, 1.0).to_bits(), Ordering::Relaxed)
    }
}

impl Drop for MacosTapSession {
    fn drop(&mut self) {
        unsafe {
            let _ = AudioDeviceStop(self.aggregate_device_id, self.io_proc_id);
            let _ = AudioDeviceDestroyIOProcID(self.aggregate_device_id, self.io_proc_id);
            let _ = AudioHardwareDestroyAggregateDevice(self.aggregate_device_id);
            let _ = AudioHardwareDestroyProcessTap(self.tap_id);
        }
    }
}

impl MacosMixerBackend {
    fn ensure_tap_session(&mut self, app_id: &str, gain: f32) -> Result<(), String> {
        if self.tap_sessions.contains_key(app_id) {
            return Ok(());
        }

        let process_objects = self
            .process_objects
            .get(app_id)
            .cloned()
            .ok_or_else(|| format!("The macOS audio session for {app_id} is no longer available."))?;
        let sessions = process_objects
            .into_iter()
            .map(|process_object| create_tap_session(app_id, process_object, gain))
            .collect::<Result<Vec<_>, _>>()?;
        self.tap_sessions.insert(app_id.to_string(), sessions);
        Ok(())
    }

    fn apply_tap_overrides(&mut self) {
        for app in &mut self.snapshot.apps {
            if let Some(session) = self.tap_sessions.get(&app.id).and_then(|sessions| sessions.first()) {
                let gain = session.io_state.gain();
                app.support.controllable = true;
                app.support.reason = None;
                app.volume = (gain * 100.0).round().clamp(0.0, 100.0) as u8;
                app.muted = app.volume == 0;
                app.peak_level = if app.muted {
                    0.04
                } else {
                    (gain * 0.72).clamp(0.06, 1.0)
                };
                continue;
            }

            app.support.controllable = app.active;
            app.support.reason = if app.active {
                None
            } else {
                Some("This macOS session is idle right now, so Waves cannot attach a live tap yet.".to_string())
            };
        }
    }
}

impl MixerBackend for MacosMixerBackend {
    fn snapshot(&self) -> MixerSnapshot {
        self.snapshot.clone()
    }

    fn refresh(&mut self) -> MixerSnapshot {
        let (snapshot, process_objects) = discover_state().unwrap_or_else(state_from_error);
        self.snapshot = snapshot;
        self.process_objects = process_objects;
        self.tap_sessions
            .retain(|app_id, _| self.process_objects.contains_key(app_id));
        self.apply_tap_overrides();
        self.snapshot.clone()
    }

    fn set_volume(&mut self, app_id: &str, volume: u8) -> Result<MixerSnapshot, String> {
        let app = self
            .snapshot
            .apps
            .iter()
            .find(|app| app.id == app_id)
            .ok_or_else(|| format!("The macOS audio session for {app_id} is no longer available."))?;

        if !app.support.controllable {
            return Err(app
                .support
                .reason
                .clone()
                .unwrap_or_else(|| "This macOS session is not controllable right now.".to_string()));
        }

        let normalized = volume.min(100);
        let target_gain = normalized as f32 / 100.0;
        let should_detach = normalized == 100 && !app.muted;

        if should_detach {
            self.tap_sessions.remove(app_id);
        } else {
            self.ensure_tap_session(app_id, target_gain)?;
            if let Some(sessions) = self.tap_sessions.get(app_id) {
                for session in sessions {
                    session.io_state.set_gain(target_gain);
                }
            }
        }

        if let Some(app) = self.snapshot.apps.iter_mut().find(|app| app.id == app_id) {
            app.volume = normalized;
            app.muted = normalized == 0;
        }

        self.apply_tap_overrides();
        self.snapshot.generated_at = now_stamp();
        Ok(self.snapshot.clone())
    }

    fn toggle_mute(&mut self, app_id: &str) -> Result<MixerSnapshot, String> {
        let app = self
            .snapshot
            .apps
            .iter()
            .find(|app| app.id == app_id)
            .cloned()
            .ok_or_else(|| format!("The macOS audio session for {app_id} is no longer available."))?;

        if !app.support.controllable {
            return Err(app
                .support
                .reason
                .clone()
                .unwrap_or_else(|| "This macOS session is not controllable right now.".to_string()));
        }

        let next_muted = !app.muted;
        let target_gain = if next_muted {
            0.0
        } else {
            (app.volume as f32 / 100.0).clamp(0.0, 1.0)
        };

        if !next_muted && app.volume >= 100 {
            self.tap_sessions.remove(app_id);
        } else {
            self.ensure_tap_session(app_id, target_gain)?;
            if let Some(sessions) = self.tap_sessions.get(app_id) {
                for session in sessions {
                    session.io_state.set_gain(target_gain);
                }
            }
        }

        if let Some(app) = self.snapshot.apps.iter_mut().find(|app| app.id == app_id) {
            app.muted = next_muted;
        }

        self.apply_tap_overrides();
        self.snapshot.generated_at = now_stamp();
        Ok(self.snapshot.clone())
    }

    fn output_devices(&self) -> Result<AudioOutputSnapshot, String> {
        enumerate_output_devices()
    }

    fn set_output_device(&mut self, device_id: &str) -> Result<AudioOutputSnapshot, String> {
        set_default_output_device(device_id.parse::<AudioObjectID>().map_err(|_| {
            format!("Unknown macOS output device id: {device_id}")
        })?)?;
        enumerate_output_devices()
    }
}

fn discover_state() -> Result<(MixerSnapshot, HashMap<String, Vec<AudioObjectID>>), String> {
    let process_objects = read_array::<AudioObjectID>(
        kAudioObjectSystemObject as AudioObjectID,
        kAudioHardwarePropertyProcessObjectList,
    )?;

    let mut deduped_apps: HashMap<String, (AppAudioSession, Vec<AudioObjectID>)> = HashMap::new();

    for process_object in process_objects {
        let app = match build_session(process_object) {
            Some(app) if app.active && app.support.controllable => app,
            _ => continue,
        };

        match deduped_apps.entry(app.id.clone()) {
            Entry::Occupied(mut entry) => {
                let (existing_app, existing_process_objects) = entry.get_mut();
                existing_process_objects.push(process_object);
                existing_app.peak_level = existing_app.peak_level.max(app.peak_level);
                existing_app.active |= app.active;
                existing_app.support.controllable |= app.support.controllable;
            }
            Entry::Vacant(entry) => {
                entry.insert((app, vec![process_object]));
            }
        }
    }

    let mut process_map = HashMap::new();
    let mut apps = deduped_apps
        .into_iter()
        .map(|(_, (app, process_objects))| {
            process_map.insert(app.id.clone(), process_objects);
            app
        })
        .collect::<Vec<_>>();

    apps.sort_by(|left, right| {
        right
            .active
            .cmp(&left.active)
            .then_with(|| left.display_name.cmp(&right.display_name))
    });

    Ok((MixerSnapshot {
        platform: PlatformSupport {
            platform: "macos".to_string(),
            native_backend: "macos-process-discovery".to_string(),
            native_control_ready: true,
            discovery_ready: true,
            notes: vec![
                "Waves is reading real macOS Core Audio process objects for live session discovery.".to_string(),
                "Per-app control uses the direct Rust Core Audio tap prototype for live sessions.".to_string(),
            ],
        },
        generated_at: now_stamp(),
        apps,
    }, process_map))
}

fn build_session(process_object: AudioObjectID) -> Option<AppAudioSession> {
    let pid = read_value::<i32>(process_object, kAudioProcessPropertyPID).ok()?;
    if pid <= 0 {
        return None;
    }

    let audible = read_bool(process_object, kAudioHardwarePropertyProcessIsAudible).unwrap_or(false);
    let running_output = read_bool(process_object, kAudioProcessPropertyIsRunningOutput).unwrap_or(false);
    let active = audible || running_output;
    if !active {
        return None;
    }

    let running_application = NSRunningApplication::runningApplicationWithProcessIdentifier(pid as _)?;
    if running_application.isTerminated() || !running_application.isFinishedLaunching() {
        return None;
    }

    let raw_display_name = running_application
        .localizedName()
        .map(|name| name.to_string())
        .filter(|name| !name.is_empty())?;
    let raw_bundle_id = running_application
        .bundleIdentifier()
        .map(|value| value.to_string())
        .filter(|value| !value.is_empty())?;

    let (display_name, bundle_id, derived_from_helper) = resolve_session_identity(&raw_display_name, &raw_bundle_id);
    if running_application.activationPolicy() == NSApplicationActivationPolicy::Prohibited && !derived_from_helper {
        return None;
    }

    if looks_like_background_audio_process(&raw_display_name, &raw_bundle_id) {
        return None;
    }

    let session_id = format!("macos:{bundle_id}");

    Some(AppAudioSession {
        id: session_id,
        display_name: display_name.clone(),
        process_name: bundle_id.clone(),
        bundle_id: Some(bundle_id.clone()),
        category: infer_category(&display_name, Some(bundle_id.as_str())),
        volume: 100,
        muted: false,
        active,
        pinned_hint: false,
        peak_level: if active { 0.62 } else { 0.04 },
        support: SessionSupport {
            controllable: active,
            reason: if active {
                None
            } else {
                Some("This macOS session is idle right now, so Waves cannot attach a live tap yet.".to_string())
            },
        },
    })
}

fn looks_like_background_audio_process(display_name: &str, bundle_id: &str) -> bool {
    let haystack = format!("{} {}", display_name, bundle_id).to_lowercase();
    let excluded_terms = [
        "daemon",
        "agent",
        "service",
        "extension",
        "plugin",
        "gpu",
        "monitor",
        "updater",
        "loginitem",
    ];

    excluded_terms.iter().any(|term| haystack.contains(term))
}

fn resolve_session_identity(display_name: &str, bundle_id: &str) -> (String, String, bool) {
    if bundle_id.eq_ignore_ascii_case("com.apple.WebKit.WebContent") || display_name.eq_ignore_ascii_case("Safari Web Content") {
        return ("Safari".to_string(), "com.apple.Safari".to_string(), true);
    }

    let canonical_bundle_id = canonical_bundle_id(bundle_id);
    let derived_from_helper = canonical_bundle_id != bundle_id;
    let resolved_display_name = if derived_from_helper || display_name.to_lowercase().contains("web content") {
        friendly_app_name_from_bundle_id(&canonical_bundle_id)
    } else {
        display_name.to_string()
    };

    (resolved_display_name, canonical_bundle_id, derived_from_helper)
}

fn canonical_bundle_id(bundle_id: &str) -> String {
    let lower_bundle_id = bundle_id.to_lowercase();
    if lower_bundle_id.contains("com.apple.webkit.webcontent") {
        return "com.apple.Safari".to_string();
    }

    if let Some(index) = lower_bundle_id.find(".helper") {
        return bundle_id[..index].to_string();
    }

    bundle_id.to_string()
}

fn friendly_app_name_from_bundle_id(bundle_id: &str) -> String {
    match bundle_id.to_lowercase().as_str() {
        "com.google.chrome" => "Google Chrome".to_string(),
        "com.microsoft.edgemac" => "Microsoft Edge".to_string(),
        "company.thebrowser.browser" => "Arc".to_string(),
        "com.brave.browser" => "Brave".to_string(),
        "org.mozilla.firefox" => "Firefox".to_string(),
        "com.apple.safari" => "Safari".to_string(),
        "com.spotify.client" => "Spotify".to_string(),
        _ => bundle_id
            .rsplit('.')
            .next()
            .unwrap_or(bundle_id)
            .replace(['-', '_'], " ")
            .split_whitespace()
            .map(|part| {
                let mut chars = part.chars();
                match chars.next() {
                    Some(first) => format!("{}{}", first.to_uppercase(), chars.as_str().to_lowercase()),
                    None => String::new(),
                }
            })
            .collect::<Vec<_>>()
            .join(" "),
    }
}

fn enumerate_output_devices() -> Result<AudioOutputSnapshot, String> {
    let device_ids = read_array::<AudioObjectID>(
        kAudioObjectSystemObject as AudioObjectID,
        kAudioHardwarePropertyDevices,
    )?;
    let current_device_id = read_value::<AudioObjectID>(
        kAudioObjectSystemObject as AudioObjectID,
        kAudioHardwarePropertyDefaultOutputDevice,
    )
    .ok();

    let mut devices = device_ids
        .into_iter()
        .filter(|device_id| device_supports_output(*device_id).unwrap_or(false))
        .filter_map(|device_id| {
            let name = read_string_property(device_id, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal).ok()?;
            Some(AudioOutputDevice {
                id: device_id.to_string(),
                name,
                current: current_device_id == Some(device_id),
            })
        })
        .collect::<Vec<_>>();

    devices.sort_by(|left, right| {
        right
            .current
            .cmp(&left.current)
            .then_with(|| left.name.cmp(&right.name))
    });

    Ok(AudioOutputSnapshot {
        supported: true,
        reason: None,
        current_device_id: current_device_id.map(|device_id| device_id.to_string()),
        devices,
    })
}

fn device_supports_output(device_id: AudioObjectID) -> Result<bool, String> {
    let mut address = property_address_for_scope(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeOutput);
    let mut size = 0_u32;
    let status = unsafe {
        AudioObjectGetPropertyDataSize(device_id, (&mut address).into(), 0, ptr::null(), (&mut size).into())
    };

    if status != 0 {
        return Err(format!(
            "Core Audio output configuration read failed for device {device_id}: {status}"
        ));
    }

    Ok(size > 0)
}

fn set_default_output_device(device_id: AudioObjectID) -> Result<(), String> {
    let mut address = property_address(kAudioHardwarePropertyDefaultOutputDevice);
    let mut target_device_id = device_id;
    let status = unsafe {
        AudioObjectSetPropertyData(
            kAudioObjectSystemObject as AudioObjectID,
            (&mut address).into(),
            0,
            ptr::null(),
            std::mem::size_of::<AudioObjectID>() as u32,
            NonNull::from(&mut target_device_id).cast(),
        )
    };

    if status != 0 {
        return Err(format!("Core Audio default output switch failed for device {device_id}: {status}"));
    }

    Ok(())
}

fn read_string_property(
    object_id: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: u32,
) -> Result<String, String> {
    let mut address = property_address_for_scope(selector, scope);
    let mut size = std::mem::size_of::<*mut NSString>() as u32;
    let mut value = MaybeUninit::<*mut NSString>::uninit();
    let status = unsafe {
        AudioObjectGetPropertyData(
            object_id,
            (&mut address).into(),
            0,
            ptr::null(),
            (&mut size).into(),
            NonNull::new(value.as_mut_ptr().cast())
                .expect("AudioObjectGetPropertyData requires non-null output storage"),
        )
    };

    if status != 0 {
        return Err(format!("Core Audio string read failed for selector {selector:#x}: {status}"));
    }

    let value = unsafe { value.assume_init() };
    if value.is_null() {
        return Err(format!("Core Audio string read returned no value for selector {selector:#x}"));
    }

    Ok(unsafe { (&*value).to_string() })
}

fn infer_category(display_name: &str, bundle_id: Option<&str>) -> String {
    let haystack = format!(
        "{} {}",
        display_name.to_lowercase(),
        bundle_id.unwrap_or_default().to_lowercase()
    );

    if haystack.contains("music") || haystack.contains("spotify") || haystack.contains("apple.music") {
        return "Music".to_string();
    }

    if haystack.contains("zoom")
        || haystack.contains("meet")
        || haystack.contains("teams")
        || haystack.contains("facetime")
    {
        return "Calls".to_string();
    }

    if haystack.contains("safari") || haystack.contains("chrome") || haystack.contains("firefox") || haystack.contains("browser") {
        return "Browser".to_string();
    }

    if haystack.contains("discord") || haystack.contains("slack") || haystack.contains("chat") || haystack.contains("messages") {
        return "Chat".to_string();
    }

    "Productivity".to_string()
}

fn create_tap_session(app_id: &str, process_object: AudioObjectID, gain: f32) -> Result<MacosTapSession, String> {
    let process_number = NSNumber::new_u32(process_object);
    let processes = NSArray::from_slice(&[&*process_number]);
    let tap_description = unsafe {
        CATapDescription::initStereoMixdownOfProcesses(CATapDescription::alloc(), &processes)
    };
    let tap_key = format!("{}-{}", app_id.replace(':', "-"), process_object);
    let tap_name = NSString::from_str(&format!("Waves {tap_key}"));

    unsafe {
        tap_description.setName(&tap_name);
        tap_description.setPrivate(true);
        tap_description.setExclusive(false);
        tap_description.setMuteBehavior(CATapMuteBehavior::MutedWhenTapped);
    }

    let mut tap_id = 0;
    let tap_status = unsafe { AudioHardwareCreateProcessTap(Some(&tap_description), &mut tap_id) };
    if tap_status != 0 {
        return Err(format!("AudioHardwareCreateProcessTap failed for {app_id}: {tap_status}"));
    }

    let tap_uid = unsafe { tap_description.UUID().UUIDString() };
    let tap_dictionary = dictionary_from_pairs(
        vec![
            key_string(kAudioSubTapUIDKey),
            key_string(kAudioSubTapDriftCompensationKey),
        ],
        vec![
            tap_uid.clone().into_super(),
            NSNumber::new_bool(true).into_super().into_super(),
        ],
    );
    let taps = NSArray::from_retained_slice(&[tap_dictionary]);
    let aggregate_name = NSString::from_str(&format!("Waves Aggregate {tap_key}"));
    let aggregate_uid = NSString::from_str(&format!("com.jonathanreed.waves.{tap_key}"));
    let aggregate_dictionary = dictionary_from_pairs(
        vec![
            key_string(kAudioAggregateDeviceNameKey),
            key_string(kAudioAggregateDeviceUIDKey),
            key_string(kAudioAggregateDeviceTapListKey),
            key_string(kAudioAggregateDeviceTapAutoStartKey),
            key_string(kAudioAggregateDeviceIsPrivateKey),
        ],
        vec![
            aggregate_name.into_super(),
            aggregate_uid.into_super(),
            taps.into_super(),
            NSNumber::new_bool(false).into_super().into_super(),
            NSNumber::new_bool(true).into_super().into_super(),
        ],
    );

    let mut aggregate_device_id = 0;
    let aggregate_status = unsafe {
        let dictionary = aggregate_dictionary.as_ref() as &CFDictionary<NSString, NSObject>;
        let dictionary = &*(dictionary as *const CFDictionary<NSString, NSObject> as *const CFDictionary);
        AudioHardwareCreateAggregateDevice(dictionary, NonNull::from(&mut aggregate_device_id))
    };
    if aggregate_status != 0 {
        unsafe {
            let _ = AudioHardwareDestroyProcessTap(tap_id);
        }
        return Err(format!(
            "AudioHardwareCreateAggregateDevice failed for {app_id}: {aggregate_status}"
        ));
    }

    let format = read_value::<AudioStreamBasicDescription>(tap_id, kAudioTapPropertyFormat)?;
    let mut io_state = Box::new(TapIoState::new(format, gain));
    let client_data = io_state.as_mut() as *mut TapIoState as *mut c_void;
    let mut io_proc_id: AudioDeviceIOProcID = None;
    let io_proc_status = unsafe {
        AudioDeviceCreateIOProcID(
            aggregate_device_id,
            Some(tap_io_proc),
            client_data,
            NonNull::from(&mut io_proc_id),
        )
    };
    if io_proc_status != 0 {
        unsafe {
            let _ = AudioHardwareDestroyAggregateDevice(aggregate_device_id);
            let _ = AudioHardwareDestroyProcessTap(tap_id);
        }
        return Err(format!("AudioDeviceCreateIOProcID failed for {app_id}: {io_proc_status}"));
    }

    let start_status = unsafe { AudioDeviceStart(aggregate_device_id, io_proc_id) };
    if start_status != 0 {
        unsafe {
            let _ = AudioDeviceDestroyIOProcID(aggregate_device_id, io_proc_id);
            let _ = AudioHardwareDestroyAggregateDevice(aggregate_device_id);
            let _ = AudioHardwareDestroyProcessTap(tap_id);
        }
        return Err(format!("AudioDeviceStart failed for {app_id}: {start_status}"));
    }

    Ok(MacosTapSession {
        tap_id,
        aggregate_device_id,
        io_proc_id,
        io_state,
    })
}

fn dictionary_from_pairs(
    keys: Vec<Retained<NSString>>,
    values: Vec<Retained<NSObject>>,
) -> Retained<NSDictionary<NSString, NSObject>> {
    let key_refs = keys.iter().map(|key| &**key).collect::<Vec<_>>();
    let value_refs = values.iter().map(|value| &**value).collect::<Vec<_>>();
    NSDictionary::from_slices(&key_refs, &value_refs)
}

fn key_string(value: &std::ffi::CStr) -> Retained<NSString> {
    NSString::from_str(value.to_str().unwrap_or_default())
}

unsafe extern "C-unwind" fn tap_io_proc(
    _device: AudioObjectID,
    _now: NonNull<AudioTimeStamp>,
    input_data: NonNull<AudioBufferList>,
    _input_time: NonNull<AudioTimeStamp>,
    output_data: NonNull<AudioBufferList>,
    _output_time: NonNull<AudioTimeStamp>,
    client_data: *mut c_void,
) -> i32 {
    let Some(io_state) = (client_data as *mut TapIoState).as_ref() else {
        return 0;
    };

    let input_buffers = unsafe { buffer_list_slice(input_data) };
    let output_buffers = unsafe { buffer_list_slice_mut(output_data) };
    let buffer_count = input_buffers.len().min(output_buffers.len());

    for index in 0..buffer_count {
        unsafe {
            process_audio_buffer(&input_buffers[index], &mut output_buffers[index], io_state);
        }
    }

    0
}

unsafe fn process_audio_buffer(input: &AudioBuffer, output: &mut AudioBuffer, io_state: &TapIoState) {
    if input.mData.is_null() || output.mData.is_null() {
        output.mDataByteSize = 0;
        return;
    }

    let byte_len = input.mDataByteSize.min(output.mDataByteSize) as usize;
    output.mDataByteSize = byte_len as u32;
    let gain = io_state.gain();

    if io_state.format.mFormatID == kAudioFormatLinearPCM
        && io_state.format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        && io_state.format.mBitsPerChannel == 32
    {
        let input_samples = std::slice::from_raw_parts(input.mData.cast::<f32>(), byte_len / std::mem::size_of::<f32>());
        let output_samples = std::slice::from_raw_parts_mut(output.mData.cast::<f32>(), byte_len / std::mem::size_of::<f32>());
        for (source, target) in input_samples.iter().zip(output_samples.iter_mut()) {
            *target = *source * gain;
        }
        return;
    }

    if io_state.format.mFormatID == kAudioFormatLinearPCM
        && io_state.format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        && io_state.format.mBitsPerChannel == 16
    {
        let input_samples = std::slice::from_raw_parts(input.mData.cast::<i16>(), byte_len / std::mem::size_of::<i16>());
        let output_samples = std::slice::from_raw_parts_mut(output.mData.cast::<i16>(), byte_len / std::mem::size_of::<i16>());
        for (source, target) in input_samples.iter().zip(output_samples.iter_mut()) {
            *target = ((*source as f32) * gain).round().clamp(i16::MIN as f32, i16::MAX as f32) as i16;
        }
        return;
    }

    if io_state.format.mFormatID == kAudioFormatLinearPCM
        && io_state.format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        && io_state.format.mBitsPerChannel == 32
    {
        let input_samples = std::slice::from_raw_parts(input.mData.cast::<i32>(), byte_len / std::mem::size_of::<i32>());
        let output_samples = std::slice::from_raw_parts_mut(output.mData.cast::<i32>(), byte_len / std::mem::size_of::<i32>());
        for (source, target) in input_samples.iter().zip(output_samples.iter_mut()) {
            *target = ((*source as f64) * gain as f64)
                .round()
                .clamp(i32::MIN as f64, i32::MAX as f64) as i32;
        }
        return;
    }

    if (gain - 1.0).abs() < f32::EPSILON {
        ptr::copy_nonoverlapping(input.mData.cast::<u8>(), output.mData.cast::<u8>(), byte_len);
    } else {
        ptr::write_bytes(output.mData.cast::<u8>(), 0, byte_len);
    }
}

unsafe fn buffer_list_slice(list: NonNull<AudioBufferList>) -> &'static [AudioBuffer] {
    let pointer = list.as_ptr();
    let count = (*pointer).mNumberBuffers as usize;
    let data = (*pointer).mBuffers.as_ptr();
    std::slice::from_raw_parts(data, count)
}

unsafe fn buffer_list_slice_mut(list: NonNull<AudioBufferList>) -> &'static mut [AudioBuffer] {
    let pointer = list.as_ptr();
    let count = (*pointer).mNumberBuffers as usize;
    let data = std::ptr::addr_of_mut!((*pointer).mBuffers) as *mut AudioBuffer;
    std::slice::from_raw_parts_mut(data, count)
}

fn state_from_error(reason: String) -> (MixerSnapshot, HashMap<String, Vec<AudioObjectID>>) {
    (MixerSnapshot {
        platform: PlatformSupport {
            platform: "macos".to_string(),
            native_backend: "macos-process-discovery".to_string(),
            native_control_ready: false,
            discovery_ready: false,
            notes: vec![
                "Waves could not enumerate macOS Core Audio process objects.".to_string(),
                reason,
            ],
        },
        generated_at: now_stamp(),
        apps: Vec::new(),
    }, HashMap::new())
}

fn read_bool(object_id: AudioObjectID, selector: AudioObjectPropertySelector) -> Result<bool, String> {
    Ok(read_value::<u32>(object_id, selector)? != 0)
}

fn read_value<T>(object_id: AudioObjectID, selector: AudioObjectPropertySelector) -> Result<T, String> {
    let mut address = property_address(selector);
    let mut size = std::mem::size_of::<T>() as u32;
    let mut value = MaybeUninit::<T>::uninit();
    let status = unsafe {
        AudioObjectGetPropertyData(
            object_id,
            (&mut address).into(),
            0,
            ptr::null(),
            (&mut size).into(),
            NonNull::new(value.as_mut_ptr().cast()).expect("AudioObjectGetPropertyData requires non-null output storage"),
        )
    };

    if status != 0 {
        return Err(format!("Core Audio read failed for selector {selector:#x}: {status}"));
    }

    Ok(unsafe { value.assume_init() })
}

fn read_array<T: Copy + Default>(
    object_id: AudioObjectID,
    selector: AudioObjectPropertySelector,
) -> Result<Vec<T>, String> {
    let mut address = property_address(selector);
    let mut size = 0_u32;
    let size_status = unsafe {
        AudioObjectGetPropertyDataSize(object_id, (&mut address).into(), 0, ptr::null(), (&mut size).into())
    };

    if size_status != 0 {
        return Err(format!(
            "Core Audio size read failed for selector {selector:#x}: {size_status}"
        ));
    }

    let count = size as usize / std::mem::size_of::<T>();
    let mut values = vec![T::default(); count];
    let read_status = unsafe {
        AudioObjectGetPropertyData(
            object_id,
            (&mut address).into(),
            0,
            ptr::null(),
            (&mut size).into(),
            NonNull::new(values.as_mut_ptr().cast()).expect("AudioObjectGetPropertyData requires non-null output storage"),
        )
    };

    if read_status != 0 {
        return Err(format!("Core Audio list read failed for selector {selector:#x}: {read_status}"));
    }

    Ok(values)
}

fn property_address(selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress {
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
    }
}

fn property_address_for_scope(selector: AudioObjectPropertySelector, scope: u32) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress {
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain,
    }
}
