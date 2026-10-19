use crate::PdfiumBackend;
use crate::test_support::{fixture, scratch};
use lyra_reader_core::{DocumentBackend, PageIndex, RasterRequest, RasterTile, Rect};

fn green(pixel: &[u8]) -> bool {
    i32::from(pixel[1]) - i32::from(pixel[2]) > 60 && i32::from(pixel[1]) - i32::from(pixel[0]) > 60
}

fn red(pixel: &[u8]) -> bool {
    pixel[2] > 180 && pixel[1] < 60 && pixel[0] < 60
}

fn blue(pixel: &[u8]) -> bool {
    pixel[0] > 180 && pixel[1] < 60 && pixel[2] < 60
}

fn count(tile: &RasterTile, rect: Rect, matches: fn(&[u8]) -> bool) -> usize {
    let mut hits = 0;
    for y in (rect.origin.y * 2.0) as usize..((rect.origin.y + rect.size.height) * 2.0) as usize {
        for x in (rect.origin.x * 2.0) as usize..((rect.origin.x + rect.size.width) * 2.0) as usize
        {
            let offset = y * tile.stride + x * 4;
            if matches(&tile.pixels[offset..offset + 4]) {
                hits += 1;
            }
        }
    }
    hits
}

#[test]
fn navigation_borders_render_without_burning_content_annotations() {
    let fixture = fixture("link-borders.pdf");
    if !crate::is_available() {
        eprintln!("skipping link borders: PDFium unavailable");
        return;
    }
    let original = std::fs::read(&fixture).expect("original bytes");
    let backend = PdfiumBackend::open(&fixture, None).expect("open");
    let mut request = RasterRequest::full_page(PageIndex(0), 2.0);
    assert!(!request.flags.annotations);
    let tile = backend.rasterize(&request).expect("render navigation only");
    assert!(count(&tile, Rect::new(70.0, 170.0, 152.0, 24.0), green) > 300);
    assert!(count(&tile, Rect::new(258.0, 170.0, 44.0, 24.0), red) > 100);
    assert_eq!(
        count(&tile, Rect::new(348.0, 170.0, 44.0, 24.0), blue),
        0,
        "a hidden link border must stay hidden"
    );
    assert_eq!(
        count(&tile, Rect::new(70.0, 220.0, 152.0, 24.0), blue),
        0,
        "a zero-width link border must stay invisible"
    );
    let highlight = Rect::new(425.0, 125.0, 70.0, 10.0);
    assert_eq!(
        count(&tile, highlight, blue),
        0,
        "the shell's highlight is not burned into its page raster"
    );

    // A /BS dashed border is painted by PDFium, including the gaps in a painted edge.
    assert!(count(&tile, Rect::new(258.0, 220.0, 134.0, 24.0), red) > 100);
    assert!(
        (440..450).any(|y| {
            let painted = (530..770)
                .filter(|x| red(&tile.pixels[y * tile.stride + x * 4..][..4]))
                .count();
            painted > 20 && painted < 200
        }),
        "the dashed edge contains both strokes and gaps"
    );

    let links = backend.link_targets(PageIndex(0)).expect("links");
    assert!(
        links
            .iter()
            .any(|link| link.uri.as_deref() == Some("https://example.org/invisible")),
        "a borderless link keeps its clickable target"
    );
    assert!(
        backend
            .annotations(PageIndex(0))
            .expect("annotations")
            .iter()
            .all(|annotation| annotation.visible),
        "renderer-only hiding must not hide the sidebar's content annotation"
    );

    request.flags.annotations = true;
    let annotated = backend.rasterize(&request).expect("render all annotations");
    assert!(
        count(&annotated, highlight, blue) > 1000,
        "explicit annotation rendering restores the original highlight"
    );
    request.flags.annotations = false;
    let again = backend
        .rasterize(&request)
        .expect("return to shell annotations");
    assert_eq!(count(&again, highlight, blue), 0);
    assert_eq!(
        tile.pixels, again.pixels,
        "switching rendering modes preserves the original navigation-only result"
    );

    request.region = Some(Rect::new(68.0, 168.0, 160.0, 30.0));
    let crop = backend
        .rasterize(&request)
        .expect("render border in a deep-zoom tile or preview region");
    assert!(
        crop.pixels
            .as_chunks::<4>()
            .0
            .iter()
            .filter(|pixel| green(*pixel))
            .count()
            > 200
    );
    request.region = None;
    request.scale = 0.5;
    let preview = backend.rasterize(&request).expect("render thumbnail");
    assert!(
        preview
            .pixels
            .as_chunks::<4>()
            .0
            .iter()
            .any(|pixel| green(pixel)),
        "preview rasters retain navigation borders too"
    );
    assert_eq!(
        std::fs::read(&fixture).expect("read source again"),
        original,
        "rendering must not modify the source PDF"
    );
}

#[test]
fn compressed_rotated_and_cropped_pages_keep_link_borders_in_their_view_coordinates() {
    if !crate::is_available() {
        return;
    }
    let fixture = fixture("link-borders.pdf");
    let mut document = lopdf::Document::load(&fixture).expect("parse fixture");
    let id = document.get_pages()[&1];
    let page = document
        .get_object_mut(id)
        .expect("page")
        .as_dict_mut()
        .expect("page dictionary");
    page.set("Rotate", 90);
    page.set(
        "CropBox",
        lopdf::Object::Array(vec![50.into(), 50.into(), 550.into(), 780.into()]),
    );
    let scratch = scratch("link-borders-rotated");
    let path = scratch.join("link-borders.pdf");
    document
        .save_modern(&mut std::fs::File::create(&path).expect("temporary file"))
        .expect("save compressed object streams");
    assert!(
        std::fs::read(&path)
            .expect("compressed PDF")
            .windows(7)
            .any(|bytes| bytes == b"/ObjStm")
    );
    let backend = PdfiumBackend::open(&path, None).expect("open rotated compressed PDF");
    let mut request = RasterRequest::full_page(PageIndex(0), 2.0);
    let tile = backend.rasterize(&request).expect("render rotated crop");
    let first = tile
        .pixels
        .as_chunks::<4>()
        .0
        .iter()
        .position(|pixel| green(pixel))
        .expect("the rotated cropped page retains its green border");
    let x = (first % (tile.stride / 4)) as f64 / 2.0;
    let y = (first / (tile.stride / 4)) as f64 / 2.0;
    request.region = Some(Rect::new(
        (x - 4.0).max(0.0),
        (y - 4.0).max(0.0),
        20.0,
        20.0,
    ));
    let crop = backend
        .rasterize(&request)
        .expect("render a tile at the transformed border");
    assert!(
        crop.pixels
            .as_chunks::<4>()
            .0
            .iter()
            .any(|pixel| green(pixel)),
        "deep-zoom tiles use the same rotated CropBox transform as the page raster"
    );
    drop(backend);
}
