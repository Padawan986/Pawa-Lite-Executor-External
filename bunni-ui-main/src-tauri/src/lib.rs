use serde::Deserialize;
use tauri::{AppHandle, Manager, State, Emitter};
use std::collections::HashMap;

use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH, Duration};
use tokio::net::{TcpListener, TcpStream};
use tokio_tungstenite::{accept_async, tungstenite::Message};
use serde_json::{json, Value};
use uuid::Uuid;
use tokio::sync::{mpsc, RwLock};
use futures_util::{SinkExt, StreamExt};
use std::sync::atomic::{AtomicU64, Ordering};
use std::fs;
use std::path::PathBuf;

type ClientId = String;
type ClientSender = mpsc::UnboundedSender<Message>;
type ClientMap = Arc<RwLock<HashMap<ClientId, ClientSender>>>;

struct WebSocketState {
    clients: ClientMap,
    app_handle: Option<AppHandle>,
}

static PING_COUNTER: AtomicU64 = AtomicU64::new(0);

fn get_path() -> Result<PathBuf, String> {
    
    let home_dir = std::env::var("HOME")
        .or_else(|_| std::env::var("USERPROFILE"))
        .map_err(|_| {
            println!("DEBUG: Could not find home directory");
            "Could not find home directory"
        })?;


    let cache_dir = PathBuf::from(home_dir).join("Library/Caches/PawaLiteBetaV2");
    
    // Create directory if it doesn't exist
    if let Err(e) = fs::create_dir_all(&cache_dir) {
        return Err(format!("Failed to create cache directory: {}", e));
    }
    
    let file_path = cache_dir.join("dont_touch_this.lua");
    
    Ok(file_path)
}

async fn handle_connection(stream: TcpStream, clients: ClientMap, app_handle: Option<AppHandle>) {
    let websocket = match accept_async(stream).await {
        Ok(ws) => ws,
        Err(_) => return,
    };

    let client_id = generate_client_id();
    let (tx, mut rx) = mpsc::unbounded_channel();
    
    {
        let mut clients_lock = clients.write().await;
        clients_lock.insert(client_id.clone(), tx);
    }

    let (mut ws_sender, mut ws_receiver) = websocket.split();
    let clients_for_handler = clients.clone();
    let client_id_for_handler = client_id.clone();
    let app_handle_for_handler = app_handle.clone();

    let sender_task = tokio::spawn(async move {
        while let Some(message) = rx.recv().await {
            if ws_sender.send(message).await.is_err() {
                break;
            }
        }
    });

    let receiver_task = tokio::spawn(async move {
        while let Some(message) = ws_receiver.next().await {
            match message {
                Ok(Message::Text(text)) => {
                    //println!("ud btw");
                    if let Some(ref handle) = app_handle_for_handler {
                                       if let Ok(parsed) = serde_json::from_str::<Value>(&text) {
                            let log_type = parsed["log_type"].as_str().unwrap_or("info");
                            let message_content = parsed["message"].as_str().unwrap_or(&text);
                            let formatted = format!("{}_{}", log_type, message_content);
                            let _ = handle.emit("ws_message", formatted);
                        } else {
                            println!("{}", &text);
                            let _ = handle.emit("ws_message", &text);
                        }
                    }
                    
                    //if handle_message(&text, &client_id_for_handler, &clients_for_handler).await.is_err() {
                     //   break;
                    //}
                }
                Ok(Message::Close(_)) => break,
                Ok(Message::Ping(data)) => {
                    let clients_lock = clients_for_handler.read().await;
                    if let Some(sender) = clients_lock.get(&client_id_for_handler) {
                        let _ = sender.send(Message::Pong(data));
                    }
                }
                Err(_) => break,
                _ => {}
            }
        }
    });

    tokio::select! {
        _ = sender_task => {},
        _ = receiver_task => {},
    }

    {
        let mut clients_lock = clients.write().await;
        clients_lock.remove(&client_id);
    }
}

async fn handle_message(
    text: &str,
    sender_id: &str,
    clients: &ClientMap,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let message: Value = serde_json::from_str(text)?;
    
    match message["type"].as_str() {
        Some("ping") => {
            send_to_client(
                sender_id,
                &json!({
                    "type": "pong",
                    "timestamp": get_timestamp()
                }),
                clients,
            ).await;
        }
        Some("direct") => {
            if let Some(target) = message["target_client"].as_str() {
                send_to_client(
                    target,
                    &json!({
                        "type": "direct_message",
                        "from": sender_id,
                        "data": message["data"]
                    }),
                    clients,
                ).await;
            }
        }
        _ => {}
    }
    Ok(())
}

async fn send_to_client(client_id: &str, message: &Value, clients: &ClientMap) {
    let clients_lock = clients.read().await;
    if let Some(sender) = clients_lock.get(client_id) {
        let msg_text = message.to_string();
        let _ = sender.send(Message::Text(msg_text));
    }
}

#[tauri::command]
async fn broadcast_raw(message: &str, state: State<'_, WebSocketState>) -> Result<String, String> {
    let clients = &state.clients;
    let clients_lock = clients.read().await;
        
    if clients_lock.is_empty() {
        return Ok("No clients connected".to_string());
    }
        
    let message_text = Message::Text(message.to_string());
    let mut sent_count = 0;
        
    for sender in clients_lock.values() {
        if sender.send(message_text.clone()).is_ok() {
            sent_count += 1;
        }
    }
        
    Ok(format!("Broadcast queued for {} clients", sent_count))
}

fn generate_client_id() -> String {
    format!("client_{}", Uuid::new_v4().simple().to_string()[..8].to_string())
}

fn get_timestamp() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
}

async fn start_ping_interval(clients: ClientMap) {
    let mut interval = tokio::time::interval(Duration::from_secs(30));
    loop {
        interval.tick().await;
        let clients_lock = clients.read().await;
        let ping_data = PING_COUNTER.fetch_add(1, Ordering::Relaxed).to_le_bytes().to_vec();
        
        for sender in clients_lock.values() {
            let _ = sender.send(Message::Ping(ping_data.clone()));
        }
    }
}

#[derive(Deserialize)]
struct OutputTypes {
    error: bool,
    warn: bool,
    info: bool,
    output: bool,
}

#[tauri::command]
fn auth_key(_key: &str) -> bool {
    true
}

/// Locate a Python helper inside FunnyExecutor's `src/` dir.
///
/// `name` is e.g. `fapi_daemon.py`. Search order:
/// 1. `FUNNY_FAPI_DIR` env var + `name` (explicit override)
/// 2. `<exe-dir>/../../../../src/<name>` (bundled layout:
///    `FunnyExecutor/bunni-ui-main/src-tauri/target/<profile>/<exe>`
///    -> up to `FunnyExecutor`, then `src/<name>`)
/// 3. `<cwd>/../src/<name>` and `<cwd>/../../src/<name>`
///    (covers `tauri dev`, where cwd is `bunni-ui-main/src-tauri`)
///
/// The executor identifies as Pawa-Lite(Beta)V2 (see FAPI `identifyexecutor`).
fn fapi_file(name: &str) -> Result<std::path::PathBuf, String> {
    if let Ok(dir) = std::env::var("FUNNY_FAPI_DIR") {
        let p = std::path::PathBuf::from(dir).join(name);
        if p.is_file() {
            return Ok(p);
        }
        return Err(format!("FUNNY_FAPI_DIR has no {name}: {}", p.display()));
    }

    let mut candidates: Vec<std::path::PathBuf> = Vec::new();

    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            // Repo-root layout: exe next to src/ (e.g. Pawa-Lite(Beta)V2.exe).
            candidates.push(dir.join("src").join(name));
        }
        if let Some(root) = exe.ancestors().nth(4) {
            candidates.push(root.join("src").join(name));
        }
    }

    if let Ok(cwd) = std::env::current_dir() {
        candidates.push(cwd.join("src").join(name));
        candidates.push(cwd.join("..").join("src").join(name));
        candidates.push(cwd.join("..").join("..").join("src").join(name));
    }

    for c in &candidates {
        if c.is_file() {
            return Ok(c.clone());
        }
    }

    Err(format!(
        "{name} not found (tried: {}). Set FUNNY_FAPI_DIR env var.",
        candidates
            .iter()
            .map(|c| c.display().to_string())
            .collect::<Vec<_>>()
            .join(", ")
    ))
}

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command as TokioCommand};
use tokio::sync::Mutex as AsyncMutex;

/// A single persistent `python -u fapi_daemon.py` process.
///
/// It must stay alive: the injected game fetches every executed script back
/// from the daemon's HTTP bridge (127.0.0.1:9475). One-shot processes exit
/// before the game polls, which surfaces in-game as `-- request error`.
struct DaemonInner {
    child: Child,
    stdin: ChildStdin,
    next_id: u64,
}

struct DaemonReply {
    ok: bool,
    msg: String,
}

struct DaemonState {
    inner: AsyncMutex<Option<DaemonInner>>,
}

impl Default for DaemonState {
    fn default() -> Self {
        Self {
            inner: AsyncMutex::new(None),
        }
    }
}

/// Spawn the daemon. Caller must hold no lock.
async fn spawn_daemon(state: &State<'_, DaemonState>) -> Result<(), String> {
    let daemon = fapi_file("fapi_daemon.py")?;
    let workdir = daemon
        .parent()
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|| std::path::PathBuf::from("."));

    // NOTE: -X utf8 is required, not optional. The Windows locale encoding
    // (cp1252) cannot round-trip scripts containing e.g. emojis (UNC tests
    // are full of them): the daemon would die with UnicodeDecodeError on
    // stdin and take every later command down with it.
    // CREATE_NO_WINDOW: python.exe is a console-subsystem binary. Without
    // this flag Windows pops a visible cmd window for the daemon that stays
    // until the UI quits. (rconsole* still AllocConsoles its own window on
    // demand from inside the daemon when scripts actually use it.)
    const NO_WINDOW: u32 = 0x08000000;

    let mut cmd = TokioCommand::new("python");
    cmd.arg("-u")
        .arg("-X")
        .arg("utf8")
        .arg(&daemon)
        .current_dir(&workdir)
        .env("PYTHONUTF8", "1")
        .creation_flags(NO_WINDOW)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null());

    let mut child = cmd.spawn().or_else(|_| {
        let mut fallback = TokioCommand::new("py");
        fallback
            .arg("-u")
            .arg("-X")
            .arg("utf8")
            .arg(&daemon)
            .current_dir(&workdir)
            .env("PYTHONUTF8", "1")
            .creation_flags(NO_WINDOW)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null());
        fallback.spawn()
    }).map_err(|e| format!("could not launch python (tried `python` and `py`): {e}"))?;

    let stdin = child
        .stdin
        .take()
        .ok_or_else(|| "daemon stdin unavailable".to_string())?;

    {
        let mut guard = state.inner.lock().await;
        *guard = Some(DaemonInner {
            child,
            stdin,
            next_id: 0,
        });
    }

    Ok(())
}

/// Send one command to the daemon and wait for its reply.
///
/// The reader is (re)installed per call: at most one call is in flight per
/// command, but concurrent Tauri commands are serialized through the stdin
/// lock, and replies are matched by id.
async fn daemon_call(
    state: &State<'_, DaemonState>,
    cmd: &str,
    script: Option<&str>,
    timeout_secs: u64,
) -> Result<DaemonReply, String> {
    // Ensure a live daemon.
    let needs_spawn = {
        let guard = state.inner.lock().await;
        match guard.as_ref() {
            Some(inner) => match inner.child.id() {
                Some(_) => false,
                None => true,
            },
            None => true,
        }
    };
    if needs_spawn {
        spawn_daemon(state).await?;
    }

    // Install a one-shot reader for this call. We take a fresh BufReader
    // over a duplicate read handle is impossible on pipes, so instead the
    // single reader task owns stdout. Simpler correct approach for our low
    // concurrency: hold the mutex for the whole round-trip.
    let mut guard = state.inner.lock().await;
    let inner = guard.as_mut().ok_or_else(|| "daemon failed to start".to_string())?;

    if inner.child.try_wait().map_err(|e| format!("daemon wait failed: {e}"))?.is_some() {
        *guard = None;
        return Err("python daemon died; retry the command".to_string());
    }

    inner.next_id += 1;
    let id = inner.next_id;
    let mut payload = serde_json::json!({"id": id, "cmd": cmd});
    if let Some(s) = script {
        payload["script"] = serde_json::Value::String(s.to_string());
    }
    let line = payload.to_string() + "\n";

    // Take stdout temporarily so we can read exactly our reply while
    // holding the lock (serializes concurrent commands).
    // NOTE: stdout was moved into the reader model below; to keep this
    // implementation single-task we read here via a short-lived reader.
    // We stored stdout in the child; take it out for this round-trip.
    let stdout = inner
        .child
        .stdout
        .take()
        .ok_or_else(|| "daemon stdout unavailable".to_string())?;
    let mut reader = BufReader::new(stdout);

    inner
        .stdin
        .write_all(line.as_bytes())
        .await
        .map_err(|e| format!("daemon write failed: {e}"))?;
    inner
        .stdin
        .flush()
        .await
        .map_err(|e| format!("daemon flush failed: {e}"))?;

    let mut raw = String::new();
    let reply: DaemonReply = tokio::time::timeout(
        std::time::Duration::from_secs(timeout_secs),
        async {
            loop {
                raw.clear();
                let n = reader.read_line(&mut raw).await.map_err(|e| format!("daemon read failed: {e}"))?;
                if n == 0 {
                    return Err("python daemon closed stdout".to_string());
                }
                let trimmed = raw.trim();
                if !trimmed.starts_with('{') {
                    continue;
                }
                let v: serde_json::Value =
                    serde_json::from_str(trimmed).map_err(|e| format!("bad daemon reply: {e}"))?;
                if v.get("id").and_then(|i| i.as_u64()) != Some(id) {
                    continue;
                }
                return Ok(DaemonReply {
                    ok: v.get("ok").and_then(|o| o.as_bool()).unwrap_or(false),
                    msg: v
                        .get("msg")
                        .and_then(|m| m.as_str())
                        .unwrap_or("")
                        .to_string(),
                });
            }
        },
    )
    .await
    .map_err(|_| format!("daemon timeout after {timeout_secs}s"))??;

    // Hand stdout back to the child for the next call.
    inner.child.stdout = Some(reader.into_inner());
    Ok(reply)
}

#[tauri::command]
async fn attach(state: State<'_, DaemonState>) -> Result<bool, String> {
    // FunnyExecutor injects into the running Windows Roblox client via FAPI.
    // The daemon stays alive so the in-game bridge keeps working.
    match daemon_call(&state, "attach", None, 180).await {
        Ok(reply) => {
            println!("attach: {}", reply.msg);
            if reply.ok {
                Ok(true)
            } else {
                Err(reply.msg)
            }
        }
        Err(e) => Err(e),
    }
}

#[tauri::command]
async fn execute(state: State<'_, DaemonState>, script: &str) -> Result<String, String> {
    if script.trim().is_empty() {
        return Err("empty script".to_string());
    }
    match daemon_call(&state, "execute", Some(script), 90).await {
        Ok(reply) => {
            if reply.ok {
                Ok(reply.msg)
            } else {
                Err(reply.msg)
            }
        }
        Err(e) => Err(e),
    }
}

#[tauri::command]
async fn set_autoinject(state: State<'_, DaemonState>, value: bool) -> Result<(), String> {
    let flag = if value { "true" } else { "false" };
    match daemon_call(&state, "set_autoinject", Some(flag), 10).await {
        Ok(reply) => {
            if reply.ok {
                Ok(())
            } else {
                Err(reply.msg)
            }
        }
        Err(e) => Err(e),
    }
}

#[tauri::command]
fn set_hotkey(_value: &str) -> Result<(), String> {
    Ok(())
}

#[tauri::command]
fn set_topmost(handle: AppHandle, value: bool) -> Result<(), String> {
    let window = handle.get_webview_window("main").ok_or("failed to get window").unwrap();
    window.set_always_on_top(value).map_err(|e| format!("failed topmost setter: {}", e))?;
    Ok(())
}

#[tauri::command]
fn set_redirect(_value: bool) -> Result<(), String> {
    Ok(())
}

#[tauri::command]
fn set_outputtypes(_value: OutputTypes) -> Result<(), String> {
    Ok(())
}

#[tauri::command]
fn on_keybind_set(_keybind: &str) -> Result<(), String> {
    Ok(())
}

/// First-run bootstrap so the installed app fetches everything itself:
/// Python (via winget), pip deps, and Defender exclusions (one UAC prompt).
/// Idempotent: a healthy system passes through in seconds.
#[tauri::command]
async fn setup_runtime(app: AppHandle) -> Result<String, String> {
    let say = move |m: String| {
        let _ = app.emit("ws_message", format!("info_{m}"));
    };
    tauri::async_runtime::spawn_blocking(move || setup_runtime_blocking(say))
        .await
        .map_err(|e| format!("setup task failed: {e}"))?
}

fn setup_marker_path() -> Option<std::path::PathBuf> {
    std::env::var("APPDATA")
        .ok()
        .map(|a| std::path::PathBuf::from(a).join("Pawa-Lite-BetaV2").join("setup.done"))
}

/// Hidden check whether all dirs are already Defender-excluded.
/// Never shows a window (NO_WINDOW) and never prompts.
fn exclusions_covered(dirs: &[String]) -> bool {
    use std::os::windows::process::CommandExt;
    const NO_WINDOW: u32 = 0x08000000;
    let out = std::process::Command::new("powershell")
        .args(["-NoProfile", "-Command", "(Get-MpPreference).ExclusionPath"])
        .creation_flags(NO_WINDOW)
        .output();
    let text = match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).to_lowercase(),
        _ => return false,
    };
    dirs.iter().all(|d| {
        let norm = d.to_lowercase().replace('/', "\\");
        let trimmed = norm.trim_end_matches('\\');
        text.contains(trimmed)
    })
}

fn setup_runtime_blocking(say: impl Fn(String)) -> Result<String, String> {
    use std::process::Command as StdCommand;

    // Fast path: first-run marker exists -> verify python silently, no windows.
    if let Some(marker) = setup_marker_path() {
        if marker.is_file() {
            let py_ok = ["python", "py"].iter().any(|cand| {
                StdCommand::new(cand)
                    .arg("--version")
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .status()
                    .map(|s| s.success())
                    .unwrap_or(false)
            });
            if py_ok {
                return Ok("Setup ready.".to_string());
            }
            // Marker stale (python removed) -> fall through to full flow.
            let _ = std::fs::remove_file(&marker);
        }
    }

    say("Setup: checking Python...".to_string());
    let mut py: Option<String> = None;
    for cand in ["python", "py"] {
        if StdCommand::new(cand)
            .arg("--version")
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
        {
            py = Some(cand.to_string());
            break;
        }
    }

    if py.is_none() {
        say("Setup: installing Python via winget (takes a bit)...".to_string());
        let _ = StdCommand::new("winget")
            .args([
                "install", "-e", "--id", "Python.Python.3.14", "--silent",
                "--accept-package-agreements", "--accept-source-agreements",
            ])
            .status();
        for cand in ["python", "py"] {
            if StdCommand::new(cand)
                .arg("--version")
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status()
                .map(|s| s.success())
                .unwrap_or(false)
            {
                py = Some(cand.to_string());
                break;
            }
        }
        // Fall back to well-known install locations (fresh PATH).
        if py.is_none() {
            if let Ok(local) = std::env::var("LOCALAPPDATA") {
                for entry in std::fs::read_dir(format!("{local}\\Programs\\Python")).into_iter().flatten().flatten() {
                    let p = entry.path().join("python.exe");
                    if p.is_file() {
                        py = Some(p.to_string_lossy().to_string());
                        break;
                    }
                }
            }
        }
    }

    let py = py.ok_or_else(|| {
        "No Python found and winget install failed. Install manually: https://www.python.org/downloads/".to_string()
    })?;
    say(format!("Setup: Python ok ({py})"));

    // pip deps (only the missing ones).
    let deps: &[(&str, &str)] = &[
        ("pymem", "pymem"),
        ("pywin32", "win32gui"),
        ("pydirectinput", "pydirectinput"),
        ("requests", "requests"),
        ("pyperclip", "pyperclip"),
        ("psutil", "psutil"),
        ("zstandard", "zstandard"),
        ("websocket-client", "websocket"),
    ];
    let mut missing: Vec<&str> = Vec::new();
    for (_, module) in deps {
        let ok = StdCommand::new(&py)
            .args(["-c", &format!("import {module}")])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if !ok {
            missing.push(deps.iter().find(|(_, m)| m == module).unwrap().0);
        }
    }
    if !missing.is_empty() {
        say(format!("Setup: installing pip packages: {}...", missing.join(", ")));
        let st = StdCommand::new(&py)
            .arg("-m")
            .arg("pip")
            .arg("install")
            .args(&missing)
            .status()
            .map_err(|e| format!("pip failed to start: {e}"))?;
        if !st.success() {
            return Err("pip install failed; run Install-PawaLite.ps1 or install deps manually".to_string());
        }
    }
    say("Setup: Python dependencies ok".to_string());

    // Defender exclusions need admin -> exactly one UAC prompt.
    let mut dirs: Vec<String> = Vec::new();
    if let Ok(exe) = std::env::current_exe() {
        if let Some(d) = exe.parent() {
            dirs.push(d.to_string_lossy().to_string());
        }
    }
    if let Ok(appdata) = std::env::var("APPDATA") {
        dirs.push(format!("{appdata}\\Pawa-Lite-BetaV2"));
    }
    if let Ok(fapi) = std::env::var("FUNNY_FAPI_DIR") {
        dirs.push(fapi);
    }
    for d in &dirs {
        let _ = std::fs::create_dir_all(d);
    }
    if exclusions_covered(&dirs) {
        say("Setup: Defender exclusions already set".to_string());
    } else {
        let ps_lines: Vec<String> = dirs
            .iter()
            .map(|d| format!("Add-MpPreference -ExclusionPath '{}'", d.replace('\'', "''")))
            .collect();
        let tmp = std::env::temp_dir().join("pawa_defender_excl.ps1");
        if std::fs::write(&tmp, ps_lines.join("\r\n")).is_ok() {
            say("Setup: requesting Defender exclusion (one UAC prompt)...".to_string());
            let st = StdCommand::new("powershell")
                .args([
                    "-NoProfile",
                    "-Command",
                    &format!(
                        "Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"{}\"' -Verb RunAs -Wait",
                        tmp.to_string_lossy().replace('\'', "''")
                    ),
                ])
                .status();
            match st {
                Ok(s) if s.success() => say("Setup: Defender exclusions set".to_string()),
                _ => say("Setup: Defender step skipped/denied (app still works)".to_string()),
            }
            let _ = std::fs::remove_file(&tmp);
        }
    }

    if let Some(marker) = setup_marker_path() {
        if let Some(parent) = marker.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = std::fs::write(&marker, "1");
    }

    Ok("Setup complete: Python + deps + Defender exclusions ready.".to_string())
}

/// ScriptBlox provider search (no key needed; RScripts needs one, skipped).
#[derive(serde::Serialize, Clone)]
struct HubScript {
    title: String,
    game: String,
    keyless: bool,
    verified: bool,
    likes: i64,
    code: String,
}

fn url_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'0'..=b'9' | b'a'..=b'z' | b'A'..=b'Z' | b'-' | b'_' | b'.' | b'~' => out.push(b as char),
            b' ' => out.push('+'),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

#[tauri::command]
async fn hub_search(query: String) -> Result<Vec<HubScript>, String> {
    let q = query.trim();
    if q.len() < 2 {
        return Err("type at least 2 characters".to_string());
    }
    let url = format!(
        "https://scriptblox.com/api/script/search?q={}&max=20",
        url_encode(q)
    );
    let out = TokioCommand::new("curl.exe")
        .args(["-sS", "-m", "25", "--compressed", &url])
        .creation_flags(0x08000000)
        .output()
        .await
        .map_err(|e| format!("search request failed: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "search failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    let v: Value =
        serde_json::from_slice(&out.stdout).map_err(|e| format!("bad search response: {e}"))?;
    let mut hits = Vec::new();
    if let Some(arr) = v.pointer("/result/scripts").and_then(|a| a.as_array()) {
        for s in arr {
            let code = s.get("script").and_then(|c| c.as_str()).unwrap_or("").trim().to_string();
            if code.is_empty() {
                continue;
            }
            let game = s
                .pointer("/game/name")
                .and_then(|g| g.as_str())
                .unwrap_or("")
                .to_string();
            let game = if s.get("isUniversal").and_then(|u| u.as_bool()).unwrap_or(false) || game.is_empty() {
                "Universal".to_string()
            } else {
                game
            };
            hits.push(HubScript {
                title: s.get("title").and_then(|t| t.as_str()).unwrap_or("Untitled").to_string(),
                game,
                keyless: s.get("keyless").and_then(|k| k.as_bool()).unwrap_or(false),
                verified: s.get("verified").and_then(|k| k.as_bool()).unwrap_or(false),
                likes: s.get("likeCount").and_then(|l| l.as_i64()).unwrap_or(0),
                code,
            });
        }
    }
    Ok(hits)
}

/// Version/update check against the release repo (runs the daemon's
/// background-fetched state on demand). Reports e.g. "up to date" or
/// "updated inject payload to ... (active on next inject)".
#[tauri::command]
async fn check_updates(state: State<'_, DaemonState>) -> Result<String, String> {
    match daemon_call(&state, "update", None, 90).await {
        Ok(reply) => {
            if reply.ok {
                Ok(reply.msg)
            } else {
                Err(reply.msg)
            }
        }
        Err(e) => Err(e),
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tokio::runtime::Runtime::new().unwrap().block_on(async {
    tauri::Builder::default()
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            // Second launch focuses the running window instead of starting
            // a rival daemon that would fight over port 9475.
            if let Some(w) = app.get_webview_window("main") {
                let _ = w.show();
                let _ = w.unminimize();
                let _ = w.set_focus();
            }
        }))
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .invoke_handler(tauri::generate_handler![auth_key, attach, execute, setup_runtime, check_updates, hub_search, set_autoinject, set_topmost, broadcast_raw, set_hotkey, set_redirect, set_outputtypes, on_keybind_set])
        .setup(|app| {
            let app_handle = app.handle().clone();
            let clients: ClientMap = Arc::new(RwLock::new(HashMap::new()));
            
            app.manage(WebSocketState {
                clients: clients.clone(),
                app_handle: Some(app_handle.clone()),
            });
            app.manage(DaemonState::default());
            // Point the FAPI lookup at the bundled resources dir, so the
            // installed app finds fapi_daemon.py next to itself instead of
            // relying on dev-tree relative paths. fapi_file() prefers this.
            if let Ok(res_dir) = app_handle.path().resource_dir() {
                let fapi_dir = res_dir.join("fapi");
                if fapi_dir.join("fapi_daemon.py").is_file() {
                    std::env::set_var("FUNNY_FAPI_DIR", &fapi_dir);
                }
            }
            
            let ping_clients = clients.clone();
            let rt = tokio::runtime::Runtime::new().unwrap();
            
            std::thread::spawn(move || {
                rt.block_on(async {
                    tokio::spawn(async move {
                        start_ping_interval(ping_clients).await;
                    });
                    
                    let addr = "127.0.0.1:5000";
                    let listener = match TcpListener::bind(&addr).await {
                        Ok(l) => l,
                        Err(_) => return,
                    };
                    
                    while let Ok((stream, _)) = listener.accept().await {
                        let clients_clone = clients.clone();
                        let handle_clone = Some(app_handle.clone());
                        tokio::spawn(async move {
                            handle_connection(stream, clients_clone, handle_clone).await;
                        });
                    }
                });
            });
  
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
    });
}