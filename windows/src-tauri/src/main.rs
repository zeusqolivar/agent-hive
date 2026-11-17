// Prevents an extra console window on Windows in release builds.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod helper;

use std::sync::Arc;

use tauri::http::Response;
use tauri::{Manager, RunEvent, WebviewUrl, WebviewWindowBuilder};

use helper::Helper;

#[cfg(windows)]
#[link(name = "user32")]
extern "system" {
    /// Lets another process take the foreground: only the process the user is clicking in can grant it.
    fn AllowSetForegroundWindow(process: u32) -> i32;
}

/// The pages' origin. On Windows, WebView2 serves a registered protocol from `http://<scheme>.localhost/`.
const APP_ORIGIN: &str = "hive.localhost";

fn main() {
    let helper = Helper::new();
    let managed = Arc::new(helper);

    let app = tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            // A second launch focuses the window that is already open.
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.unminimize();
                let _ = window.set_focus();
            }
        }))
        .manage(managed.clone())
        .invoke_handler(tauri::generate_handler![open_in_browser])
        .register_asynchronous_uri_scheme_protocol("hive", move |context, request, responder| {
            // Every page request goes to hive-core over its pipe, exactly as the Mac app's hive:// handler
            // hands it to HiveAPI.
            let helper = context.app_handle().state::<Arc<Helper>>().inner().clone();
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
            let _ = window.set_focus();
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("Agent Hive couldn't start");

    app.run(move |_app, event| {
        if let RunEvent::ExitRequested { .. } = event {
            managed.stop();
        }
    });
}

/// Opens a link in the default browser. The pages call this rather than navigating the window.
#[tauri::command]
fn open_in_browser(url: String) -> Result<(), String> {
    tauri_plugin_opener::open_url(url, None::<&str>).map_err(|error| error.to_string())
}
