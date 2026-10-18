//! Measure the document index cache against a real PDF.
//!
//! ```text
//! cargo run -p aris-reader-ffi --release --example index_cache -- <file.pdf>
//! ```
//!
//! The example opens the file twice. The first open derives the index (unless a cache already
//! exists), the second should hit the sidecar. It prints open time, index time, validation time
//! and the derived-component counter so the numbers can be checked rather than inferred.
//!
//! To measure the no-cache baseline, run the same command with the cache disabled:
//! `ARIS_READER_INDEX_CACHE=disabled … --example index_cache`. In that mode the report says
//! `disabled`, nothing is written, and the index time is the parse the cache replaces.
//!
//! Copy the PDF under `build/` before running: the sidecar belongs beside the document, and
//! committed samples/corpora must not collect cache files.

use aris_reader_ffi::api::{ArisDocument, ArisEngine};
use std::path::Path;
use std::time::Instant;

fn read_index(document: &ArisDocument) -> (f64, Vec<usize>, usize) {
    let started = Instant::now();
    let outline = document.outline().expect("outline");
    let references = document.references().expect("references");
    let figures = document.figures().expect("figures");
    let metadata = document.metadata().expect("metadata");
    let citations = document.citations(0).expect("citations on page 1");
    let elapsed = started.elapsed().as_secs_f64() * 1000.0;
    let _ = metadata;
    (
        elapsed,
        vec![outline.len(), references.len(), figures.len()],
        citations.len(),
    )
}

fn run(engine: &ArisEngine, path: &str, label: &str) {
    let opened = Instant::now();
    let document = engine
        .open_document(path.to_string(), None)
        .expect("open the document");
    let open_ms = opened.elapsed().as_secs_f64() * 1000.0;

    // The report performs the one lazy lookup, so its validation time belongs to the index
    // path, not to opening the PDF.
    let lookup_started = Instant::now();
    let _ = document.index_cache_report();
    let lookup_ms = lookup_started.elapsed().as_secs_f64() * 1000.0;
    let (index_ms, counts, page_one_citations) = read_index(&document);
    let after = document.index_cache_report();
    let total_ms = open_ms + lookup_ms + index_ms;

    println!(
        "{label}: open_ms={open_ms:.2} lookup_ms={lookup_ms:.2} index_ms={index_ms:.2} \
         open_to_citations_ms={total_ms:.2} validation_ms={:.2} derived_parts={} outcome={:?} \
         cache_bytes={} outline={} references={} figures={} page1_citations={page_one_citations} \
         sha256={}",
        after.validation_micros as f64 / 1000.0,
        after.derived_parts,
        after.outcome,
        after.cache_bytes,
        counts[0],
        counts[1],
        counts[2],
        after.content_sha256.as_deref().unwrap_or("none"),
    );
    drop(document);
}

fn main() {
    let mut args = std::env::args().skip(1);
    let Some(path) = args.next() else {
        eprintln!("usage: index_cache <file.pdf>");
        std::process::exit(64);
    };
    if !Path::new(&path).is_file() {
        eprintln!("not a file: {path}");
        std::process::exit(66);
    }
    let engine = ArisEngine::new();
    run(&engine, &path, "cold");
    run(&engine, &path, "warm");
}
