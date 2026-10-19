//! Reading and filling AcroForm fields, through the widget dictionaries and an incremental save.
//!
//! # Why the dictionaries, not PDFium's form API
//!
//! PDFium's public C ABI has a form *event* API (`FORM_OnChar`, `FORM_OnLButtonDown`, …) and a
//! renderer (`FPDF_FFLDraw`), but no field enumeration: there is no `FPDF_GetFormFieldCount`,
//! no accessor for a widget's field type and no read/write value call that a shell can use
//! without driving a whole interactive form environment. The widget dictionaries are the
//! normative description every viewer reads, and `lopdf` already parses them (including object
//! streams) for the appearance writer in [`crate::geometry_write`]. So this module reads
//! `/AcroForm` → `/Fields` (with the `/Kids` hierarchy and inherited `/FT`, `/Ff`, `/DA`,
//! `/Opt`, `/V`), associates each `/Subtype /Widget` with its page through that page's
//! `/Annots`, and returns the widget `/Rect` in **page space**. The FFI layer applies the same
//! single Y-flip and `/Rotate` transform it applies to annotations, so the shell sees one
//! coordinate convention for both.
//!
//! # Writing
//!
//! The update is an incremental revision: the field and widget dictionaries are cloned into the
//! new revision, `/V` and `/AS` are set, and a real appearance stream is generated for the new
//! value. The original bytes stay the file's prefix and every page, annotation and unaffected
//! field is left byte-for-byte alone. The file-safety contract (temporary file, verified
//! prefix, reopen-and-verify, backup for a replace, atomic rename) is
//! [`crate::writeback::save_incremental_with_contract`], the same one `save_annotated_pdf`
//! uses.
//!
//! Widgets stay interactive: the writer never calls a flattening API and never removes
//! `/AcroForm`, `/Fields`, the widget dictionaries or their `/AP`. What it does add is the
//! appearance a viewer draws when it does not synthesize one from `/V` and `/DA`, which is what
//! makes the same saved file show its values in PDFKit, Poppler and Ghostscript.
//!
//! # Encrypted documents
//!
//! An encrypted file is refused before anything is written. Filling would have to re-encrypt the
//! new objects and rewrite the security envelope; a reader that "tries anyway" writes a file
//! that other viewers reject. The refusal names the reason and leaves the original untouched.
//!
//! # Limits
//!
//! Push buttons are not forms the reader fills and are skipped. Signature fields are reported as
//! a distinct, non-editable kind. Choice fields are single-select in this build (the widget and
//! `/V` are preserved for a multi-select field, but the editor chooses one item).

use crate::geometry_write::{EmbeddedFreeTextFont, build_appearance_font};
use crate::writeback::{IncrementalSaveReport, SaveMode, save_incremental_with_contract};
use lopdf::{
    Dictionary, Document, IncrementalDocument, LoadOptions, Object, ObjectId, Stream, StringFormat,
};
use lyra_reader_core::{ErrorCode, LyraReaderError, Rect, Result};
use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

/// The kinds of field this reader understands. A push button is deliberately absent: it is a
/// control, not a value, and drawing it as an editable field would promise an edit that has no
/// meaning in a filled form.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FormFieldKind {
    Text,
    CheckBox,
    Radio,
    ComboBox,
    ListBox,
    /// A signature field: shown as a distinct, non-editable box.
    Signature,
}

impl FormFieldKind {
    /// Stable machine name across the FFI, used by the shell and the checks.
    pub fn code(self) -> &'static str {
        match self {
            Self::Text => "text",
            Self::CheckBox => "checkBox",
            Self::Radio => "radio",
            Self::ComboBox => "comboBox",
            Self::ListBox => "listBox",
            Self::Signature => "signature",
        }
    }

    fn is_choice(self) -> bool {
        matches!(self, Self::ComboBox | Self::ListBox)
    }
}

/// One widget of a field, in **PDF page space** (points, bottom-left origin).
#[derive(Clone, Debug, PartialEq)]
pub struct FormWidget {
    /// 0-based page index.
    pub page: u32,
    /// `/Rect`, normalised to a positive width and height.
    pub rect: Rect,
    /// `/AS`, or the field value when the widget states none. Empty for a text widget.
    pub state: String,
    pub(crate) object_id: ObjectId,
}

/// One option of a choice or radio field: the value written to `/V` and the label shown.
#[derive(Clone, Debug, PartialEq)]
pub struct FormOption {
    pub value: String,
    pub label: String,
}

/// One AcroForm field.
#[derive(Clone, Debug, PartialEq)]
pub struct FormField {
    /// Stable identity for this save: `f<object number>` of the field dictionary.
    pub id: String,
    /// Fully-qualified `/T` name (`person.name` for a child field).
    pub name: String,
    pub kind: FormFieldKind,
    /// The field's `/V` for text and choice fields, or the selected state name for a button.
    pub value: Option<String>,
    /// Selected option indices. Empty for text, checkbox and signature fields.
    pub selected: Vec<u32>,
    /// `/V`/`/AS` says the check box is on.
    pub checked: bool,
    pub widgets: Vec<FormWidget>,
    pub options: Vec<FormOption>,
    /// False for a signature field, a read-only field and a field with no editable kind.
    pub editable: bool,
    pub multiline: bool,
    pub max_length: Option<u32>,
    /// `/DA`'s font size, or the AcroForm default, or 12 when nothing states one.
    pub font_size: f64,
    pub required: bool,
    pub(crate) object_id: ObjectId,
}

impl FormField {
    /// The page of the first widget, for the shell's "which page is this field on" question.
    pub fn page(&self) -> Option<u32> {
        self.widgets.first().map(|widget| widget.page)
    }
}

/// The form facts and fields read from a document.
#[derive(Clone, Debug, PartialEq)]
pub struct FormDocument {
    pub fields: Vec<FormField>,
    pub encrypted: bool,
    /// The file header's version, e.g. `1.7`.
    pub pdf_version: String,
    pub page_count: u32,
    /// Page annotation counts, used by the save verification to prove that nothing outside the
    /// field dictionaries moved.
    pub annotation_counts: Vec<usize>,
}

/// One requested field value.
#[derive(Clone, Debug, PartialEq)]
pub struct FormValueUpdate {
    pub field_id: String,
    /// The new text for a text field, or the chosen option's label/value for a choice field.
    pub text: Option<String>,
    /// The new state of a check box.
    pub checked: Option<bool>,
    /// The chosen option index for a radio group or a choice field.
    pub selected: Option<u32>,
}

/// What a successful form save did.
#[derive(Clone, Debug, PartialEq)]
pub struct FormSaveReport {
    pub destination: PathBuf,
    pub written_fields: Vec<String>,
    pub appended_bytes: u64,
    pub backup_path: Option<PathBuf>,
    pub cleaned_temporaries: usize,
    pub source_bytes_preserved: bool,
}

/// `true` when the loaded file states `/Encrypt` or was decrypted with a password.
pub(crate) fn document_is_encrypted(document: &Document) -> bool {
    document.was_encrypted() || document.is_encrypted()
}

/// Loads a PDF for dictionary access. The password is the one the shell opened the document
/// with; a file that needs a different one is reported as encrypted, not corrupt.
pub(crate) fn load_document(path: &Path, password: Option<&str>) -> Result<Document> {
    let options = LoadOptions {
        password: password.map(str::to_owned),
        ..LoadOptions::default()
    };
    Document::load_with_options(path, options).map_err(|error| match error {
        lopdf::Error::InvalidPassword => {
            LyraReaderError::new(ErrorCode::Encrypted, "the document is password protected")
                .with_detail(format!("path: {}", path.display()))
        }
        _ => LyraReaderError::new(
            ErrorCode::CorruptDocument,
            "could not read the document's form dictionaries",
        )
        .with_detail(format!("path: {} → {error}", path.display())),
    })
}

/// The PDF version from the header (`%PDF-x.y`), independent of whether the document loads.
pub(crate) fn pdf_header_version(path: &Path) -> String {
    let mut bytes = [0u8; 1024];
    let read = fs::File::open(path)
        .and_then(|mut file| std::io::Read::read(&mut file, &mut bytes))
        .unwrap_or(0);
    let header = String::from_utf8_lossy(&bytes[..read]);
    header
        .find("%PDF-")
        .map(|start| {
            header[start + 5..]
                .chars()
                .take_while(|character| character.is_ascii_digit() || *character == '.')
                .collect::<String>()
        })
        .filter(|version| !version.is_empty())
        .unwrap_or_else(|| "unknown".to_string())
}

/// Follows references to the object they name.
pub(crate) fn resolve<'a>(document: &'a Document, object: &'a Object) -> Option<&'a Object> {
    let mut current = object;
    for _ in 0..32 {
        match current {
            Object::Reference(id) => current = document.get_object(*id).ok()?,
            _ => return Some(current),
        }
    }
    None
}

/// A dictionary entry, dereferenced.
pub(crate) fn dict_get<'a>(
    document: &'a Document,
    dictionary: &'a Dictionary,
    key: &[u8],
) -> Option<&'a Object> {
    dictionary
        .get(key)
        .ok()
        .and_then(|object| resolve(document, object))
}

pub(crate) fn as_dictionary<'a>(
    document: &'a Document,
    dictionary: &'a Dictionary,
    key: &[u8],
) -> Option<&'a Dictionary> {
    dict_get(document, dictionary, key).and_then(|object| object.as_dict().ok())
}

pub(crate) fn as_array<'a>(
    document: &'a Document,
    dictionary: &'a Dictionary,
    key: &[u8],
) -> Option<&'a Vec<Object>> {
    dict_get(document, dictionary, key).and_then(|object| object.as_array().ok())
}

pub(crate) fn as_name(document: &Document, dictionary: &Dictionary, key: &[u8]) -> Option<String> {
    dict_get(document, dictionary, key)
        .and_then(|object| object.as_name().ok())
        .map(|name| String::from_utf8_lossy(name).into_owned())
}

/// A PDF text string: UTF-16BE with a BOM, or PDFDocEncoding (treated as Windows-1252, which
/// agrees with it for every character this reader can display).
pub(crate) fn decode_text_string(bytes: &[u8]) -> String {
    if let Some(rest) = bytes.strip_prefix(&[0xFE, 0xFF]) {
        let units: Vec<u16> = rest
            .as_chunks::<2>()
            .0
            .iter()
            .map(|pair| u16::from_be_bytes(*pair))
            .collect();
        String::from_utf16_lossy(&units)
    } else {
        bytes
            .iter()
            .map(|byte| {
                if *byte < 0x80 {
                    char::from(*byte)
                } else {
                    // Windows-1252's 0x80–0x9F block differs from Latin-1; the characters below
                    // are the ones that occur in metadata and form values in practice.
                    match *byte {
                        0x80 => '€',
                        0x82 => '‚',
                        0x83 => 'ƒ',
                        0x84 => '„',
                        0x85 => '…',
                        0x86 => '†',
                        0x87 => '‡',
                        0x88 => 'ˆ',
                        0x89 => '‰',
                        0x8A => 'Š',
                        0x8B => '‹',
                        0x8C => 'Œ',
                        0x8E => 'Ž',
                        0x91 => '‘',
                        0x92 => '’',
                        0x93 => '“',
                        0x94 => '”',
                        0x95 => '•',
                        0x96 => '–',
                        0x97 => '—',
                        0x98 => '˜',
                        0x99 => '™',
                        0x9A => 'š',
                        0x9B => '›',
                        0x9C => 'œ',
                        0x9E => 'ž',
                        0x9F => 'Ÿ',
                        _ => char::from(*byte),
                    }
                }
            })
            .collect()
    }
}

/// The PDF object for a text string: literal ASCII, hex UTF-16BE otherwise.
pub(crate) fn text_string_object(value: &str) -> Object {
    if value.is_ascii() {
        Object::String(value.as_bytes().to_vec(), StringFormat::Literal)
    } else {
        let mut bytes = vec![0xFE, 0xFF];
        for unit in value.encode_utf16() {
            bytes.extend_from_slice(&unit.to_be_bytes());
        }
        Object::String(bytes, StringFormat::Hexadecimal)
    }
}

fn read_string_object(object: &Object) -> Option<String> {
    match object {
        Object::String(bytes, _) => Some(decode_text_string(bytes)),
        Object::Name(bytes) => Some(String::from_utf8_lossy(bytes).into_owned()),
        _ => None,
    }
}

fn inherited<'a>(document: &'a Document, field: &'a Dictionary, key: &[u8]) -> Option<&'a Object> {
    let mut current = field;
    for _ in 0..64 {
        if let Some(object) = dict_get(document, current, key) {
            return Some(object);
        }
        current = as_dictionary(document, current, b"Parent")?;
    }
    None
}

fn inherited_string(document: &Document, field: &Dictionary, key: &[u8]) -> Option<String> {
    inherited(document, field, key).and_then(read_string_object)
}

fn rect_from_object(document: &Document, object: &Object) -> Option<Rect> {
    let array = resolve(document, object)?.as_array().ok()?;
    if array.len() < 4 {
        return None;
    }
    let mut values = [0.0f64; 4];
    for (index, value) in values.iter_mut().enumerate() {
        *value = resolve(document, &array[index])?.as_float().ok()? as f64;
    }
    let x = values[0].min(values[2]);
    let y = values[1].min(values[3]);
    let width = (values[2] - values[0]).abs();
    let height = (values[3] - values[1]).abs();
    if !x.is_finite() || !y.is_finite() || width <= 0.0 || height <= 0.0 {
        return None;
    }
    Some(Rect::new(x, y, width, height))
}

fn font_size_from_da(da: &str) -> Option<f64> {
    let tokens: Vec<&str> = da.split_whitespace().collect();
    for window in tokens.windows(2) {
        if window[1] == "Tf"
            && let Ok(size) = window[0].parse::<f64>()
            && (4.0..=400.0).contains(&size)
        {
            return Some(size);
        }
    }
    None
}

/// A widget's on-state names, read from `/AP /N` (the keys other than `/Off`).
fn on_states(document: &Document, widget: &Dictionary) -> Vec<String> {
    let Some(normal) =
        as_dictionary(document, widget, b"AP").and_then(|ap| as_dictionary(document, ap, b"N"))
    else {
        return Vec::new();
    };
    normal
        .iter()
        .filter_map(|(name, _)| {
            let name = String::from_utf8_lossy(name).into_owned();
            (name != "Off").then_some(name)
        })
        .collect()
}

fn read_options(document: &Document, field: &Dictionary) -> Vec<FormOption> {
    let Some(array) = inherited(document, field, b"Opt").and_then(|object| object.as_array().ok())
    else {
        return Vec::new();
    };
    let mut options = Vec::new();
    for entry in array {
        let Some(entry) = resolve(document, entry) else {
            continue;
        };
        if let Ok(bytes) = entry.as_str() {
            let value = decode_text_string(bytes);
            options.push(FormOption {
                value: value.clone(),
                label: value,
            });
        } else if let Ok(pair) = entry.as_array()
            && !pair.is_empty()
        {
            let value = resolve(document, &pair[0])
                .and_then(read_string_object)
                .unwrap_or_default();
            let label = pair
                .get(1)
                .and_then(|object| resolve(document, object))
                .and_then(read_string_object)
                .unwrap_or_else(|| value.clone());
            options.push(FormOption { value, label });
        }
    }
    options
}

fn widget_state(document: &Document, widget: &Dictionary) -> Option<String> {
    as_name(document, widget, b"AS")
}

fn field_value(document: &Document, field: &Dictionary) -> Option<String> {
    inherited(document, field, b"V").and_then(read_string_object)
}

fn selected_indices(document: &Document, field: &Dictionary) -> Vec<u32> {
    let from_indices = inherited(document, field, b"I")
        .and_then(|object| object.as_array().ok())
        .and_then(|array| {
            let indices: Vec<u32> = array
                .iter()
                .filter_map(|object| {
                    resolve(document, object)
                        .and_then(|object| object.as_i64().ok())
                        .and_then(|index| u32::try_from(index).ok())
                })
                .collect();
            (!indices.is_empty()).then_some(indices)
        });
    let options = read_options(document, field);
    let from_value = field_value(document, field).and_then(|value| {
        options
            .iter()
            .position(|option| option.value == value || option.label == value)
            .map(|index| vec![index as u32])
    });
    match (from_indices, from_value) {
        // `/V` is what the field says it holds. `/I` can be stale in files written by
        // producers that update the value and the appearance but not the index array (PDFKit
        // does exactly that); the value is what another viewer displays, so it wins.
        (Some(indices), Some(values)) if indices != values => values,
        (Some(indices), _) => indices,
        (None, Some(values)) => values,
        (None, None) => Vec::new(),
    }
}

/// Maps every widget object to its page, through each page's `/Annots`.
fn widget_pages(document: &Document) -> HashMap<ObjectId, u32> {
    let mut pages = HashMap::new();
    for (page_number, page_id) in document.get_pages() {
        let Ok(page) = document.get_dictionary(page_id) else {
            continue;
        };
        let Some(annots) = as_array(document, page, b"Annots") else {
            continue;
        };
        for object in annots {
            if let Object::Reference(id) = object {
                pages.entry(*id).or_insert(page_number.saturating_sub(1));
            }
        }
    }
    pages
}

fn local_text(document: &Document, dictionary: &Dictionary, key: &[u8]) -> Option<String> {
    dict_get(document, dictionary, key).and_then(read_string_object)
}

fn parent_id(document: &Document, dictionary: &Dictionary) -> Option<ObjectId> {
    dictionary
        .get(b"Parent")
        .ok()
        .and_then(|object| object.as_reference().ok())
        .filter(|id| document.get_dictionary(*id).is_ok())
}

/// The object of the terminal field a widget belongs to.
///
/// Producers disagree about where the field dictionary lives. This reader accepts both shapes:
///
/// * a **merged** field+widget, where the page annotation carries `/FT`, `/T` and `/V` itself
///   (the shape `scripts/make-fixtures.py` writes, and the one PDFKit leaves on the page even
///   when it also copies the field into `/AcroForm`);
/// * a field dictionary with widget `/Kids`, where the page annotation has `/Parent` and the
///   value lives on the parent (radio groups; most producer-written text fields).
///
/// The nearest ancestor with a `/T` is the terminal field; when no ancestor has one, the nearest
/// with `/FT` is used (a malformed file where the name was dropped still has a fillable value).
fn field_owner(document: &Document, widget_id: ObjectId, widget: &Dictionary) -> Option<ObjectId> {
    if local_text(document, widget, b"T").is_some() {
        return Some(widget_id);
    }
    let mut current = widget;
    let mut with_ft = if dict_get(document, current, b"FT").is_some() {
        Some(widget_id)
    } else {
        None
    };
    for _ in 0..64 {
        let Some(parent) = parent_id(document, current) else {
            break;
        };
        let parent_dictionary = document.get_dictionary(parent).ok()?;
        if local_text(document, parent_dictionary, b"T").is_some() {
            return Some(parent);
        }
        if with_ft.is_none() && dict_get(document, parent_dictionary, b"FT").is_some() {
            with_ft = Some(parent);
        }
        current = parent_dictionary;
    }
    with_ft
}

/// The fully-qualified `/T` name, built from the terminal field up through its `/Parent` chain.
fn qualified_name(document: &Document, field: &Dictionary) -> String {
    let mut parts: Vec<String> = Vec::new();
    let mut current = field;
    for _ in 0..64 {
        if let Some(part) = local_text(document, current, b"T")
            && !part.is_empty()
        {
            parts.push(part);
        }
        let Some(parent) = parent_id(document, current) else {
            break;
        };
        let Ok(dictionary) = document.get_dictionary(parent) else {
            break;
        };
        current = dictionary;
    }
    parts.reverse();
    parts.join(".")
}

/// A field key, inherited through `/Parent`, falling back to the first widget. This is what makes
/// a PDFKit-written radio group work: the parent field has `/FT /Btn` and `/Opt`, while `/Ff`
/// and `/DA` sit on each widget.
fn attribute<'a>(
    document: &'a Document,
    field: &'a Dictionary,
    widget: Option<&'a Dictionary>,
    key: &[u8],
) -> Option<&'a Object> {
    inherited(document, field, key)
        .or_else(|| widget.and_then(|widget| dict_get(document, widget, key)))
}

fn attribute_name(
    document: &Document,
    field: &Dictionary,
    widget: Option<&Dictionary>,
    key: &[u8],
) -> Option<String> {
    attribute(document, field, widget, key)
        .and_then(|object| object.as_name().ok())
        .map(|name| String::from_utf8_lossy(name).into_owned())
}

fn attribute_string(
    document: &Document,
    field: &Dictionary,
    widget: Option<&Dictionary>,
    key: &[u8],
) -> Option<String> {
    attribute(document, field, widget, key).and_then(read_string_object)
}

fn attribute_integer(
    document: &Document,
    field: &Dictionary,
    widget: Option<&Dictionary>,
    key: &[u8],
) -> Option<i64> {
    attribute(document, field, widget, key).and_then(|object| object.as_i64().ok())
}

fn read_field_group(
    document: &Document,
    field_id: ObjectId,
    field: &Dictionary,
    widgets_in_group: &[(ObjectId, u32)],
    acroform_da: Option<&str>,
) -> Option<FormField> {
    let first_widget = widgets_in_group
        .first()
        .and_then(|(id, _)| document.get_dictionary(*id).ok());
    let ft = attribute_name(document, field, first_widget, b"FT")?;
    let flags = attribute_integer(document, field, first_widget, b"Ff").unwrap_or(0);
    let kind = match ft.as_str() {
        "Tx" => FormFieldKind::Text,
        "Btn" if flags & (1 << 15) != 0 => FormFieldKind::Radio,
        "Btn" if flags & (1 << 16) != 0 => return None,
        "Btn" => FormFieldKind::CheckBox,
        "Ch" if flags & (1 << 17) != 0 => FormFieldKind::ComboBox,
        "Ch" => FormFieldKind::ListBox,
        "Sig" => FormFieldKind::Signature,
        _ => return None,
    };

    let mut widgets = Vec::new();
    for (widget_id, page) in widgets_in_group {
        let Some(widget) = document.get_dictionary(*widget_id).ok() else {
            continue;
        };
        let Some(rect) = dict_get(document, widget, b"Rect")
            .and_then(|object| rect_from_object(document, object))
        else {
            continue;
        };
        widgets.push(FormWidget {
            page: *page,
            rect,
            state: widget_state(document, widget).unwrap_or_default(),
            object_id: *widget_id,
        });
    }
    widgets.sort_by(|left, right| {
        left.page
            .cmp(&right.page)
            .then_with(|| right.rect.max_y().total_cmp(&left.rect.max_y()))
            .then_with(|| left.rect.min_x().total_cmp(&right.rect.min_x()))
    });
    if widgets.is_empty() {
        return None;
    }

    let value = attribute(document, field, first_widget, b"V").and_then(read_string_object);
    let mut options = read_options(document, field);
    let selected = if kind.is_choice() {
        selected_indices(document, field)
    } else if kind == FormFieldKind::Radio {
        if options.is_empty() {
            for (index, widget) in widgets.iter().enumerate() {
                let states = document
                    .get_dictionary(widget.object_id)
                    .ok()
                    .map(|dictionary| on_states(document, dictionary))
                    .unwrap_or_default();
                let label = states
                    .first()
                    .cloned()
                    .unwrap_or_else(|| format!("Option {}", index + 1));
                options.push(FormOption {
                    value: label.clone(),
                    label,
                });
            }
        }
        let chosen = value
            .clone()
            .filter(|value| !value.eq_ignore_ascii_case("Off"))
            .or_else(|| {
                widgets
                    .iter()
                    .find(|widget| !widget.state.is_empty() && widget.state != "Off")
                    .map(|widget| widget.state.clone())
            });
        if let Some(chosen) = chosen {
            if let Some(index) = widgets.iter().position(|widget| widget.state == chosen) {
                vec![index as u32]
            } else if let Some(index) = options
                .iter()
                .position(|option| option.value == chosen || option.label == chosen)
            {
                vec![index as u32]
            } else {
                Vec::new()
            }
        } else {
            Vec::new()
        }
    } else {
        Vec::new()
    };

    let checked = if kind == FormFieldKind::CheckBox {
        let state = value
            .as_deref()
            .or_else(|| {
                widgets
                    .first()
                    .map(|widget| widget.state.as_str())
                    .filter(|state| !state.is_empty())
            })
            .unwrap_or("Off");
        !state.eq_ignore_ascii_case("Off") && !state.is_empty()
    } else {
        false
    };

    let da = attribute_string(document, field, first_widget, b"DA")
        .or_else(|| acroform_da.map(str::to_owned));
    let font_size = da.as_deref().and_then(font_size_from_da).unwrap_or(12.0);

    Some(FormField {
        id: format!("f{}", field_id.0),
        name: {
            let name = qualified_name(document, field);
            if name.is_empty() {
                format!("Field {}", field_id.0)
            } else {
                name
            }
        },
        kind,
        value,
        selected,
        checked,
        widgets,
        options,
        editable: kind != FormFieldKind::Signature && flags & 1 == 0,
        multiline: kind == FormFieldKind::Text && flags & (1 << 12) != 0,
        max_length: attribute_integer(document, field, first_widget, b"MaxLen")
            .and_then(|value| u32::try_from(value).ok())
            .filter(|value| *value > 0),
        font_size,
        required: flags & (1 << 1) != 0,
        object_id: field_id,
    })
}

/// Reads every fillable field from an already-loaded document.
pub(crate) fn read_form_document_from(document: &Document) -> FormDocument {
    let pdf_version = if document.version.is_empty() {
        "unknown".to_string()
    } else {
        document.version.clone()
    };
    let pages = document.get_pages();
    let page_count = u32::try_from(pages.len()).unwrap_or(u32::MAX);
    let mut annotation_counts = vec![0usize; pages.len()];
    for (page_number, page_id) in &pages {
        if let Ok(page) = document.get_dictionary(*page_id)
            && let Some(annots) = as_array(document, page, b"Annots")
        {
            let index = page_number.saturating_sub(1) as usize;
            if index < annotation_counts.len() {
                annotation_counts[index] = annots.len();
            }
        }
    }
    let pages_map = widget_pages(document);
    let mut groups: BTreeMap<ObjectId, Vec<(ObjectId, u32)>> = BTreeMap::new();
    let mut seen_widgets: std::collections::HashSet<ObjectId> = std::collections::HashSet::new();
    for page_id in pages.values() {
        let Ok(page) = document.get_dictionary(*page_id) else {
            continue;
        };
        let Some(annots) = as_array(document, page, b"Annots") else {
            continue;
        };
        for annot in annots {
            let Object::Reference(widget_id) = annot else {
                continue;
            };
            if !seen_widgets.insert(*widget_id) {
                continue;
            }
            let Ok(widget) = document.get_dictionary(*widget_id) else {
                continue;
            };
            if as_name(document, widget, b"Subtype").as_deref() != Some("Widget") {
                continue;
            }
            let Some(owner) = field_owner(document, *widget_id, widget) else {
                continue;
            };
            let Some(page) = pages_map.get(widget_id).copied() else {
                continue;
            };
            groups.entry(owner).or_default().push((*widget_id, page));
        }
    }

    let catalog = document.catalog().ok();
    let acroform = catalog.and_then(|catalog| as_dictionary(document, catalog, b"AcroForm"));
    let acroform_da = acroform.and_then(|acroform| inherited_string(document, acroform, b"DA"));
    let mut fields = Vec::new();
    for (field_id, widgets_in_group) in groups {
        let Ok(field) = document.get_dictionary(field_id) else {
            continue;
        };
        if let Some(field) = read_field_group(
            document,
            field_id,
            field,
            &widgets_in_group,
            acroform_da.as_deref(),
        ) {
            fields.push(field);
        }
    }
    fields.sort_by(|left, right| {
        let left_page = left.page().unwrap_or(u32::MAX);
        let right_page = right.page().unwrap_or(u32::MAX);
        let left_rect = left.widgets.first().map(|widget| widget.rect);
        let right_rect = right.widgets.first().map(|widget| widget.rect);
        left_page
            .cmp(&right_page)
            .then_with(|| {
                right_rect
                    .map(|rect| rect.max_y())
                    .unwrap_or(0.0)
                    .total_cmp(&left_rect.map(|rect| rect.max_y()).unwrap_or(0.0))
            })
            .then_with(|| {
                left_rect
                    .map(|rect| rect.min_x())
                    .unwrap_or(0.0)
                    .total_cmp(&right_rect.map(|rect| rect.min_x()).unwrap_or(0.0))
            })
            .then_with(|| left.object_id.0.cmp(&right.object_id.0))
    });
    FormDocument {
        fields,
        encrypted: document_is_encrypted(document),
        pdf_version,
        page_count,
        annotation_counts,
    }
}

/// Reads a document's form fields and facts.
///
/// The fields are in page space. An encrypted document is still readable when the caller has
/// its password; [`save_form_pdf`] refuses to write it.
pub fn read_form_document(path: &Path, password: Option<&str>) -> Result<FormDocument> {
    let document = load_document(path, password)?;
    Ok(read_form_document_from(&document))
}

/// Rejects a form save before any bytes are produced.
fn validate_updates(form: &FormDocument, updates: &[FormValueUpdate]) -> Result<()> {
    if updates.is_empty() {
        return Err(LyraReaderError::new(
            ErrorCode::InvalidArgument,
            "there are no form values to save",
        ));
    }
    if form.encrypted {
        return Err(LyraReaderError::new(
            ErrorCode::Encrypted,
            "this PDF is encrypted, so the reader will not fill it",
        )
        .with_detail(
            "writing a form value would add objects to an encrypted file; the security envelope \
             is not rewritten here, and a file written anyway might not open in another viewer"
                .to_string(),
        ));
    }
    let mut seen = std::collections::HashSet::new();
    for update in updates {
        if !seen.insert(update.field_id.clone()) {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                format!("two updates name the same field {:?}", update.field_id),
            ));
        }
        let Some(field) = form.fields.iter().find(|field| field.id == update.field_id) else {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                format!("no form field has the identity {:?}", update.field_id),
            ));
        };
        if !field.editable {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                format!("the field {:?} is not editable", field.name),
            ));
        }
        if let Some(text) = &update.text
            && (text.len() > 100_000 || text.contains('\0'))
        {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                format!("the field {:?} has invalid text", field.name),
            ));
        }
        match field.kind {
            FormFieldKind::Text => {
                if update.text.is_none() || update.checked.is_some() || update.selected.is_some() {
                    return Err(LyraReaderError::new(
                        ErrorCode::InvalidArgument,
                        format!("the text field {:?} needs only a text value", field.name),
                    ));
                }
            }
            FormFieldKind::CheckBox => {
                if update.checked.is_none() || update.text.is_some() || update.selected.is_some() {
                    return Err(LyraReaderError::new(
                        ErrorCode::InvalidArgument,
                        format!("the check box {:?} needs only a checked value", field.name),
                    ));
                }
            }
            FormFieldKind::Radio | FormFieldKind::ComboBox | FormFieldKind::ListBox => {
                let Some(index) = update.selected else {
                    return Err(LyraReaderError::new(
                        ErrorCode::InvalidArgument,
                        format!("the field {:?} needs a selected option", field.name),
                    ));
                };
                if index as usize >= field.options.len() {
                    return Err(LyraReaderError::new(
                        ErrorCode::InvalidArgument,
                        format!(
                            "the field {:?} has {} option(s), not {}",
                            field.name,
                            field.options.len(),
                            index + 1
                        ),
                    ));
                }
                if update.checked.is_some() {
                    return Err(LyraReaderError::new(
                        ErrorCode::InvalidArgument,
                        format!("the field {:?} is not a check box", field.name),
                    ));
                }
                if field.kind.is_choice() && update.text.is_some() {
                    let text = update.text.as_deref().unwrap_or("");
                    let option = &field.options[index as usize];
                    if text != option.value && text != option.label {
                        return Err(LyraReaderError::new(
                            ErrorCode::InvalidArgument,
                            format!(
                                "the choice {:?} option {:?} does not have the value {:?}",
                                field.name, option.label, text
                            ),
                        ));
                    }
                }
            }
            FormFieldKind::Signature => {
                return Err(LyraReaderError::new(
                    ErrorCode::InvalidArgument,
                    format!("the signature field {:?} cannot be filled", field.name),
                ));
            }
        }
    }
    Ok(())
}

fn clone_dictionary(incremental: &mut IncrementalDocument, id: ObjectId) -> Result<()> {
    incremental
        .opt_clone_object_to_new_document(id)
        .map_err(|error| {
            LyraReaderError::new(ErrorCode::CorruptDocument, "could not copy a form object")
                .with_detail(error.to_string())
        })
}

fn dictionary_mut(incremental: &mut IncrementalDocument, id: ObjectId) -> Result<&mut Dictionary> {
    incremental
        .new_document
        .get_object_mut(id)
        .map_err(|error| {
            LyraReaderError::new(ErrorCode::CorruptDocument, "a form object is missing")
                .with_detail(error.to_string())
        })?
        .as_dict_mut()
        .map_err(|error| {
            LyraReaderError::new(
                ErrorCode::CorruptDocument,
                "a form object is not a dictionary",
            )
            .with_detail(error.to_string())
        })
}

fn add_stream(incremental: &mut IncrementalDocument, stream: Stream) -> ObjectId {
    incremental.new_document.add_object(Object::Stream(stream))
}

fn stream_for_appearance(
    content: Vec<u8>,
    width: f64,
    height: f64,
    font: Option<ObjectId>,
) -> Stream {
    let mut dictionary = Dictionary::new();
    dictionary.set("Type", Object::Name(b"XObject".to_vec()));
    dictionary.set("Subtype", Object::Name(b"Form".to_vec()));
    dictionary.set(
        "BBox",
        Object::Array(vec![
            Object::Real(0.0),
            Object::Real(0.0),
            Object::Real(width.max(0.01) as f32),
            Object::Real(height.max(0.01) as f32),
        ]),
    );
    if let Some(font) = font {
        let mut fonts = Dictionary::new();
        fonts.set("F1", Object::Reference(font));
        let mut resources = Dictionary::new();
        resources.set("Font", Object::Dictionary(fonts));
        dictionary.set("Resources", Object::Dictionary(resources));
    }
    let mut stream = Stream::new(dictionary, content);
    stream.allows_compression = false;
    stream
}

fn widget_size(widget: &FormWidget) -> (f64, f64) {
    (widget.rect.size.width, widget.rect.size.height)
}

/// A widget's field text, with the same white box and grey border the reader draws.
fn text_appearance(
    widget: &FormWidget,
    text: &str,
    font: Option<&EmbeddedFreeTextFont>,
    options: Option<(&[FormOption], Option<u32>)>,
) -> Vec<u8> {
    let (width, height) = widget_size(widget);
    let mut content = String::from("q\n1 1 1 rg\n0.45 0.45 0.45 RG\n0.6 w\n");
    content.push_str(&format!(
        "0.3 0.3 {:.3} {:.3} re B\n",
        (width - 0.6).max(0.01),
        (height - 0.6).max(0.01)
    ));
    if let Some((options, selected)) = options {
        let row = (height / options.len().max(1) as f64).min(22.0);
        for (index, option) in options.iter().enumerate() {
            let top = height - row * (index + 1) as f64;
            if Some(index as u32) == selected {
                content.push_str(&format!(
                    "0.80 0.88 0.98 rg\n1 {:.3} {:.3} {:.3} re f\n0 0 0 rg\n",
                    top + 0.5,
                    (width - 2.0).max(0.01),
                    (row - 1.0).max(0.01)
                ));
            }
            if let Some(font) = font {
                content.push_str(&format!(
                    "BT\n/F1 {:.3} Tf\n0 0 0 rg\n1 0 0 1 4 {:.3} Tm\n{} Tj\nET\n",
                    font_size_for_row(row),
                    top + 5.5,
                    font.subset.hex_string(&option.label)
                ));
            }
        }
    } else if !text.is_empty()
        && let Some(font) = font
    {
        let size = 11.0_f64.min((height - 4.0).max(6.0));
        let lines = wrap_lines(text, size, (width - 8.0).max(1.0), font);
        let mut baseline = height - size - 3.0;
        for line in lines {
            if baseline < 2.0 {
                break;
            }
            content.push_str(&format!(
                "BT\n/F1 {:.3} Tf\n0 0 0 rg\n1 0 0 1 4 {:.3} Tm\n{} Tj\nET\n",
                size,
                baseline,
                font.subset.hex_string(&line)
            ));
            baseline -= size * 1.2;
        }
    }
    content.push_str("Q\n");
    content.into_bytes()
}

fn font_size_for_row(row: f64) -> f64 {
    (row - 6.0).clamp(6.0, 11.0)
}

fn wrap_lines(text: &str, size: f64, width: f64, font: &EmbeddedFreeTextFont) -> Vec<String> {
    let mut lines = Vec::new();
    for paragraph in text.replace('\r', "\n").split('\n') {
        let characters: Vec<char> = paragraph.chars().collect();
        let mut line = String::new();
        for character in characters {
            let mut candidate = line.clone();
            candidate.push(character);
            if font.subset.text_width(&candidate, size) > width && !line.is_empty() {
                lines.push(line);
                line = character.to_string();
            } else {
                line = candidate;
            }
        }
        lines.push(line);
    }
    lines
}

fn checkbox_appearance(width: f64, height: f64, on: bool) -> Vec<u8> {
    let mut content = String::from("q\n1 1 1 rg\n0.35 0.35 0.35 RG\n0.8 w\n");
    content.push_str(&format!(
        "0.8 0.8 {:.3} {:.3} re S\n",
        (width - 1.6).max(0.01),
        (height - 1.6).max(0.01)
    ));
    if on {
        content.push_str(&format!(
            "0 0 0 RG\n1.6 w\n{:.3} {:.3} m {:.3} {:.3} l {:.3} {:.3} l S\n",
            width * 0.22,
            height * 0.52,
            width * 0.42,
            height * 0.30,
            width * 0.78,
            height * 0.72
        ));
    }
    content.push_str("Q\n");
    content.into_bytes()
}

fn radio_appearance(width: f64, height: f64, on: bool) -> Vec<u8> {
    let radius = (width.min(height) / 2.0 - 1.0).max(1.0);
    let (cx, cy) = (width / 2.0, height / 2.0);
    let k = 0.5523 * radius;
    let right = cx + radius;
    let left = cx - radius;
    let top = cy + radius;
    let bottom = cy - radius;
    let mut content = format!(
        "q\n1 1 1 rg\n0.35 0.35 0.35 RG\n0.8 w\n\
         {right:.3} {cy:.3} m \
         {right:.3} {:.3} {:.3} {top:.3} {cx:.3} {top:.3} c \
         {:.3} {top:.3} {left:.3} {:.3} {left:.3} {cy:.3} c \
         {left:.3} {:.3} {:.3} {bottom:.3} {cx:.3} {bottom:.3} c \
         {:.3} {bottom:.3} {right:.3} {:.3} {right:.3} {cy:.3} c S\n",
        cy + k,
        cx + k,
        cx - k,
        cy + k,
        cy - k,
        cx - k,
        cx + k,
        cy - k,
    );
    if on {
        let inner = (radius - 4.0).max(1.5);
        let ik = 0.5523 * inner;
        content.push_str(&format!(
            "0 0 0 rg\n{cx:.3} {:.3} m \
             {:.3} {:.3} {:.3} {:.3} {cx:.3} {:.3} c \
             {:.3} {:.3} {:.3} {:.3} {cx:.3} {:.3} c \
             {:.3} {:.3} {:.3} {:.3} {cx:.3} {:.3} c \
             {:.3} {:.3} {:.3} {:.3} {cx:.3} {cy:.3} c f\n",
            cy + inner,
            cx + inner,
            cy + ik,
            cx + ik,
            cy + inner,
            cy + inner,
            cx - ik,
            cy + inner,
            cx - inner,
            cy + ik,
            cy + inner,
            cx - inner,
            cy - ik,
            cx - ik,
            cy - inner,
            cy - inner,
            cx + ik,
            cy - inner,
            cx + inner,
            cy - ik,
        ));
    }
    content.push_str("Q\n");
    content.into_bytes()
}

fn set_widget_appearance(
    incremental: &mut IncrementalDocument,
    widget_id: ObjectId,
    stream: Stream,
) -> Result<()> {
    let stream_id = add_stream(incremental, stream);
    let widget = dictionary_mut(incremental, widget_id)?;
    let mut appearance = Dictionary::new();
    appearance.set("N", Object::Reference(stream_id));
    widget.set("AP", Object::Dictionary(appearance));
    Ok(())
}

fn set_widget_state_appearance(
    incremental: &mut IncrementalDocument,
    widget_id: ObjectId,
    on_name: &str,
    on_stream: Stream,
    off_stream: Stream,
) -> Result<()> {
    let on_id = add_stream(incremental, on_stream);
    let off_id = add_stream(incremental, off_stream);
    let mut normal = Dictionary::new();
    normal.set(on_name.as_bytes().to_vec(), Object::Reference(on_id));
    normal.set("Off", Object::Reference(off_id));
    let mut appearance = Dictionary::new();
    appearance.set("N", Object::Dictionary(normal));
    let widget = dictionary_mut(incremental, widget_id)?;
    widget.set("AP", Object::Dictionary(appearance));
    Ok(())
}

fn set_acroform_need_appearances(incremental: &mut IncrementalDocument) -> Result<()> {
    let catalog_id = incremental
        .get_prev_documents()
        .trailer
        .get(b"Root")
        .ok()
        .and_then(|object| object.as_reference().ok());
    let Some(catalog_id) = catalog_id else {
        return Ok(());
    };
    let acroform = incremental
        .get_prev_documents()
        .get_dictionary(catalog_id)
        .ok()
        .and_then(|catalog| {
            catalog
                .get(b"AcroForm")
                .ok()
                .and_then(|object| object.as_reference().ok())
        });
    if let Some(acroform_id) = acroform {
        clone_dictionary(incremental, acroform_id)?;
        let dictionary = dictionary_mut(incremental, acroform_id)?;
        dictionary.set("NeedAppearances", Object::Boolean(false));
    }
    Ok(())
}

fn apply_update(
    incremental: &mut IncrementalDocument,
    form: &FormDocument,
    update: &FormValueUpdate,
    font: Option<&EmbeddedFreeTextFont>,
) -> Result<()> {
    let field = form
        .fields
        .iter()
        .find(|field| field.id == update.field_id)
        .ok_or_else(|| {
            LyraReaderError::new(
                ErrorCode::Internal,
                "a validated form field disappeared before the write",
            )
        })?
        .clone();
    let previous = incremental.get_prev_documents();
    let widget_states: Vec<Vec<String>> = field
        .widgets
        .iter()
        .map(|widget| {
            previous
                .get_dictionary(widget.object_id)
                .ok()
                .map(|dictionary| on_states(previous, dictionary))
                .unwrap_or_default()
        })
        .collect();

    match field.kind {
        FormFieldKind::Text => {
            clone_dictionary(incremental, field.object_id)?;
            {
                let dictionary = dictionary_mut(incremental, field.object_id)?;
                dictionary.set(
                    "V",
                    text_string_object(update.text.as_deref().unwrap_or("")),
                );
            }
            for widget in &field.widgets {
                clone_dictionary(incremental, widget.object_id)?;
                let (width, height) = widget_size(widget);
                let stream = stream_for_appearance(
                    text_appearance(widget, update.text.as_deref().unwrap_or(""), font, None),
                    width,
                    height,
                    font.map(|font| font.type0),
                );
                set_widget_appearance(incremental, widget.object_id, stream)?;
            }
        }
        FormFieldKind::CheckBox => {
            let checked = update.checked.unwrap_or(false);
            let on_name = widget_states
                .first()
                .and_then(|states| states.first().cloned())
                .unwrap_or_else(|| "Yes".to_string());
            let state = if checked { on_name } else { "Off".to_string() };
            clone_dictionary(incremental, field.object_id)?;
            {
                let dictionary = dictionary_mut(incremental, field.object_id)?;
                dictionary.set("V", Object::Name(state.clone().into_bytes()));
            }
            for (index, widget) in field.widgets.iter().enumerate() {
                clone_dictionary(incremental, widget.object_id)?;
                {
                    let dictionary = dictionary_mut(incremental, widget.object_id)?;
                    dictionary.set("AS", Object::Name(state.clone().into_bytes()));
                }
                if widget_states[index].is_empty() {
                    let (width, height) = widget_size(widget);
                    let on_name = if state == "Off" { "Yes" } else { &state };
                    let on_stream = stream_for_appearance(
                        checkbox_appearance(width, height, checked),
                        width,
                        height,
                        None,
                    );
                    let off_stream = stream_for_appearance(
                        checkbox_appearance(width, height, false),
                        width,
                        height,
                        None,
                    );
                    set_widget_state_appearance(
                        incremental,
                        widget.object_id,
                        on_name,
                        on_stream,
                        off_stream,
                    )?;
                }
            }
        }
        FormFieldKind::Radio => {
            let selected = update.selected.unwrap_or(0) as usize;
            let states: Vec<String> = field
                .widgets
                .iter()
                .enumerate()
                .map(|(index, _widget)| {
                    widget_states
                        .get(index)
                        .and_then(|states| states.first().cloned())
                        .or_else(|| field.options.get(index).map(|option| option.value.clone()))
                        .unwrap_or_else(|| format!("Option{}", index + 1))
                })
                .collect();
            clone_dictionary(incremental, field.object_id)?;
            {
                let dictionary = dictionary_mut(incremental, field.object_id)?;
                let value = states
                    .get(selected)
                    .cloned()
                    .or_else(|| {
                        field
                            .options
                            .get(selected)
                            .map(|option| option.value.clone())
                    })
                    .unwrap_or_else(|| "Off".to_string());
                dictionary.set("V", Object::Name(value.into_bytes()));
            }
            for (index, widget) in field.widgets.iter().enumerate() {
                let state = if index == selected {
                    states
                        .get(index)
                        .cloned()
                        .unwrap_or_else(|| "Off".to_string())
                } else {
                    "Off".to_string()
                };
                clone_dictionary(incremental, widget.object_id)?;
                {
                    let dictionary = dictionary_mut(incremental, widget.object_id)?;
                    dictionary.set("AS", Object::Name(state.clone().into_bytes()));
                }
                if widget_states[index].is_empty() {
                    let (width, height) = widget_size(widget);
                    let on_name = states
                        .get(index)
                        .cloned()
                        .unwrap_or_else(|| "Yes".to_string());
                    let on_stream = stream_for_appearance(
                        radio_appearance(width, height, index == selected),
                        width,
                        height,
                        None,
                    );
                    let off_stream = stream_for_appearance(
                        radio_appearance(width, height, false),
                        width,
                        height,
                        None,
                    );
                    set_widget_state_appearance(
                        incremental,
                        widget.object_id,
                        &on_name,
                        on_stream,
                        off_stream,
                    )?;
                }
            }
        }
        FormFieldKind::ComboBox | FormFieldKind::ListBox => {
            let selected = update.selected.unwrap_or(0) as usize;
            let option = field.options.get(selected).cloned().ok_or_else(|| {
                LyraReaderError::new(
                    ErrorCode::InvalidArgument,
                    "the selected choice is no longer in the field",
                )
            })?;
            clone_dictionary(incremental, field.object_id)?;
            {
                let dictionary = dictionary_mut(incremental, field.object_id)?;
                dictionary.set("V", text_string_object(&option.value));
                dictionary.set("I", Object::Array(vec![Object::Integer(selected as i64)]));
            }
            let options = field.options.clone();
            for widget in &field.widgets {
                clone_dictionary(incremental, widget.object_id)?;
                let (width, height) = widget_size(widget);
                let stream = if field.kind == FormFieldKind::ListBox {
                    stream_for_appearance(
                        text_appearance(
                            widget,
                            &option.label,
                            font,
                            Some((options.as_slice(), Some(selected as u32))),
                        ),
                        width,
                        height,
                        font.map(|font| font.type0),
                    )
                } else {
                    let x = (width - 15.0).max(2.0);
                    let y = height / 2.0 + 2.0;
                    let chevron = format!(
                        "q 0.35 0.35 0.35 RG 1.2 w\n{x:.3} {y:.3} m {:.3} {:.3} l {:.3} {y:.3} l S Q\n",
                        x + 4.0,
                        y - 4.0,
                        x + 8.0
                    );
                    let mut content = text_appearance(widget, &option.label, font, None);
                    content.extend_from_slice(chevron.as_bytes());
                    // `/Length` is fixed by `Stream::new`; build the final bytes first, never by
                    // appending to `content` afterwards.
                    stream_for_appearance(content, width, height, font.map(|font| font.type0))
                };
                set_widget_appearance(incremental, widget.object_id, stream)?;
            }
        }
        FormFieldKind::Signature => {
            return Err(LyraReaderError::new(
                ErrorCode::InvalidArgument,
                "signature fields cannot be filled",
            ));
        }
    }
    Ok(())
}

/// Verifies that every update is in `after` and everything else is unchanged.
fn verify_saved_form(
    source: &Path,
    saved: &Path,
    before: &FormDocument,
    updates: &[FormValueUpdate],
    password: Option<&str>,
) -> Result<()> {
    let after = read_form_document(saved, password)?;
    if after.page_count != before.page_count || after.annotation_counts != before.annotation_counts
    {
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "the saved form changed the document's pages or annotations",
        )
        .with_detail(format!("{} → {}", source.display(), saved.display())));
    }
    if !after.encrypted {
        // The source was refused when encrypted, so `after` must be unencrypted too.
    }
    if after.fields.len() != before.fields.len() {
        return Err(LyraReaderError::new(
            ErrorCode::Internal,
            "the saved form gained or lost fields",
        ));
    }
    let before_by_id: BTreeMap<&str, &FormField> = before
        .fields
        .iter()
        .map(|field| (field.id.as_str(), field))
        .collect();
    let after_by_id: BTreeMap<&str, &FormField> = after
        .fields
        .iter()
        .map(|field| (field.id.as_str(), field))
        .collect();
    let update_by_id: HashMap<&str, &FormValueUpdate> = updates
        .iter()
        .map(|update| (update.field_id.as_str(), update))
        .collect();
    for (id, before_field) in before_by_id {
        let after_field = after_by_id.get(id).ok_or_else(|| {
            LyraReaderError::new(
                ErrorCode::Internal,
                "a field disappeared from the saved form",
            )
            .with_detail((*id).to_string())
        })?;
        if let Some(update) = update_by_id.get(id) {
            match before_field.kind {
                FormFieldKind::Text => {
                    let expected = update.text.clone().unwrap_or_default();
                    if after_field.value.as_deref() != Some(expected.as_str()) {
                        return Err(LyraReaderError::new(
                            ErrorCode::Internal,
                            "a filled text field does not read back its value",
                        )
                        .with_detail(format!("{id}: {:?}", after_field.value)));
                    }
                }
                FormFieldKind::CheckBox => {
                    if after_field.checked != update.checked.unwrap_or(false) {
                        return Err(LyraReaderError::new(
                            ErrorCode::Internal,
                            "a saved check box does not read back its state",
                        )
                        .with_detail((*id).to_string()));
                    }
                }
                FormFieldKind::Radio | FormFieldKind::ComboBox | FormFieldKind::ListBox => {
                    if after_field.selected.first().copied() != update.selected {
                        return Err(LyraReaderError::new(
                            ErrorCode::Internal,
                            "a saved choice does not read back its selection",
                        )
                        .with_detail(format!("{id}: {:?}", after_field.selected)));
                    }
                }
                FormFieldKind::Signature => {}
            }
        } else {
            if before_field.value != after_field.value
                || before_field.checked != after_field.checked
                || before_field.selected != after_field.selected
                || before_field.widgets.len() != after_field.widgets.len()
            {
                return Err(LyraReaderError::new(
                    ErrorCode::Internal,
                    "a form field the save did not ask for changed",
                )
                .with_detail(format!("{id}: {}", before_field.name)));
            }
            for (old, new) in before_field.widgets.iter().zip(&after_field.widgets) {
                if old.page != new.page || old.rect != new.rect {
                    return Err(LyraReaderError::new(
                        ErrorCode::Internal,
                        "a widget the save did not ask for moved",
                    )
                    .with_detail(format!("{id}: {}", before_field.name)));
                }
            }
        }
    }
    Ok(())
}

/// Writes `updates` into a copy (or, explicitly, the original) under the verified incremental
/// save contract.
///
/// The source bytes remain the output's prefix, every unfilled field and every annotation is
/// verified unchanged, and the replacement/rename is atomic. The widgets stay interactive.
pub fn save_form_pdf(
    source: &Path,
    destination: &Path,
    updates: &[FormValueUpdate],
    password: Option<&str>,
    mode: SaveMode,
) -> Result<FormSaveReport> {
    let base = load_document(source, password)?;
    if document_is_encrypted(&base) {
        return Err(LyraReaderError::new(
            ErrorCode::Encrypted,
            "this PDF is encrypted, so the reader will not fill it",
        )
        .with_detail(
            "the form values would have to be written into an encrypted file; the reader does \
             not rewrite the security envelope, and a file written without it might not open"
                .to_string(),
        ));
    }
    let before = read_form_document_from(&base);
    validate_updates(&before, updates)?;

    let mut appearance_texts: Vec<String> = Vec::new();
    for update in updates {
        if let Some(text) = &update.text {
            appearance_texts.push(text.clone());
        }
        if let Some(field) = before
            .fields
            .iter()
            .find(|field| field.id == update.field_id)
            && field.kind.is_choice()
        {
            appearance_texts.extend(field.options.iter().map(|option| option.label.clone()));
        }
    }
    let text_refs: Vec<&str> = appearance_texts.iter().map(String::as_str).collect();

    let previous_bytes = fs::read(source).map_err(|error| {
        LyraReaderError::new(
            ErrorCode::Io,
            "could not read the document before filling its form",
        )
        .with_detail(format!("{}: {error}", source.display()))
    })?;
    let mut incremental = IncrementalDocument::create_from(previous_bytes, base);
    let font = build_appearance_font(&mut incremental.new_document, &text_refs)?;
    for update in updates {
        apply_update(&mut incremental, &before, update, font.as_ref())?;
    }
    set_acroform_need_appearances(&mut incremental)?;

    let report: IncrementalSaveReport = save_incremental_with_contract(
        source,
        destination,
        mode,
        |file| {
            incremental.save_to(file).map_err(|error| {
                LyraReaderError::new(ErrorCode::Io, "could not write the form update")
                    .with_detail(error.to_string())
            })?;
            file.flush().map_err(|error| {
                LyraReaderError::new(ErrorCode::Io, "could not flush the form update")
                    .with_detail(error.to_string())
            })?;
            Ok(())
        },
        |temp| verify_saved_form(source, temp, &before, updates, password),
    )?;

    Ok(FormSaveReport {
        destination: report.destination,
        written_fields: updates
            .iter()
            .map(|update| update.field_id.clone())
            .collect(),
        appended_bytes: report.appended_bytes,
        backup_path: report.backup_path,
        cleaned_temporaries: report.cleaned_temporaries,
        source_bytes_preserved: report.source_bytes_preserved,
    })
}

/// The default output name for a filled copy: `<name> (filled).pdf`.
pub fn suggested_filled_copy_path(source: &Path) -> PathBuf {
    suggest(source, "filled")
}

pub(crate) fn suggest(source: &Path, suffix: &str) -> PathBuf {
    let stem = source
        .file_stem()
        .map(|stem| stem.to_string_lossy().into_owned())
        .unwrap_or_else(|| "document".to_string());
    let extension = source
        .extension()
        .map(|extension| extension.to_string_lossy().into_owned())
        .unwrap_or_else(|| "pdf".to_string());
    source.with_file_name(format!("{stem} ({suffix}).{extension}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{ScratchDir, fixture};

    fn form() -> FormDocument {
        read_form_document(&fixture("form-fields.pdf"), None).expect("read form fixture")
    }

    #[test]
    fn fixture_reports_every_kind_with_page_space_rects() {
        let form = form();
        assert!(!form.encrypted);
        assert_eq!(form.fields.len(), 8);
        let kinds: Vec<&str> = form.fields.iter().map(|field| field.kind.code()).collect();
        assert_eq!(
            kinds,
            vec![
                "text",
                "text",
                "checkBox",
                "radio",
                "comboBox",
                "listBox",
                "signature",
                "text"
            ]
        );
        let email = form
            .fields
            .iter()
            .find(|field| field.name == "email")
            .unwrap();
        assert_eq!(email.value.as_deref(), Some("prefilled@example.com"));
        assert_eq!(email.page(), Some(0));
        assert!((email.widgets[0].rect.origin.x - 72.0).abs() < 0.01);
        assert!((email.widgets[0].rect.size.width - 228.0).abs() < 0.01);
        let notes = form
            .fields
            .iter()
            .find(|field| field.name == "notes")
            .unwrap();
        assert_eq!(notes.page(), Some(1));
        assert!(notes.multiline);
        let signature = form
            .fields
            .iter()
            .find(|field| field.name == "signature")
            .unwrap();
        assert!(!signature.editable);
        let color = form
            .fields
            .iter()
            .find(|field| field.name == "color")
            .unwrap();
        assert_eq!(color.selected, vec![1]);
        assert_eq!(color.options[1].label, "Green");
        let interests = form
            .fields
            .iter()
            .find(|field| field.name == "interests")
            .unwrap();
        assert_eq!(interests.selected, vec![0]);
        assert_eq!(interests.options.len(), 3);
    }

    #[test]
    fn filled_copy_keeps_the_source_and_reads_back_every_value() {
        let scratch = ScratchDir::new("forms");
        let source = fixture("form-fields.pdf");
        let destination = scratch.join("filled.pdf");
        let form = form();
        let id = |name: &str| {
            form.fields
                .iter()
                .find(|field| field.name == name)
                .unwrap()
                .id
                .clone()
        };
        let updates = vec![
            FormValueUpdate {
                field_id: id("fullName"),
                text: Some("Ada Lovelace".into()),
                checked: None,
                selected: None,
            },
            FormValueUpdate {
                field_id: id("agree"),
                text: None,
                checked: Some(true),
                selected: None,
            },
            FormValueUpdate {
                field_id: id("color"),
                text: None,
                checked: None,
                selected: Some(2),
            },
            FormValueUpdate {
                field_id: id("country"),
                text: Some("Japan".into()),
                checked: None,
                selected: Some(1),
            },
            FormValueUpdate {
                field_id: id("interests"),
                text: Some("Running".into()),
                checked: None,
                selected: Some(1),
            },
            FormValueUpdate {
                field_id: id("notes"),
                text: Some("Written on page two.".into()),
                checked: None,
                selected: None,
            },
        ];
        let report = save_form_pdf(&source, &destination, &updates, None, SaveMode::Copy)
            .expect("save filled copy");
        assert!(report.source_bytes_preserved);
        assert!(report.appended_bytes > 0);
        assert_eq!(report.written_fields.len(), updates.len());
        let source_bytes = std::fs::read(&source).unwrap();
        let saved_bytes = std::fs::read(&destination).unwrap();
        assert_eq!(&saved_bytes[..source_bytes.len()], source_bytes.as_slice());
        let after = read_form_document(&destination, None).unwrap();
        let value = |name: &str| {
            after
                .fields
                .iter()
                .find(|field| field.name == name)
                .unwrap()
        };
        assert_eq!(value("fullName").value.as_deref(), Some("Ada Lovelace"));
        assert!(value("agree").checked);
        assert_eq!(value("color").selected, vec![2]);
        assert_eq!(value("country").value.as_deref(), Some("Japan"));
        assert_eq!(value("interests").selected, vec![1]);
        assert_eq!(
            value("notes").value.as_deref(),
            Some("Written on page two.")
        );
        // Untouched fields keep their values.
        assert_eq!(
            value("email").value.as_deref(),
            Some("prefilled@example.com")
        );
    }

    #[test]
    fn encrypted_file_is_refused_before_anything_is_written() {
        let scratch = ScratchDir::new("forms");
        let source = fixture("form-fields-encrypted.pdf");
        let destination = scratch.join("filled.pdf");
        let form = form();
        let error = save_form_pdf(
            &source,
            &destination,
            &[FormValueUpdate {
                field_id: form.fields[0].id.clone(),
                text: Some("nope".into()),
                checked: None,
                selected: None,
            }],
            None,
            SaveMode::Copy,
        )
        .expect_err("encrypted form must be refused");
        assert_eq!(error.code, ErrorCode::Encrypted);
        assert!(!destination.exists());
    }

    #[test]
    fn save_refuses_to_change_an_unasked_field() {
        let form = form();
        let update = FormValueUpdate {
            field_id: form
                .fields
                .iter()
                .find(|field| field.name == "signature")
                .unwrap()
                .id
                .clone(),
            text: Some("sign".into()),
            checked: None,
            selected: None,
        };
        let scratch = ScratchDir::new("forms");
        let error = save_form_pdf(
            &fixture("form-fields.pdf"),
            &scratch.join("bad.pdf"),
            &[update],
            None,
            SaveMode::Copy,
        )
        .expect_err("signature fields cannot be filled");
        assert_eq!(error.code, ErrorCode::InvalidArgument);
    }
}
