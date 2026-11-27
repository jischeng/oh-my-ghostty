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

const STEADY_SCROLLBACK_MAX_BYTES: usize = 64 * 1024;
const STEADY_SCROLLBACK_MAX_LINES: usize = 64;
const INLINE_FLUSH_CHUNK_BYTES: usize = 64 * 1024;
const EVICTION_FALLBACK_MIN_HISTORY_ROWS: usize = 512;

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

fn parse_remote_dimensions(info: &Value) -> Option<[u8; 8]> {
    let cols = (info["cols"].as_u64()? as u16).clamp(1, 500);
    let rows = (info["rows"].as_u64()? as u16).clamp(1, 300);
    let px_w = info["pixel_width"].as_u64().unwrap_or(0).min(16_000) as u16;
    let px_h = info["pixel_height"].as_u64().unwrap_or(0).min(16_000) as u16;
    let mut bytes = [0u8; 8];
    bytes[..2].copy_from_slice(&cols.to_be_bytes());
    bytes[2..4].copy_from_slice(&rows.to_be_bytes());
    bytes[4..6].copy_from_slice(&px_w.to_be_bytes());
    bytes[6..8].copy_from_slice(&px_h.to_be_bytes());
    Some(bytes)
}

fn parse_resize_frame(data: &[u8]) -> Option<[u8; 8]> {
    match data.len() {
        4 => {
            let mut bytes = [0u8; 8];
            bytes[..4].copy_from_slice(data);
            Some(bytes)
        }
        8 => data.try_into().ok(),
        _ => None,
    }
}

fn same_terminal_size(local: [u8; 8], remote: [u8; 8]) -> bool {
    local[..4] == remote[..4]
        && (local[4..8] == [0, 0, 0, 0]
            || remote[4..8] == [0, 0, 0, 0]
            || local[4..8] == remote[4..8])
}

fn apply_dimensions_to_vt(vt: &mut Vt, dims: [u8; 8]) -> io::Result<()> {
    let cols = u16::from_be_bytes([dims[0], dims[1]]);
    let rows = u16::from_be_bytes([dims[2], dims[3]]);
    let px_w = u16::from_be_bytes([dims[4], dims[5]]);
    let px_h = u16::from_be_bytes([dims[6], dims[7]]);
    if px_w > 0 && px_h > 0 {
        vt.resize_pixels(cols, rows, px_w, px_h)
    } else {
        vt.resize(cols, rows)
    }
}

#[derive(Debug, PartialEq, Eq)]
struct ReconnectPlan {
    preserve_local_prefix: bool,
    /// `None` means replay from `history_start_row = 0` (start of retained history);
    /// `Some(row)` means track `row` (`0..=new_hist.len()`).
    history_start_row: Option<usize>,
}

fn trim_trailing_empty(lines: &[String]) -> &[String] {
    let end = lines
        .iter()
        .rposition(|s| !s.is_empty())
        .map_or(0, |i| i + 1);
    &lines[..end]
}

fn match_tail_anchor(anchor_rows: &[String], haystack: &[String]) -> Option<usize> {
    if anchor_rows.is_empty() || haystack.is_empty() {
        return None;
    }
    let Some(end_ne) = anchor_rows.iter().rposition(|s| !s.is_empty()) else {
        if haystack.len() >= anchor_rows.len()
            && haystack[..anchor_rows.len()].iter().all(String::is_empty)
        {
            return Some(anchor_rows.len());
        }
        return None;
    };
    let trailing_blanks = anchor_rows.len() - 1 - end_ne;
    for &max_win in &[16usize, 4usize, 1usize] {
        let win_len = (end_ne + 1).min(max_win);
        if max_win == 1 && anchor_rows[end_ne].len() < 6 && end_ne > 0 {
            continue;
        }
        let win_start = end_ne + 1 - win_len;
        let window = &anchor_rows[win_start..=end_ne];
        let needed = win_len + trailing_blanks;
        if haystack.len() < needed {
            continue;
        }
        let max_pos = haystack.len() - needed;
        for pos in (0..=max_pos).rev() {
            if haystack[pos..pos + win_len] == *window
                && haystack[pos + win_len..pos + needed]
                    .iter()
                    .all(String::is_empty)
            {
                return Some(pos + needed);
            }
        }
        if win_len == end_ne + 1 {
            break;
        }
    }
    None
}

fn plan_reconnect(
    had_first_picture: bool,
    was_prefix_preserved: bool,
    alt_screen: bool,
    same_seq_and_size: bool,
    old_hist: &[String],
    old_act: &[String],
    new_hist: &[String],
) -> ReconnectPlan {
    if alt_screen {
        return ReconnectPlan {
            preserve_local_prefix: false,
            history_start_row: Some(new_hist.len()),
        };
    }
    if had_first_picture {
        return ReconnectPlan {
            preserve_local_prefix: !was_prefix_preserved,
            history_start_row: None,
        };
    }
    if same_seq_and_size {
        return ReconnectPlan {
            preserve_local_prefix: !was_prefix_preserved,
            history_start_row: Some(new_hist.len()),
        };
    }
    if new_hist.is_empty() {
        return ReconnectPlan {
            preserve_local_prefix: !was_prefix_preserved,
            history_start_row: Some(0),
        };
    }
    let old_act_trimmed = trim_trailing_empty(old_act);
    if was_prefix_preserved {
        if !old_hist.is_empty() {
            if let Some(anchor_end) = match_tail_anchor(old_hist, new_hist) {
                ReconnectPlan {
                    preserve_local_prefix: false,
                    history_start_row: Some(anchor_end),
                }
            } else {
                // Anchor evicted (e.g. >4 MiB output during disconnect): preserve old active
                // viewport into outer scrollback and replay retained history from row 0.
                ReconnectPlan {
                    preserve_local_prefix: !old_act_trimmed.is_empty(),
                    history_start_row: None,
                }
            }
        } else if !old_act_trimmed.is_empty()
            && new_hist.len() >= EVICTION_FALLBACK_MIN_HISTORY_ROWS
            && match_tail_anchor(old_act_trimmed, new_hist).is_none()
        {
            ReconnectPlan {
                preserve_local_prefix: true,
                history_start_row: None,
            }
        } else {
            ReconnectPlan {
                preserve_local_prefix: false,
                history_start_row: None,
            }
        }
    } else {
        // Local shell prefix is still partially visible on the outer viewport: push
        // preserve_rows once so local prefix enters outer scrollback, and avoid
        // duplicating old_active lines if they also scrolled into new_hist.
        let mut combined = Vec::with_capacity(old_hist.len() + old_act_trimmed.len());
        combined.extend_from_slice(old_hist);
        combined.extend_from_slice(old_act_trimmed);
        let start = match_tail_anchor(&combined, new_hist)
            .or_else(|| match_tail_anchor(new_hist, &combined).map(|_| new_hist.len()))
            .or_else(|| {
                (!old_hist.is_empty())
                    .then(|| match_tail_anchor(old_hist, new_hist))
                    .flatten()
            });
        ReconnectPlan {
            preserve_local_prefix: true,
            history_start_row: start,
        }
    }
}

struct PendingRepaint {
    preserve_local_prefix: bool,
    tracked_start: Option<crate::TrackedRow>,
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
    let mut last_seen_seq: Option<u64> = None;
    let mut ready = false;
    let mut writer = false;
    let mut raw = None;
    let mut first_picture = true;
    let mut preserved_local_prefix = false;
    let mut initial_output = None;
    let mut remote_size: Option<[u8; 8]> = None;
    let mut pending_repaint: Option<PendingRepaint> = None;
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
            if stdout_poll_writable() {
                let _ =
                    flush_out_buf_chunk(&mut *raw_stdout, &mut out_buf, INLINE_FLUSH_CHUNK_BYTES);
            }
            out_buf.clear();
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
                    remote_size = None;
                    pending_repaint = None;
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
                    remote_size = parse_remote_dimensions(&info);
                    initial_output = info["initial_output"]
                        .as_str()
                        .filter(|s| s.len() <= 12 * 1024)
                        .and_then(|s| base64::engine::general_purpose::STANDARD.decode(s).ok());
                }
                b'S' => {
                    let had_first_picture = first_picture;
                    if had_first_picture && initial_output.is_some() {
                        let cur_cols = u16::from_be_bytes([size[0], size[1]]);
                        let cur_rows = u16::from_be_bytes([size[2], size[3]]);
                        screen = Screen::new(cur_cols, cur_rows)?;
                        pending_repaint = None;
                        pending_output = initial_output.take().unwrap();
                        screen.write(&pending_output);
                        if !screen.vt.in_alt_screen() && screen.scrollback_rows() > 0 {
                            preserved_local_prefix = true;
                        }
                    } else {
                        let (old_cols, old_rows, old_hist, old_act) = if !had_first_picture {
                            if screen.vt.in_alt_screen() {
                                screen.write(b"\x1b[?1049l\x1b[?1047l\x1b[?47l");
                            }
                            let (c, r, _, _) = screen.vt.grid_metrics()?;
                            (
                                c,
                                r,
                                screen.vt.region_lines(true)?,
                                screen.vt.region_lines(false)?,
                            )
                        } else {
                            (0, 0, Vec::new(), Vec::new())
                        };
                        screen.restore(&frame.data)?;
                        let (new_cols, new_rows, new_sb, new_alt) = screen.vt.grid_metrics()?;
                        let same_seq_and_size = !had_first_picture
                            && last_seen_seq == Some(frame.seq)
                            && old_cols == new_cols
                            && old_rows == new_rows;
                        let new_hist = if new_alt || had_first_picture || same_seq_and_size {
                            vec![String::new(); new_sb]
                        } else {
                            screen.vt.region_lines(true)?
                        };
                        let plan = plan_reconnect(
                            had_first_picture,
                            preserved_local_prefix,
                            new_alt,
                            same_seq_and_size,
                            &old_hist,
                            &old_act,
                            &new_hist,
                        );
                        let tracked_start = if new_alt {
                            None
                        } else if let Some(start_row) = plan.history_start_row {
                            if start_row < new_sb {
                                Some(screen.vt.track_row(true, start_row)?)
                            } else {
                                Some(screen.vt.track_row(false, 0)?)
                            }
                        } else {
                            None
                        };
                        pending_output.clear();
                        pending_repaint = Some(PendingRepaint {
                            preserve_local_prefix: plan.preserve_local_prefix,
                            tracked_start,
                        });
                    }
                    screen.take_responses();
                    first_picture = false;
                    ready = false;
                    writer = false;
                    activity_hydrated = false;
                    pending_activity = None;
                    sequence = Some(frame.seq);
                    last_seen_seq = Some(frame.seq);
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
                    size = dimensions();
                    if remote_size.is_none_or(|rem| !same_terminal_size(size, rem)) {
                        Frame::new(b'R', generation, &size).send(socket)?;
                        apply_dimensions_to_vt(&mut screen.vt, size)?;
                        screen.take_responses();
                        remote_size = Some(size);
                    }
                    if let Some(pr) = pending_repaint.take() {
                        let cur_rows = u16::from_be_bytes([size[2], size[3]]);
                        let painted = materialize_pending_repaint(
                            &mut screen,
                            pr,
                            &mut preserved_local_prefix,
                            cur_rows,
                        )?;
                        out_buf.extend_from_slice(&painted);
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
                }
                b'B' if sequence.is_some() => {
                    if raw.is_none() {
                        raw = Some(RawMode::enter()?);
                    }
                    if let Some(pr) = pending_repaint.take() {
                        let current = dimensions();
                        let cur_rows = u16::from_be_bytes([current[2], current[3]]);
                        let painted = materialize_pending_repaint(
                            &mut screen,
                            pr,
                            &mut preserved_local_prefix,
                            cur_rows,
                        )?;
                        out_buf.extend_from_slice(&painted);
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
                        if !preserved_local_prefix
                            && !screen.vt.in_alt_screen()
                            && screen.scrollback_rows() > 0
                        {
                            preserved_local_prefix = true;
                        }
                        out_buf.extend_from_slice(&frame.data);
                    } else if pending_repaint.is_none() {
                        if pending_output.len() + frame.data.len() > crate::MAX_QUEUE {
                            return Err(io::Error::other(
                                "inline presentation queue exceeded its limit",
                            ));
                        }
                        pending_output.extend_from_slice(&frame.data);
                    }
                    screen.take_responses();
                    sequence = Some(frame.seq);
                    last_seen_seq = Some(frame.seq);
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
                    if let Some(parsed) = parse_resize_frame(&frame.data) {
                        remote_size = Some(parsed);
                        apply_dimensions_to_vt(&mut screen.vt, parsed)?;
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
                    if let Some(pr) = pending_repaint.take() {
                        let current = dimensions();
                        let cur_rows = u16::from_be_bytes([current[2], current[3]]);
                        let painted = materialize_pending_repaint(
                            &mut screen,
                            pr,
                            &mut preserved_local_prefix,
                            cur_rows,
                        )?;
                        raw_stdout.write_all(&painted)?;
                    }
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
        let mut wants_stdout_flush = false;
        if out_buf.is_empty() {
            sync_hold_started = None;
        } else if !in_sync
            || !ready
            || out_buf.len() >= INLINE_OUT_BUF_LIMIT
            || sync_hold_started.is_some_and(|started| started.elapsed() >= INLINE_SYNC_HOLD_LIMIT)
        {
            if stdout_poll_writable() {
                flush_out_buf_chunk(&mut *raw_stdout, &mut out_buf, INLINE_FLUSH_CHUNK_BYTES)?;
            }
            if out_buf.is_empty() {
                sync_hold_started = None;
            } else {
                wants_stdout_flush = true;
            }
        } else {
            sync_hold_started.get_or_insert_with(Instant::now);
        }
        if raw.is_some() {
            if let Some(code) = drain_ready_stdin(socket, generation, ready, writer)? {
                if code == 0 {
                    flush_out_buf(&mut *raw_stdout, &mut out_buf)?;
                } else {
                    if stdout_poll_writable() {
                        let _ = flush_out_buf_chunk(
                            &mut *raw_stdout,
                            &mut out_buf,
                            INLINE_FLUSH_CHUNK_BYTES,
                        );
                    }
                    out_buf.clear();
                }
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
            libc::pollfd {
                fd: if wants_stdout_flush {
                    libc::STDOUT_FILENO
                } else {
                    -1
                },
                events: libc::POLLOUT,
                revents: 0,
            },
        ];
        let poll_timeout_ms = if drained_frames == 32 {
            0
        } else if sync_hold_started.is_some() && !wants_stdout_flush {
            4
        } else {
            500
        };
        let count = unsafe { libc::poll(fds.as_mut_ptr(), 3, poll_timeout_ms) };
        if count > 0 {
            if fds[1].revents & libc::POLLIN != 0 {
                let _ = wake.read(&mut [0; 256]);
            }
            if fds[0].revents & libc::POLLIN != 0 {
                if let Some(code) = drain_ready_stdin(socket, generation, ready, writer)? {
                    if code == 0 {
                        flush_out_buf(&mut *raw_stdout, &mut out_buf)?;
                    } else {
                        if stdout_poll_writable() {
                            let _ = flush_out_buf_chunk(
                                &mut *raw_stdout,
                                &mut out_buf,
                                INLINE_FLUSH_CHUNK_BYTES,
                            );
                        }
                        out_buf.clear();
                    }
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

fn stdout_poll_writable() -> bool {
    let mut pfd = libc::pollfd {
        fd: libc::STDOUT_FILENO,
        events: libc::POLLOUT,
        revents: 0,
    };
    let rc = unsafe { libc::poll(&mut pfd, 1, 0) };
    rc > 0 && (pfd.revents & (libc::POLLOUT | libc::POLLERR | libc::POLLHUP)) != 0
}

fn flush_out_buf_chunk(
    out: &mut impl Write,
    buf: &mut Vec<u8>,
    max_chunk: usize,
) -> io::Result<usize> {
    if buf.is_empty() || max_chunk == 0 {
        return Ok(0);
    }
    let end = buf.len().min(max_chunk);
    loop {
        match out.write(&buf[..end]) {
            Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
            Ok(n) => {
                buf.drain(..n);
                return Ok(n);
            }
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => return Ok(0),
            Err(e) => return Err(e),
        }
    }
}

fn flush_out_buf(out: &mut impl Write, buf: &mut Vec<u8>) -> io::Result<()> {
    if !buf.is_empty() {
        out.write_all(buf)?;
        buf.clear();
    }
    Ok(())
}

fn materialize_pending_repaint(
    screen: &mut Screen,
    pending: PendingRepaint,
    preserved_local_prefix: &mut bool,
    current_rows: u16,
) -> io::Result<Vec<u8>> {
    let (_, _, _, alt_now) = screen.vt.grid_metrics()?;
    let preserve_rows = if pending.preserve_local_prefix && !alt_now {
        *preserved_local_prefix = true;
        Some(current_rows)
    } else {
        None
    };
    let history_start_row = match pending.tracked_start {
        Some(tracked) => tracked.resolve_history_start_row(&screen.vt)?,
        None => 0,
    };
    let mut painted = screen.repaint_with_history(preserve_rows, history_start_row)?;
    painted.extend(screen.continuation()?);
    screen.shrink_scrollback()?;
    Ok(painted)
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
                max_bytes: STEADY_SCROLLBACK_MAX_BYTES,
                max_lines: Some(STEADY_SCROLLBACK_MAX_LINES),
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
        // Temporarily decode the full 4 MiB snapshot history for delta replay,
        // then shrink back to 64 lines / 64 KiB once repaint completes.
        self.vt.set_scrollback_limits(crate::ScrollbackLimits {
            max_bytes: crate::DEFAULT_SCROLLBACK_MAX_BYTES,
            max_lines: None,
        })?;
        self.vt.restore(bytes)
    }
    fn shrink_scrollback(&mut self) -> io::Result<()> {
        self.vt.set_scrollback_limits(crate::ScrollbackLimits {
            max_bytes: STEADY_SCROLLBACK_MAX_BYTES,
            max_lines: Some(STEADY_SCROLLBACK_MAX_LINES),
        })
    }
    fn scrollback_rows(&self) -> usize {
        self.vt.grid_metrics().map(|(_, _, sb, _)| sb).unwrap_or(0)
    }
    fn take_responses(&mut self) -> Vec<u8> {
        std::mem::take(&mut *self.replies)
    }
    fn in_sync(&self) -> bool {
        self.vt.in_sync()
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
    #[cfg(test)]
    fn repaint(&self, preserve_rows: Option<u16>) -> io::Result<Vec<u8>> {
        self.repaint_with_history(preserve_rows, usize::MAX)
    }

    fn repaint_with_history(
        &self,
        preserve_rows: Option<u16>,
        history_start_row: usize,
    ) -> io::Result<Vec<u8>> {
        let (bytes, alternate) = self.vt.paint_with_history(history_start_row)?;
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
        assert_eq!(
            screen.vt.scrollback_limits().unwrap(),
            (
                STEADY_SCROLLBACK_MAX_BYTES,
                Some(STEADY_SCROLLBACK_MAX_LINES)
            )
        );
        screen.restore(&original.snapshot().unwrap()).unwrap();
        assert_eq!(
            screen.vt.scrollback_limits().unwrap(),
            (crate::DEFAULT_SCROLLBACK_MAX_BYTES, None)
        );
        screen.write(b"\x1b[6n");
        assert!(!screen.take_responses().is_empty());
        let mut target = Vt::new(20, 4).unwrap();
        target.write(&screen.repaint(None).unwrap());
        screen.shrink_scrollback().unwrap();
        assert_eq!(
            screen.vt.scrollback_limits().unwrap(),
            (
                STEADY_SCROLLBACK_MAX_BYTES,
                Some(STEADY_SCROLLBACK_MAX_LINES)
            )
        );
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

    #[test]
    fn single_pass_paint_with_small_history_delta_never_overwrites_with_home_and_restores_post_state(
    ) {
        // 40-row terminal with K = 5 (< 40) history rows, soft-wrapped history, custom tabstops,
        // DECSTBM scroll region, OSC 7 pwd, ?7l, 4h, ?25l, and explicit CUP cursor position.
        let mut remote = Vt::new(20, 40).unwrap();
        remote.write(b"\x1b[3g\x1b[7G\x1bH\x1b[H");
        // Write 1 soft-wrapped line (25 chars on 20-col grid -> 2 rows) + 3 normal lines = 5 history rows,
        // followed by 40 active rows so exactly 5 rows land in history.
        remote.write(b"WRAP_HEAD_0123456789TAIL!\r\n");
        remote.write(b"HIST_ROW_2\r\nHIST_ROW_3\r\nHIST_ROW_4\r\n");
        for i in 0..40 {
            if i < 39 {
                remote.write(format!("ACTIVE_ROW_{i:02}\r\n").as_bytes());
            } else {
                remote.write(format!("ACTIVE_ROW_{i:02}").as_bytes());
            }
        }
        // Set DECSTBM, OSC 7, modes (?7l, 4h, ?25l, ?2004h), and CUP (col 5, row 11 -> 1-indexed 12;6H).
        remote.write(
            b"\x1b[4;36r\x1b]7;file://remote/workspace\x1b\\\x1b[4h\x1b[?7l\x1b[?25l\x1b[?2004h\x1b[12;6H",
        );
        let (_, _, sb_rows, alt) = remote.grid_metrics().unwrap();
        assert!(!alt);
        assert_eq!(sb_rows, 5);

        let mut viewer = Screen::new(20, 40).unwrap();
        viewer.restore(&remote.snapshot().unwrap()).unwrap();
        let raw_vt = viewer.vt.paint_with_history(0).unwrap().0;
        // Verify \x1b[H from tabstops appears ONLY before the history content, NEVER after!
        let wrap_pos = raw_vt
            .windows(b"WRAP_HEAD_".len())
            .position(|w| w == b"WRAP_HEAD_")
            .expect("history text present");
        assert!(
            !raw_vt[wrap_pos..].windows(3).any(|w| w == b"\x1b[H"),
            "CSI H must never be emitted after history text"
        );

        let repainted = viewer.repaint_with_history(None, 0).unwrap();
        viewer.shrink_scrollback().unwrap();

        let mut outer = Vt::new(20, 40).unwrap();
        outer.write(&repainted);

        let outer_hist = outer.region_lines(true).unwrap();
        assert_eq!(
            outer_hist,
            vec![
                "WRAP_HEAD_0123456789",
                "TAIL!",
                "HIST_ROW_2",
                "HIST_ROW_3",
                "HIST_ROW_4",
            ]
        );
        let outer_act = outer.region_lines(false).unwrap();
        assert_eq!(outer_act.len(), 40);
        assert_eq!(outer_act[0], "ACTIVE_ROW_00");
        assert_eq!(outer_act[39], "ACTIVE_ROW_39");

        // Modes (?25l hidden cursor, ?7l wrap off, 4h insert), DECSTBM, OSC 7, and CUP restored after text:
        let (_, outer_alt, cursor_vis, _) = outer.ui_modes().unwrap();
        assert!(!outer_alt);
        assert!(!cursor_vis, "?25l must be restored after text");
        let raw_text = String::from_utf8_lossy(&raw_vt);
        assert!(raw_text.contains("\x1b[?7l"), "{raw_text:?}");
        assert!(raw_text.contains("\x1b[4h"), "{raw_text:?}");
        assert!(raw_text.contains("\x1b[4;36r"), "{raw_text:?}");
        assert!(
            raw_text.contains("\x1b]7;file://remote/workspace"),
            "{raw_text:?}"
        );
        assert!(raw_text.contains("\x1b[12;6H"), "{raw_text:?}");

        // Confirm cursor is genuinely at (x=5, y=11) in outer terminal via DSR 6n.
        let mut outer_screen = Screen::new(20, 40).unwrap();
        outer_screen
            .vt
            .set_scrollback_limits(crate::ScrollbackLimits {
                max_bytes: crate::DEFAULT_SCROLLBACK_MAX_BYTES,
                max_lines: None,
            })
            .unwrap();
        outer_screen.write(&repainted);
        outer_screen.take_responses();
        outer_screen.write(b"\x1b[6n");
        assert_eq!(outer_screen.take_responses(), b"\x1b[12;6R");
    }

    #[test]
    fn hidden_cursor_tui_reconnect_preserves_prefix_and_avoids_duplicating_old_active() {
        // Simulate outer terminal starting with local shell output before inline SSH attach.
        let mut outer = Vt::new(40, 10).unwrap();
        outer.write(b"LOCAL_PROMPT$ omg +ssh dev\r\n");

        // Remote starts a hidden-cursor TUI (?25l) that pushes 15 conversation lines into
        // scrollback and draws a 10-row TUI frame on its active screen.
        let mut remote = Vt::new(40, 10).unwrap();
        remote.write(b"\x1b[?25l");
        for i in 0..15 {
            remote.write(format!("PRE_TURN_{i:02}\r\n").as_bytes());
        }
        for r in 0..10 {
            if r < 9 {
                remote.write(format!("OLD_TUI_BOX_{r}\r\n").as_bytes());
            } else {
                remote.write(format!("OLD_TUI_BOX_{r}").as_bytes());
            }
        }

        // 1. Initial attach to existing hidden-cursor TUI session: must preserve LOCAL_PROMPT!
        let mut viewer = Screen::new(40, 10).unwrap();
        let mut preserved_local_prefix = false;
        viewer.restore(&remote.snapshot().unwrap()).unwrap();
        let new_hist_1 = viewer.vt.region_lines(true).unwrap();
        let plan_1 = plan_reconnect(
            true,
            preserved_local_prefix,
            false,
            false,
            &[],
            &[],
            &new_hist_1,
        );
        assert!(plan_1.preserve_local_prefix);
        assert_eq!(plan_1.history_start_row, None);
        let paint_1 = materialize_pending_repaint(
            &mut viewer,
            PendingRepaint {
                preserve_local_prefix: plan_1.preserve_local_prefix,
                tracked_start: None,
            },
            &mut preserved_local_prefix,
            10,
        )
        .unwrap();
        assert!(preserved_local_prefix);
        outer.write(&paint_1);
        assert!(outer
            .region_lines(true)
            .unwrap()
            .iter()
            .any(|l| l.contains("LOCAL_PROMPT$ omg +ssh dev")));

        // 2. Disconnect for 30+ minutes: TUI clears OLD_TUI_BOX in-place, scrolls 25 new lines into
        // scrollback, and draws NEW_TUI_BOX on its 10 active rows.
        remote.write(b"\x1b[H\x1b[2J");
        for i in 0..25 {
            remote.write(format!("DISCONNECT_TURN_{i:02}\r\n").as_bytes());
        }
        for r in 0..10 {
            if r < 9 {
                remote.write(format!("NEW_TUI_BOX_{r}\r\n").as_bytes());
            } else {
                remote.write(format!("NEW_TUI_BOX_{r}").as_bytes());
            }
        }

        // Reconnect: match viewer's tail anchor against restored remote snapshot.
        let old_hist = viewer.vt.region_lines(true).unwrap();
        let old_act = viewer.vt.region_lines(false).unwrap();
        viewer.restore(&remote.snapshot().unwrap()).unwrap();
        let new_hist_2 = viewer.vt.region_lines(true).unwrap();
        let plan_2 = plan_reconnect(
            false,
            preserved_local_prefix,
            false,
            false,
            &old_hist,
            &old_act,
            &new_hist_2,
        );
        assert!(
            !plan_2.preserve_local_prefix,
            "must NOT push stale OLD_TUI_BOX into scrollback when anchor matches"
        );
        let start_row = plan_2.history_start_row.expect("anchor must match");
        let tracked = viewer.vt.track_row(true, start_row).unwrap();
        let paint_2 = materialize_pending_repaint(
            &mut viewer,
            PendingRepaint {
                preserve_local_prefix: plan_2.preserve_local_prefix,
                tracked_start: Some(tracked),
            },
            &mut preserved_local_prefix,
            10,
        )
        .unwrap();
        outer.write(&paint_2);

        let final_hist = outer.region_lines(true).unwrap();
        let final_act = outer.region_lines(false).unwrap();
        assert!(final_hist
            .iter()
            .any(|l| l.contains("LOCAL_PROMPT$ omg +ssh dev")));
        for i in 0..15 {
            let expected = format!("PRE_TURN_{i:02}");
            assert_eq!(
                final_hist.iter().filter(|l| *l == &expected).count(),
                1,
                "pre-disconnect line {expected} must appear once"
            );
        }
        for i in 0..25 {
            let expected = format!("DISCONNECT_TURN_{i:02}");
            assert_eq!(
                final_hist.iter().filter(|l| *l == &expected).count(),
                1,
                "disconnect line {expected} must appear once"
            );
        }
        assert!(
            !final_hist.iter().any(|l| l.starts_with("OLD_TUI_BOX_")),
            "stale OLD_TUI_BOX must be replaced, not pushed into scrollback: {final_hist:?}"
        );
        assert_eq!(final_act[0], "NEW_TUI_BOX_0");
        assert_eq!(final_act[9], "NEW_TUI_BOX_9");
    }

    #[test]
    fn tail_anchor_handles_eviction_clear_and_tracked_reflow_on_resize() {
        // 1. >4 MiB eviction fallback: old_hist anchor missing in large new_hist -> preserve old_active & replay from 0.
        let old_hist = vec!["ANCHOR_OLD_1".to_owned(), "ANCHOR_OLD_2".to_owned()];
        let old_act = vec!["STILL_VISIBLE_BEFORE_EVICT".to_owned(), String::new()];
        let evicted_new_hist: Vec<String> = (0..600).map(|i| format!("POST_EVICT_{i}")).collect();
        let evict_plan = plan_reconnect(
            false,
            true,
            false,
            false,
            &old_hist,
            &old_act,
            &evicted_new_hist,
        );
        assert_eq!(
            evict_plan,
            ReconnectPlan {
                preserve_local_prefix: true,
                history_start_row: None,
            }
        );

        // 2. `clear` (\x1b[3J) during disconnect: new_hist is empty -> no false eviction preserve_rows.
        let clear_plan = plan_reconnect(false, true, false, false, &old_hist, &old_act, &[]);
        assert_eq!(
            clear_plan,
            ReconnectPlan {
                preserve_local_prefix: false,
                history_start_row: Some(0),
            }
        );

        // 2b. Unpreserved prefix with small history delta already inside pre-disconnect active rows:
        // preserve_rows pushes old_act into outer scrollback, so new_hist subset is not replayed twice.
        let unpreserved_small_delta = plan_reconnect(
            false,
            false,
            false,
            false,
            &[],
            &[
                "ACT_LINE_00".to_string(),
                "ACT_LINE_01".to_string(),
                "ACT_LINE_02".to_string(),
                "ACT_LINE_03".to_string(),
            ],
            &["ACT_LINE_00".to_string(), "ACT_LINE_01".to_string()],
        );
        assert_eq!(
            unpreserved_small_delta,
            ReconnectPlan {
                preserve_local_prefix: true,
                history_start_row: Some(2),
            }
        );

        // 3. Resize before repaint: TrackedRow follows reflowed delta start row accurately.
        let mut remote = Vt::new(40, 6).unwrap();
        for i in 0..10 {
            remote.write(format!("LINE_{i:02}_01234567890123456789\r\n").as_bytes());
        }
        let mut viewer = Screen::new(40, 6).unwrap();
        viewer.restore(&remote.snapshot().unwrap()).unwrap();
        // Suppose rows 0..2 were already in outer scrollback, so delta starts at history row 3 (LINE_03).
        let tracked = viewer.vt.track_row(true, 3).unwrap();
        // Resize viewer narrower (40 -> 20 cols) BEFORE repaint, causing each 28-char line to wrap to 2 rows!
        viewer.vt.resize(20, 6).unwrap();
        let resolved = tracked.resolve_history_start_row(&viewer.vt).unwrap();
        let reflowed_hist = viewer.vt.region_lines(true).unwrap();
        assert_eq!(reflowed_hist[resolved], "LINE_03_012345678901");
    }

    #[test]
    fn history_replay_caps_10k_rows_and_chunks_out_buf_writes() {
        let mut remote = Vt::new(40, 10).unwrap();
        for i in 0..10_500 {
            remote.write(format!("ROW_{i:05}\r\n").as_bytes());
        }
        let (_, _, sb, _) = remote.grid_metrics().unwrap();
        assert!(sb > 10_200, "expected >10,200 history rows, got {sb}");
        let (painted, _) = remote.paint_with_history(0).unwrap();
        let text = String::from_utf8_lossy(&painted);
        assert!(
            !text.contains("ROW_00010"),
            "rows older than 10,000 cap must be skipped"
        );
        assert!(
            text.contains("ROW_10495"),
            "recent history rows must be retained"
        );
        assert!(painted.len() <= 2 * 1024 * 1024 + 64 * 1024);

        // Chunked stdout flush drains at most INLINE_FLUSH_CHUNK_BYTES per iteration.
        let mut sink = Vec::new();
        let mut out_buf = vec![b'A'; INLINE_FLUSH_CHUNK_BYTES * 2 + 1234];
        let n1 = flush_out_buf_chunk(&mut sink, &mut out_buf, INLINE_FLUSH_CHUNK_BYTES).unwrap();
        assert_eq!(n1, INLINE_FLUSH_CHUNK_BYTES);
        assert_eq!(out_buf.len(), INLINE_FLUSH_CHUNK_BYTES + 1234);
        let n2 = flush_out_buf_chunk(&mut sink, &mut out_buf, INLINE_FLUSH_CHUNK_BYTES).unwrap();
        assert_eq!(n2, INLINE_FLUSH_CHUNK_BYTES);
        let n3 = flush_out_buf_chunk(&mut sink, &mut out_buf, INLINE_FLUSH_CHUNK_BYTES).unwrap();
        assert_eq!(n3, 1234);
        assert!(out_buf.is_empty());
    }
}
