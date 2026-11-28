//! Starting at sign-in.
//!
//! The app's own `--autostart` switch writes the same `Run` value the Tauri autostart plugin does, so a script or
//! the Settings page reach one place. The value carries `--autostart`, which is how the app knows a launch came
//! from sign-in and may start hidden.

use std::path::PathBuf;
use std::process::{Command, Stdio};

const KEY: &str = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run";
const NAME: &str = "Agent Hive";

pub fn executable() -> Option<PathBuf> {
    std::env::current_exe().ok()
}

/// Adds or removes the `Run` value. Returns whether it is set afterwards.
pub fn set(on: bool) -> Result<bool, String> {
    let executable = executable().ok_or("couldn't find this program's own path")?;
    let command = format!("\"{}\" --autostart", executable.display());

    let mut arguments: Vec<String> = Vec::new();
    if on {
        arguments.extend(["add".into(), KEY.into(), "/v".into(), NAME.into(), "/t".into(), "REG_SZ".into()]);
        arguments.extend(["/d".into(), command, "/f".into()]);
    } else {
        arguments.extend(["delete".into(), KEY.into(), "/v".into(), NAME.into(), "/f".into()]);
    }

    let output = Command::new("reg")
        .args(&arguments)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map_err(|error| error.to_string())?;

    // Deleting a value that was never there is not a failure for the caller.
    if !on {
        return Ok(false);
    }
    if !output.success() {
        return Err(format!("reg exited with {:?}", output.code()));
    }
    Ok(is_enabled())
}

/// Whether the `Run` value is present.
pub fn is_enabled() -> bool {
    let output = Command::new("reg")
        .args(["query", KEY, "/v", NAME])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output();
    match output {
        Ok(output) => output.status.success(),
        Err(_) => false,
    }
}
