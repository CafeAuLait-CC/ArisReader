//! Inline XFA images, converted to the two forms this synthetic PDF can embed: JPEG bytes
//! passed through untouched, and BMP pixels decoded into an uncompressed RGB image.
//!
//! TIFF is deliberately not guessed at: the sample's four TIFFs are 3 KB arrow glyphs, and a
//! partly-decoded image would be worse than the triangle the layout draws in their place.

/// An image ready for the PDF writer.
#[derive(Clone, Debug, PartialEq)]
pub enum Asset {
    Jpeg {
        width: u32,
        height: u32,
        components: u8,
        bytes: Vec<u8>,
    },
    Rgb {
        width: u32,
        height: u32,
        bytes: Vec<u8>,
    },
}

impl Asset {
    pub fn width(&self) -> u32 {
        match self {
            Self::Jpeg { width, .. } | Self::Rgb { width, .. } => *width,
        }
    }

    pub fn height(&self) -> u32 {
        match self {
            Self::Jpeg { height, .. } | Self::Rgb { height, .. } => *height,
        }
    }
}

/// How an inline image can be embedded, or why it cannot.
#[derive(Clone, Debug, PartialEq)]
pub enum Decoded {
    Asset(Asset),
    /// A small TIFF arrow; the caller draws a triangle and reports the substitution.
    Arrow,
    Unsupported(String),
}

pub fn decode(content_type: &str, bytes: &[u8]) -> Decoded {
    let kind = content_type.to_ascii_lowercase();
    if (kind.contains("jpeg") || kind.contains("jpg") || bytes.starts_with(&[0xFF, 0xD8]))
        && let Some((width, height, components)) = jpeg_size(bytes)
    {
        return Decoded::Asset(Asset::Jpeg {
            width,
            height,
            components,
            bytes: bytes.to_vec(),
        });
    }
    if (kind.contains("bmp") || bytes.starts_with(b"BM"))
        && let Some(asset) = decode_bmp(bytes)
    {
        return Decoded::Asset(asset);
    }
    if kind.contains("tif")
        || kind.contains("tiff")
        || bytes.starts_with(b"II*\0")
        || bytes.starts_with(b"MM\0*")
    {
        return Decoded::Arrow;
    }
    Decoded::Unsupported(format!(
        "image `{content_type}` ({} bytes) has no supported decoder",
        bytes.len()
    ))
}

fn jpeg_size(bytes: &[u8]) -> Option<(u32, u32, u8)> {
    if bytes.len() < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8 {
        return None;
    }
    let mut index = 2;
    while index + 9 < bytes.len() {
        if bytes[index] != 0xFF {
            index += 1;
            continue;
        }
        let marker = bytes[index + 1];
        if matches!(
            marker,
            0xC0 | 0xC1
                | 0xC2
                | 0xC3
                | 0xC5
                | 0xC6
                | 0xC7
                | 0xC9
                | 0xCA
                | 0xCB
                | 0xCD
                | 0xCE
                | 0xCF
        ) {
            let height = u32::from(u16::from_be_bytes([bytes[index + 5], bytes[index + 6]]));
            let width = u32::from(u16::from_be_bytes([bytes[index + 7], bytes[index + 8]]));
            let components = bytes[index + 9];
            if width == 0 || height == 0 {
                return None;
            }
            return Some((width, height, components));
        }
        if marker == 0xD8 || marker == 0xD9 || (0xD0..=0xD7).contains(&marker) {
            index += 2;
            continue;
        }
        let length = usize::from(u16::from_be_bytes([bytes[index + 2], bytes[index + 3]]));
        index += 2 + length.max(2);
    }
    None
}

fn decode_bmp(bytes: &[u8]) -> Option<Asset> {
    if bytes.len() < 54 || &bytes[..2] != b"BM" {
        return None;
    }
    let offset = u32::from_le_bytes(bytes[10..14].try_into().ok()?) as usize;
    let header_size = u32::from_le_bytes(bytes[14..18].try_into().ok()?) as usize;
    if header_size < 40 {
        return None;
    }
    let width = i32::from_le_bytes(bytes[18..22].try_into().ok()?);
    let signed_height = i32::from_le_bytes(bytes[22..26].try_into().ok()?);
    let bits = u16::from_le_bytes(bytes[28..30].try_into().ok()?);
    let compression = u32::from_le_bytes(bytes[30..34].try_into().ok()?);
    if width <= 0 || signed_height == 0 || compression != 0 {
        return None;
    }
    let width = width as u32;
    let height = signed_height.unsigned_abs();
    let top_down = signed_height < 0;

    match bits {
        1 => {
            let palette_offset = 14 + header_size;
            if bytes.len() < palette_offset + 8 {
                return None;
            }
            let mut palette = [(0u8, 0u8, 0u8); 2];
            for (index, slot) in palette.iter_mut().enumerate() {
                let start = palette_offset + index * 4;
                *slot = (bytes[start + 2], bytes[start + 1], bytes[start]);
            }
            let row_bytes = (width as usize).div_ceil(32) * 4;
            let mut rgb = Vec::with_capacity(width as usize * height as usize * 3);
            for row in 0..height {
                let source_row = if top_down { row } else { height - 1 - row };
                let start = offset + source_row as usize * row_bytes;
                if start + row_bytes > bytes.len() {
                    return None;
                }
                for x in 0..width {
                    let byte = bytes[start + (x as usize) / 8];
                    let bit = (byte >> (7 - (x % 8))) & 1;
                    let (red, green, blue) = palette[usize::from(bit)];
                    rgb.extend_from_slice(&[red, green, blue]);
                }
            }
            Some(Asset::Rgb {
                width,
                height,
                bytes: rgb,
            })
        }
        24 => {
            let row_bytes = ((width as usize) * 3).div_ceil(4) * 4;
            let mut rgb = Vec::with_capacity(width as usize * height as usize * 3);
            for row in 0..height {
                let source_row = if top_down { row } else { height - 1 - row };
                let start = offset + source_row as usize * row_bytes;
                if start + row_bytes > bytes.len() {
                    return None;
                }
                for x in 0..width {
                    let pixel = start + (x as usize) * 3;
                    rgb.extend_from_slice(&[bytes[pixel + 2], bytes[pixel + 1], bytes[pixel]]);
                }
            }
            Some(Asset::Rgb {
                width,
                height,
                bytes: rgb,
            })
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_a_minimal_jpeg_sof() {
        let mut bytes = vec![
            0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x10, 0x00, 0x20, 0x03,
        ];
        bytes.extend(std::iter::repeat_n(0, 20));
        let size = jpeg_size(&bytes).expect("size");
        assert_eq!((size.0, size.1, size.2), (32, 16, 3));
    }

    #[test]
    fn decodes_a_two_colour_one_bit_bmp() {
        let width = 2u32;
        let height = 2u32;
        let row_bytes = 4usize;
        let mut bytes = vec![0u8; 14 + 40 + 8 + row_bytes * 2];
        bytes[0..2].copy_from_slice(b"BM");
        bytes[10..14].copy_from_slice(&(62u32).to_le_bytes());
        bytes[14..18].copy_from_slice(&(40u32).to_le_bytes());
        bytes[18..22].copy_from_slice(&(width as i32).to_le_bytes());
        bytes[22..26].copy_from_slice(&(height as i32).to_le_bytes());
        bytes[26..28].copy_from_slice(&(1u16).to_le_bytes());
        bytes[28..30].copy_from_slice(&(1u16).to_le_bytes());
        bytes[54..58].copy_from_slice(&[0, 0, 0, 0]);
        bytes[58..62].copy_from_slice(&[255, 255, 255, 0]);
        bytes[62] = 0b1100_0000;
        bytes[66] = 0b0100_0000;
        let asset = decode_bmp(&bytes).expect("bmp");
        match asset {
            Asset::Rgb {
                width,
                height,
                bytes,
            } => {
                assert_eq!((width, height), (2, 2));
                // BMP rows are bottom-up: the last source row is the top row, and its first
                // bit selects the black palette entry.
                assert_eq!(&bytes[0..3], &[0, 0, 0]);
                assert_eq!(&bytes[3..6], &[255, 255, 255]);
            }
            _ => panic!("expected RGB"),
        }
    }
}
