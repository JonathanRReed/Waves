mod backend;
mod models;

use std::{fs, path::PathBuf, sync::Mutex};

use backend::{create_backend, MixerBackend};
use models::{AudioOutputSnapshot, MixerSnapshot};
use tauri::{
    menu::{MenuBuilder, MenuItemBuilder},
    tray::{MouseButton, MouseButtonState, TrayIcon, TrayIconBuilder, TrayIconEvent},
    AppHandle, LogicalPosition, LogicalSize, Manager, Position, RunEvent, Size, State, WebviewWindow,
};

struct WavesState {
    backend: Mutex<Box<dyn MixerBackend>>,
    shell_mode: Mutex<String>,
    tray_ready: Mutex<bool>,
}

struct TrayState {
    _tray: Mutex<Option<TrayIcon>>,
}

const SHELL_MODE_FILENAME: &str = "shell-mode.txt";

fn normalize_shell_mode(mode: String) -> String {
    if mode == "topbar" {
        "topbar".to_string()
    } else {
        "desktop".to_string()
    }
}

fn main_window(app: &AppHandle) -> Result<WebviewWindow, String> {
    app.get_webview_window("main")
        .ok_or_else(|| "Main Waves window is unavailable".to_string())
}

fn focus_window(window: &WebviewWindow) -> Result<(), String> {
    let _ = window.unminimize();
    window.show().map_err(|cause| cause.to_string())?;
    window.set_focus().map_err(|cause| cause.to_string())
}

fn position_topbar_window(window: &WebviewWindow) -> Result<(), String> {
    let Some(monitor) = window.current_monitor().map_err(|cause| cause.to_string())? else {
        return Ok(());
    };

    let scale_factor = monitor.scale_factor();
    let monitor_size = monitor.size().to_logical::<f64>(scale_factor);
    let monitor_position = monitor.position().to_logical::<f64>(scale_factor);
    let width = 640.0;
    let x = monitor_position.x + ((monitor_size.width - width) / 2.0).max(0.0);
    let y = monitor_position.y + 16.0;

    window
        .set_position(Position::Logical(LogicalPosition::new(x, y)))
        .map_err(|cause| cause.to_string())
}

fn apply_shell_mode_to_window(window: &WebviewWindow, mode: &str) -> Result<(), String> {
    match mode {
        "topbar" => {
            window
                .set_min_size(Some(Size::Logical(LogicalSize::new(520.0, 560.0))))
                .map_err(|cause| cause.to_string())?;
            window
                .set_size(Size::Logical(LogicalSize::new(640.0, 620.0)))
                .map_err(|cause| cause.to_string())?;
            position_topbar_window(window)?;
            window
                .set_always_on_top(true)
                .map_err(|cause| cause.to_string())?;
            window
                .set_title("Waves • Top Bar")
                .map_err(|cause| cause.to_string())?;
        }
        _ => {
            window
                .set_min_size(Some(Size::Logical(LogicalSize::new(980.0, 720.0))))
                .map_err(|cause| cause.to_string())?;
            window
                .set_size(Size::Logical(LogicalSize::new(1180.0, 860.0)))
                .map_err(|cause| cause.to_string())?;
            window
                .set_always_on_top(false)
                .map_err(|cause| cause.to_string())?;
            window.set_title("Waves").map_err(|cause| cause.to_string())?;
        }
    }

    focus_window(window)
}

fn shell_mode_path(app: &AppHandle) -> Result<PathBuf, String> {
    let config_dir = app.path().app_config_dir().map_err(|cause| cause.to_string())?;
    fs::create_dir_all(&config_dir).map_err(|cause| cause.to_string())?;
    Ok(config_dir.join(SHELL_MODE_FILENAME))
}

fn read_persisted_shell_mode(app: &AppHandle) -> String {
    let Ok(path) = shell_mode_path(app) else {
        return "desktop".to_string();
    };

    match fs::read_to_string(path) {
        Ok(contents) => normalize_shell_mode(contents.trim().to_string()),
        Err(_) => "desktop".to_string(),
    }
}

fn persist_shell_mode(app: &AppHandle, mode: &str) -> Result<(), String> {
    let path = shell_mode_path(app)?;
    fs::write(path, mode).map_err(|cause| cause.to_string())
}

fn set_shell_mode_internal(app: &AppHandle, mode: String) -> Result<String, String> {
    let normalized = normalize_shell_mode(mode);
    let window = main_window(app)?;
    apply_shell_mode_to_window(&window, &normalized)?;

    let state = app.state::<WavesState>();
    let mut shell_mode = state
        .shell_mode
        .lock()
        .map_err(|_| "Shell mode state is unavailable".to_string())?;
    *shell_mode = normalized.clone();
    persist_shell_mode(app, &normalized)?;

    Ok(normalized)
}

fn hide_main_window_internal(app: &AppHandle) -> Result<(), String> {
    let window = main_window(app)?;
    #[cfg(target_os = "macos")]
    {
        return window.minimize().map_err(|cause| cause.to_string());
    }

    #[cfg(not(target_os = "macos"))]
    {
        window.hide().map_err(|cause| cause.to_string())
    }
}

fn show_main_window_internal(app: &AppHandle) -> Result<(), String> {
    let window = main_window(app)?;
    let state = app.state::<WavesState>();
    let shell_mode = state
        .shell_mode
        .lock()
        .map_err(|_| "Shell mode state is unavailable".to_string())?
        .clone();

    apply_shell_mode_to_window(&window, &shell_mode)
}

fn toggle_main_window(app: &AppHandle) -> Result<(), String> {
    let window = main_window(app)?;
    let is_visible = window.is_visible().map_err(|cause| cause.to_string())?;
    let is_minimized = window.is_minimized().map_err(|cause| cause.to_string())?;

    if is_visible && !is_minimized {
        hide_main_window_internal(app)
    } else {
        show_main_window_internal(app)
    }
}

fn handle_tray_menu_event(app: &AppHandle, item_id: &str) {
    let result = match item_id {
        "show" => show_main_window_internal(app),
        "hide" => hide_main_window_internal(app),
        "desktop" => set_shell_mode_internal(app, "desktop".to_string()).map(|_| ()),
        "topbar" => set_shell_mode_internal(app, "topbar".to_string()).map(|_| ()),
        "quit" => {
            app.exit(0);
            Ok(())
        }
        _ => Ok(()),
    };

    if let Err(cause) = result {
        eprintln!("{cause}");
    }
}

fn build_tray(app: &AppHandle) -> tauri::Result<TrayIcon> {
    let show = MenuItemBuilder::with_id("show", "Show Waves").build(app)?;
    #[cfg(target_os = "macos")]
    let hide = MenuItemBuilder::with_id("hide", "Hide Window").build(app)?;
    #[cfg(not(target_os = "macos"))]
    let hide = MenuItemBuilder::with_id("hide", "Hide to Tray").build(app)?;
    let desktop = MenuItemBuilder::with_id("desktop", "Desktop Mode").build(app)?;
    let topbar = MenuItemBuilder::with_id("topbar", "Top Bar Mode").build(app)?;
    let quit = MenuItemBuilder::with_id("quit", "Quit Waves").build(app)?;

    let menu = MenuBuilder::new(app)
        .items(&[&show, &hide, &desktop, &topbar, &quit])
        .build()?;

    let mut builder = TrayIconBuilder::new()
        .tooltip("Waves")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app: &AppHandle, event: tauri::menu::MenuEvent| {
            handle_tray_menu_event(app, event.id().as_ref())
        })
        .on_tray_icon_event(|tray: &TrayIcon, event: TrayIconEvent| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                let app = tray.app_handle();
                if let Err(cause) = toggle_main_window(&app) {
                    eprintln!("{cause}");
                }
            }
        });

    #[cfg(target_os = "macos")]
    {
        builder = builder.title("Waves");
    }

    #[cfg(not(target_os = "macos"))]
    if let Some(icon) = app.default_window_icon().cloned() {
        builder = builder.icon(icon);
    }

    builder.build(app)
}

fn augment_snapshot_with_shell_state(snapshot: &mut MixerSnapshot, tray_ready: bool) {
    #[cfg(target_os = "macos")]
    if !tray_ready {
        snapshot
            .platform
            .notes
            .push("Waves could not create its menu bar item. Reopen from the Dock while troubleshooting tray setup.".to_string());
    }
}

#[tauri::command]
fn get_mixer_snapshot(state: State<'_, WavesState>) -> Result<MixerSnapshot, String> {
    let backend = state
        .backend
        .lock()
        .map_err(|_| "Mixer backend is unavailable".to_string())?;
    let tray_ready = *state
        .tray_ready
        .lock()
        .map_err(|_| "Shell state is unavailable".to_string())?;

    let mut snapshot = backend.snapshot();
    augment_snapshot_with_shell_state(&mut snapshot, tray_ready);
    Ok(snapshot)
}

#[tauri::command]
fn refresh_sessions(state: State<'_, WavesState>) -> Result<MixerSnapshot, String> {
    let mut backend = state
        .backend
        .lock()
        .map_err(|_| "Mixer backend is unavailable".to_string())?;
    let tray_ready = *state
        .tray_ready
        .lock()
        .map_err(|_| "Shell state is unavailable".to_string())?;

    let mut snapshot = backend.refresh();
    augment_snapshot_with_shell_state(&mut snapshot, tray_ready);
    Ok(snapshot)
}

#[tauri::command]
fn set_app_volume(
    app_id: String,
    volume: u8,
    state: State<'_, WavesState>,
) -> Result<MixerSnapshot, String> {
    let mut backend = state
        .backend
        .lock()
        .map_err(|_| "Mixer backend is unavailable".to_string())?;

    backend.set_volume(&app_id, volume)
}

#[tauri::command]
fn toggle_app_mute(app_id: String, state: State<'_, WavesState>) -> Result<MixerSnapshot, String> {
    let mut backend = state
        .backend
        .lock()
        .map_err(|_| "Mixer backend is unavailable".to_string())?;

    backend.toggle_mute(&app_id)
}

#[tauri::command]
fn get_output_devices(state: State<'_, WavesState>) -> Result<AudioOutputSnapshot, String> {
    let backend = state
        .backend
        .lock()
        .map_err(|_| "Mixer backend is unavailable".to_string())?;

    backend.output_devices()
}

#[tauri::command]
fn set_output_device(
    device_id: String,
    state: State<'_, WavesState>,
) -> Result<AudioOutputSnapshot, String> {
    let mut backend = state
        .backend
        .lock()
        .map_err(|_| "Mixer backend is unavailable".to_string())?;

    backend.set_output_device(&device_id)
}

#[tauri::command]
fn set_shell_mode(
    mode: String,
    app: AppHandle,
) -> Result<String, String> {
    set_shell_mode_internal(&app, mode)
}

#[tauri::command]
fn get_shell_mode(state: State<'_, WavesState>) -> Result<String, String> {
    state
        .shell_mode
        .lock()
        .map_err(|_| "Shell mode state is unavailable".to_string())
        .map(|mode| mode.clone())
}

#[tauri::command]
fn hide_main_window(app: AppHandle) -> Result<(), String> {
    hide_main_window_internal(&app)
}

#[tauri::command]
fn show_main_window(app: AppHandle) -> Result<(), String> {
    show_main_window_internal(&app)
}

pub fn run() {
    let app = tauri::Builder::default()
        .manage(WavesState {
            backend: Mutex::new(create_backend()),
            shell_mode: Mutex::new("desktop".to_string()),
            tray_ready: Mutex::new(false),
        })
        .setup(|app| {
            let app_handle = app.handle().clone();
            let initial_shell_mode = read_persisted_shell_mode(&app_handle);
            {
                let state = app.state::<WavesState>();
                let mut shell_mode = state
                    .shell_mode
                    .lock()
                    .map_err(|_| -> Box<dyn std::error::Error> {
                        Box::new(std::io::Error::new(
                            std::io::ErrorKind::Other,
                            "Shell mode state is unavailable",
                        ))
                    })?;
                *shell_mode = initial_shell_mode.clone();
            }
            set_shell_mode_internal(&app_handle, initial_shell_mode)
                .map_err(|cause| -> Box<dyn std::error::Error> {
                    Box::new(std::io::Error::new(std::io::ErrorKind::Other, cause))
                })?;
            let tray = match build_tray(&app_handle) {
                Ok(tray) => {
                    let state = app.state::<WavesState>();
                    if let Ok(mut tray_ready) = state.tray_ready.lock() {
                        *tray_ready = true;
                    }
                    Some(tray)
                }
                Err(cause) => {
                    eprintln!("Failed to initialize Waves tray icon: {cause}");
                    None
                }
            };
            app.manage(TrayState {
                _tray: Mutex::new(tray),
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_mixer_snapshot,
            refresh_sessions,
            set_app_volume,
            toggle_app_mute,
            get_output_devices,
            set_output_device,
            set_shell_mode,
            get_shell_mode,
            hide_main_window,
            show_main_window
        ])
        .build(tauri::generate_context!())
        .expect("failed to build Waves");

    app.run(|app_handle, event| {
        if let RunEvent::Reopen { .. } = event {
            if let Err(cause) = show_main_window_internal(app_handle) {
                eprintln!("{cause}");
            }
        }
    });
}
