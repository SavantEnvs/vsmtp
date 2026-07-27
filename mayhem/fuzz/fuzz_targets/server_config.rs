// Additive Mayhem fuzz target: vSMTP server configuration parser.
//
// Re-fit of the original `server-config` target onto the current upstream API.
// The 2022 tree parsed a TOML config via `Config::from_toml`; the current
// vSMTP configuration format is a rhai (vSL) script, parsed by
// `Config::from_vsl_script`, which compiles the script, runs its `on_config`
// function and deserializes the resulting map into a `Config`. That whole path
// (rhai compile + eval + serde) is what we fuzz here. Upstream sources are
// referenced by path from the additive `mayhem/fuzz` crate; `src/` is untouched.
#![no_main]

use libfuzzer_sys::fuzz_target;
use vsmtp_config::Config;

fuzz_target!(|data: &[u8]| {
    if let Ok(script) = std::str::from_utf8(data) {
        // `None` resolve-path: no module resolution against the filesystem.
        let _ = Config::from_vsl_script(script, None);
    }
});
