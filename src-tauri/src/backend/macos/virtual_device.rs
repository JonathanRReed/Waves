use std::collections::HashMap;

use objc2_app_kit::NSRunningApplication;
use objc2_core_audio::{
    AudioObjectID, kAudioDevicePropertyDeviceUID, kAudioHardwarePropertyDefaultOutputDevice,
    kAudioHardwarePropertyDevices, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal,
    kAudioObjectSystemObject,
};

use crate::models::{
    AppAudioSession, AudioOutputDevice, AudioOutputSnapshot, MixerSnapshot, PlatformSupport, SessionSupport,
};

use super::{
    bridge::{BridgeStatus, BridgeTarget, MacosAudioBridge},
    driver_rpc::{self, DriverSession, DriverSnapshot},
    device_supports_output, friendly_app_name_from_bundle_id, infer_category, now_stamp, read_string_property,
    read_value, resolve_session_identity, set_default_output_device, MixerBackend, LIVE_PEAK_FLOOR,
};

const WAVES_VIRTUAL_DEVICE_UID: &str = "com.jonathanreed.waves.virtual-output";

pub fn build_virtual_backend() -> Result<MacosVirtualBackend, String> {
    let virtual_device_id = find_virtual_device_id()?
        .ok_or_else(|| "The Waves virtual audio driver is not installed or loaded.".to_string())?;
    driver_rpc::ping_driver()?;

    let outputs = enumerate_physical_outputs(Some(virtual_device_id))?;
    let current_default_device_id = current_default_output_device_id()?;
    let initial_target = pick_initial_target(&outputs, current_default_device_id, virtual_device_id)?;
    let bridge = MacosAudioBridge::start(initial_target.clone())?;

    if current_default_device_id != Some(virtual_device_id) {
        set_default_output_device(virtual_device_id)?;
    }

    let mut backend = MacosVirtualBackend {
        snapshot: MixerSnapshot {
            platform: PlatformSupport {
                platform: "macos".to_string(),
                native_backend: "macos-waves-virtual-device".to_string(),
                native_control_ready: true,
                discovery_ready: true,
                notes: Vec::new(),
            },
            generated_at: now_stamp(),
            apps: Vec::new(),
        },
        virtual_device_id,
        restore_device_id: Some(initial_target.device_id.clone()),
        target_device_id: initial_target.device_id,
        bridge,
        app_keys: HashMap::new(),
    };
    backend.snapshot = backend.refresh_snapshot()?;
    Ok(backend)
}

pub struct MacosVirtualBackend {
    snapshot: MixerSnapshot,
    virtual_device_id: AudioObjectID,
    restore_device_id: Option<String>,
    target_device_id: String,
    bridge: MacosAudioBridge,
    app_keys: HashMap<String, String>,
}

impl Drop for MacosVirtualBackend {
    fn drop(&mut self) {
        if let Some(device_id) = self.restore_device_id.as_deref() {
            if let Ok(parsed) = device_id.parse::<AudioObjectID>() {
                let _ = set_default_output_device(parsed);
            }
        }
    }
}

impl MacosVirtualBackend {
    fn refresh_snapshot(&mut self) -> Result<MixerSnapshot, String> {
        let driver_snapshot = driver_rpc::snapshot()?;
        let bridge_status = self.bridge.status();
        ensure_virtual_default(self.virtual_device_id)?;
        let fallback_apps = super::discover_state()
            .map(|(snapshot, _)| snapshot.apps)
            .unwrap_or_default();
        let (apps, app_keys) = build_app_sessions(&driver_snapshot, &fallback_apps);
        self.app_keys = app_keys;
        Ok(MixerSnapshot {
            platform: platform_support(&bridge_status),
            apps,
            generated_at: if driver_snapshot.generated_at_ms > 0 {
                driver_snapshot.generated_at_ms.to_string()
            } else {
                now_stamp()
            },
        })
    }
}

impl MixerBackend for MacosVirtualBackend {
    fn snapshot(&self) -> MixerSnapshot {
        self.snapshot.clone()
    }

    fn refresh(&mut self) -> MixerSnapshot {
        match self.refresh_snapshot() {
            Ok(snapshot) => {
                self.snapshot = snapshot.clone();
                snapshot
            }
            Err(reason) => {
                self.snapshot.platform.native_control_ready = false;
                self.snapshot.platform.discovery_ready = false;
                self.snapshot.platform.notes = vec![
                    "Waves lost contact with the macOS virtual audio engine.".to_string(),
                    reason,
                ];
                self.snapshot.generated_at = now_stamp();
                self.snapshot.clone()
            }
        }
    }

    fn set_volume(&mut self, app_id: &str, volume: u8) -> Result<MixerSnapshot, String> {
        let key = self
            .app_keys
            .get(app_id)
            .cloned()
            .ok_or_else(|| format!("The Waves virtual audio session for {app_id} is no longer available."))?;
        driver_rpc::set_volume(&key, volume)?;
        let snapshot = self.refresh_snapshot()?;
        self.snapshot = snapshot.clone();
        Ok(snapshot)
    }

    fn toggle_mute(&mut self, app_id: &str) -> Result<MixerSnapshot, String> {
        let key = self
            .app_keys
            .get(app_id)
            .cloned()
            .ok_or_else(|| format!("The Waves virtual audio session for {app_id} is no longer available."))?;
        let app = self
            .snapshot
            .apps
            .iter()
            .find(|app| app.id == app_id)
            .cloned()
            .ok_or_else(|| format!("The Waves virtual audio session for {app_id} is no longer available."))?;
        driver_rpc::set_mute(&key, !app.muted)?;
        let snapshot = self.refresh_snapshot()?;
        self.snapshot = snapshot.clone();
        Ok(snapshot)
    }

    fn output_devices(&self) -> Result<AudioOutputSnapshot, String> {
        output_snapshot(Some(self.virtual_device_id), Some(&self.target_device_id))
    }

    fn set_output_device(&mut self, device_id: &str) -> Result<AudioOutputSnapshot, String> {
        let outputs = enumerate_physical_outputs(Some(self.virtual_device_id))?;
        let target = outputs
            .into_iter()
            .find(|device| device.id == device_id)
            .ok_or_else(|| format!("Unknown Waves physical output device: {device_id}"))?;
        self.bridge.set_target(BridgeTarget {
            device_id: target.id.clone(),
            device_name: target.name.clone(),
        })?;
        self.target_device_id = target.id.clone();
        self.restore_device_id = Some(target.id.clone());
        output_snapshot(Some(self.virtual_device_id), Some(&self.target_device_id))
    }
}

fn platform_support(bridge_status: &BridgeStatus) -> PlatformSupport {
    let mut notes = vec![
        "Waves is running through its macOS virtual audio device for true per-app volume control.".to_string(),
    ];

    if let Some(target_device_name) = bridge_status.target_device_name.as_deref() {
        notes.push(format!("Audio is being played through {target_device_name}."));
    }

    if let Some(last_error) = bridge_status.last_error.as_deref() {
        notes.push(last_error.to_string());
    }

    PlatformSupport {
        platform: "macos".to_string(),
        native_backend: "macos-waves-virtual-device".to_string(),
        native_control_ready: bridge_status.running,
        discovery_ready: true,
        notes,
    }
}

fn build_app_sessions(
    snapshot: &DriverSnapshot,
    fallback_apps: &[AppAudioSession],
) -> (Vec<AppAudioSession>, HashMap<String, String>) {
    let mut apps_by_id = HashMap::new();
    let mut app_keys = HashMap::new();

    for session in &snapshot.sessions {
        let bundle_id = session
            .bundle_id
            .clone()
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| format!("pid-{}", session.pid));
        let (display_name, canonical_bundle_id, _) =
            resolve_driver_identity(session, &bundle_id, session.pid);
        let app_id = format!("macos:{canonical_bundle_id}");
        app_keys.insert(app_id.clone(), session.key.clone());

        let active = session.connected_clients > 0 || session.recent_signal || session.recent_render;
        let peak_level = if active {
            session.peak.max(LIVE_PEAK_FLOOR).clamp(0.0, 1.0)
        } else {
            0.04
        };

        apps_by_id.insert(app_id.clone(), AppAudioSession {
            id: app_id,
            display_name: display_name.clone(),
            process_name: canonical_bundle_id.clone(),
            bundle_id: Some(canonical_bundle_id.clone()),
            detected: true,
            audible: session.recent_signal,
            running_output: session.connected_clients > 0 || session.recent_render,
            recent_signal: session.recent_signal,
            recent_render: session.recent_render,
            last_seen_at: session.last_seen_ms.to_string(),
            last_signal_at: (session.last_signal_ms > 0).then_some(session.last_signal_ms.to_string()),
            category: infer_category(&display_name, Some(canonical_bundle_id.as_str())),
            volume: session.volume.min(100),
            muted: session.muted,
            active,
            pinned_hint: false,
            peak_level,
            support: SessionSupport {
                controllable: true,
                reason: None,
            },
        });
    }

    for fallback_app in fallback_apps {
        let entry = apps_by_id.entry(fallback_app.id.clone());
        match entry {
            std::collections::hash_map::Entry::Occupied(mut existing) => {
                let app = existing.get_mut();
                app.detected |= fallback_app.detected;
                app.audible |= fallback_app.audible;
                app.running_output |= fallback_app.running_output;
                app.recent_signal |= fallback_app.recent_signal;
                app.recent_render |= fallback_app.recent_render;
                app.active |= fallback_app.active;
                app.peak_level = app.peak_level.max(fallback_app.peak_level);
                if app.display_name.trim().is_empty() {
                    app.display_name = fallback_app.display_name.clone();
                }
            }
            std::collections::hash_map::Entry::Vacant(vacant) => {
                vacant.insert(fallback_app.clone());
            }
        }
    }

    let mut apps = apps_by_id.into_values().collect::<Vec<_>>();
    apps.sort_by(|left, right| {
        right
            .active
            .cmp(&left.active)
            .then_with(|| left.display_name.cmp(&right.display_name))
    });

    (apps, app_keys)
}

fn resolve_driver_identity(session: &DriverSession, fallback_bundle_id: &str, fallback_pid: i32) -> (String, String, bool) {
    let bundle_id = session
        .bundle_id
        .clone()
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| fallback_bundle_id.to_string());

    let running_application = if fallback_pid > 0 {
        NSRunningApplication::runningApplicationWithProcessIdentifier(fallback_pid)
    } else {
        None
    };
    let display_name = running_application
        .as_ref()
        .and_then(|application| application.localizedName())
        .map(|name| name.to_string())
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| friendly_app_name_from_bundle_id(&bundle_id));

    resolve_session_identity(&display_name, &bundle_id)
}

fn output_snapshot(
    excluded_device_id: Option<AudioObjectID>,
    current_target_device_id: Option<&str>,
) -> Result<AudioOutputSnapshot, String> {
    let mut devices = enumerate_physical_outputs(excluded_device_id)?;
    let current_target = current_target_device_id.map(str::to_string);
    for device in &mut devices {
        device.current = current_target.as_deref() == Some(device.id.as_str());
    }

    devices.sort_by(|left, right| {
        right
            .current
            .cmp(&left.current)
            .then_with(|| left.name.cmp(&right.name))
    });

    Ok(AudioOutputSnapshot {
        supported: true,
        reason: None,
        current_device_id: current_target,
        devices,
    })
}

fn pick_initial_target(
    outputs: &[AudioOutputDevice],
    current_default_device_id: Option<AudioObjectID>,
    virtual_device_id: AudioObjectID,
) -> Result<BridgeTarget, String> {
    if let Some(current_device_id) = current_default_device_id {
        if current_device_id != virtual_device_id {
            if let Some(device) = outputs.iter().find(|device| device.id == current_device_id.to_string()) {
                return Ok(BridgeTarget {
                    device_id: device.id.clone(),
                    device_name: device.name.clone(),
                });
            }
        }
    }

    outputs
        .first()
        .map(|device| BridgeTarget {
            device_id: device.id.clone(),
            device_name: device.name.clone(),
        })
        .ok_or_else(|| "Waves could not find a physical output device for the virtual bridge.".to_string())
}

fn enumerate_physical_outputs(excluded_device_id: Option<AudioObjectID>) -> Result<Vec<AudioOutputDevice>, String> {
    let device_ids = super::read_array::<AudioObjectID>(
        kAudioObjectSystemObject as AudioObjectID,
        kAudioHardwarePropertyDevices,
    )
    .map_err(|cause| format!("Waves could not enumerate macOS output devices: {cause}"))?;

    let mut devices = Vec::new();
    for device_id in device_ids {
        if Some(device_id) == excluded_device_id {
            continue;
        }
        if !device_supports_output(device_id).unwrap_or(false) {
            continue;
        }

        let name = match read_string_property(device_id, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal) {
            Ok(name) => name,
            Err(_) => continue,
        };
        devices.push(AudioOutputDevice {
            id: device_id.to_string(),
            name,
            current: false,
        });
    }

    Ok(devices)
}

fn find_virtual_device_id() -> Result<Option<AudioObjectID>, String> {
    let device_ids =
        super::read_array::<AudioObjectID>(kAudioObjectSystemObject as AudioObjectID, kAudioHardwarePropertyDevices)?;
    for device_id in device_ids {
        let uid = read_string_property(device_id, kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal)
            .or_else(|_| read_string_property(device_id, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal))?;
        if uid == WAVES_VIRTUAL_DEVICE_UID || uid == "Waves" {
            return Ok(Some(device_id));
        }
    }

    Ok(None)
}

fn current_default_output_device_id() -> Result<Option<AudioObjectID>, String> {
    read_value::<AudioObjectID>(
        kAudioObjectSystemObject as AudioObjectID,
        kAudioHardwarePropertyDefaultOutputDevice,
    )
    .map(Some)
}

fn ensure_virtual_default(virtual_device_id: AudioObjectID) -> Result<(), String> {
    let current_default = current_default_output_device_id()?;
    if current_default != Some(virtual_device_id) {
        set_default_output_device(virtual_device_id)?;
    }
    Ok(())
}
