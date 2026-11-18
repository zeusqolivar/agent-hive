//! Keeping the PC awake, the way `KeepAwakePolicy` does on the Mac.
//!
//! `SetThreadExecutionState` applies to the calling thread, so the flag is held by one dedicated thread that
//! only receives on/off messages. On lets the PC work while the screen still turns off, as on the Mac: no
//! `ES_DISPLAY_REQUIRED`.

use std::sync::mpsc::{channel, Sender};
use std::sync::{Mutex, OnceLock};

/// The four modes the panel offers.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    Off,
    WhileWorking,
    Always,
    ForOneHour,
}

impl Mode {
    pub fn as_str(self) -> &'static str {
        match self {
            Mode::Off => "off",
            Mode::WhileWorking => "while-working",
            Mode::Always => "always",
            Mode::ForOneHour => "for-one-hour",
        }
    }

    pub fn from_str(value: &str) -> Mode {
        match value {
            "while-working" => Mode::WhileWorking,
            "always" => Mode::Always,
            "for-one-hour" => Mode::ForOneHour,
            _ => Mode::Off,
        }
    }
}

#[cfg(windows)]
#[link(name = "kernel32")]
extern "system" {
    fn SetThreadExecutionState(flags: u32) -> u32;
}

#[cfg(windows)]
const ES_CONTINUOUS: u32 = 0x8000_0000;
#[cfg(windows)]
const ES_SYSTEM_REQUIRED: u32 = 0x0000_0001;

static CHANNEL: OnceLock<Mutex<Option<Sender<bool>>>> = OnceLock::new();

/// Starts the thread that owns the flag. Called once, at startup.
pub fn start() {
    let (sender, receiver) = channel::<bool>();
    if CHANNEL.set(Mutex::new(Some(sender))).is_err() {
        return;
    }
    std::thread::spawn(move || {
        let mut held = false;
        while let Ok(want) = receiver.recv() {
            if want == held {
                continue;
            }
            #[cfg(windows)]
            unsafe {
                let flags = if want { ES_CONTINUOUS | ES_SYSTEM_REQUIRED } else { ES_CONTINUOUS };
                SetThreadExecutionState(flags);
            }
            // Logged so the behaviour is observable: `powercfg /requests` needs elevation, this doesn't.
            eprintln!("keep awake: {}", if want { "on" } else { "off" });
            held = want;
        }
    });
}

/// Asks the owning thread to hold or release the flag.
pub fn set(on: bool) {
    if let Some(channel) = CHANNEL.get() {
        if let Ok(guard) = channel.lock() {
            if let Some(sender) = guard.as_ref() {
                let _ = sender.send(on);
            }
        }
    }
}

/// Whether a session is working or waiting, which is what "While working" keys off.
pub fn any_session_busy(counts: &serde_json::Value) -> bool {
    let number = |key: &str| counts.get(key).and_then(|value| value.as_i64()).unwrap_or(0);
    number("needs") > 0 || number("working") > 0
}
