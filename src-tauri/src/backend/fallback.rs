use crate::models::{AppAudioSession, MixerSnapshot, PlatformSupport, SessionSupport};

use super::{now_stamp, SnapshotMixerBackend};

pub fn build_backend() -> SnapshotMixerBackend {
    SnapshotMixerBackend::new(MixerSnapshot {
        platform: PlatformSupport {
            platform: std::env::consts::OS.to_string(),
            native_backend: "desktop-fallback-scaffold".to_string(),
            native_control_ready: false,
            discovery_ready: false,
            notes: vec![
                "Waves has loaded with the fallback backend for an unsupported platform target.".to_string(),
                "Windows and macOS adapters are the intended native targets for v1.".to_string(),
            ],
        },
        generated_at: now_stamp(),
        apps: vec![
            app(
                "browser",
                "Browser",
                "browser",
                None,
                "Browser",
                58,
                0.55,
                true,
                true,
                true,
                None,
            ),
            app(
                "music",
                "Music",
                "music-player",
                None,
                "Music",
                80,
                0.74,
                false,
                true,
                true,
                None,
            ),
            app(
                "chat",
                "Chat",
                "chat-client",
                None,
                "Chat",
                34,
                0.27,
                false,
                true,
                true,
                None,
            ),
        ],
    })
}

fn app(
    id: &str,
    display_name: &str,
    process_name: &str,
    bundle_id: Option<&str>,
    category: &str,
    volume: u8,
    peak_level: f32,
    pinned_hint: bool,
    active: bool,
    controllable: bool,
    reason: Option<&str>,
) -> AppAudioSession {
    let now = now_stamp();

    AppAudioSession {
        id: id.to_string(),
        display_name: display_name.to_string(),
        process_name: process_name.to_string(),
        bundle_id: bundle_id.map(str::to_string),
        detected: true,
        audible: active,
        running_output: active,
        recent_signal: active,
        recent_render: active,
        last_seen_at: now.clone(),
        last_signal_at: active.then_some(now.clone()),
        category: category.to_string(),
        volume,
        muted: false,
        active,
        pinned_hint,
        peak_level,
        support: SessionSupport {
            controllable,
            reason: reason.map(str::to_string),
        },
    }
}
