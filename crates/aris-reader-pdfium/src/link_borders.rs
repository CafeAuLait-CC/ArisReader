//! Legacy /Link borders have no appearance stream, and PDFium's bitmap renderer omits them.
//! Read only their dictionary geometry once; paint directly into the existing BGRA raster.

use aris_reader_core::{PageGeometry, PageIndex, RasterRequest, RasterTile};
use lopdf::{Dictionary, Document, LoadOptions, Object};
use std::collections::HashMap;
use std::path::Path;
use tiny_skia::{Paint, PathBuilder, PixmapMut, Stroke, StrokeDash, Transform};

pub(crate) struct LinkBorder {
    path: tiny_skia::Path,
    color: [f32; 3],
    opacity: f32,
    stroke: Stroke,
}

pub(crate) fn read(path: &Path, password: Option<&str>) -> HashMap<PageIndex, Vec<LinkBorder>> {
    let options = LoadOptions {
        password: password.map(str::to_owned),
        max_decompressed_size: Some(64 * 1024 * 1024),
        ..LoadOptions::default()
    };
    let document = match Document::load_with_options(path, options) {
        Ok(document) => document,
        Err(error) => {
            eprintln!("aris-link-borders: could not read legacy border dictionaries: {error}");
            return HashMap::new();
        }
    };
    let mut pages = HashMap::new();
    for (number, id) in document.get_pages() {
        let Ok(page) = document.get_dictionary(id) else {
            continue;
        };
        let Some(annotations) = value(&document, page, b"Annots").and_then(|o| o.as_array().ok())
        else {
            continue;
        };
        let borders: Vec<_> = annotations
            .iter()
            .filter_map(|object| {
                let annotation = direct(&document, object)?.as_dict().ok()?;
                parse(&document, annotation)
            })
            .collect();
        if !borders.is_empty() {
            pages.insert(PageIndex(number - 1), borders);
        }
    }
    // Drop the PDF object graph; the cache retains only the small border paths and styles.
    pages
}

fn direct<'a>(document: &'a Document, object: &'a Object) -> Option<&'a Object> {
    document.dereference(object).ok().map(|(_, object)| object)
}

fn value<'a>(document: &'a Document, dictionary: &'a Dictionary, key: &[u8]) -> Option<&'a Object> {
    direct(document, dictionary.get(key).ok()?)
}

fn number(object: &Object) -> Option<f32> {
    let value = match object {
        Object::Integer(n) => *n as f32,
        Object::Real(n) => *n,
        _ => return None,
    };
    value.is_finite().then_some(value)
}

fn numbers(document: &Document, object: &Object) -> Option<Vec<f32>> {
    direct(document, object)?
        .as_array()
        .ok()?
        .iter()
        .map(|item| number(direct(document, item)?))
        .collect()
}

fn parse(document: &Document, annotation: &Dictionary) -> Option<LinkBorder> {
    if value(document, annotation, b"Subtype")?.as_name().ok()? != b"Link" {
        return None;
    }
    let flags = value(document, annotation, b"F")
        .and_then(|o| o.as_i64().ok())
        .unwrap_or(0);
    if flags & (1 | 2 | 32) != 0 {
        return None;
    }
    // Existing appearance streams belong to the native renderer, including custom artwork.
    if value(document, annotation, b"AP")
        .and_then(|o| o.as_dict().ok())
        .and_then(|ap| value(document, ap, b"N"))
        .is_some()
    {
        return None;
    }
    let rect = numbers(document, value(document, annotation, b"Rect")?)?;
    if rect.len() != 4 {
        return None;
    }
    let bs = value(document, annotation, b"BS").and_then(|o| o.as_dict().ok());
    // A /BS dictionary supersedes /Border entirely, including the default width of 1.
    let border = if bs.is_none() {
        value(document, annotation, b"Border").and_then(|o| o.as_array().ok())
    } else {
        None
    };
    let border_number = |index: usize| {
        border
            .and_then(|a| a.get(index))
            .and_then(|o| direct(document, o))
            .and_then(number)
    };
    let width = bs
        .and_then(|d| value(document, d, b"W"))
        .and_then(number)
        .unwrap_or_else(|| border_number(2).unwrap_or(1.0));
    if width <= 0.0 {
        return None;
    }
    let color = match value(document, annotation, b"C") {
        None => [0.0; 3],
        Some(object) => match numbers(document, object)?.as_slice() {
            [gray] => [*gray; 3],
            [r, g, b] => [*r, *g, *b],
            [c, m, y, k] => [
                (1.0 - c) * (1.0 - k),
                (1.0 - m) * (1.0 - k),
                (1.0 - y) * (1.0 - k),
            ],
            _ => return None, // An empty /C array explicitly requests an invisible border.
        },
    }
    .map(|component| component.clamp(0.0, 1.0));
    let style = bs
        .and_then(|d| value(document, d, b"S"))
        .and_then(|o| o.as_name().ok())
        .unwrap_or(b"S");
    let dash = if style == b"D" {
        bs.and_then(|d| value(document, d, b"D"))
            .and_then(|o| numbers(document, o))
            .or_else(|| Some(vec![3.0]))
    } else if bs.is_none() {
        border
            .and_then(|a| a.get(3))
            .and_then(|o| numbers(document, o))
    } else {
        None
    };
    let dash = dash.and_then(|mut values| {
        if values.len() % 2 != 0 {
            values.extend(values.clone());
        }
        StrokeDash::new(values, 0.0)
    });
    let left = rect[0].min(rect[2]) + width / 2.0;
    let right = rect[0].max(rect[2]) - width / 2.0;
    let bottom = rect[1].min(rect[3]) + width / 2.0;
    let top = rect[1].max(rect[3]) - width / 2.0;
    if right <= left || top <= bottom {
        return None;
    }
    let mut path = PathBuilder::new();
    if style == b"U" {
        path.move_to(left, bottom);
        path.line_to(right, bottom);
    } else {
        let rx = border_number(0)
            .unwrap_or(0.0)
            .max(0.0)
            .min((right - left) / 2.0);
        let ry = border_number(1)
            .unwrap_or(0.0)
            .max(0.0)
            .min((top - bottom) / 2.0);
        let k = 0.552_284_8;
        path.move_to(left + rx, bottom);
        path.line_to(right - rx, bottom);
        path.cubic_to(
            right - rx + k * rx,
            bottom,
            right,
            bottom + ry - k * ry,
            right,
            bottom + ry,
        );
        path.line_to(right, top - ry);
        path.cubic_to(
            right,
            top - ry + k * ry,
            right - rx + k * rx,
            top,
            right - rx,
            top,
        );
        path.line_to(left + rx, top);
        path.cubic_to(
            left + rx - k * rx,
            top,
            left,
            top - ry + k * ry,
            left,
            top - ry,
        );
        path.line_to(left, bottom + ry);
        path.cubic_to(
            left,
            bottom + ry - k * ry,
            left + rx - k * rx,
            bottom,
            left + rx,
            bottom,
        );
        path.close();
    }
    Some(LinkBorder {
        path: path.finish()?,
        color,
        opacity: value(document, annotation, b"CA")
            .and_then(number)
            .unwrap_or(1.0)
            .clamp(0.0, 1.0),
        stroke: Stroke {
            width,
            dash,
            ..Stroke::default()
        },
    })
}

pub(crate) fn paint(
    borders: &[LinkBorder],
    geometry: PageGeometry,
    request: &RasterRequest,
    tile: &mut RasterTile,
) {
    let mut transform = geometry.page_to_view(request.scale);
    if let Some(region) = request.region {
        transform.tx -= region.origin.x * request.scale;
        transform.ty -= region.origin.y * request.scale;
    }
    let transform = Transform::from_row(
        transform.a as f32,
        transform.b as f32,
        transform.c as f32,
        transform.d as f32,
        transform.tx as f32,
        transform.ty as f32,
    );
    let Some(mut pixmap) = PixmapMut::from_bytes(
        &mut tile.pixels,
        tile.size.width as u32,
        tile.size.height as u32,
    ) else {
        return;
    };
    for border in borders {
        // A deep-zoom tile usually intersects only a few of a page's hundreds of links.
        let margin = border.stroke.width * 2.0;
        let Some(bounds) = border
            .path
            .bounds()
            .outset(margin, margin)
            .and_then(|bounds| bounds.transform(transform))
        else {
            continue;
        };
        if bounds.right() < 0.0
            || bounds.bottom() < 0.0
            || bounds.left() > tile.size.width as f32
            || bounds.top() > tile.size.height as f32
        {
            continue;
        }
        let mut paint = Paint {
            anti_alias: true,
            ..Paint::default()
        };
        // tiny-skia sees RGBA bytes; the page is BGRA. Swap the paint's red/blue channels so
        // coverage compositing acts on the existing premultiplied buffer without a copy.
        paint.set_color_rgba8(
            (border.color[2] * 255.0).round() as u8,
            (border.color[1] * 255.0).round() as u8,
            (border.color[0] * 255.0).round() as u8,
            (border.opacity * 255.0).round() as u8,
        );
        pixmap.stroke_path(&border.path, &paint, &border.stroke, transform, None);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lopdf::dictionary;

    #[test]
    fn border_style_dictionary_overrides_a_zero_width_legacy_border() {
        let mut document = Document::new();
        let style = document.add_object(dictionary! {"S" => "D"});
        let annotation = dictionary! {
            "Subtype" => "Link", "Rect" => vec![0.into(), 0.into(), 100.into(), 20.into()],
            "Border" => vec![0.into(), 0.into(), 0.into()], "BS" => Object::Reference(style),
        };
        let border = parse(&document, &annotation).expect("/BS has a visible default width of 1");
        assert_eq!(border.stroke.width, 1.0);
        assert!(border.stroke.dash.is_some());
    }

    #[test]
    fn empty_colour_and_no_view_flag_suppress_legacy_borders() {
        let document = Document::new();
        let mut annotation = dictionary! {
            "Subtype" => "Link", "Rect" => vec![0.into(), 0.into(), 100.into(), 20.into()],
            "C" => Object::Array(vec![]),
        };
        assert!(parse(&document, &annotation).is_none());
        annotation.remove(b"C");
        annotation.set("F", 32);
        assert!(parse(&document, &annotation).is_none());
    }
}
