mod backend;
mod models;

use std::{fs, path::PathBuf, sync::Mutex};
#[cfg(target_os = "macos")]
use std::{process::Command, thread, time::Duration};

use backend::{create_backend, MixerBackend};
use models::{AudioOutputSnapshot, MixerSnapshot};
use tauri::{
    menu::{MenuBuilder, MenuItemBuilder},
    tray::{MouseButton, MouseButtonState, TrayIcon, TrayIconBuilder, TrayIconEvent},
    AppHandle, LogicalPosition, LogicalSize, Manager, Position, Rect, RunEvent, Size, State, WebviewUrl,
    WebviewWindow, WebviewWindowBuilder, WindowEvent,
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
    let _ = mode;
    "desktop".to_string()
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

fn apply_shell_mode_to_window(window: &WebviewWindow, mode: &str) -> Result<(), String> {
    let _ = mode;
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

    focus_window(window)
}

#[cfg(target_os = "macos")]
fn panel_window(app: &AppHandle) -> Result<WebviewWindow, String> {
    app.get_webview_window("panel")
        .ok_or_else(|| "Waves panel window is unavailable".to_string())
}

#[cfg(target_os = "macos")]
fn build_panel_window(app: &AppHandle) -> tauri::Result<WebviewWindow> {
    if let Some(existing) = app.get_webview_window("panel") {
        return Ok(existing);
    }

    let panel = WebviewWindowBuilder::new(app, "panel", WebviewUrl::App("index.html?surface=panel".into()))
        .title("Waves Panel")
        .inner_size(440.0, 560.0)
        .min_inner_size(440.0, 560.0)
        .resizable(false)
        .decorations(false)
        .visible(false)
        .skip_taskbar(true)
        .always_on_top(true)
        .build()?;

    let panel_clone = panel.clone();
    panel.on_window_event(move |event| {
        if matches!(event, WindowEvent::Focused(false)) {
            let _ = panel_clone.hide();
        }
    });

    Ok(panel)
}

#[cfg(target_os = "macos")]
fn rect_to_logical_components(rect: &Rect) -> (f64, f64, f64, f64) {
    let (x, y) = match rect.position {
        Position::Physical(position) => (position.x as f64, position.y as f64),
        Position::Logical(position) => (position.x, position.y),
    };
    let (width, height) = match rect.size {
        Size::Physical(size) => (size.width as f64, size.height as f64),
        Size::Logical(size) => (size.width, size.height),
    };

    (x, y, width, height)
}

#[cfg(target_os = "macos")]
fn position_panel_window(window: &WebviewWindow, rect: Option<&Rect>) -> Result<(), String> {
    let panel_width = 440.0;
    let panel_height = 560.0;
    window
        .set_size(Size::Logical(LogicalSize::new(panel_width, panel_height)))
        .map_err(|cause| cause.to_string())?;

    if let Some(rect) = rect {
        let (x, y, width, height) = rect_to_logical_components(rect);
        let anchor_x = x + (width / 2.0) - (panel_width / 2.0);
        let anchor_y = y + height + 10.0;
        window
            .set_position(Position::Logical(LogicalPosition::new(anchor_x.max(12.0), anchor_y.max(12.0))))
            .map_err(|cause| cause.to_string())?;
    }

    Ok(())
}

#[cfg(target_os = "macos")]
fn show_panel_window_internal(app: &AppHandle, rect: Option<&Rect>) -> Result<(), String> {
    let window = panel_window(app)?;
    position_panel_window(&window, rect)?;
    focus_window(&window)
}

#[cfg(target_os = "macos")]
fn hide_panel_window_internal(app: &AppHandle) -> Result<(), String> {
    panel_window(app)?.hide().map_err(|cause| cause.to_string())
}

#[cfg(target_os = "macos")]
fn toggle_panel_window(app: &AppHandle, rect: Option<&Rect>) -> Result<(), String> {
    let window = panel_window(app)?;
    let is_visible = window.is_visible().map_err(|cause| cause.to_string())?;
    if is_visible {
        hide_panel_window_internal(app)
    } else {
        show_panel_window_internal(app, rect)
    }
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
        return window.hide().map_err(|cause| cause.to_string());
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

#[cfg(not(target_os = "macos"))]
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
        #[cfg(target_os = "macos")]
        "panel" => show_panel_window_internal(app, None),
        "hide" => hide_main_window_internal(app),
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
    let panel = MenuItemBuilder::with_id("panel", "Open Menu Bar Panel").build(app)?;
    #[cfg(target_os = "macos")]
    let hide = MenuItemBuilder::with_id("hide", "Hide Window").build(app)?;
    #[cfg(not(target_os = "macos"))]
    let hide = MenuItemBuilder::with_id("hide", "Hide to Tray").build(app)?;
    let quit = MenuItemBuilder::with_id("quit", "Quit Waves").build(app)?;

    #[cfg(target_os = "macos")]
    let menu = MenuBuilder::new(app)
        .items(&[&show, &panel, &hide, &quit])
        .build()?;
    #[cfg(not(target_os = "macos"))]
    let menu = MenuBuilder::new(app)
        .items(&[&show, &hide, &quit])
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
                rect,
                ..
            } = event
            {
                let app = tray.app_handle();
                #[cfg(target_os = "macos")]
                let result = toggle_panel_window(&app, Some(&rect));
                #[cfg(not(target_os = "macos"))]
                let result = toggle_main_window(&app);

                if let Err(cause) = result {
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

#[cfg(target_os = "macos")]
fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

#[cfg(target_os = "macos")]
fn apple_script_quote(value: &str) -> String {
    format!("\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\""))
}

#[cfg(target_os = "macos")]
fn resolve_macos_driver_bundle(app: &AppHandle) -> Result<PathBuf, String> {
    let mut candidates = Vec::new();

    if let Ok(resource_dir) = app.path().resource_dir() {
        candidates.push(resource_dir.join("macos").join("WavesAudio.driver"));
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    candidates.push(manifest_dir.join("../native/macos/WavesAudioDriver/build/WavesAudio.driver"));
    candidates.push(manifest_dir.join("../native/macos/WavesAudioDriver/build2/WavesAudio.driver"));

    candidates
        .into_iter()
        .find(|path| path.exists())
        .ok_or_else(|| "Waves could not find a bundled macOS audio driver to install.".to_string())
}

#[cfg(target_os = "macos")]
fn rebuild_backend_snapshot(app: &AppHandle, state: &WavesState) -> Result<MixerSnapshot, String> {
    let tray_ready = *state
        .tray_ready
        .lock()
        .map_err(|_| "Shell state is unavailable".to_string())?;
    let mut backend = state
        .backend
        .lock()
        .map_err(|_| "Mixer backend is unavailable".to_string())?;
    *backend = create_backend();
    let mut snapshot = backend.snapshot();
    augment_snapshot_with_shell_state(&mut snapshot, tray_ready);
    let _ = app;
    Ok(snapshot)
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

#[cfg(target_os = "macos")]
#[tauri::command]
fn install_macos_driver(app: AppHandle, state: State<'_, WavesState>) -> Result<MixerSnapshot, String> {
    let driver_bundle = resolve_macos_driver_bundle(&app)?;
    let driver_bundle_str = driver_bundle
        .to_str()
        .ok_or_else(|| "The Waves macOS driver path contains unsupported characters.".to_string())?;

    let install_script = format!(
        "mkdir -p /Library/Audio/Plug-Ins/HAL && rm -rf /Library/Audio/Plug-Ins/HAL/WavesAudio.driver && cp -R {source} /Library/Audio/Plug-Ins/HAL/WavesAudio.driver && chown -R root:wheel /Library/Audio/Plug-Ins/HAL/WavesAudio.driver && killall coreaudiod",
        source = shell_quote(driver_bundle_str),
    );
    let apple_script = format!(
        "do shell script {} with administrator privileges",
        apple_script_quote(&install_script)
    );

    let output = Command::new("osascript")
        .arg("-e")
        .arg(apple_script)
        .output()
        .map_err(|cause| format!("Waves could not launch the macOS driver installer: {cause}"))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!(
            "Waves driver installation failed: {}",
            stderr.trim().trim_matches('"')
        ));
    }

    thread::sleep(Duration::from_millis(1800));
    rebuild_backend_snapshot(&app, state.inner())
}

#[cfg(not(target_os = "macos"))]
#[tauri::command]
fn install_macos_driver(_app: AppHandle, _state: State<'_, WavesState>) -> Result<MixerSnapshot, String> {
    Err("The macOS driver installer is only available on macOS.".to_string())
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

#[cfg(target_os = "macos")]
#[tauri::command]
fn hide_panel_window(app: AppHandle) -> Result<(), String> {
    hide_panel_window_internal(&app)
}

#[cfg(not(target_os = "macos"))]
#[tauri::command]
fn hide_panel_window(_app: AppHandle) -> Result<(), String> {
    Ok(())
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
            #[cfg(target_os = "macos")]
            build_panel_window(&app_handle)?;
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
            install_macos_driver,
            set_shell_mode,
            get_shell_mode,
            hide_main_window,
            hide_panel_window,
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
