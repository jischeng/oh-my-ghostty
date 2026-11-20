//! Presentation facts and authoritative agent activity reduction.
//! Terminal output never authorizes session recovery or cleanup.
use base64::{engine::general_purpose::STANDARD, Engine as _};
use serde::{Deserialize, Serialize};
use std::io;

pub const FRAME: u8 = b'G';
pub const SYNC: &str = "omg-agent-sync";
pub const TAP: &str = "omg-osc26";
pub const MAX_RECORDS: usize = 64;
pub const MAX_SNAPSHOT: usize = 2 * 1024 * 1024;
const TAP_MAX_BYTES: usize = 4096;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct Signal {
    pub id: String,
    pub metadata: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Tier {
    Fallback = 1,
    Hook = 2,
    ProgramStatus = 3,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Presentation {
    pub tier: Tier,
    pub agent: String,
    pub state: &'static str,
    pub attention: Option<&'static str>,
    pub message: String,
    pub background: bool,
    pub conversation: Option<String>,
    pub task_progress: Option<String>,
    pub title: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Snapshot {
    pub version: u32,
    pub revision: u64,
    pub records: Vec<Signal>,
    pub pending: Option<Vec<Signal>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remote_host: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remote_cwd: Option<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub sync_restore: bool,
}

impl Default for Snapshot {
    fn default() -> Self {
        Self {
            version: 1,
            revision: 0,
            records: Vec::new(),
            pending: None,
            remote_host: None,
            remote_cwd: None,
            sync_restore: false,
        }
    }
}

impl Snapshot {
    pub fn decode(bytes: &[u8]) -> io::Result<Self> {
        if bytes.len() > MAX_SNAPSHOT {
            return Err(io::Error::other("activity snapshot too large"));
        }
        let value: Self = serde_json::from_slice(bytes)?;
        if value.version != 1
            || value.records.len() > MAX_RECORDS
            || value
                .pending
                .as_ref()
                .is_some_and(|r| r.len() > MAX_RECORDS)
            || value
                .records
                .iter()
                .chain(value.pending.iter().flatten())
                .any(|s| !valid(s))
        {
            return Err(io::Error::other("invalid activity snapshot"));
        }
        Ok(value)
    }

    /// The inline viewer uses the existing context bridge, at a parser ground
    /// boundary. This transaction also lets the outer local holder retain it.
    pub fn inline_bytes(&self) -> Vec<u8> {
        self.inline_bytes_with_mode("restore")
    }

    pub fn inline_bytes_with_mode(&self, mode: &str) -> Vec<u8> {
        let tag = match mode {
            "live" => "live",
            _ => "restore",
        };
        let mut bytes =
            format!("\x1b]3008;start={SYNC};mode={tag}\x07\x1b]3008;start={SYNC};begin\x07")
                .into_bytes();
        for signal in &self.records {
            bytes.extend_from_slice(
                format!("\x1b]3008;start={};{}\x07", signal.id, signal.metadata).as_bytes(),
            );
        }
        bytes.extend_from_slice(format!("\x1b]3008;start={SYNC};end\x07").as_bytes());
        if let Some(pending) = self.pending.as_ref().filter(|pending| !pending.is_empty()) {
            bytes.extend_from_slice(
                format!("\x1b]3008;start={SYNC};mode={tag}\x07\x1b]3008;start={SYNC};begin\x07")
                    .as_bytes(),
            );
            for signal in pending {
                bytes.extend_from_slice(
                    format!("\x1b]3008;start={};{}\x07", signal.id, signal.metadata).as_bytes(),
                );
            }
            bytes.extend_from_slice(format!("\x1b]3008;start={SYNC};end\x07").as_bytes());
        }
        bytes
    }

    pub fn acknowledge(&mut self) -> bool {
        let mut changed = false;
        for signal in &mut self.records {
            changed |= acknowledge_signal(signal);
        }
        if let Some(pending) = &mut self.pending {
            for signal in pending {
                changed |= acknowledge_signal(signal);
            }
        }
        if changed {
            self.revision = self.revision.saturating_add(1);
        }
        changed
    }

    /// Canonical authoritative reduction across Tier 1 (OSC 7501 & OSC 26 TAP),
    /// Tier 2 (Socket `omgd report` / OSC 3008 Hooks), and Tier 3 (Fallback).
    ///
    /// Priority within a tier:
    /// `needsAttention` > foreground `working` > background `working` > `error` > `done` > `idle`.
    /// When both OSC 7501 and OSC 26 TAP report for the same agent, OSC 7501
    /// wins on state/attention while OSC 26 enriches metadata (`conversation`,
    /// `task_progress`, `title`).
    /// Never maps `error`/`failed` to `needsAttention` or `"Waiting for you"`.
    pub fn presentation(&self) -> Option<Presentation> {
        let mut inherited_app: Option<String> = None;
        for sig in &self.records {
            if sig.id == "omg-program-status" {
                if let Some(raw_app) = field(&sig.metadata, ':', "app") {
                    if let Some(norm) = crate::agents::normalize_id(raw_app) {
                        inherited_app = Some(norm);
                    }
                }
            }
        }
        if inherited_app.is_none() {
            for sig in &self.records {
                if sig.id == TAP {
                    if let Some(tap) = parse_tap(&sig.metadata, None) {
                        inherited_app = Some(tap.agent);
                    }
                }
            }
        }
        if inherited_app.is_none() {
            for sig in &self.records {
                if sig.id.starts_with("omg-agent-") {
                    if let Some(raw_app) = field(&sig.metadata, ';', "omg_agent") {
                        if let Some(norm) = crate::agents::normalize_id(raw_app) {
                            inherited_app = Some(norm);
                        }
                    }
                }
            }
        }

        struct TapMetadata {
            agent: String,
            session_id: Option<String>,
            task_progress: Option<String>,
            title: Option<String>,
        }

        let mut best_t1_7501: Option<Presentation> = None;
        let mut best_t1_tap: Option<Presentation> = None;
        let mut tap_meta_by_agent: Vec<TapMetadata> = Vec::new();
        let mut best_t2: Option<Presentation> = None;
        let mut best_t3: Option<Presentation> = None;

        for signal in &self.records {
            if signal.id == TAP {
                if let Some(tap) = parse_tap(&signal.metadata, inherited_app.as_deref()) {
                    tap_meta_by_agent.retain(|meta| meta.agent != tap.agent);
                    tap_meta_by_agent.push(TapMetadata {
                        agent: tap.agent.clone(),
                        session_id: tap.session_id.clone(),
                        task_progress: tap.task_progress.clone(),
                        title: tap.title.clone(),
                    });
                    let item = tap.into_presentation();
                    if best_t1_tap
                        .as_ref()
                        .is_none_or(|prev| presentation_rank(&item) <= presentation_rank(prev))
                    {
                        best_t1_tap = Some(item);
                    }
                }
                continue;
            }
            let Some(item) = parse_presentation(signal, inherited_app.as_deref()) else {
                continue;
            };
            let slot = match item.tier {
                Tier::ProgramStatus => &mut best_t1_7501,
                Tier::Hook => &mut best_t2,
                Tier::Fallback => &mut best_t3,
            };
            if slot
                .as_ref()
                .is_none_or(|prev| presentation_rank(&item) <= presentation_rank(prev))
            {
                *slot = Some(item);
            }
        }

        // Enrich OSC 7501 with same-agent TAP metadata (`SessionId`, `TaskProgress`, `Title`).
        if let Some(p7501) = best_t1_7501.as_mut() {
            if let Some(meta) = tap_meta_by_agent
                .iter()
                .find(|meta| meta.agent == p7501.agent)
            {
                if p7501.conversation.is_none() {
                    p7501.conversation = meta.session_id.clone();
                }
                if p7501.task_progress.is_none() {
                    p7501.task_progress = meta.task_progress.clone();
                }
                if p7501.title.is_none() {
                    p7501.title = meta.title.clone();
                }
            }
        }

        // Tier 1 arbitration: same-agent OSC 7501 wins on state/attention over OSC 26 TAP.
        let best_t1 = match (best_t1_7501, best_t1_tap) {
            (Some(p7501), Some(ptap)) => {
                if p7501.agent == ptap.agent
                    || presentation_rank(&p7501) <= presentation_rank(&ptap)
                {
                    Some(p7501)
                } else {
                    Some(ptap)
                }
            }
            (Some(p7501), None) => Some(p7501),
            (None, Some(ptap)) => Some(ptap),
            (None, None) => None,
        };

        // Strict authority hierarchy: Tier 1 > Tier 2 > Tier 3.
        // Exception: if Tier 1 only reports generic `working` while Tier 2 Hook
        // reports active `needsAttention` on the same agent (for CLIs whose
        // permission prompt comes via Hook rather than OSC 7501 `blocked` / TAP),
        // surface the Tier 2 `needsAttention`.
        if let Some(t1) = &best_t1 {
            if t1.state != "idle" {
                if t1.state == "working" {
                    if let Some(t2) = &best_t2 {
                        if t2.state == "needsAttention" && t2.agent == t1.agent {
                            return Some(t2.clone());
                        }
                    }
                }
                return Some(t1.clone());
            }
        }
        if let Some(t2) = &best_t2 {
            if t2.state != "idle" {
                return Some(t2.clone());
            }
        }
        if let Some(t3) = &best_t3 {
            let shadowed_by_higher_tier = best_t1.as_ref().is_some_and(|t1| t1.agent == t3.agent)
                || best_t2.as_ref().is_some_and(|t2| t2.agent == t3.agent);
            if !shadowed_by_higher_tier && t3.state != "idle" {
                return Some(t3.clone());
            }
        }
        best_t1.or(best_t2).or(best_t3)
    }
}

fn presentation_rank(p: &Presentation) -> u8 {
    match p.state {
        "needsAttention" => 0,
        "working" if !p.background => 1,
        "working" => 2,
        "error" => 3,
        "done" => 4,
        _ => 5,
    }
}

fn decode_base64_utf8(raw: &str) -> Option<String> {
    if raw.is_empty() || raw.len() > 2800 {
        return None;
    }
    let rem = raw.len() % 4;
    let decoded = if rem == 0 {
        STANDARD.decode(raw).ok()?
    } else {
        let mut padded = String::with_capacity(raw.len() + (4 - rem));
        padded.push_str(raw);
        for _ in 0..(4 - rem) {
            padded.push('=');
        }
        STANDARD.decode(padded).ok()?
    };
    let text = String::from_utf8(decoded).ok()?;
    if text
        .chars()
        .all(|c| !c.is_control() && !('\u{007f}'..='\u{009f}').contains(&c))
    {
        Some(text)
    } else {
        None
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct TapPayload {
    pub agent: String,
    pub state: &'static str,
    pub attention: Option<&'static str>,
    pub session_id: Option<String>,
    pub task_progress: Option<String>,
    pub title: Option<String>,
}

impl TapPayload {
    fn into_presentation(self) -> Presentation {
        let message = self
            .title
            .clone()
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| default_message(self.state, self.attention).to_owned());
        Presentation {
            tier: Tier::ProgramStatus,
            agent: self.agent,
            state: self.state,
            attention: self.attention,
            message,
            background: false,
            conversation: self.session_id,
            task_progress: self.task_progress,
            title: self.title,
        }
    }
}

fn valid_tap_session_id(raw: &str) -> bool {
    !raw.is_empty()
        && raw.len() <= 128
        && !raw.starts_with('-')
        && raw
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
}

fn is_printable_tap_text(raw: &str, max_bytes: usize) -> bool {
    !raw.is_empty()
        && raw.len() <= max_bytes
        && raw
            .chars()
            .all(|c| !c.is_control() && !('\u{007f}'..='\u{009f}').contains(&c))
}

fn resolve_tap_agent(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() || trimmed.len() > 64 {
        return None;
    }
    if let Some(spec) = crate::agents::resolve(trimmed) {
        return Some(spec.id.to_owned());
    }
    if let Some(spec) = crate::agents::AGENTS
        .iter()
        .find(|spec| spec.display_name.eq_ignore_ascii_case(trimmed))
    {
        return Some(spec.id.to_owned());
    }
    if trimmed.contains(char::is_whitespace) {
        let hyphenated = trimmed.split_whitespace().collect::<Vec<_>>().join("-");
        if let Some(spec) = crate::agents::resolve(&hyphenated) {
            return Some(spec.id.to_owned());
        }
    }
    crate::agents::normalize_id(trimmed)
}

/// Parses an OSC 26 (Terminal Agent Protocol / TAP) payload with strict bounds
/// and validation. `ProjectFolder` is intentionally ignored for FS/cwd authority.
pub(crate) fn parse_tap(metadata: &str, fallback_app: Option<&str>) -> Option<TapPayload> {
    if metadata.is_empty()
        || metadata.len() > TAP_MAX_BYTES
        || !metadata
            .chars()
            .all(|c| !c.is_control() && !('\u{007f}'..='\u{009f}').contains(&c))
    {
        return None;
    }

    let mut code_agent: Option<String> = None;
    let mut saw_code_agent = false;
    let mut state_and_attention: Option<(&'static str, Option<&'static str>)> = None;
    let mut session_id: Option<String> = None;
    let mut task_progress: Option<String> = None;
    let mut title: Option<String> = None;

    for part in metadata.split(';') {
        let trimmed_part = part.trim();
        if trimmed_part.is_empty() {
            continue;
        }
        let (raw_key, raw_val) = trimmed_part.split_once('=')?;
        let key = raw_key.trim();
        let val = raw_val.trim();
        if key.is_empty() || key.len() > 32 {
            return None;
        }
        if key.eq_ignore_ascii_case("CodeAgent") {
            saw_code_agent = true;
            code_agent = Some(resolve_tap_agent(val)?);
        } else if key.eq_ignore_ascii_case("Status") {
            let mapped = match val.to_ascii_lowercase().as_str() {
                "running" => ("working", None),
                "awaiting-input" => ("needsAttention", Some("question")),
                "awaiting-approval" => ("needsAttention", Some("permission")),
                "idle" => ("idle", None),
                "error" => ("error", None),
                "done" | "completed" => ("done", None),
                _ => return None,
            };
            state_and_attention = Some(mapped);
        } else if key.eq_ignore_ascii_case("SessionId") {
            if val.is_empty() {
                session_id = None;
            } else if valid_tap_session_id(val) {
                session_id = Some(val.to_owned());
            } else {
                return None;
            }
        } else if key.eq_ignore_ascii_case("TaskProgress") {
            if val.is_empty() {
                task_progress = None;
            } else if is_printable_tap_text(val, 32) {
                task_progress = Some(val.to_owned());
            } else {
                return None;
            }
        } else if key.eq_ignore_ascii_case("Title") {
            if val.is_empty() {
                title = None;
            } else if is_printable_tap_text(val, 256) {
                title = Some(val.to_owned());
            } else {
                return None;
            }
        } else if key.eq_ignore_ascii_case("ProjectFolder") {
            // Untrusted terminal output must never establish cwd or FS authority.
            continue;
        }
    }

    let (state, attention) = state_and_attention?;
    let agent = if saw_code_agent {
        code_agent?
    } else {
        fallback_app.and_then(resolve_tap_agent)?
    };

    Some(TapPayload {
        agent,
        state,
        attention,
        session_id,
        task_progress,
        title,
    })
}

fn parse_presentation(signal: &Signal, fallback_app: Option<&str>) -> Option<Presentation> {
    if signal.id == TAP {
        return parse_tap(&signal.metadata, fallback_app).map(TapPayload::into_presentation);
    }
    let native = signal.id == "omg-program-status";
    if native {
        let agent = field(&signal.metadata, ':', "app")
            .and_then(crate::agents::normalize_id)
            .or_else(|| fallback_app.map(str::to_owned))?;
        let state = match field(&signal.metadata, ':', "state")? {
            "working" => "working",
            "blocked" => "needsAttention",
            "error" => "error",
            "done" => "done",
            "idle" => "idle",
            _ => return None,
        };
        let attention = if state == "needsAttention" {
            match field(&signal.metadata, ':', "kind") {
                Some("permission") => Some("permission"),
                Some("question") => Some("question"),
                _ => None,
            }
        } else {
            None
        };
        let background = field(&signal.metadata, ':', "phase") == Some("background");
        let message = field(&signal.metadata, ':', "msg")
            .and_then(decode_base64_utf8)
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| default_message(state, attention).to_owned());
        return Some(Presentation {
            tier: Tier::ProgramStatus,
            agent,
            state,
            attention,
            message,
            background,
            conversation: None,
            task_progress: None,
            title: None,
        });
    }
    if !signal.id.starts_with("omg-agent-") || signal.id == SYNC {
        return None;
    }
    let agent = field(&signal.metadata, ';', "omg_agent").and_then(crate::agents::normalize_id)?;
    let state = match field(&signal.metadata, ';', "omg_state")? {
        "working" | "processing" | "active" => "working",
        "waiting" | "awaiting" | "blocked" | "needsAttention" => "needsAttention",
        "error" | "failed" => "error",
        "done" | "completed" => "done",
        "idle" => "idle",
        _ => return None,
    };
    let tier = match field(&signal.metadata, ';', "omg_tier") {
        Some("fallback") => Tier::Fallback,
        _ => Tier::Hook,
    };
    let attention = if state == "needsAttention" {
        match field(&signal.metadata, ';', "omg_attention") {
            Some("permission") => Some("permission"),
            Some("question") => Some("question"),
            _ => None,
        }
    } else {
        None
    };
    let background = field(&signal.metadata, ';', "omg_phase") == Some("background");
    let conversation = field(&signal.metadata, ';', "omg_conversation")
        .map(decode_percent)
        .filter(|s| !s.is_empty());
    let message = field(&signal.metadata, ';', "message")
        .map(decode_percent)
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| default_message(state, attention).to_owned());
    Some(Presentation {
        tier,
        agent,
        state,
        attention,
        message,
        background,
        conversation,
        task_progress: None,
        title: None,
    })
}

fn default_message(state: &str, attention: Option<&str>) -> &'static str {
    match state {
        "working" => "Working",
        "needsAttention" => {
            if attention == Some("permission") {
                "Waiting for permission"
            } else {
                "Waiting for you"
            }
        }
        "error" => "Error",
        "done" => "Done",
        _ => "",
    }
}

fn rewrite_signal_state(
    signal: &mut Signal,
    target_state: &str,
    new_message: Option<&str>,
) -> bool {
    if signal.id == "omg-program-status" {
        if field(&signal.metadata, ':', "state") == Some(target_state) && new_message.is_none() {
            return false;
        }
        let mut rewritten = Vec::new();
        for part in signal.metadata.split(':') {
            let Some((key, _)) = part.trim().split_once('=') else {
                rewritten.push(part.to_owned());
                continue;
            };
            match key.trim() {
                "state" => rewritten.push(format!("state={target_state}")),
                "msg" | "progress" | "kind" => {}
                _ => rewritten.push(part.to_owned()),
            }
        }
        if let Some(msg) = new_message {
            let encoded = STANDARD.encode(msg.as_bytes());
            rewritten.push(format!("msg={encoded}"));
        }
        signal.metadata = rewritten.join(":");
        return true;
    }
    if signal.id == TAP {
        let target_tap_status = match target_state {
            "working" => "running",
            "idle" => "idle",
            "error" => "error",
            "done" => "done",
            other => other,
        };
        if signal_effective_state(signal) == Some(target_state) && new_message.is_none() {
            return false;
        }
        let mut rewritten = Vec::new();
        let mut replaced_status = false;
        for part in signal.metadata.split(';') {
            let trimmed = part.trim();
            if trimmed.is_empty() {
                continue;
            }
            let Some((key, _)) = trimmed.split_once('=') else {
                rewritten.push(trimmed.to_owned());
                continue;
            };
            if key.trim().eq_ignore_ascii_case("Status") {
                rewritten.push(format!("Status={target_tap_status}"));
                replaced_status = true;
            } else if key.trim().eq_ignore_ascii_case("TaskProgress") && target_tap_status == "idle"
            {
                // Drop stale progress when acknowledging to idle.
            } else if key.trim().eq_ignore_ascii_case("Title") && new_message.is_some() {
                // Replaced below with new_message.
            } else {
                rewritten.push(trimmed.to_owned());
            }
        }
        if !replaced_status {
            rewritten.push(format!("Status={target_tap_status}"));
        }
        if let Some(msg) = new_message {
            rewritten.push(format!("Title={msg}"));
        }
        signal.metadata = rewritten.join(";");
        return true;
    }
    if signal.id.starts_with("omg-agent-") && signal.id != SYNC {
        if field(&signal.metadata, ';', "omg_state") == Some(target_state) && new_message.is_none()
        {
            return false;
        }
        let mut rewritten = Vec::new();
        for part in signal.metadata.split(';') {
            let Some((key, _)) = part.trim().split_once('=') else {
                rewritten.push(part.to_owned());
                continue;
            };
            match key.trim() {
                "omg_state" => rewritten.push(format!("omg_state={target_state}")),
                "message" | "omg_phase" | "progress" | "omg_attention" | "omg_event" => {}
                _ => rewritten.push(part.to_owned()),
            }
        }
        if let Some(msg) = new_message {
            rewritten.push(format!("message={}", encode_percent(msg)));
        }
        signal.metadata = rewritten.join(";");
        return true;
    }
    false
}

fn acknowledge_signal(signal: &mut Signal) -> bool {
    if signal.id == "omg-program-status" {
        if !matches!(
            field(&signal.metadata, ':', "state"),
            Some("done" | "error")
        ) {
            return false;
        }
        return rewrite_signal_state(signal, "idle", None);
    }
    if signal.id == TAP {
        if !matches!(signal_effective_state(signal), Some("done" | "error")) {
            return false;
        }
        return rewrite_signal_state(signal, "idle", None);
    }
    if signal.id.starts_with("omg-agent-") && signal.id != SYNC {
        if !matches!(
            field(&signal.metadata, ';', "omg_state"),
            Some("done" | "completed" | "error" | "failed")
        ) {
            return false;
        }
        return rewrite_signal_state(signal, "idle", None);
    }
    false
}

fn signal_effective_state(signal: &Signal) -> Option<&'static str> {
    if signal.id == "omg-program-status" {
        match field(&signal.metadata, ':', "state")? {
            "working" => Some("working"),
            "blocked" => Some("needsAttention"),
            "error" => Some("error"),
            "done" => Some("done"),
            "idle" => Some("idle"),
            _ => None,
        }
    } else if signal.id == TAP {
        parse_tap(&signal.metadata, Some("unknown")).map(|t| t.state)
    } else if signal.id.starts_with("omg-agent-") && signal.id != SYNC {
        match field(&signal.metadata, ';', "omg_state")? {
            "working" | "processing" | "active" => Some("working"),
            "waiting" | "awaiting" | "blocked" | "needsAttention" => Some("needsAttention"),
            "error" | "failed" => Some("error"),
            "done" | "completed" => Some("done"),
            "idle" => Some("idle"),
            _ => None,
        }
    } else {
        None
    }
}

#[derive(Clone)]
struct Record {
    signal: Signal,
    key: String,
    remote: bool,
    // Only meaningful on the machine actually owning this process.
    owner: Option<(i32, bool)>,
    verified_session: bool,
    attention_locked: bool,
    interrupted: bool,
    saw_active_job: bool,
    terminal_revision: u64,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct InputOutcome {
    pub activity_changed: bool,
    pub user_interaction: bool,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct CsiScan {
    params: [u32; 4],
    base_key: u32,
    event_type: u8,
    param_idx: u8,
    sub_idx: u8,
    has_digit: bool,
    private: bool,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
enum InputScanState {
    #[default]
    Ground,
    Esc,
    Csi(CsiScan),
    Osc,
    OscEsc,
    StrSeq,
    StrEsc,
    Ss3,
    X10Mouse(u8),
}

#[derive(Clone, Copy, Debug, Default)]
struct InputTracker {
    state: InputScanState,
    in_paste: bool,
}

#[derive(Clone, Default)]
pub struct Osc133Scanner {
    state: Osc133State,
    buf: [u8; 24],
    len: usize,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
enum Osc133State {
    #[default]
    Ground,
    Esc,
    Osc,
    OscEsc,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Osc133Event {
    PromptStart,
    CommandDone(Option<i32>),
}

impl Osc133Scanner {
    pub fn in_sequence(&self) -> bool {
        self.state != Osc133State::Ground
    }

    pub fn step(&mut self, byte: u8) -> Option<Osc133Event> {
        match self.state {
            Osc133State::Ground => {
                if byte == 0x1b {
                    self.state = Osc133State::Esc;
                }
                None
            }
            Osc133State::Esc => {
                if byte == b']' {
                    self.state = Osc133State::Osc;
                    self.len = 0;
                } else if byte != 0x1b {
                    self.state = Osc133State::Ground;
                }
                None
            }
            Osc133State::Osc => {
                if byte == 0x07 {
                    self.state = Osc133State::Ground;
                    return self.finish();
                }
                if byte == 0x1b {
                    self.state = Osc133State::OscEsc;
                    return None;
                }
                if byte < 0x20 {
                    self.state = Osc133State::Ground;
                    self.len = 0;
                    return None;
                }
                if self.len < self.buf.len() {
                    self.buf[self.len] = byte;
                    self.len += 1;
                    if self.len <= 4 && self.buf[..self.len] != b"133;"[..self.len] {
                        // Still consume until BEL/ST in Osc, just mark non-133 by setting len = usize::MAX
                        self.len = usize::MAX;
                    }
                }
                None
            }
            Osc133State::OscEsc => {
                self.state = Osc133State::Ground;
                if byte == b'\\' {
                    return self.finish();
                }
                if byte == b']' {
                    self.state = Osc133State::Osc;
                    self.len = 0;
                }
                None
            }
        }
    }

    fn finish(&mut self) -> Option<Osc133Event> {
        let len = self.len;
        self.len = 0;
        if len == usize::MAX || len < 5 {
            return None;
        }
        let payload = &self.buf[..len.min(self.buf.len())];
        if !payload.starts_with(b"133;") {
            return None;
        }
        match payload[4] {
            b'A' if len == 5 || payload.get(5) == Some(&b';') => Some(Osc133Event::PromptStart),
            b'D' if len == 5 => Some(Osc133Event::CommandDone(None)),
            b'D' if payload.get(5) == Some(&b';') => {
                let rest = &payload[6..];
                let end = rest.iter().position(|&b| b == b';').unwrap_or(rest.len());
                let code = std::str::from_utf8(&rest[..end])
                    .ok()
                    .and_then(|s| s.parse::<i32>().ok());
                Some(Osc133Event::CommandDone(code))
            }
            _ => None,
        }
    }
}

#[derive(Default)]
pub struct State {
    records: Vec<Record>,
    revision: u64,
    ack_up_to_revision: u64,
    pending: Option<Vec<Record>>,
    next_sync_restore: Option<bool>,
    pending_sync_restore: bool,
    last_change_sync_restore: bool,
    remote: bool,
    remote_id: Option<String>,
    remote_host: Option<String>,
    remote_cwd: Option<String>,
    input_tracker: InputTracker,
    pub(crate) osc133: Osc133Scanner,
    pub local: bool,
    pub foreground: Option<i32>,
    pub session_leader: Option<i32>,
    leader_login: Option<(i32, bool)>,
    shell_pgid: Option<i32>,
}

pub fn encode_percent(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-' | b'~') {
            out.push(byte as char);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

fn decode_percent(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(hex) = std::str::from_utf8(&bytes[i + 1..i + 3]) {
                if let Ok(byte) = u8::from_str_radix(hex, 16) {
                    out.push(byte);
                    i += 3;
                    continue;
                }
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn decode_hex(value: &str) -> Option<String> {
    if !value.len().is_multiple_of(2) || value.is_empty() {
        return None;
    }
    let mut out = Vec::with_capacity(value.len() / 2);
    let bytes = value.as_bytes();
    for chunk in bytes.chunks_exact(2) {
        let hex = std::str::from_utf8(chunk).ok()?;
        out.push(u8::from_str_radix(hex, 16).ok()?);
    }
    String::from_utf8(out).ok()
}

pub(crate) fn field<'a>(metadata: &'a str, separator: char, key: &str) -> Option<&'a str> {
    metadata
        .split(separator)
        .filter_map(|s| s.trim().split_once('='))
        .filter(|(k, _)| *k == key)
        .map(|(_, v)| v.trim())
        .next_back()
}

fn valid(signal: &Signal) -> bool {
    (signal.id.starts_with("omg-agent-") && signal.id != SYNC
        || signal.id == "omg-program-status"
        || signal.id == TAP)
        && !signal.id.is_empty()
        && signal.id.len() <= 64
        && signal
            .id
            .bytes()
            .all(|b| (32..127).contains(&b) && b != b';')
        && signal.metadata.len() <= 4096
        && signal.metadata.chars().all(|c| !c.is_control())
}

/// Queries `(ppid, uid, pgid, is_zombie)` for `pid` on macOS and Linux.
pub fn process_info(pid: i32) -> Option<(i32, u32, i32, bool)> {
    if pid <= 1 {
        return None;
    }
    #[cfg(target_os = "macos")]
    {
        extern "C" {
            fn omg_process_bsdinfo(
                pid: i32,
                ppid: *mut i32,
                uid: *mut u32,
                pgid: *mut i32,
                zombie: *mut i32,
            ) -> i32;
        }
        let (mut ppid, mut uid, mut pgid, mut zombie) = (0, 0, 0, 0);
        if unsafe { omg_process_bsdinfo(pid, &mut ppid, &mut uid, &mut pgid, &mut zombie) } == 0 {
            Some((ppid, uid, pgid, zombie != 0))
        } else {
            None
        }
    }
    #[cfg(target_os = "linux")]
    {
        use std::os::unix::fs::MetadataExt;
        let uid = std::fs::metadata(format!("/proc/{pid}")).ok()?.uid();
        let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
        let after_comm = stat.rsplit_once(')')?.1.trim_start();
        let mut parts = after_comm.split_whitespace();
        let state_ch = parts.next()?.chars().next()?;
        let ppid: i32 = parts.next()?.parse().ok()?;
        let pgid: i32 = parts.next()?.parse().ok()?;
        Some((ppid, uid, pgid, state_ch == 'Z'))
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        let pgid = unsafe { libc::getpgid(pid) };
        if pgid <= 1 {
            return None;
        }
        Some((1, unsafe { libc::geteuid() }, pgid, false))
    }
}

pub fn is_descendant_of(pid: i32, ancestor: i32) -> bool {
    if pid <= 1 || ancestor <= 1 {
        return false;
    }
    if pid == ancestor {
        return true;
    }
    let mut current = pid;
    for _ in 0..32 {
        let Some((ppid, _, _, _)) = process_info(current) else {
            return false;
        };
        if ppid == ancestor {
            return true;
        }
        if ppid <= 1 || ppid == current {
            return false;
        }
        current = ppid;
    }
    false
}

fn exe_basename(arg0: &str) -> &str {
    arg0.rsplit('/')
        .next()
        .unwrap_or(arg0)
        .trim_start_matches('-')
}

fn is_shell_name(name: &str) -> bool {
    matches!(
        name,
        "sh" | "bash"
            | "zsh"
            | "fish"
            | "dash"
            | "ksh"
            | "mksh"
            | "oksh"
            | "tcsh"
            | "csh"
            | "nu"
            | "nushell"
            | "elvish"
            | "xonsh"
            | "pwsh"
    )
}

pub(crate) fn is_interactive_shell_argv(argv: &[String]) -> bool {
    let Some(first) = argv.first() else {
        return false;
    };
    if !is_shell_name(exe_basename(first)) {
        return false;
    }
    let mut iter = argv[1..].iter();
    while let Some(arg) = iter.next() {
        if arg == "--" || arg == "-" {
            return iter.next().is_none();
        }
        if matches!(arg.as_str(), "--command" | "--commands" | "-c")
            || arg.starts_with("--command=")
            || arg.starts_with("--commands=")
        {
            return false;
        }
        if matches!(
            arg.as_str(),
            "--rcfile"
                | "--init-file"
                | "--init-command"
                | "-C"
                | "-o"
                | "+o"
                | "--config"
                | "--env-config"
                | "--plugin-config"
        ) {
            let _ = iter.next();
            continue;
        }
        if arg.starts_with("--") {
            continue;
        }
        if arg.len() > 1 && arg.starts_with('-') {
            if arg[1..].contains('c') {
                return false;
            }
            continue;
        }
        if arg.len() > 1 && arg.starts_with('+') {
            continue;
        }
        return false;
    }
    true
}

pub(crate) fn is_interactive_shell_pid(pid: i32) -> bool {
    if pid <= 1 {
        return false;
    }
    crate::location::process_argv(pid)
        .as_deref()
        .is_some_and(is_interactive_shell_argv)
}

pub(crate) fn is_login_wrapper(pid: i32) -> bool {
    if pid <= 1 {
        return false;
    }
    if crate::location::process_argv(pid)
        .as_deref()
        .and_then(|argv| argv.first())
        .is_some_and(|arg0| exe_basename(arg0) == "login")
    {
        return true;
    }
    crate::location::process_path(pid)
        .and_then(|p| p.file_name().and_then(|n| n.to_str()).map(str::to_owned))
        .is_some_and(|name| exe_basename(&name) == "login")
}

pub(crate) fn is_login_shell_child(pid: i32, leader: i32) -> bool {
    if pid <= 1 || leader <= 1 || pid == leader || !is_login_wrapper(leader) {
        return false;
    }
    let Some((ppid, uid, pgid, zombie)) = process_info(pid) else {
        return false;
    };
    if zombie
        || ppid != leader
        || pgid != pid
        || uid != unsafe { libc::geteuid() }
        || unsafe { libc::getsid(pid) } != leader
    {
        return false;
    }
    crate::location::process_argv(pid)
        .as_deref()
        .is_some_and(is_interactive_shell_argv)
}

/// Validates a socket `AgentEvent` sender and resolves `(owner_id, is_group, job_pgid)`.
/// Supports foreground child process groups, interactive shells (including macOS
/// `/usr/bin/login -> -/bin/zsh`), direct `exec` launches, and inherited-capability
/// daemons owned by the same effective UID.
pub fn resolve_event_owner(
    event_pid: i32,
    event_group: i32,
    explicit_owner_pid: Option<i32>,
    session_leader: i32,
    fg_pgid: i32,
) -> Option<(i32, bool, i32)> {
    if event_pid <= 1 || event_group <= 1 || session_leader <= 1 {
        return None;
    }
    let euid = unsafe { libc::geteuid() };
    let (caller_ppid, caller_uid, caller_pgid, caller_zombie) = process_info(event_pid)?;
    if caller_zombie || caller_uid != euid || caller_pgid != event_group {
        return None;
    }

    if let Some(opid) = explicit_owner_pid {
        if opid <= 1 {
            return None;
        }
        let (_, o_uid, o_pgid, o_zombie) = process_info(opid)?;
        if o_zombie || o_uid != euid {
            return None;
        }
        return Some((opid, false, o_pgid.max(session_leader)));
    }

    let in_session = unsafe { libc::getsid(event_pid) } == session_leader;

    if in_session {
        let mut chain = Vec::with_capacity(8);
        let mut current = event_pid;
        let mut reached_leader = false;
        for _ in 0..32 {
            if current == session_leader {
                reached_leader = true;
                break;
            }
            chain.push(current);
            let Some((ppid, _, _, _)) = process_info(current) else {
                break;
            };
            if ppid == session_leader {
                reached_leader = true;
                break;
            }
            if ppid <= 1 || ppid == current {
                break;
            }
            current = ppid;
        }
        chain.reverse();

        let mut shell_root = session_leader;
        let mut job_idx = 0usize;
        if reached_leader && !chain.is_empty() && is_login_shell_child(chain[0], session_leader) {
            shell_root = chain[0];
            job_idx = 1;
        }

        if reached_leader {
            if let Some(&p1) = chain.get(job_idx) {
                if p1 != event_pid {
                    let p1_pgid = process_info(p1)
                        .map(|(_, _, pg, _)| pg)
                        .unwrap_or(event_group);
                    if p1_pgid > 1
                        && p1_pgid != session_leader
                        && p1_pgid != shell_root
                        && fg_pgid > 1
                        && (fg_pgid == p1_pgid || is_descendant_of(fg_pgid, p1))
                    {
                        return Some((p1_pgid, true, p1_pgid));
                    }
                    return Some((shell_root, true, shell_root));
                }
                let job = if fg_pgid > 1 { fg_pgid } else { shell_root };
                return Some((shell_root, true, job));
            }
            return Some((shell_root, true, shell_root));
        }

        if fg_pgid > 1 && fg_pgid != session_leader {
            return Some((fg_pgid, true, fg_pgid));
        }
        return Some((session_leader, true, session_leader));
    }

    // Same-UID detached daemon (e.g. `opencode serve` with inherited capability).
    // Walk `ppid` upward past ephemeral `/bin/sh` hook wrappers to the root daemon PID.
    if caller_ppid > 1 {
        if let Some((mut next_ppid, p_uid, mut root_pgid, p_zombie)) = process_info(caller_ppid) {
            if !p_zombie && p_uid == euid {
                let mut root_pid = caller_ppid;
                for _ in 0..16 {
                    if next_ppid <= 1
                        || next_ppid == root_pid
                        || unsafe { libc::getsid(root_pid) } == root_pid
                    {
                        break;
                    }
                    let Some((grand_ppid, g_uid, g_pgid, g_zombie)) = process_info(next_ppid)
                    else {
                        break;
                    };
                    if g_zombie || g_uid != euid {
                        break;
                    }
                    root_pid = next_ppid;
                    root_pgid = g_pgid;
                    next_ppid = grand_ppid;
                }
                let job = if fg_pgid > 1 { fg_pgid } else { root_pgid };
                return Some((root_pid, false, job));
            }
        }
    }
    None
}

fn owner_alive_in_session(pid: i32, group: bool, session: i32, verified_session: bool) -> bool {
    if pid <= 1 {
        return false;
    }
    if !group {
        let Some((_, _, _, zombie)) = process_info(pid) else {
            return false;
        };
        if zombie {
            return false;
        }
        if verified_session {
            return unsafe { libc::kill(pid, 0) == 0 }
                || io::Error::last_os_error().raw_os_error() == Some(libc::EPERM);
        }
        return unsafe { libc::getsid(pid) == session && libc::kill(pid, 0) == 0 };
    }

    // Process-group (`pgid`) liveness: original group leader `pid` may have exited
    // (`getsid(pid) == -1`) while child processes in `-pid` remain alive!
    let kill_ok = unsafe { libc::kill(-pid, 0) == 0 }
        || io::Error::last_os_error().raw_os_error() == Some(libc::EPERM);
    if !kill_ok {
        return false;
    }

    #[cfg(target_os = "macos")]
    {
        extern "C" {
            fn omg_group_pids(pgid: i32, pids: *mut i32, capacity: usize) -> i32;
        }
        let mut pids = [0i32; 256];
        let count = unsafe { omg_group_pids(pid, pids.as_mut_ptr(), pids.len()) };
        if count > 0 {
            for &member in &pids[..(count as usize).min(pids.len())] {
                if member <= 1 {
                    continue;
                }
                if let Some((_, _, _, zombie)) = process_info(member) {
                    if !zombie && unsafe { libc::getsid(member) == session } {
                        return true;
                    }
                } else if unsafe { libc::getsid(member) == session }
                    && (unsafe { libc::kill(member, 0) == 0 }
                        || io::Error::last_os_error().raw_os_error() == Some(libc::EPERM))
                {
                    // Setuid-root wrappers such as `/usr/bin/login` refuse unprivileged
                    // `PROC_PIDTBSDINFO` while remaining live in `session`.
                    return true;
                }
            }
            return false;
        }
    }

    #[cfg(target_os = "linux")]
    {
        if let Some((_, _, _, zombie)) = process_info(pid) {
            if !zombie && unsafe { libc::getsid(pid) == session } {
                return true;
            }
        }
        if let Ok(entries) = std::fs::read_dir("/proc") {
            for entry in entries.flatten().take(8192) {
                let Some(member) = entry
                    .file_name()
                    .to_str()
                    .and_then(|s| s.parse::<i32>().ok())
                else {
                    continue;
                };
                if let Some((_, _, pgid, zombie)) = process_info(member) {
                    if !zombie && pgid == pid && unsafe { libc::getsid(member) == session } {
                        return true;
                    }
                }
            }
            return false;
        }
    }

    unsafe { libc::getsid(pid) == session }
}

fn inherit_native_app(records: &[Record], key: &str, metadata: &str) -> String {
    if field(metadata, ':', "app").is_some_and(|v| !v.is_empty()) {
        return metadata.to_owned();
    }
    let mut candidate: Option<String> = None;

    // 1. Exact key match in existing OSC 7501 records.
    for r in records.iter().rev() {
        if r.signal.id == "omg-program-status" && r.key == key {
            if let Some(app) = field(&r.signal.metadata, ':', "app").filter(|a| !a.is_empty()) {
                candidate = Some(app.to_owned());
                break;
            }
        }
    }
    // 2. Parent namespace walk (`a/b/c` -> `a/b` -> `a` -> `""`).
    if candidate.is_none() && !key.is_empty() {
        let mut prefix = key;
        while let Some((parent, _)) = prefix.rsplit_once('/') {
            if let Some(app) = records.iter().rev().find_map(|r| {
                (r.signal.id == "omg-program-status" && r.key == parent)
                    .then(|| field(&r.signal.metadata, ':', "app"))
                    .flatten()
                    .filter(|a| !a.is_empty())
            }) {
                candidate = Some(app.to_owned());
                break;
            }
            prefix = parent;
        }
    }
    // 3. Root `id=""` or sole active OSC 7501 agent.
    if candidate.is_none() {
        candidate = records
            .iter()
            .rev()
            .find_map(|r| {
                (r.signal.id == "omg-program-status" && r.key.is_empty())
                    .then(|| field(&r.signal.metadata, ':', "app"))
                    .flatten()
                    .filter(|a| !a.is_empty())
                    .map(str::to_owned)
            })
            .or_else(|| {
                let mut unique: Option<String> = None;
                for r in records {
                    if r.signal.id == "omg-program-status" {
                        if let Some(app) = field(&r.signal.metadata, ':', "app")
                            .and_then(crate::agents::normalize_id)
                        {
                            match &unique {
                                None => unique = Some(app),
                                Some(prev) if prev == &app => {}
                                Some(_) => return None,
                            }
                        }
                    }
                }
                unique
            });
    }
    // 4. Sole active Hook agent in the same session.
    if candidate.is_none() {
        let mut unique: Option<String> = None;
        for r in records {
            if r.signal.id.starts_with("omg-agent-") {
                if let Some(app) = field(&r.signal.metadata, ';', "omg_agent")
                    .and_then(crate::agents::normalize_id)
                {
                    match &unique {
                        None => unique = Some(app),
                        Some(prev) if prev == &app => {}
                        Some(_) => {
                            unique = None;
                            break;
                        }
                    }
                }
            }
        }
        candidate = unique;
    }

    if let Some(app) = candidate {
        if metadata.len() + 5 + app.len() <= 4087 {
            return format!("{metadata}:app={app}");
        }
    }
    metadata.to_owned()
}

fn inherit_tap_agent(records: &[Record], metadata: &str) -> String {
    let has_code_agent = metadata.split(';').any(|part| {
        part.trim().split_once('=').is_some_and(|(k, v)| {
            k.trim().eq_ignore_ascii_case("CodeAgent") && !v.trim().is_empty()
        })
    });
    if has_code_agent {
        return metadata.to_owned();
    }
    let mut unique: Option<String> = None;
    for r in records {
        let app = if r.signal.id == "omg-program-status" {
            field(&r.signal.metadata, ':', "app").and_then(crate::agents::normalize_id)
        } else if r.signal.id == TAP {
            parse_tap(&r.signal.metadata, None).map(|t| t.agent)
        } else if r.signal.id.starts_with("omg-agent-") {
            field(&r.signal.metadata, ';', "omg_agent").and_then(crate::agents::normalize_id)
        } else {
            None
        };
        if let Some(app) = app {
            match &unique {
                None => unique = Some(app),
                Some(prev) if prev == &app => {}
                Some(_) => {
                    unique = None;
                    break;
                }
            }
        }
    }
    if let Some(app) = unique {
        if metadata.len() + 11 + app.len() <= TAP_MAX_BYTES {
            return format!("{metadata};CodeAgent={app}");
        }
    }
    metadata.to_owned()
}

impl State {
    pub fn revision(&self) -> u64 {
        self.revision
    }
    pub fn ack_up_to_revision(&self) -> u64 {
        self.ack_up_to_revision
    }
    pub fn take_last_change_sync_restore(&mut self) -> bool {
        std::mem::take(&mut self.last_change_sync_restore)
    }
    pub fn remote_host(&self) -> Option<&str> {
        self.remote_host.as_deref()
    }
    pub fn remote_cwd(&self) -> Option<&str> {
        self.remote_cwd.as_deref()
    }
    pub fn replace(&mut self, snapshot: Snapshot) {
        self.records.clear();
        self.pending = None;
        self.remote_host = snapshot.remote_host;
        self.remote_cwd = snapshot.remote_cwd;
        self.remote = self.remote_host.is_some() || self.remote_cwd.is_some();
        for signal in snapshot.records {
            self.consume(false, &signal.id, &signal.metadata);
        }
        if let Some(pending) = snapshot.pending {
            self.consume(false, SYNC, "begin");
            for signal in pending {
                self.consume(false, &signal.id, &signal.metadata);
            }
        }
        self.revision = snapshot.revision;
        self.last_change_sync_restore = false;
    }
    pub fn snapshot(&self) -> Snapshot {
        Snapshot {
            version: 1,
            revision: self.revision,
            records: self.records.iter().map(|r| r.signal.clone()).collect(),
            pending: self
                .pending
                .as_ref()
                .map(|r| r.iter().map(|r| r.signal.clone()).collect()),
            remote_host: self.remote_host.clone(),
            remote_cwd: self.remote_cwd.clone(),
            sync_restore: false,
        }
    }
    pub fn presentation(&self) -> Option<Presentation> {
        self.snapshot().presentation()
    }

    /// Feeds a validated socket `omgd report` event directly into the authoritative engine.
    #[allow(clippy::too_many_arguments)]
    pub fn consume_report(
        &mut self,
        agent_raw: &str,
        state: &str,
        owner_id: i32,
        owner_is_group: bool,
        local_scope: bool,
        conversation_id: Option<&str>,
        cwd: Option<&str>,
        context_id: Option<&str>,
        attention: Option<&str>,
        phase: Option<&str>,
        message: Option<&str>,
        tier: Option<&str>,
        event_kind: Option<&str>,
    ) -> bool {
        let Some(agent) = crate::agents::normalize_id(agent_raw) else {
            return false;
        };
        let id = if owner_id > 1 {
            format!("omg-agent-{agent}-{owner_id}")
        } else {
            format!("omg-agent-{agent}")
        };
        let before = self.revision;
        if state == "end" || state == "clear" {
            let meta = if let Some(ctx) = context_id.filter(|s| !s.is_empty()) {
                format!("omg_context={}", encode_percent(ctx))
            } else {
                String::new()
            };
            self.consume_with_verified_owner(true, &id, &meta, Some((owner_id, owner_is_group)));
            return self.revision != before;
        }
        let scope = if local_scope { "local" } else { "remote" };
        let liveness = if owner_is_group { "pgid" } else { "pid" };
        let mut parts = vec![
            "type=app".to_owned(),
            format!("omg_agent={agent}"),
            format!("omg_scope={scope}"),
            format!("omg_liveness={liveness}"),
            format!("omg_state={state}"),
        ];
        if let Some(att) = attention.filter(|a| matches!(*a, "permission" | "question")) {
            parts.push(format!("omg_attention={att}"));
        }
        if let Some(ph) = phase.filter(|p| matches!(*p, "foreground" | "background")) {
            parts.push(format!("omg_phase={ph}"));
        }
        if let Some(conv) = conversation_id.filter(|c| !c.is_empty() && c.len() <= 128) {
            parts.push(format!("omg_conversation={}", encode_percent(conv)));
        }
        if let Some(dir) = cwd.filter(|d| d.starts_with('/') && d.len() <= 4096) {
            parts.push(format!("omg_cwd={}", encode_percent(dir)));
        }
        if let Some(ctx) = context_id.filter(|c| !c.is_empty() && c.len() <= 128) {
            parts.push(format!("omg_context={}", encode_percent(ctx)));
        }
        if let Some(msg) = message.filter(|m| !m.is_empty()) {
            let truncated: String = msg.chars().take(256).collect();
            parts.push(format!("message={}", encode_percent(&truncated)));
        }
        if tier == Some("fallback") {
            parts.push("omg_tier=fallback".to_owned());
        }
        if let Some(ev) = event_kind.filter(|e| !e.is_empty() && e.len() <= 32) {
            parts.push(format!("omg_event={}", encode_percent(ev)));
        }
        let metadata = parts.join(";");
        self.consume_with_verified_owner(false, &id, &metadata, Some((owner_id, owner_is_group)));
        self.revision != before
    }

    pub fn consume(&mut self, ended: bool, id: &str, metadata: &str) {
        self.consume_with_verified_owner(ended, id, metadata, None);
    }

    fn consume_with_verified_owner(
        &mut self,
        ended: bool,
        id: &str,
        metadata: &str,
        explicit_verified_owner: Option<(i32, bool)>,
    ) {
        if id == SYNC {
            if metadata == "mode=live" || metadata == "mode=restore" {
                self.next_sync_restore = Some(metadata != "mode=live");
                return;
            }
            let is_begin = metadata == "begin" || metadata.starts_with("begin;");
            let is_end = metadata == "end" || metadata.starts_with("end;");
            if is_begin {
                self.pending = Some(Vec::new());
                self.pending_sync_restore = if metadata.contains("mode=") {
                    field(metadata, ';', "mode") != Some("live")
                } else {
                    self.next_sync_restore.take().unwrap_or(true)
                };
            } else if is_end {
                let end_is_restore = if metadata.contains("mode=") {
                    field(metadata, ';', "mode") != Some("live")
                } else {
                    self.pending_sync_restore
                };
                if let Some(records) = self.pending.take() {
                    self.records = records;
                    self.revision = self.revision.saturating_add(1);
                    self.last_change_sync_restore = end_is_restore;
                }
                self.pending_sync_restore = false;
                self.next_sync_restore = None;
            }
            return;
        }
        self.last_change_sync_restore = false;
        if id.starts_with("omg-ssh-") {
            if ended {
                if self
                    .remote_id
                    .as_deref()
                    .is_some_and(|current| current != id)
                {
                    return;
                }
                self.remote = false;
                self.remote_id = None;
                self.remote_host = None;
                self.remote_cwd = None;
                self.pending = None;
                self.clear_remote();
                self.revision = self.revision.saturating_add(1);
            } else {
                self.remote = true;
                self.remote_id = Some(id.into());
                if let Some(host) = field(metadata, ';', "targethost")
                    .map(decode_percent)
                    .filter(|s| !s.is_empty() && s.len() <= 256)
                {
                    self.remote_host = Some(host);
                }
                if let Some(cwd) = field(metadata, ';', "cwdhex")
                    .and_then(decode_hex)
                    .or_else(|| field(metadata, ';', "cwd").map(decode_percent))
                    .filter(|s| (s.starts_with('/') || s.starts_with('~')) && s.len() <= 4096)
                {
                    self.remote_cwd = Some(cwd);
                }
                self.revision = self.revision.saturating_add(1);
                // Prompt cwd signals clear remote contexts. Runtime attachment
                // metadata is explicitly marked and never means shell return.
                if !id.starts_with("omg-ssh-inline-")
                    && (field(metadata, ';', "cwd").is_some()
                        || field(metadata, ';', "cwdhex").is_some())
                {
                    self.pending = None;
                    self.clear_remote();
                }
            }
            return;
        }

        let native = id == "omg-program-status";
        let tap = id == TAP;
        let tier1 = native || tap;
        let in_sync_batch = self.pending.is_some();

        let clear = native && field(metadata, ':', "state") == Some("clear");
        if ended || clear {
            let raw_key = if native {
                field(metadata, ':', "id").unwrap_or("").to_owned()
            } else if tap {
                parse_tap(metadata, None)
                    .map(|t| t.agent)
                    .unwrap_or_default()
            } else if let Some(ctx) = field(metadata, ';', "omg_context").filter(|s| !s.is_empty())
            {
                format!("{id}#{ctx}")
            } else {
                id.to_owned()
            };
            let ended_socket_agent = (!tier1 && explicit_verified_owner.is_some())
                .then(|| id.strip_prefix("omg-agent-"))
                .flatten()
                .map(|rest| {
                    rest.rsplit_once('-')
                        .and_then(|(prefix, tail)| tail.parse::<i32>().ok().map(|_| prefix))
                        .unwrap_or(rest)
                })
                .and_then(crate::agents::normalize_id);
            let records = self.pending.as_mut().unwrap_or(&mut self.records);
            let before = records.len();
            records.retain(|r| {
                if native || tap {
                    r.signal.id != id
                        || !(raw_key.is_empty()
                            || r.key == raw_key
                            || r.key.starts_with(&(raw_key.clone() + "/")))
                } else if let Some(ctx) = field(metadata, ';', "omg_context") {
                    if r.key == raw_key {
                        return false;
                    }
                    if let Some(ref target_agent) = ended_socket_agent {
                        let same_ctx = field(&r.signal.metadata, ';', "omg_context") == Some(ctx);
                        let same_pgid_agent = field(&r.signal.metadata, ';', "omg_liveness")
                            == Some("pgid")
                            && field(&r.signal.metadata, ';', "omg_agent")
                                .and_then(crate::agents::normalize_id)
                                .as_deref()
                                == Some(target_agent.as_str());
                        return !(same_ctx && same_pgid_agent);
                    }
                    true
                } else {
                    if r.signal.id == id || r.key == raw_key {
                        return false;
                    }
                    if let Some(ref target_agent) = ended_socket_agent {
                        let same_pgid_agent = field(&r.signal.metadata, ';', "omg_liveness")
                            == Some("pgid")
                            && field(&r.signal.metadata, ';', "omg_agent")
                                .and_then(crate::agents::normalize_id)
                                .as_deref()
                                == Some(target_agent.as_str());
                        return !same_pgid_agent;
                    }
                    true
                }
            });
            if records.len() != before || in_sync_batch {
                self.revision = self.revision.saturating_add(1);
            }
            return;
        }

        let (effective_metadata, raw_key, parsed_tap) = if native {
            let key = field(metadata, ':', "id").unwrap_or("").to_owned();
            let target_records = self.pending.as_deref().unwrap_or(&self.records);
            let meta = inherit_native_app(target_records, &key, metadata);
            (meta, key, None)
        } else if tap {
            let target_records = self.pending.as_deref().unwrap_or(&self.records);
            let meta = inherit_tap_agent(target_records, metadata);
            let Some(parsed) = parse_tap(&meta, None) else {
                return;
            };
            let key = parsed.agent.clone();
            (meta, key, Some(parsed))
        } else {
            let key =
                if let Some(ctx) = field(metadata, ';', "omg_context").filter(|s| !s.is_empty()) {
                    format!("{id}#{ctx}")
                } else {
                    id.to_owned()
                };
            (metadata.to_owned(), key, None)
        };

        let signal = Signal {
            id: id.into(),
            metadata: effective_metadata.clone(),
        };
        if !valid(&signal) {
            return;
        }
        if native
            && !matches!(
                field(&effective_metadata, ':', "state"),
                Some("idle" | "working" | "done" | "blocked" | "error" | "clear")
            )
        {
            return;
        }
        if !tier1 {
            let state = field(&effective_metadata, ';', "omg_state");
            if field(&effective_metadata, ';', "type") != Some("app")
                || field(&effective_metadata, ';', "omg_agent").is_none()
                || !matches!(
                    state,
                    Some(
                        "idle"
                            | "working"
                            | "processing"
                            | "active"
                            | "waiting"
                            | "awaiting"
                            | "blocked"
                            | "needsAttention"
                            | "done"
                            | "completed"
                            | "error"
                            | "failed"
                    )
                )
            {
                return;
            }
        }

        let new_state = signal_effective_state(&signal);
        let is_prompt_event =
            !tier1 && field(&effective_metadata, ';', "omg_event") == Some("prompt");
        let is_background = if native {
            field(&effective_metadata, ':', "phase") == Some("background")
        } else if tap {
            false
        } else {
            field(&effective_metadata, ';', "omg_phase") == Some("background")
        };

        let session_leader = self.session_leader;
        let local_flag = self.local;
        let self_remote = self.remote;
        let foreground = self.foreground;
        let shell_pgid = session_leader
            .filter(|&l| l > 1)
            .and_then(|l| self.resolve_shell_pgid(l));
        let in_child_fg_now = match (session_leader, foreground) {
            (Some(leader), Some(fg)) if leader > 1 => {
                fg > 1 && fg != leader && Some(fg) != shell_pgid
            }
            _ => false,
        };

        let records = self.pending.as_mut().unwrap_or(&mut self.records);

        let is_root_hook = !tier1 && field(&effective_metadata, ';', "omg_context").is_none();
        let hook_agent = (!tier1)
            .then(|| field(&effective_metadata, ';', "omg_agent"))
            .flatten()
            .and_then(crate::agents::normalize_id);
        let incoming_pgid_scoped = !tier1
            && (explicit_verified_owner.is_some_and(|(_, g)| g)
                || field(&effective_metadata, ';', "omg_liveness") == Some("pgid"));

        // Enforce `needsAttention` lock: prevent out-of-order sibling/tool `working`
        // (or background `working`) on the same Hook record from overwriting an active
        // `needsAttention` until unlocked by user input, explicit `prompt` event, or
        // resolved via `done`/`error`/`idle`/`end`.
        if !in_sync_batch && new_state == Some("working") {
            if let Some(existing) = records.iter().find(|r| {
                (r.signal.id == id && r.key == raw_key)
                    || (incoming_pgid_scoped
                        && is_root_hook
                        && r.signal.id != "omg-program-status"
                        && r.signal.id != TAP
                        && field(&r.signal.metadata, ';', "omg_context").is_none()
                        && field(&r.signal.metadata, ';', "omg_liveness") == Some("pgid")
                        && hook_agent.is_some()
                        && field(&r.signal.metadata, ';', "omg_agent")
                            .and_then(crate::agents::normalize_id)
                            == hook_agent)
            }) {
                if signal_effective_state(&existing.signal) == Some("needsAttention")
                    && ((!tier1 && existing.attention_locked && !is_prompt_event) || is_background)
                {
                    return;
                }
            }
        }

        // Cross-agent & cross-channel new-turn superseding: when a new live foreground
        // `working` turn begins in this pane, supersede stale prior-turn `done`/`error`
        // across all records regardless of agent or channel (and for background `working`,
        // across channels or sibling records of the same agent).
        if !in_sync_batch && new_state == Some("working") {
            let incoming_agent = if native {
                field(&effective_metadata, ':', "app").and_then(crate::agents::normalize_id)
            } else if let Some(ref parsed) = parsed_tap {
                Some(parsed.agent.clone())
            } else {
                field(&effective_metadata, ';', "omg_agent").and_then(crate::agents::normalize_id)
            };
            for r in records.iter_mut() {
                let should_supersede = if !is_background {
                    true
                } else {
                    let r_tier1 = r.signal.id == "omg-program-status" || r.signal.id == TAP;
                    let same_agent = incoming_agent.as_deref().is_some_and(|inc| {
                        let existing = if r.signal.id == "omg-program-status" {
                            field(&r.signal.metadata, ':', "app")
                                .and_then(crate::agents::normalize_id)
                        } else if r.signal.id == TAP {
                            parse_tap(&r.signal.metadata, None).map(|t| t.agent)
                        } else {
                            field(&r.signal.metadata, ';', "omg_agent")
                                .and_then(crate::agents::normalize_id)
                        };
                        existing.as_deref() == Some(inc)
                    });
                    r_tier1 != tier1 || same_agent
                };
                if should_supersede && acknowledge_signal(&mut r.signal) {
                    r.terminal_revision = 0;
                    r.interrupted = false;
                }
            }
        }

        let remote = if tier1 {
            self_remote
        } else {
            field(&effective_metadata, ';', "omg_scope") == Some("remote")
        };
        let existing_owner = records
            .iter()
            .find(|r| r.signal.id == id && r.key == raw_key)
            .and_then(|r| r.owner);
        if tier1 && !(local_flag && remote) && new_state == Some("idle") {
            if let Some((old_pid, true)) = existing_owner {
                if foreground != Some(old_pid) && unsafe { libc::kill(-old_pid, 0) != 0 } {
                    records.retain(|r| r.signal.id != id || r.key != raw_key);
                    self.revision = self.revision.saturating_add(1);
                    return;
                }
            }
        }
        let owner = if let Some(explicit) = explicit_verified_owner {
            if local_flag && remote {
                None
            } else {
                Some(explicit)
            }
        } else if !tier1 && !(local_flag && remote) {
            let pid = id
                .rsplit('-')
                .next()
                .and_then(|s| s.parse::<i32>().ok())
                .filter(|p| *p > 1);
            match (pid, field(&effective_metadata, ';', "omg_liveness")) {
                (Some(pid), Some("pid")) => Some((pid, false)),
                (Some(pid), Some("pgid")) => Some((pid, true)),
                _ => foreground.filter(|p| *p > 1).map(|p| (p, true)),
            }
        } else if tier1 && !(local_flag && remote) {
            match (new_state, existing_owner) {
                (Some("idle"), Some((old_pid, true))) if foreground != Some(old_pid) => {
                    Some((old_pid, true))
                }
                _ => foreground.filter(|p| *p > 1).map(|p| (p, true)),
            }
        } else {
            None
        };

        let verified_session = if explicit_verified_owner.is_some() {
            true
        } else if let (Some((opid, ogroup)), Some(leader)) = (owner, session_leader) {
            owner_alive_in_session(opid, ogroup, leader, false)
        } else {
            false
        };

        let attention_locked = !tier1 && new_state == Some("needsAttention");

        records.retain(|r| {
            if r.signal.id == id && r.key == raw_key {
                return false;
            }
            if !in_sync_batch
                && incoming_pgid_scoped
                && is_root_hook
                && r.signal.id != "omg-program-status"
                && r.signal.id != TAP
                && r.remote == remote
                && field(&r.signal.metadata, ';', "omg_context").is_none()
                && field(&r.signal.metadata, ';', "omg_liveness") == Some("pgid")
            {
                let existing_agent = field(&r.signal.metadata, ';', "omg_agent")
                    .and_then(crate::agents::normalize_id);
                if hook_agent.is_some() && existing_agent == hook_agent {
                    return false;
                }
            }
            true
        });
        if records.len() >= MAX_RECORDS {
            records.remove(0);
        }
        let next_revision = self.revision.saturating_add(1);
        let terminal_revision = if matches!(new_state, Some("done" | "error")) {
            next_revision
        } else {
            0
        };
        records.push(Record {
            signal,
            key: raw_key,
            remote,
            owner,
            verified_session,
            attention_locked,
            interrupted: false,
            saw_active_job: in_child_fg_now,
            terminal_revision,
        });
        self.revision = next_revision;
    }

    fn clear_remote(&mut self) {
        let before = self.records.len();
        self.records.retain(|r| !r.remote);
        if self.records.len() != before {
            self.revision = self.revision.saturating_add(1);
        }
    }

    /// Inspects raw `'I'` (`INPUT`) frames from the active writer.
    ///
    /// - Mouse reports (`\x1b[<...M`/`m`, `\x1b[M...`), focus events (`\x1b[I`/`\x1b[O`),
    ///   and terminal query replies (`\x1b[...R`, `\x1b[?1u`, `\x1b]...`) NEVER wipe
    ///   `done`/`error`, do not unlock `needsAttention`, and do not count as user interaction.
    /// - `0x03` (`Ctrl+C`), Kitty `CSI 99;5u` / `99;5:1u`, or `modifyOtherKeys` `CSI 27;5;99~`
    ///   outside bracketed paste transitions `needsAttention`/`working -> idle` (Interrupt Fence).
    /// - Standalone `0x1b` (`Esc`), Kitty `CSI 27u` / `27;1u`, or `modifyOtherKeys` `CSI 27;1;27~`
    ///   outside bracketed paste transitions `needsAttention -> idle`.
    /// - Real user keystrokes (including Kitty `CSI u` non-release keys) unlock `attention_locked`
    ///   and report `user_interaction = true` so `close_on_agent_done` resets without wiping UI `done`.
    pub fn consume_input(&mut self, data: &[u8]) -> bool {
        self.consume_input_detailed(data).activity_changed
    }

    pub fn consume_input_detailed(&mut self, data: &[u8]) -> InputOutcome {
        if data.is_empty() {
            return InputOutcome::default();
        }
        let mut saw_ctrl_c = false;
        let mut saw_bare_esc = false;
        let mut saw_user_key = false;

        for (idx, &byte) in data.iter().enumerate() {
            match self.input_tracker.state {
                InputScanState::Ground => {
                    if byte == 0x1b {
                        if idx == 0 && data.len() == 1 && !self.input_tracker.in_paste {
                            saw_bare_esc = true;
                        } else {
                            self.input_tracker.state = InputScanState::Esc;
                        }
                    } else if !self.input_tracker.in_paste {
                        if byte == 0x03 {
                            saw_ctrl_c = true;
                        } else if byte == b'\r'
                            || byte == b'\n'
                            || byte == b'\t'
                            || byte == 0x7f
                            || byte == 0x08
                            || byte >= 0x20
                        {
                            saw_user_key = true;
                        }
                    }
                }
                InputScanState::Esc => match byte {
                    b'[' => {
                        self.input_tracker.state = InputScanState::Csi(CsiScan::default());
                    }
                    b']' => self.input_tracker.state = InputScanState::Osc,
                    b'P' | b'X' | b'^' | b'_' => self.input_tracker.state = InputScanState::StrSeq,
                    b'O' => self.input_tracker.state = InputScanState::Ss3,
                    0x1b => {
                        if idx + 1 == data.len() && !self.input_tracker.in_paste {
                            saw_bare_esc = true;
                            self.input_tracker.state = InputScanState::Ground;
                        }
                    }
                    _ => {
                        // Alt+<key>
                        self.input_tracker.state = InputScanState::Ground;
                        if !self.input_tracker.in_paste && byte >= 0x20 {
                            saw_user_key = true;
                        }
                    }
                },
                InputScanState::Ss3 => {
                    self.input_tracker.state = InputScanState::Ground;
                    if !self.input_tracker.in_paste {
                        saw_user_key = true;
                    }
                }
                InputScanState::X10Mouse(rem) => {
                    if rem <= 1 {
                        self.input_tracker.state = InputScanState::Ground;
                    } else {
                        self.input_tracker.state = InputScanState::X10Mouse(rem - 1);
                    }
                }
                InputScanState::Csi(mut csi) => {
                    if byte == 0x03 && !self.input_tracker.in_paste {
                        self.input_tracker.state = InputScanState::Ground;
                        saw_ctrl_c = true;
                    } else if matches!(byte, b'<' | b'?' | b'>' | b'=') {
                        csi.private = true;
                        self.input_tracker.state = InputScanState::Csi(csi);
                    } else if byte.is_ascii_digit() {
                        let d = (byte - b'0') as u32;
                        csi.has_digit = true;
                        if csi.sub_idx == 0 && (csi.param_idx as usize) < csi.params.len() {
                            let slot = &mut csi.params[csi.param_idx as usize];
                            *slot = slot.saturating_mul(10).saturating_add(d);
                        } else if csi.param_idx == 0 && csi.sub_idx == 2 {
                            csi.base_key = csi.base_key.saturating_mul(10).saturating_add(d);
                        } else if csi.param_idx == 1 && csi.sub_idx == 1 {
                            csi.event_type =
                                csi.event_type.saturating_mul(10).saturating_add(d as u8);
                        }
                        self.input_tracker.state = InputScanState::Csi(csi);
                    } else if byte == b';' {
                        csi.param_idx = csi.param_idx.saturating_add(1);
                        csi.sub_idx = 0;
                        self.input_tracker.state = InputScanState::Csi(csi);
                    } else if byte == b':' {
                        csi.sub_idx = csi.sub_idx.saturating_add(1);
                        self.input_tracker.state = InputScanState::Csi(csi);
                    } else if (0x20..0x40).contains(&byte) {
                        self.input_tracker.state = InputScanState::Csi(csi);
                    } else if (0x40..=0x7e).contains(&byte) {
                        if byte == b'M' && !csi.private && !csi.has_digit && csi.param_idx == 0 {
                            // Classic X10 mouse `\x1b[M<cb><cx><cy>` consumes 3 raw bytes
                            self.input_tracker.state = InputScanState::X10Mouse(3);
                        } else {
                            let is_release = csi.event_type == 3;
                            if byte == b'~' && !csi.private && csi.has_digit {
                                if csi.param_idx == 0 && csi.params[0] == 200 {
                                    self.input_tracker.in_paste = true;
                                } else if csi.param_idx == 0 && csi.params[0] == 201 {
                                    self.input_tracker.in_paste = false;
                                    saw_user_key = true;
                                } else if !self.input_tracker.in_paste && !is_release {
                                    if csi.param_idx >= 2 && csi.params[0] == 27 {
                                        let mods = csi.params[1].saturating_sub(1) & 0x0f;
                                        let key = csi.params[2];
                                        if mods == 4 && (key == 99 || key == 67) {
                                            saw_ctrl_c = true;
                                        } else if mods == 0 && key == 27 {
                                            saw_bare_esc = true;
                                        } else {
                                            saw_user_key = true;
                                        }
                                    } else {
                                        saw_user_key = true;
                                    }
                                }
                            } else if byte == b'u'
                                && !csi.private
                                && csi.has_digit
                                && !self.input_tracker.in_paste
                                && !is_release
                            {
                                let key = csi.params[0];
                                let mods = csi.params[1].saturating_sub(1) & 0x0f;
                                if mods == 4 && (key == 99 || key == 67 || csi.base_key == 99) {
                                    saw_ctrl_c = true;
                                } else if mods == 0 && key == 27 {
                                    saw_bare_esc = true;
                                } else {
                                    saw_user_key = true;
                                }
                            } else if !self.input_tracker.in_paste
                                && !csi.private
                                && !is_release
                                && matches!(
                                    byte,
                                    b'A' | b'B'
                                        | b'C'
                                        | b'D'
                                        | b'H'
                                        | b'F'
                                        | b'Z'
                                        | b'P'
                                        | b'Q'
                                        | b'S'
                                )
                            {
                                saw_user_key = true;
                            }
                            self.input_tracker.state = InputScanState::Ground;
                        }
                    } else {
                        self.input_tracker.state = InputScanState::Ground;
                    }
                }
                InputScanState::Osc => {
                    if byte == 0x07 {
                        self.input_tracker.state = InputScanState::Ground;
                    } else if byte == 0x1b {
                        self.input_tracker.state = InputScanState::OscEsc;
                    }
                }
                InputScanState::OscEsc => {
                    self.input_tracker.state = if byte == b'\\' {
                        InputScanState::Ground
                    } else {
                        InputScanState::Osc
                    };
                }
                InputScanState::StrSeq => {
                    if byte == 0x07 {
                        self.input_tracker.state = InputScanState::Ground;
                    } else if byte == 0x1b {
                        self.input_tracker.state = InputScanState::StrEsc;
                    }
                }
                InputScanState::StrEsc => {
                    self.input_tracker.state = if byte == b'\\' {
                        InputScanState::Ground
                    } else {
                        InputScanState::StrSeq
                    };
                }
            }
        }

        let user_interaction = saw_user_key || saw_ctrl_c || saw_bare_esc;
        let mut changed = false;
        if user_interaction {
            for r in &mut self.records {
                r.attention_locked = false;
            }
        }
        if saw_ctrl_c {
            for r in &mut self.records {
                if matches!(
                    signal_effective_state(&r.signal),
                    Some("working" | "needsAttention")
                ) && rewrite_signal_state(&mut r.signal, "idle", None)
                {
                    r.interrupted = true;
                    r.attention_locked = false;
                    changed = true;
                }
            }
        } else if saw_bare_esc {
            for r in &mut self.records {
                if signal_effective_state(&r.signal) == Some("needsAttention")
                    && rewrite_signal_state(&mut r.signal, "idle", None)
                {
                    r.attention_locked = false;
                    changed = true;
                }
            }
        }
        if changed {
            self.last_change_sync_restore = false;
            self.revision = self.revision.saturating_add(1);
        }
        InputOutcome {
            activity_changed: changed,
            user_interaction,
        }
    }

    fn is_leader_login(&mut self, leader: i32) -> bool {
        if leader <= 1 {
            return false;
        }
        if let Some((cached_pid, cached_val)) = self.leader_login {
            if cached_pid == leader {
                return cached_val;
            }
        }
        let is_login = is_login_wrapper(leader);
        self.leader_login = Some((leader, is_login));
        if !is_login {
            self.shell_pgid = None;
        }
        is_login
    }

    fn resolve_shell_pgid(&mut self, leader: i32) -> Option<i32> {
        if !self.is_leader_login(leader) {
            return None;
        }
        if let Some(spgid) = self.shell_pgid {
            if owner_alive_in_session(spgid, true, leader, false)
                && is_login_shell_child(spgid, leader)
            {
                return Some(spgid);
            }
            self.shell_pgid = None;
        }
        if let Some(fg) = self.foreground {
            if fg > 1 && fg != leader && is_login_shell_child(fg, leader) {
                self.shell_pgid = Some(fg);
                return Some(fg);
            }
        }
        for r in &self.records {
            if let Some((pid, true)) = r.owner {
                if pid > 1 && pid != leader && is_login_shell_child(pid, leader) {
                    self.shell_pgid = Some(pid);
                    return Some(pid);
                }
            }
        }
        None
    }

    /// Shell Prompt Return Fence (`OSC 133;A` / `OSC 133;D`):
    /// When the shell emits `OSC 133;A` and the foreground process group is back at
    /// the shell (not a live tracked agent child), clear lingering `working` /
    /// `needsAttention` records while preserving `done` and `error`.
    pub(crate) fn on_osc133(&mut self, event: Osc133Event) -> bool {
        match event {
            Osc133Event::CommandDone(Some(code)) if code != 0 && code != 130 => {
                // Non-zero command exit (excluding SIGINT 130): if back at shell and an
                // un-interrupted record was `working` without a live child owner, mark error.
                if !self.is_at_shell_prompt() {
                    return false;
                }
                let shell_pgid = self.session_leader.and_then(|l| self.resolve_shell_pgid(l));
                let session_leader = self.session_leader;
                let mut changed = false;
                let next_rev = self.revision.saturating_add(1);
                for r in &mut self.records {
                    if r.remote && self.local {
                        continue;
                    }
                    if signal_effective_state(&r.signal) == Some("working") && !r.interrupted {
                        let owner_still_live = match (r.owner, session_leader) {
                            (Some((pid, group)), Some(leader))
                                if pid != leader && Some(pid) != shell_pgid =>
                            {
                                owner_alive_in_session(pid, group, leader, r.verified_session)
                            }
                            _ => false,
                        };
                        if !owner_still_live
                            && rewrite_signal_state(
                                &mut r.signal,
                                "error",
                                Some("Agent exited with an error."),
                            )
                        {
                            r.owner = None;
                            r.verified_session = false;
                            r.terminal_revision = next_rev;
                            changed = true;
                        }
                    }
                }
                if changed {
                    self.last_change_sync_restore = false;
                    self.revision = self.revision.saturating_add(1);
                }
                changed
            }
            Osc133Event::CommandDone(_) => false,
            Osc133Event::PromptStart => {
                if !self.is_at_shell_prompt() {
                    return false;
                }
                let shell_pgid = self.session_leader.and_then(|l| self.resolve_shell_pgid(l));
                let session_leader = self.session_leader;
                let mut changed = false;
                for r in &mut self.records {
                    if r.remote && self.local {
                        continue;
                    }
                    let owner_is_live_child = match (r.owner, session_leader) {
                        (Some((pid, group)), Some(leader))
                            if pid != leader && Some(pid) != shell_pgid =>
                        {
                            owner_alive_in_session(pid, group, leader, r.verified_session)
                        }
                        _ => false,
                    };
                    if owner_is_live_child {
                        continue;
                    }
                    if matches!(
                        signal_effective_state(&r.signal),
                        Some("working" | "needsAttention")
                    ) && rewrite_signal_state(&mut r.signal, "idle", None)
                    {
                        r.attention_locked = false;
                        r.owner = None;
                        r.verified_session = false;
                        changed = true;
                    }
                }
                // Also drop stale `idle` ownerless local records so bounded table stays clean.
                let before = self.records.len();
                self.records.retain(|r| {
                    (r.remote && self.local)
                        || r.owner.is_some()
                        || signal_effective_state(&r.signal) != Some("idle")
                });
                if self.records.len() != before {
                    changed = true;
                }
                if changed {
                    self.last_change_sync_restore = false;
                    self.revision = self.revision.saturating_add(1);
                }
                changed
            }
        }
    }

    fn is_at_shell_prompt(&mut self) -> bool {
        match (self.session_leader, self.foreground) {
            (Some(leader), Some(fg)) => {
                if fg == leader || self.resolve_shell_pgid(leader) == Some(fg) {
                    return true;
                }
                !owner_alive_in_session(fg, true, leader, false)
            }
            (Some(_), None) => true,
            (None, Some(fg)) => unsafe { libc::kill(-fg, 0) != 0 },
            (None, None) => true,
        }
    }

    /// Runs even without viewers. Never probes remote PIDs on the local host.
    pub fn prune(&mut self, session: i32) -> bool {
        let mut changed = false;
        let effective_leader = self.session_leader.unwrap_or(session);
        let shell_pgid = (effective_leader > 1)
            .then(|| self.resolve_shell_pgid(effective_leader))
            .flatten();
        let at_shell = self
            .foreground
            .is_some_and(|fg| fg == session || fg == effective_leader || Some(fg) == shell_pgid);
        let in_child_fg = self.foreground.is_some_and(|fg| {
            fg > 1 && fg != session && fg != effective_leader && Some(fg) != shell_pgid
        });
        let mut bare_interactive_shell_checked: Option<bool> = None;
        let next_rev = self.revision.saturating_add(1);
        let mut retained = Vec::with_capacity(self.records.len());

        for mut r in self.records.drain(..) {
            match r.owner {
                Some((pid, group)) => {
                    if owner_alive_in_session(pid, group, session, r.verified_session) {
                        let owned_by_shell_root =
                            pid == session || pid == effective_leader || Some(pid) == shell_pgid;
                        if !(r.remote && self.local)
                            && owned_by_shell_root
                            && matches!(
                                signal_effective_state(&r.signal),
                                Some("working" | "needsAttention")
                            )
                        {
                            if in_child_fg {
                                r.saw_active_job = true;
                            } else if at_shell {
                                let is_bare_shell = *bare_interactive_shell_checked
                                    .get_or_insert_with(|| {
                                        (Some(pid) == shell_pgid || is_interactive_shell_pid(pid))
                                            && !crate::location::session_has_non_shell_member(
                                                effective_leader,
                                                shell_pgid,
                                            )
                                    });
                                if !is_bare_shell {
                                    r.saw_active_job = true;
                                } else if r.saw_active_job
                                    && rewrite_signal_state(&mut r.signal, "idle", None)
                                {
                                    r.attention_locked = false;
                                    r.owner = None;
                                    r.verified_session = false;
                                    r.saw_active_job = false;
                                    changed = true;
                                }
                            }
                        }
                        retained.push(r);
                    } else if r.verified_session {
                        let st = signal_effective_state(&r.signal);
                        if st == Some("working") && !r.interrupted {
                            // Owned working process terminated unexpectedly without done/idle/end!
                            let _ = rewrite_signal_state(
                                &mut r.signal,
                                "error",
                                Some("Agent process exited unexpectedly."),
                            );
                            r.owner = None;
                            r.verified_session = false;
                            r.attention_locked = false;
                            r.terminal_revision = next_rev;
                            retained.push(r);
                            changed = true;
                        } else if matches!(st, Some("done" | "error")) {
                            // Preserve completed/error badge from a one-shot CLI until acked or next turn.
                            r.owner = None;
                            r.verified_session = false;
                            retained.push(r);
                        } else {
                            changed = true;
                        }
                    } else {
                        changed = true;
                    }
                }
                None => {
                    // Preserve remote records on local outer holder; bound non-remote ownerless
                    // working/attention records if foreground returned to the shell leader.
                    if !(r.remote && self.local)
                        && at_shell
                        && matches!(
                            signal_effective_state(&r.signal),
                            Some("working" | "needsAttention")
                        )
                        && rewrite_signal_state(&mut r.signal, "idle", None)
                    {
                        r.attention_locked = false;
                        changed = true;
                    }
                    retained.push(r);
                }
            }
        }

        self.records = retained;
        if changed {
            self.last_change_sync_restore = false;
            self.revision = self.revision.saturating_add(1);
            true
        } else {
            false
        }
    }

    pub fn acknowledge(&mut self) -> bool {
        let target = self.revision;
        self.acknowledge_up_to(target)
    }

    /// Idempotent acknowledgement bounded by `max_revision`.
    pub fn acknowledge_up_to(&mut self, max_revision: u64) -> bool {
        if max_revision < self.ack_up_to_revision {
            return false;
        }
        let mut changed = false;
        for record in &mut self.records {
            if record.terminal_revision <= max_revision && acknowledge_signal(&mut record.signal) {
                record.terminal_revision = 0;
                changed = true;
            }
        }
        if let Some(pending) = &mut self.pending {
            for record in pending {
                if record.terminal_revision <= max_revision
                    && acknowledge_signal(&mut record.signal)
                {
                    record.terminal_revision = 0;
                    changed = true;
                }
            }
        }
        if changed {
            self.last_change_sync_restore = false;
            self.revision = self.revision.saturating_add(1);
            self.ack_up_to_revision = self.revision;
        } else {
            self.ack_up_to_revision = self.ack_up_to_revision.max(max_revision.min(self.revision));
        }
        changed
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Vt;

    fn report(agent: &str, state: &str) -> String {
        format!("\x1b]3008;start=omg-agent-{agent}-42;type=app;omg_agent={agent};omg_scope=remote;omg_state={state}\x07")
    }

    #[test]
    fn ghostty_collects_fragmented_hooks_without_a_viewer() {
        let mut vt = Vt::new(80, 24).unwrap();
        for agent in ["codex", "claude", "pi", "omp"] {
            for state in ["idle", "working", "needsAttention", "done"] {
                for byte in report(agent, state).bytes() {
                    vt.write(&[byte]);
                }
            }
        }
        let snapshot = vt.activity().snapshot();
        assert_eq!(snapshot.records.len(), 4);
        assert!(snapshot.records[..3]
            .iter()
            .all(|s| s.metadata.contains("omg_state=idle")));
        assert!(snapshot.records[3].metadata.contains("omg_state=done"));
        vt.write(b"\x1b]3008;end=omg-agent-omp-42\x1b\\");
        assert_eq!(vt.activity().snapshot().records.len(), 3);
    }

    #[test]
    fn native_status_has_namespaced_clear_and_ignores_queries() {
        let mut vt = Vt::new(80, 24).unwrap();
        vt.write(b"\x1b]7501;state=working:app=codex:id=one/child\x07");
        vt.write(b"\x1b]7501;state=blocked:app=codex:id=two:kind=permission\x1b\\");
        vt.write(b"\x1b]7501;?\x07");
        vt.write(b"\x1b]7501;state=clear:id=one\x07");
        let snapshot = vt.activity().snapshot();
        assert_eq!(snapshot.records.len(), 1);
        assert!(snapshot.records[0].metadata.contains("id=two"));
        vt.write(b"\x1b]7501;state=clear\x07");
        assert!(vt.activity().snapshot().records.is_empty());
    }

    #[test]
    fn exiting_native_status_idle_does_not_transfer_ownership_to_shell() {
        let mut vt = Vt::new(80, 24).unwrap();
        vt.activity_mut().local = true;
        vt.activity_mut().foreground = Some(999_991);
        vt.write(b"\x1b]7501;state=working:app=antigravity\x07");
        assert_eq!(vt.activity().snapshot().records.len(), 1);
        let shell_pgid = unsafe { libc::getpgrp() };
        vt.activity_mut().foreground = Some(shell_pgid);
        vt.write(b"\x1b]7501;state=idle:app=antigravity\x07");
        assert!(vt.activity().snapshot().records.is_empty());
    }

    #[test]
    fn nested_inline_snapshot_replaces_old_state_atomically_and_survives_mid_transaction_attach() {
        let mut source = Vt::new(80, 24).unwrap();
        source.write(report("pi", "working").as_bytes());
        source.write(b"\x1b]3008;start=omg-agent-sync;begin\x07");
        source.write(report("omp", "needsAttention").as_bytes());
        let snapshot = source.activity().snapshot();
        assert_eq!(snapshot.records.len(), 1);
        assert_eq!(snapshot.pending.as_ref().unwrap().len(), 1);
        let bytes = serde_json::to_vec(&snapshot).unwrap();
        let mut outer = Vt::new(80, 24).unwrap();
        outer.write(&Snapshot::decode(&bytes).unwrap().inline_bytes());
        outer.write(b"\x1b]3008;start=omg-agent-sync;end\x07");
        assert_eq!(
            outer.activity().snapshot().records[0].id,
            "omg-agent-omp-42"
        );
        let mut empty = Vt::new(80, 24).unwrap();
        empty.write(&State::default().snapshot().inline_bytes());
        outer.write(&empty.activity().snapshot().inline_bytes());
        assert!(outer.activity().snapshot().records.is_empty());
    }

    #[test]
    fn local_holder_does_not_validate_remote_process_ids() {
        let mut vt = Vt::new(80, 24).unwrap();
        vt.activity_mut().local = true;
        vt.write(
            report("codex", "working")
                .replace(";omg_state", ";omg_liveness=pgid;omg_state")
                .as_bytes(),
        );
        assert!(!vt.activity_mut().prune(1));
        vt.activity_mut().local = false;
        vt.write(
            report("codex", "working")
                .replace(";omg_state", ";omg_liveness=pgid;omg_state")
                .as_bytes(),
        );
        assert!(vt.activity_mut().prune(1));
    }

    #[test]
    fn metadata_does_not_clear_remote_state_but_prompt_and_matching_exit_do() {
        let mut vt = Vt::new(80, 24).unwrap();
        vt.write(b"\x1b]3008;start=omg-ssh-inline-fixture;type=remote;cwd=/srv\x07");
        vt.write(report("pi", "working").as_bytes());
        vt.write(b"\x1b]7501;state=done:app=codex\x07");
        vt.write(b"\x1b]3008;start=omg-ssh-inline-fixture;type=remote;cwd=/srv\x07");
        vt.write(b"\x1b]3008;end=omg-ssh-old\x07");
        assert_eq!(vt.activity().snapshot().records.len(), 2);
        vt.write(b"\x1b]3008;end=omg-ssh-inline-fixture\x07");
        assert!(vt.activity().snapshot().records.is_empty());
        vt.write(report("pi", "working").as_bytes());
        vt.write(b"\x1b]3008;start=omg-ssh-prompt;cwd=/srv\x07");
        assert!(vt.activity().snapshot().records.is_empty());
    }

    #[test]
    fn snapshot_bounds_and_non_context_effects_are_not_replayed() {
        let mut vt = Vt::new(80, 24).unwrap();
        for pid in 1..100 {
            vt.write(
                report("omp", "idle")
                    .replace("-42;", &format!("-{pid};"))
                    .as_bytes(),
            );
        }
        vt.write(b"\x1b]52;c;c2VjcmV0\x07\x1b]777;notify;title;body\x07");
        assert_eq!(vt.activity().snapshot().records.len(), MAX_RECORDS);
        let encoded = serde_json::to_vec(&vt.activity().snapshot()).unwrap();
        let bytes = Snapshot::decode(&encoded).unwrap().inline_bytes();
        assert!(!bytes.windows(4).any(|s| s == b"]52;" || s == b"777;"));
        let invalid = r#"{"version":1,"revision":0,"records":[{"id":"omg-agent-pi","metadata":"\u001b]52;"}],"pending":null}"#;
        assert!(Snapshot::decode(invalid.as_bytes()).is_err());
    }

    #[test]
    fn acknowledging_activity_transitions_completed_and_failed_signals_to_idle() {
        let mut vt = Vt::new(80, 24).unwrap();
        vt.write(report("claude", "working").as_bytes());
        vt.write(
            b"\x1b]3008;start=omg-agent-pi-72155;type=app;omg_agent=pi;omg_scope=local;omg_liveness=pid;omg_state=done;message=Finished;omg_cwd=%2Ftmp%2Frepo\x07",
        );
        vt.write(b"\x1b]7501;state=done:app=codex:msg=RG9uZQ==:progress=100\x07");
        let before = vt.activity().revision();
        assert!(vt.activity_mut().acknowledge());
        assert!(vt.activity().revision() > before);
        let snapshot = vt.activity().snapshot();
        assert_eq!(snapshot.records.len(), 3);
        assert!(snapshot.records[0].metadata.contains("omg_state=working"));
        assert_eq!(
            snapshot.records[1].metadata,
            "type=app;omg_agent=pi;omg_scope=local;omg_liveness=pid;omg_state=idle;omg_cwd=%2Ftmp%2Frepo"
        );
        assert_eq!(snapshot.records[2].metadata, "state=idle:app=codex");
        assert!(!vt.activity_mut().acknowledge());
    }

    #[test]
    fn osc7501_inherits_app_and_enforces_tier_and_attention_hierarchy() {
        let mut vt = Vt::new(80, 24).unwrap();
        // Root sets `app=codex`; child omits `app` and blocks for permission.
        vt.write(b"\x1b]7501;state=working:app=codex:id=turn1\x07");
        vt.write(b"\x1b]7501;state=blocked:id=turn1/perm:kind=permission\x07");
        // Sibling sub-record starts working without `app`.
        vt.write(b"\x1b]7501;state=working:id=turn1/sub2\x07");

        let snap = vt.activity().snapshot();
        assert!(snap.records[1].metadata.contains("app=codex"));
        let pres = snap.presentation().unwrap();
        assert_eq!(pres.tier, Tier::ProgramStatus);
        assert_eq!(pres.agent, "codex");
        assert_eq!(pres.state, "needsAttention");
        assert_eq!(pres.attention, Some("permission"));
        assert_eq!(pres.message, "Waiting for permission");

        // Tier 3 fallback error/done cannot override active Tier 1 or Tier 2.
        vt.activity_mut().consume_report(
            "codex",
            "done",
            42,
            true,
            false,
            None,
            None,
            None,
            None,
            None,
            None,
            Some("fallback"),
            None,
        );
        assert_eq!(
            vt.activity().presentation().unwrap().state,
            "needsAttention"
        );

        // Resolve the blocked sub-record; remaining `turn1` and `turn1/sub2` stay `working`.
        vt.write(b"\x1b]7501;state=clear:id=turn1/perm\x07");
        assert_eq!(vt.activity().presentation().unwrap().state, "working");
    }

    #[test]
    fn hook_needs_attention_locks_against_sibling_working_until_user_input() {
        let mut vt = Vt::new(80, 24).unwrap();
        vt.activity_mut().consume_report(
            "claude",
            "needsAttention",
            500,
            true,
            false,
            Some("conv-1"),
            Some("/tmp"),
            None,
            Some("permission"),
            None,
            None,
            None,
            None,
        );
        assert_eq!(
            vt.activity().presentation().unwrap().state,
            "needsAttention"
        );

        // Sibling PostToolUse `working` on same agent/owner without user input is ignored!
        vt.activity_mut().consume_report(
            "claude",
            "working",
            500,
            true,
            false,
            Some("conv-1"),
            Some("/tmp"),
            None,
            None,
            None,
            None,
            None,
            None,
        );
        assert_eq!(
            vt.activity().presentation().unwrap().state,
            "needsAttention"
        );

        // Mouse motion & focus events do NOT unlock or wipe anything.
        assert!(!vt
            .activity_mut()
            .consume_input(b"\x1b[<35;10;20M\x1b[I\x1b[O"));
        vt.activity_mut().consume_report(
            "claude",
            "working",
            500,
            true,
            false,
            Some("conv-1"),
            Some("/tmp"),
            None,
            None,
            None,
            None,
            None,
            None,
        );
        assert_eq!(
            vt.activity().presentation().unwrap().state,
            "needsAttention"
        );

        // Real user keystroke (`y\r`) unlocks `attention_locked`, so next `working` hook transitions!
        assert!(!vt.activity_mut().consume_input(b"y\r"));
        vt.activity_mut().consume_report(
            "claude",
            "working",
            500,
            true,
            false,
            Some("conv-1"),
            Some("/tmp"),
            None,
            None,
            None,
            None,
            None,
            None,
        );
        assert_eq!(vt.activity().presentation().unwrap().state, "working");
    }

    #[test]
    fn new_working_turn_supersedes_stale_done_and_error_across_channels() {
        let mut vt = Vt::new(80, 24).unwrap();
        vt.write(b"\x1b]7501;state=error:app=antigravity:id=t1\x07");
        vt.activity_mut().consume_report(
            "antigravity",
            "done",
            700,
            true,
            false,
            Some("conv-a"),
            Some("/tmp"),
            None,
            None,
            None,
            None,
            None,
            None,
        );
        assert_eq!(vt.activity().presentation().unwrap().state, "error");

        // New Hook turn begins: supersedes prior OSC 7501 `error` AND prior Hook `done`!
        vt.activity_mut().consume_report(
            "antigravity",
            "working",
            700,
            true,
            false,
            Some("conv-a"),
            Some("/tmp"),
            None,
            None,
            None,
            None,
            None,
            Some("prompt"),
        );
        assert_eq!(vt.activity().presentation().unwrap().state, "working");
        assert!(vt.activity().snapshot().records[0]
            .metadata
            .contains("state=idle"));
    }

    #[test]
    fn interrupt_and_osc133_prompt_fences_clear_stuck_working_but_preserve_done_and_error() {
        let mut vt = Vt::new(80, 24).unwrap();
        vt.write(b"\x1b]7501;state=working:app=claude\x07");
        // Ctrl+C inside bracketed paste must NOT trigger interrupt fence.
        assert!(!vt
            .activity_mut()
            .consume_input(b"\x1b[200~hello\x03world\x1b[201~"));
        assert_eq!(vt.activity().presentation().unwrap().state, "working");

        // Real Ctrl+C outside paste transitions `working -> idle`.
        assert!(vt.activity_mut().consume_input(b"\x03"));
        assert_eq!(vt.activity().presentation().unwrap().state, "idle");

        // Bare Esc in `needsAttention` transitions `needsAttention -> idle`.
        vt.write(b"\x1b]7501;state=blocked:app=claude:kind=question\x07");
        assert_eq!(
            vt.activity().presentation().unwrap().state,
            "needsAttention"
        );
        assert!(vt.activity_mut().consume_input(b"\x1b"));
        assert_eq!(vt.activity().presentation().unwrap().state, "idle");

        // OSC 133;A shell prompt return clears stuck `working`, but preserves `done` and `error`!
        vt.write(b"\x1b]7501;state=working:app=codex\x07");
        assert_eq!(vt.activity().presentation().unwrap().state, "working");
        vt.write(b"\x1b]133;A;cl=m\x07$ ");
        assert!(vt
            .activity()
            .presentation()
            .is_none_or(|p| p.state == "idle"));

        vt.write(b"\x1b]7501;state=done:app=codex\x07");
        vt.write(b"\x1b]133;A\x07$ ");
        assert_eq!(vt.activity().presentation().unwrap().state, "done");

        vt.write(b"\x1b]7501;state=error:app=codex\x07");
        vt.write(b"\x1b]133;A\x07$ ");
        assert_eq!(vt.activity().presentation().unwrap().state, "error");
    }

    #[test]
    fn kitty_csi_u_and_modify_other_keys_handle_interrupt_esc_unlock_and_chunk_splits() {
        let mut vt = Vt::new(80, 24).unwrap();

        // 1. Kitty keyboard query reply `\x1b[?1u`, SGR mouse, and chunk-split `\x1b` must NOT
        //    count as user interaction or false-fire bare `Esc`!
        vt.write(b"\x1b]7501;state=blocked:app=claude:kind=permission\x07");
        let out_query = vt
            .activity_mut()
            .consume_input_detailed(b"\x1b[?1u\x1b[<35;10;20M\x1b");
        assert!(!out_query.activity_changed);
        assert!(!out_query.user_interaction);
        assert_eq!(
            vt.activity().presentation().unwrap().state,
            "needsAttention"
        );
        let out_cont = vt.activity_mut().consume_input_detailed(b"[<35;11;20M");
        assert!(!out_cont.activity_changed);
        assert!(!out_cont.user_interaction);
        assert_eq!(
            vt.activity().presentation().unwrap().state,
            "needsAttention"
        );

        // 2. Kitty key-release (`:3u`) is ignored, while press (`\x1b[27u` / `\x1b[27;1:1u`) clears `needsAttention`.
        let out_rel = vt.activity_mut().consume_input_detailed(b"\x1b[27;1:3u");
        assert!(!out_rel.activity_changed);
        assert!(!out_rel.user_interaction);
        assert_eq!(
            vt.activity().presentation().unwrap().state,
            "needsAttention"
        );

        let out_esc = vt.activity_mut().consume_input_detailed(b"\x1b[27;1:1u");
        assert!(out_esc.activity_changed);
        assert!(out_esc.user_interaction);
        assert_eq!(vt.activity().presentation().unwrap().state, "idle");

        // 3. Kitty `Ctrl+C` (`\x1b[99;5u`, `\x1b[99:67;5:1u`) and `modifyOtherKeys` (`\x1b[27;5;99~`)
        //    trigger Interrupt Fence on `working`, while release `\x1b[99;5:3u` is ignored!
        vt.write(b"\x1b]7501;state=working:app=codex\x07");
        assert!(!vt.activity_mut().consume_input(b"\x1b[99;5:3u"));
        assert_eq!(vt.activity().presentation().unwrap().state, "working");
        assert!(vt.activity_mut().consume_input(b"\x1b[99:67;5:1u"));
        assert_eq!(vt.activity().presentation().unwrap().state, "idle");

        vt.write(b"\x1b]7501;state=working:app=codex\x07");
        assert!(vt.activity_mut().consume_input(b"\x1b[27;5;99~"));
        assert_eq!(vt.activity().presentation().unwrap().state, "idle");

        // 4. `modifyOtherKeys` Esc (`\x1b[27;1;27~`) clears `needsAttention`.
        vt.write(b"\x1b]7501;state=blocked:app=pi:kind=question\x07");
        assert!(vt.activity_mut().consume_input(b"\x1b[27;1;27~"));
        assert_eq!(vt.activity().presentation().unwrap().state, "idle");

        // 5. Kitty `CSI u` ordinary key (`\x1b[121u` 'y' / `\x1b[13u` Enter) unlocks Hook `attention_locked`!
        vt.activity_mut().consume_report(
            "claude",
            "needsAttention",
            501,
            true,
            false,
            Some("conv-k"),
            Some("/tmp"),
            None,
            Some("permission"),
            None,
            None,
            None,
            None,
        );
        assert_eq!(
            vt.activity().presentation().unwrap().state,
            "needsAttention"
        );
        let out_y = vt
            .activity_mut()
            .consume_input_detailed(b"\x1b[121u\x1b[13u");
        assert!(!out_y.activity_changed);
        assert!(out_y.user_interaction);
        vt.activity_mut().consume_report(
            "claude",
            "working",
            501,
            true,
            false,
            Some("conv-k"),
            Some("/tmp"),
            None,
            None,
            None,
            None,
            None,
            None,
        );
        assert_eq!(vt.activity().presentation().unwrap().state, "working");
    }

    #[test]
    fn tier3_fallback_surfaces_for_different_agent_after_higher_tier_settles_idle_and_cross_agent_working_supersedes_error(
    ) {
        let mut vt = Vt::new(80, 24).unwrap();

        // Agent A (`claude`, Tier 2) fails with `error`.
        vt.activity_mut().consume_report(
            "claude",
            "error",
            601,
            true,
            false,
            None,
            Some("/tmp"),
            None,
            None,
            None,
            Some("API 500"),
            None,
            None,
        );
        assert_eq!(vt.activity().presentation().unwrap().state, "error");

        // Agent B (`opencode`, Tier 2) starts a foreground `working` turn in the same shell ->
        // supersedes `claude`'s stale `error` so `opencode`'s subsequent `done` is NOT masked!
        vt.activity_mut().consume_report(
            "opencode",
            "working",
            602,
            true,
            false,
            None,
            Some("/tmp"),
            None,
            None,
            None,
            None,
            None,
            None,
        );
        vt.activity_mut().consume_report(
            "opencode",
            "done",
            602,
            true,
            false,
            None,
            Some("/tmp"),
            None,
            None,
            None,
            Some("Completed"),
            None,
            None,
        );
        let pres_b = vt.activity().presentation().unwrap();
        assert_eq!(pres_b.agent, "opencode");
        assert_eq!(pres_b.state, "done");

        // Acknowledge `opencode` -> Tier 2 settles to `idle`.
        assert!(vt.activity_mut().acknowledge());
        assert_eq!(vt.activity().presentation().unwrap().state, "idle");

        // Same-agent (`opencode`) Tier 3 fallback remains shadowed by Tier 2 `opencode`,
        // whereas a different Tier 3-only agent (`crush`) surfaces cleanly!
        vt.activity_mut().consume_report(
            "opencode",
            "working",
            602,
            false,
            false,
            None,
            Some("/tmp"),
            Some("fb"),
            None,
            Some("background"),
            None,
            Some("fallback"),
            None,
        );
        // Note: background `working` did not supersede `opencode`'s Tier 2 `idle`, and Tier 2 owns `opencode`.
        assert_eq!(vt.activity().presentation().unwrap().state, "idle");

        vt.activity_mut().consume_report(
            "crush",
            "working",
            603,
            true,
            false,
            None,
            Some("/tmp"),
            None,
            None,
            None,
            Some("Thinking"),
            Some("fallback"),
            None,
        );
        let pres_t3 = vt.activity().presentation().unwrap();
        assert_eq!(pres_t3.tier, Tier::Fallback);
        assert_eq!(pres_t3.agent, "crush");
        assert_eq!(pres_t3.state, "working");
    }

    #[test]
    fn interactive_shell_argv_distinguishes_login_shells_from_commands_and_direct_agents() {
        let vec_str = |items: &[&str]| items.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();
        assert!(is_interactive_shell_argv(&vec_str(&["-/bin/zsh"])));
        assert!(is_interactive_shell_argv(&vec_str(&["/bin/zsh", "-l"])));
        assert!(is_interactive_shell_argv(&vec_str(&[
            "-/opt/homebrew/bin/fish",
            "-C",
            "source /tmp/ghostty.fish"
        ])));
        assert!(is_interactive_shell_argv(&vec_str(&["bash", "--posix"])));
        assert!(is_interactive_shell_argv(&vec_str(&[
            "-/bin/bash",
            "--noprofile",
            "--norc",
            "-i"
        ])));
        assert!(is_interactive_shell_argv(&vec_str(&[
            "-/bin/sh", "-m", "-i"
        ])));

        assert!(!is_interactive_shell_argv(&vec_str(&["-claude"])));
        assert!(!is_interactive_shell_argv(&vec_str(&[
            "/usr/local/bin/claude",
            "--resume",
            "abc"
        ])));
        assert!(!is_interactive_shell_argv(&vec_str(&[
            "/bin/bash",
            "--noprofile",
            "--norc",
            "-c",
            "exec -l claude"
        ])));
        assert!(!is_interactive_shell_argv(&vec_str(&[
            "-/bin/sh",
            "-c",
            "claude; exec -l /bin/zsh"
        ])));
        assert!(!is_interactive_shell_argv(&vec_str(&[
            "/bin/zsh", "-lc", "codex"
        ])));
        assert!(!is_interactive_shell_argv(&vec_str(&[
            "/bin/zsh",
            "/tmp/run_script.zsh"
        ])));
    }

    #[test]
    fn owner_alive_in_session_enforces_session_id_on_groups_and_prune_clears_bare_shell_working() {
        let self_pid = std::process::id() as i32;
        let self_pgid = unsafe { libc::getpgrp() };
        let self_sid = unsafe { libc::getsid(0) };
        let foreign_sid = if self_sid == 999_999 {
            999_998
        } else {
            999_999
        };
        if self_pgid > 1 && self_sid > 1 {
            assert!(owner_alive_in_session(self_pgid, true, self_sid, true));
            assert!(!owner_alive_in_session(self_pgid, true, foreign_sid, true));
        }
        assert!(owner_alive_in_session(self_pid, false, foreign_sid, true));
        assert!(!owner_alive_in_session(self_pid, false, foreign_sid, false));

        // Spawn an interactive `/bin/sh -i` PTY session without OSC 133 shell integration
        // and verify a shell-owned `working` record expires once returned from a child job.
        let mut master: libc::c_int = -1;
        let mut slave: libc::c_int = -1;
        assert_eq!(
            unsafe {
                libc::openpty(
                    &mut master,
                    &mut slave,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                )
            },
            0
        );
        use std::os::{fd::FromRawFd, unix::process::CommandExt};
        let slave_file = unsafe { std::fs::File::from_raw_fd(slave) };
        let mut cmd = std::process::Command::new("/bin/sh");
        cmd.arg("-i")
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .env("HOME", "/tmp")
            .env("PS1", "$ ")
            .env("TERM", "dumb")
            .stdin(slave_file.try_clone().unwrap())
            .stdout(slave_file.try_clone().unwrap())
            .stderr(slave_file);
        unsafe {
            cmd.pre_exec(|| {
                if libc::setsid() < 0 || libc::ioctl(0, libc::TIOCSCTTY as _, 0) < 0 {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let child = cmd.spawn().unwrap();
        drop(cmd);
        unsafe {
            libc::fcntl(master, libc::F_SETFL, libc::O_NONBLOCK);
        }
        struct PtyGuard {
            child: std::process::Child,
            master: libc::c_int,
        }
        impl Drop for PtyGuard {
            fn drop(&mut self) {
                let leader = self.child.id() as i32;
                if leader > 1 {
                    unsafe {
                        libc::kill(-leader, libc::SIGKILL);
                    }
                }
                let _ = self.child.kill();
                let _ = self.child.wait();
                if self.master >= 0 {
                    unsafe {
                        libc::close(self.master);
                    }
                }
            }
        }
        let guard = PtyGuard { child, master };
        let leader = guard.child.id() as i32;
        let drain_master = || {
            let mut sink = [0u8; 1024];
            while unsafe { libc::read(guard.master, sink.as_mut_ptr().cast(), sink.len()) } > 0 {}
        };
        for _ in 0..50 {
            drain_master();
            if unsafe { libc::tcgetpgrp(guard.master) } == leader {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        let mut vt = crate::Vt::new(80, 24).unwrap();
        {
            let tracker = vt.activity_mut();
            tracker.local = true;
            tracker.session_leader = Some(leader);
            tracker.foreground = Some(leader);
        }
        // 1) Bare shell OSC 7501 `working` and `blocked` (`needsAttention`) with NO active
        //    child job must NOT decay to `idle` across repeated `prune()` calls even past >2s!
        vt.write(b"\x1b]7501;state=working:app=codex:id=fixture\x07");
        assert_eq!(vt.activity().presentation().unwrap().state, "working");
        assert!(!vt.activity_mut().prune(leader));
        std::thread::sleep(std::time::Duration::from_millis(2100));
        assert!(!vt.activity_mut().prune(leader));
        assert_eq!(vt.activity().presentation().unwrap().state, "working");

        vt.write(b"\x1b]7501;state=blocked:app=claude:id=fixture:kind=permission\x07");
        assert_eq!(
            vt.activity().presentation().unwrap().state,
            "needsAttention"
        );
        std::thread::sleep(std::time::Duration::from_millis(200));
        assert!(!vt.activity_mut().prune(leader));
        assert_eq!(
            vt.activity().presentation().unwrap().state,
            "needsAttention"
        );

        // 2) Once a non-shell child member runs in the session and exits back to bare `/bin/sh -i`,
        //    `prune()` observes `saw_active_job` and clears `needsAttention` to `idle`.
        let cmd_bytes = b"/bin/sleep 0.3\n";
        assert_eq!(
            unsafe { libc::write(guard.master, cmd_bytes.as_ptr().cast(), cmd_bytes.len(),) },
            cmd_bytes.len() as isize
        );
        let observed_non_shell = (0..40).any(|_| {
            std::thread::sleep(std::time::Duration::from_millis(15));
            drain_master();
            let fg = unsafe { libc::tcgetpgrp(guard.master) };
            vt.activity_mut().foreground = (fg > 1).then_some(fg);
            let _ = vt.activity_mut().prune(leader);
            fg != leader || crate::location::session_has_non_shell_member(leader, None)
        });
        assert!(observed_non_shell);
        let cleared_after_exit = (0..60).any(|_| {
            std::thread::sleep(std::time::Duration::from_millis(15));
            drain_master();
            let fg = unsafe { libc::tcgetpgrp(guard.master) };
            vt.activity_mut().foreground = (fg > 1).then_some(fg);
            let _ = vt.activity_mut().prune(leader);
            vt.activity().presentation().unwrap().state == "idle"
        });
        assert!(cleared_after_exit);

        // 3) Entering a child foreground PGID and returning to bare `/bin/sh -i` also clears `working`.
        let tracker = vt.activity_mut();
        tracker.consume_report(
            "claude",
            "working",
            leader,
            true,
            true,
            None,
            Some("/tmp"),
            None,
            None,
            None,
            Some("Thinking"),
            None,
            None,
        );
        assert_eq!(tracker.presentation().unwrap().state, "working");
        tracker.foreground = Some(leader + 10_000);
        let _ = tracker.prune(leader);
        tracker.foreground = Some(leader);
        assert!(tracker.prune(leader));
        assert_eq!(tracker.presentation().unwrap().state, "idle");

        drop(guard);
    }

    #[test]
    fn inline_bytes_closes_pending_sync_transaction_and_ignores_empty_pending() {
        let mut source = Vt::new(80, 24).unwrap();
        source.write(b"\x1b]7501;state=working:app=antigravity:id=t1\x07");
        source.write(b"\x1b]3008;start=omg-agent-sync;begin\x07");
        source.write(b"\x1b]7501;state=blocked:app=antigravity:id=t2:kind=permission\x07");
        let with_pending = source.activity().snapshot().inline_bytes_with_mode("live");
        let text = String::from_utf8_lossy(&with_pending);
        assert_eq!(
            text.matches("start=omg-agent-sync;begin\x07").count(),
            text.matches("start=omg-agent-sync;end\x07").count(),
            "every omg-agent-sync;begin must be balanced by end: {text:?}"
        );
        // Subsequent OSC 7501 update after inline_bytes must commit cleanly (not trapped open).
        let mut receiver = Vt::new(80, 24).unwrap();
        receiver.write(&with_pending);
        receiver.write(b"\x1b]7501;state=done:app=antigravity:id=t2\x07");
        let snap = receiver.activity().snapshot();
        assert!(snap.pending.is_none());
        assert_eq!(snap.presentation().unwrap().state, "done");

        // Empty pending (`Some([])`) after committed records must not open an empty wipe batch.
        let mut empty_pending_src = Vt::new(80, 24).unwrap();
        empty_pending_src.write(b"\x1b]7501;state=working:app=antigravity:id=t3\x07");
        empty_pending_src.write(b"\x1b]3008;start=omg-agent-sync;begin\x07");
        let encoded = empty_pending_src
            .activity()
            .snapshot()
            .inline_bytes_with_mode("restore");
        let mut rx2 = Vt::new(80, 24).unwrap();
        rx2.write(&encoded);
        assert_eq!(
            rx2.activity().snapshot().presentation().unwrap().state,
            "working"
        );
    }

    #[test]
    fn osc26_tap_parsing_bounds_and_validation() {
        // Valid TAP payload with all fields (ProjectFolder must be ignored for cwd authority).
        let parsed = parse_tap(
            "CodeAgent=Claude Code;SessionId=sess_01.a-b;Status=running;TaskProgress=45%;Title=Refactor parser;ProjectFolder=/etc/shadow",
            None,
        )
        .unwrap();
        assert_eq!(parsed.agent, "claude");
        assert_eq!(parsed.state, "working");
        assert_eq!(parsed.attention, None);
        assert_eq!(parsed.session_id.as_deref(), Some("sess_01.a-b"));
        assert_eq!(parsed.task_progress.as_deref(), Some("45%"));
        assert_eq!(parsed.title.as_deref(), Some("Refactor parser"));

        // Status mappings: awaiting-input -> question, awaiting-approval -> permission, idle, error.
        let awaiting_input = parse_tap("CodeAgent=Codex;Status=awaiting-input", None).unwrap();
        assert_eq!(awaiting_input.agent, "codex");
        assert_eq!(awaiting_input.state, "needsAttention");
        assert_eq!(awaiting_input.attention, Some("question"));

        let awaiting_approval = parse_tap("CodeAgent=agy;Status=awaiting-approval", None).unwrap();
        assert_eq!(awaiting_approval.agent, "antigravity");
        assert_eq!(awaiting_approval.state, "needsAttention");
        assert_eq!(awaiting_approval.attention, Some("permission"));

        assert_eq!(
            parse_tap("CodeAgent=Cursor Agent;Status=idle", None)
                .unwrap()
                .state,
            "idle"
        );
        assert_eq!(
            parse_tap("CodeAgent=OpenCode;Status=error", None)
                .unwrap()
                .state,
            "error"
        );

        // Strict SessionId validation: charset [A-Za-z0-9._-], no leading '-', len <= 128.
        assert!(parse_tap("CodeAgent=Claude;Status=running;SessionId=-flag", None).is_none());
        assert!(parse_tap("CodeAgent=Claude;Status=running;SessionId=../escape", None).is_none());
        assert!(parse_tap("CodeAgent=Claude;Status=running;SessionId=bad id", None).is_none());
        let long_id = "a".repeat(129);
        assert!(parse_tap(
            &format!("CodeAgent=Claude;Status=running;SessionId={long_id}"),
            None
        )
        .is_none());

        // Bounds & control characters & unknown status.
        let huge = format!("CodeAgent=Claude;Status=running;Title={}", "x".repeat(4100));
        assert!(parse_tap(&huge, None).is_none());
        assert!(parse_tap("CodeAgent=Claude;Status=running;Title=bad\x07bell", None).is_none());
        assert!(parse_tap("CodeAgent=Claude;Status=bogus", None).is_none());
        assert!(parse_tap("CodeAgent=Claude", None).is_none());
    }

    #[test]
    fn osc26_tap_tier1_arbitration_with_osc7501_and_tier2_hooks() {
        // 1) Same-agent OSC 7501 + OSC 26: OSC 7501 wins on state/attention,
        //    OSC 26 enriches metadata (SessionId -> conversation, TaskProgress, Title).
        let mut vt = Vt::new(80, 24).unwrap();
        vt.write(b"\x1b]26;CodeAgent=Claude;SessionId=conv-42;Status=awaiting-approval;TaskProgress=60%;Title=Review diff;ProjectFolder=/tmp/untrusted\x07");
        vt.write(b"\x1b]7501;state=working:app=claude\x07");
        let snap = vt.activity().snapshot();
        assert!(snap.remote_cwd.is_none());
        let pres = snap.presentation().unwrap();
        assert_eq!(pres.tier, Tier::ProgramStatus);
        assert_eq!(pres.agent, "claude");
        assert_eq!(pres.state, "working");
        assert_eq!(pres.attention, None);
        assert_eq!(pres.conversation.as_deref(), Some("conv-42"));
        assert_eq!(pres.task_progress.as_deref(), Some("60%"));
        assert_eq!(pres.title.as_deref(), Some("Review diff"));

        // 2) TAP-only agent drives Tier 1 and respects Tier 2 needsAttention
        //    surfacing over generic Tier 1 working on the same agent.
        let mut tap_only = Vt::new(80, 24).unwrap();
        tap_only.write(
            b"\x1b]26;CodeAgent=Codex;SessionId=cx-7;Status=running;Title=Running tests\x07",
        );
        let p1 = tap_only.activity().presentation().unwrap();
        assert_eq!(p1.tier, Tier::ProgramStatus);
        assert_eq!(p1.agent, "codex");
        assert_eq!(p1.state, "working");
        assert_eq!(p1.conversation.as_deref(), Some("cx-7"));
        assert_eq!(p1.message, "Running tests");

        // Tier 2 Hook `needsAttention` on same agent surfaces over generic Tier 1 `working`.
        tap_only.write(b"\x1b]3008;start=omg-agent-codex-101;type=app;omg_agent=codex;omg_state=needsAttention;omg_attention=permission\x07");
        let p2 = tap_only.activity().presentation().unwrap();
        assert_eq!(p2.tier, Tier::Hook);
        assert_eq!(p2.state, "needsAttention");
        assert_eq!(p2.attention, Some("permission"));

        // Tier 1 TAP `awaiting-input` takes back authority over Tier 2.
        tap_only.write(b"\x1b]26;CodeAgent=Codex;SessionId=cx-7;Status=awaiting-input\x07");
        let p3 = tap_only.activity().presentation().unwrap();
        assert_eq!(p3.tier, Tier::ProgramStatus);
        assert_eq!(p3.state, "needsAttention");
        assert_eq!(p3.attention, Some("question"));

        // Tier 1 TAP `error` is acknowledged to `idle` once the prior Tier 2 hook has ended.
        tap_only.write(b"\x1b]3008;end=omg-agent-codex-101\x07");
        tap_only.write(b"\x1b]26;CodeAgent=Codex;Status=error\x07");
        assert_eq!(tap_only.activity().presentation().unwrap().state, "error");
        let mut ack_snap = tap_only.activity().snapshot();
        assert!(ack_snap.acknowledge());
        assert_eq!(ack_snap.presentation().unwrap().state, "idle");
    }

    #[test]
    fn osc26_tap_vt_bounds_and_sync_snapshot_replay() {
        let mut source = Vt::new(80, 24).unwrap();
        // Oversized OSC 26 (> 4096 bytes) and non-26 unknown OSCs must be ignored.
        let oversized = format!(
            "\x1b]26;CodeAgent=Claude;Status=running;Title={}\x07",
            "z".repeat(4200)
        );
        source.write(oversized.as_bytes());
        source.write(b"\x1b]7400;status=busy\x07");
        source.write(b"\x1b]88;cmd=claude\x07");
        assert!(source.activity().presentation().is_none());

        // Valid OSC 26 syncs via `omg-agent-sync` and survives Snapshot JSON round-trip.
        source.write(b"\x1b]26;CodeAgent=Claude;SessionId=sess_sync_1;Status=awaiting-approval;TaskProgress=80%;Title=Approve tool\x07");
        let snap = source.activity().snapshot();
        let json = serde_json::to_vec(&snap).unwrap();
        let decoded = Snapshot::decode(&json).unwrap();
        let decoded_pres = decoded.presentation().unwrap();
        assert_eq!(decoded_pres.agent, "claude");
        assert_eq!(decoded_pres.state, "needsAttention");
        assert_eq!(decoded_pres.attention, Some("permission"));
        assert_eq!(decoded_pres.conversation.as_deref(), Some("sess_sync_1"));
        assert_eq!(decoded_pres.task_progress.as_deref(), Some("80%"));

        // Replay over inline `omg-agent-sync` into a fresh VT receiver.
        let sync_bytes = snap.inline_bytes_with_mode("restore");
        let mut receiver = Vt::new(80, 24).unwrap();
        receiver.write(&sync_bytes);
        let replayed = receiver.activity().presentation().unwrap();
        assert_eq!(replayed.tier, Tier::ProgramStatus);
        assert_eq!(replayed.agent, "claude");
        assert_eq!(replayed.state, "needsAttention");
        assert_eq!(replayed.attention, Some("permission"));
        assert_eq!(replayed.conversation.as_deref(), Some("sess_sync_1"));
        assert_eq!(replayed.title.as_deref(), Some("Approve tool"));

        // Also verify `omg_vt_restore` preserves the unknown_sequence callback.
        let vt_snapshot = source.snapshot().unwrap();
        let mut restored = Vt::new(80, 24).unwrap();
        restored.restore(&vt_snapshot).unwrap();
        restored.write(b"\x1b]26;CodeAgent=Codex;Status=running;SessionId=after-restore\x07");
        let after = restored.activity().presentation().unwrap();
        assert_eq!(after.agent, "codex");
        assert_eq!(after.state, "working");
        assert_eq!(after.conversation.as_deref(), Some("after-restore"));
    }
}
