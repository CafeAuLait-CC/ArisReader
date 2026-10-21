//! LLM provider abstraction. **This module contains no vendor-specific code**; implementations arrive in M5 (T5.1).

/// AI layer error.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AiError {
    /// No provider configured (in this case the UI should hide the AI entry point rather than show a greyed-out button).
    NotConfigured,
    /// A transport failure that is not one of the recognized categories below (for example a
    /// TLS handshake error, a remote host that refused the connection, or a malformed response).
    Unreachable(String),
    /// The request never left this Mac: no route to the provider, the network is down, or the
    /// provider's name could not be resolved. Only produced for a remote endpoint.
    Offline(String),
    /// The configured endpoint is loopback and nothing is listening there. This is not evidence
    /// that the Mac has no network.
    LocalServer(String),
    /// Authentication failed (invalid or expired key).
    Unauthorized,
    /// Rate or quota limit exceeded.
    RateLimited,
    /// Cancelled by the user or the system.
    Cancelled,
    /// The model does not support the requested capability (for example an image sent to a text-only model).
    UnsupportedCapability(&'static str),
    /// The reader's settings are not usable (empty URL, bad model, an impossible temperature).
    InvalidSettings(String),
    /// The requested context has nothing to send (no text layer, empty selection, no pages).
    EmptyContext(String),
    /// The provider answered with an HTTP status that is not 2xx.
    HttpStatus(String),
    /// The response was not the streaming protocol this client speaks.
    Protocol(String),
    /// The connection or the stream took too long.
    Timeout(String),
    /// Any other error.
    Other(String),
}

impl std::fmt::Display for AiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotConfigured => write!(f, "AI provider not configured"),
            Self::Unreachable(what) => write!(f, "provider unreachable: {what}"),
            Self::Offline(what) => write!(f, "provider unreachable: {what}"),
            Self::LocalServer(what) => write!(f, "provider unreachable: {what}"),
            Self::Unauthorized => write!(f, "unauthorized (check API key)"),
            Self::RateLimited => write!(f, "rate limited"),
            Self::Cancelled => write!(f, "cancelled"),
            Self::UnsupportedCapability(c) => write!(f, "model lacks capability: {c}"),
            Self::InvalidSettings(message) => write!(f, "{message}"),
            Self::EmptyContext(message) => write!(f, "{message}"),
            Self::HttpStatus(message) => write!(f, "{message}"),
            Self::Protocol(message) => write!(f, "{message}"),
            Self::Timeout(message) => write!(f, "{message}"),
            Self::Other(msg) => write!(f, "{msg}"),
        }
    }
}

impl std::error::Error for AiError {}

/// Why a transport failed, reduced to the few cases the shell can describe honestly.
///
/// The shell shows a no-network hint only for [`AiFailure::Offline`], and a "the local server is
/// not running" sentence only for [`AiFailure::LocalServer`]. Everything else keeps the existing
/// transport error text. This crosses the FFI boundary with every error event so neither the
/// panel nor the audit trail has to match on a message.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AiFailure {
    Other,
    Offline,
    LocalServer,
}

impl AiError {
    /// The stable category of this error. Message text is never inspected.
    pub fn failure(&self) -> AiFailure {
        match self {
            Self::Offline(_) => AiFailure::Offline,
            Self::LocalServer(_) => AiFailure::LocalServer,
            _ => AiFailure::Other,
        }
    }
}

/// Model capabilities.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Capabilities {
    pub streaming: bool,
    /// Supports image input (region discussion, chart understanding).
    pub vision: bool,
    /// Supports local embeddings (RAG).
    pub embeddings: bool,
    /// Supports tool calling.
    pub tools: bool,
    /// The model runs locally (privacy first, no upload required).
    pub local: bool,
}

/// Chat role.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    System,
    User,
    Assistant,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ChatMessage {
    pub role: Role,
    pub text: String,
}

/// A single chat request.
#[derive(Clone, Debug, PartialEq)]
pub struct ChatRequest {
    pub request_id: u64,
    pub messages: Vec<ChatMessage>,
    /// Attached images (vision models).
    pub images: Vec<super::ImageRef>,
    pub max_tokens: u32,
    pub temperature: f32,
}

impl Default for ChatRequest {
    fn default() -> Self {
        Self {
            request_id: 0,
            messages: Vec::new(),
            images: Vec::new(),
            max_tokens: 2048,
            temperature: 0.2,
        }
    }
}

/// Streaming callback: the host renders the token stream into the panel.
pub trait StreamSink: Send {
    fn on_delta(&mut self, text: &str);
    fn on_done(&mut self);
    fn on_error(&mut self, error: AiError);
}

/// Model provider (cloud or local).
pub trait LlmProvider: Send + Sync {
    fn id(&self) -> &str;
    fn capabilities(&self) -> Capabilities;

    /// Run a chat turn; **must block on a dedicated thread/runtime**, the caller is responsible for not blocking the UI.
    fn chat(&self, request: ChatRequest, sink: &mut dyn StreamSink) -> Result<(), AiError>;

    /// Cancel an in-flight request.
    fn cancel(&self, request_id: u64);
}

/// Provider registry and current selection (M5 T5.8: prefer local models).
#[derive(Default)]
pub struct ProviderRegistry {
    providers: Vec<Box<dyn LlmProvider>>,
    active: Option<String>,
}

impl ProviderRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn register(&mut self, provider: Box<dyn LlmProvider>) {
        self.providers.push(provider);
    }

    pub fn is_empty(&self) -> bool {
        self.providers.is_empty()
    }

    pub fn active_id(&self) -> Option<&str> {
        self.active.as_deref()
    }

    /// Select a provider; `None` means not configured (the UI should hide the AI entry point).
    pub fn set_active(&mut self, id: Option<&str>) {
        self.active = id.map(|s| s.to_string());
    }

    pub fn get(&self, id: &str) -> Option<&dyn LlmProvider> {
        self.providers
            .iter()
            .find(|p| p.id() == id)
            .map(|p| p.as_ref())
    }
}
