//! The `hive-core.exe` child process.
//!
//! One JSON object per line goes in, one comes back (phase 2's protocol). Requests are concurrent and the
//! helper may answer them out of order, so each one waits on its own channel, keyed by the id the shell chose.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::Engine;
use serde_json::{json, Value};
use tokio::sync::oneshot;

#[cfg(windows)]
use std::os::windows::process::CommandExt;

/// No console window for the helper: it is a background program.
#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const LOG_LIMIT: u64 = 1024 * 1024;

pub struct Answer {
    pub status: u16,
    pub content_type: String,
    pub body: Vec<u8>,
}

impl Answer {
    /// An answer the shell makes up when the helper is unreachable, so the pages show their own "can't reach
    /// the data" state rather than hanging.
    pub fn error(status: u16, message: &str) -> Answer {
        Answer {
            status,
            content_type: "application/json; charset=utf-8".into(),
            body: json!({ "error": message }).to_string().into_bytes(),
        }
    }
}

struct Inner {
    stdin: Option<ChildStdin>,
    child: Option<Child>,
    pending: HashMap<u64, oneshot::Sender<Answer>>,
    next_id: u64,
}

#[derive(Clone)]
pub struct Helper {
    inner: Arc<Mutex<Inner>>,
}

impl Helper {
    pub fn new() -> Helper {
        Helper {
            inner: Arc::new(Mutex::new(Inner {
                stdin: None,
                child: None,
                pending: HashMap::new(),
                next_id: 0,
            })),
        }
    }

    /// Starts the helper if it isn't running. Called on the first request and after a crash.
    pub fn ensure_running(&self) -> Result<(), String> {
        let mut inner = self.inner.lock().unwrap();
        if let Some(child) = inner.child.as_mut() {
            match child.try_wait() {
                Ok(None) => return Ok(()),                    // still running
                Ok(Some(code)) => eprintln!("hive-core exited with {code}; restarting"),
                Err(error) => eprintln!("couldn't ask about hive-core: {error}"),
            }
        }
        let exe = resolve_helper()?;
        let mut command = Command::new(&exe);
        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .env("PATH", child_path(&exe));
        #[cfg(windows)]
        command.creation_flags(CREATE_NO_WINDOW);
        let mut child = command
            .spawn()
            .map_err(|error| format!("couldn't start {}: {error}", exe.display()))?;
        let stdin = child.stdin.take().ok_or("hive-core has no stdin")?;
        let stdout = child.stdout.take().ok_or("hive-core has no stdout")?;
        if let Some(stderr) = child.stderr.take() {
            spawn_log_reader(stderr);
        }
        inner.stdin = Some(stdin);
        inner.child = Some(child);
        drop(inner);
        let reader = self.clone();
        std::thread::spawn(move || reader.read_answers(stdout));
        Ok(())
    }

    /// Reads answers until the helper exits, then fails whatever was waiting.
    fn read_answers(&self, stdout: std::process::ChildStdout) {
        for line in BufReader::new(stdout).lines() {
            let Ok(line) = line else { break };
            let Ok(value) = serde_json::from_str::<Value>(&line) else {
                eprintln!("hive-core sent a line that isn't JSON");
                continue;
            };
            let id = value.get("id").and_then(Value::as_u64);
            let answer = Answer {
                status: value.get("status").and_then(Value::as_u64).unwrap_or(500) as u16,
                content_type: value
                    .get("contentType")
                    .and_then(Value::as_str)
                    .unwrap_or("application/json; charset=utf-8")
                    .to_string(),
                body: value
                    .get("body")
                    .and_then(Value::as_str)
                    .and_then(|text| base64::engine::general_purpose::STANDARD.decode(text).ok())
                    .unwrap_or_default(),
            };
            let waiter = id.and_then(|id| self.inner.lock().unwrap().pending.remove(&id));
            if let Some(waiter) = waiter {
                let _ = waiter.send(answer);
            }
        }
        // The helper is gone. Anything still waiting gets a 502 rather than a hang.
        let waiting: Vec<_> = self.inner.lock().unwrap().pending.drain().collect();
        for (_, waiter) in waiting {
            let _ = waiter.send(Answer::error(502, "hive-core stopped."));
        }
    }

    /// One request. `path` carries the query string, exactly as the page asked for it.
    pub async fn request(&self, method: &str, path: &str, body: Option<Vec<u8>>) -> Answer {
        if let Err(error) = self.ensure_running() {
            return Answer::error(502, &error);
        }

        let (id, receiver) = {
            let mut inner = self.inner.lock().unwrap();
            inner.next_id += 1;
            let id = inner.next_id;
            let (sender, receiver) = oneshot::channel();
            let mut line = json!({ "id": id, "method": method, "path": path });
            if let Some(body) = body {
                line["body"] = json!(base64::engine::general_purpose::STANDARD.encode(body));
            } else {
                line["body"] = Value::Null;
            }
            let wrote = match inner.stdin.as_mut() {
                Some(stdin) => writeln!(stdin, "{line}").and_then(|_| stdin.flush()).is_ok(),
                None => false,
            };
            if !wrote {
                return Answer::error(502, "hive-core's input pipe is closed.");
            }
            inner.pending.insert(id, sender);
            (id, receiver)
        };

        match tokio::time::timeout(REQUEST_TIMEOUT, receiver).await {
            Ok(Ok(answer)) => answer,
            Ok(Err(_)) => Answer::error(502, "hive-core stopped before answering."),
            Err(_) => {
                self.inner.lock().unwrap().pending.remove(&id);
                Answer::error(504, "hive-core didn't answer in 30 seconds.")
            }
        }
    }

    /// The helper's process id, so the shell can let it take the foreground when a page asks to open an app.
    pub fn pid(&self) -> Option<u32> {
        self.inner.lock().unwrap().child.as_ref().map(|child| child.id())
    }

    /// The close-the-shell path: ask politely by closing stdin, then end the process.
    pub fn stop(&self) {
        let mut inner = self.inner.lock().unwrap();
        inner.stdin = None; // dropping it closes the pipe, which makes the helper exit on its own
        if let Some(mut child) = inner.child.take() {
            std::thread::sleep(Duration::from_millis(200));
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

/// `hive-core`'s stderr, appended to `%APPDATA%\Agent Hive\logs\hive-core.log`, truncated at 1 MB.
fn spawn_log_reader(stderr: std::process::ChildStderr) {
    std::thread::spawn(move || {
        let path = log_path();
        if let Some(folder) = path.parent() {
            let _ = std::fs::create_dir_all(folder);
        }
        if std::fs::metadata(&path).map(|m| m.len() > LOG_LIMIT).unwrap_or(false) {
            let _ = std::fs::remove_file(&path);
        }
        for line in BufReader::new(stderr).lines().map_while(Result::ok) {
            if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
                let _ = writeln!(file, "{line}");
            }
        }
    });
}

fn log_path() -> PathBuf {
    let app_data = std::env::var_os("APPDATA").map(PathBuf::from).unwrap_or_default();
    app_data.join("Agent Hive").join("logs").join("hive-core.log")
}

/// Where `hive-core.exe` is: `HIVE_CORE`, then beside this executable (how the installer ships it), then the
/// Swift build this repository already has (how it runs from source).
fn resolve_helper() -> Result<PathBuf, String> {
    if let Some(path) = std::env::var_os("HIVE_CORE") {
        let path = PathBuf::from(path);
        if path.exists() {
            return Ok(path);
        }
    }
    if let Some(folder) = std::env::current_exe().ok().and_then(|exe| exe.parent().map(Path::to_path_buf)) {
        for name in ["hive-core.exe", "hive-core-x86_64-pc-windows-msvc.exe"] {
            let candidate = folder.join(name);
            if candidate.exists() {
                return Ok(candidate);
            }
        }
    }
    let repository = Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..");
    for profile in ["Debug", "Release", "debug", "release"] {
        let candidate = repository
            .join(".build")
            .join("out")
            .join("Products")
            .join(format!("{profile}-windows-x86_64"))
            .join("hive-core.exe");
        if candidate.exists() {
            return Ok(candidate);
        }
    }
    Err("hive-core.exe not found: build it with `swift build --product hive-core`, or set HIVE_CORE".into())
}

/// The `PATH` hive-core is started with.
///
/// hive-core is a Swift program and needs the Swift runtime DLLs. An installed app ships them beside the
/// executable, which is the first place looked at; a development build falls back to the toolchain installed on
/// this PC. Without this the child exits before reading a single request.
fn child_path(exe: &Path) -> std::ffi::OsString {
    let mut folders: Vec<PathBuf> = Vec::new();
    if let Some(folder) = exe.parent() {
        folders.push(folder.to_path_buf());
    }
    for root in ["LOCALAPPDATA", "ProgramFiles", "ProgramFiles(x86)"] {
        let Some(base) = std::env::var_os(root).map(PathBuf::from) else { continue };
        let runtimes = base.join("Programs/Swift").join("Runtimes");
        let runtimes = if runtimes.exists() { runtimes } else { base.join("Swift").join("Runtimes") };
        let mut versions: Vec<PathBuf> = std::fs::read_dir(&runtimes)
            .map(|entries| entries.filter_map(|entry| entry.ok().map(|e| e.path())).collect())
            .unwrap_or_default();
        versions.sort();
        if let Some(newest) = versions.last() {
            let bin = newest.join("usr").join("bin");
            if bin.exists() {
                folders.push(bin);
            }
        }
    }
    if let Some(existing) = std::env::var_os("PATH") {
        folders.extend(std::env::split_paths(&existing));
    }
    std::env::join_paths(folders).unwrap_or_else(|_| std::env::var_os("PATH").unwrap_or_default())
}
