use std::{path::Path, ptr};

use windows::{
    core::{Interface, PWSTR},
    Win32::{
        Foundation::{CloseHandle, S_OK, RPC_E_CHANGED_MODE},
        Media::Audio::{
            eMultimedia, eRender, AudioSessionStateActive, IAudioSessionControl,
            IAudioSessionControl2, IAudioSessionManager2, IMMDevice, IMMDeviceEnumerator,
            ISimpleAudioVolume, MMDeviceEnumerator,
        },
        System::{
            Com::{
                CoCreateInstance, CoInitializeEx, CoTaskMemFree, CoUninitialize, CLSCTX_ALL,
                COINIT_MULTITHREADED,
            },
            Threading::{
                OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_FORMAT,
                PROCESS_QUERY_LIMITED_INFORMATION,
            },
        },
    },
};

use crate::models::{AppAudioSession, MixerSnapshot, PlatformSupport, SessionSupport};

use super::{now_stamp, MixerBackend};

pub fn build_backend() -> WindowsMixerBackend {
    WindowsMixerBackend {
        snapshot: enumerate_snapshot().unwrap_or_else(snapshot_from_error),
    }
}

pub struct WindowsMixerBackend {
    snapshot: MixerSnapshot,
}

struct ComScope {
    should_uninitialize: bool,
}

struct NativeWindowsSession {
    id: String,
    app: AppAudioSession,
    simple_volume: Option<ISimpleAudioVolume>,
}

impl ComScope {
    fn init() -> Result<Self, String> {
        let result = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
        if result.is_ok() {
            Ok(Self {
                should_uninitialize: true,
            })
        } else if result == RPC_E_CHANGED_MODE {
            Ok(Self {
                should_uninitialize: false,
            })
        } else {
            Err(format!("Windows COM initialization failed: {result}"))
        }
    }
}

impl Drop for ComScope {
    fn drop(&mut self) {
        if self.should_uninitialize {
            unsafe {
                CoUninitialize();
            }
        }
    }
}

impl MixerBackend for WindowsMixerBackend {
    fn snapshot(&self) -> MixerSnapshot {
        self.snapshot.clone()
    }

    fn refresh(&mut self) -> MixerSnapshot {
        self.snapshot = enumerate_snapshot().unwrap_or_else(snapshot_from_error);
        self.snapshot.clone()
    }

    fn set_volume(&mut self, app_id: &str, volume: u8) -> Result<MixerSnapshot, String> {
        with_matching_session(app_id, |session| {
            let simple_volume = session
                .simple_volume
                .as_ref()
                .ok_or_else(|| unsupported_reason(&session.app))?;
            unsafe {
                simple_volume
                    .SetMasterVolume((volume.min(100) as f32 / 100.0).clamp(0.0, 1.0), ptr::null())
                    .map_err(|error| format!("Windows session volume write failed: {error}"))?;
            }
            Ok(())
        })?;

        self.snapshot = enumerate_snapshot().unwrap_or_else(snapshot_from_error);
        Ok(self.snapshot.clone())
    }

    fn toggle_mute(&mut self, app_id: &str) -> Result<MixerSnapshot, String> {
        with_matching_session(app_id, |session| {
            let simple_volume = session
                .simple_volume
                .as_ref()
                .ok_or_else(|| unsupported_reason(&session.app))?;
            let current = unsafe {
                simple_volume
                    .GetMute()
                    .map_err(|error| format!("Windows session mute read failed: {error}"))?
                    .as_bool()
            };
            unsafe {
                simple_volume
                    .SetMute(!current, ptr::null())
                    .map_err(|error| format!("Windows session mute write failed: {error}"))?;
            }
            Ok(())
        })?;

        self.snapshot = enumerate_snapshot().unwrap_or_else(snapshot_from_error);
        Ok(self.snapshot.clone())
    }
}

fn enumerate_snapshot() -> Result<MixerSnapshot, String> {
    let sessions = with_com(enumerate_native_sessions)?;

    let mut apps = sessions.into_iter().map(|session| session.app).collect::<Vec<_>>();
    apps.sort_by(|left, right| {
        right
            .active
            .cmp(&left.active)
            .then_with(|| left.display_name.cmp(&right.display_name))
    });

    Ok(MixerSnapshot {
        platform: PlatformSupport {
            platform: "windows".to_string(),
            native_backend: "windows-wasapi-session-manager".to_string(),
            native_control_ready: true,
            discovery_ready: true,
            notes: vec![
                "Waves is enumerating real Windows WASAPI render sessions.".to_string(),
                "Per-app volume and mute writes use ISimpleAudioVolume on the matching session.".to_string(),
            ],
        },
        generated_at: now_stamp(),
        apps,
    })
}

fn with_matching_session<T>(
    app_id: &str,
    callback: impl FnOnce(NativeWindowsSession) -> Result<T, String>,
) -> Result<T, String> {
    with_com(|| {
        let session = enumerate_native_sessions()?
            .into_iter()
            .find(|session| session.id == app_id)
            .ok_or_else(|| format!("Unknown Windows audio session: {app_id}"))?;

        callback(session)
    })
}

fn with_com<T>(callback: impl FnOnce() -> Result<T, String>) -> Result<T, String> {
    let _scope = ComScope::init()?;
    callback()
}

fn enumerate_native_sessions() -> Result<Vec<NativeWindowsSession>, String> {
    let enumerator: IMMDeviceEnumerator = unsafe {
        CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)
            .map_err(|error| format!("Windows MMDeviceEnumerator creation failed: {error}"))?
    };
    let device: IMMDevice = unsafe {
        enumerator
            .GetDefaultAudioEndpoint(eRender, eMultimedia)
            .map_err(|error| format!("Windows default render endpoint lookup failed: {error}"))?
    };
    let manager: IAudioSessionManager2 = unsafe {
        device
            .Activate(CLSCTX_ALL, None)
            .map_err(|error| format!("Windows audio session manager activation failed: {error}"))?
    };
    let session_enumerator = unsafe {
        manager
            .GetSessionEnumerator()
            .map_err(|error| format!("Windows audio session enumeration failed: {error}"))?
    };
    let count = unsafe {
        session_enumerator
            .GetCount()
            .map_err(|error| format!("Windows audio session count lookup failed: {error}"))?
    };

    let mut sessions = Vec::new();
    for index in 0..count {
        let control = unsafe {
            session_enumerator
                .GetSession(index)
                .map_err(|error| format!("Windows audio session access failed: {error}"))?
        };
        if let Some(session) = build_native_session(index, control)? {
            sessions.push(session);
        }
    }

    Ok(sessions)
}

fn build_native_session(
    index: i32,
    control: IAudioSessionControl,
) -> Result<Option<NativeWindowsSession>, String> {
    let control2: IAudioSessionControl2 = control
        .cast()
        .map_err(|error| format!("Windows session control cast failed: {error}"))?;
    let process_id = unsafe {
        control2
            .GetProcessId()
            .map_err(|error| format!("Windows session process id lookup failed: {error}"))?
    };
    let session_id = take_pwstr_string(unsafe {
        control2
            .GetSessionInstanceIdentifier()
            .map_err(|error| format!("Windows session identifier lookup failed: {error}"))?
    });
    let state = unsafe {
        control
            .GetState()
            .map_err(|error| format!("Windows session state lookup failed: {error}"))?
    };
    let system_sounds = unsafe { control2.IsSystemSoundsSession() == S_OK };

    if process_id == 0 && !system_sounds {
        return Ok(None);
    }

    let simple_volume = control.cast::<ISimpleAudioVolume>().ok();
    let volume = if let Some(simple_volume) = &simple_volume {
        unsafe {
            (simple_volume
                .GetMasterVolume()
                .map_err(|error| format!("Windows session volume read failed: {error}"))?
                * 100.0)
                .round()
                .clamp(0.0, 100.0) as u8
        }
    } else {
        100
    };
    let muted = if let Some(simple_volume) = &simple_volume {
        unsafe {
            simple_volume
                .GetMute()
                .map_err(|error| format!("Windows session mute read failed: {error}"))?
                .as_bool()
        }
    } else {
        false
    };

    let display_name_raw = take_pwstr_string(unsafe {
        control
            .GetDisplayName()
            .map_err(|error| format!("Windows session display name lookup failed: {error}"))?
    });
    let process_path = process_image_path(process_id);
    let process_name = process_path
        .as_deref()
        .and_then(file_name)
        .unwrap_or_else(|| {
            if system_sounds {
                "SystemSounds.exe".to_string()
            } else {
                format!("process-{process_id}.exe")
            }
        });
    let display_name = if display_name_raw.is_empty() {
        if system_sounds {
            "System Sounds".to_string()
        } else {
            friendly_name_from_process(&process_name)
        }
    } else {
        display_name_raw
    };
    let id = if session_id.is_empty() {
        format!("windows:{process_id}:{index}")
    } else {
        format!("windows:{session_id}")
    };
    let active = state == AudioSessionStateActive;

    Ok(Some(NativeWindowsSession {
        id: id.clone(),
        app: AppAudioSession {
            id,
            display_name: display_name.clone(),
            process_name: process_name.clone(),
            bundle_id: process_path
                .as_deref()
                .and_then(file_stem)
                .map(|stem| stem.to_ascii_lowercase()),
            category: infer_category(&display_name, &process_name),
            volume,
            muted,
            active,
            pinned_hint: false,
            peak_level: if active && !muted {
                ((volume as f32 / 100.0) * 0.74).clamp(0.06, 1.0)
            } else {
                0.04
            },
            support: SessionSupport {
                controllable: simple_volume.is_some(),
                reason: if simple_volume.is_some() {
                    None
                } else {
                    Some("Waves could not open ISimpleAudioVolume for this Windows session.".to_string())
                },
            },
        },
        simple_volume,
    }))
}

fn process_image_path(process_id: u32) -> Option<String> {
    if process_id == 0 {
        return None;
    }

    let handle = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, process_id).ok()? };
    let mut buffer = vec![0_u16; 1024];
    let mut size = buffer.len() as u32;
    let result = unsafe {
        QueryFullProcessImageNameW(
            handle,
            PROCESS_NAME_FORMAT(0),
            PWSTR(buffer.as_mut_ptr()),
            &mut size,
        )
    };
    unsafe {
        let _ = CloseHandle(handle);
    }
    if result.is_err() {
        return None;
    }

    Some(String::from_utf16_lossy(&buffer[..size as usize]))
}

fn take_pwstr_string(pointer: PWSTR) -> String {
    if pointer.is_null() {
        return String::new();
    }

    let text = unsafe { pointer.to_string().unwrap_or_default() };
    unsafe {
        CoTaskMemFree(Some(pointer.0.cast()));
    }
    text
}

fn file_name(path: &str) -> Option<String> {
    Path::new(path)
        .file_name()
        .map(|value| value.to_string_lossy().into_owned())
}

fn file_stem(path: &str) -> Option<String> {
    Path::new(path)
        .file_stem()
        .map(|value| value.to_string_lossy().into_owned())
}

fn friendly_name_from_process(process_name: &str) -> String {
    file_stem(process_name)
        .unwrap_or_else(|| process_name.to_string())
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
        .join(" ")
}

fn infer_category(display_name: &str, process_name: &str) -> String {
    let haystack = format!(
        "{} {}",
        display_name.to_lowercase(),
        process_name.to_lowercase()
    );

    if haystack.contains("spotify") || haystack.contains("music") {
        return "Music".to_string();
    }

    if haystack.contains("discord")
        || haystack.contains("slack")
        || haystack.contains("teams")
        || haystack.contains("chat")
    {
        return "Chat".to_string();
    }

    if haystack.contains("zoom") || haystack.contains("meet") || haystack.contains("call") {
        return "Calls".to_string();
    }

    if haystack.contains("chrome") || haystack.contains("edge") || haystack.contains("firefox") || haystack.contains("browser") {
        return "Browser".to_string();
    }

    "Productivity".to_string()
}

fn unsupported_reason(app: &AppAudioSession) -> String {
    app.support
        .reason
        .clone()
        .unwrap_or_else(|| "This Windows session is not controllable right now.".to_string())
}

fn snapshot_from_error(reason: String) -> MixerSnapshot {
    MixerSnapshot {
        platform: PlatformSupport {
            platform: "windows".to_string(),
            native_backend: "windows-wasapi-session-manager".to_string(),
            native_control_ready: false,
            discovery_ready: false,
            notes: vec![
                "Waves could not enumerate Windows WASAPI render sessions.".to_string(),
                reason,
            ],
        },
        generated_at: now_stamp(),
        apps: Vec::new(),
    }
}
