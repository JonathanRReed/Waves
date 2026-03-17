use std::{
    collections::HashMap,
    ffi::c_void,
    mem::MaybeUninit,
    ptr,
    ptr::NonNull,
    sync::atomic::{AtomicU32, Ordering},
};

use objc2::{rc::Retained, ClassType};
use objc2_app_kit::NSRunningApplication;
use objc2_core_audio::{
    AudioDeviceCreateIOProcID, AudioDeviceDestroyIOProcID, AudioDeviceIOProcID, AudioDeviceStart,
    AudioDeviceStop, AudioHardwareCreateAggregateDevice, AudioHardwareCreateProcessTap,
    AudioHardwareDestroyAggregateDevice, AudioHardwareDestroyProcessTap, AudioObjectGetPropertyData,
    AudioObjectGetPropertyDataSize, AudioObjectID, AudioObjectPropertyAddress,
    AudioObjectPropertySelector, CATapDescription, CATapMuteBehavior,
    kAudioAggregateDeviceIsPrivateKey, kAudioAggregateDeviceNameKey, kAudioAggregateDeviceTapAutoStartKey,
    kAudioAggregateDeviceTapListKey, kAudioAggregateDeviceUIDKey, kAudioHardwarePropertyProcessIsAudible,
    kAudioHardwarePropertyProcessObjectList, kAudioObjectPropertyElementMain,
    kAudioObjectPropertyScopeGlobal, kAudioObjectSystemObject, kAudioProcessPropertyIsRunningOutput,
    kAudioProcessPropertyPID, kAudioSubTapDriftCompensationKey, kAudioSubTapUIDKey, kAudioTapPropertyFormat,
};
use objc2_core_audio_types::{
    AudioBuffer, AudioBufferList, AudioStreamBasicDescription, kAudioFormatFlagIsFloat,
    kAudioFormatFlagIsSignedInteger, kAudioFormatLinearPCM,
};
use objc2_foundation::{NSArray, NSDictionary, NSMutableDictionary, NSNumber, NSObject, NSString};

use crate::models::{AppAudioSession, MixerSnapshot, PlatformSupport, SessionSupport};

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
    process_objects: HashMap<String, AudioObjectID>,
    tap_sessions: HashMap<String, MacosTapSession>,
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
            if let Some(session) = self.tap_sessions.get(app_id) {
                session.io_state.set_gain(target_gain);
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
            if let Some(session) = self.tap_sessions.get(app_id) {
                session.io_state.set_gain(target_gain);
            }
        }

        if let Some(app) = self.snapshot.apps.iter_mut().find(|app| app.id == app_id) {
            app.muted = next_muted;
        }

        self.apply_tap_overrides();
        self.snapshot.generated_at = now_stamp();
        Ok(self.snapshot.clone())
    }
}

fn discover_state() -> Result<(MixerSnapshot, HashMap<String, AudioObjectID>), String> {
    let process_objects = read_array::<AudioObjectID>(
        kAudioObjectSystemObject as AudioObjectID,
        kAudioHardwarePropertyProcessObjectList,
    )?;

    let mut process_map = HashMap::new();
    let mut apps = process_objects
        .into_iter()
        .filter_map(|process_object| {
            let app = build_session(process_object)?;
            process_map.insert(app.id.clone(), process_object);
            Some(app)
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

    let running_application = NSRunningApplication::runningApplicationWithProcessIdentifier(pid as _);
    let display_name = running_application
        .as_ref()
        .and_then(|app| app.localizedName())
        .map(|name| name.to_string())
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| format!("Process {pid}"));
    let bundle_id = running_application
        .as_ref()
        .and_then(|app| app.bundleIdentifier())
        .map(|value| value.to_string())
        .filter(|value| !value.is_empty());
    let process_name = bundle_id
        .clone()
        .unwrap_or_else(|| format!("pid-{pid}"));

    Some(AppAudioSession {
        id: format!("macos:{pid}"),
        display_name: display_name.clone(),
        process_name,
        bundle_id: bundle_id.clone(),
        category: infer_category(&display_name, bundle_id.as_deref()),
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

fn state_from_error(reason: String) -> (MixerSnapshot, HashMap<String, AudioObjectID>) {
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
