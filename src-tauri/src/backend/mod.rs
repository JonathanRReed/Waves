#[cfg(not(any(target_os = "windows", target_os = "macos")))]
pub mod fallback;
#[cfg(target_os = "macos")]
pub mod macos;
#[cfg(target_os = "windows")]
pub mod windows;

use std::time::{SystemTime, UNIX_EPOCH};

use crate::models::{AppAudioSession, AudioOutputSnapshot, MixerSnapshot};

pub trait MixerBackend: Send {
    fn snapshot(&self) -> MixerSnapshot;
    fn refresh(&mut self) -> MixerSnapshot;
    fn set_volume(&mut self, app_id: &str, volume: u8) -> Result<MixerSnapshot, String>;
    fn toggle_mute(&mut self, app_id: &str) -> Result<MixerSnapshot, String>;

    fn output_devices(&self) -> Result<AudioOutputSnapshot, String> {
        Ok(AudioOutputSnapshot {
            supported: false,
            reason: Some("Output device control is unavailable on this platform.".to_string()),
            current_device_id: None,
            devices: Vec::new(),
        })
    }

    fn set_output_device(&mut self, _device_id: &str) -> Result<AudioOutputSnapshot, String> {
        Err("Output device switching is unavailable on this platform.".to_string())
    }
}

pub struct SnapshotMixerBackend {
    snapshot: MixerSnapshot,
}

impl SnapshotMixerBackend {
    pub fn new(snapshot: MixerSnapshot) -> Self {
        Self { snapshot }
    }

    fn locate_app_mut(&mut self, app_id: &str) -> Result<&mut AppAudioSession, String> {
        self.snapshot
            .apps
            .iter_mut()
            .find(|app| app.id == app_id)
            .ok_or_else(|| format!("Unknown app session: {app_id}"))
    }

    fn stamp(&mut self) {
        self.snapshot.generated_at = now_stamp();
    }
}

pub(crate) fn session_control_error(app: &AppAudioSession) -> String {
    app.support
        .reason
        .clone()
        .unwrap_or_else(|| "This session is not controllable yet".to_string())
}

pub(crate) fn update_peak_levels(apps: &mut [AppAudioSession]) {
    let tick = tick_seed();

    for (index, app) in apps.iter_mut().enumerate() {
        if !app.active || app.muted || app.volume == 0 {
            app.peak_level = 0.04;
            continue;
        }

        let jitter = (stable_seed(&app.id) + tick + index as u64 * 19) % 100;
        let lift = 0.18 + jitter as f32 / 100.0 * 0.68;
        app.peak_level = ((app.volume as f32 / 100.0) * lift).clamp(0.06, 1.0);
    }
}

impl MixerBackend for SnapshotMixerBackend {
    fn snapshot(&self) -> MixerSnapshot {
        self.snapshot.clone()
    }

    fn refresh(&mut self) -> MixerSnapshot {
        update_peak_levels(&mut self.snapshot.apps);

        self.stamp();
        self.snapshot.clone()
    }

    fn set_volume(&mut self, app_id: &str, volume: u8) -> Result<MixerSnapshot, String> {
        {
            let app = self.locate_app_mut(app_id)?;
            if !app.support.controllable {
                return Err(session_control_error(app));
            }

            app.volume = volume.min(100);
            app.muted = app.volume == 0;
        }

        Ok(self.refresh())
    }

    fn toggle_mute(&mut self, app_id: &str) -> Result<MixerSnapshot, String> {
        {
            let app = self.locate_app_mut(app_id)?;
            if !app.support.controllable {
                return Err(session_control_error(app));
            }

            app.muted = !app.muted;
        }

        Ok(self.refresh())
    }
}

#[cfg(target_os = "windows")]
pub fn create_backend() -> Box<dyn MixerBackend> {
    Box::new(windows::build_backend())
}

#[cfg(target_os = "macos")]
pub fn create_backend() -> Box<dyn MixerBackend> {
    Box::new(macos::build_backend())
}

#[cfg(not(any(target_os = "windows", target_os = "macos")))]
pub fn create_backend() -> Box<dyn MixerBackend> {
    Box::new(fallback::build_backend())
}

pub fn now_stamp() -> String {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
        .to_string()
}

fn tick_seed() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

fn stable_seed(value: &str) -> u64 {
    value
        .bytes()
        .fold(0_u64, |accumulator, byte| accumulator.wrapping_mul(31).wrapping_add(byte as u64))
}
