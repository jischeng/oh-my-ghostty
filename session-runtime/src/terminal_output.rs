// Adapted from herdr-core 5a9de29b2f9b6690388a1c297a7ca8d73df7d3e2.
// Apache-2.0; see ../LICENSE.herdr. Modified to use OMG's VT wrapper.
//! Program output -> the core's screen and the bytes viewers get.
//! Every byte reaches the screen. Viewers get every byte too, except queries
//! the screen answered itself: a viewer seeing them would answer a second time.

/// The actor's VT and reply queue are accessed serially.
pub(crate) trait Screen {
    fn write(&mut self, bytes: &[u8]);
    fn pending_responses(&self) -> usize;
}

const ESC: u8 = 0x1b;
const BEL: u8 = 0x07;
/// Queries are short; anything longer is passed through unexamined.
const MAX_CSI: usize = 64;
const MAX_STRING: usize = 512;

#[derive(Default)]
pub struct Relay {
    /// An escape sequence still arriving, kept back until it can be judged.
    held: Vec<u8>,
}

enum Seq {
    Pending,
    Done { maybe_query: bool },
}

impl Relay {
    /// Feeds program output; returns what viewers should get. Replies the
    /// screen produced are left in it for the caller to send to the program.
    pub fn feed(&mut self, screen: &mut impl Screen, input: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(input.len());
        let mut run = 0;
        for (i, &b) in input.iter().enumerate() {
            if self.held.is_empty() {
                if b == ESC {
                    pass(screen, &mut out, &input[run..i]);
                    self.held.push(b);
                }
                continue;
            }
            self.held.push(b);
            if let Seq::Done { maybe_query } = self.judge() {
                let seq = std::mem::take(&mut self.held);
                if maybe_query {
                    let before = screen.pending_responses();
                    screen.write(&seq);
                    if screen.pending_responses() == before {
                        out.extend_from_slice(&seq); // not answered here: the viewer may
                    }
                } else {
                    pass(screen, &mut out, &seq);
                }
                run = i + 1;
            }
        }
        if self.held.is_empty() {
            pass(screen, &mut out, &input[run..]);
        }
        out
    }

    fn judge(&self) -> Seq {
        let h = &self.held;
        let last = *h.last().expect("held starts with ESC");
        match h.get(1) {
            None => Seq::Pending,
            Some(b'[') if h.len() > 2 && (0x40..=0x7e).contains(&last) => Seq::Done {
                maybe_query: b"cnpqtu".contains(&last),
            },
            Some(b'[') if h.len() > MAX_CSI => Seq::Done { maybe_query: false },
            Some(b'[') => Seq::Pending,
            Some(b']') | Some(b'P') => {
                let ended = last == BEL && h[1] == b']' || h.ends_with(b"\x1b\\") && h.len() > 3;
                if ended {
                    let end_len = if last == BEL { 1 } else { 2 };
                    let body = &h[2..h.len() - end_len];
                    let query = match h[1] {
                        b']' => is_osc_query(body),
                        _ => body.starts_with(b"$q") || body.starts_with(b"+q"),
                    };
                    Seq::Done { maybe_query: query }
                } else if h.len() > MAX_STRING {
                    Seq::Done { maybe_query: false }
                } else {
                    Seq::Pending
                }
            }
            Some(_) => Seq::Done { maybe_query: false },
        }
    }
}

fn is_osc_query(body: &[u8]) -> bool {
    if let Some(rest) = body
        .strip_prefix(b"4;")
        .or_else(|| body.strip_prefix(b"10;"))
        .or_else(|| body.strip_prefix(b"11;"))
        .or_else(|| body.strip_prefix(b"12;"))
        .or_else(|| body.strip_prefix(b"52;"))
    {
        return rest.split(|&b| b == b';').any(|part| part == b"?");
    }
    if let Some(rest) = body.strip_prefix(b"21;") {
        return rest
            .split(|&b| b == b';')
            .any(|part| part == b"?" || part.ends_with(b"=?"));
    }
    if let Some(rest) = body.strip_prefix(b"7501;") {
        let start = rest
            .iter()
            .position(|b| !b.is_ascii_whitespace())
            .unwrap_or(rest.len());
        let end = rest[start..]
            .iter()
            .rposition(|b| !b.is_ascii_whitespace())
            .map_or(start, |idx| start + idx + 1);
        return &rest[start..end] == b"?";
    }
    false
}

fn pass(screen: &mut impl Screen, out: &mut Vec<u8>, bytes: &[u8]) {
    if !bytes.is_empty() {
        screen.write(bytes);
        out.extend_from_slice(bytes);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct MockScreen {
        written: Vec<u8>,
        replies_pending: usize,
    }

    impl Screen for MockScreen {
        fn write(&mut self, bytes: &[u8]) {
            self.written.extend_from_slice(bytes);
            if bytes.starts_with(b"\x1b") && bytes.contains(&b'?') {
                self.replies_pending += 1;
            }
        }
        fn pending_responses(&self) -> usize {
            self.replies_pending
        }
    }

    #[test]
    fn relay_strips_exact_osc_queries_while_preserving_hyperlinks_titles_and_reports() {
        let mut screen = MockScreen {
            written: Vec::new(),
            replies_pending: 0,
        };
        let mut relay = Relay::default();
        let hyperlink = b"\x1b]8;;https://example.com/q?a=1&b=2\x07link\x1b]8;;\x07";
        let title = b"\x1b]2;What?\x07";
        let cwd = b"\x1b]7;file://host/dir?x\x07";
        let status = b"\x1b]7501;state=working:app=antigravity\x07";
        let queries = concat!(
            "\x1b]4;0;?\x07",
            "\x1b]10;?\x07",
            "\x1b]11;?\x1b\\",
            "\x1b]12;?\x07",
            "\x1b]21;foreground=?\x07",
            "\x1b]52;c;?\x07",
            "\x1b]7501;?\x07",
        )
        .as_bytes();

        let mut visible = Vec::new();
        for chunk in [hyperlink.as_slice(), title, cwd, status, queries] {
            visible.extend_from_slice(&relay.feed(&mut screen, chunk));
        }
        let expected: Vec<u8> = [hyperlink.as_slice(), title, cwd, status].concat();
        assert_eq!(visible, expected);
        assert!(screen
            .written
            .windows(b"\x1b]10;?\x07".len())
            .any(|w| w == b"\x1b]10;?\x07"));
        assert!(screen
            .written
            .windows(b"\x1b]7501;?\x07".len())
            .any(|w| w == b"\x1b]7501;?\x07"));
    }
}
