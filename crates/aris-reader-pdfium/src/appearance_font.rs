//! The font Lyra embeds in `/FreeText` appearance streams.
//!
//! # Why a bundled font, and why this one
//!
//! A free-text annotation's appearance was drawn in Helvetica with WinAnsi codes. Anything
//! outside cp1252 became `?` in a viewer that paints the appearance (the exact string was still
//! in `/Contents`). The reader annotates in Chinese, so the appearance needs a real Unicode font.
//!
//! The shipped file is a subset of **Noto Sans SC** (SIL OFL 1.1), renamed `Lyra Sans SC` because
//! the OFL reserves the name “Source”. It is committed at
//! `apps/macos/Resources/Fonts/LyraSansSC-Regular.ttf` with its licence next to it; no system
//! font is bundled and no glyph outline was copied out of one. `scripts/build-appearance-font.py`
//! documents and reproduces the subsetting: GB 2312, JIS X 0208, Latin, Greek and the maths
//! symbols papers use. The variable font is instantiated at `wght=400` before shipping, so the
//! file is already static.
//!
//! # The per-document subset
//!
//! Embedding the whole shipped font in every PDF would add ~3.5 MB per save. [`AppearanceSubset`]
//! instead collects every character used by the document's free-text annotations, maps it through
//! the font's cmap, and runs `subsetter` — the PDF-oriented subsetter from Typst — over that set.
//! The subsetter remaps glyph IDs to a contiguous sequence and removes `cmap`, which is the shape
//! a Type0/Identity-H font with an explicit `CIDToGIDMap` needs. The result is tens of kilobytes
//! for a typical page and is shared by every text box in one save.
//!
//! # Characters the font cannot show
//!
//! A character outside the shipped repertoire is **not** turned into `?`. It is encoded through
//! glyph 0 (`.notdef`) using a CID of its own, and that CID's `/ToUnicode` entry keeps the exact
//! Unicode. The viewer therefore paints a visible missing-glyph box (not a question mark), text
//! extraction still returns the original string, and `/Contents` is exact. The editor's
//! `PlacedTextEditorOverlay` asks [`missing_glyphs`] what it cannot show and warns while typing.

use aris_reader_core::{ArisError, ErrorCode, Result};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::path::PathBuf;
use std::sync::OnceLock;

/// Family name written into the PDF font dictionaries and the font's name table.
pub(crate) const FAMILY: &str = "Lyra Sans SC";
/// PostScript name written into `/BaseFont` and `/FontDescriptor /FontName`.
pub(crate) const POSTSCRIPT_NAME: &str = "LyraSansSC-Regular";
/// The committed font file. The writer loads it from the app bundle at run time; see [`font_bytes`].
const FILE_NAME: &str = "LyraSansSC-Regular.ttf";
/// Environment override used by tests and by a development build outside a bundle.
const FONT_PATH_ENV: &str = "ARIS_READER_APPEARANCE_FONT";
/// Checkout-relative fallback compiled into the library. This makes `cargo test` and the native
/// checks work without an `.app`; a packaged app finds the font in its own resources first.
const CHECKOUT_FONT: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../apps/macos/Resources/Fonts/LyraSansSC-Regular.ttf"
);

/// What [`missing_glyphs`] reports to the editor.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AppearanceCoverage {
    /// The embedded family's name, for the message.
    pub family: String,
    /// Number of glyphs in the shipped subset (not the per-document subset).
    pub glyph_count: u16,
    /// Characters that would use `.notdef`, in first-appearance order, de-duplicated.
    pub missing: Vec<char>,
}

/// Loads the committed font once per process.
///
/// Search order:
/// 1. `ARIS_READER_APPEARANCE_FONT` (tests, development);
/// 2. `<executable>/../Resources/Fonts/LyraSansSC-Regular.ttf` (a packaged `Lyra.app`);
/// 3. the checkout path compiled into the library (cargo tests and the native checks).
///
/// A missing file is an error, not a reason to fall back to Helvetica/WinAnsi: that fallback is
/// the bug this module exists to remove.
pub(crate) fn font_bytes() -> Result<&'static [u8]> {
    static BYTES: OnceLock<std::result::Result<Vec<u8>, String>> = OnceLock::new();
    match BYTES.get_or_init(load_font) {
        Ok(bytes) => Ok(bytes),
        Err(detail) => Err(ArisError::new(
            ErrorCode::Io,
            "the bundled appearance font could not be read",
        )
        .with_detail(detail.clone())),
    }
}

fn load_font() -> std::result::Result<Vec<u8>, String> {
    let mut tried: Vec<PathBuf> = Vec::new();
    for candidate in candidate_paths() {
        if tried.contains(&candidate) {
            continue;
        }
        tried.push(candidate.clone());
        let Ok(bytes) = std::fs::read(&candidate) else {
            continue;
        };
        if ttf_parser::Face::parse(&bytes, 0).is_ok() {
            return Ok(bytes);
        }
    }
    let tried = tried
        .iter()
        .map(|path| format!("  {}", path.display()))
        .collect::<Vec<_>>()
        .join("\n");
    Err(format!(
        "expected {FILE_NAME} in one of:\n{tried}\n\
         Set {FONT_PATH_ENV} to override, or run ./scripts/build-appearance-font.py."
    ))
}

fn candidate_paths() -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if let Some(override_path) = std::env::var_os(FONT_PATH_ENV)
        && !override_path.is_empty()
    {
        paths.push(PathBuf::from(override_path));
    }
    if let Ok(executable) = std::env::current_exe()
        && let Some(directory) = executable.parent()
    {
        paths.push(directory.join("../Resources/Fonts").join(FILE_NAME));
    }
    paths.push(PathBuf::from(CHECKOUT_FONT));
    paths
}

fn parse_face(data: &[u8]) -> Result<ttf_parser::Face<'_>> {
    ttf_parser::Face::parse(data, 0).map_err(|error| {
        ArisError::new(
            ErrorCode::Internal,
            "the bundled appearance font is not a readable TrueType/OpenType font",
        )
        .with_detail(format!("{error:?}"))
    })
}

/// Characters the font cannot draw, de-duplicated and in the order they first appear.
///
/// Newlines and tabs are layout, not glyphs, and are never reported. Callers show this to the
/// user; the writer does not use it to reject text.
pub fn missing_glyphs(text: &str) -> Result<Vec<char>> {
    let data = font_bytes()?;
    let face = parse_face(data)?;
    let mut seen = HashSet::new();
    let mut missing = Vec::new();
    for character in text.chars() {
        if is_layout_control(character) || !seen.insert(character) {
            continue;
        }
        if face.glyph_index(character).is_none() {
            missing.push(character);
        }
    }
    Ok(missing)
}

/// Coverage details for the editor warning and for the test that documents what was shipped.
pub fn coverage(text: &str) -> Result<AppearanceCoverage> {
    let data = font_bytes()?;
    let face = parse_face(data)?;
    Ok(AppearanceCoverage {
        family: FAMILY.to_string(),
        glyph_count: face.number_of_glyphs(),
        missing: missing_glyphs(text)?,
    })
}

/// True for characters that are layout rather than visible glyphs.
pub(crate) fn is_layout_control(character: char) -> bool {
    matches!(character, '\n' | '\r' | '\t')
}

/// One document's embedded font: the subset bytes, the CID assignment, and the maps the PDF
/// dictionaries need.
pub(crate) struct AppearanceSubset {
    /// The TrueType program for `FontFile2` (cmap removed, glyphs renumbered).
    font_file: Vec<u8>,
    /// Character to CID. A CID is either the remapped glyph ID or a synthetic ID for a glyph
    /// shared by several characters or for a `.notdef` fallback.
    cids: HashMap<char, u16>,
    /// Widths in 1/1000 em, indexed by CID.
    widths: Vec<u16>,
    /// CID to Unicode, for `/ToUnicode`.
    unicode: Vec<(u16, char)>,
    /// CID to glyph ID, for the explicit `CIDToGIDMap` stream. Missing characters map to 0.
    cid_to_gid: Vec<u16>,
    /// Number of glyphs in the embedded program (including `.notdef`).
    glyph_count: u16,
    /// Characters encoded through `.notdef`, in sorted order.
    missing: Vec<char>,
}

impl AppearanceSubset {
    /// Subset the bundled font to the characters in `texts`.
    ///
    /// An empty set still produces a valid font containing `.notdef`, but the writer avoids
    /// building one unless at least one visible character exists.
    pub(crate) fn build(texts: &[&str]) -> Result<Self> {
        let data = font_bytes()?;
        let face = parse_face(data)?;
        let units_per_em = f64::from(face.units_per_em().max(1));
        let scale = |font_units: u16| -> u16 {
            ((f64::from(font_units) * 1000.0 / units_per_em).round()).clamp(0.0, 65_535.0) as u16
        };

        // A sorted set makes the CID assignment and the resulting PDF deterministic.
        let characters: BTreeSet<char> = texts
            .iter()
            .flat_map(|text| {
                // The appearance lays a tab out as a space (see `wrap_free_text`), so the subset
                // must contain the space glyph for extraction to keep the column gap.
                text.chars()
                    .map(|character| if character == '\t' { ' ' } else { character })
            })
            .filter(|character| !is_layout_control(*character))
            .collect();

        let mut remapper = subsetter::GlyphRemapper::new();
        let mut glyphs: BTreeMap<char, u16> = BTreeMap::new();
        for character in &characters {
            if let Some(glyph) = face.glyph_index(*character) {
                remapper.remap(glyph.0);
                glyphs.insert(*character, glyph.0);
            }
        }

        let font_file = subsetter::subset(data, 0, &remapper).map_err(|error| {
            ArisError::new(
                ErrorCode::Internal,
                "could not subset the appearance font for this document",
            )
            .with_detail(error.to_string())
        })?;
        let glyph_count = ttf_parser::Face::parse(&font_file, 0)
            .map(|subset_face| subset_face.number_of_glyphs())
            .unwrap_or_else(|_| remapper.num_gids());

        let mut cids: HashMap<char, u16> = HashMap::new();
        let mut unicode: Vec<(u16, char)> = Vec::new();
        let mut cid_glyphs: Vec<(u16, u16)> = Vec::new();
        let mut missing: Vec<char> = Vec::new();
        // Synthetic CIDs start after every real glyph. They address glyph 0 (`.notdef`) or a
        // real glyph that is already addressed by another character.
        let mut next_synthetic = remapper.num_gids();
        let mut first_character_for_glyph: HashMap<u16, char> = HashMap::new();

        for character in &characters {
            let glyph = glyphs.get(character).copied();
            let cid = match glyph {
                Some(glyph) => {
                    let remapped = remapper.get(glyph).ok_or_else(|| {
                        ArisError::new(
                            ErrorCode::Internal,
                            "the appearance subset lost a glyph it had just remapped",
                        )
                        .with_detail(format!("{character:?} -> glyph {glyph}"))
                    })?;
                    if first_character_for_glyph
                        .insert(remapped, *character)
                        .is_none()
                    {
                        remapped
                    } else {
                        let cid = next_synthetic;
                        next_synthetic = next_synthetic.checked_add(1).ok_or_else(|| {
                            ArisError::new(
                                ErrorCode::Internal,
                                "the appearance font ran out of CIDs for this document",
                            )
                        })?;
                        cid
                    }
                }
                None => {
                    missing.push(*character);
                    let cid = next_synthetic;
                    next_synthetic = next_synthetic.checked_add(1).ok_or_else(|| {
                        ArisError::new(
                            ErrorCode::Internal,
                            "the appearance font ran out of CIDs for this document",
                        )
                    })?;
                    cid
                }
            };
            cids.insert(*character, cid);
            unicode.push((cid, *character));
            // CIDToGIDMap addresses glyphs in the **subset** font, whose IDs were remapped by
            // `subsetter`; the original ID is only useful for reading the advance width.
            let mapped_glyph = glyph.and_then(|glyph| remapper.get(glyph)).unwrap_or(0);
            cid_glyphs.push((cid, mapped_glyph));
        }

        let max_cid = next_synthetic.saturating_sub(1);
        let mut widths = vec![0u16; usize::from(max_cid) + 1];
        let mut cid_to_gid = vec![0u16; usize::from(max_cid) + 1];
        for (cid, glyph) in &cid_glyphs {
            cid_to_gid[usize::from(*cid)] = *glyph;
        }
        for (cid, character) in &unicode {
            let glyph = glyphs.get(character).copied().unwrap_or(0);
            let width = face
                .glyph_hor_advance(ttf_parser::GlyphId(glyph))
                .unwrap_or(500);
            widths[usize::from(*cid)] = scale(width);
        }
        // `.notdef`'s own width is the default for CIDs the writer never assigns.
        let notdef_width = face
            .glyph_hor_advance(ttf_parser::GlyphId(0))
            .unwrap_or(500);
        if let Some(first) = widths.first_mut() {
            *first = scale(notdef_width);
        }
        unicode.sort_unstable();
        missing.sort_unstable();

        Ok(Self {
            font_file,
            cids,
            widths,
            unicode,
            cid_to_gid,
            glyph_count,
            missing,
        })
    }

    pub(crate) fn font_file(&self) -> &[u8] {
        &self.font_file
    }

    pub(crate) fn glyph_count(&self) -> u16 {
        self.glyph_count
    }

    pub(crate) fn cid(&self, character: char) -> Option<u16> {
        self.cids.get(&character).copied()
    }

    pub(crate) fn width(&self, cid: u16) -> u16 {
        self.widths.get(usize::from(cid)).copied().unwrap_or(0)
    }

    /// Width in points of `character` set at `size`.
    pub(crate) fn character_width(&self, character: char, size: f64) -> f64 {
        self.cid(character)
            .map(|cid| f64::from(self.width(cid)) * size / 1000.0)
            .unwrap_or(0.0)
    }

    pub(crate) fn text_width(&self, text: &str, size: f64) -> f64 {
        text.chars()
            .map(|character| self.character_width(character, size))
            .sum()
    }

    /// Hex string for a `Tj` in an Identity-H font: two bytes per CID.
    pub(crate) fn hex_string(&self, text: &str) -> String {
        let mut encoded = String::with_capacity(text.len() * 4 + 2);
        encoded.push('<');
        for character in text.chars() {
            match self.cid(character) {
                Some(cid) => encoded.push_str(&format!("{cid:04X}")),
                None => encoded.push_str("0000"),
            }
        }
        encoded.push('>');
        encoded
    }

    pub(crate) fn missing(&self) -> &[char] {
        &self.missing
    }

    /// The explicit `CIDToGIDMap` stream. Two big-endian bytes per CID.
    pub(crate) fn cid_to_gid_map(&self) -> Vec<u8> {
        let mut bytes = Vec::with_capacity(self.cid_to_gid.len() * 2);
        for glyph in &self.cid_to_gid {
            bytes.extend_from_slice(&glyph.to_be_bytes());
        }
        bytes
    }

    /// `/W` entries as `(first CID, widths)`, grouping consecutive CIDs.
    pub(crate) fn width_groups(&self) -> Vec<(u16, Vec<u16>)> {
        let mut groups: Vec<(u16, Vec<u16>)> = Vec::new();
        for (index, width) in self.widths.iter().enumerate().skip(1) {
            let cid = index as u16;
            match groups.last_mut() {
                Some((first, widths)) if *first + widths.len() as u16 == cid => {
                    widths.push(*width);
                }
                _ => groups.push((cid, vec![*width])),
            }
        }
        groups
    }

    /// The `/ToUnicode` CMap. Every encoded CID maps to its exact Unicode scalar, including the
    /// `.notdef` fallbacks, so extraction from the appearance returns the input string.
    pub(crate) fn to_unicode_cmap(&self) -> Vec<u8> {
        let mut cmap = String::from(
            "/CIDInit /ProcSet findresource begin\n\
             12 dict begin\n\
             begincmap\n\
             /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n\
             /CMapName /LyraSansSC-UCS def\n\
             /CMapType 2 def\n\
             1 begincodespacerange\n\
             <0000> <FFFF>\n\
             endcodespacerange\n",
        );
        for chunk in self.unicode.chunks(100) {
            cmap.push_str(&format!("{} beginbfchar\n", chunk.len()));
            for (cid, character) in chunk {
                cmap.push_str(&format!("<{cid:04X}> <{}>\n", utf16be_hex(*character)));
            }
            cmap.push_str("endbfchar\n");
        }
        cmap.push_str(
            "endcmap\n\
             CMapName currentdict /CMap defineresource pop\n\
             end\n\
             end\n",
        );
        cmap.into_bytes()
    }
}

/// UTF-16BE as the hex string a `bfchar` destination needs. Non-BMP characters become a
/// surrogate pair, not U+FFFD.
fn utf16be_hex(character: char) -> String {
    let mut units = [0u16; 2];
    character
        .encode_utf16(&mut units)
        .iter()
        .map(|unit| format!("{unit:04X}"))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn subset_for(text: &str) -> AppearanceSubset {
        AppearanceSubset::build(&[text]).expect("subset the appearance font")
    }

    #[test]
    fn the_shipped_font_covers_the_scripts_annotations_use() {
        let data = font_bytes().expect("the committed font is present");
        let face = parse_face(data).expect("the committed font parses");
        for text in [
            "中文测试：这是一条中文批注。",
            "日本語のテキストです。語と観。",
            "α ≤ ∑ ∈ √ ∞ ∂ ∇ ≠ ≈ ⊂ ⊆",
            "Hello, world! 123",
        ] {
            for character in text.chars() {
                assert!(
                    face.glyph_index(character).is_some(),
                    "{character:?} (U+{:04X}) is missing from the shipped font",
                    u32::from(character)
                );
            }
        }
        assert!(face.number_of_glyphs() > 10_000);
    }

    #[test]
    fn the_subset_contains_only_the_glyphs_the_text_uses_and_keeps_unicode() {
        let subset = subset_for("中文 α");
        assert_eq!(subset.glyph_count(), 5, ".notdef plus 中, 文, space, α");
        assert_eq!(
            subset.missing(),
            &[] as &[char],
            "every character is covered"
        );
        let map = subset.cid_to_gid_map();
        assert_eq!(map.len(), subset.cid_to_gid.len() * 2);
        let cmap = String::from_utf8(subset.to_unicode_cmap()).expect("ASCII CMap");
        assert!(cmap.contains(&format!("<{:04X}> <4E2D>", subset.cid('中').unwrap())));
        assert!(cmap.contains(&format!("<{:04X}> <03B1>", subset.cid('α').unwrap())));
        // The embedded program is small, not the 3.5 MB shipped file.
        assert!(
            subset.font_file().len() < 200_000,
            "subset was {} bytes",
            subset.font_file().len()
        );
    }

    #[test]
    fn a_character_outside_the_font_keeps_its_unicode_in_the_appearance() {
        let subset = subset_for("中😀文");
        assert_eq!(subset.missing(), &['😀']);
        let cid = usize::from(subset.cid('😀').unwrap());
        let map = subset.cid_to_gid_map();
        assert_eq!(
            u16::from_be_bytes([map[cid * 2], map[cid * 2 + 1]]),
            0,
            "a missing character maps to .notdef"
        );
        let cmap = String::from_utf8(subset.to_unicode_cmap()).expect("ASCII CMap");
        assert!(
            cmap.contains(&format!("<{:04X}> <D83DDE00>", subset.cid('😀').unwrap())),
            "a non-BMP fallback keeps a surrogate pair in ToUnicode"
        );
        assert_ne!(subset.cid('😀'), subset.cid('中'));
    }

    #[test]
    fn a_tab_is_laid_out_as_a_space_and_keeps_an_extractable_gap() {
        let subset = subset_for("a\tb");
        assert!(
            subset.cid(' ').is_some(),
            "the space glyph is included when a tab is laid out as a space"
        );
        assert_eq!(subset.missing(), &[] as &[char]);
    }

    #[test]
    fn two_characters_sharing_a_glyph_get_distinct_cids() {
        // U+0020 and U+00A0 need not share a glyph in this font, but the assignment logic must
        // remain safe if they do: each character has its own CID and its own ToUnicode entry.
        let subset = subset_for("a\u{00A0}b");
        assert_ne!(subset.cid('a'), subset.cid('b'));
        assert_eq!(subset.unicode.len(), subset.cids.len());
    }
}
