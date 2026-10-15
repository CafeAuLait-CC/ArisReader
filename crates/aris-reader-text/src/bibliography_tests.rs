use super::*;
use std::collections::BTreeMap;

fn references(text: &str) -> Vec<ReferenceEntry> {
    find_references([(0, &test_page(text))], 100)
}

#[test]
fn numeric_noise_does_not_mask_a_mid_page_author_year_list() {
    let body = test_page("[1] First instruction.\n[2] Second instruction.\n");
    let list = test_page(
        "[3] A body citation.\nReferences\nHe, T.; Guo, J.;\nTan, X.; Wang, C. 2024. GAIA.\nMa, Y.; Wang, S. 2023a. TalkCLIP.\nMa, Y.; Wang, S. 2023b. Styletalk.\n",
    );
    let entries = find_references([(0, &body), (1, &body), (2, &list)], 100);
    assert_eq!(
        entries.iter().map(|e| e.label.as_str()).collect::<Vec<_>>(),
        ["He 2024", "Ma 2023a", "Ma 2023b"]
    );
    assert!(entries.iter().all(|e| e.page == 2));
    assert!(entries[0].text.contains("Tan, X."));
    assert!(entries[0].text.ends_with("GAIA."));
}

#[test]
fn styles_and_missing_pages_do_not_join_into_one_candidate_run() {
    let numeric = test_page("References\n[1] One 2020.\n[2] Two 2021.\n");
    let authors = test_page("References\nHe, T. 2024. A.\nMa, Y. 2023. B.\nWu, X. 2022. C.\n");
    let entries = find_references([(0, &numeric), (1, &authors)], 100);
    assert_eq!(entries.len(), 3);
    assert!(entries.iter().all(|e| e.page == 1));
    let continuation = test_page("[3] Three 2022.\n[4] Four 2023.\n");
    let entries = find_references([(0, &numeric), (2, &continuation)], 100);
    assert_eq!(entries.len(), 2);
    assert!(entries.iter().all(|e| e.page == 0));
}

#[test]
fn numbered_prose_and_bracketed_years_are_not_a_bibliography() {
    assert!(references("[1978] We describe muscles here.\n").is_empty());
    assert!(
        references("1. First instruction.\n2. Second instruction.\n3. Third instruction.\n")
            .is_empty()
    );
}

#[test]
fn repeated_bibliography_headers_preserve_the_whole_numbered_list() {
    let first = test_page("Bibliography\n[1] One 2020.\n[2] Two 2021.\n");
    let next = test_page("Bibliography\n[3] Three 2022.\n[4] Four 2023.\n");
    let entries = find_references([(0, &first), (1, &next)], 100);
    assert_eq!(entries.len(), 4);
    let noise = test_page("[8] A body mention.\nReferences\n[1] One 2020.\n[2] Two 2021.\n");
    assert_eq!(find_references([(0, &noise)], 100).len(), 2);
}

#[test]
fn numeric_boundaries_handle_indentation_heading_and_wrapped_years() {
    let entries = references(
        "References [12] First author.\n2024. More title.\n  [13] Second author. 2020.\n  [14] Third author. 2021.\n",
    );
    assert_eq!(
        entries.iter().map(|e| e.label.as_str()).collect::<Vec<_>>(),
        ["12", "13", "14"]
    );
    assert!(entries[0].text.contains("More title."));
    assert!(!entries[0].text.contains("Second author"));
}

#[test]
fn a_doi_at_the_top_of_a_continuation_page_cannot_hide_its_entries() {
    let entries = references(
        "Bibliography\n10.18653/v1/2024.naacl-long.274.\n[103] Author. 2025. Title.\n[104] Author. 2026. Title.\n",
    );
    assert_eq!(
        entries.iter().map(|e| e.label.as_str()).collect::<Vec<_>>(),
        ["103", "104"]
    );
}

#[test]
fn full_names_work_without_promoting_title_lines_to_authors() {
    let entries = references(
        "References\nYunfei Bai, Danny M Kaufman,\nKaren Liu. 2016. Artist-directed dynamics.\nAccessible Animation and Customizable Graphics.\nRonen Barzel and Alan Barr. 1988. A modeling system.\nErin Catto. 2007. Box2d.\n",
    );
    assert_eq!(
        entries.iter().map(|e| e.label.as_str()).collect::<Vec<_>>(),
        ["Bai 2016", "Barzel 1988", "Catto 2007"]
    );
    assert!(entries[0].text.contains("Accessible Animation"));
    assert_eq!(
        entry_label("Yunfei Bai, Danny Kaufman. 2016. Title."),
        "Bai 2016"
    );
}

#[test]
fn capitalized_titles_do_not_swallow_the_following_entry() {
    let entries = references(
        "References\nFeng, G. 2024. Emotion control.\nFine-grained Emotion-Controlled Talking Face Generation.\nGan, Y. 2023. Emotional adaptation.\nHe, T.; Guo, J.;\nTan, X. 2024. Zero-shot\nTalking Avatar Generation. ICLR.\nHeusel, M. 2017. Training.\n",
    );
    assert_eq!(entries.len(), 4);
    assert_eq!(entries[1].label, "Gan 2023");
    assert!(
        entries[2]
            .text
            .ends_with("Talking Avatar Generation. ICLR.")
    );
    assert!(entries[3].text.starts_with("Heusel,"));
}

#[test]
fn publication_year_is_not_an_arxiv_identifier_or_a_long_number() {
    assert_eq!(first_year("arXiv:2006.10204, 2020."), Some("2020".into()));
    assert_eq!(first_year("120231 / 2023b."), Some("2023b".into()));
    assert_eq!(first_year("2023a"), Some("2023a".into()));
}

#[test]
fn year_suffixes_resolve_to_distinct_works_and_ambiguity_abstains() {
    let entries = references(
        "References\nMa, Y. 2023a. TalkCLIP.\nMa, Y. 2023b. Styletalk.\nMa, Y. 2023c. Dreamtalk.\n",
    );
    for (suffix, title) in [('a', "TalkCLIP"), ('b', "Styletalk"), ('c', "Dreamtalk")] {
        let citations = find_citations(&test_page(&format!("(Ma et al. 2023{suffix})")));
        assert!(
            resolve_reference(&citations[0].labels, &entries)
                .unwrap()
                .text
                .contains(title)
        );
    }
    assert!(resolve_reference(&["Ma 2023".into()], &entries).is_none());
    let duplicated = references("References\nTan, S. 2024. EDTalk.\nTan, S. 2024. Style2Talker.\n");
    assert!(resolve_reference(&["Tan 2024".into()], &duplicated).is_none());
}

/// Labels of a resolved slice, in the order they came back.
fn resolved_labels<'a>(resolved: &[&'a ReferenceEntry]) -> Vec<&'a str> {
    resolved.iter().map(|entry| entry.label.as_str()).collect()
}

#[test]
fn a_grouped_numeric_citation_resolves_every_label_in_order() {
    let entries = references("References\n[1] One 2020.\n[2] Two 2021.\n[3] Three 2022.\n");
    // The detector hands over the whole group, and the citation reads `[3,1]`, so the
    // preview must follow the reader's order, not the list's.
    let citations = find_citations(&test_page("See [3,1] for details."));
    assert_eq!(citations[0].labels, ["3", "1"]);

    let resolved = resolve_references(&citations[0].labels, &entries);
    assert_eq!(resolved_labels(&resolved), ["3", "1"]);
    assert!(resolved[0].text.contains("Three"));
    assert!(resolved[1].text.contains("One"));
}

#[test]
fn every_label_of_an_unnumbered_list_resolves_by_position() {
    // ACM-style lists carry no numbers while the body cites them, so `[1,2]` must take the
    // first two entries -- each label separately, not just the first one.
    let entries = references(
        "References\nBai, X. 2016. Artist-directed dynamics.\nBarzel, R. 1988. A modeling system.\n",
    );
    assert_eq!(entries.len(), 2, "{entries:?}");

    let resolved = resolve_references(&["1".into(), "2".into()], &entries);
    assert_eq!(resolved_labels(&resolved), ["Bai 2016", "Barzel 1988"]);
}

#[test]
fn a_grouped_author_year_citation_resolves_every_label() {
    let entries =
        references("References\nHe, T.; Guo, J. 2024. GAIA.\nMa, Y.; Wang, S. 2023a. TalkCLIP.\n");
    // The detector keys each `;`-separated part of the group separately, and the resolver
    // follows the order the group was written in.
    let citations = find_citations(&test_page("(He et al. 2024; Ma et al. 2023a)"));
    assert_eq!(citations[0].labels, ["He 2024", "Ma 2023a"]);

    let resolved = resolve_references(&citations[0].labels, &entries);
    assert_eq!(resolved_labels(&resolved), ["He 2024", "Ma 2023a"]);
    assert!(resolved[0].text.contains("GAIA"));
    assert!(resolved[1].text.contains("TalkCLIP"));
}

#[test]
fn a_parenthesised_date_is_still_not_a_citation() {
    // Splitting a group on `;` must not turn a year-only span into a work.
    assert!(find_citations(&test_page("Publication date (July 2017).")).is_empty());
    assert!(find_citations(&test_page("Accepted (2020; 2021).")).is_empty());
}

#[test]
fn an_unknown_label_is_skipped_and_does_not_hide_its_neighbours() {
    // A grouped citation often names a work the parser could not recover; the rest of the
    // group must still resolve, and an entirely unknown group is empty rather than fatal.
    let entries = references("References\n[1] One 2020.\n[2] Two 2021.\n");

    let resolved = resolve_references(&["1".into(), "99".into(), "2".into()], &entries);
    assert_eq!(resolved_labels(&resolved), ["1", "2"]);
    assert!(resolve_references(&["99".into()], &entries).is_empty());
    assert!(resolve_references(&[], &entries).is_empty());
}

#[test]
fn duplicate_labels_collapse_to_one_entry() {
    let entries = references("References\n[1] One 2020.\n[2] Two 2021.\n");
    // `[1,1]` and `[1, 1]` mean one work; the panel must not list it twice.
    let resolved = resolve_references(&["1".into(), "1".into()], &entries);
    assert_eq!(resolved.len(), 1);
    assert_eq!(resolved_labels(&resolved), ["1"]);

    let authors = references("References\nHe, T. 2024. GAIA.\nMa, Y. 2023a. TalkCLIP.\n");
    let resolved = resolve_references(&["He 2024".into(), "He 2024".into()], &authors);
    assert_eq!(resolved_labels(&resolved), ["He 2024"]);
}

#[test]
fn surname_mentions_in_a_title_do_not_resolve() {
    let entries =
        references("References\nBrown, A. 2020. He won in 2024.\nChen, B. 2024. Another title.\n");
    assert!(resolve_reference(&["He 2024".into()], &entries).is_none());
}

#[test]
fn compound_surnames_only_match_the_first_author_uniquely() {
    let entries = references(
        "References\nManolo Canales Cuba, James Smith. 2025. Flowmotion.\nJane Brown, Manolo Canales Cuba. 2025. Different work.\n",
    );
    let citation = find_citations(&test_page("(Canales Cuba et al., 2025)"));
    assert_eq!(citation[0].labels, ["Canales Cuba 2025"]);
    assert!(
        resolve_reference(&citation[0].labels, &entries)
            .unwrap()
            .text
            .contains("Flowmotion")
    );
}

#[test]
fn narrative_year_citations_include_the_author_in_the_hit_box() {
    for (text, label) in [
        ("See Lasseter [1987].", "Lasseter 1987"),
        ("Wang et al. [2006]", "Wang 2006"),
        ("Noble and Tang [2006]", "Noble 2006"),
    ] {
        let raw = test_page(text);
        let citations = find_citations(&raw);
        assert_eq!(citations[0].labels, [label]);
        assert_eq!(
            raw.chars[citations[0].start..citations[0].end]
                .iter()
                .map(|c| char::from_u32(c.unicode).unwrap())
                .collect::<String>(),
            citations[0].text
        );
    }
    assert!(find_citations(&test_page("Publication date (July 2017).")).is_empty());
}

#[test]
fn unicode_ranges_and_invalid_codepoints_preserve_character_indices() {
    let mut raw = test_page("é? see [7–9] and (Ope\u{2}nAI 2023)");
    raw.chars[1].unicode = 0x110000;
    let citations = find_citations(&raw);
    assert_eq!(citations[0].labels, ["7", "8", "9"]);
    assert_eq!(raw.chars[citations[0].start].unicode, '[' as u32);
    assert_eq!(citations[1].labels, ["OpenAI 2023"]);
}

fn geometric_page(lines: &[(f64, f64, &str)]) -> RawTextPage {
    let mut raw = test_page("");
    for (x, y, line) in lines {
        let mut run = test_page(&format!("{line}\n"));
        for c in &mut run.chars {
            c.rect.origin.x += x;
            c.rect.origin.y = *y;
        }
        raw.chars.extend(run.chars);
    }
    raw
}

#[test]
fn y_only_link_bands_cannot_mix_columns() {
    let raw = geometric_page(&[
        (10., 700., "[1] Left 2020."),
        (10., 650., "[2] Left 2021."),
        (310., 700., "[3] Right 2022."),
        (310., 650., "[4] Right 2023."),
    ]);
    let pages = vec![(0, raw)];
    let parsed = find_references([(0, &pages[0].1)], 100);
    assert_eq!(parsed.len(), 4);
    assert_eq!(
        find_references_with_landings(&pages, &BTreeMap::from([(0, vec![710., 660.])]), 100),
        parsed
    );
}

#[test]
fn sparse_links_cannot_drop_entries_or_add_an_appendix() {
    let raw = geometric_page(&[
        (10., 700., "[1] One 2020."),
        (10., 670., "[2] Two 2021."),
        (10., 640., "[3] Three 2022."),
    ]);
    let appendix = geometric_page(&[(10., 700., "[1] Step one."), (10., 640., "[2] Step two.")]);
    let pages = vec![(0, raw), (1, appendix)];
    let parsed = find_references(pages.iter().map(|(p, t)| (*p, t)), 100);
    assert_eq!(parsed.len(), 3);
    let landings = BTreeMap::from([(0, vec![710., 650.]), (1, vec![710., 650.])]);
    assert_eq!(
        find_references_with_landings(&pages, &landings, 100),
        parsed
    );
    assert!(find_references_with_landings(&pages, &landings, 0).is_empty());
}

/// A page built line by line: `(top, font size, text)`, each line starting at x = 60.
///
/// Unlike [`test_page`], which puts every character on one baseline, these lines carry the
/// geometry a section boundary is read from: a top, a size, and a line break between them.
fn page_of(lines: &[(f64, f64, &str)]) -> RawTextPage {
    use aris_reader_core::{PageIndex, RawCharBox, RawTextPage, Rect};
    let mut chars = Vec::new();
    let mut text = String::new();
    for (top, size, line) in lines {
        let mut x = 60.0;
        for character in line.chars().chain(std::iter::once('\n')) {
            chars.push(RawCharBox {
                rect: Rect::new(x, top - size, size * 0.5, *size),
                origin: aris_reader_core::Point::new(x, top - size),
                unicode: character as u32,
                font_size: *size,
                angle: 0.0,
                font_name: "Body".to_string(),
            });
            x += size * 0.5;
            text.push(character);
        }
    }
    RawTextPage {
        page: PageIndex(0),
        chars,
        text,
        is_generated: false,
        has_unicode_map_error: false,
    }
}

#[test]
fn the_last_entry_stops_where_a_larger_section_begins() {
    // The shape T4.29 measured on four real papers: the list ends, and an appendix set in a
    // larger type follows it on the same page, after a paragraph break.
    let page = page_of(&[
        (760.0, 10.0, "References"),
        (748.0, 10.0, "[1] Alpha, A. 2019. First reference."),
        (736.0, 10.0, "[2] Beta, B. 2020. Second reference that"),
        (724.0, 10.0, "wraps onto a second line."),
        (700.0, 12.0, "Appendix A: More results"),
        (
            688.0,
            12.0,
            "The appendix body is set larger than the list.",
        ),
        (676.0, 12.0, "It is not part of the reference above it."),
    ]);
    let entries = find_references([(0, &page)], 100);
    assert_eq!(
        entries.iter().map(|e| e.label.as_str()).collect::<Vec<_>>(),
        ["1", "2"]
    );
    let last = entries.last().unwrap();
    assert!(last.text.contains("wraps onto a second line."), "{last:?}");
    assert!(!last.text.contains("Appendix A"), "{last:?}");
    assert!(!last.text.contains("appendix body"), "{last:?}");
    // The range and the box follow the text: the entry ends at the appendix heading's first
    // character, not at the end of the page.
    let heading = page
        .text
        .find("Appendix A")
        .expect("the appendix heading is in the page");
    assert_eq!(last.end, heading);
}

#[test]
fn a_paragraph_gap_inside_an_entry_does_not_end_it() {
    // The rejected fix — cut at the largest paragraph gap — truncated real references. This one
    // resumes at the same size after twice the line spacing, and in an italic face below it.
    let page = page_of(&[
        (760.0, 10.0, "References"),
        (748.0, 10.0, "[1] Alpha, A. 2019. First reference."),
        (
            736.0,
            10.0,
            "[2] Beta, B. 2020. A reference whose title runs",
        ),
        (712.0, 10.0, "on after a gap of two line spacings."),
        (700.0, 9.0, "In Proceedings of the Conference, pages 1-9."),
        (688.0, 10.0, "[3] Gamma, C. 2021. Third reference."),
    ]);
    let entries = find_references([(0, &page)], 100);
    let entry = entries
        .iter()
        .find(|entry| entry.label == "2")
        .expect("entry 2");
    assert!(entry.text.contains("on after a gap"), "{entry:?}");
    assert!(entry.text.contains("In Proceedings"), "{entry:?}");
    assert!(!entry.text.contains("Gamma"), "{entry:?}");
}

#[test]
fn one_tall_glyph_on_a_wrapped_reference_line_does_not_end_it() {
    // A reference line can carry a single glyph larger than its body — a delimiter, a math
    // symbol. It is a full-width line, not a heading, so it does not end the entry.
    let page = page_of(&[
        (760.0, 10.0, "References"),
        (748.0, 10.0, "[1] Alpha, A. 2019. First reference."),
        (736.0, 10.0, "[2] Beta, B. 2020. A reference with a large"),
        (
            712.0,
            12.0,
            "delimiter spanning a wrapped line of its own here.",
        ),
        (700.0, 10.0, "In Proceedings of the Conference, pages 1-9."),
        (688.0, 10.0, "[3] Gamma, C. 2021. Third reference."),
    ]);
    let entries = find_references([(0, &page)], 100);
    let entry = entries
        .iter()
        .find(|entry| entry.label == "2")
        .expect("entry 2");
    assert!(entry.text.contains("delimiter spanning"), "{entry:?}");
    assert!(entry.text.contains("In Proceedings"), "{entry:?}");
}
