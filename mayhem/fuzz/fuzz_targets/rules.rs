// Additive Mayhem fuzz target: vSMTP rule-engine (vSL) script compiler.
//
// Re-fit of the original `rules` target onto the current upstream API. The 2022
// tree used `RuleEngine::from_script(config, script)`; that constructor no
// longer exists. The current rule engine compiles a "root filter" vSL script
// through `RuleEngine::with_hierarchy`, whose builder callback exposes
// `add_root_filter_rules(script)` (the same `Script::compile_source` path the
// engine uses internally). We build the surrounding config / DNS resolvers /
// queue-manager ONCE (they are input-independent) and, per input, compile the
// fuzzed script into a fresh rule hierarchy — exercising the rhai + vSL
// front-end. Upstream sources are referenced by path; `src/` is untouched.
#![no_main]

use std::sync::{Arc, OnceLock};

use libfuzzer_sys::fuzz_target;
use vqueue::GenericQueueManager;
use vsmtp_config::{Config, DnsResolvers};
use vsmtp_rule_engine::RuleEngine;

struct Ctx {
    config: Arc<Config>,
    resolvers: Arc<DnsResolvers>,
    queue: Arc<dyn GenericQueueManager>,
}

fn ctx() -> &'static Ctx {
    static CTX: OnceLock<Ctx> = OnceLock::new();
    CTX.get_or_init(|| {
        // Mayhem mounts the commit image read-only; make relative spool/app
        // paths in the test config resolve under a writable tmpfs directory.
        let _ = std::env::set_current_dir("/tmp");

        let config = Arc::new(vsmtp_test::config::local_test());
        let queue = <vqueue::temp::QueueManager as GenericQueueManager>::init(config.clone(), vec![])
            .expect("temp queue-manager init");
        let resolvers = Arc::new(DnsResolvers::from_config(&config).expect("dns resolvers"));
        Ctx {
            config,
            resolvers,
            queue,
        }
    })
}

fuzz_target!(|data: &[u8]| {
    let script = match std::str::from_utf8(data) {
        Ok(s) => s.to_owned(),
        Err(_) => return,
    };
    let ctx = ctx();
    let _ = RuleEngine::with_hierarchy(
        move |builder| Ok(builder.add_root_filter_rules(&script)?.build()),
        ctx.config.clone(),
        ctx.resolvers.clone(),
        ctx.queue.clone(),
    );
});
