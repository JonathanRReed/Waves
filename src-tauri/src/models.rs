use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MixerSnapshot {
    pub platform: PlatformSupport,
    pub apps: Vec<AppAudioSession>,
    pub generated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlatformSupport {
    pub platform: String,
    pub native_backend: String,
    pub native_control_ready: bool,
    pub discovery_ready: bool,
    pub notes: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionSupport {
    pub controllable: bool,
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppAudioSession {
    pub id: String,
    pub display_name: String,
    pub process_name: String,
    pub bundle_id: Option<String>,
    pub category: String,
    pub volume: u8,
    pub muted: bool,
    pub active: bool,
    pub pinned_hint: bool,
    pub peak_level: f32,
    pub support: SessionSupport,
}
