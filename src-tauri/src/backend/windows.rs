use crate::models::{AppAudioSession, MixerSnapshot, PlatformSupport, SessionSupport};

use super::{now_stamp, SnapshotMixerBackend};

pub fn build_backend() -> SnapshotMixerBackend {
    SnapshotMixerBackend::new(MixerSnapshot {
        platform: PlatformSupport {
            platform: "windows".to_string(),
            native_backend: "windows-session-scaffold".to_string(),
            native_control_ready: false,
            discovery_ready: true,
            notes: vec![
                "Windows is the first target for full native session control in Waves.".to_string(),
                "This build already routes UI actions through the shared Rust mixer contract.".to_string(),
            ],
        },
        generated_at: now_stamp(),
        apps: vec![
            app(
                "spotify",
                "Spotify",
                "Spotify.exe",
                Some("com.spotify.client"),
                "Music",
                82,
                0.82,
                true,
                true,
                true,
                None,
            ),
            app(
                "discord",
                "Discord",
                "Discord.exe",
                Some("com.hnc.Discord"),
                "Chat",
                38,
                0.36,
                false,
                true,
                true,
                None,
            ),
            app(
                "chrome",
                "Chrome",
                "chrome.exe",
                Some("com.google.Chrome"),
                "Browser",
                56,
                0.61,
                false,
                true,
                true,
                None,
            ),
            app(
                "zoom",
                "Zoom",
                "Zoom.exe",
                None,
                "Calls",
                47,
                0.43,
                false,
                true,
                true,
                None,
            ),
            app(
                "notion",
                "Notion",
                "Notion.exe",
                None,
                "Productivity",
                18,
                0.04,
                false,
                false,
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
    AppAudioSession {
        id: id.to_string(),
        display_name: display_name.to_string(),
        process_name: process_name.to_string(),
        bundle_id: bundle_id.map(str::to_string),
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
