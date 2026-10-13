//! Select a coherent bibliography, independently of citation matching.
//!
//! Keep numeric and author-year candidates separate until the document-level
//! decision. A spurious numeric marker must not suppress an author-year page,
//! and candidates in different styles must not join into a run through the body.

use super::*;

#[derive(Default)]
struct Run {
    entries: Vec<ReferenceEntry>,
    last_page: Option<u32>,
    headed: bool,
}

impl Run {
    fn score(&self) -> f64 {
        if self.entries.len() < 2 {
            return 0.0;
        }
        let dated = self
            .entries
            .iter()
            .filter(|e| first_year(&e.text).is_some())
            .count();
        // Numbered paragraphs alone are not bibliographic evidence. A heading
        // admits short/undated entries, otherwise require publication years.
        if !self.headed && dated * 2 < self.entries.len() {
            return 0.0;
        }
        let ordered = self
            .entries
            .windows(2)
            .filter(
                |pair| match (pair[0].label.parse::<u32>(), pair[1].label.parse::<u32>()) {
                    (Ok(a), Ok(b)) => a.checked_add(1) == Some(b),
                    _ => pair[0].label.to_lowercase() <= pair[1].label.to_lowercase(),
                },
            )
            .count();
        self.entries.len() as f64
            + dated as f64
            + ordered as f64
            + if self.headed { 8.0 } else { 0.0 }
    }

    fn finish(&mut self, best: &mut Run) {
        if self.score() > best.score() {
            *best = std::mem::take(self);
        } else {
            *self = Self::default();
        }
    }
}

pub(super) fn select_reference_run<'a>(
    pages: impl IntoIterator<Item = (u32, &'a RawTextPage)>,
    max_entries: usize,
) -> Vec<ReferenceEntry> {
    if max_entries == 0 {
        return Vec::new();
    }
    let mut numeric = Run::default();
    let mut author_year = Run::default();
    let mut best = Run::default();
    for (page, text) in pages {
        // Work in character offsets, matching RawTextPage and the preview ABI.
        let mut offset = 0;
        let heading = text
            .chars
            .split_inclusive(|c| c.unicode == '\n' as u32)
            .find_map(|line| {
                let start = offset;
                offset += line.len();
                let line: String = line
                    .iter()
                    .filter_map(|c| char::from_u32(c.unicode))
                    .collect();
                looks_like_reference_heading(&line).then_some(start)
            });
        for (run, mut entries, numbered) in [
            (&mut numeric, parse_numeric_references(page, text), true),
            (
                &mut author_year,
                parse_author_year_references(page, text),
                false,
            ),
        ] {
            if let Some(start) = heading {
                entries.retain(|entry| entry.start >= start);
            }
            let consecutive_page = run
                .last_page
                .is_some_and(|p| p.checked_add(1) == Some(page));
            let consecutive_label = !numbered
                || run
                    .entries
                    .last()
                    .zip(entries.first())
                    .is_some_and(|(a, b)| {
                        a.label.parse::<u32>().ok().and_then(|n| n.checked_add(1))
                            == b.label.parse::<u32>().ok()
                    });
            // Theses often repeat "Bibliography" as a running page header.
            // Continue an established, coherent list through those headers.
            if !consecutive_page || !consecutive_label || (heading.is_some() && !run.headed) {
                run.finish(&mut best);
            }
            // An isolated author-like line in prose must not bridge two runs.
            let viable = entries.len() >= 2 || (!run.entries.is_empty() && entries.len() == 1);
            if !viable {
                run.finish(&mut best);
                continue;
            }
            run.headed |= heading.is_some();
            run.last_page = Some(page);
            run.entries.extend(entries);
        }
    }
    numeric.finish(&mut best);
    author_year.finish(&mut best);
    best.entries.truncate(max_entries);
    best.entries
}
