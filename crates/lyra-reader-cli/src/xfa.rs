//! `lyra-reader-cli xfa`: the phase-1 evidence command.
//!
//! It writes the decrypted packets and prints the structure the renderer saw: packets, page
//! areas and break hints, every field with its geometry and type, the requested fonts, and the
//! values and LOV tables in the dataset. `summary.json` carries the same facts for tooling.

use lyra_reader_xfa::{PreparedXfa, XfaError};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

pub fn run(args: &[String]) -> ExitCode {
    let (positional, options) = crate::parse(args);
    let Some(path) = positional.first() else {
        eprintln!("usage: lyra-reader-cli xfa <file.pdf> --out <dir>");
        return ExitCode::from(64);
    };
    let output = crate::opt(&options, &["--out", "-o"])
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            let stem = Path::new(path)
                .file_stem()
                .and_then(|stem| stem.to_str())
                .unwrap_or("xfa");
            PathBuf::from(format!("xfa-{stem}"))
        });

    let prepared = match lyra_reader_xfa::prepare(Path::new(path), None) {
        Ok(Some(prepared)) => prepared,
        Ok(None) => {
            eprintln!("error: {path} is not an XFA form (no /AcroForm /XFA)");
            return ExitCode::from(2);
        }
        Err(XfaError::PasswordRequired) => {
            eprintln!(
                "error: {path} needs a password; this command only opens the empty user password"
            );
            return ExitCode::from(2);
        }
        Err(error) => {
            eprintln!("error: {error}");
            return ExitCode::from(1);
        }
    };

    if let Some(path) = crate::opt(&options, &["--pdf"]) {
        match &prepared.pdf {
            Some(bytes) => {
                if let Err(error) = std::fs::write(path, bytes) {
                    eprintln!("error: could not write {path}: {error}");
                    return ExitCode::from(1);
                }
                println!("synthetic PDF: {path}");
            }
            None => eprintln!("warning: no synthetic PDF was produced"),
        }
    }

    let written = match lyra_reader_xfa::write_packets(&prepared.file, &output) {
        Ok(paths) => paths,
        Err(error) => {
            eprintln!("error: {error}");
            return ExitCode::from(1);
        }
    };

    print_report(&prepared, &written);
    let json_path = output.join("summary.json");
    match serde_json::to_vec_pretty(&summary_json(&prepared)) {
        Ok(bytes) => {
            if let Err(error) = std::fs::write(&json_path, bytes) {
                eprintln!("error: could not write {}: {error}", json_path.display());
                return ExitCode::from(1);
            }
            println!("\nsummary JSON: {}", json_path.display());
        }
        Err(error) => {
            eprintln!("error: could not serialize the summary: {error}");
            return ExitCode::from(1);
        }
    }
    ExitCode::SUCCESS
}

fn print_report(prepared: &PreparedXfa, written: &[PathBuf]) {
    println!("file      : XFA form");
    println!(
        "encryption: {} (opened with the empty user password: {})",
        if prepared.file.encrypted { "yes" } else { "no" },
        if prepared.file.opened_with_empty_password {
            "yes"
        } else {
            "no"
        }
    );
    println!("needsRendering: {}", prepared.file.needs_rendering);
    println!("packets   : {}", prepared.file.packets.len());
    for (index, packet) in prepared.file.packets.iter().enumerate() {
        let written_path = written.get(index);
        println!(
            "  {:<3} {:<14} {:>9} bytes  {}",
            index,
            packet.name,
            packet.bytes.len(),
            written_path
                .map(|path| path.display().to_string())
                .unwrap_or_default()
        );
    }
    if !prepared.file.warnings.is_empty() {
        println!("packet warnings:");
        for warning in &prepared.file.warnings {
            println!("  - {warning}");
        }
    }

    let Some(template) = &prepared.template else {
        println!("\ntemplate  : MISSING OR MALFORMED");
        for skipped in &prepared.status.skipped {
            println!("  - {skipped}");
        }
        return;
    };

    println!("\npages     : {}", prepared.status.page_count);
    println!("page areas:");
    for area in &template.page_areas {
        println!(
            "  {}  {:.0}×{:.0} pt  content {:.2},{:.2} {:.2}×{:.2} pt",
            area.name,
            area.page_size.width,
            area.page_size.height,
            area.content_area.x,
            area.content_area.y,
            area.content_area.width,
            area.content_area.height
        );
    }
    println!("page breaks:");
    for (page, page_break) in template.page_breaks() {
        match page_break {
            Some(page_break) => println!(
                "  {} ← targetType={} target={} startNew={}",
                page,
                page_break.target_type.as_deref().unwrap_or("-"),
                page_break.target.as_deref().unwrap_or("-"),
                page_break.start_new
            ),
            None => println!("  {} ← no breakBefore", page),
        }
    }

    println!("\nfields    : {}", prepared.status.field_count);
    let counts = template.field_type_counts();
    let summary = counts
        .iter()
        .map(|(kind, count)| format!("{kind} {count}"))
        .collect::<Vec<_>>()
        .join(", ");
    println!("  by type : {summary}");
    let draws = template.draws();
    println!("static draws: {}", draws.len());
    println!("fonts requested:");
    for (name, usage) in &template.fonts {
        println!(
            "  {name:<28} sizes {:?}  ({} uses)",
            usage.sizes(),
            usage.uses()
        );
    }

    println!("\nfield tree:");
    for field in template.fields() {
        let geometry = &field.geometry;
        println!(
            "  p{}  {:<72} {:<11} x={:<7} y={:<7} w={:<7} h={:<7}{}{}",
            field.page + 1,
            truncate(&field.path, 72),
            field.kind.label(),
            format_optional(geometry.x, 0.0),
            format_optional(geometry.y, 0.0),
            format_optional_option(geometry.width),
            format_optional_option(geometry.height),
            field
                .caption
                .as_deref()
                .map(|caption| format!(" caption={caption:?}"))
                .unwrap_or_default(),
            field
                .value
                .as_deref()
                .map(|value| format!(" value={value:?}"))
                .unwrap_or_default()
        );
    }

    println!(
        "\ndataset values ({} non-empty leaves):",
        prepared.dataset.values.len()
    );
    for (path, value) in &prepared.dataset.values {
        println!("  {path} = {value:?}");
    }
    println!(
        "LOV tables: {} ({} entries; {} lookup names including aliases)",
        prepared.dataset.lov_table_count,
        prepared.dataset.lov_entries,
        prepared.dataset.lov.len()
    );
    for (name, entries) in prepared.dataset.lov.iter().take(12) {
        println!(
            "  {name:<32} {} entries; first: {:?}",
            entries.len(),
            entries.first().map(|entry| (&entry.value, &entry.label))
        );
    }
    if prepared.dataset.lov.len() > 12 {
        println!(
            "  … {} more tables (see summary.json)",
            prepared.dataset.lov.len() - 12
        );
    }

    println!("\nskipped / substituted:");
    if prepared.status.skipped.is_empty() {
        println!("  (nothing)");
    }
    for skipped in &prepared.status.skipped {
        println!("  - {skipped}");
    }
    match &prepared.status.error {
        Some(error) => println!("\nrender    : FAILED — {error}"),
        None => println!(
            "\nrender    : {} page(s) from the XML, read-only in memory",
            prepared.status.page_count
        ),
    }
}

fn summary_json(prepared: &PreparedXfa) -> serde_json::Value {
    let template = prepared.template.as_ref();
    serde_json::json!({
        "xfa": true,
        "encrypted": prepared.file.encrypted,
        "opened_with_empty_password": prepared.file.opened_with_empty_password,
        "needs_rendering": prepared.file.needs_rendering,
        "packets": prepared.file.packets.iter().map(|packet| serde_json::json!({
            "name": packet.name,
            "bytes": packet.bytes.len(),
            "wrapper": packet.is_wrapper(),
        })).collect::<Vec<_>>(),
        "page_count": prepared.status.page_count,
        "page_areas": template.map(|template| template.page_areas.iter().map(|area| serde_json::json!({
            "name": area.name,
            "width_pt": area.page_size.width,
            "height_pt": area.page_size.height,
            "content_area_pt": {
                "x": area.content_area.x,
                "y": area.content_area.y,
                "width": area.content_area.width,
                "height": area.content_area.height,
            }
        })).collect::<Vec<_>>()),
        "page_breaks": template.map(|template| template.page_breaks().iter().map(|(page, hint)| serde_json::json!({
            "page": page,
            "target_type": hint.as_ref().and_then(|hint| hint.target_type.clone()),
            "target": hint.as_ref().and_then(|hint| hint.target.clone()),
            "start_new": hint.as_ref().is_some_and(|hint| hint.start_new),
        })).collect::<Vec<_>>()),
        "fields": template.map(|template| template.fields().iter().map(|field| serde_json::json!({
            "page": field.page + 1,
            "path": field.path,
            "type": field.kind.label(),
            "x": field.geometry.x,
            "y": field.geometry.y,
            "w": field.geometry.width,
            "h": field.geometry.height,
            "presence": format!("{:?}", field.presence),
            "read_only": field.read_only,
            "caption": field.caption,
            "value": field.value,
        })).collect::<Vec<_>>()),
        "field_types": template.map(|template| template.field_type_counts()),
        "fonts": template.map(|template| template.fonts.iter().map(|(name, usage)| (name.clone(), serde_json::json!(usage.sizes()))).collect::<serde_json::Map<String, serde_json::Value>>()),
        "dataset_values": prepared.dataset.values.iter().map(|(path, value)| serde_json::json!({"path": path, "value": value})).collect::<Vec<_>>(),
        "lov_tables": prepared.dataset.lov_table_count,
        "lov_entries": prepared.dataset.lov_entries,
        "skipped": prepared.status.skipped,
        "render_error": prepared.status.error,
        "read_only_reason": prepared.status.read_only_reason,
    })
}

fn format_optional(value: f64, zero: f64) -> String {
    if value == zero {
        "0".to_string()
    } else {
        format!("{value:.1}")
    }
}

fn format_optional_option(value: Option<f64>) -> String {
    value
        .map(|value| format!("{value:.1}"))
        .unwrap_or_else(|| "-".to_string())
}

fn truncate(text: &str, limit: usize) -> String {
    if text.chars().count() <= limit {
        text.to_string()
    } else {
        text.chars()
            .take(limit.saturating_sub(1))
            .collect::<String>()
            + "…"
    }
}
