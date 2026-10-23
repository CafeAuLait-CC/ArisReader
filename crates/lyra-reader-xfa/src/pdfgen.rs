//! Writes the layout to a small, static PDF in memory.
//!
//! The synthetic document is never saved beside the source. It is handed to PDFium as bytes,
//! so the reader's existing tile cache, text layer and search paths work unchanged, and the
//! original file is only ever read.

use crate::image::Asset;
use crate::layout::{Op, RenderedDocument};
use crate::text::encode_winansi;
use crate::units::Color;
use std::fmt::Write as _;

macro_rules! push_fmt {
    ($out:expr, $($arg:tt)*) => {{
        let mut text = String::new();
        let _ = write!(text, $($arg)*);
        $out.extend_from_slice(text.as_bytes());
    }};
}

/// Serializes `document`; also returns the characters that had to be written as `?`.
pub fn generate(document: &RenderedDocument) -> (Vec<u8>, Vec<char>) {
    let mut writer = Writer::new();
    let mut missing = Vec::new();
    for asset in &document.assets {
        let object = writer.add_image(asset);
        writer.image_objects.push(object);
    }
    for page in &document.pages {
        let (content, page_missing) = page_content(page, &writer.image_objects);
        for character in page_missing {
            if !missing.contains(&character) {
                missing.push(character);
            }
        }
        writer.add_page(page.width, page.height, content);
    }
    (writer.finish(), missing)
}

fn page_content(
    page: &crate::layout::RenderedPage,
    image_objects: &[usize],
) -> (Vec<u8>, Vec<char>) {
    let mut out = Vec::new();
    let mut missing = Vec::new();
    let height = page.height;
    for op in &page.ops {
        match op {
            Op::Rect {
                x,
                y,
                width,
                height: rect_height,
                fill,
                stroke,
                line_width,
            } => {
                if *width <= 0.0 || *rect_height <= 0.0 {
                    continue;
                }
                if let Some(fill) = fill {
                    write_fill(&mut out, *fill);
                }
                if let Some(stroke) = stroke {
                    write_stroke(&mut out, *stroke);
                    push_fmt!(out, "{:.2} w\n", line_width.max(0.1));
                }
                push_fmt!(
                    out,
                    "{x:.2} {:.2} {width:.2} {rect_height:.2} re\n",
                    height - y - rect_height
                );
                out.extend_from_slice(if fill.is_some() && stroke.is_some() {
                    b"B\n"
                } else if fill.is_some() {
                    b"f\n"
                } else {
                    b"S\n"
                });
            }
            Op::Line {
                x1,
                y1,
                x2,
                y2,
                width,
                color,
            } => {
                write_stroke(&mut out, *color);
                push_fmt!(out, "{width:.2} w\n");
                push_fmt!(
                    out,
                    "{x1:.2} {:.2} m {x2:.2} {:.2} l S\n",
                    height - y1,
                    height - y2
                );
            }
            Op::Circle {
                x,
                y,
                radius,
                fill,
                stroke,
                line_width,
            } => {
                if let Some(fill) = fill {
                    write_fill(&mut out, *fill);
                }
                if let Some(stroke) = stroke {
                    write_stroke(&mut out, *stroke);
                    push_fmt!(out, "{:.2} w\n", line_width.max(0.1));
                }
                write_circle(&mut out, *x, height - y, *radius);
                out.extend_from_slice(if fill.is_some() && stroke.is_some() {
                    b"B\n"
                } else if fill.is_some() {
                    b"f\n"
                } else {
                    b"S\n"
                });
            }
            Op::Triangle {
                x,
                y,
                width,
                height: triangle_height,
                color,
            } => {
                write_fill(&mut out, *color);
                push_fmt!(
                    out,
                    "{x:.2} {:.2} m {:.2} {:.2} l {x:.2} {:.2} l f\n",
                    height - y,
                    x + width,
                    height - (y + *triangle_height / 2.0),
                    height - (y + *triangle_height)
                );
            }
            Op::Text {
                x,
                y,
                text,
                size,
                bold,
                italic,
                color,
            } => {
                let (bytes, page_missing) = encode_winansi(text);
                for character in page_missing {
                    if !missing.contains(&character) {
                        missing.push(character);
                    }
                }
                if bytes.is_empty() {
                    continue;
                }
                let font = match (*bold, *italic) {
                    (false, false) => "/F1",
                    (true, false) => "/F2",
                    (false, true) => "/F3",
                    (true, true) => "/F4",
                };
                write_fill(&mut out, *color);
                push_fmt!(
                    out,
                    "BT {font} {size:.2} Tf 1 0 0 1 {x:.2} {:.2} Tm (",
                    height - (y + size * 0.92)
                );
                escape_bytes(&mut out, &bytes);
                out.extend_from_slice(b") Tj ET\n");
            }
            Op::Image {
                asset,
                x,
                y,
                width,
                height: image_height,
            } => {
                if let Some(object) = image_objects.get(*asset) {
                    push_fmt!(
                        out,
                        "q {width:.2} 0 0 {image_height:.2} {x:.2} {:.2} cm /Im{object} Do Q\n",
                        height - y - image_height
                    );
                }
            }
        }
    }
    (out, missing)
}

fn write_fill(out: &mut Vec<u8>, colour: Color) {
    push_fmt!(
        out,
        "{:.3} {:.3} {:.3} rg\n",
        colour.red,
        colour.green,
        colour.blue
    );
}

fn write_stroke(out: &mut Vec<u8>, colour: Color) {
    push_fmt!(
        out,
        "{:.3} {:.3} {:.3} RG\n",
        colour.red,
        colour.green,
        colour.blue
    );
}

fn escape_bytes(out: &mut Vec<u8>, bytes: &[u8]) {
    for byte in bytes {
        match byte {
            b'(' | b')' | b'\\' => {
                out.push(b'\\');
                out.push(*byte);
            }
            _ => out.push(*byte),
        }
    }
}

fn write_circle(out: &mut Vec<u8>, centre_x: f64, centre_y: f64, radius: f64) {
    let k = 0.552_284_749_8 * radius;
    push_fmt!(
        out,
        "{:.2} {:.2} m {:.2} {:.2} {:.2} {:.2} {:.2} {:.2} c {:.2} {:.2} {:.2} {:.2} {:.2} {:.2} c {:.2} {:.2} {:.2} {:.2} {:.2} {:.2} c {:.2} {:.2} {:.2} {:.2} {:.2} {:.2} c\n",
        centre_x + radius,
        centre_y,
        centre_x + radius,
        centre_y + k,
        centre_x + k,
        centre_y + radius,
        centre_x,
        centre_y + radius,
        centre_x - k,
        centre_y + radius,
        centre_x - radius,
        centre_y + k,
        centre_x - radius,
        centre_y,
        centre_x - radius,
        centre_y - k,
        centre_x - k,
        centre_y - radius,
        centre_x,
        centre_y - radius,
        centre_x + k,
        centre_y - radius,
        centre_x + radius,
        centre_y - k,
        centre_x + radius,
        centre_y,
    );
}

struct Object {
    dictionary: Vec<u8>,
    stream: Option<Vec<u8>>,
}

struct Writer {
    objects: Vec<Object>,
    page_objects: Vec<usize>,
    font_objects: [usize; 4],
    image_objects: Vec<usize>,
}

impl Writer {
    fn new() -> Self {
        let mut writer = Self {
            objects: Vec::new(),
            page_objects: Vec::new(),
            font_objects: [0; 4],
            image_objects: Vec::new(),
        };
        writer.objects.push(Object {
            dictionary: b"<< /Type /Catalog /Pages 2 0 R >>".to_vec(),
            stream: None,
        });
        writer.objects.push(Object {
            dictionary: Vec::new(),
            stream: None,
        });
        for (index, base_font) in [
            "Helvetica",
            "Helvetica-Bold",
            "Helvetica-Oblique",
            "Helvetica-BoldOblique",
        ]
        .iter()
        .enumerate()
        {
            writer.objects.push(Object {
                dictionary: format!(
                    "<< /Type /Font /Subtype /Type1 /BaseFont /{base_font} /Encoding /WinAnsiEncoding >>"
                )
                .into_bytes(),
                stream: None,
            });
            writer.font_objects[index] = writer.objects.len();
        }
        writer
    }

    fn add_image(&mut self, asset: &Asset) -> usize {
        let object = match asset {
            Asset::Jpeg {
                width,
                height,
                components,
                bytes,
            } => {
                let colour_space = match components {
                    1 => "/DeviceGray",
                    3 => "/DeviceRGB",
                    _ => "/DeviceCMYK",
                };
                Object {
                    dictionary: format!(
                        "<< /Type /XObject /Subtype /Image /Width {width} /Height {height} \
                         /ColorSpace {colour_space} /BitsPerComponent 8 /Filter /DCTDecode \
                         /Length {} >>",
                        bytes.len()
                    )
                    .into_bytes(),
                    stream: Some(bytes.clone()),
                }
            }
            Asset::Rgb {
                width,
                height,
                bytes,
            } => Object {
                dictionary: format!(
                    "<< /Type /XObject /Subtype /Image /Width {width} /Height {height} \
                     /ColorSpace /DeviceRGB /BitsPerComponent 8 /Length {} >>",
                    bytes.len()
                )
                .into_bytes(),
                stream: Some(bytes.clone()),
            },
        };
        self.objects.push(object);
        self.objects.len()
    }

    fn add_page(&mut self, width: f64, height: f64, content: Vec<u8>) {
        self.objects.push(Object {
            dictionary: format!("<< /Length {} >>", content.len()).into_bytes(),
            stream: Some(content),
        });
        let content_id = self.objects.len();
        let mut xobjects = String::new();
        for object in &self.image_objects {
            let _ = write!(xobjects, "/Im{object} {object} 0 R ");
        }
        let resources = format!(
            "<< /Font << /F1 {} 0 R /F2 {} 0 R /F3 {} 0 R /F4 {} 0 R >>{} >>",
            self.font_objects[0],
            self.font_objects[1],
            self.font_objects[2],
            self.font_objects[3],
            if self.image_objects.is_empty() {
                String::new()
            } else {
                format!(" /XObject << {xobjects} >>")
            }
        );
        self.objects.push(Object {
            dictionary: format!(
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {width:.2} {height:.2}] \
                 /Resources {resources} /Contents {content_id} 0 R >>"
            )
            .into_bytes(),
            stream: None,
        });
        self.page_objects.push(self.objects.len());
    }

    fn finish(mut self) -> Vec<u8> {
        let kids = self
            .page_objects
            .iter()
            .map(|object| format!("{object} 0 R"))
            .collect::<Vec<_>>()
            .join(" ");
        self.objects[1].dictionary = format!(
            "<< /Type /Pages /Count {} /Kids [ {kids} ] >>",
            self.page_objects.len()
        )
        .into_bytes();
        let mut out = Vec::new();
        out.extend_from_slice(b"%PDF-1.7\n%\xE2\xE3\xCF\xD3\n");
        let mut offsets = Vec::with_capacity(self.objects.len());
        for (index, object) in self.objects.iter().enumerate() {
            offsets.push(out.len());
            push_fmt!(out, "{} 0 obj\n", index + 1);
            out.extend_from_slice(&object.dictionary);
            if let Some(stream) = &object.stream {
                out.extend_from_slice(b"\nstream\n");
                out.extend_from_slice(stream);
                out.extend_from_slice(b"\nendstream");
            }
            out.extend_from_slice(b"\nendobj\n");
        }
        let xref = out.len();
        push_fmt!(out, "xref\n0 {}\n", self.objects.len() + 1);
        out.extend_from_slice(b"0000000000 65535 f \n");
        for offset in &offsets {
            push_fmt!(out, "{offset:010} 00000 n \n");
        }
        push_fmt!(
            out,
            "trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n",
            self.objects.len() + 1
        );
        out
    }
}
