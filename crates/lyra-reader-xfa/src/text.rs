//! Helvetica metrics and WinAnsi encoding for the synthetic PDF.
//!
//! The XFA asks for Myriad Pro, which is not shipped with this reader or with PDF. The
//! synthetic document therefore uses the standard Helvetica faces; the metrics below are the
//! Adobe AFM advance widths, so line breaking and centred text land close to what a viewer
//! would print. A character outside WinAnsi is written as `?` and reported, never silently
//! dropped.

const HELVETICA: [u16; 95] = [
    278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278, //
    556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556, //
    1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778, //
    667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556, //
    333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556, //
    556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584,
];

const HELVETICA_BOLD: [u16; 95] = [
    278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278, //
    556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556, //
    1015, 722, 722, 722, 722, 667, 611, 778, 722, 278, 556, 722, 611, 833, 722, 778, //
    667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556, //
    333, 556, 611, 556, 611, 556, 333, 611, 611, 278, 278, 556, 278, 889, 611, 611, //
    611, 611, 389, 556, 333, 611, 556, 778, 556, 556, 500, 334, 260, 334, 584,
];

/// Width of `text` at `size` points in the Helvetica face.
pub fn width(text: &str, size: f64, bold: bool) -> f64 {
    let table = if bold { &HELVETICA_BOLD } else { &HELVETICA };
    let units: u32 = text
        .chars()
        .map(|character| {
            let code = character as u32;
            if (32..=126).contains(&code) {
                u32::from(table[(code - 32) as usize])
            } else {
                u32::from(latin_width(character, bold))
            }
        })
        .sum();
    f64::from(units) * size / 1000.0
}

fn latin_width(character: char, bold: bool) -> u16 {
    let table = if bold { &HELVETICA_BOLD } else { &HELVETICA };
    let base = match character {
        'à' | 'á' | 'â' | 'ã' | 'ä' | 'å' | 'À' | 'Á' | 'Â' | 'Ã' | 'Ä' | 'Å' => 'a',
        'è' | 'é' | 'ê' | 'ë' | 'È' | 'É' | 'Ê' | 'Ë' => 'e',
        'ì' | 'í' | 'î' | 'ï' | 'Ì' | 'Í' | 'Î' | 'Ï' => 'i',
        'ò' | 'ó' | 'ô' | 'õ' | 'ö' | 'Ò' | 'Ó' | 'Ô' | 'Õ' | 'Ö' => 'o',
        'ù' | 'ú' | 'û' | 'ü' | 'Ù' | 'Ú' | 'Û' | 'Ü' => 'u',
        'ç' | 'Ç' => 'c',
        'ñ' | 'Ñ' => 'n',
        'ý' | 'ÿ' | 'Ý' => 'y',
        'ß' => 's',
        '\u{2013}' | '\u{2014}' | '-' => '-',
        '\u{2018}' | '\u{2019}' | '\'' => '\'',
        '\u{201c}' | '\u{201d}' | '"' => '"',
        '\u{2022}' => 'o',
        _ => return 556,
    };
    let upper = if character.is_uppercase() {
        base.to_ascii_uppercase()
    } else {
        base
    };
    table[(upper as u32 - 32) as usize]
}

/// Wraps `text` to `max_width`, keeping explicit newlines. A single word wider than the line is
/// broken by characters so it cannot run out of its field.
pub fn wrap(text: &str, size: f64, bold: bool, max_width: f64) -> Vec<String> {
    if max_width <= 0.0 || !max_width.is_finite() {
        return text.lines().map(str::to_string).collect();
    }
    let mut lines = Vec::new();
    for paragraph in text.split('\n') {
        let paragraph = paragraph.trim_end();
        if paragraph.is_empty() {
            lines.push(String::new());
            continue;
        }
        let mut line = String::new();
        for word in paragraph.split(' ') {
            if word.is_empty() {
                continue;
            }
            let candidate = if line.is_empty() {
                word.to_string()
            } else {
                format!("{line} {word}")
            };
            if width(&candidate, size, bold) <= max_width || line.is_empty() {
                if line.is_empty() && width(word, size, bold) > max_width {
                    // Break an over-long token at the last character that fits, then continue.
                    let mut current = String::new();
                    for character in word.chars() {
                        let mut next = current.clone();
                        next.push(character);
                        if width(&next, size, bold) > max_width && !current.is_empty() {
                            lines.push(current);
                            current = String::new();
                        }
                        current.push(character);
                    }
                    line = current;
                } else {
                    line = candidate;
                }
            } else {
                lines.push(std::mem::take(&mut line));
                line = word.to_string();
            }
        }
        if !line.is_empty() {
            lines.push(line);
        }
    }
    if lines.is_empty() {
        lines.push(String::new());
    }
    lines
}

/// WinAnsi bytes for a PDF text string, plus the characters that had no mapping.
pub fn encode_winansi(text: &str) -> (Vec<u8>, Vec<char>) {
    let mut bytes = Vec::with_capacity(text.len());
    let mut missing = Vec::new();
    for character in text.chars() {
        match character {
            '\n' | '\r' => continue,
            '\t' => bytes.push(b' '),
            '\u{a0}' => bytes.push(b' '),
            character if (character as u32) < 0x80 => bytes.push(character as u8),
            character => match winansi_byte(character) {
                Some(byte) => bytes.push(byte),
                None => {
                    bytes.push(b'?');
                    if !missing.contains(&character) {
                        missing.push(character);
                    }
                }
            },
        }
    }
    (bytes, missing)
}

fn winansi_byte(character: char) -> Option<u8> {
    let byte = match character {
        '€' => 0x80,
        '‚' => 0x82,
        'ƒ' => 0x83,
        '„' => 0x84,
        '…' => 0x85,
        '†' => 0x86,
        '‡' => 0x87,
        'ˆ' => 0x88,
        '‰' => 0x89,
        'Š' => 0x8A,
        '‹' => 0x8B,
        'Œ' => 0x8C,
        'Ž' => 0x8E,
        '‘' => 0x91,
        '’' => 0x92,
        '“' => 0x93,
        '”' => 0x94,
        '•' => 0x95,
        '–' => 0x96,
        '—' => 0x97,
        '˜' => 0x98,
        '™' => 0x99,
        'š' => 0x9A,
        '›' => 0x9B,
        'œ' => 0x9C,
        'ž' => 0x9E,
        'Ÿ' => 0x9F,
        character if (0xA0..=0xFF).contains(&(character as u32)) => character as u32 as u8,
        _ => return None,
    };
    Some(byte)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn measures_helvetica_advances() {
        assert!((width("Hello", 10.0, false) - 22.78).abs() < 0.01);
        assert!(width("Hello", 10.0, true) > width("Hello", 10.0, false));
    }

    #[test]
    fn wraps_at_word_boundaries_and_keeps_paragraphs() {
        let lines = wrap("one two three\nfour", 8.0, false, 30.0);
        assert!(lines.len() >= 3);
        assert_eq!(lines.last().map(String::as_str), Some("four"));
    }

    #[test]
    fn encodes_accented_french_and_reports_missing_glyphs() {
        let (bytes, missing) = encode_winansi("RÉFUGIÉS – 中文");
        assert_eq!(&bytes[0..2], &[b'R', 0xC9]);
        assert!(bytes.contains(&0x96));
        assert_eq!(missing, vec!['中', '文']);
    }
}
