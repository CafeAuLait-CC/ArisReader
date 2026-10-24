//! AI and advanced reading support layer.
//!
//! **Important**: the citation/figure index ([`citation`]) **does not depend on any LLM** — it is pure
//! PDF structure + text layout analysis and ships in M4; [`provider`] only layers chat and generation
//! capabilities on top in M5.
//!
//! See `docs/06-ai.md` for details.

pub mod chat;
pub mod citation;
pub mod mock;
pub mod openai;
pub mod provider;

pub use chat::{
    Action, CHAT_RETRIEVED_BLOCKS, ChatImage, ChatPart, ChatPlan, ChatSettings, ChatSource,
    ConversationTurn, DocumentChatRequest, EndpointInfo, MAX_CHAT_CONTEXT_CHARS,
    MAX_CHAT_HISTORY_CHARS, MAX_CHAT_HISTORY_TURNS, MAX_REGION_IMAGE_BYTES,
    MAX_REGION_QUESTION_CHARS, MAX_REGION_TEXT_CHARS, NOTHING_RELEVANT_MESSAGE,
    PROMPT_SYSTEM_PROMPT, PageText, PlanRequest, PromptPlanRequest, RegionQuestionRequest,
    RegionRect, SUMMARY_ABSTRACT_MAX_CHARS, SUMMARY_ABSTRACT_MAX_PAGES,
    SUMMARY_MAX_CONCURRENT_REQUESTS, SUMMARY_MAX_REQUESTS_PER_BATCH, SUMMARY_PAGE_MAX_CHARS,
    SUMMARY_SECTION_MAX_CHARS, SelectionRange, SourceRect, SummaryCoverage, SummaryLayer,
    SummaryLayerPlan, SummaryLayerRequest, SummaryUnitPlan, SummaryUnitRequest,
    build_document_chat_plan, build_document_knowledge_plan, build_prompt_plan,
    build_region_question_plan, build_summary_layer, inspect_base_url, inspect_summary_layer,
    validate_model,
};
pub use citation::{CitationIndex, CitationKind, FigureEntry, RefEntry, ResolvedCitation};
pub use mock::MockProvider;
pub use openai::{
    CancellationToken, ClientConfig, RequestSpec, ResponseStream, RunEvent, SseDecoder, SseFrame,
    StreamPayload, TokenUsage, Transport, UreqTransport, build_request_spec, default_transport,
    preview_headers, redact, redact_error, run_plan, run_plan_with_transport,
};
pub use provider::{
    AiError, AiFailure, Capabilities, ChatMessage, ChatRequest, LlmProvider, Role, StreamSink,
};

/// Image reference (a screenshot of the marquee-selected region; supplied by the render layer, M5).
#[derive(Clone, Debug, PartialEq)]
pub struct ImageRef {
    pub width_px: u32,
    pub height_px: u32,
    /// PNG/JPEG-encoded bytes (for passing across the FFI).
    pub encoded: Vec<u8>,
}

/// One retrieved context snippet (**must carry the page number and rect** so answers can be linked back and highlighted).
#[derive(Clone, Debug, PartialEq)]
pub struct Snippet {
    pub page: lyra_reader_core::PageIndex,
    pub rect: lyra_reader_core::Rect,
    pub text: String,
    pub score: f32,
}

/// Context of a single AI request.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct AiContext {
    pub doc_title: Option<String>,
    pub page_range: Option<(u32, u32)>,
    pub selection_text: Option<String>,
    /// Screenshot of the marquee-selected region (the vision model path).
    pub region_image: Option<ImageRef>,
    /// Retrieved relevant snippets.
    pub snippets: Vec<Snippet>,
    /// Citations the user has opened (used as extra context).
    pub citations: Vec<ResolvedCitation>,
}

impl AiContext {
    /// Rough token estimate (4 characters ≈ 1 token); used for cost hints and truncation decisions.
    pub fn estimated_tokens(&self) -> usize {
        let mut chars = self
            .selection_text
            .as_ref()
            .map_or(0, |s| s.chars().count());
        for s in &self.snippets {
            chars += s.text.chars().count();
        }
        for c in &self.citations {
            chars += c.text.chars().count();
        }
        chars / 4 + 64
    }
}

/// Long-document strategy (`docs/06-ai.md` §4.2).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LongDocStrategy {
    /// Chunked summarization followed by a merge (whole-document summary).
    MapReduce,
    /// Retrieval-augmented (chat/Q&A).
    RetrieveThenRead,
}
