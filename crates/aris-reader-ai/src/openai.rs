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
use crate::provider::AiError;

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
            ("User-Agent".to_string(), "Lyra/0.0".to_string()),
        ],
        body: part.wire_body.as_bytes().to_vec(),
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
        ("User-Agent".to_string(), "Lyra/0.0".to_string()),
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
    Usage(TokenUsage),
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
            .map_err(|error| map_ureq_error(error, cancel))?;
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

fn map_ureq_error(error: ureq::Error, cancel: &CancellationToken) -> AiError {
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
        ureq::Error::Io(error) => AiError::Unreachable(format!("the connection failed: {error}")),
        ureq::Error::HostNotFound => {
            AiError::Unreachable("could not resolve the provider host".to_string())
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
    Usage(TokenUsage),
}

/// Decode one `data:` payload. Unknown fields and empty keep-alives are ignored; an `error`
/// object or malformed JSON becomes a readable error.
pub fn parse_stream_payload(data: &str) -> Result<Vec<StreamPayload>, AiError> {
    let value: Value = serde_json::from_str(data).map_err(|error| {
        AiError::Protocol(format!(
            "The provider sent a data event that is not JSON ({}): {}",
            error,
            truncate(data, 160)
        ))
    })?;
    let mut payloads = Vec::new();
    if let Some(error) = value.get("error") {
        let message = error
            .get("message")
            .and_then(Value::as_str)
            .map(str::to_string)
            .or_else(|| error.as_str().map(str::to_string))
            .unwrap_or_else(|| "The provider reported an error mid-stream.".to_string());
        return Err(AiError::Other(message));
    }
    if let Some(choices) = value.get("choices").and_then(Value::as_array)
        && let Some(choice) = choices.first()
        && let Some(delta) = choice.get("delta").and_then(|delta| delta.get("content"))
    {
        let text = content_text(delta);
        if !text.is_empty() {
            payloads.push(StreamPayload::Delta(text));
        }
    }
    if let Some(usage) = value.get("usage").and_then(Value::as_object) {
        let parsed = TokenUsage {
            prompt_tokens: usage.get("prompt_tokens").and_then(Value::as_u64),
            completion_tokens: usage.get("completion_tokens").and_then(Value::as_u64),
            total_tokens: usage.get("total_tokens").and_then(Value::as_u64),
        };
        if parsed != TokenUsage::default() {
            payloads.push(StreamPayload::Usage(parsed));
        }
    }
    Ok(payloads)
}

fn content_text(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Array(parts) => {
            let mut text = String::new();
            for part in parts {
                if let Some(segment) = part.get("text").and_then(Value::as_str) {
                    text.push_str(segment);
                }
            }
            text
        }
        _ => String::new(),
    }
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
        if !(200..300).contains(&status) {
            let body = read_error_body(&mut *response, cancel)?;
            return Err(http_error(status, response.reason(), &body));
        }

        let mut decoder = SseDecoder::new();
        loop {
            cancel.check()?;
            let chunk = match response.next_chunk() {
                Ok(Some(chunk)) => chunk,
                Ok(None) => break,
                Err(error) => return Err(error),
            };
            for frame in decoder.push(&chunk)? {
                match frame {
                    SseFrame::Done => {}
                    SseFrame::Data(data) => {
                        for payload in parse_stream_payload(&data)? {
                            match payload {
                                StreamPayload::Delta(text) => emit(RunEvent::Delta(text)),
                                StreamPayload::Usage(usage) => emit(RunEvent::Usage(usage)),
                            }
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
            return Err(AiError::Protocol(
                "The server closed the connection before [DONE]; the answer is incomplete."
                    .to_string(),
            ));
        }
    }
    emit(RunEvent::Done);
    Ok(())
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
        400 | 404 | 422 => with_detail(format!(
            "The provider rejected the request ({status_label})."
        )),
        500..=599 => with_detail(format!("The provider failed ({status_label}).")),
        _ => with_detail(format!("The provider answered with {status_label}.")),
    })
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
    use crate::chat::{Action, ChatSettings, PageText, PlanRequest, build_plan};

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
            }],
            settings: ChatSettings {
                base_url: "http://127.0.0.1:9/v1".to_string(),
                model: "test-model".to_string(),
                temperature: Some(0.2),
                max_tokens: Some(100),
            },
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
                    total_tokens: Some(12)
                })
            ]
        );
    }

    #[test]
    fn payload_reports_a_mid_stream_error() {
        let error =
            parse_stream_payload(r#"{"error":{"message":"model overloaded"}}"#).unwrap_err();
        assert!(error.to_string().contains("model overloaded"));
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
