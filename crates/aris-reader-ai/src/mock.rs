//! A deterministic provider used by the regression checks and by the panel's mock mode.
//!
//! It returns preset strings, not model output. It never opens a socket and never reads an API
//! key, which is what lets every UI check run without a network.

use std::time::Duration;

use crate::chat::ChatPlan;
use crate::openai::{CancellationToken, RunEvent, TokenUsage};
use crate::provider::AiError;

/// The preset answer. `{page}` is replaced with the first page of the part being "answered" so
/// the citation in the mock text is one the panel can actually jump to.
const PRESET_CHUNKS: &[&str] = &[
    "This page explains the method in three steps. ",
    "It first builds a local index, then ranks the document blocks, ",
    "and finally streams an answer back to the reader [p.{page}].\n\n",
    "Key points:\n- Retrieval runs on this machine.\n- Nothing is sent before the reader confirms the preview.",
];

/// Deterministic mock provider.
#[derive(Clone, Debug)]
pub struct MockProvider {
    pub chunks: Vec<String>,
    pub delay: Duration,
    pub usage: TokenUsage,
}

impl Default for MockProvider {
    fn default() -> Self {
        Self::preset()
    }
}

impl MockProvider {
    pub fn preset() -> Self {
        Self {
            chunks: PRESET_CHUNKS
                .iter()
                .map(|chunk| chunk.to_string())
                .collect(),
            delay: Duration::from_millis(80),
            usage: TokenUsage {
                prompt_tokens: Some(123),
                completion_tokens: Some(45),
                total_tokens: Some(168),
            },
        }
    }

    pub fn with_chunks(chunks: Vec<String>) -> Self {
        Self {
            chunks,
            ..Self::preset()
        }
    }

    /// Stream the preset answer for every part. The cancellation token is checked between
    /// chunks, so a panel test can prove Cancel stops the stream rather than merely hiding it.
    pub fn run(
        &self,
        plan: &ChatPlan,
        cancel: &CancellationToken,
        emit: &mut dyn FnMut(RunEvent),
    ) -> Result<(), AiError> {
        for part in &plan.parts {
            cancel.check()?;
            emit(RunEvent::PartStarted {
                index: part.index,
                total: part.total,
                label: part.label.clone(),
            });
            let page = part.primary_page;
            for chunk in &self.chunks {
                std::thread::sleep(self.delay.min(Duration::from_millis(250)));
                cancel.check()?;
                emit(RunEvent::Delta(chunk.replace("{page}", &page.to_string())));
            }
            emit(RunEvent::Usage(self.usage));
        }
        cancel.check()?;
        emit(RunEvent::Done);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::chat::{Action, ChatSettings, PageText, PlanRequest, build_plan};

    fn plan() -> ChatPlan {
        build_plan(PlanRequest {
            action: Action::SummarizePage,
            document_title: "Mock".to_string(),
            page_count: 2,
            current_page: 1,
            selection: None,
            question: None,
            language: None,
            pages: vec![
                PageText {
                    page: 0,
                    text: "Page one has text about retrieval.".to_string(),
                },
                PageText {
                    page: 1,
                    text: "Page two has the method described in enough detail for a summary."
                        .to_string(),
                },
            ],
            settings: ChatSettings {
                base_url: "http://127.0.0.1:1/v1".to_string(),
                model: "mock".to_string(),
                temperature: None,
                max_tokens: None,
            },
        })
        .unwrap()
    }

    #[test]
    fn preset_answer_mentions_the_planned_page_and_reports_usage() {
        let plan = plan();
        let cancel = CancellationToken::new();
        let provider = MockProvider::with_chunks(vec!["A summary [p.{page}].".to_string()]);
        let mut text = String::new();
        let mut done = false;
        provider
            .run(&plan, &cancel, &mut |event| match event {
                RunEvent::Delta(delta) => text.push_str(&delta),
                RunEvent::Done => done = true,
                _ => {}
            })
            .unwrap();
        assert_eq!(text, "A summary [p.2].");
        assert!(done);
    }

    #[test]
    fn cancellation_stops_the_preset_stream() {
        let plan = plan();
        let cancel = CancellationToken::new();
        let provider = MockProvider {
            chunks: vec!["one".to_string(), "two".to_string(), "three".to_string()],
            delay: Duration::from_millis(50),
            usage: TokenUsage::default(),
        };
        let mut seen = 0;
        let error = provider
            .run(&plan, &cancel, &mut |event| {
                if matches!(event, RunEvent::Delta(_)) {
                    seen += 1;
                    if seen == 1 {
                        cancel.cancel();
                    }
                }
            })
            .unwrap_err();
        assert_eq!(error, AiError::Cancelled);
        assert_eq!(seen, 1);
    }
}
