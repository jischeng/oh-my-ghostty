//! Daemon-owned lifetime decisions. Output never refreshes a detached deadline.
use serde::{Deserialize, Serialize};
use std::{
    io,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
pub struct Policy {
    /// Zero is an explicit opt-in to unlimited detached lifetime.
    pub detached_ttl_seconds: u64,
    /// Optional UTC deadline; only applies when no live attachments remain.
    pub expires_at: Option<u64>,
    pub close_on_agent_done: bool,
    pub agent_done_grace_seconds: u64,
    pub terminate_grace_seconds: u64,
    pub host_idle_seconds: u64,
    pub record_retention_seconds: u64,
}
impl Default for Policy {
    fn default() -> Self {
        Self {
            detached_ttl_seconds: 3 * 24 * 3600,
            expires_at: None,
            close_on_agent_done: true,
            agent_done_grace_seconds: 60,
            terminate_grace_seconds: 5,
            host_idle_seconds: 300,
            record_retention_seconds: 7 * 24 * 3600,
        }
    }
}
impl Policy {
    pub fn validate(&self) -> io::Result<()> {
        if self.detached_ttl_seconds > 365 * 24 * 3600
            || self.agent_done_grace_seconds > 24 * 3600
            || self.terminate_grace_seconds == 0
            || self.terminate_grace_seconds > 60
            || self.host_idle_seconds == 0
            || self.host_idle_seconds > 24 * 3600
            || self.record_retention_seconds < 60
            || self.record_retention_seconds > 365 * 24 * 3600
        {
            return Err(io::Error::other("invalid session lifetime policy"));
        }
        Ok(())
    }
}
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum EndReason {
    ProcessExited,
    ExplicitClose,
    DetachedTimeout,
    Deadline,
    AgentCompleted,
    Lost,
}
impl EndReason {
    pub fn resumable(self) -> bool {
        matches!(
            self,
            Self::DetachedTimeout | Self::Deadline | Self::AgentCompleted | Self::ProcessExited
        )
    }
}
pub fn unix_time() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
pub struct Lifetime {
    detached_since: Option<Instant>,
    completed_since: Option<Instant>,
}
impl Lifetime {
    pub fn new(now: Instant) -> Self {
        Self {
            detached_since: Some(now),
            completed_since: None,
        }
    }
    pub fn attached(&mut self, count: usize, now: Instant) {
        if count > 0 {
            if self.detached_since.take().is_some() {
                self.completed_since = None;
            }
        } else if self.detached_since.is_none() {
            self.detached_since = Some(now);
        }
    }
    pub fn activity(&mut self, completed: bool, now: Instant) {
        self.completed_since = if completed { Some(now) } else { None };
    }
    pub fn reason(
        &self,
        policy: &Policy,
        now: Instant,
        wall: u64,
        can_resume: bool,
    ) -> Option<EndReason> {
        let detached = self.detached_since?;
        if policy.expires_at.is_some_and(|expiry| wall >= expiry) {
            return Some(EndReason::Deadline);
        }
        if policy.detached_ttl_seconds > 0
            && now.duration_since(detached) >= Duration::from_secs(policy.detached_ttl_seconds)
        {
            return Some(EndReason::DetachedTimeout);
        }
        if policy.close_on_agent_done
            && can_resume
            && self.completed_since.is_some_and(|done| {
                now.duration_since(done.max(detached))
                    >= Duration::from_secs(policy.agent_done_grace_seconds)
            })
        {
            return Some(EndReason::AgentCompleted);
        }
        None
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn detached_timeout_ignores_output_but_not_reattach() {
        let now = Instant::now();
        let mut state = Lifetime::new(now);
        let p = Policy {
            detached_ttl_seconds: 5,
            ..Policy::default()
        };
        assert_eq!(
            state.reason(&p, now + Duration::from_secs(5), 0, false),
            Some(EndReason::DetachedTimeout)
        );
        state.attached(1, now + Duration::from_secs(6));
        assert_eq!(
            state.reason(&p, now + Duration::from_secs(30), 0, false),
            None
        );
        state.attached(0, now + Duration::from_secs(30));
        assert_eq!(
            state.reason(&p, now + Duration::from_secs(34), 0, false),
            None
        );
    }
    #[test]
    fn completion_requires_resume_and_cancels_on_activity_or_attach() {
        let now = Instant::now();
        let mut state = Lifetime::new(now);
        let p = Policy {
            close_on_agent_done: true,
            agent_done_grace_seconds: 2,
            ..Policy::default()
        };
        state.activity(true, now);
        assert_eq!(
            state.reason(&p, now + Duration::from_secs(3), 0, false),
            None
        );
        assert_eq!(
            state.reason(&p, now + Duration::from_secs(3), 0, true),
            Some(EndReason::AgentCompleted)
        );
        state.activity(false, now + Duration::from_secs(3));
        assert_eq!(
            state.reason(&p, now + Duration::from_secs(10), 0, true),
            None
        );
        state.activity(true, now);
        state.attached(1, now);
        state.attached(0, now);
        assert_eq!(
            state.reason(&p, now + Duration::from_secs(10), 0, true),
            None
        );
    }
    #[test]
    fn ttl_and_completion_are_independent_retirement_conditions() {
        let defaults: Policy = serde_json::from_str("{}").unwrap();
        assert_eq!(defaults.detached_ttl_seconds, 3 * 24 * 3600);
        assert!(defaults.close_on_agent_done);
        let now = Instant::now();
        let mut state = Lifetime::new(now);
        state.activity(true, now);
        let after_grace = now + Duration::from_secs(defaults.agent_done_grace_seconds);
        assert_eq!(
            state.reason(&defaults, after_grace, 0, true),
            Some(EndReason::AgentCompleted)
        );
        let unlimited = Policy {
            detached_ttl_seconds: 0,
            ..defaults.clone()
        };
        assert_eq!(
            state.reason(&unlimited, after_grace, 0, true),
            Some(EndReason::AgentCompleted)
        );
        let completion_disabled = Policy {
            close_on_agent_done: false,
            ..defaults.clone()
        };
        assert_eq!(
            state.reason(&completion_disabled, after_grace, 0, true),
            None
        );
        let expiry = now + Duration::from_secs(defaults.detached_ttl_seconds);
        state.activity(false, now);
        assert_eq!(
            state.reason(&defaults, expiry, 0, false),
            Some(EndReason::DetachedTimeout)
        );
        assert_eq!(
            state.reason(&completion_disabled, expiry, 0, true),
            Some(EndReason::DetachedTimeout)
        );
    }

    #[test]
    fn completion_grace_starts_after_both_detach_and_completion() {
        let now = Instant::now();
        let policy = Policy::default();
        let mut state = Lifetime::new(now);
        state.attached(1, now);
        state.activity(true, now + Duration::from_secs(10));
        state.attached(0, now + Duration::from_secs(100));
        assert_eq!(
            state.reason(&policy, now + Duration::from_secs(159), 0, true),
            None
        );
        assert_eq!(
            state.reason(&policy, now + Duration::from_secs(160), 0, true),
            Some(EndReason::AgentCompleted)
        );
    }

    #[test]
    fn deadline_only_expires_detached_sessions() {
        let now = Instant::now();
        let mut state = Lifetime::new(now);
        let p = Policy {
            expires_at: Some(42),
            ..Policy::default()
        };
        assert_eq!(state.reason(&p, now, 42, false), Some(EndReason::Deadline));
        state.attached(1, now);
        assert_eq!(state.reason(&p, now, 100, false), None);
    }
}
