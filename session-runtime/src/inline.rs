//! A terminal-byte viewer for a managed remote PTY inside an existing local PTY.
//! The viewer owns no AppKit window and never replaces its calling local shell.

use crate::{Frame, Vt};
use base64::Engine;
use serde::Deserialize;
use serde_json::Value;
use std::{
    ffi::c_void,
    fs::File,
    io::{self, Read, Write},
    mem::ManuallyDrop,
    net::Shutdown,
    os::fd::{AsRawFd, FromRawFd},
    os::unix::net::UnixStream,
    path::Path,
    sync::{
        atomic::{AtomicI32, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};

static INTERRUPTED: AtomicI32 = AtomicI32::new(0);
static WAKE: AtomicI32 = AtomicI32::new(-1);
extern "C" fn interrupted(signal: i32) {
    if signal != libc::SIGWINCH {
        INTERRUPTED.store(signal, Ordering::Relaxed);
    }
    let fd = WAKE.load(Ordering::Relaxed);
    if fd >= 0 {
        unsafe {
            libc::write(fd, [1u8].as_ptr().cast(), 1);
        }
    }
}

struct Signals(Vec<(i32, libc::sighandler_t)>);
impl Signals {
    fn install(wake: i32) -> Self {
        INTERRUPTED.store(0, Ordering::Relaxed);
        WAKE.store(wake, Ordering::Relaxed);
        Self(
            [libc::SIGINT, libc::SIGTERM, libc::SIGHUP, libc::SIGWINCH]
                .into_iter()
                .map(|signal| {
                    (signal, unsafe {
                        libc::signal(signal, interrupted as *const () as libc::sighandler_t)
                    })
                })
                .collect(),
        )
    }
}
impl Drop for Signals {
    fn drop(&mut self) {
        WAKE.store(-1, Ordering::Relaxed);
        for &(signal, previous) in &self.0 {
            unsafe {
                libc::signal(signal, previous);
            }
        }
    }
}

struct RawMode(libc::termios);
impl RawMode {
    fn enter() -> io::Result<Self> {
        let mut original = unsafe { std::mem::zeroed() };
        if unsafe { libc::tcgetattr(0, &mut original) } != 0 {
            return Err(io::Error::last_os_error());
        }
        let mut raw = original;
        unsafe {
            libc::cfmakeraw(&mut raw);
        }
        if unsafe { libc::tcsetattr(0, libc::TCSAFLUSH, &raw) } != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self(original))
    }
}
impl Drop for RawMode {
    fn drop(&mut self) {
        unsafe {
            libc::tcsetattr(0, libc::TCSAFLUSH, &self.0);
        }
    }
}

fn dimensions() -> [u8; 8] {
    let mut size: libc::winsize = unsafe { std::mem::zeroed() };
    unsafe {
        libc::ioctl(0, libc::TIOCGWINSZ, &mut size);
    }
    let cols = size.ws_col.clamp(1, 500);
    let rows = size.ws_row.clamp(1, 300);
    let mut bytes = [0; 8];
    bytes[..2].copy_from_slice(&cols.to_be_bytes());
    bytes[2..4].copy_from_slice(&rows.to_be_bytes());
    bytes[4..6].copy_from_slice(&size.ws_xpixel.min(16_000).to_be_bytes());
    bytes[6..].copy_from_slice(&size.ws_ypixel.min(16_000).to_be_bytes());
    bytes
}

fn encoded(value: &str) -> String {
    value
        .bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() || b"-_./~".contains(&b) {
                char::from(b).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect()
}

#[derive(Deserialize)]
pub struct Context {
    pub connection_id: String,
    pub target: String,
    pub local_cwd: String,
    #[serde(default)]
    pub active_record: Option<std::path::PathBuf>,
    #[serde(default)]
    pub owner_record: Option<std::path::PathBuf>,
}

fn persist_record(session: &Context, fields: &[(&str, Value)]) -> io::Result<()> {
    use std::os::unix::fs::OpenOptionsExt;
    let Some(path) = &session.active_record else {
        return Ok(());
    };
    let mut value: Value = serde_json::from_slice(&crate::handoff::read_private(path)?)?;
    if value["connectionID"] != session.connection_id
        || fields.iter().all(|(key, next)| value[*key] == *next)
    {
        return Ok(());
    }
    for (key, next) in fields {
        value[*key] = next.clone();
    }
    let temporary = path.with_extension(format!("{}.tmp", crate::record::nonce()?));
    let result = (|| {
        let mut file = std::fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(&temporary)?;
        file.write_all(&serde_json::to_vec(&value)?)?;
        file.sync_all()?;
        std::fs::rename(&temporary, path)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(temporary);
    }
    result
}

pub(crate) fn forget_context(session: &Context) {
    for path in [&session.active_record, &session.owner_record]
        .into_iter()
        .flatten()
    {
        if let Ok(bytes) = crate::handoff::read_private(path) {
            if let Ok(value) = serde_json::from_slice::<Value>(&bytes) {
                if value["connectionID"] == session.connection_id {
                    let _ = std::fs::remove_file(path);
                }
            }
        }
    }
}

pub(crate) fn end_context(session: &Context, status: i32) {
    let _ = io::stdout().write_all(&context(session, None, Some(status)));
    let _ = io::stdout().flush();
}

fn context(context: &Context, cwd: Option<&str>, status: Option<i32>) -> Vec<u8> {
    if let Some(status) = status {
        format!(
            "\x1b]3008;end={};status={status};cwd={}\x07",
            context.connection_id,
            encoded(&context.local_cwd)
        )
        .into_bytes()
    } else {
        format!(
            "\x1b]3008;start={};type=remote;targethost={};localcwd={}{}\x07",
            context.connection_id,
            context.target,
            encoded(&context.local_cwd),
            cwd.map(|s| format!(";cwd={}", encoded(s)))
                .unwrap_or_default()
        )
        .into_bytes()
    }
}

// Adapted from herdr-core's attach RESET. Reset both screens' input modes
// before the original local shell regains its terminal.
const RESET: &[u8] = b"\x18\x1b[?2026l\x1b[?1049h\x1b[=0;1u\x1b[?1049l\x1b[?1047l\x1b[?47l\x1b[=0;1u\x1b[>4;0m\
\x1b7\x1b[4l\x1b[20l\x1b[?1l\x1b[?5l\x1b[?6l\x1b[?66l\x1b[?67l\x1b[?69l\x1b[?9l\x1b[?1000l\x1b[?1001l\x1b[?1002l\
\x1b[?1003l\x1b[?1004l\x1b[?1005l\x1b[?1006l\x1b[?1015l\x1b[?1016l\x1b[?2004l\x1b[?2031l\x1b[?2033l\
\x1b[?2048l\x1b[?7h\x1b[?25h\x1b[?1007h\x1b[r\x1b8\x1b[0 q\x1b(B\x1b[0m\
\x1b]104\x1b\\\x1b]110\x1b\\\x1b]111\x1b\\\x1b]112\x1b\\\x1b]22;\x1b\\\r\n";

/// The local PTY (not the GUI) owns this blocking viewer. Transport reconnects
/// retain its socket and discard input until the new writer generation is ready.
fn enrich_open_request(open: &mut Value) {
    let Some(obj) = open.as_object_mut() else {
        return;
    };
    let spawns = obj.get("create").and_then(Value::as_bool) == Some(true)
        || obj.get("recreate_if_gone").and_then(Value::as_bool) == Some(true);
    if !spawns {
        return;
    }
    let size = dimensions();
    let cols = u16::from_be_bytes([size[0], size[1]]);
    let rows = u16::from_be_bytes([size[2], size[3]]);
    let pixel_width = u16::from_be_bytes([size[4], size[5]]);
    let pixel_height = u16::from_be_bytes([size[6], size[7]]);
    obj.entry("cols").or_insert_with(|| Value::from(cols));
    obj.entry("rows").or_insert_with(|| Value::from(rows));
    if pixel_width > 0 {
        obj.entry("pixel_width")
            .or_insert_with(|| Value::from(pixel_width));
    }
    if pixel_height > 0 {
        obj.entry("pixel_height")
            .or_insert_with(|| Value::from(pixel_height));
    }
    for (env_key, json_key) in [
        ("TERM", "term"),
        ("COLORTERM", "colorterm"),
        ("TERM_PROGRAM", "term_program"),
        ("TERM_PROGRAM_VERSION", "term_program_version"),
    ] {
        if !obj.contains_key(json_key) {
            if let Ok(val) = std::env::var(env_key) {
                let trimmed = val.trim();
                if !trimmed.is_empty() && trimmed.len() <= 128 && trimmed != "dumb" {
                    obj.insert(json_key.into(), Value::String(trimmed.to_owned()));
                }
            }
        }
    }
}

pub fn view(path: &Path, mut open: Value, session: &Context) -> io::Result<i32> {
    enrich_open_request(&mut open);
    let (mut wake_read, mut wake_write) = UnixStream::pair()?;
    wake_read.set_nonblocking(true)?;
    wake_write.set_nonblocking(true)?;
    let signal_wake = wake_write.try_clone()?;
    let _signals = Signals::install(signal_wake.as_raw_fd());
    let mut socket = UnixStream::connect(path)?;
    socket.set_write_timeout(Some(Duration::from_secs(2)))?;
    Frame::new(b'H', 0, serde_json::to_vec(&open)?.as_slice()).send(&mut socket)?;
    let mut reader = socket.try_clone()?;
    let (tx, rx) = mpsc::sync_channel(2);
    let worker = std::thread::spawn(move || loop {
        let result = Frame::read(&mut reader);
        let done = result.is_err();
        if tx.send(result).is_err() {
            break;
        }
        let _ = wake_write.write(&[1]);
        if done {
            break;
        }
    });
    let result = view_loop(&mut socket, &rx, &mut wake_read, session);
    let _ = socket.shutdown(Shutdown::Both);
    drop(rx);
    let _ = worker.join();
    let mut stdout = io::stdout().lock();
    let _ = stdout.write_all(RESET);
    let _ = stdout.write_all(&context(
        session,
        None,
        Some(result.as_ref().copied().unwrap_or(255)),
    ));
    let _ = stdout.flush();
    result
}

fn view_loop(
    socket: &mut UnixStream,
    rx: &mpsc::Receiver<io::Result<Frame>>,
    wake: &mut UnixStream,
    session: &Context,
) -> io::Result<i32> {
    let mut generation = 0;
    let mut sequence = None;
    let mut ready = false;
    let mut writer = false;
    let mut raw = None;
    let mut first_picture = true;
    let mut preserved_local_prefix = false;
    let mut initial_output = None;
    let mut password_input = false;
    let mut pending_password = None;
    let mut pending_cwd = None;
    let mut pending_output = Vec::new();
    let mut out_buf: Vec<u8> = Vec::new();
    let mut sync_hold_started: Option<Instant> = None;
    let mut pending_activity: Option<&'static str> = None;
    let mut activity_hydrated = false;
    let mut size = dimensions();
    let mut screen = Screen::new(
        u16::from_be_bytes([size[0], size[1]]),
        u16::from_be_bytes([size[2], size[3]]),
    )?;
    {
        let mut stdout = io::stdout().lock();
        stdout.write_all(&context(session, None, None))?;
        stdout.flush()?;
    }
    let mut raw_stdout = ManuallyDrop::new(unsafe { File::from_raw_fd(libc::STDOUT_FILENO) });
    loop {
        let signal = INTERRUPTED.load(Ordering::Relaxed);
        if signal != 0 {
            let _ = flush_out_buf(&mut *raw_stdout, &mut out_buf);
            return Ok(128 + signal);
        }
        let mut drained_frames = 0usize;
        for _ in 0..32 {
            let frame = match rx.try_recv() {
                Ok(frame) => {
                    drained_frames += 1;
                    frame?
                }
                Err(mpsc::TryRecvError::Empty) => break,
                Err(mpsc::TryRecvError::Disconnected) => {
                    let _ = flush_out_buf(&mut *raw_stdout, &mut out_buf);
                    return Err(io::ErrorKind::UnexpectedEof.into());
                }
            };
            match frame.kind {
                b'T' => {
                    let status: Value = serde_json::from_slice(&frame.data)?;
                    flush_out_buf(&mut *raw_stdout, &mut out_buf)?;
                    sync_hold_started = None;
                    generation = frame.seq;
                    ready = false;
                    writer = false;
                    sequence = None;
                    pending_password = Some(false);
                    pending_output.clear();
                    persist_record(
                        session,
                        &[
                            ("phase", status["state"].clone()),
                            ("attachmentGeneration", Value::from(generation)),
                            ("passwordInput", Value::Bool(false)),
                        ],
                    )?;
                    if status["state"] == "attention" {
                        return Err(io::Error::other(
                            status["message"]
                                .as_str()
                                .unwrap_or("SSH connection needs attention"),
                        ));
                    }
                }
                b'J' => {
                    let info: Value = serde_json::from_slice(&frame.data)?;
                    if info["inline_viewer"] != true {
                        return Err(io::Error::other(
                            "host did not enable inline terminal replies",
                        ));
                    }
                    initial_output = info["initial_output"]
                        .as_str()
                        .filter(|s| s.len() <= 12 * 1024)
                        .and_then(|s| base64::engine::general_purpose::STANDARD.decode(s).ok());
                }
                b'S' => {
                    let had_first_picture = first_picture;
                    if had_first_picture && initial_output.is_some() {
                        screen = Screen::new(
                            u16::from_be_bytes([size[0], size[1]]),
                            u16::from_be_bytes([size[2], size[3]]),
                        )?;
                        pending_output = initial_output.take().unwrap();
                        screen.write(&pending_output);
                    } else {
                        screen.restore(&frame.data)?;
                        let (_, alt_screen, cursor_visible, mouse_active) = screen.ui_modes();
                        let preserve_rows = if !had_first_picture
                            && !preserved_local_prefix
                            && !alt_screen
                            && cursor_visible
                            && !mouse_active
                        {
                            preserved_local_prefix = true;
                            let current = dimensions();
                            Some(u16::from_be_bytes([current[2], current[3]]))
                        } else {
                            None
                        };
                        pending_output = screen.repaint(preserve_rows)?;
                        pending_output.extend(screen.continuation()?);
                    }
                    screen.take_responses();
                    first_picture = false;
                    ready = false;
                    writer = false;
                    activity_hydrated = false;
                    pending_activity = None;
                    sequence = Some(frame.seq);
                    Frame::new(b'A', frame.seq, &generation.to_be_bytes()).send(socket)?;
                    Frame::new(b'W', generation, b"inline/1").send(socket)?;
                }
                b'W' if frame.seq == generation && sequence.is_some() => {
                    if raw.is_none() {
                        raw = Some(RawMode::enter()?);
                    } else if !ready {
                        // The outer PTY can still contain keys typed while this
                        // remote generation was unavailable.
                        unsafe {
                            libc::tcflush(0, libc::TCIFLUSH);
                        }
                    }
                    ready = true;
                    writer = true;
                    out_buf.extend_from_slice(&pending_output);
                    pending_output.clear();
                    persist_record(
                        session,
                        &[
                            ("phase", Value::String("ready".into())),
                            ("attachmentGeneration", Value::from(generation)),
                        ],
                    )?;
                    size = dimensions();
                    Frame::new(b'R', generation, &size).send(socket)?;
                }
                b'B' if sequence.is_some() => {
                    if raw.is_none() {
                        raw = Some(RawMode::enter()?);
                    }
                    ready = true;
                    writer = false;
                    out_buf.extend_from_slice(&pending_output);
                    pending_output.clear();
                    persist_record(
                        session,
                        &[
                            ("phase", Value::String("ready".into())),
                            ("attachmentGeneration", Value::from(generation)),
                        ],
                    )?;
                }
                b'O' => {
                    let previous = sequence.ok_or_else(|| {
                        io::Error::other("SSH output arrived before its snapshot")
                    })?;
                    if frame.seq != previous + frame.data.len() as u64 {
                        return Err(io::Error::other("SSH output sequence gap"));
                    }
                    screen.write(&frame.data);
                    if ready {
                        out_buf.extend_from_slice(&frame.data);
                    } else {
                        if pending_output.len() + frame.data.len() > crate::MAX_QUEUE {
                            return Err(io::Error::other(
                                "inline presentation queue exceeded its limit",
                            ));
                        }
                        pending_output.extend_from_slice(&frame.data);
                    }
                    screen.take_responses();
                    sequence = Some(frame.seq);
                }
                crate::activity::FRAME => {
                    if sequence != Some(frame.seq) {
                        return Err(io::Error::other("activity snapshot sequence mismatch"));
                    }
                    screen
                        .vt
                        .activity_mut()
                        .replace(crate::activity::Snapshot::decode(&frame.data)?);
                    let mode = if activity_hydrated { "live" } else { "restore" };
                    activity_hydrated = true;
                    pending_activity = Some(mode);
                }
                b'R' if frame.data.len() == 4 || frame.data.len() == 8 => {
                    let cols = u16::from_be_bytes([frame.data[0], frame.data[1]]);
                    let rows = u16::from_be_bytes([frame.data[2], frame.data[3]]);
                    if frame.data.len() == 8 {
                        let px_w = u16::from_be_bytes([frame.data[4], frame.data[5]]);
                        let px_h = u16::from_be_bytes([frame.data[6], frame.data[7]]);
                        if px_w > 0 && px_h > 0 {
                            screen.vt.resize_pixels(cols, rows, px_w, px_h)?;
                        } else {
                            screen.vt.resize(cols, rows)?;
                        }
                    } else {
                        screen.vt.resize(cols, rows)?;
                    }
                    screen.take_responses();
                }
                b'M' => {
                    let metadata: Value = serde_json::from_slice(&frame.data)?;
                    let password = metadata["password_input"].as_bool().unwrap_or(false);
                    persist_record(session, &[("passwordInput", Value::Bool(password))])?;
                    pending_password = Some(password);
                    if let Some(cwd) = metadata["cwd"]
                        .as_str()
                        .filter(|s| s.starts_with('/') && s.len() <= 4096)
                    {
                        persist_record(
                            session,
                            &[("workingDirectory", Value::String(cwd.into()))],
                        )?;
                        pending_cwd = Some(cwd.to_owned());
                    }
                }
                b'X' => {
                    flush_out_buf(&mut *raw_stdout, &mut out_buf)?;
                    if !pending_output.is_empty() {
                        let mut ended = Screen::new(80, 24)?;
                        let mut filter = crate::terminal_output::Relay::default();
                        raw_stdout.write_all(&filter.feed(&mut ended, &pending_output))?;
                    }
                    return std::str::from_utf8(&frame.data)
                        .ok()
                        .and_then(|s| s.parse().ok())
                        .ok_or_else(|| io::Error::other("invalid remote exit status"));
                }
                b'E' => {
                    let _ = flush_out_buf(&mut *raw_stdout, &mut out_buf);
                    return Err(io::Error::other(
                        String::from_utf8_lossy(&frame.data).into_owned(),
                    ));
                }
                _ => {}
            }
        }
        const INLINE_SYNC_HOLD_LIMIT: Duration = Duration::from_millis(12);
        const INLINE_OUT_BUF_LIMIT: usize = 256 * 1024;
        let in_sync = screen.in_sync();
        // Do not splice host metadata into a split CSI/OSC/image sequence or
        // an open DEC 2026 synchronized-output frame.
        if ready && !in_sync && screen.continuation().is_ok_and(|bytes| bytes.is_empty()) {
            if let Some(cwd) = pending_cwd.take() {
                out_buf.extend_from_slice(&context(session, Some(&cwd), None));
            }
            if let Some(mode) = pending_activity.take() {
                out_buf.extend_from_slice(
                    &screen.vt.activity().snapshot().inline_bytes_with_mode(mode),
                );
            }
            if let Some(password) = pending_password.take() {
                if password != password_input {
                    out_buf.extend_from_slice(if password {
                        b"\x1b]3008;start=omg-inline-password;1\x07"
                    } else {
                        b"\x1b]3008;start=omg-inline-password;0\x07"
                    });
                    password_input = password;
                }
            }
        }
        if out_buf.is_empty() {
            sync_hold_started = None;
        } else if !in_sync
            || !ready
            || out_buf.len() >= INLINE_OUT_BUF_LIMIT
            || sync_hold_started.is_some_and(|started| started.elapsed() >= INLINE_SYNC_HOLD_LIMIT)
        {
            flush_out_buf(&mut *raw_stdout, &mut out_buf)?;
            sync_hold_started = None;
        } else {
            sync_hold_started.get_or_insert_with(Instant::now);
        }
        if raw.is_some() {
            if let Some(code) = drain_ready_stdin(socket, generation, ready, writer)? {
                flush_out_buf(&mut *raw_stdout, &mut out_buf)?;
                return Ok(code);
            }
        }
        if ready && writer {
            let current = dimensions();
            if size != current {
                size = current;
                Frame::new(b'R', generation, &size).send(socket)?;
            }
        }
        // Before writer acquisition, SSH itself owns the cooked controlling
        // terminal for authentication. Afterward drop disconnected input.
        let mut fds = [
            libc::pollfd {
                fd: if raw.is_some() { 0 } else { -1 },
                events: libc::POLLIN,
                revents: 0,
            },
            libc::pollfd {
                fd: wake.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            },
        ];
        let poll_timeout_ms = if drained_frames == 32 {
            0
        } else if sync_hold_started.is_some() {
            4
        } else {
            500
        };
        let count = unsafe { libc::poll(fds.as_mut_ptr(), 2, poll_timeout_ms) };
        if count > 0 {
            if fds[1].revents & libc::POLLIN != 0 {
                let _ = wake.read(&mut [0; 256]);
            }
            if fds[0].revents & libc::POLLIN != 0 {
                if let Some(code) = drain_ready_stdin(socket, generation, ready, writer)? {
                    flush_out_buf(&mut *raw_stdout, &mut out_buf)?;
                    return Ok(code);
                }
            }
            if fds[0].revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0 {
                flush_out_buf(&mut *raw_stdout, &mut out_buf)?;
                return Ok(0);
            }
        }
    }
}

fn drain_ready_stdin(
    socket: &mut UnixStream,
    generation: u64,
    ready: bool,
    writer: bool,
) -> io::Result<Option<i32>> {
    let mut sent_takeover = false;
    drain_ready_stdin_with(
        || {
            let mut pfd = libc::pollfd {
                fd: 0,
                events: libc::POLLIN,
                revents: 0,
            };
            if unsafe { libc::poll(&mut pfd, 1, 0) } > 0 {
                pfd.revents
            } else {
                0
            }
        },
        |buf| io::stdin().read(buf),
        |chunk| {
            if !writer && !sent_takeover {
                sent_takeover = true;
                Frame::new(b'W', generation, b"inline-takeover/1").send(socket)?;
            }
            Frame::new(b'I', generation, chunk).send(socket)
        },
        ready,
    )
}

fn drain_ready_stdin_with(
    mut poll_stdin: impl FnMut() -> libc::c_short,
    mut read_stdin: impl FnMut(&mut [u8]) -> io::Result<usize>,
    mut on_chunk: impl FnMut(&[u8]) -> io::Result<()>,
    ready: bool,
) -> io::Result<Option<i32>> {
    let mut bytes = [0u8; 8192];
    for _ in 0..64 {
        let revents = poll_stdin();
        if revents & libc::POLLIN != 0 {
            let len = match read_stdin(&mut bytes) {
                Ok(n) => n,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) => return Err(e),
            };
            if len == 0 {
                return Ok(Some(0));
            }
            if ready {
                on_chunk(&bytes[..len])?;
            } else if bytes[..len].contains(&3) {
                return Ok(Some(130));
            }
            continue;
        }
        if revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0 {
            return Ok(Some(0));
        }
        break;
    }
    Ok(None)
}

fn flush_out_buf(out: &mut impl Write, buf: &mut Vec<u8>) -> io::Result<()> {
    if !buf.is_empty() {
        out.write_all(buf)?;
        buf.clear();
    }
    Ok(())
}

struct Screen {
    vt: Vt,
    // The C callback keeps a pointer to the Vec header while Screen can move.
    #[allow(clippy::box_collection)]
    replies: Box<Vec<u8>>,
}

extern "C" fn response(context: *mut c_void, data: *const u8, len: usize) {
    let replies = unsafe { &mut *context.cast::<Vec<u8>>() };
    // Queries are bounded; a broken peer must not grow this capture indefinitely.
    if len <= 64 * 1024 - replies.len() {
        replies.extend_from_slice(unsafe { std::slice::from_raw_parts(data, len) });
    }
}

impl Screen {
    fn new(cols: u16, rows: u16) -> io::Result<Self> {
        let mut replies = Box::new(Vec::new());
        let vt = Vt::with_reply_pixels_scrollback(
            cols,
            rows,
            cols.saturating_mul(8),
            rows.saturating_mul(16),
            crate::ScrollbackLimits {
                max_bytes: 0,
                max_lines: Some(0),
            },
            Some(response),
            (&mut *replies as *mut Vec<u8>).cast(),
        )?;
        Ok(Self { vt, replies })
    }

    fn write(&mut self, bytes: &[u8]) {
        self.vt.write(bytes);
    }
    fn restore(&mut self, bytes: &[u8]) -> io::Result<()> {
        self.vt.restore(bytes)?;
        // The outer managed terminal owns scrollback; the query mirror needs
        // only the active screen, even when a reconnect snapshot has history.
        crate::check(unsafe { crate::omg_vt_screen_only(self.vt.0) })
    }
    fn take_responses(&mut self) -> Vec<u8> {
        std::mem::take(&mut *self.replies)
    }
    fn in_sync(&self) -> bool {
        self.vt.in_sync()
    }
    fn ui_modes(&self) -> (bool, bool, bool, bool) {
        self.vt.ui_modes().unwrap_or((false, false, true, false))
    }
    fn continuation(&self) -> io::Result<Vec<u8>> {
        let mut data = std::ptr::null_mut();
        let mut len = 0;
        crate::check(unsafe { crate::omg_vt_continuation(self.vt.0, &mut data, &mut len) })?;
        let bytes = if len == 0 {
            Vec::new()
        } else {
            unsafe { std::slice::from_raw_parts(data, len).to_vec() }
        };
        unsafe { crate::omg_vt_buffer_free(data, len) };
        Ok(bytes)
    }

    // Mode reset and active-screen filtering follow herdr-core's Terminal::paint.
    // See LICENSE.herdr and THIRD-PARTY-NOTICES.
    fn repaint(&self, preserve_rows: Option<u16>) -> io::Result<Vec<u8>> {
        let mut data = std::ptr::null_mut();
        let mut len = 0;
        let mut alternate = false;
        crate::check(unsafe {
            crate::omg_vt_paint(self.vt.0, &mut data, &mut len, &mut alternate)
        })?;
        let bytes = if len == 0 {
            Vec::new()
        } else {
            unsafe { std::slice::from_raw_parts(data, len).to_vec() }
        };
        unsafe { crate::omg_vt_buffer_free(data, len) };
        let mut out = b"\x18\x1b[!p\x1b[?2026l\x1b[?2026h\x1b[?9l\x1b[?1000l\x1b[?1001l\x1b[?1002l\x1b[?1003l\
\x1b[?1004l\x1b[?1005l\x1b[?1006l\x1b[?1015l\x1b[?1016l\x1b[?2004l\x1b[?1l\
\x1b[?66l\x1b[?2031l\x1b[?2048l\x1b[=0;1u\x1b[?1049l\x1b[?1047l\x1b[?47l"
            .to_vec();
        if let Some(rows) = preserve_rows.filter(|&r| r > 0 && !alternate) {
            // Retain the local prefix in outer scrollback before a reconnect
            // replaces the remote viewport. The whole repaint is synchronized.
            out.extend_from_slice(b"\x1b[?6l\x1b[?69l\x1b[r\x1b[999;1H");
            for _ in 0..rows {
                out.extend_from_slice(b"\r\n");
            }
        }
        out.extend_from_slice(b"\x1b[H\x1b[2J");
        out.extend_from_slice(b"\x1b]110\x1b\\\x1b]111\x1b\\\x1b]112\x1b\\");
        for index in 0..3 {
            let mut rgb = [0; 3];
            if unsafe { crate::omg_vt_dynamic_color(self.vt.0, index, rgb.as_mut_ptr()) } == 0 {
                out.extend_from_slice(
                    format!(
                        "\x1b]{};rgb:{:02x}/{:02x}/{:02x}\x1b\\",
                        index + 10,
                        rgb[0],
                        rgb[1],
                        rgb[2]
                    )
                    .as_bytes(),
                );
            }
        }
        if alternate {
            out.extend_from_slice(b"\x1b[?1049h");
        }
        let skip: &[&[u8]] = &[b"\x1b[?2026h", b"\x1b[?47h", b"\x1b[?1047h", b"\x1b[?1049h"];
        let mut at = 0;
        while at < bytes.len() {
            if let Some(sequence) = skip.iter().find(|s| bytes[at..].starts_with(s)) {
                at += sequence.len();
            } else {
                out.push(bytes[at]);
                at += 1;
            }
        }
        out.extend_from_slice(b"\x1b[?2026l");
        Ok(out)
    }
}

impl crate::terminal_output::Screen for Screen {
    fn write(&mut self, bytes: &[u8]) {
        self.vt.write(bytes);
    }
    fn pending_responses(&self) -> usize {
        self.replies.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn query_filter_preserves_output_and_does_not_duplicate_authoritative_replies() {
        let mut screen = Screen::new(80, 24).unwrap();
        let mut relay = crate::terminal_output::Relay::default();
        let input = b"hello\x1b[31mred\x1b[0m\x1b[6n\x1b]2;remote\x07";
        let output: Vec<u8> = input
            .iter()
            .flat_map(|b| relay.feed(&mut screen, &[*b]))
            .collect();
        assert_eq!(output, b"hello\x1b[31mred\x1b[0m\x1b]2;remote\x07");
        assert!(!screen.take_responses().is_empty());
    }

    #[test]
    fn snapshot_restore_keeps_reply_capture_and_repaints_terminal_modes() {
        let mut original = Vt::new(20, 4).unwrap();
        original.write(b"\x1b[?1049hremote\x1b[?2004h");
        let mut screen = Screen::new(20, 4).unwrap();
        screen.restore(&original.snapshot().unwrap()).unwrap();
        assert_eq!(screen.vt.scrollback_limits().unwrap(), (0, Some(0)));
        screen.write(b"\x1b[6n");
        assert!(!screen.take_responses().is_empty());
        let mut target = Vt::new(20, 4).unwrap();
        target.write(&screen.repaint(None).unwrap());
        assert!(target.text().unwrap().contains("remote"));
        assert!(screen.continuation().unwrap().is_empty());
    }

    #[test]
    fn repaint_restores_program_colors_without_inventing_black_theme_defaults() {
        let mut screen = Screen::new(20, 4).unwrap();
        let plain = screen.repaint(None).unwrap();
        let prefix = b"]11;rgb:";
        assert!(!plain.windows(prefix.len()).any(|s| s == prefix));
        screen.write(b"\x1b]11;rgb:11/22/33\x1b\\");
        let styled = screen.repaint(None).unwrap();
        let color = b"]11;rgb:11/22/33\x1b\\";
        assert!(styled.windows(color.len()).any(|s| s == color));
    }

    #[test]
    fn repaint_skips_preserve_rows_scroll_when_in_alt_screen() {
        let mut screen = Screen::new(80, 24).unwrap();
        let primary_repaint = screen.repaint(Some(24)).unwrap();
        assert!(primary_repaint
            .windows(b"\x1b[999;1H\r\n".len())
            .any(|w| w == b"\x1b[999;1H\r\n"));

        screen.write(b"\x1b[?1049halt-app");
        let alt_repaint = screen.repaint(Some(24)).unwrap();
        assert!(
            !alt_repaint
                .windows(b"\x1b[999;1H".len())
                .any(|w| w == b"\x1b[999;1H"),
            "alt-screen repaint must not emit scrollback newlines"
        );
    }

    #[test]
    fn flush_out_buf_drains_and_clears_buffered_bytes_for_eof_paths() {
        let mut out = Vec::new();
        let mut buf = b"\x1b[?2026h\x1b[2Jpartial".to_vec();
        flush_out_buf(&mut out, &mut buf).unwrap();
        assert_eq!(out, b"\x1b[?2026h\x1b[2Jpartial");
        assert!(buf.is_empty());
        // Calling again on empty buffer must be a clean no-op.
        flush_out_buf(&mut out, &mut buf).unwrap();
        assert_eq!(out, b"\x1b[?2026h\x1b[2Jpartial");
    }

    #[test]
    fn drain_ready_stdin_flushes_multi_chunk_burst_before_resize_and_handles_ctrl_c() {
        #[derive(Debug, PartialEq, Eq)]
        enum Sent {
            Takeover,
            Input(usize),
            Resize,
        }
        let mut remaining = vec![b'x'; 20_000];
        remaining.extend_from_slice(b"\r");
        let cursor = std::cell::Cell::new(0usize);
        let mut events = Vec::new();
        let mut sent_takeover = false;
        let writer = false;

        let exit = drain_ready_stdin_with(
            || {
                if cursor.get() < remaining.len() {
                    libc::POLLIN
                } else {
                    0
                }
            },
            |buf| {
                let at = cursor.get();
                let n = (remaining.len() - at).min(buf.len());
                buf[..n].copy_from_slice(&remaining[at..at + n]);
                cursor.set(at + n);
                Ok(n)
            },
            |chunk| {
                if !writer && !sent_takeover {
                    sent_takeover = true;
                    events.push(Sent::Takeover);
                }
                events.push(Sent::Input(chunk.len()));
                Ok(())
            },
            true,
        )
        .unwrap();
        events.push(Sent::Resize);

        assert_eq!(exit, None);
        assert_eq!(cursor.get(), 20_001);
        assert_eq!(
            events,
            vec![
                Sent::Takeover,
                Sent::Input(8192),
                Sent::Input(8192),
                Sent::Input(3617),
                Sent::Resize,
            ]
        );

        // Unready Ctrl+C exits with 130 without forwarding input.
        let unready_exit = drain_ready_stdin_with(
            || libc::POLLIN,
            |buf| {
                buf[0] = 3;
                Ok(1)
            },
            |_| panic!("unready input must not forward"),
            false,
        )
        .unwrap();
        assert_eq!(unready_exit, Some(130));
    }
}
