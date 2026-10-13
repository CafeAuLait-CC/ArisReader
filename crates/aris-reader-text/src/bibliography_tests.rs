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
