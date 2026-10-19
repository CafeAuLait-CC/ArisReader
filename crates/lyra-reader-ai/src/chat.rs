//! Platform-independent chat planning: settings validation, context selection, retrieval and
//! prompt assembly.
//!
//! The shell owns the window, the API key and the Keychain. This module owns what would be sent:
//! which page text, which retrieved blocks, which prompt, and the exact JSON body for each
//! request. A plan is built *before* any request starts, so the panel can show it and the reader
//! can decide whether to send it.
//!
//! Nothing here performs I/O, reads a key, or logs. That keeps the plan cheap to test and makes
//! the privacy rule enforceable: the request preview and the request itself come from the same
//! [`ChatPart::wire_body`].

use std::collections::HashSet;
use std::net::Ipv4Addr;

use crate::provider::AiError;

/// Largest amount of page text placed in one request. Long documents are split into parts; a
/// single long page is truncated for a page summary and rejected for a translation.
pub const MAX_PART_CHARS: usize = 12_000;
/// Largest amount of one page used as context for a page summary or a selection question.
pub const MAX_PAGE_CHARS: usize = 8_000;
/// Largest amount of selected text sent for one question. A translation refuses anything longer
/// rather than silently returning a partial translation.
pub const MAX_SELECTION_CHARS: usize = 12_000;
/// Retrieved context is deliberately small: it is a hint, not a second copy of the document.
pub const MAX_RETRIEVED_CHARS: usize = 2_000;
/// Retrieved blocks considered for one request.
pub const RETRIEVED_BLOCKS: usize = 4;
/// A page longer than this is split into several context segments before the parts are grouped.
const MAX_SEGMENT_CHARS: usize = 3_500;
/// Longest single paragraph kept intact before it is split on a whitespace boundary.
const MAX_BLOCK_CHARS: usize = 700;

/// What the reader asked the assistant to do.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    /// Summarise the page the reader is looking at.
    SummarizePage,
    /// Summarise every page, split into parts when the document is long.
    SummarizeDocument,
    /// Answer a question about the current selection.
    AskSelection,
    /// Translate the current selection.
    TranslateSelection,
}

impl Action {
    /// Short label for the panel and for the request preview.
    pub fn label(self) -> &'static str {
        match self {
            Self::SummarizePage => "Summarise this page",
            Self::SummarizeDocument => "Summarise the document",
            Self::AskSelection => "Ask about the selection",
            Self::TranslateSelection => "Translate the selection",
        }
    }

    /// Whether the action cannot run without a selected range.
    pub fn requires_selection(self) -> bool {
        matches!(self, Self::AskSelection | Self::TranslateSelection)
    }
}

/// Provider settings that are not secret. The API key is deliberately not a field here: it is
/// supplied to the request runner after the reader confirms the preview, so no plan can carry it.
#[derive(Clone, Debug, PartialEq)]
pub struct ChatSettings {
    /// Base URL such as `https://api.openai.com/v1` or `http://localhost:11434/v1`.
    pub base_url: String,
    /// Provider model name, for example `gpt-4o-mini` or `llama3.2`.
    pub model: String,
    pub temperature: Option<f32>,
    pub max_tokens: Option<u32>,
    /// Whether to ask the provider to think, and how hard. `Default` sends nothing.
    pub reasoning_mode: ReasoningMode,
    /// The request extension used to express `reasoning_mode`. One field only; a strict provider
    /// rejects unknown parameters, and sending several "to be safe" would hide which one failed.
    pub reasoning_encoding: ReasoningEncoding,
}

/// Reasoning request extensions. The provider is OpenAI-compatible for chat, but exposes these
/// extensions instead of a standard "disable reasoning" field.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ReasoningMode {
    /// Send no reasoning field at all (the plain OpenAI-compatible request).
    #[default]
    Default,
    Off,
    Low,
    High,
    Max,
}

impl ReasoningMode {
    pub fn from_wire(value: &str) -> Option<Self> {
        match value {
            "default" => Some(Self::Default),
            "off" => Some(Self::Off),
            "low" => Some(Self::Low),
            "high" => Some(Self::High),
            "max" => Some(Self::Max),
            _ => None,
        }
    }

    pub fn wire_name(self) -> &'static str {
        match self {
            Self::Default => "default",
            Self::Off => "off",
            Self::Low => "low",
            Self::High => "high",
            Self::Max => "max",
        }
    }

    fn effort(self) -> Option<&'static str> {
        match self {
            Self::Low => Some("low"),
            Self::High => Some("high"),
            Self::Max => Some("max"),
            Self::Default | Self::Off => None,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ReasoningEncoding {
    #[default]
    None,
    Thinking,
    ReasoningEffort,
    OutputConfig,
    Reasoning,
}

impl ReasoningEncoding {
    pub fn from_wire(value: &str) -> Option<Self> {
        match value {
            "none" => Some(Self::None),
            "thinking" => Some(Self::Thinking),
            "reasoning_effort" => Some(Self::ReasoningEffort),
            "output_config" => Some(Self::OutputConfig),
            "reasoning.effort" => Some(Self::Reasoning),
            _ => None,
        }
    }

    pub fn wire_name(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Thinking => "thinking",
            Self::ReasoningEffort => "reasoning_effort",
            Self::OutputConfig => "output_config",
            Self::Reasoning => "reasoning.effort",
        }
    }

    fn field_name(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Thinking => "thinking",
            Self::ReasoningEffort => "reasoning_effort",
            Self::OutputConfig => "output_config",
            Self::Reasoning => "reasoning",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
struct ReasoningRequest {
    field: &'static str,
    value: serde_json::Value,
    summary: String,
}

impl Default for ChatSettings {
    fn default() -> Self {
        Self {
            base_url: "https://api.openai.com/v1".to_string(),
            model: "gpt-4o-mini".to_string(),
            temperature: Some(0.2),
            max_tokens: Some(900),
            reasoning_mode: ReasoningMode::Off,
            reasoning_encoding: ReasoningEncoding::Thinking,
        }
    }
}

fn reasoning_request(
    mode: ReasoningMode,
    encoding: ReasoningEncoding,
) -> Result<Option<ReasoningRequest>, AiError> {
    if mode == ReasoningMode::Default {
        return Ok(None);
    }
    if encoding == ReasoningEncoding::None {
        return Err(invalid(
            "Choose a reasoning encoding, or set reasoning to default to send no reasoning field.",
        ));
    }
    let (field, value, summary) = match (mode, encoding) {
        (ReasoningMode::Off, ReasoningEncoding::Thinking) => (
            "thinking",
            serde_json::json!({ "type": "disabled" }),
            "Thinking: disabled (thinking.type = disabled).".to_string(),
        ),
        (ReasoningMode::Off, ReasoningEncoding::Reasoning) => (
            "reasoning",
            serde_json::json!({ "effort": "none" }),
            "Reasoning effort: none (reasoning.effort = none).".to_string(),
        ),
        (
            ReasoningMode::Low | ReasoningMode::High | ReasoningMode::Max,
            ReasoningEncoding::ReasoningEffort,
        ) => {
            let effort = mode.effort().expect("non-default mode");
            (
                "reasoning_effort",
                serde_json::json!(effort),
                format!("Reasoning effort: {effort} (reasoning_effort = {effort})."),
            )
        }
        (
            ReasoningMode::Low | ReasoningMode::High | ReasoningMode::Max,
            ReasoningEncoding::OutputConfig,
        ) => {
            let effort = mode.effort().expect("non-default mode");
            (
                "output_config",
                serde_json::json!({ "effort": effort }),
                format!("Output effort: {effort} (output_config.effort = {effort})."),
            )
        }
        (
            ReasoningMode::Low | ReasoningMode::High | ReasoningMode::Max,
            ReasoningEncoding::Reasoning,
        ) => {
            let effort = mode.effort().expect("non-default mode");
            (
                "reasoning",
                serde_json::json!({ "effort": effort }),
                format!("Reasoning effort: {effort} (reasoning.effort = {effort})."),
            )
        }
        (_, ReasoningEncoding::Thinking) => {
            return Err(invalid(
                "The thinking encoding is a toggle: use reasoning off or default with it. For low, high or max choose reasoning_effort, output_config, or reasoning.effort.",
            ));
        }
        (
            ReasoningMode::Off,
            ReasoningEncoding::ReasoningEffort | ReasoningEncoding::OutputConfig,
        ) => {
            return Err(invalid(
                "That encoding has no documented off value. Use the thinking or reasoning.effort encoding for off, or choose default.",
            ));
        }
        (ReasoningMode::Default, _) => unreachable!("handled before the match"),
        (_, ReasoningEncoding::None) => unreachable!("checked above"),
    };
    debug_assert_eq!(field, encoding.field_name());
    Ok(Some(ReasoningRequest {
        field,
        value,
        summary,
    }))
}

/// A validated endpoint. `base_url` and `endpoint` are normalised, not merely echoed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EndpointInfo {
    pub base_url: String,
    pub endpoint: String,
    /// Host without brackets, for display and for the local/remote badge.
    pub host: String,
    pub is_local: bool,
}

/// One character's box on the page, in view-space points. `page` text and `chars` are the same
/// sequence; the boxes let the context builder identify a line-number gutter without guessing
/// from the string (a numbered list or a table's index column must survive).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PageChar {
    pub unicode: u32,
    pub x_pt: f64,
    pub y_pt: f64,
    pub width_pt: f64,
    pub height_pt: f64,
}

/// One page's plain text. `page` is 0-based here, matching the engine; prompts and previews use
/// 1-based page numbers.
#[derive(Clone, Debug, PartialEq)]
pub struct PageText {
    pub page: u32,
    pub text: String,
    /// One entry per `text` character, when the caller has layout geometry. Empty means the
    /// caller only supplied text; gutter removal is then skipped (tests and callers without a
    /// text layer use that path).
    pub chars: Vec<PageChar>,
}

/// A selected character range on one page (inclusive, 0-based, aligned with the text layer).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SelectionRange {
    pub page: u32,
    pub start: u32,
    pub end: u32,
}

impl SelectionRange {
    fn character_count(self) -> usize {
        (self.end.saturating_sub(self.start) as usize).saturating_add(1)
    }
}

/// Everything the context builder needs. The FFI layer fills `pages` from the open document; the
/// Rust tests fill it with synthetic pages, so both exercise the same selection logic.
#[derive(Clone, Debug, PartialEq)]
pub struct PlanRequest {
    pub action: Action,
    pub document_title: String,
    pub page_count: u32,
    /// 0-based page the reader is looking at.
    pub current_page: u32,
    pub selection: Option<SelectionRange>,
    pub question: Option<String>,
    pub language: Option<String>,
    pub pages: Vec<PageText>,
    pub settings: ChatSettings,
}

/// One outgoing request. `wire_body` is the exact JSON body; `system_prompt` and `user_prompt`
/// are the strings inside it, duplicated here so the preview never has to re-serialise anything.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChatPart {
    /// 0-based part index.
    pub index: u32,
    pub total: u32,
    pub label: String,
    /// 1-based pages whose text this part sends.
    pub pages: Vec<u32>,
    /// The 1-based page the action was about (the current page or the selection page). For a
    /// document-summary part this is its first page. The mock provider cites this page.
    pub primary_page: u32,
    /// Characters copied from the document into this request.
    pub page_characters: u64,
    /// Characters in the system and user messages.
    pub request_characters: u64,
    pub system_prompt: String,
    pub user_prompt: String,
    pub wire_body: String,
    /// A reader-facing note such as "page text truncated".
    pub note: Option<String>,
}

/// A plan is shown in the panel before anything is sent. It is also the unit the request runner
/// consumes, which is what makes "the preview matches what is sent" checkable.
#[derive(Clone, Debug, PartialEq)]
pub struct ChatPlan {
    pub action: Action,
    pub document_title: String,
    pub page_count: u32,
    pub base_url: String,
    pub endpoint: String,
    pub host: String,
    pub is_local: bool,
    pub model: String,
    pub temperature: Option<f32>,
    pub max_tokens: Option<u32>,
    pub parts: Vec<ChatPart>,
    /// 1-based pages used anywhere in the plan.
    pub source_pages: Vec<u32>,
    /// Long-document or truncation explanation, shown above the preview.
    pub note: Option<String>,
}

impl ChatPlan {
    /// Estimated prompt tokens using the same four-characters-per-token rule as
    /// `AiContext::estimated_tokens`; a hint for the preview, not a billing figure.
    pub fn estimated_tokens(&self) -> u64 {
        let characters: u64 = self.parts.iter().map(|part| part.request_characters).sum();
        characters.div_ceil(4)
    }
}

/// One finished part summary passed to the consolidation request.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MergePart {
    /// 1-based part number, matching the preview.
    pub index: u32,
    pub total: u32,
    /// 1-based pages covered by this part.
    pub pages: Vec<u32>,
    pub summary: String,
}

/// The local input to the consolidation request. It contains no API key and no page text beyond
/// the part summaries the reader has already seen.
#[derive(Clone, Debug, PartialEq)]
pub struct MergePlanRequest {
    pub document_title: String,
    pub settings: ChatSettings,
    pub parts: Vec<MergePart>,
}

/// Build the one extra request that turns part summaries into the single document summary.
/// This is previewed and sent as its own step, never merged silently into the part requests.
pub fn build_merge_plan(request: MergePlanRequest) -> Result<ChatPlan, AiError> {
    if request.parts.is_empty() {
        return Err(empty_context("There are no part summaries to consolidate."));
    }
    let (endpoint, model, temperature, max_tokens, reasoning) =
        validate_settings(&request.settings)?;
    let mut parts = request.parts.clone();
    parts.sort_by_key(|part| part.index);
    let missing: Vec<String> = parts
        .iter()
        .filter(|part| part.summary.trim().is_empty())
        .map(|part| {
            format!(
                "part {} of {} ({})",
                part.index,
                part.total,
                page_label(&part.pages)
            )
        })
        .collect();
    if !missing.is_empty() {
        return Err(empty_context(format!(
            "The consolidation was not sent because {} {} missing. The per-part summaries are kept.",
            missing.join(", "),
            if missing.len() == 1 { "is" } else { "are" }
        )));
    }
    let total = parts
        .iter()
        .map(|part| part.total)
        .max()
        .unwrap_or(parts.len() as u32);
    let mut pages: Vec<u32> = Vec::new();
    let mut user = String::new();
    let mut summary_chars = 0usize;
    for part in &parts {
        pages.extend(part.pages.iter().copied());
        summary_chars += part.summary.chars().count();
        user.push_str(&format!(
            "[Part {} of {} · {}]\n{}\n\n",
            part.index,
            total,
            page_label(&part.pages),
            part.summary.trim()
        ));
    }
    pages.sort_unstable();
    pages.dedup();
    user.push_str(
        "Consolidate the part summaries above into one coherent summary of the whole document. \
         Remove repetition introduced by the part boundaries, keep the main claims, method and \
         result, and do not invent anything absent from the summaries. Cite the pages you use as \
         [p.N].",
    );
    let system = consolidation_system_prompt();
    let label = format!("Consolidated summary · {}", page_label(&pages));
    let page_characters = summary_chars as u64;
    let request_characters = (system.chars().count() + user.chars().count()) as u64;
    let wire_body = make_wire_body(
        &model,
        temperature,
        max_tokens,
        reasoning.as_ref(),
        &system,
        &user,
    );
    let note = Some(format!(
        "This consolidation is a separate request built from {} part summaries. Nothing is sent until you press Send.",
        parts.len()
    ));
    Ok(ChatPlan {
        action: Action::SummarizeDocument,
        document_title: request.document_title,
        page_count: pages.iter().copied().max().unwrap_or(0),
        base_url: endpoint.base_url,
        endpoint: endpoint.endpoint,
        host: endpoint.host,
        is_local: endpoint.is_local,
        model,
        temperature,
        max_tokens,
        parts: vec![ChatPart {
            index: 0,
            total: 1,
            label,
            pages: pages.clone(),
            primary_page: pages.first().copied().unwrap_or(0),
            page_characters,
            request_characters,
            system_prompt: system,
            user_prompt: user,
            wire_body,
            note: note.clone(),
        }],
        source_pages: pages,
        note,
    })
}

fn consolidation_system_prompt() -> String {
    "You are LyraReader, consolidating summaries of one long PDF into a single summary. Use only the part summaries in this request; do not add outside knowledge. Remove repetition caused by the part boundaries, keep the main claims, method and result, and cite pages in the exact form [p.12]. Do not claim to have read pages that are not covered by the part summaries. If the summaries conflict, say so plainly. Be concise.".to_string()
}

/// Inspect and normalise a base URL.
///
/// The rules are intentionally narrow: HTTP(S), no userinfo, no query, no fragment, and no
/// `/chat/completions` suffix. A trailing slash is removed rather than left to produce an
/// endpoint with a double slash.
pub fn inspect_base_url(raw: &str) -> Result<EndpointInfo, AiError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(invalid(
            "Enter a base URL, for example https://api.openai.com/v1.",
        ));
    }
    if trimmed.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err(invalid(
            "The base URL must not contain spaces or control characters.",
        ));
    }

    let lower = trimmed.to_ascii_lowercase();
    let (scheme, rest) = if let Some(rest) = lower.strip_prefix("https://") {
        ("https", &trimmed[trimmed.len() - rest.len()..])
    } else if let Some(rest) = lower.strip_prefix("http://") {
        ("http", &trimmed[trimmed.len() - rest.len()..])
    } else {
        return Err(invalid(
            "The base URL must start with http:// or https:// (for example http://localhost:11434/v1).",
        ));
    };

    if rest.is_empty() || rest.starts_with('/') {
        return Err(invalid(
            "The base URL needs a host, for example https://api.openai.com/v1.",
        ));
    }
    if rest.contains('?') || rest.contains('#') {
        return Err(invalid(
            "The base URL must not contain a query string or a fragment.",
        ));
    }
    if rest.contains('@') {
        return Err(invalid(
            "The base URL must not contain a username or password.",
        ));
    }

    let authority_end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let authority = &rest[..authority_end];
    let mut path = &rest[authority_end..];
    if authority.is_empty() {
        return Err(invalid("The base URL needs a host."));
    }
    if !path.is_empty() && !path.starts_with('/') {
        return Err(invalid("The base URL path must start with /."));
    }
    path = path.trim_end_matches('/');
    if path.to_ascii_lowercase().ends_with("/chat/completions") {
        return Err(invalid(
            "Enter the base URL without /chat/completions; LyraReader appends that endpoint itself.",
        ));
    }

    let (host, port) = split_authority(authority)?;
    if host.is_empty() {
        return Err(invalid("The base URL needs a host."));
    }
    let port_suffix = port.map(|port| format!(":{port}")).unwrap_or_default();
    let normalized_authority = if host.contains(':') {
        // Bracketed IPv6 literal.
        format!("[{host}]{port_suffix}")
    } else {
        format!("{host}{port_suffix}")
    };
    let base_url = format!("{scheme}://{normalized_authority}{path}");
    let endpoint = format!("{base_url}/chat/completions");
    let is_local = is_loopback_host(&host);
    Ok(EndpointInfo {
        base_url,
        endpoint,
        host,
        is_local,
    })
}

/// Validate a model name. Provider names are single tokens; whitespace is almost always a typo
/// and would be sent verbatim.
pub fn validate_model(raw: &str) -> Result<String, AiError> {
    let model = raw.trim();
    if model.is_empty() {
        return Err(invalid(
            "Enter a model name, for example gpt-4o-mini or llama3.2.",
        ));
    }
    if model.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err(invalid(
            "The model name must not contain spaces or control characters.",
        ));
    }
    Ok(model.to_string())
}

type ValidatedSettings = (
    EndpointInfo,
    String,
    Option<f32>,
    Option<u32>,
    Option<ReasoningRequest>,
);

fn validate_settings(settings: &ChatSettings) -> Result<ValidatedSettings, AiError> {
    let endpoint = inspect_base_url(&settings.base_url)?;
    let model = validate_model(&settings.model)?;
    let temperature = match settings.temperature {
        Some(value) if !value.is_finite() || !(0.0..=2.0).contains(&value) => {
            return Err(invalid("Temperature must be between 0 and 2."));
        }
        value => value,
    };
    let max_tokens = match settings.max_tokens {
        Some(0) => return Err(invalid("Max tokens must be at least 1.")),
        Some(value) if value > 32_768 => {
            return Err(invalid("Max tokens must be 32,768 or fewer."));
        }
        value => value,
    };
    let reasoning = reasoning_request(settings.reasoning_mode, settings.reasoning_encoding)?;
    Ok((endpoint, model, temperature, max_tokens, reasoning))
}

fn split_authority(authority: &str) -> Result<(String, Option<u16>), AiError> {
    let (host, port_text) = if let Some(rest) = authority.strip_prefix('[') {
        let Some(close) = rest.find(']') else {
            return Err(invalid(
                "The IPv6 host in the base URL is missing its closing bracket.",
            ));
        };
        let host = &rest[..close];
        let after = &rest[close + 1..];
        let port = if after.is_empty() {
            None
        } else if let Some(port) = after.strip_prefix(':') {
            Some(port)
        } else {
            return Err(invalid(
                "The base URL has characters after the IPv6 address.",
            ));
        };
        (host, port)
    } else if authority.matches(':').count() > 1 {
        return Err(invalid(
            "Bracket IPv6 hosts in the base URL, for example http://[::1]:11434/v1.",
        ));
    } else if let Some((host, port)) = authority.rsplit_once(':') {
        (host, Some(port))
    } else {
        (authority, None)
    };

    if host.is_empty() {
        return Err(invalid("The base URL needs a host."));
    }
    if !host
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_' | ':' | '%'))
    {
        return Err(invalid(
            "The base URL host contains characters that are not allowed.",
        ));
    }
    let port = match port_text {
        None => None,
        Some("") => return Err(invalid("The base URL has an empty port after ':'.")),
        Some(text) => {
            let port: u16 = text
                .parse()
                .map_err(|_| invalid("The base URL port must be a number between 1 and 65535."))?;
            if port == 0 {
                return Err(invalid("The base URL port must be between 1 and 65535."));
            }
            Some(port)
        }
    };
    Ok((host.to_ascii_lowercase(), port))
}

fn is_loopback_host(host: &str) -> bool {
    let host = host.trim_matches(['[', ']']).to_ascii_lowercase();
    if host == "localhost" || host.ends_with(".localhost") || host == "::1" {
        return true;
    }
    host.parse::<Ipv4Addr>()
        .map(|address| address.is_loopback())
        .unwrap_or(false)
}

fn invalid(message: impl Into<String>) -> AiError {
    AiError::InvalidSettings(message.into())
}

fn empty_context(message: impl Into<String>) -> AiError {
    AiError::EmptyContext(message.into())
}

/// Build the request plan. No I/O, no key, no network.
pub fn build_plan(request: PlanRequest) -> Result<ChatPlan, AiError> {
    if request.page_count == 0 {
        return Err(empty_context("This document has no pages."));
    }
    if request.current_page >= request.page_count {
        return Err(empty_context(format!(
            "The current page {} is outside this document.",
            request.current_page + 1
        )));
    }
    let (endpoint, model, temperature, max_tokens, reasoning) =
        validate_settings(&request.settings)?;

    // Keep the raw text layer. Selection ranges are character indices into this exact text;
    // normalising it before slicing shifted every selection that followed whitespace the
    // normaliser removed (line-number gutter, trailing spaces, collapsed blank lines).
    let mut pages: Vec<Option<&PageText>> = vec![None; request.page_count as usize];
    for page in &request.pages {
        if let Some(slot) = pages.get_mut(page.page as usize) {
            *slot = Some(page);
        }
    }

    let mut builder = PlanBuilder {
        request: &request,
        model: &model,
        temperature,
        max_tokens,
        reasoning,
    };

    let (parts, note) = match request.action {
        Action::TranslateSelection => {
            let selection = request.selection.ok_or_else(|| {
                empty_context("Select text first; there is no selection to translate.")
            })?;
            builder.translate(selection, &pages)?
        }
        Action::AskSelection => {
            let selection = request.selection.ok_or_else(|| {
                empty_context("Select text first; there is no selection to ask about.")
            })?;
            builder.ask(selection, &pages)?
        }
        Action::SummarizePage => builder.summarize_page(&pages)?,
        Action::SummarizeDocument => builder.summarize_document(&pages)?,
    };

    let mut source_pages: Vec<u32> = parts
        .iter()
        .flat_map(|part| part.pages.iter().copied())
        .collect();
    source_pages.sort_unstable();
    source_pages.dedup();

    Ok(ChatPlan {
        action: request.action,
        document_title: request.document_title,
        page_count: request.page_count,
        base_url: endpoint.base_url,
        endpoint: endpoint.endpoint,
        host: endpoint.host,
        is_local: endpoint.is_local,
        model,
        temperature,
        max_tokens,
        parts,
        source_pages,
        note,
    })
}

struct PlanBuilder<'a> {
    request: &'a PlanRequest,
    model: &'a str,
    temperature: Option<f32>,
    max_tokens: Option<u32>,
    reasoning: Option<ReasoningRequest>,
}

impl PlanBuilder<'_> {
    fn summarize_page(
        &mut self,
        pages: &[Option<&PageText>],
    ) -> Result<(Vec<ChatPart>, Option<String>), AiError> {
        let page = self.request.current_page;
        let page_data = pages.get(page as usize).and_then(|page| *page);
        let raw_text = page_data.map(|page| page.text.as_str()).unwrap_or("");
        if raw_text.trim().is_empty() {
            return Err(empty_context(format!(
                "Page {} has no text layer, so there is nothing to send. Scanned pages need the image path, which this build does not implement.",
                page + 1
            )));
        }

        // Page context removes a real margin line-number column. Selection text below never
        // goes through this path; it is the raw sequence the canvas uses.
        let text = page_data.map(page_context_text).unwrap_or_default();
        let (page_text, truncated) = truncate_chars(&text, MAX_PAGE_CHARS);
        let blocks = document_blocks(pages);
        let retrieved = retrieve(
            &blocks,
            &text,
            Some(page),
            RETRIEVED_BLOCKS,
            MAX_RETRIEVED_CHARS,
        );
        let context = RetrievalText::render(&retrieved);

        let mut used_pages = vec![page + 1];
        used_pages.extend(retrieved.iter().map(|block| block.page + 1));
        used_pages.sort_unstable();
        used_pages.dedup();

        let mut note = None;
        let mut user = String::new();
        user.push_str(&format!(
            "Summarise page {} of \"{}\".\n\n[Page {}]\n{}\n",
            page + 1,
            self.request.document_title,
            page + 1,
            page_text
        ));
        if truncated {
            user.push_str(&format!(
                "\n[The page text was truncated to {MAX_PAGE_CHARS} characters for this request.]\n"
            ));
            note = Some(format!(
                "Page {} is longer than {MAX_PAGE_CHARS} characters; its text was truncated in the request.",
                page + 1
            ));
        }
        if !context.is_empty() {
            user.push_str("\n[Related context retrieved from elsewhere in the document]\n");
            user.push_str(&context);
        }
        user.push_str(
            "\nReturn a short summary as a few bullet points. Cite each point with [p.N].",
        );

        let system = summary_system_prompt();
        let page_characters = page_text.chars().count() as u64 + context.chars().count() as u64;
        let part = self.make_part(
            0,
            1,
            page_label(&[page + 1]),
            used_pages,
            page + 1,
            page_characters,
            system,
            user,
            note,
        );
        Ok((vec![part], truncated.then(|| {
            format!(
                "Page {} is longer than {MAX_PAGE_CHARS} characters and was truncated for this request.",
                page + 1
            )
        })))
    }

    fn ask(
        &mut self,
        selection: SelectionRange,
        pages: &[Option<&PageText>],
    ) -> Result<(Vec<ChatPart>, Option<String>), AiError> {
        let page = selection.page;
        if page >= self.request.page_count {
            return Err(empty_context("The selected page is outside this document."));
        }
        let page_data = pages.get(page as usize).and_then(|page| *page);
        let raw_text = page_data.map(|page| page.text.as_str()).unwrap_or("");
        if selection.character_count() > MAX_SELECTION_CHARS {
            return Err(empty_context(format!(
                "The selection is {} characters; ask about at most {MAX_SELECTION_CHARS} characters at a time.",
                selection.character_count()
            )));
        }
        // The selection is sliced from the raw text layer with the same character indices the
        // canvas uses. Only the surrounding page context is normalised. An out-of-range range
        // is an error, never a silently clamped or trimmed answer.
        let selected = selection_text(raw_text, selection)?;
        if selected.trim().is_empty() {
            return Err(empty_context(
                "The selection is empty, so there is nothing to ask about.",
            ));
        }
        let question = self
            .request
            .question
            .as_deref()
            .map(str::trim)
            .filter(|question| !question.is_empty())
            .unwrap_or("Explain this passage.");
        let normalized_page = page_data.map(page_context_text).unwrap_or_default();
        let (page_context, page_truncated) = truncate_chars(&normalized_page, MAX_PAGE_CHARS);
        let blocks = document_blocks(pages);
        let query = format!("{selected} {question}");
        let retrieved = retrieve(
            &blocks,
            &query,
            Some(page),
            RETRIEVED_BLOCKS,
            MAX_RETRIEVED_CHARS,
        );
        let context = RetrievalText::render(&retrieved);

        let mut used_pages = vec![page + 1];
        used_pages.extend(retrieved.iter().map(|block| block.page + 1));
        used_pages.sort_unstable();
        used_pages.dedup();

        let mut user = String::new();
        user.push_str(&format!(
            "Answer this question about a selection in \"{}\".\n\nQuestion: {}\n\n[Selected text - page {}]\n{}\n",
            self.request.document_title,
            question,
            page + 1,
            selected
        ));
        if !page_context.trim().is_empty() {
            user.push_str(&format!("\n[Page {}]\n{}\n", page + 1, page_context));
        }
        if page_truncated {
            user.push_str(&format!(
                "\n[The page text was truncated to {MAX_PAGE_CHARS} characters for this request.]\n"
            ));
        }
        if !context.is_empty() {
            user.push_str("\n[Related context retrieved from elsewhere in the document]\n");
            user.push_str(&context);
        }
        user.push_str("\nAnswer in a few short paragraphs. Cite the pages you use as [p.N].");

        let note = page_truncated.then(|| {
            format!(
                "Page {} was truncated to {MAX_PAGE_CHARS} characters in this request.",
                page + 1
            )
        });
        let page_characters = selected.chars().count() as u64
            + page_context.chars().count() as u64
            + context.chars().count() as u64;
        let system = summary_system_prompt();
        let part = self.make_part(
            0,
            1,
            page_label(&[page + 1]),
            used_pages,
            page + 1,
            page_characters,
            system,
            user,
            note.clone(),
        );
        Ok((vec![part], note))
    }

    fn translate(
        &mut self,
        selection: SelectionRange,
        pages: &[Option<&PageText>],
    ) -> Result<(Vec<ChatPart>, Option<String>), AiError> {
        let page = selection.page;
        if page >= self.request.page_count {
            return Err(empty_context("The selected page is outside this document."));
        }
        let page_data = pages.get(page as usize).and_then(|page| *page);
        let page_text = page_data.map(|page| page.text.as_str()).unwrap_or("");
        let selected = if selection.character_count() > MAX_SELECTION_CHARS {
            return Err(empty_context(format!(
                "The selection is {} characters; translate at most {MAX_SELECTION_CHARS} characters at a time.",
                selection.character_count()
            )));
        } else {
            selection_text(page_text, selection)?
        };
        if selected.trim().is_empty() {
            return Err(empty_context(
                "The selection is empty, so there is nothing to translate.",
            ));
        }
        let language = self
            .request
            .language
            .as_deref()
            .map(str::trim)
            .filter(|language| !language.is_empty())
            .unwrap_or("English");
        let system = translate_system_prompt(language);
        let user = format!(
            "Translate the selected passage from \"{}\" into {}.\n\n[Selected text - page {}]\n{}\n",
            self.request.document_title,
            language,
            page + 1,
            selected
        );
        let page_characters = selected.chars().count() as u64;
        let part = self.make_part(
            0,
            1,
            page_label(&[page + 1]),
            vec![page + 1],
            page + 1,
            page_characters,
            system,
            user,
            None,
        );
        Ok((vec![part], None))
    }

    fn summarize_document(
        &mut self,
        pages: &[Option<&PageText>],
    ) -> Result<(Vec<ChatPart>, Option<String>), AiError> {
        let segments = page_segments(pages);
        if segments.is_empty() {
            return Err(empty_context(
                "This document has no text layer that could be summarised. Scanned PDFs are not supported by this build.",
            ));
        }

        let mut groups: Vec<Vec<&Segment>> = Vec::new();
        let mut current: Vec<&Segment> = Vec::new();
        let mut current_chars = 0usize;
        for segment in &segments {
            let label_overhead = format!("[Page {}]\n\n", segment.page + 1).chars().count();
            let size = segment.text.chars().count() + label_overhead;
            if !current.is_empty() && current_chars + size > MAX_PART_CHARS {
                groups.push(std::mem::take(&mut current));
                current_chars = 0;
            }
            current.push(segment);
            current_chars += size;
        }
        if !current.is_empty() {
            groups.push(current);
        }

        let total = groups.len() as u32;
        let mut parts = Vec::with_capacity(groups.len());
        for (index, group) in groups.iter().enumerate() {
            let mut used_pages: Vec<u32> = Vec::new();
            let mut user = String::new();
            let mut page_characters = 0usize;
            for segment in group {
                if !used_pages.contains(&(segment.page + 1)) {
                    used_pages.push(segment.page + 1);
                }
                user.push_str(&format!(
                    "[Page {}]\n{}\n\n",
                    segment.page + 1,
                    segment.text
                ));
                page_characters += segment.text.chars().count();
            }
            // The label names pages only; the shell adds "Part i of n" exactly once. This
            // prevents the live "Part 1 of 9 · Part 1 of 9 · Pages 1-3" duplication.
            let label = page_label(&used_pages);
            let instruction = if total == 1 {
                "Summarise this document. Give 4-8 bullet points covering the main claims, method and result. Cite the pages you use as [p.N].".to_string()
            } else {
                format!(
                    "This is part {} of {} of a long document. Summarise this part with 3-6 bullet points. Do not claim to summarise pages that are not in this part. Cite the pages you use as [p.N].",
                    index + 1,
                    total
                )
            };
            user.push_str(&format!(
                "\nThe document \"{}\" has {} pages. {}",
                self.request.document_title, self.request.page_count, instruction
            ));
            let system = summary_system_prompt();
            let primary_page = used_pages.first().copied().unwrap_or(1);
            parts.push(self.make_part(
                index as u32,
                total,
                label,
                used_pages,
                primary_page,
                page_characters as u64,
                system,
                user,
                None,
            ));
        }

        let note = if total > 1 {
            Some(format!(
                "This document is split into {total} parts of at most {MAX_PART_CHARS} page characters each; each request also carries the system prompt and instructions. After the parts, a separate consolidation request turns them into one summary; it is previewed before it is sent."
            ))
        } else {
            None
        };
        Ok((parts, note))
    }

    #[allow(clippy::too_many_arguments)]
    fn make_part(
        &self,
        index: u32,
        total: u32,
        label: String,
        pages: Vec<u32>,
        primary_page: u32,
        page_characters: u64,
        system_prompt: String,
        user_prompt: String,
        note: Option<String>,
    ) -> ChatPart {
        let request_characters =
            (system_prompt.chars().count() + user_prompt.chars().count()) as u64;
        let wire_body = make_wire_body(
            self.model,
            self.temperature,
            self.max_tokens,
            self.reasoning.as_ref(),
            &system_prompt,
            &user_prompt,
        );
        ChatPart {
            index,
            total,
            label,
            pages,
            primary_page,
            page_characters,
            request_characters,
            system_prompt,
            user_prompt,
            wire_body,
            note,
        }
    }
}

fn make_wire_body(
    model: &str,
    temperature: Option<f32>,
    max_tokens: Option<u32>,
    reasoning: Option<&ReasoningRequest>,
    system_prompt: &str,
    user_prompt: &str,
) -> String {
    let mut object = serde_json::Map::new();
    object.insert("model".to_string(), serde_json::json!(model));
    object.insert(
        "messages".to_string(),
        serde_json::json!([
            { "role": "system", "content": system_prompt },
            { "role": "user", "content": user_prompt },
        ]),
    );
    object.insert("stream".to_string(), serde_json::json!(true));
    if let Some(temperature) = temperature {
        object.insert("temperature".to_string(), serde_json::json!(temperature));
    }
    if let Some(max_tokens) = max_tokens {
        object.insert("max_tokens".to_string(), serde_json::json!(max_tokens));
    }
    if let Some(reasoning) = reasoning {
        object.insert(reasoning.field.to_string(), reasoning.value.clone());
    }
    serde_json::Value::Object(object).to_string()
}

fn summary_system_prompt() -> String {
    "You are LyraReader, a careful reading assistant inside a PDF reader. Use only the document context in this request; do not add outside knowledge. Cite the page for each factual claim with a marker in the exact form [p.12], using the 1-based page numbers in the context's [Page N] headings. Cite only pages that appear in the context. If the context does not contain the answer, say so plainly. Be concise.".to_string()
}

fn translate_system_prompt(language: &str) -> String {
    format!(
        "You are LyraReader's translation assistant inside a PDF reader. Translate the selected passage into {language}. Preserve the meaning, technical terms and paragraph breaks. Do not add commentary, summaries or page citations. Output only the translation."
    )
}

fn retrieval_context_label() -> &'static str {
    "[Retrieved context]"
}

/// The character sequence the page context sends: the raw text with a real margin line-number
/// column removed. The rule is geometric and deliberately narrow:
///
/// * the line consists only of digits (so a numbered list item or a table row, both of which
///   carry other text on the same line, is never a candidate);
/// * at least five such lines share an equal-width, left-aligned column;
/// * their values increase by exactly one down the page;
/// * the column sits left of the body's left edge with a visible gap, and at the page's
///   leftmost text edge.
///
/// Selection text never goes through this function: it is sliced from the raw character
/// sequence using the canvas's indices, so a reader can still select a gutter digit if they
/// really highlight it.
fn page_context_text(page: &PageText) -> String {
    normalize_text(&page_without_margin_numbers(page))
}

fn page_without_margin_numbers(page: &PageText) -> String {
    if page.chars.is_empty() {
        return page.text.clone();
    }
    let glyph_text: String = page
        .chars
        .iter()
        .map(|character| char::from_u32(character.unicode).unwrap_or('\u{FFFD}'))
        .collect();
    if glyph_text != page.text {
        // The boxes and the text disagree; removing characters would corrupt the context.
        return page.text.clone();
    }

    const MIN_GUTTER_LINES: usize = 5;
    const MIN_BODY_GAP_PT: f64 = 10.0;
    const MAX_COLUMN_WIDTH_PT: f64 = 40.0;
    const X_ALIGNMENT_PT: f64 = 1.5;
    const WIDTH_TOLERANCE_PT: f64 = 0.6;

    let is_space = |index: usize| matches!(page.chars[index].unicode, 9 | 10 | 13 | 32);

    // Split the raw sequence into lines, keeping original character indices so the removal is
    // exact. A CRLF pair closes one line (the CR closes it, the LF sees an empty line).
    let mut lines: Vec<Vec<usize>> = Vec::new();
    let mut current: Vec<usize> = Vec::new();
    for (index, character) in page.chars.iter().enumerate() {
        if character.unicode == 10 || character.unicode == 13 {
            if !current.is_empty() {
                lines.push(std::mem::take(&mut current));
            }
        } else {
            current.push(index);
        }
    }
    if !current.is_empty() {
        lines.push(current);
    }

    let first_content_line = lines
        .iter()
        .position(|line| line.iter().any(|&index| !is_space(index)));
    let Some(first_content_line) = first_content_line else {
        return page.text.clone();
    };

    #[derive(Clone)]
    struct GutterLine {
        digits: Vec<usize>,
        value: u64,
        x_min: f64,
        x_max: f64,
    }

    let mut block: Vec<GutterLine> = Vec::new();
    let mut body_x: Option<f64> = None;
    for line in &lines[first_content_line..] {
        let content: Vec<usize> = line.iter().copied().filter(|&i| !is_space(i)).collect();
        if content.is_empty() {
            // Blank lines between the margin block and the body are harmless.
            continue;
        }
        if content
            .iter()
            .all(|&i| (48..=57).contains(&page.chars[i].unicode))
        {
            let widths: Vec<f64> = content.iter().map(|&i| page.chars[i].width_pt).collect();
            let width_min = widths.iter().copied().fold(f64::INFINITY, f64::min);
            let width_max = widths.iter().copied().fold(f64::NEG_INFINITY, f64::max);
            let digits_text: String = content
                .iter()
                .map(|&i| char::from_u32(page.chars[i].unicode).unwrap_or('0'))
                .collect();
            let Ok(value) = digits_text.parse::<u64>() else {
                break;
            };
            if content.len() < 2 || width_max - width_min > WIDTH_TOLERANCE_PT {
                break;
            }
            let first = content[0];
            let last = *content.last().expect("non-empty");
            block.push(GutterLine {
                digits: content,
                value,
                x_min: page.chars[first].x_pt,
                x_max: page.chars[last].x_pt + page.chars[last].width_pt,
            });
        } else {
            body_x = Some(page.chars[content[0]].x_pt);
            break;
        }
    }

    if block.len() < MIN_GUTTER_LINES {
        return page.text.clone();
    }
    let digit_count = block[0].digits.len();
    if !block.iter().all(|line| line.digits.len() == digit_count) {
        return page.text.clone();
    }
    let Some(body_x) = body_x else {
        return page.text.clone();
    };
    let column_x = block[0].x_min;
    let column_width = block[0].x_max - column_x;
    if block.iter().any(|line| {
        (line.x_min - column_x).abs() > X_ALIGNMENT_PT
            || ((line.x_max - line.x_min) - column_width).abs() > WIDTH_TOLERANCE_PT
            || line.x_max + MIN_BODY_GAP_PT > body_x
    }) {
        return page.text.clone();
    }
    if column_width > MAX_COLUMN_WIDTH_PT {
        return page.text.clone();
    }
    let page_min_x = page
        .chars
        .iter()
        .filter(|character| character.width_pt > 0.0)
        .map(|character| character.x_pt)
        .fold(f64::INFINITY, f64::min);
    if column_x > page_min_x + 2.0 {
        return page.text.clone();
    }
    // Values must increase by exactly one down the page.
    if block
        .windows(2)
        .any(|pair| pair[1].value != pair[0].value + 1)
    {
        return page.text.clone();
    }

    let mut remove: std::collections::HashSet<usize> = std::collections::HashSet::new();
    for line in block {
        remove.extend(line.digits);
    }
    page.chars
        .iter()
        .enumerate()
        .filter(|(index, _)| !remove.contains(index))
        .map(|(_, character)| char::from_u32(character.unicode).unwrap_or('\u{FFFD}'))
        .collect()
}

fn normalize_text(text: &str) -> String {
    let mut normalized = String::with_capacity(text.len());
    let mut blank_lines = 0usize;
    for line in text.replace("\r\n", "\n").replace('\r', "\n").split('\n') {
        let line = line.trim_end();
        if line.trim().is_empty() {
            blank_lines += 1;
            if blank_lines > 1 {
                continue;
            }
            normalized.push('\n');
        } else {
            blank_lines = 0;
            normalized.push_str(line);
            normalized.push('\n');
        }
    }
    normalized.trim().to_string()
}

fn truncate_chars(text: &str, limit: usize) -> (String, bool) {
    let count = text.chars().count();
    if count <= limit {
        return (text.to_string(), false);
    }
    let truncated: String = text.chars().take(limit).collect();
    (truncated, true)
}

fn selection_text(page_text: &str, selection: SelectionRange) -> Result<String, AiError> {
    let characters: Vec<char> = page_text.chars().collect();
    let start = selection.start as usize;
    let end = selection.end as usize;
    if start >= characters.len() || end < start || end >= characters.len() {
        return Err(empty_context(
            "The selection does not match the page text anymore; nothing was sent. Select again and retry.",
        ));
    }
    Ok(characters[start..=end].iter().collect())
}

fn page_label(pages: &[u32]) -> String {
    if pages.is_empty() {
        return "No pages".to_string();
    }
    let mut pages = pages.to_vec();
    pages.sort_unstable();
    pages.dedup();
    if pages.len() == 1 {
        return format!("Page {}", pages[0]);
    }
    let first = pages[0];
    let last = pages[pages.len() - 1];
    let contiguous = pages.windows(2).all(|pair| pair[1] == pair[0] + 1);
    if contiguous && last - first == pages.len() as u32 - 1 {
        format!("Pages {first}-{last}")
    } else {
        let list: Vec<String> = pages.iter().map(u32::to_string).collect();
        format!("Pages {}", list.join(", "))
    }
}

// ── Document blocks and retrieval ───────────────────────────────────────────────────────────

#[derive(Clone, Debug)]
struct Segment {
    page: u32,
    text: String,
}

/// One paragraph-sized block used by the local retrieval ranking.
#[derive(Clone, Debug)]
struct Block {
    page: u32,
    text: String,
    terms: Vec<String>,
}

#[derive(Clone, Debug)]
struct Retrieved {
    page: u32,
    text: String,
}

struct RetrievalText;

impl RetrievalText {
    fn render(blocks: &[Retrieved]) -> String {
        if blocks.is_empty() {
            return String::new();
        }
        let mut text = String::new();
        for block in blocks {
            text.push_str(&format!(
                "{} [Page {}]\n{}\n\n",
                retrieval_context_label(),
                block.page + 1,
                block.text
            ));
        }
        text.trim_end().to_string()
    }
}

fn page_segments(pages: &[Option<&PageText>]) -> Vec<Segment> {
    let mut segments = Vec::new();
    for (page, page_text) in pages.iter().enumerate() {
        let Some(page_text) = page_text else {
            continue;
        };
        let text = page_context_text(page_text);
        if text.trim().is_empty() {
            continue;
        }
        for segment in split_text_segments(&text) {
            segments.push(Segment {
                page: page as u32,
                text: segment,
            });
        }
    }
    segments
}

fn split_text_segments(text: &str) -> Vec<String> {
    let mut chunks: Vec<String> = Vec::new();
    for paragraph in text.split('\n') {
        // Each line is kept separate: the PDF text layer already gives logical lines, and
        // grouping them without layout columns would join the two columns of a paper.
        if paragraph.trim().is_empty() {
            continue;
        }
        if paragraph.chars().count() <= MAX_SEGMENT_CHARS {
            chunks.push(paragraph.to_string());
            continue;
        }
        let characters: Vec<char> = paragraph.chars().collect();
        let mut start = 0usize;
        while start < characters.len() {
            let mut end = (start + MAX_SEGMENT_CHARS).min(characters.len());
            while end > start && !characters[end - 1].is_whitespace() {
                end -= 1;
            }
            if end == start {
                end = (start + MAX_SEGMENT_CHARS).min(characters.len());
            }
            chunks.push(characters[start..end].iter().collect());
            start = end;
            while start < characters.len() && characters[start].is_whitespace() {
                start += 1;
            }
        }
    }
    chunks
}

fn document_blocks(pages: &[Option<&PageText>]) -> Vec<Block> {
    let mut blocks = Vec::new();
    for (page, page_text) in pages.iter().enumerate() {
        let Some(page_text) = page_text else {
            continue;
        };
        let text = page_context_text(page_text);
        for paragraph in text.split('\n') {
            let paragraph = paragraph.trim();
            if paragraph.chars().count() < 20 {
                continue;
            }
            for chunk in split_block(paragraph) {
                blocks.push(Block {
                    page: page as u32,
                    terms: tokenize(&chunk),
                    text: chunk,
                });
            }
        }
    }
    blocks
}

fn split_block(paragraph: &str) -> Vec<String> {
    let length = paragraph.chars().count();
    if length <= MAX_BLOCK_CHARS {
        return vec![paragraph.to_string()];
    }
    let characters: Vec<char> = paragraph.chars().collect();
    let mut chunks = Vec::new();
    let mut start = 0usize;
    while start < characters.len() {
        let mut end = (start + MAX_BLOCK_CHARS).min(characters.len());
        while end > start && !characters[end - 1].is_whitespace() {
            end -= 1;
        }
        if end == start {
            end = (start + MAX_BLOCK_CHARS).min(characters.len());
        }
        chunks.push(characters[start..end].iter().collect());
        start = end;
        while start < characters.len() && characters[start].is_whitespace() {
            start += 1;
        }
    }
    chunks
}

fn tokenize(text: &str) -> Vec<String> {
    const STOP_WORDS: &[&str] = &[
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "from", "has", "have", "he",
        "her", "his", "in", "is", "it", "its", "of", "on", "or", "she", "that", "the", "their",
        "them", "then", "there", "these", "they", "this", "to", "was", "were", "with", "which",
        "we", "you", "our", "not", "can", "will", "would", "could", "should", "into", "than",
        "also", "such", "may", "more", "most", "some", "any", "all", "been", "being",
    ];
    let mut tokens = Vec::new();
    let mut current = String::new();
    let flush = |current: &mut String, tokens: &mut Vec<String>| {
        if current.is_empty() {
            return;
        }
        let token = current.to_ascii_lowercase();
        if token.chars().count() >= 2 && !STOP_WORDS.contains(&token.as_str()) {
            // CJK text has no spaces; index its characters as unigrams so a query still finds
            // the paragraph. The whole token is kept too, for mixed-language text.
            let has_cjk = token
                .chars()
                .any(|c| matches!(c as u32, 0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xF900..=0xFAFF));
            if has_cjk {
                tokens.extend(token.chars().map(|c| c.to_string()));
            } else {
                tokens.push(token);
            }
        }
        current.clear();
    };
    for character in text.chars() {
        if character.is_alphanumeric() {
            current.push(character);
        } else {
            flush(&mut current, &mut tokens);
        }
    }
    flush(&mut current, &mut tokens);
    tokens
}

fn retrieve(
    blocks: &[Block],
    query: &str,
    exclude_page: Option<u32>,
    limit: usize,
    character_budget: usize,
) -> Vec<Retrieved> {
    if blocks.is_empty() || limit == 0 || character_budget == 0 {
        return Vec::new();
    }
    let query_terms = tokenize(query);
    if query_terms.is_empty() {
        return Vec::new();
    }
    let total_blocks = blocks.len() as f32;
    let average_length =
        blocks.iter().map(|block| block.terms.len()).sum::<usize>() as f32 / total_blocks;
    if average_length <= 0.0 {
        return Vec::new();
    }
    let mut document_frequency: std::collections::HashMap<&str, usize> =
        std::collections::HashMap::new();
    for block in blocks {
        let unique: HashSet<&str> = block.terms.iter().map(String::as_str).collect();
        for term in unique {
            *document_frequency.entry(term).or_insert(0) += 1;
        }
    }
    let k1 = 1.2f32;
    let b = 0.75f32;
    let mut seen_queries: HashSet<&str> = HashSet::new();
    let query_terms: Vec<&str> = query_terms
        .iter()
        .map(String::as_str)
        .filter(|term| seen_queries.insert(term))
        .collect();

    let mut scored: Vec<(usize, f32)> = Vec::new();
    for (index, block) in blocks.iter().enumerate() {
        if exclude_page == Some(block.page) {
            continue;
        }
        let length = block.terms.len() as f32;
        let mut score = 0.0;
        for term in &query_terms {
            let frequency = block
                .terms
                .iter()
                .filter(|candidate| candidate == term)
                .count() as f32;
            if frequency == 0.0 {
                continue;
            }
            let df = document_frequency.get(term).copied().unwrap_or(0) as f32;
            let idf = ((total_blocks - df + 0.5) / (df + 0.5) + 1.0).ln();
            score += idf * (frequency * (k1 + 1.0))
                / (frequency + k1 * (1.0 - b + b * length / average_length));
        }
        if score > 0.0 {
            scored.push((index, score));
        }
    }
    scored.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

    let mut results = Vec::new();
    let mut used = 0usize;
    for (index, score) in scored {
        let block = &blocks[index];
        let remaining = character_budget.saturating_sub(used);
        if remaining == 0 {
            break;
        }
        let (text, _) = truncate_chars(&block.text, remaining.min(MAX_BLOCK_CHARS));
        if text.is_empty() {
            break;
        }
        used += text.chars().count();
        let _ = score;
        results.push(Retrieved {
            page: block.page,
            text,
        });
        if results.len() >= limit {
            break;
        }
    }
    results
}

#[cfg(test)]
mod tests {
    use super::*;

    fn settings(base_url: &str) -> ChatSettings {
        ChatSettings {
            base_url: base_url.to_string(),
            model: "test-model".to_string(),
            temperature: Some(0.2),
            max_tokens: Some(256),
            reasoning_mode: ReasoningMode::Off,
            reasoning_encoding: ReasoningEncoding::Thinking,
        }
    }

    fn pages(count: u32) -> Vec<PageText> {
        (0..count)
            .map(|page| PageText {
                page,
                text: format!(
                    "Page {} discusses a different subject. Alpha topic {} is explained here with enough detail to be useful.",
                    page + 1,
                    page + 1
                ),

                chars: Vec::new(),})
            .collect()
    }

    #[test]
    fn base_url_is_normalised_and_trailing_slashes_are_removed() {
        let info = inspect_base_url("  http://localhost:11434/v1/// ").unwrap();
        assert_eq!(info.base_url, "http://localhost:11434/v1");
        assert_eq!(info.endpoint, "http://localhost:11434/v1/chat/completions");
        assert!(info.is_local);
        assert_eq!(info.host, "localhost");

        let remote = inspect_base_url("HTTPS://api.openai.com/v1").unwrap();
        assert_eq!(remote.base_url, "https://api.openai.com/v1");
        assert!(!remote.is_local);
    }

    #[test]
    fn base_url_rejects_shapes_that_would_surprise_the_reader() {
        for value in [
            "",
            "api.openai.com/v1",
            "ftp://api.openai.com/v1",
            "https:///v1",
            "https://api.openai.com/v1?x=1",
            "https://api.openai.com/v1#frag",
            "https://user:pass@api.openai.com/v1",
            "https://api.openai.com/v1/chat/completions",
            "http://[::1/v1",
        ] {
            assert!(inspect_base_url(value).is_err(), "accepted {value:?}");
        }
    }

    #[test]
    fn settings_reject_empty_model_and_bad_limits() {
        assert!(validate_model("  ").is_err());
        let mut bad = settings("http://localhost:11434/v1");
        bad.temperature = Some(2.5);
        assert!(validate_settings(&bad).is_err());
        bad.temperature = Some(0.2);
        bad.max_tokens = Some(0);
        assert!(validate_settings(&bad).is_err());
    }

    #[test]
    fn page_plan_carries_page_text_and_builds_a_streaming_body() {
        let request = PlanRequest {
            action: Action::SummarizePage,
            document_title: "A Paper".to_string(),
            page_count: 3,
            current_page: 1,
            selection: None,
            question: None,
            language: None,
            pages: pages(3),
            settings: settings("http://localhost:11434/v1"),
        };
        let plan = build_plan(request).unwrap();
        assert_eq!(plan.parts.len(), 1);
        let part = &plan.parts[0];
        assert_eq!(part.primary_page, 2);
        assert!(part.pages.contains(&2));
        assert!(part.user_prompt.contains("Summarise page 2"));
        assert!(part.user_prompt.contains("[Page 2]"));
        assert!(part.wire_body.contains("\"stream\":true"));
        assert!(part.wire_body.contains("\"model\":\"test-model\""));
        assert!(plan.endpoint.ends_with("/chat/completions"));
        assert!(plan.is_local);
    }

    #[test]
    fn reasoning_settings_send_exactly_one_documented_field() {
        let base = settings("https://api.deepseek.com");
        let plan_for = |mode: ReasoningMode, encoding: ReasoningEncoding| {
            let mut settings = base.clone();
            settings.reasoning_mode = mode;
            settings.reasoning_encoding = encoding;
            build_plan(PlanRequest {
                action: Action::SummarizePage,
                document_title: "Reasoning".to_string(),
                page_count: 1,
                current_page: 0,
                selection: None,
                question: None,
                language: None,
                pages: vec![PageText {
                    page: 0,
                    text: "A page with enough text to build a context block for the request."
                        .to_string(),
                    chars: Vec::new(),
                }],
                settings,
            })
            .unwrap()
            .parts
            .remove(0)
            .wire_body
        };

        let default_body = plan_for(ReasoningMode::Default, ReasoningEncoding::Thinking);
        for field in ["thinking", "reasoning_effort", "output_config", "reasoning"] {
            assert!(
                !default_body.contains(&format!("\"{field}\"")),
                "default mode must send no reasoning field: {default_body}"
            );
        }

        let off_thinking = plan_for(ReasoningMode::Off, ReasoningEncoding::Thinking);
        assert!(off_thinking.contains("\"thinking\":{\"type\":\"disabled\"}"));
        assert!(!off_thinking.contains("reasoning_effort"));
        assert!(!off_thinking.contains("output_config"));

        let high_effort = plan_for(ReasoningMode::High, ReasoningEncoding::ReasoningEffort);
        assert!(high_effort.contains("\"reasoning_effort\":\"high\""));
        assert!(!high_effort.contains("\"thinking\""));
        assert!(!high_effort.contains("\"reasoning\":{\"effort\""));

        let low_output = plan_for(ReasoningMode::Low, ReasoningEncoding::OutputConfig);
        assert!(low_output.contains("\"output_config\":{\"effort\":\"low\"}"));

        let max_reasoning = plan_for(ReasoningMode::Max, ReasoningEncoding::Reasoning);
        assert!(max_reasoning.contains("\"reasoning\":{\"effort\":\"max\"}"));

        let off_reasoning = plan_for(ReasoningMode::Off, ReasoningEncoding::Reasoning);
        assert!(off_reasoning.contains("\"reasoning\":{\"effort\":\"none\"}"));

        for (mode, encoding) in [
            (ReasoningMode::High, ReasoningEncoding::Thinking),
            (ReasoningMode::Off, ReasoningEncoding::ReasoningEffort),
            (ReasoningMode::Off, ReasoningEncoding::OutputConfig),
            (ReasoningMode::Off, ReasoningEncoding::None),
        ] {
            let mut settings = base.clone();
            settings.reasoning_mode = mode;
            settings.reasoning_encoding = encoding;
            let error = build_plan(PlanRequest {
                action: Action::SummarizePage,
                document_title: "Reasoning".to_string(),
                page_count: 1,
                current_page: 0,
                selection: None,
                question: None,
                language: None,
                pages: vec![PageText {
                    page: 0,
                    text: "A page with enough text to build a context block for the request."
                        .to_string(),
                    chars: Vec::new(),
                }],
                settings,
            })
            .unwrap_err();
            assert!(error.to_string().contains("encoding") || error.to_string().contains("toggle"));
        }
    }

    #[test]
    fn document_summary_parts_respect_the_page_character_budget() {
        let page_text = "word ".repeat(4_000);
        let pages: Vec<PageText> = (0..6)
            .map(|page| PageText {
                page,
                text: page_text.clone(),
                chars: Vec::new(),
            })
            .collect();
        let request = PlanRequest {
            action: Action::SummarizeDocument,
            document_title: "Long paper".to_string(),
            page_count: 6,
            current_page: 0,
            selection: None,
            question: None,
            language: None,
            pages,
            settings: settings("http://localhost:11434/v1"),
        };
        let plan = build_plan(request).unwrap();
        assert!(plan.parts.len() > 1, "long pages should be split");
        for part in &plan.parts {
            assert!(
                part.page_characters <= MAX_PART_CHARS as u64,
                "part {} has {} page characters, budget {}",
                part.index,
                part.page_characters,
                MAX_PART_CHARS
            );
        }
        let note = plan.note.unwrap();
        assert!(note.contains("page characters"));
        assert!(note.contains("consolidation"));
        assert!(!note.contains("does not merge"));
    }

    #[test]
    fn consolidation_plan_contains_all_part_summaries_and_cost() {
        let plan = build_merge_plan(MergePlanRequest {
            document_title: "Long paper".to_string(),
            settings: settings("https://api.deepseek.com"),
            parts: vec![
                MergePart {
                    index: 1,
                    total: 3,
                    pages: vec![1, 2],
                    summary: "Part one summary with a claim [p.1].".to_string(),
                },
                MergePart {
                    index: 2,
                    total: 3,
                    pages: vec![3, 4],
                    summary: "Part two summary with the method [p.3].".to_string(),
                },
                MergePart {
                    index: 3,
                    total: 3,
                    pages: vec![5],
                    summary: "Part three summary with the result [p.5].".to_string(),
                },
            ],
        })
        .unwrap();
        assert_eq!(plan.parts.len(), 1, "consolidation is one request");
        let part = &plan.parts[0];
        assert!(part.label.starts_with("Consolidated summary"));
        assert!(part.user_prompt.contains("[Part 1 of 3 · Pages 1-2]"));
        assert!(
            part.user_prompt
                .contains("Part two summary with the method")
        );
        assert!(part.user_prompt.contains("[Part 3 of 3 · Page 5]"));
        assert!(part.wire_body.contains("\"stream\":true"));
        assert!(
            part.wire_body
                .contains("\"thinking\":{\"type\":\"disabled\"}")
        );
        assert_eq!(part.pages, vec![1, 2, 3, 4, 5]);
        assert!(part.page_characters > 0);
        assert!(part.request_characters > part.page_characters);
        assert!(plan.note.unwrap().contains("separate request"));
    }

    #[test]
    fn consolidation_names_missing_parts_instead_of_summarising_the_rest() {
        let error = build_merge_plan(MergePlanRequest {
            document_title: "Long paper".to_string(),
            settings: settings("https://api.deepseek.com"),
            parts: vec![
                MergePart {
                    index: 1,
                    total: 3,
                    pages: vec![1],
                    summary: "Part one [p.1].".to_string(),
                },
                MergePart {
                    index: 2,
                    total: 3,
                    pages: vec![2],
                    summary: String::new(),
                },
                MergePart {
                    index: 3,
                    total: 3,
                    pages: vec![3],
                    summary: "Part three [p.3].".to_string(),
                },
            ],
        })
        .unwrap_err();
        let message = error.to_string();
        assert!(message.contains("part 2 of 3"), "message: {message}");
        assert!(message.contains("Page 2"), "message: {message}");
        assert!(message.contains("missing"), "message: {message}");
        assert!(
            message.contains("per-part summaries are kept"),
            "message: {message}"
        );
    }

    #[test]
    fn retrieval_prefers_the_page_that_mentions_the_query() {
        let mut page_texts = pages(4);
        page_texts[2].text =
            "This page is about spectral clustering with a graph Laplacian and an eigendecomposition."
                .to_string();
        let request = PlanRequest {
            action: Action::SummarizePage,
            document_title: "Retrieval".to_string(),
            page_count: 4,
            current_page: 0,
            selection: None,
            question: None,
            language: None,
            pages: page_texts,
            settings: settings("http://localhost:11434/v1"),
        };
        let plan = build_plan(request).unwrap();
        assert!(plan.parts[0].user_prompt.contains("spectral clustering"));
        assert!(plan.parts[0].pages.contains(&3));
    }

    #[test]
    fn selection_question_includes_the_selection_and_the_page() {
        let request = PlanRequest {
            action: Action::AskSelection,
            document_title: "A Paper".to_string(),
            page_count: 2,
            current_page: 0,
            selection: Some(SelectionRange {
                page: 0,
                start: 0,
                end: 20,
            }),
            question: Some("What does this mean?".to_string()),
            language: None,
            pages: pages(2),
            settings: settings("http://localhost:11434/v1"),
        };
        let plan = build_plan(request).unwrap();
        let part = &plan.parts[0];
        assert!(part.user_prompt.contains("What does this mean?"));
        assert!(part.user_prompt.contains("Selected text - page 1"));
        assert_eq!(part.primary_page, 1);
        assert!(part.pages.contains(&1));
    }

    #[test]
    fn selection_prompt_is_the_exact_raw_character_range() {
        // The numbered margin is a run of real characters at the start of the text layer, and
        // the body lines carry trailing spaces and blank lines. Normalising the page before
        // slicing shifted the range in the live manuscript; this pins the raw-index invariant.
        let raw = "\r\n\r\n000\r\n001\r\n028\r\n029\r\n030\r\n\r\nExisting 3D motion generators face a trade-off between convenient but coarse   \r\ntext-based control and precise but manually specified pose guidance. Moreover,\r\ndiffusion-based methods further incur substantial iterative sampling costs.\r\n\r\n";
        let characters: Vec<char> = raw.chars().collect();
        let char_offset = |byte: usize| raw[..byte].chars().count();
        // Start and end inside words on purpose: the model must receive the partial words the
        // reader selected, not a cleaned-up phrase.
        let start = char_offset(raw.find("motion").unwrap()) + 2;
        let end = char_offset(raw.find("sampling").unwrap()) + 3;
        let expected: String = characters[start..=end].iter().collect();
        assert!(expected.starts_with("tion"));
        assert!(expected.ends_with("samp"));

        let request = PlanRequest {
            action: Action::TranslateSelection,
            document_title: "Numbered margin".to_string(),
            page_count: 1,
            current_page: 0,
            selection: Some(SelectionRange {
                page: 0,
                start: start as u32,
                end: end as u32,
            }),
            question: None,
            language: Some("English".to_string()),
            pages: vec![PageText {
                page: 0,
                text: raw.to_string(),

                chars: Vec::new(),
            }],
            settings: settings("http://localhost:11434/v1"),
        };
        let plan = build_plan(request).unwrap();
        let prompt = &plan.parts[0].user_prompt;
        let marker = "[Selected text - page 1]\n";
        let selected = prompt
            .split_once(marker)
            .map(|(_, rest)| rest.strip_suffix('\n').unwrap_or(rest))
            .expect("the selection marker");
        assert_eq!(
            selected, expected,
            "the prompt must contain the exact raw characters the canvas selected"
        );
        assert!(!selected.contains("028"));
        assert!(!selected.contains("029"));
        assert!(!selected.contains("030"));
    }

    fn push_page_run(
        text: &mut String,
        chars: &mut Vec<PageChar>,
        value: &str,
        x: f64,
        y: f64,
        width: f64,
        height: f64,
    ) {
        for character in value.chars() {
            text.push(character);
            chars.push(PageChar {
                unicode: character as u32,
                x_pt: x,
                y_pt: y,
                width_pt: width,
                height_pt: height,
            });
        }
    }

    fn numbered_margin_page_text() -> PageText {
        let mut text = String::new();
        let mut chars = Vec::new();
        for line in 0..=10 {
            push_page_run(
                &mut text,
                &mut chars,
                &format!("{line:03}"),
                10.0,
                10.0 + line as f64 * 12.0,
                4.0,
                8.0,
            );
            push_page_run(
                &mut text,
                &mut chars,
                "\r\n",
                22.0,
                10.0 + line as f64 * 12.0,
                0.0,
                0.0,
            );
        }
        push_page_run(
            &mut text,
            &mut chars,
            "Existing 3D motion generators face a trade-off between convenient but coarse",
            60.0,
            10.0,
            5.0,
            8.0,
        );
        push_page_run(&mut text, &mut chars, "\r\n", 500.0, 10.0, 0.0, 0.0);
        push_page_run(
            &mut text,
            &mut chars,
            "text-based control and precise but manually specified pose guidance.",
            60.0,
            22.0,
            5.0,
            8.0,
        );
        PageText {
            page: 0,
            text,
            chars,
        }
    }

    #[test]
    fn page_context_removes_a_geometric_margin_run_but_keeps_the_body() {
        let page = numbered_margin_page_text();
        let request = PlanRequest {
            action: Action::SummarizePage,
            document_title: "Numbered margin".to_string(),
            page_count: 1,
            current_page: 0,
            selection: None,
            question: None,
            language: None,
            pages: vec![page],
            settings: settings("http://localhost:11434/v1"),
        };
        let plan = build_plan(request).unwrap();
        let prompt = &plan.parts[0].user_prompt;
        assert!(
            !prompt.contains("000") && !prompt.contains("010"),
            "the margin run is not document text: {prompt}"
        );
        assert!(
            prompt.contains("Existing 3D motion generators face a trade-off"),
            "the abstract survives gutter removal: {prompt}"
        );
        assert!(prompt.contains("pose guidance."));
    }

    #[test]
    fn numbered_lists_and_table_rows_are_not_mistaken_for_a_gutter() {
        let mut text = String::new();
        let mut chars = Vec::new();
        for (line, value) in [
            "1. Introduction",
            "2. Method",
            "3. Results",
            "4. Conclusion",
            "5. References",
            "10  Accuracy  0.93",
            "11  Recall    0.88",
            "12  F1        0.90",
        ]
        .iter()
        .enumerate()
        {
            let y = 10.0 + line as f64 * 12.0;
            push_page_run(&mut text, &mut chars, value, 10.0, y, 5.0, 8.0);
            push_page_run(&mut text, &mut chars, "\r\n", 90.0, y, 0.0, 0.0);
        }
        let page = PageText {
            page: 0,
            text,
            chars,
        };
        let request = PlanRequest {
            action: Action::SummarizePage,
            document_title: "Lists".to_string(),
            page_count: 1,
            current_page: 0,
            selection: None,
            question: None,
            language: None,
            pages: vec![page],
            settings: settings("http://localhost:11434/v1"),
        };
        let plan = build_plan(request).unwrap();
        let prompt = &plan.parts[0].user_prompt;
        for expected in ["1. Introduction", "2. Method", "10  Accuracy", "12  F1"] {
            assert!(prompt.contains(expected), "missing {expected}: {prompt}");
        }
    }

    #[test]
    fn a_selection_inside_a_gutter_page_is_still_raw_text() {
        let page = numbered_margin_page_text();
        let characters: Vec<char> = page.text.chars().collect();
        let start = page.text.find("motion").unwrap();
        let start = page.text[..start].chars().count() + 2;
        let end = page.text.find("pose guidance").unwrap();
        let end = page.text[..end].chars().count() + "pose guidance".chars().count() - 1;
        let expected: String = characters[start..=end].iter().collect();
        let request = PlanRequest {
            action: Action::TranslateSelection,
            document_title: "Numbered margin".to_string(),
            page_count: 1,
            current_page: 0,
            selection: Some(SelectionRange {
                page: 0,
                start: start as u32,
                end: end as u32,
            }),
            question: None,
            language: Some("English".to_string()),
            pages: vec![page],
            settings: settings("http://localhost:11434/v1"),
        };
        let plan = build_plan(request).unwrap();
        let prompt = &plan.parts[0].user_prompt;
        let marker = "[Selected text - page 1]\n";
        let selected = prompt
            .split_once(marker)
            .map(|(_, rest)| rest.strip_suffix('\n').unwrap_or(rest))
            .expect("selection marker");
        assert_eq!(selected, expected);
        assert!(!selected.contains("000"));
    }

    #[test]
    fn an_out_of_range_selection_is_refused_not_clamped() {
        let request = PlanRequest {
            action: Action::TranslateSelection,
            document_title: "Bounds".to_string(),
            page_count: 1,
            current_page: 0,
            selection: Some(SelectionRange {
                page: 0,
                start: 7,
                end: 9,
            }),
            question: None,
            language: Some("English".to_string()),
            pages: vec![PageText {
                page: 0,
                text: "short".to_string(),

                chars: Vec::new(),
            }],
            settings: settings("http://localhost:11434/v1"),
        };
        let error = build_plan(request).unwrap_err();
        assert!(error.to_string().contains("does not match the page text"));
    }

    #[test]
    fn translation_refuses_a_selection_that_would_be_truncated() {
        let long = "word ".repeat(MAX_SELECTION_CHARS);
        let request = PlanRequest {
            action: Action::TranslateSelection,
            document_title: "A Paper".to_string(),
            page_count: 1,
            current_page: 0,
            selection: Some(SelectionRange {
                page: 0,
                start: 0,
                end: (long.chars().count() - 1) as u32,
            }),
            question: None,
            language: Some("English".to_string()),
            pages: vec![PageText {
                page: 0,
                text: long,

                chars: Vec::new(),
            }],
            settings: settings("http://localhost:11434/v1"),
        };
        let error = build_plan(request).unwrap_err();
        assert!(format!("{error}").contains("translate at most"));
    }

    #[test]
    fn long_document_is_split_and_the_plan_says_so() {
        let mut page_texts = Vec::new();
        for page in 0..8u32 {
            page_texts.push(PageText {
                page,
                text: format!(
                    "{}. ",
                    "This page has a long explanation of the method. ".repeat(40)
                ),

                chars: Vec::new(),
            });
        }
        let request = PlanRequest {
            action: Action::SummarizeDocument,
            document_title: "Long".to_string(),
            page_count: 8,
            current_page: 0,
            selection: None,
            question: None,
            language: None,
            pages: page_texts,
            settings: settings("http://localhost:11434/v1"),
        };
        let plan = build_plan(request).unwrap();
        assert!(
            plan.parts.len() > 1,
            "expected parts, got {}",
            plan.parts.len()
        );
        assert!(plan.note.as_deref().unwrap().contains("consolidation"));
        for part in &plan.parts {
            assert!(
                !part.label.contains("Part "),
                "the shell adds the part number exactly once: {}",
                part.label
            );
            assert!(part.label.starts_with("Page"));
        }
        assert_eq!(
            plan.parts.iter().map(|part| part.index).collect::<Vec<_>>(),
            (0..plan.parts.len() as u32).collect::<Vec<_>>()
        );
        for part in &plan.parts {
            assert!(part.request_characters > 0);
            assert!(part.wire_body.contains("stream"));
        }
    }

    #[test]
    fn action_labels_are_stable_for_the_preview() {
        assert_eq!(Action::SummarizePage.label(), "Summarise this page");
    }
}
