// Additive Mayhem fuzz target: vSMTP MIME/mail parser.
//
// Re-fit of the original `mime_parser` target onto the current upstream
// (erebe/vSMTP) API. In the 2022 tree this called
// `MailMimeParser::default().parse_lines(&[&str])`; the current
// `vsmtp-mail-parser` exposes the parser through the `MailParser` trait whose
// entry point is `parse_sync(Vec<Vec<u8>>)` (one `Vec<u8>` per line). We feed
// the fuzz input split into CRLF/LF lines. Upstream sources are referenced by
// path from the additive `mayhem/fuzz` crate; nothing under `src/` is modified.
#![no_main]

use libfuzzer_sys::fuzz_target;
use vsmtp_mail_parser::{MailMimeParser, MailParser};

fuzz_target!(|data: &[u8]| {
    // The upstream parser unwraps its input as UTF-8 (vsmtp-mail-parser
    // mail_mime_parser.rs:41) — it is fed already-decoded SMTP lines, and the
    // original target took `&[&str]`. Feeding raw non-UTF-8 bytes makes it panic on
    // the FIRST such byte, so the target crashes before covering anything. Decode
    // lossily first (matching the &str contract) so we fuzz the parser logic instead
    // of the trivial UTF-8 boundary.
    let text = String::from_utf8_lossy(data);
    // Split into lines the way an SMTP message body arrives (CRLF/LF framed),
    // one `Vec<u8>` per line, matching what the receiver feeds the parser.
    let lines: Vec<Vec<u8>> = text
        .split('\n')
        .map(|line| line.strip_suffix('\r').unwrap_or(line).as_bytes().to_vec())
        .collect();

    let _ = MailMimeParser::default().parse_sync(lines);
});
