//! XFA lengths and colours.
//!
//! XFA writes lengths in millimetres, inches, centimetres and points. All layout math in this
//! crate happens in PDF points, so every length is converted at the parse boundary.

/// PDF points per unit.
pub const POINTS_PER_INCH: f64 = 72.0;
pub const POINTS_PER_MM: f64 = POINTS_PER_INCH / 25.4;

/// Parses an XFA length (`12.7mm`, `0.75in`, `7pt`, `1.2cm`) into points.
///
/// A bare number is points: that is how XFA writes font sizes and edge thicknesses. Returns
/// `None` for a missing or malformed value so the caller can apply its own default rather than
/// silently treating garbage as zero.
pub fn length(value: Option<&str>) -> Option<f64> {
    let value = value?.trim();
    if value.is_empty() {
        return None;
    }
    let split = value
        .find(|character: char| {
            !(character.is_ascii_digit() || matches!(character, '.' | '-' | '+' | 'e' | 'E'))
        })
        .unwrap_or(value.len());
    let number = value[..split].parse::<f64>().ok()?;
    if !number.is_finite() {
        return None;
    }
    let unit = value[split..].trim().to_ascii_lowercase();
    let factor = match unit.as_str() {
        "" | "pt" => 1.0,
        "in" => POINTS_PER_INCH,
        "mm" => POINTS_PER_MM,
        "cm" => POINTS_PER_MM * 10.0,
        "pc" => 12.0,
        "px" => 0.75,
        // XFA also allows a percentage, but no geometry this crate lays out uses one.
        _ => return None,
    };
    Some(number * factor)
}

/// Parses a length with a fallback.
pub fn length_or(value: Option<&str>, fallback: f64) -> f64 {
    length(value).unwrap_or(fallback)
}

/// An sRGB colour as PDF wants it (0.0–1.0).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Color {
    pub red: f64,
    pub green: f64,
    pub blue: f64,
}

impl Color {
    pub const BLACK: Self = Self {
        red: 0.0,
        green: 0.0,
        blue: 0.0,
    };
    pub const WHITE: Self = Self {
        red: 1.0,
        green: 1.0,
        blue: 1.0,
    };

    /// Parses `r,g,b` with 0–255 components, as XFA `<color value="..."/>` writes it.
    pub fn parse(value: &str) -> Option<Self> {
        let parts: Vec<&str> = value.split(',').map(str::trim).collect();
        if parts.len() != 3 {
            return None;
        }
        let channel = |part: &str| -> Option<f64> {
            let number = part.parse::<f64>().ok()?;
            Some((number / 255.0).clamp(0.0, 1.0))
        };
        Some(Self {
            red: channel(parts[0])?,
            green: channel(parts[1])?,
            blue: channel(parts[2])?,
        })
    }

    /// A grey value for rules and default field boxes.
    pub fn grey(value: f64) -> Self {
        Self {
            red: value,
            green: value,
            blue: value,
        }
    }
}

/// A non-breaking space appears in LiveCycle rich text as a spacer. It is layout, not data.
pub fn normalise_space(text: &str) -> String {
    text.replace(['\u{a0}', '\u{2007}'], " ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn converts_every_unit_livecycle_emits() {
        assert!((length(Some("1in")).unwrap() - 72.0).abs() < 1e-9);
        assert!((length(Some("25.4mm")).unwrap() - 72.0).abs() < 1e-6);
        assert!((length(Some("2.54cm")).unwrap() - 72.0).abs() < 1e-6);
        assert!((length(Some("12pt")).unwrap() - 12.0).abs() < 1e-9);
        assert!((length(Some("7")).unwrap() - 7.0).abs() < 1e-9);
        assert_eq!(length(Some("odd")), None);
        assert_eq!(length(None), None);
    }

    #[test]
    fn parses_colours_and_clamps_components() {
        let colour = Color::parse("255, 128, 0").unwrap();
        assert!((colour.red - 1.0).abs() < 1e-9);
        assert!((colour.green - (128.0 / 255.0)).abs() < 1e-9);
        assert_eq!(Color::parse("1,2"), None);
    }
}
