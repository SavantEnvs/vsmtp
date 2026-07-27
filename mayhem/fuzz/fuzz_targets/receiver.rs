// Additive Mayhem fuzz target: vSMTP SMTP receiver (full protocol state machine).
//
// Re-fit of the original `receiver` target onto the current upstream API. The
// 2022 tree drove `vsmtp_server::Connection::receive` over an in-memory `Mock`
// stream. In the current tree the receiver lives in `vsmtp-protocol`
// (`Receiver` + `ReceiverHandler`), and its only public constructor
// (`Receiver::new` + `into_stream`) is specialised to `tokio::net::TcpStream`
// (the struct fields are `pub(crate)`, so a generic in-memory stream cannot be
// built from outside the crate). We therefore embed a real vSMTP receiver on an
// ephemeral loopback socket and feed it the fuzz bytes as a client — the entire
// SMTP handshake + command + message state machine runs in-process, exactly the
// code path the original harness covered. The heavy server context (config,
// rule engine, queue manager) is built ONCE; each input creates one short-lived
// loopback connection (client uses SO_LINGER=0 to send RST on close, avoiding
// TIME_WAIT port exhaustion across millions of iterations). Upstream sources are
// referenced by path; `src/` is untouched.
#![no_main]

use std::sync::{Arc, OnceLock};

use libfuzzer_sys::fuzz_target;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio_stream::StreamExt;
use vqueue::GenericQueueManager;
use vsmtp_config::{Config, DnsResolvers};
use vsmtp_protocol::{ConnectionKind, Receiver};
use vsmtp_rule_engine::RuleEngine;
use vsmtp_server::{Handler, ValidationVSL};
use vsmtp_test::receiver::DefaultMailHandler;

struct Srv {
    rt: tokio::runtime::Runtime,
    config: Arc<Config>,
    rule_engine: Arc<RuleEngine>,
    queue: Arc<dyn GenericQueueManager>,
}

fn srv() -> &'static Srv {
    static SRV: OnceLock<Srv> = OnceLock::new();
    SRV.get_or_init(|| {
        // Read-only image: relative spool/app paths must resolve under tmpfs.
        let _ = std::env::set_current_dir("/tmp");

        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("tokio runtime");

        let config = Arc::new(vsmtp_test::config::local_test());
        let queue = <vqueue::temp::QueueManager as GenericQueueManager>::init(config.clone(), vec![])
            .expect("temp queue-manager init");
        let resolvers = Arc::new(DnsResolvers::from_config(&config).expect("dns resolvers"));
        let rule_engine =
            Arc::new(RuleEngine::new(config.clone(), resolvers, queue.clone()).expect("rule engine"));

        Srv {
            rt,
            config,
            rule_engine,
            queue,
        }
    })
}

fuzz_target!(|data: &[u8]| {
    let srv = srv();
    let data = data.to_vec();

    srv.rt.block_on(async move {
        let listener = match TcpListener::bind("127.0.0.1:0").await {
            Ok(l) => l,
            Err(_) => return,
        };
        let addr = match listener.local_addr() {
            Ok(a) => a,
            Err(_) => return,
        };

        let config = srv.config.clone();
        let rule_engine = srv.rule_engine.clone();
        let queue = srv.queue.clone();

        let server = async move {
            let (sock, client_addr) = match listener.accept().await {
                Ok(x) => x,
                Err(_) => return,
            };
            let server_addr = match sock.local_addr() {
                Ok(a) => a,
                Err(_) => return,
            };

            let handler = Handler::new(
                Box::new(DefaultMailHandler::default()),
                config.clone(),
                None,
                rule_engine,
                queue,
            );
            let receiver = Receiver::<_, ValidationVSL, _, _>::new(
                sock,
                ConnectionKind::Relay,
                handler,
                config.server.smtp.error.soft_count,
                config.server.smtp.error.hard_count,
                config.server.message_size_limit,
            );
            let stream = receiver.into_stream(
                client_addr,
                server_addr,
                time::OffsetDateTime::now_utc(),
                uuid::Uuid::new_v4(),
            );
            tokio::pin!(stream);
            while let Some(Ok(())) = stream.next().await {}
        };

        let client = async move {
            let sock = match TcpStream::connect(addr).await {
                Ok(s) => s,
                Err(_) => return,
            };
            // RST on close instead of FIN -> no TIME_WAIT buildup while fuzzing.
            let _ = sock.set_linger(Some(std::time::Duration::from_secs(0)));
            let (mut rd, mut wr) = sock.into_split();
            let writer = async move {
                let _ = wr.write_all(&data).await;
                let _ = wr.shutdown().await;
            };
            let reader = async move {
                let mut buf = [0u8; 1024];
                loop {
                    match rd.read(&mut buf).await {
                        Ok(0) | Err(_) => break,
                        Ok(_) => {}
                    }
                }
            };
            tokio::join!(writer, reader);
        };

        // Bound each input so a wedged transaction can never hang the fuzzer.
        let _ = tokio::time::timeout(std::time::Duration::from_secs(5), async {
            tokio::join!(server, client)
        })
        .await;
    });
});
