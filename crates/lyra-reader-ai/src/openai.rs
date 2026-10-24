//! OpenAI-compatible chat transport: request construction, streaming SSE decoding, timeouts,
//! cancellation and readable HTTP errors.
//!
//! The protocol is the one OpenAI, DeepSeek and local Ollama expose:
//! `POST {base}/chat/completions` with a JSON body and `stream: true`; the answer arrives as
//! server-sent events whose `data:` lines are JSON objects and whose last event is `[DONE]`.
//!
//! One transport is used for both schemes: [`UreqTransport`] runs `http://` and `https://`
//! through the same ureq/rustls client. The loopback tests therefore exercise the same
//! connection, TLS, timeout and body-reading code the app uses for a real provider; only the
//! certificate roots differ (`with_certificates` in the tests).
//!
//! Trust roots come from the operating system through `rustls-native-certs`. If that yields no
//! certificates, the client falls back to ureq's bundled webpki roots. If neither is usable the
//! handshake fails with the provider's certificate error, surfaced as a readable message.
//!
//! The client never logs. The key lives only in the request's `Authorization` header and in the
//! in-process request spec; there is no shell-out and no temporary request file.

use std::fmt;
use std::io::Read;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use serde_json::Value;
use ureq::tls::{Certificate, RootCerts, TlsConfig};
use ureq::unversioned::resolver::DefaultResolver;
use ureq::unversioned::transport::time::Duration as UreqDuration;
use ureq::unversioned::transport::{
    Buffers, ConnectionDetails, Connector, DefaultConnector, NextTimeout,
    Transport as UreqTransportTrait,
};

use crate::chat::{ChatPart, ChatPlan};
use crate::provider::{AiError, AiFailure};

/// Default time allowed to establish a connection.
pub const DEFAULT_CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// Default time with no bytes received before the request is considered stalled.
pub const DEFAULT_IDLE_TIMEOUT: Duration = Duration::from_secs(60);
/// Default total budget for one request, including streaming.
pub const DEFAULT_MAX_TIME: Duration = Duration::from_secs(300);
/// How often blocking transports wake up to check cancellation.
const POLL_INTERVAL: Duration = Duration::from_millis(100);
/// Longest error body kept in an error message.
const MAX_ERROR_BODY: usize = 32 * 1024;
/// Longest diagnostic text taken from a server body.
const MAX_DETAIL_CHARS: usize = 600;

/// A cancellation flag shared with a request worker.
#[derive(Clone, Debug, Default)]
pub struct CancellationToken {
    cancelled: Arc<AtomicBool>,
}

impl CancellationToken {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::SeqCst);
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::SeqCst)
    }

    /// Turn the flag into the error every transport returns once it has stopped.
    pub fn check(&self) -> Result<(), AiError> {
        if self.is_cancelled() {
            Err(AiError::Cancelled)
        } else {
            Ok(())
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct ClientConfig {
    pub connect_timeout: Duration,
    pub idle_timeout: Duration,
    pub max_time: Duration,
}

impl Default for ClientConfig {
    fn default() -> Self {
        Self {
            connect_timeout: DEFAULT_CONNECT_TIMEOUT,
            idle_timeout: DEFAULT_IDLE_TIMEOUT,
            max_time: DEFAULT_MAX_TIME,
        }
    }
}

/// The exact HTTP request for one plan part.
///
/// Its `Debug` implementation is deliberately redacted: a request carries the API key and the
/// document text, and neither belongs in a log line.
pub struct RequestSpec {
    pub url: String,
    pub method: &'static str,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
    /// Whether this endpoint is loopback. Connection failures mean different things for a local
    /// server and a remote provider, and the transport is the only layer that sees the OS error.
    pub is_local: bool,
}

impl fmt::Debug for RequestSpec {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RequestSpec")
            .field("url", &self.url)
            .field("method", &self.method)
            .field("headers", &redact_headers(&self.headers))
            .field("body_bytes", &self.body.len())
            .finish()
    }
}

/// Build the request for one part.
///
/// The key is checked for line breaks (header injection) and placed only in the `Authorization`
/// header. The body is the plan's `wire_body`, so the preview and the request cannot diverge.
pub fn build_request_spec(
    plan: &ChatPlan,
    part: &ChatPart,
    api_key: &str,
) -> Result<RequestSpec, AiError> {
    if api_key.is_empty() {
        return Err(AiError::InvalidSettings(
            "No API key is configured. Add one in Settings > AI; nothing was sent.".to_string(),
        ));
    }
    if api_key.chars().any(|character| character.is_control()) {
        return Err(AiError::InvalidSettings(
            "The API key contains a control character or line break, so it was not sent."
                .to_string(),
        ));
    }
    // A record passed back across FFI is data, not a promise: refuse a body that is not the
    // JSON shape this client produces rather than send it.
    let parsed: Value = serde_json::from_str(&part.wire_body).map_err(|_| {
        AiError::InvalidSettings(
            "The request preview is not valid JSON, so nothing was sent.".to_string(),
        )
    })?;
    if parsed.get("messages").and_then(Value::as_array).is_none()
        || parsed.get("model").and_then(Value::as_str).is_none()
    {
        return Err(AiError::InvalidSettings(
            "The request preview is missing its model or messages, so nothing was sent."
                .to_string(),
        ));
    }

    Ok(RequestSpec {
        url: plan.endpoint.clone(),
        method: "POST",
        headers: vec![
            ("Content-Type".to_string(), "application/json".to_string()),
            ("Accept".to_string(), "text/event-stream".to_string()),
            ("Authorization".to_string(), format!("Bearer {api_key}")),
            ("User-Agent".to_string(), "LyraReader/0.0".to_string()),
        ],
        body: part.wire_body.as_bytes().to_vec(),
        is_local: plan.is_local,
    })
}

/// The headers the preview shows. The key is not available when a plan is built, so the value is
/// a redaction; the other headers are the ones [`build_request_spec`] actually sends.
pub fn preview_headers() -> Vec<(String, String)> {
    vec![
        ("Content-Type".to_string(), "application/json".to_string()),
        ("Accept".to_string(), "text/event-stream".to_string()),
        (
            "Authorization".to_string(),
            "Bearer <redacted until you press Send>".to_string(),
        ),
        ("User-Agent".to_string(), "LyraReader/0.0".to_string()),
    ]
}

fn redact_headers(headers: &[(String, String)]) -> Vec<(String, String)> {
    headers
        .iter()
        .map(|(name, value)| {
            if name.eq_ignore_ascii_case("authorization") {
                (name.clone(), "Bearer <redacted>".to_string())
            } else {
                (name.clone(), value.clone())
            }
        })
        .collect()
}

/// Remove a key from any text that might reach the reader.
pub fn redact(text: &str, key: &str) -> String {
    if key.len() >= 4 {
        text.replace(key, "<redacted>")
    } else {
        text.replace(&format!("Bearer {key}"), "Bearer <redacted>")
    }
}

/// Redact every message-shaped error variant. Called by [`run_plan`] before an error leaves the
/// client, so a provider that echoes a key in its error body cannot put it in the panel.
pub fn redact_error(error: AiError, key: &str) -> AiError {
    match error {
        AiError::Unreachable(message) => AiError::Unreachable(redact(&message, key)),
        AiError::Offline(message) => AiError::Offline(redact(&message, key)),
        AiError::LocalServer(message) => AiError::LocalServer(redact(&message, key)),
        AiError::InvalidSettings(message) => AiError::InvalidSettings(redact(&message, key)),
        AiError::EmptyContext(message) => AiError::EmptyContext(redact(&message, key)),
        AiError::HttpStatus(message) => AiError::HttpStatus(redact(&message, key)),
        AiError::Protocol(message) => AiError::Protocol(redact(&message, key)),
        AiError::Timeout(message) => AiError::Timeout(redact(&message, key)),
        AiError::Other(message) => AiError::Other(redact(&message, key)),
        other => other,
    }
}

// ── Events and usage ────────────────────────────────────────────────────────────────────────

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct TokenUsage {
    pub prompt_tokens: Option<u64>,
    pub completion_tokens: Option<u64>,
    pub total_tokens: Option<u64>,
    /// Reasoning tokens are a subset of completion tokens on providers that expose them.,
    pub reasoning_tokens: Option<u64>,
}

impl TokenUsage {
    pub fn merge(self, other: Self) -> Self {
        Self {
            prompt_tokens: add_optional(self.prompt_tokens, other.prompt_tokens),
            completion_tokens: add_optional(self.completion_tokens, other.completion_tokens),
            total_tokens: add_optional(self.total_tokens, other.total_tokens),
            reasoning_tokens: add_optional(self.reasoning_tokens, other.reasoning_tokens),
        }
    }

    pub fn is_empty(self) -> bool {
        self == Self::default()
    }
}

fn add_optional(left: Option<u64>, right: Option<u64>) -> Option<u64> {
    match (left, right) {
        (None, None) => None,
        (Some(value), None) | (None, Some(value)) => Some(value),
        (Some(left), Some(right)) => Some(left.saturating_add(right)),
    }
}

/// Instrumentation for one request. The shell shows these counts when no answer text arrived,
/// instead of guessing from the usage line. Counts and byte totals only; no content.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct StreamDiagnostics {
    pub http_status: u16,
    pub bytes: u64,
    pub frames: u32,
    pub data_frames: u32,
    pub content_frames: u32,
    pub reasoning_frames: u32,
    pub role_only_frames: u32,
    pub empty_frames: u32,
    pub usage_frames: u32,
    /// "string", "array", "complete JSON", or "none".
    pub content_shape: String,
    pub finish_reason: Option<String>,
    pub usage: TokenUsage,
}

impl StreamDiagnostics {
    fn merge_usage(&mut self, usage: TokenUsage) {
        self.usage = self.usage.merge(usage);
    }

    fn note_shape(&mut self, shape: &str) {
        if self.content_shape == "none" {
            self.content_shape = shape.to_string();
        }
    }
}

/// One event from a plan run. The FFI surface mirrors these variants.
#[derive(Clone, Debug, PartialEq)]
pub enum RunEvent {
    PartStarted {
        index: u32,
        total: u32,
        label: String,
    },
    Delta(String),
    /// The provider's reasoning/thinking channel. Never appended to the answer.
    ReasoningDelta(String),
    Usage(TokenUsage),
    /// End-of-request instrumentation for the panel and the optional trace.
    Diagnostics(StreamDiagnostics),
    Done,
}

// ── Transports ──────────────────────────────────────────────────────────────────────────────

/// A response whose body arrives incrementally. Status and headers are available first, so a
/// non-2xx answer can be read as an error body rather than parsed as SSE.
pub trait ResponseStream: Send {
    fn status(&self) -> u16;
    fn reason(&self) -> &str;
    fn headers(&self) -> &[(String, String)];
    /// The next decoded body bytes, or `None` at the end of the response.
    fn next_chunk(&mut self) -> Result<Option<Vec<u8>>, AiError>;
}

pub trait Transport: Send + Sync {
    fn execute(
        &self,
        spec: &RequestSpec,
        cancel: &CancellationToken,
    ) -> Result<Box<dyn ResponseStream>, AiError>;
}

/// The one production transport. Both `http://` and `https://` go through the same ureq agent;
/// only the `TlsConfig` is different (system roots in the app, injected roots in the TLS test).
pub struct UreqTransport {
    config: ClientConfig,
    roots: RootCerts,
}

impl UreqTransport {
    /// The production configuration: roots loaded from the operating system's trust store.
    pub fn system(config: ClientConfig) -> Self {
        Self {
            config,
            roots: system_roots(),
        }
    }

    /// A transport with explicit roots. Used by the loopback TLS test to trust its own CA.
    pub fn with_certificates(
        config: ClientConfig,
        certificates: Vec<Certificate<'static>>,
    ) -> Self {
        Self {
            config,
            roots: RootCerts::from(certificates),
        }
    }

    /// A transport with a pre-built root set. Exposed for tests and for a future platform shell
    /// that wants to supply its own trust policy.
    pub fn with_roots(config: ClientConfig, roots: RootCerts) -> Self {
        Self { config, roots }
    }

    fn make_agent(&self, cancel: &CancellationToken) -> ureq::Agent {
        let tls = TlsConfig::builder().root_certs(self.roots.clone()).build();
        let agent_config = ureq::Agent::config_builder()
            // The total budget covers connect + TLS + headers + the whole stream. Idle time is
            // enforced by CancellableTransport, which resets on every received chunk.
            .timeout_global(Some(self.config.max_time))
            .timeout_resolve(Some(self.config.connect_timeout))
            .timeout_connect(Some(self.config.connect_timeout))
            .timeout_send_request(Some(self.config.connect_timeout))
            .timeout_send_body(Some(self.config.max_time))
            .timeout_recv_response(None)
            .timeout_recv_body(None)
            .max_redirects(0)
            .http_status_as_error(false)
            .tls_config(tls)
            .build();
        ureq::Agent::with_parts(
            agent_config,
            CancellableConnector {
                cancel: cancel.clone(),
                idle_timeout: self.config.idle_timeout,
            },
            DefaultResolver::default(),
        )
    }
}

impl Transport for UreqTransport {
    fn execute(
        &self,
        spec: &RequestSpec,
        cancel: &CancellationToken,
    ) -> Result<Box<dyn ResponseStream>, AiError> {
        cancel.check()?;
        let agent = self.make_agent(cancel);
        let mut request = agent.post(&spec.url);
        for (name, value) in &spec.headers {
            request = request.header(name.as_str(), value.as_str());
        }
        // `http_status_as_error(false)` above is what makes a 401 body readable instead of an
        // opaque status error.
        let response = request
            .send(&spec.body)
            .map_err(|error| map_ureq_error(error, cancel, spec.is_local))?;
        let status = response.status().as_u16();
        let reason = response
            .status()
            .canonical_reason()
            .unwrap_or("")
            .to_string();
        let headers = response
            .headers()
            .iter()
            .filter_map(|(name, value)| {
                value
                    .to_str()
                    .ok()
                    .map(|value| (name.as_str().to_ascii_lowercase(), value.to_string()))
            })
            .collect();
        let reader: Box<dyn Read + Send> = Box::new(response.into_body().into_reader());
        Ok(Box::new(UreqResponseStream {
            reader,
            status,
            reason,
            headers,
            cancel: cancel.clone(),
            done: false,
        }))
    }
}

/// Trust roots: the OS store first, the bundled webpki roots as a documented fallback. The
/// result is cached because loading the platform store parses every root certificate.
fn system_roots() -> RootCerts {
    static ROOTS: OnceLock<RootCerts> = OnceLock::new();
    ROOTS
        .get_or_init(|| {
            let loaded = rustls_native_certs::load_native_certs();
            let certificates: Vec<Certificate<'static>> = loaded
                .certs
                .iter()
                .map(|der| Certificate::from_der(der.as_ref()).to_owned())
                .collect();
            if certificates.is_empty() {
                RootCerts::WebPki
            } else {
                RootCerts::from(certificates)
            }
        })
        .clone()
}

struct UreqResponseStream {
    reader: Box<dyn Read + Send>,
    status: u16,
    reason: String,
    headers: Vec<(String, String)>,
    cancel: CancellationToken,
    done: bool,
}

impl ResponseStream for UreqResponseStream {
    fn status(&self) -> u16 {
        self.status
    }

    fn reason(&self) -> &str {
        &self.reason
    }

    fn headers(&self) -> &[(String, String)] {
        &self.headers
    }

    fn next_chunk(&mut self) -> Result<Option<Vec<u8>>, AiError> {
        if self.done {
            return Ok(None);
        }
        let mut buffer = [0u8; 8192];
        loop {
            if self.cancel.is_cancelled() {
                return Err(AiError::Cancelled);
            }
            match self.reader.read(&mut buffer) {
                Ok(0) => {
                    self.done = true;
                    return Ok(None);
                }
                Ok(read) => return Ok(Some(buffer[..read].to_vec())),
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::UnexpectedEof
                            | std::io::ErrorKind::ConnectionAborted
                            | std::io::ErrorKind::ConnectionReset
                    ) =>
                {
                    // The HTTP framing may have ended early. Treat it as EOF: run_plan then
                    // reports the missing [DONE] rather than a misleading socket error.
                    self.done = true;
                    return Ok(None);
                }
                Err(error) => {
                    if self.cancel.is_cancelled() {
                        return Err(AiError::Cancelled);
                    }
                    let message = error.to_string();
                    if error.kind() == std::io::ErrorKind::TimedOut
                        || error.kind() == std::io::ErrorKind::WouldBlock
                        || message.to_ascii_lowercase().contains("timeout")
                    {
                        return Err(AiError::Timeout(
                            "the provider stopped sending data; the idle timeout expired"
                                .to_string(),
                        ));
                    }
                    return Err(AiError::Unreachable(format!(
                        "the connection failed while reading: {message}"
                    )));
                }
            }
        }
    }
}

/// The platform errors that mean "this Mac could not put the request on the network".
///
/// `ErrorKind` is used rather than any message text, so the mapping survives a locale change and
/// a wording change in the HTTP stack. Rust maps the Unix/macOS codes (`ENETUNREACH`,
/// `EHOSTUNREACH`, `ENETDOWN`) and the Windows equivalents to these kinds.
fn is_network_unreachable(kind: std::io::ErrorKind) -> bool {
    matches!(
        kind,
        std::io::ErrorKind::NetworkUnreachable
            | std::io::ErrorKind::HostUnreachable
            | std::io::ErrorKind::NetworkDown
    )
}

/// Classify a connection-stage OS error. A loopback endpoint that refuses the connection means
/// the local server is not running; the same error for a remote endpoint is not evidence that the
/// Mac is offline, so it stays generic.
fn classify_io_failure(error: &std::io::Error, is_local: bool) -> AiFailure {
    let kind = error.kind();
    if is_local {
        return if is_network_unreachable(kind) || kind == std::io::ErrorKind::ConnectionRefused {
            AiFailure::LocalServer
        } else {
            AiFailure::Other
        };
    }
    if is_network_unreachable(kind) {
        AiFailure::Offline
    } else {
        AiFailure::Other
    }
}

fn map_ureq_error(error: ureq::Error, cancel: &CancellationToken, is_local: bool) -> AiError {
    if cancel.is_cancelled() {
        return AiError::Cancelled;
    }
    match error {
        ureq::Error::Timeout(_) => AiError::Timeout(
            "the provider did not answer within the configured timeout".to_string(),
        ),
        ureq::Error::Tls(message) => {
            AiError::Unreachable(format!("TLS handshake failed: {message}"))
        }
        ureq::Error::Io(error) => match classify_io_failure(&error, is_local) {
            AiFailure::Offline => AiError::Offline(format!("no network route: {error}")),
            AiFailure::LocalServer => AiError::LocalServer(format!(
                "the local server did not accept the connection: {error}"
            )),
            AiFailure::Other => AiError::Unreachable(format!("the connection failed: {error}")),
        },
        ureq::Error::HostNotFound => {
            if is_local {
                // A loopback host should not need the resolver; keep the generic transport error
                // rather than claiming anything about the network or the local server.
                AiError::Unreachable("could not resolve the endpoint host".to_string())
            } else {
                AiError::Offline("could not resolve the provider host".to_string())
            }
        }
        ureq::Error::BadUri(message) => {
            AiError::InvalidSettings(format!("The endpoint URL is not valid: {message}"))
        }
        other => AiError::Unreachable(format!("the HTTP request failed: {other}")),
    }
}

fn cancelled_ureq_error() -> ureq::Error {
    ureq::Error::Io(std::io::Error::new(
        std::io::ErrorKind::Interrupted,
        "request cancelled",
    ))
}

/// Ensures the connection is handed to a transport that notices cancellation between short
/// socket reads. Ureq itself is blocking; the adapter bounds each inner read to
/// [`POLL_INTERVAL`] (or the remaining idle budget), checks the cancel flag, and then retries.
/// That is what keeps a stalled provider from making Cancel wait forever.
#[derive(Debug)]
struct CancellableConnector {
    cancel: CancellationToken,
    idle_timeout: Duration,
}

impl Connector<()> for CancellableConnector {
    type Out = Box<dyn UreqTransportTrait>;

    fn connect(
        &self,
        details: &ConnectionDetails,
        chained: Option<()>,
    ) -> Result<Option<Self::Out>, ureq::Error> {
        let Some(inner) = DefaultConnector::new().connect(details, chained)? else {
            return Ok(None);
        };
        Ok(Some(Box::new(CancellableTransport {
            inner,
            cancel: self.cancel.clone(),
            idle_timeout: self.idle_timeout,
            last_activity: Instant::now(),
        })))
    }
}

struct CancellableTransport {
    inner: Box<dyn UreqTransportTrait>,
    cancel: CancellationToken,
    idle_timeout: Duration,
    last_activity: Instant,
}

impl fmt::Debug for CancellableTransport {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CancellableTransport")
            .field("idle_timeout", &self.idle_timeout)
            .finish_non_exhaustive()
    }
}

impl UreqTransportTrait for CancellableTransport {
    fn buffers(&mut self) -> &mut dyn Buffers {
        self.inner.buffers()
    }

    fn transmit_output(&mut self, amount: usize, timeout: NextTimeout) -> Result<(), ureq::Error> {
        if self.cancel.is_cancelled() {
            return Err(cancelled_ureq_error());
        }
        self.inner.transmit_output(amount, timeout)
    }

    fn await_input(&mut self, timeout: NextTimeout) -> Result<bool, ureq::Error> {
        let requested = timeout.not_zero().map(|remaining| *remaining);
        let started = Instant::now();
        loop {
            if self.cancel.is_cancelled() {
                return Err(cancelled_ureq_error());
            }
            let now = Instant::now();
            let idle_elapsed = now.duration_since(self.last_activity);
            if idle_elapsed >= self.idle_timeout {
                return Err(ureq::Error::Timeout(ureq::Timeout::RecvBody));
            }
            let mut wait = self.idle_timeout.saturating_sub(idle_elapsed);
            if let Some(requested) = requested {
                let remaining = requested.saturating_sub(now.duration_since(started));
                if remaining.is_zero() {
                    return Err(ureq::Error::Timeout(timeout.reason));
                }
                wait = wait.min(remaining);
            }
            let poll = wait.min(POLL_INTERVAL).max(Duration::from_millis(1));
            match self.inner.await_input(NextTimeout {
                after: UreqDuration::Exact(poll),
                reason: timeout.reason,
            }) {
                Ok(progress) => {
                    if progress {
                        self.last_activity = Instant::now();
                    }
                    return Ok(progress);
                }
                // The short poll expired; this is not the request's timeout. Re-check the
                // cancel flag and the real idle/global deadline.
                Err(ureq::Error::Timeout(_)) => continue,
                Err(error) => return Err(error),
            }
        }
    }

    fn is_open(&mut self) -> bool {
        self.inner.is_open()
    }

    fn is_tls(&self) -> bool {
        self.inner.is_tls()
    }
}

/// Pick the transport for an endpoint. This is intentionally the same implementation for both
/// schemes: only the TLS configuration (and therefore whether a handshake happens) differs.
pub fn default_transport(url: &str, config: ClientConfig) -> Result<Box<dyn Transport>, AiError> {
    let lower = url.to_ascii_lowercase();
    if lower.starts_with("http://") || lower.starts_with("https://") {
        Ok(Box::new(UreqTransport::system(config)))
    } else {
        Err(AiError::InvalidSettings(
            "The endpoint must use http:// or https://.".to_string(),
        ))
    }
}

// ── SSE decoding ────────────────────────────────────────────────────────────────────────────

/// One parsed server-sent event.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SseFrame {
    Data(String),
    Done,
}

/// Incremental SSE parser: chunk boundaries are irrelevant to it, including boundaries inside a
/// JSON object, inside a `data:` line, or inside `[DONE]`.
pub struct SseDecoder {
    buffer: Vec<u8>,
    done: bool,
}

impl Default for SseDecoder {
    fn default() -> Self {
        Self::new()
    }
}

impl SseDecoder {
    pub fn new() -> Self {
        Self {
            buffer: Vec::new(),
            done: false,
        }
    }

    pub fn is_done(&self) -> bool {
        self.done
    }

    pub fn push(&mut self, bytes: &[u8]) -> Result<Vec<SseFrame>, AiError> {
        if self.done {
            return Ok(Vec::new());
        }
        self.buffer.extend_from_slice(bytes);
        if self.buffer.len() > 1024 * 1024 {
            return Err(AiError::Protocol(
                "The server sent an SSE event larger than 1 MiB.".to_string(),
            ));
        }
        let mut frames = Vec::new();
        while let Some((end, delimiter)) = find_event_boundary(&self.buffer) {
            let event = self.buffer[..end].to_vec();
            self.buffer.drain(..end + delimiter);
            let mut data_lines = Vec::new();
            let text = String::from_utf8_lossy(&event);
            for line in text.lines() {
                let line = line.trim_end_matches('\r');
                if line.is_empty() || line.starts_with(':') {
                    continue;
                }
                let Some((field, value)) = line.split_once(':') else {
                    continue;
                };
                if field == "data" {
                    data_lines.push(value.strip_prefix(' ').unwrap_or(value).to_string());
                }
            }
            if data_lines.is_empty() {
                continue;
            }
            let data = data_lines.join("\n");
            if data.trim() == "[DONE]" {
                self.done = true;
                frames.push(SseFrame::Done);
                break;
            }
            frames.push(SseFrame::Data(data));
        }
        Ok(frames)
    }
}

fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

fn find_event_boundary(buffer: &[u8]) -> Option<(usize, usize)> {
    let lf = find_bytes(buffer, b"\n\n").map(|index| (index, 2));
    let crlf = find_bytes(buffer, b"\r\n\r\n").map(|index| (index, 4));
    match (lf, crlf) {
        (Some(a), Some(b)) => Some(if a.0 <= b.0 { a } else { b }),
        (Some(a), None) => Some(a),
        (None, Some(b)) => Some(b),
        (None, None) => None,
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StreamPayload {
    Delta(String),
    /// The provider's reasoning/thinking channel. Kept separate from the answer.
    ReasoningDelta(String),
    Usage(TokenUsage),
}

/// Decode one `data:` payload. Unknown fields and empty keep-alives are ignored; an `error`
/// object or malformed JSON becomes a readable error.
#[derive(Clone, Debug, Default, PartialEq)]
struct PayloadMeta {
    content: bool,
    reasoning: bool,
    role_only: bool,
    empty: bool,
    usage: bool,
    usage_value: TokenUsage,
    content_shape: Option<String>,
    finish_reason: Option<String>,
}

pub fn parse_stream_payload(data: &str) -> Result<Vec<StreamPayload>, AiError> {
    parse_stream_frame(data).map(|(payloads, _)| payloads)
}

fn parse_stream_frame(data: &str) -> Result<(Vec<StreamPayload>, PayloadMeta), AiError> {
    let value: Value = serde_json::from_str(data).map_err(|error| {
        AiError::Protocol(format!(
            "The provider sent a data event that is not JSON ({}): {}",
            error,
            truncate(data, 160)
        ))
    })?;
    let mut meta = PayloadMeta::default();
    let mut payloads = Vec::new();
    if let Some(error) = value.get("error") {
        let message = error_message(error).unwrap_or("The provider reported an error mid-stream.");
        return Err(AiError::Other(format!(
            "The provider reported an error: {message}"
        )));
    }
    if let Some(choices) = value.get("choices").and_then(Value::as_array)
        && let Some(choice) = choices.first()
    {
        if let Some(reason) = choice.get("finish_reason").and_then(Value::as_str)
            && !reason.is_empty()
        {
            meta.finish_reason = Some(reason.to_string());
        }
        if let Some(delta) = choice.get("delta") {
            if let Some(content) = delta.get("content") {
                meta.content = !content_text(content).is_empty();
                meta.content_shape = Some(if content.is_array() {
                    "array".to_string()
                } else if content.is_string() {
                    "string".to_string()
                } else {
                    "other".to_string()
                });
            }
            meta.reasoning = delta
                .get("reasoning_content")
                .or_else(|| delta.get("reasoning"))
                .is_some_and(|reasoning| !content_text(reasoning).is_empty());
            meta.role_only = !meta.content
                && !meta.reasoning
                && delta.get("role").and_then(Value::as_str).is_some();
            meta.empty = !meta.content && !meta.reasoning && !meta.role_only;
            append_text_payloads(delta, &mut payloads);
        }
    }
    append_usage(&value, &mut payloads);
    for payload in &payloads {
        if let StreamPayload::Usage(usage) = payload {
            meta.usage = true;
            meta.usage_value = usage.merge(meta.usage_value);
        }
    }
    Ok((payloads, meta))
}

/// Parse a complete non-SSE JSON response.
///
/// Some gateways ignore `stream: true` and return one `choices[0].message.content` object.
/// Parsing that shape (and a 200 response whose body is an `error` object) is preferable to
/// reporting an empty answer or a misleading "missing [DONE]".
pub fn parse_complete_body(body: &str) -> Result<Vec<StreamPayload>, AiError> {
    parse_complete_body_with_meta(body).map(|(payloads, _)| payloads)
}

fn parse_complete_body_with_meta(body: &str) -> Result<(Vec<StreamPayload>, PayloadMeta), AiError> {
    let value: Value = serde_json::from_str(body).map_err(|error| {
        AiError::Protocol(format!(
            "The provider returned a non-SSE response that is not JSON ({}): {}",
            error,
            truncate(body, 160)
        ))
    })?;
    if let Some(error) = value.get("error") {
        let message = error_message(error).unwrap_or("The provider returned an error.");
        return Err(AiError::Other(format!(
            "The provider returned an error: {message}"
        )));
    }
    let mut payloads = Vec::new();
    let mut meta = PayloadMeta::default();
    if let Some(choices) = value.get("choices").and_then(Value::as_array)
        && let Some(choice) = choices.first()
    {
        if let Some(reason) = choice.get("finish_reason").and_then(Value::as_str)
            && !reason.is_empty()
        {
            meta.finish_reason = Some(reason.to_string());
        }
        if let Some(message) = choice.get("message") {
            append_text_payloads(message, &mut payloads);
        }
        // Legacy completions API / a few gateways use `choices[0].text`.
        if let Some(text) = choice.get("text").and_then(Value::as_str)
            && !text.is_empty()
        {
            payloads.push(StreamPayload::Delta(text.to_string()));
        }
    }
    append_usage(&value, &mut payloads);
    if payloads.is_empty() {
        return Err(AiError::Protocol(
            "The provider returned a JSON body with neither a message nor usage.".to_string(),
        ));
    }
    meta.content = payloads
        .iter()
        .any(|payload| matches!(payload, StreamPayload::Delta(_)));
    meta.reasoning = payloads
        .iter()
        .any(|payload| matches!(payload, StreamPayload::ReasoningDelta(_)));
    for payload in &payloads {
        if let StreamPayload::Usage(usage) = payload {
            meta.usage = true;
            meta.usage_value = usage.merge(meta.usage_value);
        }
    }
    meta.content_shape = if meta.content || meta.reasoning {
        Some("complete JSON".to_string())
    } else {
        None
    };
    Ok((payloads, meta))
}

fn append_text_payloads(container: &Value, payloads: &mut Vec<StreamPayload>) {
    // DeepSeek's thinking-mode streams use `reasoning_content`; some gateways use `reasoning`.
    // Both are the thinking channel, never the answer.
    if let Some(reasoning) = container
        .get("reasoning_content")
        .or_else(|| container.get("reasoning"))
    {
        let text = content_text(reasoning);
        if !text.is_empty() {
            payloads.push(StreamPayload::ReasoningDelta(text));
        }
    }
    if let Some(content) = container.get("content") {
        let text = content_text(content);
        if !text.is_empty() {
            payloads.push(StreamPayload::Delta(text));
        }
    }
}

fn append_usage(value: &Value, payloads: &mut Vec<StreamPayload>) {
    if let Some(usage) = value.get("usage").and_then(Value::as_object) {
        let reasoning_tokens = usage
            .get("completion_tokens_details")
            .and_then(Value::as_object)
            .and_then(|details| details.get("reasoning_tokens"))
            .and_then(Value::as_u64)
            .or_else(|| usage.get("reasoning_tokens").and_then(Value::as_u64));
        let parsed = TokenUsage {
            prompt_tokens: usage.get("prompt_tokens").and_then(Value::as_u64),
            completion_tokens: usage.get("completion_tokens").and_then(Value::as_u64),
            total_tokens: usage.get("total_tokens").and_then(Value::as_u64),
            reasoning_tokens,
        };
        if parsed != TokenUsage::default() {
            payloads.push(StreamPayload::Usage(parsed));
        }
    }
}

fn error_message(error: &Value) -> Option<&str> {
    error
        .get("message")
        .and_then(Value::as_str)
        .or_else(|| error.as_str())
}

fn content_text(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Array(parts) => {
            let mut text = String::new();
            for part in parts {
                match part {
                    Value::String(segment) => text.push_str(segment),
                    _ => {
                        if let Some(segment) = part.get("text").and_then(Value::as_str) {
                            text.push_str(segment);
                        }
                    }
                }
            }
            text
        }
        _ => String::new(),
    }
}

/// Largest non-SSE JSON body accepted as a complete answer. A normal answer is far smaller;
/// this is a sanity ceiling, not a context budget.
const MAX_COMPLETE_BODY: usize = 4 * 1024 * 1024;

/// Whether the raw-stream trace is enabled. Read once, like the app's other development hooks.
fn trace_enabled() -> bool {
    static ENABLED: OnceLock<bool> = OnceLock::new();
    *ENABLED.get_or_init(|| {
        std::env::var("LYRA_READER_AI_TRACE")
            .map(|value| !value.is_empty() && value != "0")
            .unwrap_or(false)
    })
}

fn trace(message: impl AsRef<str>) {
    if trace_enabled() {
        eprintln!("lyra-reader-ai-trace: {}", message.as_ref());
    }
}

fn trace_sse_frame(frame: &SseFrame) {
    match frame {
        SseFrame::Done => trace("sse frame=done"),
        SseFrame::Data(data) => match serde_json::from_str::<Value>(data) {
            Ok(value) => trace(format!("sse frame=data {}", json_shape(&value))),
            Err(_) => trace(format!(
                "sse frame=data non-json chars={}",
                data.chars().count()
            )),
        },
    }
}

fn trace_complete_body(body: &str) {
    match serde_json::from_str::<Value>(body) {
        Ok(value) => trace(format!("non-sse body json {}", json_shape(&value))),
        Err(_) => trace(format!(
            "non-sse body non-json chars={}",
            body.chars().count()
        )),
    }
}

/// Describe a JSON payload by its keys and content lengths only. Never include values: the
/// trace exists so a reader can share what a provider streams without sharing the text.
fn json_shape(value: &Value) -> String {
    let Some(object) = value.as_object() else {
        return "type=non-object".to_string();
    };
    let keys = |map: &serde_json::Map<String, Value>| {
        map.keys().map(String::as_str).collect::<Vec<_>>().join(",")
    };
    let mut parts = vec![format!("keys=[{}]", keys(object))];
    if let Some(error) = object.get("error").and_then(Value::as_object) {
        parts.push(format!("error_keys=[{}]", keys(error)));
    }
    if let Some(usage) = object.get("usage").and_then(Value::as_object) {
        parts.push(format!("usage_keys=[{}]", keys(usage)));
    }
    if let Some(choices) = object.get("choices").and_then(Value::as_array) {
        parts.push(format!("choices={}", choices.len()));
        if let Some(choice) = choices.first().and_then(Value::as_object) {
            if let Some(reason) = choice.get("finish_reason").and_then(Value::as_str) {
                parts.push(format!("finish_reason={reason}"));
            }
            for field in ["delta", "message"] {
                if let Some(container) = choice.get(field).and_then(Value::as_object) {
                    parts.push(format!("{field}_keys=[{}]", keys(container)));
                    for key in ["content", "reasoning_content", "reasoning"] {
                        if let Some(value) = container.get(key) {
                            parts.push(format!(
                                "{key}_chars={}",
                                content_text(value).chars().count()
                            ));
                        }
                    }
                }
            }
        }
    }
    parts.join(" ")
}

fn emit_payload(payload: StreamPayload, emit: &mut dyn FnMut(RunEvent)) {
    match payload {
        StreamPayload::Delta(text) => emit(RunEvent::Delta(text)),
        StreamPayload::ReasoningDelta(text) => emit(RunEvent::ReasoningDelta(text)),
        StreamPayload::Usage(usage) => emit(RunEvent::Usage(usage)),
    }
}

fn header_value<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    headers
        .iter()
        .find(|(candidate, _)| candidate.eq_ignore_ascii_case(name))
        .map(|(_, value)| value.as_str())
}

fn read_complete_body(
    response: &mut dyn ResponseStream,
    cancel: &CancellationToken,
) -> Result<Vec<u8>, AiError> {
    let mut body = Vec::new();
    loop {
        cancel.check()?;
        match response.next_chunk() {
            Ok(Some(chunk)) => {
                if body.len() + chunk.len() > MAX_COMPLETE_BODY {
                    return Err(AiError::Protocol(format!(
                        "The provider sent a non-SSE response larger than {} MiB.",
                        MAX_COMPLETE_BODY / (1024 * 1024)
                    )));
                }
                body.extend_from_slice(&chunk);
            }
            Ok(None) => break,
            Err(error) => return Err(error),
        }
    }
    Ok(body)
}

// ── Running a plan ─────────────────────────────────────────────────────────────────────────

/// Run every part of a plan with the transport chosen by the endpoint scheme.
///
/// This blocking function is meant for a worker thread. It emits [`RunEvent`]s as they arrive and
/// stops at the first error; a cancelled run returns [`AiError::Cancelled`]. The caller owns the
/// key and should drop it when this returns.
pub fn run_plan(
    plan: &ChatPlan,
    api_key: &str,
    cancel: &CancellationToken,
    emit: &mut dyn FnMut(RunEvent),
) -> Result<(), AiError> {
    let result = (|| {
        let transport = default_transport(&plan.endpoint, ClientConfig::default())?;
        run_plan_with_transport(plan, api_key, transport.as_ref(), cancel, emit)
    })();
    result.map_err(|error| redact_error(error, api_key))
}

/// The transport-injected form, used by the local mock-server tests.
pub fn run_plan_with_transport(
    plan: &ChatPlan,
    api_key: &str,
    transport: &dyn Transport,
    cancel: &CancellationToken,
    emit: &mut dyn FnMut(RunEvent),
) -> Result<(), AiError> {
    let result = run_plan_inner(plan, api_key, transport, cancel, emit);
    result.map_err(|error| redact_error(error, api_key))
}

fn run_plan_inner(
    plan: &ChatPlan,
    api_key: &str,
    transport: &dyn Transport,
    cancel: &CancellationToken,
    emit: &mut dyn FnMut(RunEvent),
) -> Result<(), AiError> {
    if plan.parts.is_empty() {
        return Err(AiError::Protocol(
            "The plan contains no request parts; nothing was sent.".to_string(),
        ));
    }
    for part in &plan.parts {
        cancel.check()?;
        emit(RunEvent::PartStarted {
            index: part.index,
            total: part.total,
            label: part.label.clone(),
        });
        let spec = build_request_spec(plan, part, api_key)?;
        let mut response = transport.execute(&spec, cancel)?;
        let status = response.status();
        let mut diagnostics = StreamDiagnostics {
            http_status: status,
            content_shape: "none".to_string(),
            ..Default::default()
        };
        if !(200..300).contains(&status) {
            let body = read_error_body(&mut *response, cancel)?;
            return Err(http_error(status, response.reason(), &body));
        }

        let content_type = header_value(response.headers(), "content-type")
            .unwrap_or("")
            .to_ascii_lowercase();
        trace(format!(
            "response status={status} content_type={}",
            if content_type.is_empty() {
                "(none)"
            } else {
                content_type.as_str()
            }
        ));

        // A gateway may ignore `stream: true` and return one ordinary JSON response. Parse that
        // as a complete answer (or a 200-with-error body) instead of demanding [DONE].
        if !content_type.contains("text/event-stream") {
            let body = read_complete_body(&mut *response, cancel)?;
            let text = String::from_utf8_lossy(&body);
            trace_complete_body(&text);
            let (payloads, meta) = parse_complete_body_with_meta(&text)?;
            diagnostics.bytes = body.len() as u64;
            diagnostics.frames = 1;
            diagnostics.data_frames = 1;
            absorb_meta(&mut diagnostics, &meta);
            for payload in payloads {
                emit_payload(payload, emit);
            }
            trace_diagnostics(&diagnostics);
            emit(RunEvent::Diagnostics(diagnostics));
            continue;
        }

        let mut decoder = SseDecoder::new();
        let mut frames_seen = false;
        // If the server claims SSE but actually sends one JSON object, keep the raw bytes until
        // the first real SSE frame so EOF can be retried as a complete body.
        let mut fallback = Vec::new();
        loop {
            cancel.check()?;
            let chunk = match response.next_chunk() {
                Ok(Some(chunk)) => chunk,
                Ok(None) => break,
                Err(error) => return Err(error),
            };
            diagnostics.bytes = diagnostics.bytes.saturating_add(chunk.len() as u64);
            if !frames_seen {
                if fallback.len() + chunk.len() > MAX_COMPLETE_BODY {
                    return Err(AiError::Protocol(format!(
                        "The provider sent an SSE response with no frames and more than {} MiB of data.",
                        MAX_COMPLETE_BODY / (1024 * 1024)
                    )));
                }
                fallback.extend_from_slice(&chunk);
            }
            let frames = decoder.push(&chunk)?;
            if !frames.is_empty() {
                frames_seen = true;
                fallback.clear();
            }
            for frame in frames {
                diagnostics.frames += 1;
                trace_sse_frame(&frame);
                match frame {
                    SseFrame::Done => {}
                    SseFrame::Data(data) => {
                        diagnostics.data_frames += 1;
                        let (payloads, meta) = parse_stream_frame(&data)?;
                        absorb_meta(&mut diagnostics, &meta);
                        for payload in payloads {
                            emit_payload(payload, emit);
                        }
                    }
                }
            }
            if decoder.is_done() {
                break;
            }
            if cancel.is_cancelled() {
                return Err(AiError::Cancelled);
            }
        }
        if !decoder.is_done() {
            if !frames_seen && !fallback.is_empty() {
                let text = String::from_utf8_lossy(&fallback);
                trace_complete_body(&text);
                let (payloads, meta) = parse_complete_body_with_meta(&text)?;
                diagnostics.frames = 1;
                diagnostics.data_frames = 1;
                absorb_meta(&mut diagnostics, &meta);
                for payload in payloads {
                    emit_payload(payload, emit);
                }
            } else {
                return Err(AiError::Protocol(
                    "The server closed the connection before [DONE]; the answer is incomplete."
                        .to_string(),
                ));
            }
        }
        trace_diagnostics(&diagnostics);
        emit(RunEvent::Diagnostics(diagnostics));
    }
    emit(RunEvent::Done);
    Ok(())
}

fn absorb_meta(diagnostics: &mut StreamDiagnostics, meta: &PayloadMeta) {
    if meta.content {
        diagnostics.content_frames += 1;
    }
    if meta.reasoning {
        diagnostics.reasoning_frames += 1;
    }
    if meta.role_only {
        diagnostics.role_only_frames += 1;
    }
    if meta.empty {
        diagnostics.empty_frames += 1;
    }
    if meta.usage {
        diagnostics.usage_frames += 1;
    }
    if let Some(shape) = &meta.content_shape {
        diagnostics.note_shape(shape);
    }
    if let Some(reason) = &meta.finish_reason {
        diagnostics.finish_reason = Some(reason.clone());
    }
    diagnostics.merge_usage(meta.usage_value);
}

fn trace_diagnostics(diagnostics: &StreamDiagnostics) {
    trace(format!(
        "request summary http={} bytes={} frames={} data={} content={} reasoning={} role_only={} empty={} usage_frames={} content_shape={} finish_reason={} usage={:?}",
        diagnostics.http_status,
        diagnostics.bytes,
        diagnostics.frames,
        diagnostics.data_frames,
        diagnostics.content_frames,
        diagnostics.reasoning_frames,
        diagnostics.role_only_frames,
        diagnostics.empty_frames,
        diagnostics.usage_frames,
        diagnostics.content_shape,
        diagnostics.finish_reason.as_deref().unwrap_or("none"),
        diagnostics.usage
    ));
}

fn read_error_body(
    response: &mut dyn ResponseStream,
    cancel: &CancellationToken,
) -> Result<String, AiError> {
    let mut body = Vec::new();
    loop {
        cancel.check()?;
        if body.len() >= MAX_ERROR_BODY {
            break;
        }
        match response.next_chunk() {
            Ok(Some(chunk)) => {
                let remaining = MAX_ERROR_BODY - body.len();
                body.extend_from_slice(&chunk[..chunk.len().min(remaining)]);
            }
            Ok(None) => break,
            Err(AiError::Cancelled) => return Err(AiError::Cancelled),
            Err(_) => break,
        }
    }
    Ok(String::from_utf8_lossy(&body).to_string())
}

fn http_error(status: u16, reason: &str, body: &str) -> AiError {
    let detail = error_detail(body);
    let with_detail = |prefix: String| {
        if detail.is_empty() {
            prefix
        } else {
            format!("{prefix} {detail}")
        }
    };
    let reason = truncate(reason.trim(), 80);
    let status_label = if reason.is_empty() {
        format!("HTTP {status}")
    } else {
        format!("HTTP {status} {reason}")
    };
    AiError::HttpStatus(match status {
        401 | 403 => with_detail(format!(
            "Authentication failed ({status_label}). Check the API key in Settings > AI. Nothing further was sent."
        )),
        429 => with_detail(format!(
            "The provider is rate limiting this key ({status_label}). Wait a moment and try again."
        )),
        400 | 404 | 422 => {
            let mut message = with_detail(format!(
                "The provider rejected the request ({status_label})."
            ));
            if let Some(hint) = reasoning_parameter_hint(&detail) {
                message.push(' ');
                message.push_str(hint);
            }
            message
        }
        500..=599 => with_detail(format!("The provider failed ({status_label}).")),
        _ => with_detail(format!("The provider answered with {status_label}.")),
    })
}

fn reasoning_parameter_hint(detail: &str) -> Option<&'static str> {
    let lower = detail.to_ascii_lowercase();
    let names_parameter = lower.contains("unknown")
        || lower.contains("unrecognized")
        || lower.contains("unsupported")
        || lower.contains("not supported");
    let is_reasoning = lower.contains("reasoning")
        || lower.contains("thinking")
        || lower.contains("output_config")
        || lower.contains("reasoning_effort");
    (names_parameter
        && is_reasoning
        && (lower.contains("parameter") || lower.contains("argument") || lower.contains("field")))
    .then_some(
        "The reasoning encoding selected in Settings > AI was not accepted; change it or set reasoning to provider default.",
    )
}

fn error_detail(body: &str) -> String {
    let trimmed = body.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    if let Ok(value) = serde_json::from_str::<Value>(trimmed) {
        let message = value
            .get("error")
            .and_then(|error| {
                error
                    .get("message")
                    .and_then(Value::as_str)
                    .or_else(|| error.as_str())
            })
            .or_else(|| value.get("message").and_then(Value::as_str))
            .or_else(|| value.get("detail").and_then(Value::as_str));
        if let Some(message) = message {
            return truncate(&collapse_whitespace(message), MAX_DETAIL_CHARS);
        }
    }
    truncate(&collapse_whitespace(trimmed), MAX_DETAIL_CHARS)
}

fn collapse_whitespace(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn truncate(text: &str, limit: usize) -> String {
    if text.chars().count() <= limit {
        return text.to_string();
    }
    let mut truncated: String = text.chars().take(limit).collect();
    truncated.push_str("...");
    truncated
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::chat::{
        Action, ChatSettings, PageText, PlanRequest, ReasoningEncoding, ReasoningMode, build_plan,
    };

    fn test_plan() -> ChatPlan {
        build_plan(PlanRequest {
            action: Action::SummarizePage,
            document_title: "Test".to_string(),
            page_count: 1,
            current_page: 0,
            selection: None,
            question: None,
            language: None,
            pages: vec![PageText {
                page: 0,
                text: "The method has three steps. It builds an index, ranks blocks and streams an answer.".to_string(),

                chars: Vec::new(),}],
            settings: ChatSettings {
                base_url: "http://127.0.0.1:9/v1".to_string(),
                model: "test-model".to_string(),
                temperature: Some(0.2),
                max_tokens: Some(100),

                reasoning_mode: ReasoningMode::Off,
                reasoning_encoding: ReasoningEncoding::Thinking,},
        })
        .unwrap()
    }

    #[test]
    fn request_debug_redacts_authorization() {
        let plan = test_plan();
        let spec = build_request_spec(&plan, &plan.parts[0], "sk-secret-12345").unwrap();
        let debug = format!("{spec:?}");
        assert!(!debug.contains("sk-secret-12345"));
        assert!(debug.contains("<redacted>"));
        assert!(!debug.contains("The method has three steps"));
    }

    #[test]
    fn key_with_a_line_break_is_refused() {
        let plan = test_plan();
        let error = build_request_spec(&plan, &plan.parts[0], "sk-a\r\nX: y").unwrap_err();
        assert!(error.to_string().contains("control character"));
        assert!(!error.to_string().contains("sk-a"));
    }

    #[test]
    fn redaction_removes_a_key_from_http_errors() {
        let error = AiError::HttpStatus(format!("HTTP 401: bad key {}", "sk-secret-12345"));
        let redacted = redact_error(error, "sk-secret-12345");
        assert!(!redacted.to_string().contains("sk-secret-12345"));
        assert!(redacted.to_string().contains("<redacted>"));
    }

    #[test]
    fn redaction_also_applies_to_the_new_transport_categories() {
        for error in [
            AiError::Offline("no route for sk-secret-12345".to_string()),
            AiError::LocalServer("refused for sk-secret-12345".to_string()),
        ] {
            let failure = error.failure();
            let redacted = redact_error(error, "sk-secret-12345");
            assert_eq!(redacted.failure(), failure);
            assert!(!redacted.to_string().contains("sk-secret-12345"));
        }
    }

    #[test]
    fn sse_decoder_handles_a_json_object_split_between_chunks() {
        let mut decoder = SseDecoder::new();
        assert!(decoder.push(b"data: {\"cho").unwrap().is_empty());
        assert!(
            decoder
                .push(b"ices\":[{\"delta\":{\"content\":\"hel")
                .unwrap()
                .is_empty()
        );
        let frames = decoder.push(b"lo\"}}]}\n\n").unwrap();
        assert_eq!(
            frames,
            vec![SseFrame::Data(
                "{\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}".to_string()
            )]
        );
        let frames = decoder.push(b"data: [DO").unwrap();
        assert!(frames.is_empty());
        let frames = decoder.push(b"NE]\n\n").unwrap();
        assert_eq!(frames, vec![SseFrame::Done]);
        assert!(decoder.is_done());
    }

    #[test]
    fn sse_decoder_accepts_crlf_and_comments() {
        let mut decoder = SseDecoder::new();
        let frames = decoder
            .push(b": keepalive\r\n\r\ndata: {\"choices\":[]}\r\n\r\ndata: [DONE]\r\n\r\n")
            .unwrap();
        assert_eq!(
            frames,
            vec![
                SseFrame::Data("{\"choices\":[]}".to_string()),
                SseFrame::Done
            ]
        );
    }

    #[test]
    fn payload_parses_delta_and_usage() {
        let payloads = parse_stream_payload(
            r#"{"choices":[{"delta":{"content":"Hello"}}],"usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12}}"#,
        )
        .unwrap();
        assert_eq!(
            payloads,
            vec![
                StreamPayload::Delta("Hello".to_string()),
                StreamPayload::Usage(TokenUsage {
                    prompt_tokens: Some(10),
                    completion_tokens: Some(2),
                    total_tokens: Some(12),

                    reasoning_tokens: None,
                })
            ]
        );
    }

    #[test]
    fn payload_keeps_reasoning_and_answer_separate() {
        let payloads = parse_stream_payload(
            r#"{"choices":[{"delta":{"reasoning_content":"think first","content":"answer"}}]}"#,
        )
        .unwrap();
        assert_eq!(
            payloads,
            vec![
                StreamPayload::ReasoningDelta("think first".to_string()),
                StreamPayload::Delta("answer".to_string())
            ]
        );
    }

    #[test]
    fn payload_parses_content_parts_and_reasoning_only() {
        let mut decoder = SseDecoder::new();
        let frames = decoder
            .push(include_bytes!("../tests/fixtures/content_parts.sse"))
            .unwrap();
        let mut payloads = Vec::new();
        for frame in frames {
            if let SseFrame::Data(data) = frame {
                payloads.extend(parse_stream_payload(&data).unwrap());
            }
        }
        assert_eq!(
            payloads,
            vec![
                StreamPayload::Delta("Hello from a content array.".to_string()),
                StreamPayload::Usage(TokenUsage {
                    prompt_tokens: Some(12),
                    completion_tokens: Some(6),
                    total_tokens: Some(18),

                    reasoning_tokens: None,
                })
            ]
        );

        let reasoning = parse_stream_payload(
            r#"{"choices":[{"delta":{"reasoning_content":"still thinking"}}],"usage":{"completion_tokens":900}}"#,
        )
        .unwrap();
        assert_eq!(
            reasoning,
            vec![
                StreamPayload::ReasoningDelta("still thinking".to_string()),
                StreamPayload::Usage(TokenUsage {
                    prompt_tokens: None,
                    completion_tokens: Some(900),
                    total_tokens: None,

                    reasoning_tokens: None,
                })
            ]
        );
    }

    #[test]
    fn complete_body_parses_message_content_and_usage() {
        let payloads = parse_complete_body(
            r#"{"choices":[{"message":{"role":"assistant","content":[{"type":"text","text":"Bonjour"}]},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}"#,
        )
        .unwrap();
        assert_eq!(
            payloads,
            vec![
                StreamPayload::Delta("Bonjour".to_string()),
                StreamPayload::Usage(TokenUsage {
                    prompt_tokens: Some(3),
                    completion_tokens: Some(2),
                    total_tokens: Some(5),

                    reasoning_tokens: None,
                })
            ]
        );
    }

    #[test]
    fn complete_body_keeps_reasoning_out_of_the_answer() {
        let payloads = parse_complete_body(
            r#"{"choices":[{"message":{"content":null,"reasoning_content":"internal"}}]}"#,
        )
        .unwrap();
        assert_eq!(
            payloads,
            vec![StreamPayload::ReasoningDelta("internal".to_string())]
        );
    }

    #[test]
    fn complete_body_surfaces_a_200_error_object() {
        let error = parse_complete_body(
            r#"{"error":{"message":"Model Not Exist","type":"invalid_request_error"}}"#,
        )
        .unwrap_err();
        assert!(error.to_string().contains("Model Not Exist"), "{error}");
        assert!(!error.to_string().is_empty());
    }

    #[test]
    fn the_wire_body_asks_for_standard_streaming_usage() {
        let plan = build_plan(PlanRequest {
            action: Action::SummarizePage,
            document_title: "DeepSeek".to_string(),
            page_count: 1,
            current_page: 0,
            selection: None,
            question: None,
            language: None,
            pages: vec![PageText {
                page: 0,
                text: "A sentence long enough to be a context block for the translation test."
                    .to_string(),

                chars: Vec::new(),
            }],
            settings: ChatSettings {
                base_url: "https://api.deepseek.com".to_string(),
                model: "deepseek-flash".to_string(),
                temperature: Some(0.2),
                max_tokens: Some(900),

                reasoning_mode: ReasoningMode::Off,
                reasoning_encoding: ReasoningEncoding::Thinking,
            },
        })
        .unwrap();
        assert_eq!(plan.endpoint, "https://api.deepseek.com/chat/completions");
        assert!(
            plan.parts[0]
                .wire_body
                .contains("\"model\":\"deepseek-flash\"")
        );
        assert!(plan.parts[0].wire_body.contains("\"stream\":true"));
        assert!(
            plan.parts[0]
                .wire_body
                .contains("\"stream_options\":{\"include_usage\":true}"),
            "body: {}",
            plan.parts[0].wire_body
        );
    }

    #[test]
    fn trace_shape_lists_keys_without_values() {
        let value: Value = serde_json::from_str(
            r#"{"choices":[{"delta":{"reasoning_content":"SECRET-REASONING"},"finish_reason":null}],"usage":{"prompt_tokens":1}}"#,
        )
        .unwrap();
        let shape = json_shape(&value);
        assert!(shape.contains("reasoning_content"));
        assert!(shape.contains("reasoning_content_chars=16"));
        assert!(shape.contains("usage_keys="));
        assert!(!shape.contains("SECRET-REASONING"));
    }

    #[test]
    fn payload_reports_a_mid_stream_error() {
        let error =
            parse_stream_payload(r#"{"error":{"message":"model overloaded"}}"#).unwrap_err();
        assert!(error.to_string().contains("model overloaded"));
    }

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    #[test]
    fn platform_network_errors_are_offline_only_for_a_remote_endpoint() {
        // The raw platform codes, not message text. std maps these to the portable ErrorKinds
        // the classifier matches; this test pins the mapping the app relies on.
        #[cfg(target_os = "macos")]
        let (unreachable_network, unreachable_host, network_down, refused) = (51, 65, 50, 61);
        #[cfg(target_os = "linux")]
        let (unreachable_network, unreachable_host, network_down, refused) = (101, 113, 100, 111);

        for code in [unreachable_network, unreachable_host, network_down] {
            let error = std::io::Error::from_raw_os_error(code);
            assert_eq!(classify_io_failure(&error, false), AiFailure::Offline);
            assert_eq!(classify_io_failure(&error, true), AiFailure::LocalServer);
        }

        let refused_error = std::io::Error::from_raw_os_error(refused);
        assert_eq!(
            classify_io_failure(&refused_error, true),
            AiFailure::LocalServer,
            "a refused loopback connection means the local server is not running"
        );
        assert_eq!(
            classify_io_failure(&refused_error, false),
            AiFailure::Other,
            "a refused remote connection is not evidence that this Mac is offline"
        );
    }

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    #[test]
    fn ureq_io_errors_keep_the_category_through_mapping() {
        #[cfg(target_os = "macos")]
        let (unreachable_network, refused) = (51, 61);
        #[cfg(target_os = "linux")]
        let (unreachable_network, refused) = (101, 111);

        let cancel = CancellationToken::new();
        let remote = map_ureq_error(
            ureq::Error::Io(std::io::Error::from_raw_os_error(unreachable_network)),
            &cancel,
            false,
        );
        assert_eq!(remote.failure(), AiFailure::Offline);

        let local = map_ureq_error(
            ureq::Error::Io(std::io::Error::from_raw_os_error(refused)),
            &cancel,
            true,
        );
        assert_eq!(local.failure(), AiFailure::LocalServer);

        let refused_remote = map_ureq_error(
            ureq::Error::Io(std::io::Error::from_raw_os_error(refused)),
            &cancel,
            false,
        );
        assert_eq!(refused_remote.failure(), AiFailure::Other);
    }

    #[test]
    fn other_transport_errors_stay_generic() {
        let reset = std::io::Error::from(std::io::ErrorKind::ConnectionReset);
        assert_eq!(classify_io_failure(&reset, false), AiFailure::Other);
        assert_eq!(classify_io_failure(&reset, true), AiFailure::Other);
    }

    #[test]
    fn error_failure_categories_are_stable() {
        assert_eq!(
            AiError::Offline("no route".to_string()).failure(),
            AiFailure::Offline
        );
        assert_eq!(
            AiError::LocalServer("refused".to_string()).failure(),
            AiFailure::LocalServer
        );
        assert_eq!(
            AiError::Unreachable("TLS".to_string()).failure(),
            AiFailure::Other
        );
        assert_eq!(
            AiError::HttpStatus("HTTP 500".to_string()).failure(),
            AiFailure::Other
        );
    }

    #[test]
    fn cancellation_flag_is_observable() {
        let cancel = CancellationToken::new();
        assert!(!cancel.is_cancelled());
        assert!(matches!(cancel.check(), Ok(())));
        cancel.cancel();
        assert!(matches!(cancel.check(), Err(AiError::Cancelled)));
    }
}
