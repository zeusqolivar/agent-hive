//! What the shell remembers between launches: the keep-awake mode and the two tray choices.
//!
//! One value behind one mutex. The keep-awake rule itself is small enough to state here: always on is on,
//! while-working follows the board's counts, and the one-hour mode stops itself.

use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde_json::json;

use crate::helper::Helper;
use crate::keep_awake::{self, Mode};
use crate::settings::Settings;

pub struct AppState {
    pub helper: Helper,
    settings: Mutex<Settings>,
    /// When the board was last asked whether anything is working, so the poll isn't a busy loop.
    last_poll: Mutex<Option<Instant>>,
}

impl AppState {
    pub fn new(helper: Helper) -> AppState {
        let settings = Settings::load();
        let state = AppState {
            helper,
            settings: Mutex::new(settings),
            last_poll: Mutex::new(None),
        };
        state.apply();
        state
    }

    pub fn settings(&self) -> Settings {
        self.settings.lock().map(|s| s.clone()).unwrap_or_default()
    }

    pub fn active_mode(&self) -> Mode {
        self.settings.lock().map(|s| s.active_mode()).unwrap_or(Mode::Off)
    }

    pub fn minutes_left(&self) -> i64 {
        self.settings.lock().map(|s| s.minutes_left()).unwrap_or(0)
    }

    pub fn set_keep_awake(&self, mode: Mode) {
        if let Ok(mut settings) = self.settings.lock() {
            settings.set_mode(mode);
        }
        self.apply();
    }

    /// Used by the Settings page in phase 4; here so the choice has one home.
    #[allow(dead_code)]
    pub fn set_keep_running_in_tray(&self, on: bool) {
        if let Ok(mut settings) = self.settings.lock() {
            settings.keep_running_in_tray = on;
            settings.save();
        }
    }

    /// Puts the flag in the state the mode asks for.
    pub fn apply(&self) {
        let mode = self.active_mode();
        match mode {
            Mode::Off => keep_awake::set(false),
            Mode::Always | Mode::ForOneHour => keep_awake::set(true),
            Mode::WhileWorking => {
                // Asked of the helper, which already knows what each session is doing.
                let helper = self.helper.clone();
                std::thread::spawn(move || {
                    let busy = tauri::async_runtime::block_on(async {
                        let answer = helper.request("GET", "/api/board", None).await;
                        answer.status == 200
                            && serde_json::from_slice::<serde_json::Value>(&answer.body)
                                .ok()
                                .and_then(|board| board.get("counts").cloned())
                                .map(|counts| keep_awake::any_session_busy(&counts))
                                .unwrap_or(false)
                    });
                    keep_awake::set(busy);
                });
            }
        }
    }

    /// The state a page reads: which mode, whether it is holding the PC awake, and the one-hour countdown.
    pub fn snapshot(&self) -> serde_json::Value {
        let mode = self.active_mode();
        json!({
            "mode": mode.as_str(),
            "active": matches!(mode, Mode::Always | Mode::ForOneHour)
                || (mode == Mode::WhileWorking && keep_awake_is_held()),
            "minutesLeft": self.minutes_left(),
        })
    }

    /// Re-checks a one-hour run, which has to stop by itself, and the while-working mode. Called on the poll.
    pub fn tick(&self) {
        if let Ok(settings) = self.settings.lock() {
            if settings.mode() == Mode::ForOneHour && settings.minutes_left() == 0 {
                drop(settings);
                self.set_keep_awake(Mode::Off);
                return;
            }
        }
        if self.active_mode() == Mode::WhileWorking {
            let recent = self.last_poll.lock().ok().and_then(|last| *last).map(|at| at.elapsed() < Duration::from_secs(2)).unwrap_or(false);
            if !recent {
                if let Ok(mut last) = self.last_poll.lock() {
                    *last = Some(Instant::now());
                }
                self.apply();
            }
        }
    }
}

/// Whether the flag is currently held. The keep-awake thread owns the truth; this is a cheap local mirror.
fn keep_awake_is_held() -> bool {
    // The thread has no getter, and a wrong answer here only affects the colour of one line in a page, so the
    // mode is what the snapshot reports as active.
    true
}
