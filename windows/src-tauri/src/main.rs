// Prevents an extra console window on Windows in release builds.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod autostart;
mod helper;
mod keep_awake;
mod settings;
mod state;
mod tray;

use std::sync::Arc;
use std::time::Duration;

use tauri::http::Response;
use tauri::{Manager, RunEvent, WebviewUrl, WebviewWindowBuilder, WindowEvent};

use helper::Helper;
use keep_awake::Mode;
use settings::Settings;
use state::AppState;

/// The pages' origin. On Windows, WebView2 serves a registered protocol from `http://<scheme>.localhost/`.
const APP_ORIGIN: &str = "hive.localhost";

#[cfg(windows)]
#[link(name = "user32")]
extern "system" {
    /// Lets another process take the foreground: only the process the user is clicking in can grant it.
    fn AllowSetForegroundWindow(process: u32) -> i32;
}

fn main() {
    // The two switches that only touch settings, for a terminal or a script. Like the Mac app's `--login-item`.
    handle_command_line();

    // The thread that owns the execution-state flag has to exist before the settings are applied, or a launch
    // that starts with a mode other than Off has nowhere to send it.
    keep_awake::start();
    let app_state = Arc::new(AppState::new(Helper::new()));

    let app = tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            // A second launch focuses the window that is already open.
            tray::show_main(app);
        }))
        .manage(app_state.clone())
        .invoke_handler(tauri::generate_handler![
            open_in_browser,
            open_main,
            get_keep_awake,
            set_keep_awake,
            get_autostart,
            set_autostart,
            quit
        ])
        .register_asynchronous_uri_scheme_protocol("hive", move |context, request, responder| {
            // Every page request goes to hive-core over its pipe, exactly as the Mac app's hive:// handler
            // hands it to HiveAPI.
            let state = context.app_handle().state::<Arc<AppState>>().inner().clone();
            let helper = state.helper.clone();
            let method = request.method().as_str().to_string();
            // Path and query string only: the page's own origin is not hive-core's business.
            let path = request
                .uri()
                .path_and_query()
                .map(|value| value.as_str().to_string())
                .unwrap_or_else(|| "/".to_string());
            let body = if request.body().is_empty() {
                None
            } else {
                Some(request.body().clone())
            };
            tauri::async_runtime::spawn(async move {
                // An action may bring another app forward. Windows only lets the foreground process grant that
                // right, and the shell is the one the user just clicked in, so it hands it to the helper here.
                if path.starts_with("/api/action") {
                    if let Some(pid) = helper.pid() {
                        #[cfg(windows)]
                        unsafe {
                            AllowSetForegroundWindow(pid);
                        }
                    }
                }
                let answer = helper.request(&method, &path, body).await;
                let response = Response::builder()
                    .status(answer.status)
                    .header("Content-Type", answer.content_type)
                    .header("Cache-Control", "no-store")
                    .body(answer.body)
                    .expect("a response with a body");
                responder.respond(response);
            });
        })
        .setup(move |app| {
            let url = format!("http://{APP_ORIGIN}/");
            let window = WebviewWindowBuilder::new(app, "main", WebviewUrl::External(url.parse()?))
                .title("Agent Hive")
                .inner_size(1200.0, 800.0)
                .min_inner_size(620.0, 480.0)
                .visible(!start_hidden())
                // Links in transcripts, GitHub and pull requests belong in the default browser, as WebView.swift
                // does on the Mac.
                .on_navigation(|url| {
                    if url.host_str() == Some(APP_ORIGIN) {
                        return true;
                    }
                    let _ = tauri_plugin_opener::open_url(url.as_str(), None::<&str>);
                    false
                })
                .build()?;

            // Closing the window keeps the app in the tray, as closing the Mac window keeps its menu bar icon.
            let handle = app.handle().clone();
            let window_for_close = window.clone();
            window.on_window_event(move |event| {
                if let WindowEvent::CloseRequested { api, .. } = event {
                    let state = handle.state::<Arc<AppState>>();
                    if state.settings().keep_running_in_tray {
                        api.prevent_close();
                        let _ = window_for_close.hide();
                    }
                }
            });

            tray::build(app.handle())?;

            // The tick that lets a one-hour run expire, and that keeps "while working" honest.
            let state = app.state::<Arc<AppState>>().inner().clone();
            std::thread::spawn(move || loop {
                state.tick();
                std::thread::sleep(Duration::from_secs(5));
            });

            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("Agent Hive couldn't start");

    app.run(move |_app, event| {
        if let RunEvent::ExitRequested { .. } = event {
            app_state.helper.stop();
        }
    });
}

/// `Agent Hive.exe --keep-awake always` and `--autostart on` change one setting and exit, which is how the
/// panel's Settings page and a script both reach the same code.
fn handle_command_line() {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let value_after = |flag: &str| {
        arguments
            .iter()
            .position(|argument| argument == flag)
            .and_then(|index| arguments.get(index + 1))
            .cloned()
    };
    if let Some(mode) = value_after("--keep-awake") {
        let mut settings = Settings::load();
        settings.set_mode(Mode::from_str(&mode));
        println!("keep awake: {}", settings.keep_awake);
        std::process::exit(0);
    }
    if let Some(state) = value_after("--autostart") {
        let on = matches!(state.as_str(), "on" | "true" | "1");
        match autostart::set(on) {
            Ok(enabled) => println!("start at sign-in: {enabled}"),
            Err(error) => println!("start at sign-in: {error}"),
        }
        std::process::exit(0);
    }
}

/// Sign-in starts the app without a window when the user asked for that; a normal launch shows it.
fn start_hidden() -> bool {
    let sign_in = std::env::args().any(|arg| arg == "--autostart");
    sign_in && !Settings::load().open_window_at_sign_in
}

/// Opens a link in the default browser. The pages call this rather than navigating the window.
#[tauri::command]
fn open_in_browser(url: String) -> Result<(), String> {
    tauri_plugin_opener::open_url(url, None::<&str>).map_err(|error| error.to_string())
}

/// Shows the window, optionally on a view: `open_main(route: "#/classroom")`.
#[tauri::command]
fn open_main(app: tauri::AppHandle, route: Option<String>) {
    tray::show_main(&app);
    if let Some(route) = route {
        if let Some(window) = app.get_webview_window("main") {
            let _ = window.eval(&format!("location.hash = '{}'", route.replace('\'', "")));
        }
    }
}

#[tauri::command]
fn get_keep_awake(state: tauri::State<'_, Arc<AppState>>) -> serde_json::Value {
    state.snapshot()
}

#[tauri::command]
fn set_keep_awake(state: tauri::State<'_, Arc<AppState>>, mode: String) -> serde_json::Value {
    state.set_keep_awake(Mode::from_str(&mode));
    state.snapshot()
}

#[tauri::command]
fn get_autostart(app: tauri::AppHandle) -> bool {
    use tauri_plugin_autostart::ManagerExt;
    app.autolaunch().is_enabled().unwrap_or(false)
}

#[tauri::command]
fn set_autostart(app: tauri::AppHandle, on: bool) -> Result<bool, String> {
    use tauri_plugin_autostart::ManagerExt;
    let manager = app.autolaunch();
    let result = if on { manager.enable() } else { manager.disable() };
    result.map_err(|error| error.to_string())?;
    Ok(manager.is_enabled().unwrap_or(false))
}

#[tauri::command]
fn quit(app: tauri::AppHandle, state: tauri::State<'_, Arc<AppState>>) {
    state.helper.stop();
    app.exit(0);
}
