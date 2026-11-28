//! The shell's own settings: `%APPDATA%\Agent Hive\shell.json`.
//!
//! Small on purpose — a JSON object of the choices that outlive a launch. The Mac app keeps the same four in
//! `AppModel`; here they belong to the shell, not to HiveCore.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::keep_awake::Mode;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    /// The keep-awake mode, and when a one-hour run ends (unix seconds), so a restart doesn't forget it.
    pub keep_awake: String,
    pub keep_awake_until: Option<i64>,
    /// Start in the tray instead of opening the window at sign-in.
    pub open_window_at_sign_in: bool,
    /// Keep running in the tray when the window is closed.
    pub keep_running_in_tray: bool,
}

impl Default for Settings {
    fn default() -> Settings {
        Settings {
            keep_awake: "off".into(),
            keep_awake_until: None,
            open_window_at_sign_in: true,
            keep_running_in_tray: true,
        }
    }
}

impl Settings {
    pub fn path() -> PathBuf {
        let app_data = std::env::var_os("APPDATA").map(PathBuf::from).unwrap_or_default();
        app_data.join("Agent Hive").join("shell.json")
    }

    /// Never fails: a missing or damaged file means the defaults, which is what a first run looks like.
    pub fn load() -> Settings {
        std::fs::read_to_string(Self::path())
            .ok()
            .and_then(|text| serde_json::from_str(&text).ok())
            .unwrap_or_default()
    }

    pub fn save(&self) {
        let path = Self::path();
        if let Some(folder) = path.parent() {
            let _ = std::fs::create_dir_all(folder);
        }
        if let Ok(text) = serde_json::to_string_pretty(self) {
            // Written beside and moved over, so a reader never sees half a file.
            let temp = path.with_extension("json.tmp");
            if std::fs::write(&temp, text).is_ok() {
                let _ = std::fs::rename(&temp, &path);
            }
        }
    }

    pub fn mode(&self) -> Mode {
        Mode::from_str(&self.keep_awake)
    }

    /// The mode that is actually in force: an expired one-hour run is Off.
    pub fn active_mode(&self) -> Mode {
        match self.mode() {
            Mode::ForOneHour => match self.keep_awake_until {
                Some(until) if until > now() => Mode::ForOneHour,
                _ => Mode::Off,
            },
            other => other,
        }
    }

    pub fn minutes_left(&self) -> i64 {
        match self.keep_awake_until {
            Some(until) if self.mode() == Mode::ForOneHour => ((until - now()).max(0) + 59) / 60,
            _ => 0,
        }
    }

    /// Sets a mode, remembering the deadline for the one-hour one.
    pub fn set_mode(&mut self, mode: Mode) {
        self.keep_awake = mode.as_str().to_string();
        self.keep_awake_until = if mode == Mode::ForOneHour { Some(now() + 3600) } else { None };
        self.save();
    }
}

pub fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}
