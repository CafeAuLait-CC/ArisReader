//! OpenAI-compatible chat transport: request construction, streaming SSE decoding, timeouts,
//! cancellation and readable HTTP errors.
//!
//! The protocol is the one OpenAI, DeepSeek and local Ollama expose:
//! `POST {base}/chat/completions` with a JSON body and `stream: true`; the answer arrives as
//! server-sent events whose `data:` lines are JSON objects and whose last event is `[DONE]`.
//!
//! Two transports are provided:
//!
//! * [`TcpTransport`] speaks HTTP/1.1 directly for `http://` endpoints (Ollama and the tests);
//! * [`CurlTransport`] sends the same request through the system `curl` program for `https://`
//!   endpoints, keeping the `Authorization` header out of its argv by passing the whole request
//!   configuration on stdin.
//!
//! Neither transport logs. The key lives only in the request headers and, for curl, in the
//! config written to the child's stdin.

use std::fmt;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream, ToSocketAddrs};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use serde_json::Value;

use crate::chat::{ChatPart, ChatPlan};
use crate::provider::AiError;

/// Status, reason, headers, and body bytes that followed the response head.
type ResponseHead = (u16, String, Vec<(String, String)>, Vec<u8>);

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

/// Pick the transport for an endpoint: plain HTTP uses the in-process TCP client, HTTPS goes
/// through the system `curl` (the dependency set has no TLS client crate).
pub fn default_transport(url: &str, config: ClientConfig) -> Result<Box<dyn Transport>, AiError> {
    let lower = url.to_ascii_lowercase();
    if lower.starts_with("http://") {
        Ok(Box::new(TcpTransport::new(config)))
    } else if lower.starts_with("https://") {
        Ok(Box::new(CurlTransport::new(config)))
    } else {
        Err(AiError::InvalidSettings(
            "The endpoint must use http:// or https://.".to_string(),
        ))
    }
}

// ── Plain HTTP transport ────────────────────────────────────────────────────────────────────

#[derive(Clone, Debug)]
struct HttpTarget {
    host: String,
    port: u16,
    path: String,
    host_header: String,
}

pub struct TcpTransport {
    config: ClientConfig,
}

impl TcpTransport {
    pub fn new(config: ClientConfig) -> Self {
        Self { config }
    }

    fn connect(
        &self,
        target: &HttpTarget,
        cancel: &CancellationToken,
    ) -> Result<TcpStream, AiError> {
        cancel.check()?;
        let addresses: Vec<SocketAddr> = (target.host.as_str(), target.port)
            .to_socket_addrs()
            .map_err(|error| {
                AiError::Unreachable(format!("could not resolve {}: {error}", target.host))
            })?
            .collect();
        if addresses.is_empty() {
            return Err(AiError::Unreachable(format!(
                "could not resolve {}",
                target.host
            )));
        }
        let mut last_error = None;
        for address in addresses {
            cancel.check()?;
            match TcpStream::connect_timeout(&address, self.config.connect_timeout) {
                Ok(stream) => {
                    let _ = stream.set_nodelay(true);
                    let _ = stream.set_read_timeout(Some(POLL_INTERVAL));
                    let _ = stream.set_write_timeout(Some(self.config.connect_timeout));
                    return Ok(stream);
                }
                Err(error) => last_error = Some(error),
            }
        }
        Err(AiError::Unreachable(match last_error {
            Some(error) => format!("could not connect to {}: {error}", target.host),
            None => format!("could not connect to {}", target.host),
        }))
    }
}

impl Transport for TcpTransport {
    fn execute(
        &self,
        spec: &RequestSpec,
        cancel: &CancellationToken,
    ) -> Result<Box<dyn ResponseStream>, AiError> {
        let target = parse_http_target(&spec.url)?;
        let mut stream = self.connect(&target, cancel)?;
        let mut request = Vec::new();
        request.extend_from_slice(
            format!(
                "{} {} HTTP/1.1\r\nHost: {}\r\n",
                spec.method, target.path, target.host_header
            )
            .as_bytes(),
        );
        for (name, value) in &spec.headers {
            request.extend_from_slice(format!("{name}: {value}\r\n").as_bytes());
        }
        request.extend_from_slice(format!("Content-Length: {}\r\n", spec.body.len()).as_bytes());
        request.extend_from_slice(b"Connection: close\r\n\r\n");
        request.extend_from_slice(&spec.body);
        cancel.check()?;
        stream.write_all(&request).map_err(|error| {
            AiError::Unreachable(format!("could not send the request: {error}"))
        })?;

        let (status, reason, headers, leftover) =
            read_response_headers(&mut stream, &self.config, cancel)?;
        let body = BodyDecoder::new(&headers);
        Ok(Box::new(TcpResponseStream {
            stream,
            status,
            reason,
            headers,
            body,
            leftover,
            cancel: cancel.clone(),
            config: self.config,
            last_activity: Instant::now(),
            started: Instant::now(),
        }))
    }
}

struct TcpResponseStream {
    stream: TcpStream,
    status: u16,
    reason: String,
    headers: Vec<(String, String)>,
    body: BodyDecoder,
    leftover: Vec<u8>,
    cancel: CancellationToken,
    config: ClientConfig,
    last_activity: Instant,
    started: Instant,
}

impl ResponseStream for TcpResponseStream {
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
        loop {
            self.cancel.check()?;
            check_deadline(self.last_activity, self.started, &self.config)?;

            if !self.leftover.is_empty() {
                let chunk = std::mem::take(&mut self.leftover);
                let decoded = self.body.feed(&chunk)?;
                if !decoded.is_empty() {
                    return Ok(Some(decoded));
                }
                if self.body.is_done() {
                    return Ok(None);
                }
                continue;
            }
            if self.body.is_done() {
                return Ok(None);
            }

            let mut buffer = [0u8; 8192];
            match self.stream.read(&mut buffer) {
                Ok(0) => {
                    self.body.finish()?;
                    return Ok(None);
                }
                Ok(read) => {
                    self.last_activity = Instant::now();
                    let decoded = self.body.feed(&buffer[..read])?;
                    if !decoded.is_empty() {
                        return Ok(Some(decoded));
                    }
                    if self.body.is_done() {
                        return Ok(None);
                    }
                }
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    // The read timeout is how a blocking transport notices cancellation.
                }
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
                Err(error) => {
                    return Err(AiError::Unreachable(format!(
                        "the connection failed while reading: {error}"
                    )));
                }
            }
        }
    }
}

fn check_deadline(
    last_activity: Instant,
    started: Instant,
    config: &ClientConfig,
) -> Result<(), AiError> {
    if last_activity.elapsed() >= config.idle_timeout {
        return Err(AiError::Timeout(format!(
            "the provider sent no data for {} seconds",
            config.idle_timeout.as_secs().max(1)
        )));
    }
    if started.elapsed() >= config.max_time {
        return Err(AiError::Timeout(format!(
            "the request exceeded its {} second limit",
            config.max_time.as_secs().max(1)
        )));
    }
    Ok(())
}

fn parse_http_target(url: &str) -> Result<HttpTarget, AiError> {
    let lower = url.to_ascii_lowercase();
    let rest = if lower.starts_with("http://") {
        &url[7..]
    } else {
        return Err(AiError::InvalidSettings(
            "The plain HTTP transport only handles http:// URLs.".to_string(),
        ));
    };
    let authority_end = rest.find('/').unwrap_or(rest.len());
    let authority = &rest[..authority_end];
    let path = if authority_end == rest.len() {
        "/".to_string()
    } else {
        rest[authority_end..].to_string()
    };
    let (host, port) = parse_authority(authority)?;
    let default_port = 80u16;
    let port = port.unwrap_or(default_port);
    let host_header = if port == default_port && !host.contains(':') {
        host.clone()
    } else if host.contains(':') {
        format!("[{host}]:{port}")
    } else {
        format!("{host}:{port}")
    };
    Ok(HttpTarget {
        host,
        port,
        path,
        host_header,
    })
}

fn parse_authority(authority: &str) -> Result<(String, Option<u16>), AiError> {
    if let Some(rest) = authority.strip_prefix('[') {
        let Some(close) = rest.find(']') else {
            return Err(AiError::InvalidSettings(
                "The IPv6 address is missing ']'.".to_string(),
            ));
        };
        let host = rest[..close].to_string();
        let after = &rest[close + 1..];
        let port = if after.is_empty() {
            None
        } else if let Some(port) = after.strip_prefix(':') {
            Some(port.parse::<u16>().map_err(|_| {
                AiError::InvalidSettings("The endpoint port is not a number.".to_string())
            })?)
        } else {
            return Err(AiError::InvalidSettings(
                "The endpoint has characters after the IPv6 address.".to_string(),
            ));
        };
        return Ok((host, port));
    }
    match authority.rsplit_once(':') {
        Some((host, port)) => {
            let port = port.parse::<u16>().map_err(|_| {
                AiError::InvalidSettings("The endpoint port is not a number.".to_string())
            })?;
            Ok((host.to_string(), Some(port)))
        }
        None => Ok((authority.to_string(), None)),
    }
}

fn read_response_headers(
    stream: &mut TcpStream,
    config: &ClientConfig,
    cancel: &CancellationToken,
) -> Result<ResponseHead, AiError> {
    let started = Instant::now();
    let mut last_activity = Instant::now();
    let mut buffer = Vec::new();
    loop {
        cancel.check()?;
        check_deadline(last_activity, started, config)?;
        if let Some((status, reason, headers, leftover)) = parse_head_block(&buffer)? {
            if (100..200).contains(&status) {
                buffer = leftover;
                continue;
            }
            return Ok((status, reason, headers, leftover));
        }
        if buffer.len() > 64 * 1024 {
            return Err(AiError::Protocol(
                "The server sent more than 64 KiB of response headers.".to_string(),
            ));
        }
        let mut chunk = [0u8; 4096];
        match stream.read(&mut chunk) {
            Ok(0) => {
                return Err(AiError::Unreachable(
                    "the server closed the connection before sending response headers".to_string(),
                ));
            }
            Ok(read) => {
                last_activity = Instant::now();
                buffer.extend_from_slice(&chunk[..read]);
            }
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) => {}
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(error) => {
                return Err(AiError::Unreachable(format!(
                    "could not read response headers: {error}"
                )));
            }
        }
    }
}

fn parse_head_block(buffer: &[u8]) -> Result<Option<ResponseHead>, AiError> {
    let Some(end) = find_bytes(buffer, b"\r\n\r\n") else {
        return Ok(None);
    };
    let head = String::from_utf8_lossy(&buffer[..end]);
    let leftover = buffer[end + 4..].to_vec();
    let mut lines = head.split("\r\n");
    let status_line = lines
        .next()
        .ok_or_else(|| AiError::Protocol("The server sent an empty response head.".to_string()))?;
    let mut parts = status_line.splitn(3, ' ');
    let protocol = parts.next().unwrap_or("");
    if !protocol.starts_with("HTTP/") {
        return Err(AiError::Protocol(format!(
            "The server did not answer with HTTP: {}",
            truncate(status_line, 120)
        )));
    }
    let status: u16 = parts
        .next()
        .and_then(|value| value.parse().ok())
        .ok_or_else(|| {
            AiError::Protocol(format!(
                "Unreadable HTTP status line: {}",
                truncate(status_line, 120)
            ))
        })?;
    let reason = parts.next().unwrap_or("").trim().to_string();
    let mut headers = Vec::new();
    for line in lines {
        if line.is_empty() {
            continue;
        }
        if let Some((name, value)) = line.split_once(':') {
            headers.push((name.trim().to_ascii_lowercase(), value.trim().to_string()));
        }
    }
    Ok(Some((status, reason, headers, leftover)))
}

fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

fn header_value<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    headers
        .iter()
        .find(|(candidate, _)| candidate.eq_ignore_ascii_case(name))
        .map(|(_, value)| value.as_str())
}

// ── Decoding the response body ─────────────────────────────────────────────────────────────

enum BodyMode {
    Chunked(ChunkedDecoder),
    ContentLength(u64),
    UntilEof,
}

struct BodyDecoder {
    mode: BodyMode,
    done: bool,
}

impl BodyDecoder {
    fn new(headers: &[(String, String)]) -> Self {
        let chunked = header_value(headers, "transfer-encoding")
            .map(|value| value.to_ascii_lowercase().contains("chunked"))
            .unwrap_or(false);
        let mode = if chunked {
            BodyMode::Chunked(ChunkedDecoder::default())
        } else if let Some(length) =
            header_value(headers, "content-length").and_then(|value| value.parse::<u64>().ok())
        {
            BodyMode::ContentLength(length)
        } else {
            BodyMode::UntilEof
        };
        Self { mode, done: false }
    }

    fn is_done(&self) -> bool {
        self.done
    }

    fn feed(&mut self, bytes: &[u8]) -> Result<Vec<u8>, AiError> {
        match &mut self.mode {
            BodyMode::Chunked(decoder) => {
                let decoded = decoder.feed(bytes)?;
                if decoder.done {
                    self.done = true;
                }
                Ok(decoded)
            }
            BodyMode::ContentLength(remaining) => {
                if *remaining == 0 {
                    self.done = true;
                    return Ok(Vec::new());
                }
                let take = bytes.len().min(*remaining as usize);
                *remaining -= take as u64;
                if *remaining == 0 {
                    self.done = true;
                }
                Ok(bytes[..take].to_vec())
            }
            BodyMode::UntilEof => {
                if bytes.is_empty() {
                    self.done = true;
                    Ok(Vec::new())
                } else {
                    Ok(bytes.to_vec())
                }
            }
        }
    }

    fn finish(&mut self) -> Result<(), AiError> {
        match &mut self.mode {
            BodyMode::Chunked(decoder) => {
                if decoder.done {
                    self.done = true;
                    Ok(())
                } else {
                    Err(AiError::Protocol(
                        "The server closed the connection in the middle of a chunked response."
                            .to_string(),
                    ))
                }
            }
            BodyMode::ContentLength(remaining) => {
                if *remaining == 0 {
                    self.done = true;
                    Ok(())
                } else {
                    Err(AiError::Protocol(
                        "The server closed the connection before the response body was complete."
                            .to_string(),
                    ))
                }
            }
            BodyMode::UntilEof => {
                self.done = true;
                Ok(())
            }
        }
    }
}

#[derive(Default)]
struct ChunkedDecoder {
    buffer: Vec<u8>,
    state: ChunkState,
    done: bool,
}

#[derive(Default)]
enum ChunkState {
    #[default]
    NeedSize,
    Data(u64),
    Crlf,
    Trailers,
}

impl ChunkedDecoder {
    fn feed(&mut self, bytes: &[u8]) -> Result<Vec<u8>, AiError> {
        self.buffer.extend_from_slice(bytes);
        let mut output = Vec::new();
        loop {
            match &mut self.state {
                ChunkState::NeedSize => {
                    let Some(end) = find_bytes(&self.buffer, b"\r\n") else {
                        if self.buffer.len() > 1024 {
                            return Err(AiError::Protocol(
                                "The chunked response has an overlong size line.".to_string(),
                            ));
                        }
                        break;
                    };
                    let line = String::from_utf8_lossy(&self.buffer[..end]).to_string();
                    self.buffer.drain(..end + 2);
                    let size_text = line.split(';').next().unwrap_or("").trim();
                    let size = u64::from_str_radix(size_text, 16).map_err(|_| {
                        AiError::Protocol(format!(
                            "The chunked response has an unreadable chunk size: {}",
                            truncate(&line, 80)
                        ))
                    })?;
                    if size == 0 {
                        self.state = ChunkState::Trailers;
                    } else {
                        self.state = ChunkState::Data(size);
                    }
                }
                ChunkState::Data(remaining) => {
                    if self.buffer.is_empty() {
                        break;
                    }
                    let take = (self.buffer.len() as u64).min(*remaining) as usize;
                    output.extend(self.buffer.drain(..take));
                    *remaining -= take as u64;
                    if *remaining == 0 {
                        self.state = ChunkState::Crlf;
                    }
                }
                ChunkState::Crlf => {
                    if self.buffer.len() < 2 {
                        break;
                    }
                    if &self.buffer[..2] != b"\r\n" {
                        return Err(AiError::Protocol(
                            "The chunked response is missing the CRLF after a chunk.".to_string(),
                        ));
                    }
                    self.buffer.drain(..2);
                    self.state = ChunkState::NeedSize;
                }
                ChunkState::Trailers => {
                    if let Some(end) = find_bytes(&self.buffer, b"\r\n\r\n") {
                        self.buffer.drain(..end + 4);
                        self.done = true;
                    } else if self.buffer.starts_with(b"\r\n") {
                        self.buffer.drain(..2);
                        self.done = true;
                    } else {
                        break;
                    }
                    if self.done {
                        break;
                    }
                }
            }
        }
        Ok(output)
    }
}

// ── curl transport for HTTPS ───────────────────────────────────────────────────────────────

/// The argv and stdin configuration for a curl request. Public so a test can prove the key is not
/// in the argv; the struct intentionally has no `Debug` implementation.
pub struct CurlInvocation {
    pub args: Vec<String>,
    pub stdin_config: String,
}

pub struct CurlTransport {
    config: ClientConfig,
}

impl CurlTransport {
    pub fn new(config: ClientConfig) -> Self {
        Self { config }
    }
}

impl Transport for CurlTransport {
    fn execute(
        &self,
        spec: &RequestSpec,
        cancel: &CancellationToken,
    ) -> Result<Box<dyn ResponseStream>, AiError> {
        let invocation = curl_invocation(spec, self.config)?;
        cancel.check()?;
        let mut child = Command::new("curl")
            .args(&invocation.args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|error| {
                AiError::Unreachable(format!(
                    "HTTPS needs the system curl program, which could not be started: {error}"
                ))
            })?;
        if let Some(mut stdin) = child.stdin.take()
            && let Err(error) = stdin.write_all(invocation.stdin_config.as_bytes())
        {
            let _ = child.kill();
            let _ = child.wait();
            return Err(AiError::Unreachable(format!(
                "could not pass the request to curl: {error}"
            )));
        }
        let Some(stdout) = child.stdout.take() else {
            let _ = child.kill();
            let _ = child.wait();
            return Err(AiError::Unreachable("curl has no stdout".to_string()));
        };
        let Some(stderr) = child.stderr.take() else {
            let _ = child.kill();
            let _ = child.wait();
            return Err(AiError::Unreachable("curl has no stderr".to_string()));
        };
        let child = Arc::new(Mutex::new(child));
        let stderr_text = Arc::new(Mutex::new(String::new()));
        spawn_stderr_reader(stderr, Arc::clone(&stderr_text));

        let (sender, receiver) = mpsc::channel();
        thread::spawn(move || {
            let mut stdout = stdout;
            let mut buffer = [0u8; 8192];
            loop {
                match stdout.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(read) => {
                        if sender.send(Ok(buffer[..read].to_vec())).is_err() {
                            break;
                        }
                    }
                    Err(error) => {
                        let _ = sender.send(Err(error.to_string()));
                        break;
                    }
                }
            }
        });

        let started = Instant::now();
        let mut last_activity = Instant::now();
        let mut header_buffer = Vec::new();
        let result = (|| -> Result<Box<dyn ResponseStream>, AiError> {
            loop {
                cancel.check()?;
                check_deadline(last_activity, started, &self.config)?;
                if let Some((status, reason, headers, leftover)) = parse_head_block(&header_buffer)?
                {
                    if (100..200).contains(&status) {
                        header_buffer = leftover;
                        continue;
                    }
                    return Ok(Box::new(CurlResponseStream {
                        receiver,
                        status,
                        reason,
                        headers,
                        leftover,
                        child: Arc::clone(&child),
                        stderr: Arc::clone(&stderr_text),
                        cancel: cancel.clone(),
                        config: self.config,
                        last_activity: Instant::now(),
                        started,
                        finished: false,
                    }));
                }
                match receiver.recv_timeout(POLL_INTERVAL) {
                    Ok(Ok(chunk)) => {
                        last_activity = Instant::now();
                        header_buffer.extend_from_slice(&chunk);
                    }
                    Ok(Err(error)) => {
                        let detail = error.to_string();
                        return Err(AiError::Unreachable(format!(
                            "could not read curl's output: {detail}"
                        )));
                    }
                    Err(RecvTimeoutError::Timeout) => {}
                    Err(RecvTimeoutError::Disconnected) => {
                        let code = terminate(&child);
                        let detail = take_stderr(&stderr_text);
                        return Err(curl_exit_error(code, &detail));
                    }
                }
            }
        })();
        if result.is_err() {
            terminate(&child);
        }
        result
    }
}

struct CurlResponseStream {
    receiver: Receiver<Result<Vec<u8>, String>>,
    status: u16,
    reason: String,
    headers: Vec<(String, String)>,
    leftover: Vec<u8>,
    child: Arc<Mutex<Child>>,
    stderr: Arc<Mutex<String>>,
    cancel: CancellationToken,
    config: ClientConfig,
    last_activity: Instant,
    started: Instant,
    finished: bool,
}

impl ResponseStream for CurlResponseStream {
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
        if !self.leftover.is_empty() {
            return Ok(Some(std::mem::take(&mut self.leftover)));
        }
        loop {
            if self.cancel.is_cancelled() {
                self.finished = true;
                terminate(&self.child);
                return Err(AiError::Cancelled);
            }
            check_deadline(self.last_activity, self.started, &self.config)?;
            match self.receiver.recv_timeout(POLL_INTERVAL) {
                Ok(Ok(chunk)) => {
                    self.last_activity = Instant::now();
                    return Ok(Some(chunk));
                }
                Ok(Err(error)) => {
                    self.finished = true;
                    terminate(&self.child);
                    return Err(AiError::Unreachable(format!(
                        "could not read curl's output: {error}"
                    )));
                }
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => {
                    self.finished = true;
                    let code = terminate(&self.child);
                    if code == 0 {
                        return Ok(None);
                    }
                    return Err(curl_exit_error(code, &take_stderr(&self.stderr)));
                }
            }
        }
    }
}

impl Drop for CurlResponseStream {
    fn drop(&mut self) {
        if !self.finished {
            terminate(&self.child);
        }
    }
}

fn spawn_stderr_reader(mut stderr: std::process::ChildStderr, output: Arc<Mutex<String>>) {
    thread::spawn(move || {
        let mut buffer = [0u8; 4096];
        loop {
            match stderr.read(&mut buffer) {
                Ok(0) => break,
                Ok(read) => {
                    if let Ok(mut text) = output.lock()
                        && text.len() < MAX_ERROR_BODY
                    {
                        text.push_str(&String::from_utf8_lossy(&buffer[..read]));
                    }
                }
                Err(_) => break,
            }
        }
    });
}

fn take_stderr(stderr: &Arc<Mutex<String>>) -> String {
    stderr
        .lock()
        .map(|text| text.trim().to_string())
        .unwrap_or_default()
}

/// Kill and reap a curl child, returning its exit code when one is available.
fn terminate(child: &Arc<Mutex<Child>>) -> i32 {
    let mut child = match child.lock() {
        Ok(child) => child,
        Err(poisoned) => poisoned.into_inner(),
    };
    let _ = child.kill();
    match child.wait() {
        Ok(status) => status.code().unwrap_or(-1),
        Err(_) => -1,
    }
}

fn curl_exit_error(code: i32, stderr: &str) -> AiError {
    let detail = truncate(stderr, MAX_DETAIL_CHARS);
    if code == 28 {
        return AiError::Timeout(if detail.is_empty() {
            "the request timed out".to_string()
        } else {
            format!("the request timed out: {detail}")
        });
    }
    let suffix = if detail.is_empty() {
        String::new()
    } else {
        format!(": {detail}")
    };
    AiError::Unreachable(format!("curl exited with status {code}{suffix}"))
}

/// Build the argv and stdin configuration for a curl request.
///
/// The API key is written into the **stdin config**, never into `args`: process arguments are
/// visible to other processes, and this is the only place where that is easy to get wrong.
pub fn curl_invocation(
    spec: &RequestSpec,
    config: ClientConfig,
) -> Result<CurlInvocation, AiError> {
    if !spec
        .headers
        .iter()
        .any(|(name, _)| name.eq_ignore_ascii_case("authorization"))
    {
        return Err(AiError::InvalidSettings(
            "The request has no Authorization header.".to_string(),
        ));
    }
    let mut lines = Vec::new();
    lines.push(format!("url = \"{}\"", curl_quote(&spec.url)));
    lines.push(format!("request = \"{}\"", spec.method));
    for (name, value) in &spec.headers {
        if name.eq_ignore_ascii_case("authorization") {
            // Keep the key on stdin with the rest of the configuration.
            lines.push(format!("header = \"{}: {}\"", name, curl_quote(value)));
        } else {
            lines.push(format!("header = \"{}: {}\"", name, curl_quote(value)));
        }
    }
    let body = String::from_utf8_lossy(&spec.body);
    lines.push(format!("data-binary = \"{}\"", curl_quote(&body)));
    lines.push(format!(
        "connect-timeout = {}",
        config.connect_timeout.as_secs().max(1)
    ));
    lines.push(format!("max-time = {}", config.max_time.as_secs().max(1)));
    lines.push("speed-limit = 1".to_string());
    lines.push(format!(
        "speed-time = {}",
        config.idle_timeout.as_secs().max(1)
    ));
    // `--include` prints the response head; `--no-buffer` keeps the SSE chunks flowing.
    let args = vec![
        "--silent".to_string(),
        "--show-error".to_string(),
        "--include".to_string(),
        "--no-buffer".to_string(),
        "--http1.1".to_string(),
        "--config".to_string(),
        "-".to_string(),
    ];
    Ok(CurlInvocation {
        args,
        stdin_config: lines.join("\n") + "\n",
    })
}

fn curl_quote(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for character in value.chars() {
        match character {
            '\\' => escaped.push_str("\\\\"),
            '"' => escaped.push_str("\\\""),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            '\t' => escaped.push_str("\\t"),
            other => escaped.push(other),
        }
    }
    escaped
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
    fn curl_keeps_the_key_out_of_argv() {
        let plan = test_plan();
        let spec = build_request_spec(&plan, &plan.parts[0], "sk-secret-12345").unwrap();
        let invocation = curl_invocation(&spec, ClientConfig::default()).unwrap();
        assert!(!invocation.args.join(" ").contains("sk-secret-12345"));
        assert!(invocation.stdin_config.contains("sk-secret-12345"));
        assert!(invocation.stdin_config.contains("data-binary"));
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
