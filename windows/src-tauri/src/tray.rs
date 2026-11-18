//! The tray icon: the thing that makes this a background app rather than a window you can lose.
//!
//! Left-click brings the window up; right-click opens the menu, with the four keep-awake modes as a submenu of
//! check items, so the current one is visible without opening anything else.

use std::sync::Arc;

use tauri::menu::{CheckMenuItem, Menu, MenuItem, Submenu};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager, Wry};

use crate::keep_awake::Mode;
use crate::state::AppState;

pub fn build(app: &AppHandle) -> tauri::Result<()> {
    let state = app.state::<Arc<AppState>>();
    let mode = state.active_mode();

    let open = MenuItem::with_id(app, "open", "Open Agent Hive", true, None::<&str>)?;
    let keep = Submenu::with_id(app, "keep", "Keep PC awake", true)?;
    for (id, label, value) in [
        ("ka-off", "Off", Mode::Off),
        ("ka-while", "While working", Mode::WhileWorking),
        ("ka-always", "Always", Mode::Always),
        ("ka-hour", "For 1 hour", Mode::ForOneHour),
    ] {
        let item = CheckMenuItem::with_id(app, id, label, true, value == mode, None::<&str>)?;
        keep.append(&item)?;
    }
    let quit = MenuItem::with_id(app, "quit", "Quit Agent Hive", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&open, &keep, &quit])?;

    TrayIconBuilder::with_id("main")
        .icon(tauri::include_image!("icons/icon.png"))
        .tooltip("Agent Hive")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| handle_menu(app, event.id().as_ref()))
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = event
            {
                show_main(tray.app_handle());
            }
        })
        .build(app)?;
    Ok(())
}

fn handle_menu(app: &AppHandle, id: &str) {
    match id {
        "open" => show_main(app),
        "quit" => app.exit(0),
        "ka-off" => set_mode(app, Mode::Off),
        "ka-while" => set_mode(app, Mode::WhileWorking),
        "ka-always" => set_mode(app, Mode::Always),
        "ka-hour" => set_mode(app, Mode::ForOneHour),
        _ => {}
    }
}

fn set_mode(app: &AppHandle, mode: Mode) {
    let state = app.state::<Arc<AppState>>();
    state.set_keep_awake(mode);
    // The menu's ticks have to follow the choice; rebuilding it is the simplest way to keep them honest.
    if let Some(tray) = app.tray_by_id("main") {
        let _ = rebuild_menu(app, &tray);
    }
}

fn rebuild_menu(app: &AppHandle, tray: &tauri::tray::TrayIcon<Wry>) -> tauri::Result<()> {
    let state = app.state::<Arc<AppState>>();
    let mode = state.active_mode();
    let open = MenuItem::with_id(app, "open", "Open Agent Hive", true, None::<&str>)?;
    let keep = Submenu::with_id(app, "keep", "Keep PC awake", true)?;
    for (id, label, value) in [
        ("ka-off", "Off", Mode::Off),
        ("ka-while", "While working", Mode::WhileWorking),
        ("ka-always", "Always", Mode::Always),
        ("ka-hour", "For 1 hour", Mode::ForOneHour),
    ] {
        let item = CheckMenuItem::with_id(app, id, label, true, value == mode, None::<&str>)?;
        keep.append(&item)?;
    }
    let quit = MenuItem::with_id(app, "quit", "Quit Agent Hive", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&open, &keep, &quit])?;
    tray.set_menu(Some(menu))
}

/// Shows and focuses the window, creating nothing: the window exists for as long as the app does.
pub fn show_main(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
    }
}
