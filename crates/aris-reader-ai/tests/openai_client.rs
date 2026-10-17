//! Client tests against a local mock HTTP server.
//!
//! The server is a plain `TcpListener` on 127.0.0.1 and the client uses the same
//! [`UreqTransport`] the app uses for HTTP and HTTPS. No test opens a connection to anything
//! except the loopback listener this process created.

use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use rustls::{ServerConfig, ServerConnection, StreamOwned};
use ureq::tls::Certificate;

use aris_reader_ai::AiError;
use aris_reader_ai::chat::{Action, ChatSettings, PageText, PlanRequest, build_plan};
use aris_reader_ai::openai::{
    CancellationToken, ClientConfig, RequestSpec, RunEvent, TokenUsage, UreqTransport,
    run_plan_with_transport,
};

#[derive(Clone, Debug)]
struct RecordedRequest {
    method: String,
    path: String,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
}

impl RecordedRequest {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(candidate, _)| candidate.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }
}

#[derive(Clone)]
enum Behavior {
    /// Stream the given body chunks (already framed as transferred bytes), then close.
    Chunked {
        chunks: Vec<Vec<u8>>,
        delay: Duration,
        watch_close: bool,
    },
    /// Answer with a fixed status and body.
    Error {
        status: u16,
        reason: &'static str,
        body: Vec<u8>,
    },
}

struct Server {
    base_url: String,
    recorded: Arc<Mutex<Option<RecordedRequest>>>,
    closed: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
}

impl Server {
    fn start(behavior: Behavior) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback");
        listener.set_nonblocking(false).expect("blocking listener");
        let address = listener.local_addr().expect("local address");
        let recorded = Arc::new(Mutex::new(None));
        let closed = Arc::new(AtomicBool::new(false));
        let recorded_for_thread = Arc::clone(&recorded);
        let closed_for_thread = Arc::clone(&closed);
        let handle = thread::spawn(move || {
            let (mut stream, _) = match listener.accept() {
                Ok(connection) => connection,
                Err(_) => return,
            };
            let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
            let request = match read_request(&mut stream) {
                Some(request) => request,
                None => return,
            };
            *recorded_for_thread.lock().unwrap() = Some(request);
            match behavior {
                Behavior::Chunked {
                    chunks,
                    delay,
                    watch_close,
                } => {
                    let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n";
                    if stream.write_all(headers.as_bytes()).is_err() {
                        return;
                    }
                    let _ = stream.flush();
                    for chunk in chunks {
                        if write_chunk(&mut stream, &chunk).is_err() {
                            break;
                        }
                        thread::sleep(delay);
                    }
                    if !watch_close {
                        let _ = write_chunk(&mut stream, b"");
                        let _ = stream.flush();
                    }
                    if watch_close {
                        // Wait for the client to close, so cancellation is observable on the
                        // server side too.
                        let _ = stream.set_read_timeout(Some(Duration::from_secs(3)));
                        let mut buffer = [0u8; 1];
                        loop {
                            match stream.read(&mut buffer) {
                                Ok(0) => {
                                    closed_for_thread.store(true, Ordering::SeqCst);
                                    break;
                                }
                                Ok(_) => {}
                                Err(error)
                                    if error.kind() == std::io::ErrorKind::WouldBlock
                                        || error.kind() == std::io::ErrorKind::TimedOut =>
                                {
                                    break;
                                }
                                Err(_) => {
                                    closed_for_thread.store(true, Ordering::SeqCst);
                                    break;
                                }
                            }
                        }
                    }
                }
                Behavior::Error {
                    status,
                    reason,
                    body,
                } => {
                    let head = format!(
                        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        body.len()
                    );
                    let _ = stream.write_all(head.as_bytes());
                    let _ = stream.write_all(&body);
                    let _ = stream.flush();
                }
            }
        });
        Self {
            base_url: format!("http://{address}/v1"),
            recorded,
            closed,
            handle: Some(handle),
        }
    }

    fn join(&mut self) {
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }

    fn wait_closed(&self, timeout: Duration) -> bool {
        let started = Instant::now();
        while started.elapsed() < timeout {
            if self.closed.load(Ordering::SeqCst) {
                return true;
            }
            thread::sleep(Duration::from_millis(10));
        }
        self.closed.load(Ordering::SeqCst)
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        self.join();
    }
}

fn write_chunk<W: Write>(stream: &mut W, chunk: &[u8]) -> std::io::Result<()> {
    if chunk.is_empty() {
        stream.write_all(b"0\r\n\r\n")?;
    } else {
        stream.write_all(format!("{:x}\r\n", chunk.len()).as_bytes())?;
        stream.write_all(chunk)?;
        stream.write_all(b"\r\n")?;
    }
    stream.flush()
}

fn read_request<R: Read>(stream: &mut R) -> Option<RecordedRequest> {
    let mut buffer = Vec::new();
    let mut chunk = [0u8; 4096];
    loop {
        let read = stream.read(&mut chunk).ok()?;
        if read == 0 {
            return None;
        }
        buffer.extend_from_slice(&chunk[..read]);
        if let Some(end) = find(&buffer, b"\r\n\r\n") {
            let head = String::from_utf8_lossy(&buffer[..end]).to_string();
            let mut lines = head.split("\r\n");
            let request_line = lines.next()?;
            let mut parts = request_line.split_whitespace();
            let method = parts.next()?.to_string();
            let path = parts.next()?.to_string();
            let mut headers = Vec::new();
            for line in lines {
                if let Some((name, value)) = line.split_once(':') {
                    headers.push((name.trim().to_string(), value.trim().to_string()));
                }
            }
            let content_length = headers
                .iter()
                .find(|(name, _)| name.eq_ignore_ascii_case("content-length"))
                .and_then(|(_, value)| value.parse::<usize>().ok())
                .unwrap_or(0);
            let mut body = buffer[end + 4..].to_vec();
            while body.len() < content_length {
                let read = stream.read(&mut chunk).ok()?;
                if read == 0 {
                    break;
                }
                body.extend_from_slice(&chunk[..read]);
            }
            body.truncate(content_length);
            return Some(RecordedRequest {
                method,
                path,
                headers,
                body,
            });
        }
        if buffer.len() > 128 * 1024 {
            return None;
        }
    }
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

fn plan_for(server: &Server) -> aris_reader_ai::ChatPlan {
    plan_for_base(&server.base_url)
}

fn plan_for_base(base_url: &str) -> aris_reader_ai::ChatPlan {
    build_plan(PlanRequest {
        action: Action::SummarizePage,
        document_title: "Mock-server paper".to_string(),
        page_count: 2,
        current_page: 0,
        selection: None,
        question: None,
        language: None,
        pages: vec![
            PageText {
                page: 0,
                text: "The method builds a local index and ranks document blocks before it streams an answer."
                    .to_string(),
            },
            PageText {
                page: 1,
                text: "A different page discusses evaluation and measurements in enough detail."
                    .to_string(),
            },
        ],
        settings: ChatSettings {
            base_url: base_url.to_string(),
            model: "test-model".to_string(),
            temperature: Some(0.2),
            max_tokens: Some(128),
        },
    })
    .expect("plan")
}

fn fast_config() -> ClientConfig {
    ClientConfig {
        connect_timeout: Duration::from_secs(2),
        idle_timeout: Duration::from_secs(3),
        max_time: Duration::from_secs(5),
    }
}

fn key() -> &'static str {
    "sk-test-not-a-real-key-1234567890"
}

#[test]
fn request_matches_the_preview_and_streams_split_sse() {
    let mut server = Server::start(Behavior::Chunked {
        chunks: vec![
            b"data: {\"choices\":[{\"delta\":{\"content\":\"Hello".to_vec(),
            b" from the paper\"}}]}\n\ndata: {\"choices\":[],\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":4,\"total_tokens\":16}}\n\n".to_vec(),
            b"data: [D".to_vec(),
            b"ONE]\n\n".to_vec(),
        ],
        delay: Duration::from_millis(5),
        watch_close: false,
    });
    let plan = plan_for(&server);
    let transport = UreqTransport::system(fast_config());
    let cancel = CancellationToken::new();
    let mut text = String::new();
    let mut usage = None;
    let mut done = false;
    let mut started = Vec::new();
    let mut received = Vec::new();
    run_plan_with_transport(&plan, key(), &transport, &cancel, &mut |event| {
        received.push(event.clone());
        match event {
            RunEvent::PartStarted { index, .. } => started.push(index),
            RunEvent::Delta(delta) => text.push_str(&delta),
            RunEvent::Usage(values) => usage = Some(values),
            RunEvent::Done => done = true,
        }
    })
    .expect("stream");
    server.join();

    assert_eq!(started, vec![0]);
    assert_eq!(text, "Hello from the paper");
    assert_eq!(
        usage,
        Some(TokenUsage {
            prompt_tokens: Some(12),
            completion_tokens: Some(4),
            total_tokens: Some(16)
        })
    );
    assert!(done);

    let recorded = server.recorded.lock().unwrap().clone().expect("request");
    assert_eq!(recorded.method, "POST");
    assert_eq!(recorded.path, "/v1/chat/completions");
    let expected_authorization = format!("Bearer {}", key());
    assert_eq!(
        recorded.header("authorization"),
        Some(expected_authorization.as_str())
    );
    assert_eq!(recorded.header("content-type"), Some("application/json"));
    assert_eq!(recorded.header("accept"), Some("text/event-stream"));
    assert_eq!(
        String::from_utf8(recorded.body).unwrap(),
        plan.parts[0].wire_body,
        "the bytes on the wire must be exactly the previewed body"
    );
    assert!(plan.parts[0].wire_body.contains("\"stream\":true"));
}

#[test]
fn a_401_error_body_is_readable_and_the_key_is_redacted() {
    let mut server = Server::start(Behavior::Error {
        status: 401,
        reason: "Unauthorized",
        body: format!(
            "{{\"error\":{{\"message\":\"Incorrect API key provided: {}. Check your key.\",\"type\":\"invalid_request_error\"}}}}",
            key()
        )
        .into_bytes(),
    });
    let plan = plan_for(&server);
    let transport = UreqTransport::system(fast_config());
    let cancel = CancellationToken::new();
    let error = run_plan_with_transport(&plan, key(), &transport, &cancel, &mut |_| {})
        .expect_err("401 must fail");
    server.join();
    let message = error.to_string();
    assert!(
        message.contains("Authentication failed"),
        "message: {message}"
    );
    assert!(message.contains("HTTP 401"), "message: {message}");
    assert!(message.contains("Incorrect API key"), "message: {message}");
    assert!(
        !message.contains(key()),
        "the key leaked into the error: {message}"
    );
    assert!(message.contains("<redacted>"), "message: {message}");
}

#[test]
fn a_mid_stream_disconnect_is_reported_as_incomplete() {
    let mut server = Server::start(Behavior::Chunked {
        chunks: vec![b"data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n".to_vec()],
        delay: Duration::from_millis(5),
        watch_close: false,
    });
    let plan = plan_for(&server);
    let transport = UreqTransport::system(fast_config());
    let cancel = CancellationToken::new();
    let error = run_plan_with_transport(&plan, key(), &transport, &cancel, &mut |_| {})
        .expect_err("missing [DONE] must fail");
    server.join();
    assert!(error.to_string().contains("[DONE]"), "message: {error}");
}

#[test]
fn cancellation_closes_the_http_request() {
    let mut server = Server::start(Behavior::Chunked {
        chunks: vec![b"data: {\"choices\":[{\"delta\":{\"content\":\"first\"}}]}\n\n".to_vec()],
        delay: Duration::from_millis(10),
        watch_close: true,
    });
    let plan = plan_for(&server);
    let transport = UreqTransport::system(fast_config());
    let cancel = CancellationToken::new();
    let (sender, receiver) = mpsc::channel();
    let cancel_for_thread = cancel.clone();
    let key = key().to_string();
    let worker = thread::spawn(move || {
        run_plan_with_transport(&plan, &key, &transport, &cancel_for_thread, &mut |event| {
            let _ = sender.send(event);
        })
    });

    loop {
        let event = receiver
            .recv_timeout(Duration::from_secs(3))
            .expect("an event");
        if matches!(event, RunEvent::Delta(_)) {
            break;
        }
    }
    cancel.cancel();
    let result = worker.join().expect("worker thread");
    assert_eq!(result, Err(AiError::Cancelled));
    assert!(
        server.wait_closed(Duration::from_secs(3)),
        "the server did not observe the request being closed"
    );
    server.join();
}

#[test]
fn an_idle_stream_times_out_with_a_readable_message() {
    let mut server = Server::start(Behavior::Chunked {
        chunks: Vec::new(),
        delay: Duration::from_millis(10),
        watch_close: true,
    });
    let plan = plan_for(&server);
    let transport = UreqTransport::system(ClientConfig {
        connect_timeout: Duration::from_secs(2),
        idle_timeout: Duration::from_millis(150),
        max_time: Duration::from_secs(5),
    });
    let cancel = CancellationToken::new();
    let error = run_plan_with_transport(&plan, key(), &transport, &cancel, &mut |_| {})
        .expect_err("idle stream must time out");
    assert!(
        matches!(error, AiError::Timeout(ref message) if message.contains("idle timeout")),
        "error: {error}"
    );
    server.join();
}

// ── TLS ─────────────────────────────────────────────────────────────────────────────────────

struct TestTlsIdentity {
    ca_der: Vec<u8>,
    leaf_der: CertificateDer<'static>,
    leaf_key: PrivateKeyDer<'static>,
}

fn test_tls_identity() -> TestTlsIdentity {
    let ca_key = rcgen::KeyPair::generate().expect("CA key");
    let mut ca_params = rcgen::CertificateParams::default();
    ca_params.is_ca = rcgen::IsCa::Ca(rcgen::BasicConstraints::Unconstrained);
    ca_params
        .distinguished_name
        .push(rcgen::DnType::CommonName, "Lyra test CA");
    let ca_cert = ca_params.self_signed(&ca_key).expect("CA certificate");

    let leaf_key = rcgen::KeyPair::generate().expect("leaf key");
    let mut leaf_params =
        rcgen::CertificateParams::new(vec!["localhost".to_string()]).expect("leaf parameters");
    leaf_params
        .distinguished_name
        .push(rcgen::DnType::CommonName, "localhost");
    let leaf_cert = leaf_params
        .signed_by(&leaf_key, &ca_cert, &ca_key)
        .expect("leaf certificate");

    TestTlsIdentity {
        ca_der: ca_cert.der().as_ref().to_vec(),
        leaf_der: CertificateDer::from(leaf_cert.der().as_ref().to_vec()),
        leaf_key: PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(leaf_key.serialize_der())),
    }
}

struct TlsServer {
    base_url: String,
    recorded: Arc<Mutex<Option<RecordedRequest>>>,
    handle: Option<JoinHandle<()>>,
}

impl TlsServer {
    fn start(identity: TestTlsIdentity, behavior: Behavior) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind TLS loopback");
        let port = listener.local_addr().expect("TLS local address").port();
        let config =
            ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
                .with_safe_default_protocol_versions()
                .expect("TLS versions")
                .with_no_client_auth()
                .with_single_cert(vec![identity.leaf_der], identity.leaf_key)
                .expect("server certificate");
        let config = Arc::new(config);
        let recorded = Arc::new(Mutex::new(None));
        let recorded_for_thread = Arc::clone(&recorded);
        let handle = thread::spawn(move || {
            let (tcp, _) = match listener.accept() {
                Ok(connection) => connection,
                Err(_) => return,
            };
            let _ = tcp.set_read_timeout(Some(Duration::from_secs(5)));
            let connection = match ServerConnection::new(config) {
                Ok(connection) => connection,
                Err(_) => return,
            };
            let mut stream = StreamOwned::new(connection, tcp);
            let Some(request) = read_request(&mut stream) else {
                return;
            };
            *recorded_for_thread.lock().unwrap() = Some(request);
            match behavior {
                Behavior::Chunked {
                    chunks,
                    delay,
                    watch_close,
                } => {
                    let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n";
                    if stream.write_all(head.as_bytes()).is_err() {
                        return;
                    }
                    let _ = stream.flush();
                    for chunk in chunks {
                        if write_chunk(&mut stream, &chunk).is_err() {
                            break;
                        }
                        thread::sleep(delay);
                    }
                    if !watch_close {
                        let _ = write_chunk(&mut stream, b"");
                        let _ = stream.flush();
                    } else {
                        // Wait for the client to close, so a cancellation test observes the TLS
                        // connection being dropped rather than a clean end of body.
                        let mut buffer = [0u8; 1];
                        loop {
                            match stream.read(&mut buffer) {
                                Ok(0) => break,
                                Ok(_) => {}
                                Err(_) => break,
                            }
                        }
                    }
                }
                Behavior::Error {
                    status,
                    reason,
                    body,
                } => {
                    let head = format!(
                        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        body.len()
                    );
                    let _ = stream.write_all(head.as_bytes());
                    let _ = stream.write_all(&body);
                    let _ = stream.flush();
                }
            }
        });
        Self {
            base_url: format!("https://localhost:{port}/v1"),
            recorded,
            handle: Some(handle),
        }
    }

    fn join(&mut self) {
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }
}

impl Drop for TlsServer {
    fn drop(&mut self) {
        self.join();
    }
}

#[test]
fn tls_streaming_round_trip_with_an_injected_ca() {
    let identity = test_tls_identity();
    let ca_der = identity.ca_der.clone();
    let mut server = TlsServer::start(
        identity,
        Behavior::Chunked {
            chunks: vec![
                b"data: {\"choices\":[{\"delta\":{\"content\":\"Hello over TLS\"}}]}\n\n".to_vec(),
                b"data: {\"choices\":[],\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":3,\"total_tokens\":10}}\n\n".to_vec(),
                b"data: [DONE]\n\n".to_vec(),
            ],
            delay: Duration::from_millis(5),
            watch_close: false,
        },
    );
    let plan = plan_for_base(&server.base_url);
    let transport = UreqTransport::with_certificates(
        fast_config(),
        vec![Certificate::from_der(&ca_der).to_owned()],
    );
    let cancel = CancellationToken::new();
    let mut text = String::new();
    let mut usage = None;
    let mut done = false;
    run_plan_with_transport(
        &plan,
        key(),
        &transport,
        &cancel,
        &mut |event| match event {
            RunEvent::Delta(delta) => text.push_str(&delta),
            RunEvent::Usage(values) => usage = Some(values),
            RunEvent::Done => done = true,
            _ => {}
        },
    )
    .expect("TLS streaming round trip");
    server.join();

    assert_eq!(text, "Hello over TLS");
    assert_eq!(
        usage,
        Some(TokenUsage {
            prompt_tokens: Some(7),
            completion_tokens: Some(3),
            total_tokens: Some(10)
        })
    );
    assert!(done);
    let recorded = server
        .recorded
        .lock()
        .unwrap()
        .clone()
        .expect("TLS request");
    assert_eq!(recorded.path, "/v1/chat/completions");
    let expected = format!("Bearer {}", key());
    assert_eq!(recorded.header("authorization"), Some(expected.as_str()));
    assert_eq!(
        String::from_utf8(recorded.body).unwrap(),
        plan.parts[0].wire_body
    );
}

#[test]
fn tls_cancellation_aborts_a_blocking_read() {
    let identity = test_tls_identity();
    let ca_der = identity.ca_der.clone();
    let mut server = TlsServer::start(
        identity,
        Behavior::Chunked {
            chunks: vec![b"data: {\"choices\":[{\"delta\":{\"content\":\"first\"}}]}\n\n".to_vec()],
            delay: Duration::from_millis(5),
            watch_close: true,
        },
    );
    let plan = plan_for_base(&server.base_url);
    let transport = UreqTransport::with_certificates(
        fast_config(),
        vec![Certificate::from_der(&ca_der).to_owned()],
    );
    let cancel = CancellationToken::new();
    let (sender, receiver) = mpsc::channel();
    let cancel_for_thread = cancel.clone();
    let key = key().to_string();
    let worker = thread::spawn(move || {
        run_plan_with_transport(&plan, &key, &transport, &cancel_for_thread, &mut |event| {
            let _ = sender.send(event);
        })
    });

    loop {
        let event = receiver
            .recv_timeout(Duration::from_secs(3))
            .expect("a delta over TLS");
        if matches!(event, RunEvent::Delta(_)) {
            break;
        }
    }
    let started = Instant::now();
    cancel.cancel();
    let result = worker.join().expect("TLS worker");
    assert_eq!(result, Err(AiError::Cancelled));
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "TLS cancellation took {:?}",
        started.elapsed()
    );
    server.join();
}

#[test]
fn tls_refuses_an_untrusted_certificate() {
    let server_identity = test_tls_identity();
    let other_identity = test_tls_identity();
    let mut server = TlsServer::start(
        server_identity,
        Behavior::Chunked {
            chunks: Vec::new(),
            delay: Duration::from_millis(1),
            watch_close: false,
        },
    );
    let plan = plan_for_base(&server.base_url);
    let transport = UreqTransport::with_certificates(
        fast_config(),
        vec![Certificate::from_der(&other_identity.ca_der).to_owned()],
    );
    let cancel = CancellationToken::new();
    let error = run_plan_with_transport(&plan, key(), &transport, &cancel, &mut |_| {})
        .expect_err("an untrusted certificate must be refused");
    let message = error.to_string();
    assert!(
        message.to_ascii_lowercase().contains("tls")
            || message.to_ascii_lowercase().contains("certificate"),
        "expected a TLS/certificate error, got: {message}"
    );
    assert!(!matches!(error, AiError::Cancelled));
    server.join();
}

#[test]
fn the_request_spec_never_prints_its_key_or_body() {
    let plan = build_plan(PlanRequest {
        action: Action::SummarizePage,
        document_title: "No server".to_string(),
        page_count: 1,
        current_page: 0,
        selection: None,
        question: None,
        language: None,
        pages: vec![PageText {
            page: 0,
            text: "A local index ranks document blocks before an answer is streamed.".to_string(),
        }],
        settings: ChatSettings {
            base_url: "http://127.0.0.1:9/v1".to_string(),
            model: "test-model".to_string(),
            temperature: None,
            max_tokens: None,
        },
    })
    .unwrap();
    let spec: RequestSpec =
        aris_reader_ai::build_request_spec(&plan, &plan.parts[0], key()).unwrap();
    let debug = format!("{spec:?}");
    assert!(!debug.contains(key()));
    assert!(!debug.contains("local index"));
    assert!(debug.contains("<redacted>"));
}
