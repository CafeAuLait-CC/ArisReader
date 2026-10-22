//! Edits to annotations that a page's `/Annots` carries.
//!
//! PDF 32000-1 requires annotations to be indirect objects, but real producers write
//! dictionaries **inline** in `/Annots`, and PDFium reads them. The reader lists and adopts those
//! annotations, so the writer must find them by the same identity it reports. The sample in
//! `pdf-samples/with_annotations/` is such a file: page 1 carries two highlight dictionaries
//! directly in its `/Annots` array.
//!
//! These tests exercise the public save boundary rather than the module internals: they prove
//! that an identity PDFium reports can always be named in an edit, whichever form the dictionary
//! has and whichever page it lives on.

use lopdf::{Dictionary, Document, Object, Stream, dictionary};
use lyra_reader_core::{AnnotationAlignment, ErrorCode, PageIndex, RawAnnotation, Rect};
use lyra_reader_pdfium::{
    AnnotationChanges, AnnotationReader, AnnotationUpdate, SaveMode, WriteAnnotation,
    WriteAnnotationKind, is_available, save_annotation_changes,
};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// A test-owned directory removed when the test ends, including on a panic.
struct Scratch(PathBuf);

impl Scratch {
    fn new(label: &str) -> Self {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock before the epoch")
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "lyra-annotation-edit-{label}-{}-{nanos}",
            std::process::id()
        ));
        std::fs::create_dir_all(&path).expect("create scratch directory");
        Self(path)
    }

    fn join(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn require_pdfium() -> bool {
    if is_available() {
        true
    } else {
        eprintln!("skipping: PDFium unavailable");
        false
    }
}

/// Every annotation identity PDFium reports, across every page, sorted.
///
/// This is the same identity the shell adopts, so comparing this set before and after a save
/// answers "did the edit keep the file's annotations?" without trusting the writer's own parser.
fn identities(path: &Path) -> Vec<String> {
    let page_count = Document::load(path)
        .expect("open the document")
        .get_pages()
        .len();
    let reader = AnnotationReader::open(path, None).expect("open annotations with PDFium");
    let mut found = Vec::new();
    for page in 0..u32::try_from(page_count).expect("page count fits u32") {
        for annotation in reader.page(PageIndex(page)).expect("read page annotations") {
            found.push(annotation.id);
        }
    }
    found.sort();
    found
}

fn page_annotations(path: &Path, page: u32) -> Vec<RawAnnotation> {
    let reader = AnnotationReader::open(path, None).expect("open annotations with PDFium");
    reader.page(PageIndex(page)).expect("read page annotations")
}

/// The writer model for a record the reader reported, with one field replaced.
fn update_from(record: &RawAnnotation, contents: &str) -> AnnotationUpdate {
    let kind = match &record.kind {
        lyra_reader_core::RawAnnotationKind::Highlight => WriteAnnotationKind::Highlight,
        lyra_reader_core::RawAnnotationKind::Underline => WriteAnnotationKind::Underline,
        lyra_reader_core::RawAnnotationKind::Strikeout => WriteAnnotationKind::StrikeOut,
        lyra_reader_core::RawAnnotationKind::Text => WriteAnnotationKind::Text,
        lyra_reader_core::RawAnnotationKind::FreeText => WriteAnnotationKind::FreeText,
        lyra_reader_core::RawAnnotationKind::Ink => WriteAnnotationKind::Ink,
        lyra_reader_core::RawAnnotationKind::Square => WriteAnnotationKind::Square,
        lyra_reader_core::RawAnnotationKind::Circle => WriteAnnotationKind::Circle,
        lyra_reader_core::RawAnnotationKind::Line => WriteAnnotationKind::Line,
        other => panic!("no write model for {other:?}"),
    };
    AnnotationUpdate {
        target: record.id.clone(),
        assign_name: None,
        values: WriteAnnotation {
            id: format!("edit-{}", record.id),
            page: record.page,
            kind,
            rect: record.rect,
            quads: record.quads.clone(),
            ink_paths: record.ink_paths.clone(),
            line: record.line,
            line_arrow: record.line_arrow,
            border_width: record.border_width.unwrap_or(1.0),
            font_size: record.font_size_pt.unwrap_or(14.0),
            stamp_style: None,
            stamp_image: None,
            alignment: record.alignment,
            color: record.color.map_or([0x80, 0x80, 0x80], |colour| {
                [colour.red, colour.green, colour.blue]
            }),
            opacity: record.opacity.unwrap_or(1.0),
            contents: Some(contents.to_string()),
            author: None,
            modified: Some("D:20261019120000-07'00'".to_string()),
        },
    }
}

fn highlight(name: &str, contents: &str, y: f64) -> Dictionary {
    let rect = vec![
        Object::Real(72.0),
        Object::Real(y as f32),
        Object::Real(300.0),
        Object::Real((y + 12.0) as f32),
    ];
    dictionary! {
        "Type" => "Annot",
        "Subtype" => "Highlight",
        "Rect" => rect.clone(),
        "QuadPoints" => vec![
            Object::Real(72.0),
            Object::Real((y + 12.0) as f32),
            Object::Real(300.0),
            Object::Real((y + 12.0) as f32),
            Object::Real(72.0),
            Object::Real(y as f32),
            Object::Real(300.0),
            Object::Real(y as f32),
        ],
        "NM" => Object::string_literal(name),
        "Contents" => Object::string_literal(contents),
        "T" => Object::string_literal("Alex"),
        "F" => 4,
        "C" => vec![Object::Real(1.0), Object::Real(1.0), Object::Real(0.0)],
        "CA" => Object::Real(1.0),
    }
}

/// One entry in a synthetic page's `/Annots`: either the dictionary itself (the inline form
/// real producers use) or an indirect object the helper creates.
enum Entry {
    Inline(Dictionary),
    Indirect(Dictionary),
}

/// Writes a PDF whose page `/Annots` arrays are built from `pages`.
fn write_pdf(path: &Path, pages: &[Vec<Entry>]) {
    let mut document = Document::with_version("1.7");
    let pages_id = document.new_object_id();
    let mut kids = Vec::new();
    for entries in pages {
        let annots: Vec<Object> = entries
            .iter()
            .map(|entry| match entry {
                Entry::Inline(dictionary) => Object::Dictionary(dictionary.clone()),
                Entry::Indirect(dictionary) => {
                    Object::Reference(document.add_object(dictionary.clone()))
                }
            })
            .collect();
        let content = document.add_object(Stream::new(dictionary! {}, Vec::new()));
        let page = document.add_object(dictionary! {
            "Type" => "Page",
            "Parent" => pages_id,
            "MediaBox" => vec![0.into(), 0.into(), 612.into(), 792.into()],
            "Contents" => content,
            "Annots" => annots,
        });
        kids.push(page.into());
    }
    document.objects.insert(
        pages_id,
        Object::Dictionary(dictionary! {
            "Type" => "Pages",
            "Kids" => kids,
            "Count" => pages.len() as i64,
        }),
    );
    let catalog = document.add_object(dictionary! { "Type" => "Catalog", "Pages" => pages_id });
    document.trailer.set("Root", catalog);
    document.save(path).expect("write synthetic PDF");
}

fn highlight_update(id: &str, page: u32) -> WriteAnnotation {
    WriteAnnotation {
        id: id.to_string(),
        page: PageIndex(page),
        kind: WriteAnnotationKind::Highlight,
        rect: Rect::new(72.0, 700.0, 228.0, 12.0),
        quads: vec![Rect::new(72.0, 700.0, 228.0, 12.0)],
        ink_paths: Vec::new(),
        line: None,
        line_arrow: false,
        border_width: 1.0,
        font_size: 0.0,
        stamp_style: None,
        stamp_image: None,
        alignment: AnnotationAlignment::Left,
        color: [12, 200, 40],
        opacity: 1.0,
        contents: Some("edited".to_string()),
        author: None,
        modified: Some("D:20261019120000-07'00'".to_string()),
    }
}

#[test]
fn the_review_sample_edit_reaches_inline_annotations_on_every_page() {
    if !require_pdfium() {
        return;
    }
    let Ok(samples) = std::env::var("LYRA_READER_PDF_SAMPLES") else {
        eprintln!("skipping: LYRA_READER_PDF_SAMPLES is not set");
        return;
    };
    let source = Path::new(&samples).join("with_annotations/review_du_0923 (annotated).pdf");
    if !source.is_file() {
        eprintln!("skipping: {} is not present", source.display());
        return;
    }
    let scratch = Scratch::new("sample");
    let copy = scratch.join("source.pdf");
    std::fs::copy(&source, &copy).expect("copy the sample");
    let original_bytes = std::fs::read(&copy).expect("read the source copy");
    let before = identities(&copy);

    // The exact identity the defect report names, plus everything else the reader reports as
    // editable content. The application adopts all of them before a content edit and writes
    // each one back through an update, whichever page it lives on.
    let target = "nm:215E95D5-376F-444C-B18D-95099FEFC3B6";
    assert!(
        before.iter().any(|identity| identity == target),
        "the sample must report the identity this test edits: {before:?}"
    );
    let mut updates = Vec::new();
    let page_count = Document::load(&copy)
        .expect("open the sample")
        .get_pages()
        .len();
    let reader = AnnotationReader::open(&copy, None).expect("open annotations");
    for page in 0..u32::try_from(page_count).expect("page count fits u32") {
        for record in reader.page(PageIndex(page)).expect("read page") {
            if !record.visible {
                continue;
            }
            if matches!(
                record.kind,
                lyra_reader_core::RawAnnotationKind::Highlight
                    | lyra_reader_core::RawAnnotationKind::Text
                    | lyra_reader_core::RawAnnotationKind::Underline
                    | lyra_reader_core::RawAnnotationKind::Strikeout
                    | lyra_reader_core::RawAnnotationKind::Ink
                    | lyra_reader_core::RawAnnotationKind::Square
                    | lyra_reader_core::RawAnnotationKind::Circle
                    | lyra_reader_core::RawAnnotationKind::Line
            ) {
                updates.push(update_from(&record, "edited by the identity check"));
            }
        }
    }
    drop(reader);
    assert!(
        updates.len() >= 7,
        "the sample has two page-1 highlights and five more marks on page 8: {}",
        updates.len()
    );

    let destination = scratch.join("edited.pdf");
    let report = save_annotation_changes(
        &copy,
        &destination,
        &AnnotationChanges {
            additions: Vec::new(),
            updates,
            deletions: Vec::new(),
        },
        &[],
        None,
        SaveMode::Copy,
    )
    .expect("a content edit of the sample must find the annotations it adopted");

    assert!(
        report.deleted_ids.is_empty(),
        "an edit deletes nothing: {:?}",
        report.deleted_ids
    );
    assert!(
        !report.written_ids.is_empty(),
        "the save must report the identities it wrote"
    );
    assert!(
        std::fs::read(&destination)
            .expect("read saved bytes")
            .starts_with(&original_bytes),
        "an edit is an incremental update, so every source byte stays the prefix"
    );
    assert_eq!(
        std::fs::read(&copy).expect("read source after the save"),
        original_bytes,
        "saving a copy leaves the source untouched"
    );
    assert_eq!(
        identities(&destination),
        before,
        "a reopen must report exactly the source's annotation identities"
    );
    let after_page_one = page_annotations(&destination, 0);
    let inline = after_page_one
        .iter()
        .find(|record| record.id == target)
        .expect("the page-1 inline highlight keeps its identity");
    assert_eq!(
        inline.contents.as_deref(),
        Some("edited by the identity check"),
        "the inline dictionary itself was rewritten"
    );
    assert_eq!(
        inline.author.as_deref(),
        Some("Alex Xu"),
        "keys the editor does not own are preserved"
    );
}

#[test]
fn an_annotation_on_another_page_is_found_whichever_form_it_has() {
    if !require_pdfium() {
        return;
    }
    let scratch = Scratch::new("cross-page");
    let source = scratch.join("two-pages.pdf");
    // The edit happens on page 1; page 2 carries one annotation in each storage form.
    write_pdf(
        &source,
        &[
            Vec::new(),
            vec![
                Entry::Inline(highlight("inline-second-page", "inline", 700.0)),
                Entry::Indirect(highlight("indirect-second-page", "indirect", 650.0)),
            ],
        ],
    );

    let before = identities(&source);
    assert_eq!(
        before,
        vec![
            "nm:indirect-second-page".to_string(),
            "nm:inline-second-page".to_string()
        ]
    );

    let updates = vec![
        AnnotationUpdate {
            target: "nm:inline-second-page".to_string(),
            assign_name: None,
            values: highlight_update("inline-second-page", 1),
        },
        AnnotationUpdate {
            target: "nm:indirect-second-page".to_string(),
            assign_name: None,
            values: highlight_update("indirect-second-page", 1),
        },
    ];
    save_annotation_changes(
        &source,
        &scratch.join("edited.pdf"),
        &AnnotationChanges {
            additions: Vec::new(),
            updates,
            deletions: Vec::new(),
        },
        &[],
        None,
        SaveMode::Copy,
    )
    .expect("an annotation on page 2 must be found while page 1 is the edited page");
    let destination = scratch.join("edited.pdf");
    assert_eq!(identities(&destination), before);
    let page_two = page_annotations(&destination, 1);
    assert_eq!(page_two.len(), 2);
    for record in page_two {
        assert_eq!(record.contents.as_deref(), Some("edited"));
    }
}

#[test]
fn a_kind_the_editor_cannot_change_is_refused_as_such() {
    if !require_pdfium() {
        return;
    }
    let scratch = Scratch::new("unsupported");
    let source = scratch.join("unsupported.pdf");
    let squiggly = dictionary! {
        "Type" => "Annot",
        "Subtype" => "Squiggly",
        "Rect" => vec![Object::Real(72.0), Object::Real(700.0), Object::Real(300.0), Object::Real(712.0)],
        "NM" => Object::string_literal("not-editable"),
        "Contents" => Object::string_literal("a kind this editor has no model for"),
        "F" => 4,
    };
    let link = dictionary! {
        "Type" => "Annot",
        "Subtype" => "Link",
        "Rect" => vec![Object::Real(72.0), Object::Real(650.0), Object::Real(300.0), Object::Real(662.0)],
        "NM" => Object::string_literal("link"),
        "Border" => vec![Object::Real(0.0), Object::Real(0.0), Object::Real(1.0)],
        "A" => dictionary! { "S" => "URI", "URI" => Object::string_literal("https://example.com") },
    };
    write_pdf(
        &source,
        &[vec![Entry::Inline(squiggly), Entry::Indirect(link)]],
    );
    let destination = scratch.join("refused.pdf");

    for target in ["nm:not-editable", "nm:link"] {
        let error = save_annotation_changes(
            &source,
            &destination,
            &AnnotationChanges {
                additions: Vec::new(),
                updates: vec![AnnotationUpdate {
                    target: target.to_string(),
                    assign_name: None,
                    values: highlight_update("unsupported", 0),
                }],
                deletions: Vec::new(),
            },
            &[],
            None,
            SaveMode::Copy,
        )
        .expect_err("a kind without an editable model must be refused");
        assert_eq!(
            error.code,
            ErrorCode::UnsupportedFeature,
            "{target}: {error}"
        );
        let message = error.to_string();
        assert!(
            message.contains("kind the editor cannot modify"),
            "{target} must name the real problem, not a missing annotation: {message}"
        );
        assert!(
            !message.contains("does not contain"),
            "{target} exists in the file, so NotFound would be a lie: {message}"
        );
        assert!(
            !destination.exists(),
            "a refused edit writes no output file"
        );
    }
}

#[test]
fn an_identity_the_file_really_lacks_is_still_not_found() {
    if !require_pdfium() {
        return;
    }
    let scratch = Scratch::new("missing");
    let source = scratch.join("one-page.pdf");
    write_pdf(
        &source,
        &[vec![Entry::Inline(highlight("present", "present", 700.0))]],
    );
    let destination = scratch.join("refused.pdf");
    let error = save_annotation_changes(
        &source,
        &destination,
        &AnnotationChanges {
            additions: Vec::new(),
            updates: vec![AnnotationUpdate {
                target: "nm:not-in-the-file".to_string(),
                assign_name: None,
                values: highlight_update("unsupported", 0),
            }],
            deletions: Vec::new(),
        },
        &[],
        None,
        SaveMode::Copy,
    )
    .expect_err("an identity that is not in the file must still be refused");
    assert_eq!(error.code, ErrorCode::NotFound, "{error}");
    assert!(error.to_string().contains("does not contain"), "{error}");
    assert!(!destination.exists());
}

#[test]
fn an_inline_annotation_can_be_deleted_without_touching_its_neighbour() {
    if !require_pdfium() {
        return;
    }
    let scratch = Scratch::new("inline-delete");
    let source = scratch.join("two-inline.pdf");
    write_pdf(
        &source,
        &[vec![
            Entry::Inline(highlight("first", "first", 700.0)),
            Entry::Inline(highlight("second", "second", 650.0)),
        ]],
    );
    let destination = scratch.join("deleted.pdf");
    let report = save_annotation_changes(
        &source,
        &destination,
        &AnnotationChanges {
            additions: Vec::new(),
            updates: Vec::new(),
            deletions: vec![lyra_reader_pdfium::AnnotationDelete {
                target: "nm:first".to_string(),
            }],
        },
        &[],
        None,
        SaveMode::Copy,
    )
    .expect("an inline annotation can be removed by identity");
    assert_eq!(report.deleted_ids, vec!["nm:first".to_string()]);
    assert_eq!(
        identities(&destination),
        vec!["nm:second".to_string()],
        "the sibling survives with its own identity"
    );
    let surviving = page_annotations(&destination, 0);
    assert_eq!(surviving.len(), 1);
    assert_eq!(surviving[0].contents.as_deref(), Some("second"));
}
