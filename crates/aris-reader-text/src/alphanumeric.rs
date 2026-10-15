//! Explicit alphabetic bibliography keys, e.g. `[HR18]` and `[VSP+ 17]`.
//! Recognition is gated by a bibliography using this style; arbitrary bracketed codes in
//! numeric/author-year documents do not become citations. Unknown well-formed keys remain
//! visible as unresolved citations rather than being filtered out of evaluation.
use crate::{Citation, ReferenceEntry, looks_like_reference_heading, union_boxes};
use aris_reader_core::RawTextPage;

/// BibTeX alpha-style key: letters, optional `+`, two year digits, optional lowercase suffix.
/// Whitespace is allowed around the key and between `+` and the year (PDF extraction), not
/// inside author initials or year digits. This intentionally excludes `[S3]` and `[A.1]`.
pub(crate) fn label(value: &str) -> Option<String> {
    let value = value.trim();
    let n = value.bytes().take_while(u8::is_ascii_alphabetic).count();
    if !(1..=12).contains(&n) {
        return None;
    }
    let stem = &value[..n];
    let rest = &value[n..];
    let (plus, rest) = match rest.strip_prefix('+') {
        Some(tail) => ("+", tail.trim_start()),
        None => ("", rest),
    };
    let bytes = rest.as_bytes();
    if !(bytes.len() == 2 || (bytes.len() == 3 && bytes[2].is_ascii_lowercase()))
        || !bytes[0].is_ascii_digit()
        || !bytes[1].is_ascii_digit()
    {
        return None;
    }
    Some(format!("{stem}{plus}{rest}"))
}

pub(crate) fn references(page: u32, text: &RawTextPage) -> Vec<ReferenceEntry> {
    let chars: Vec<_> = text
        .chars
        .iter()
        .map(|c| char::from_u32(c.unicode).unwrap_or(char::REPLACEMENT_CHARACTER))
        .collect();
    let mut markers = Vec::new();
    let mut offset = 0;
    for line in chars.split_inclusive(|c| *c == '\n') {
        let mut start = offset;
        offset += line.len();
        while start < offset && chars[start].is_whitespace() {
            start += 1;
        }
        let line_text: String = chars[start..offset].iter().collect();
        if looks_like_reference_heading(&line_text) {
            markers.clear();
            while start < offset && chars[start] != '[' {
                start += 1;
            }
        }
        if chars.get(start) != Some(&'[') {
            continue;
        }
        let Some(close) = (start + 1..offset).find(|i| chars[*i] == ']') else {
            continue;
        };
        if close - start > 24 || !chars.get(close + 1).is_some_and(|c| c.is_whitespace()) {
            continue;
        }
        let inner: String = chars[start + 1..close].iter().collect();
        if let Some(key) = label(&inner) {
            markers.push((start, close + 1, key));
        }
    }
    markers
        .iter()
        .enumerate()
        .map(|(i, (start, body, key))| {
            let end = markers.get(i + 1).map_or(chars.len(), |m| m.0);
            ReferenceEntry {
                label: key.clone(),
                text: chars[*body..end]
                    .iter()
                    .collect::<String>()
                    .trim()
                    .to_string(),
                page,
                start: *start,
                end,
                fragments: Vec::new(),
            }
        })
        .collect()
}

pub(crate) fn citations(text: &RawTextPage) -> Vec<Citation> {
    let chars: Vec<_> = text
        .chars
        .iter()
        .map(|c| char::from_u32(c.unicode).unwrap_or(char::REPLACEMENT_CHARACTER))
        .collect();
    let mut found = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        if chars[i] != '[' {
            i += 1;
            continue;
        }
        let mut end = i + 1;
        while end < chars.len() && end - i <= 120 && !matches!(chars[end], '[' | ']') {
            end += 1;
        }
        if chars.get(end) == Some(&']') && end - i <= 120 {
            let inner: String = chars[i + 1..end].iter().collect();
            let labels: Option<Vec<_>> = inner.split([',', ';']).map(label).collect();
            if let Some(labels) = labels {
                found.push(Citation {
                    text: chars[i..=end].iter().collect(),
                    labels,
                    rect: union_boxes(&text.chars[i..=end]),
                    start: i,
                    end: end + 1,
                });
                i = end + 1;
                continue;
            }
        }
        i += 1;
    }
    found
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        CitationStyle, find_citations_with, find_references, resolve_references, test_page,
    };

    #[test]
    fn grouped_keys_preserve_ranges_and_resolve_every_entry() {
        let mut bib = test_page(
            "References\n[HR18] Hart and Reed. Work, 2018.\n[MCCD13] Miller et al. Work, 2013.\n[PSM14] Patel et al. Work, 2014.\n[VSP+ 17] Vaswani et al. Work, 2017.\n",
        );
        bib.page = aris_reader_core::PageIndex(1);
        let pages = vec![(1, bib)];
        let refs = find_references(pages.iter().map(|(p, t)| (*p, t)), 100);
        assert_eq!(refs.len(), 4);
        let style = CitationStyle::for_document(&pages, &refs);
        let body = test_page("é [HR18] and [MCCD13, PSM14; VSP+\n17], unknown [XYZ99].");
        let spans = find_citations_with(&body, &style);
        assert_eq!(spans.len(), 3);
        assert_eq!(spans[1].labels, ["MCCD13", "PSM14", "VSP+17"]);
        assert_eq!(resolve_references(&spans[1].labels, &refs).len(), 3);
        assert!(resolve_references(&spans[2].labels, &refs).is_empty());
        assert!(resolve_references(&["1".into()], &refs).is_empty());
        for span in &spans {
            assert_eq!(
                body.text
                    .chars()
                    .skip(span.start)
                    .take(span.end - span.start)
                    .collect::<String>(),
                span.text
            );
        }
        assert!(find_citations_with(&body, &CitationStyle::numeric_only()).is_empty());
    }

    #[test]
    fn keys_reject_codes_formulas_and_broken_groups() {
        for key in [
            "S3", "A.1", "H2O", "12", "HR2018", "HR 18", "HR1 8", "HR++18", "", "é18",
        ] {
            assert!(label(key).is_none(), "{key}");
        }
        assert_eq!(label("VSP+ 17a"), Some("VSP+17a".into()));
        let page = test_page("[HR18,] [HR18, H2O] [HR18-PSM14] [S3] [A.1]");
        assert!(citations(&page).is_empty());
    }

    #[test]
    fn heading_inline_and_cross_page_entries_remain_a_single_run() {
        let a = test_page("References [AB18] Adams. First, 2018.\n[CD19] Chen. Second, 2019.\n");
        let b = test_page("[EF20] Evans. Third, 2020.\n");
        let refs = find_references([(4, &a), (5, &b)], 10);
        assert_eq!(
            refs.iter().map(|r| r.label.as_str()).collect::<Vec<_>>(),
            ["AB18", "CD19", "EF20"]
        );
        assert_eq!(crate::entry_label("[VSP+ 17] Authors"), "VSP+17");
    }
}
