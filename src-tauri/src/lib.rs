mod backend;
mod models;

use std::sync::Mutex;

use backend::{create_backend, MixerBackend};
use models::MixerSnapshot;
use tauri::{
    menu::{MenuBuilder, MenuItemBuilder},
    tray::{MouseButton, MouseButtonState, TrayIcon, TrayIconBuilder, TrayIconEvent},
    AppHandle, LogicalSize, Manager, Size, State, WebviewWindow,
};

struct WavesState {
    backend: Mutex<Box<dyn MixerBackend>>,
    shell_mode: Mutex<String>,
}

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

fn apply_shell_mode_to_window(window: &WebviewWindow, mode: &str) -> Result<(), String> {
    match mode {
        "topbar" => {
            window
                .set_size(Size::Logical(LogicalSize::new(920.0, 720.0)))
                .map_err(|cause| cause.to_string())?;
            window
                .set_always_on_top(true)
                .map_err(|cause| cause.to_string())?;
            window
                .set_title("Waves • Top Bar")
                .map_err(|cause| cause.to_string())?;
        }
        _ => {
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

    Ok(normalized)
}

fn hide_main_window_internal(app: &AppHandle) -> Result<(), String> {
    let window = main_window(app)?;
    window.hide().map_err(|cause| cause.to_string())
}

fn show_main_window_internal(app: &AppHandle) -> Result<(), String> {
    let window = main_window(app)?;
    focus_window(&window)
}

fn toggle_main_window(app: &AppHandle) -> Result<(), String> {
    let window = main_window(app)?;
    if window.is_visible().map_err(|cause| cause.to_string())? {
        window.hide().map_err(|cause| cause.to_string())
    } else {
        focus_window(&window)
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

fn build_tray(app: &AppHandle) -> tauri::Result<()> {
    let show = MenuItemBuilder::with_id("show", "Show Waves").build(app)?;
    let hide = MenuItemBuilder::with_id("hide", "Hide to Tray").build(app)?;
    let desktop = MenuItemBuilder::with_id("desktop", "Desktop Mode").build(app)?;
    let topbar = MenuItemBuilder::with_id("topbar", "Top Bar Mode").build(app)?;
    let quit = MenuItemBuilder::with_id("quit", "Quit Waves").build(app)?;

    let menu = MenuBuilder::new(app)
        .items(&[&show, &hide, &desktop, &topbar, &quit])
        .build()?;

    TrayIconBuilder::new()
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
        })
        .build(app)?;

    Ok(())
}

#[tauri::command]
fn get_mixer_snapshot(state: State<'_, WavesState>) -> Result<MixerSnapshot, String> {
    let backend = state
        .backend
        .lock()
        .map_err(|_| "Mixer backend is unavailable".to_string())?;

    Ok(backend.snapshot())
}

#[tauri::command]
fn refresh_sessions(state: State<'_, WavesState>) -> Result<MixerSnapshot, String> {
    let mut backend = state
        .backend
        .lock()
        .map_err(|_| "Mixer backend is unavailable".to_string())?;

    Ok(backend.refresh())
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
fn set_shell_mode(
    mode: String,
    app: AppHandle,
) -> Result<String, String> {
    set_shell_mode_internal(&app, mode)
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
    tauri::Builder::default()
        .setup(|app| {
            let app_handle = app.handle().clone();
            build_tray(&app_handle).map_err(|cause| -> Box<dyn std::error::Error> { Box::new(cause) })?;
            Ok(())
        })
        .manage(WavesState {
            backend: Mutex::new(create_backend()),
            shell_mode: Mutex::new("desktop".to_string()),
        })
        .invoke_handler(tauri::generate_handler![
            get_mixer_snapshot,
            refresh_sessions,
            set_app_volume,
            toggle_app_mute,
            set_shell_mode,
            hide_main_window,
            show_main_window
        ])
        .run(tauri::generate_context!())
        .expect("failed to run Waves");
}
