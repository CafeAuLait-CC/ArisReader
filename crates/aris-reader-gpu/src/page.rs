//! Textured-quad rendering: the beginning of the tile compositor.
//!
//! The M0 spike drew a triangle to prove the surface path; this module replaces that
//! with the real shape of the pipeline — a page bitmap uploaded as a GPU texture and
//! drawn as a quad at a destination rectangle. Tiles, atlases and per-page caching are
//! T1.6/T1.7 refinements of exactly these three calls.
//!
//! # Data flow (M1 slice)
//!
//! ```text
//! PDFium (BGRA, sRGB) ──upload_page_texture()──▶ wgpu texture
//!                                                 │
//!                       render_page(surface, texture, dest) ──▶ surface drawable
//! ```
//!
//! # Colour handling
//!
//! Both the uploaded texture and the render target are `*Srgb` formats, so the sampler
//! decodes sRGB → linear and the target encodes linear → sRGB again: pixels survive the
//! round trip unchanged (`docs/03-rendering.md` §7).

use crate::{FrameReport, GpuContext, SurfaceId};
use aris_reader_core::{ArisError, ErrorCode, Result};
use std::collections::HashMap;

/// Handle to a texture owned by the GPU context.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct TextureId(pub u64);

/// Uniform block layout: `dest: vec4<f32>` + `surface: vec2<f32>` + padding.
const UNIFORM_BYTES: u64 = 32;

/// The shader that draws a textured quad in *pixel* coordinates.
///
/// Pixel coordinates (converted to NDC in the vertex stage) keep the caller's math
/// trivial — the shell works in device pixels anyway — and avoid a second coordinate
/// convention leaking into the engine.
const PAGE_SHADER: &str = r#"
struct Uniforms {
    // x, y, width, height in physical pixels of the target surface.
    dest: vec4<f32>,
    // Surface size in physical pixels.
    surface: vec2<f32>,
    _padding: vec2<f32>,
};

@group(0) @binding(0) var<uniform> uniforms: Uniforms;
@group(0) @binding(1) var page_texture: texture_2d<f32>;
@group(0) @binding(2) var page_sampler: sampler;

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@vertex
fn vs_page(@builtin(vertex_index) index: u32) -> VertexOutput {
    var corners = array<vec2<f32>, 6>(
        vec2<f32>(0.0, 0.0),
        vec2<f32>(1.0, 0.0),
        vec2<f32>(0.0, 1.0),
        vec2<f32>(1.0, 0.0),
        vec2<f32>(1.0, 1.0),
        vec2<f32>(0.0, 1.0),
    );

    let corner = corners[index];
    let pixel = uniforms.dest.xy + corner * uniforms.dest.zw;

    var out: VertexOutput;
    out.position = vec4<f32>(
        pixel.x / uniforms.surface.x * 2.0 - 1.0,
        1.0 - pixel.y / uniforms.surface.y * 2.0,
        0.0,
        1.0,
    );
    out.uv = corner;
    return out;
}

@fragment
fn fs_page(in: VertexOutput) -> @location(0) vec4<f32> {
    return textureSample(page_texture, page_sampler, in.uv);
}

// `/BM /Multiply`, the blend mode a PDF highlight is normally stored with.
//
// The tint texture holds the annotation colour C gamma-encoded (sRGB) and its opacity a,
// straight rather than premultiplied. The pipeline's blend state is
// `src * dst + dst * (1 - a)`, so emitting `C * a` yields `dst * (a * C + 1 - a)`, which is
// PDF's multiply with constant opacity (PDF 32000-1 §11.3.5) for an opaque backdrop.
//
// Why a linear-space GPU multiply comes out as PDF's gamma-space multiply: the sampler
// decodes C from sRGB to linear and the sRGB render target encodes the result back, and
// `encode(decode(p) * decode(c)) == p * c` for the same transfer function. Doing the
// arithmetic in linear light *without* that round trip would darken every highlight.
@fragment
fn fs_page_multiply(in: VertexOutput) -> @location(0) vec4<f32> {
    let colour = textureSample(page_texture, page_sampler, in.uv);
    return vec4<f32>(colour.rgb * colour.a, colour.a);
}
"#;

/// How a textured quad is composited with what is already in the frame.
///
/// This is not cosmetic. A highlight is drawn as a tint quad over the page, and PDF stores
/// highlights with `/BM /Multiply`: drawing one with plain alpha-over paints the stored colour
/// *over* the glyphs instead of multiplying into them, so the same file shows a different
/// colour here than in Preview. [`QuadBlend::Multiply`] is that missing half.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum QuadBlend {
    /// Straight alpha-over: pages, selection, and any overlay that should cover what is below.
    Normal,
    /// The PDF `/BM /Multiply` blend mode.
    ///
    /// Callers that have a constant opacity to apply should **bake it into the tint colour
    /// first**: upload `c' = a·c + (1 − a)` at alpha 255 rather than `c` at alpha `a`. PDF mixes
    /// the opacity in the stored (gamma-encoded) colour space while the hardware mixes in linear
    /// light, and the two are not the same picture: measured on a 0xE0 page with a 0x50 channel at
    /// `/CA 0.5`, the unbaked path lands 23/255 (about 9%) brighter than the file. Baking costs
    /// one rounding step at upload and makes the drawn colour exactly the file's — see the
    /// `multiply_with_baked_opacity_matches_pdf` test.
    Multiply,
}

impl QuadBlend {
    /// The fragment entry point and blend state that implement this mode.
    fn fragment_entry(self) -> &'static str {
        match self {
            Self::Normal => "fs_page",
            Self::Multiply => "fs_page_multiply",
        }
    }

    /// The blend state paired with [`QuadBlend::fragment_entry`].
    ///
    /// `Multiply` reads the destination as the source factor, which is what makes the shader's
    /// `C * a` multiply the page colour; the alpha channel keeps the usual
    /// over-operator so a translucent highlight still ends up with a sane alpha.
    fn blend_state(self) -> wgpu::BlendState {
        match self {
            Self::Normal => wgpu::BlendState::ALPHA_BLENDING,
            Self::Multiply => wgpu::BlendState {
                color: wgpu::BlendComponent {
                    src_factor: wgpu::BlendFactor::Dst,
                    dst_factor: wgpu::BlendFactor::OneMinusSrcAlpha,
                    operation: wgpu::BlendOperation::Add,
                },
                alpha: wgpu::BlendComponent {
                    src_factor: wgpu::BlendFactor::One,
                    dst_factor: wgpu::BlendFactor::OneMinusSrcAlpha,
                    operation: wgpu::BlendOperation::Add,
                },
            },
        }
    }
}

/// Page-pipeline state: shader, one pipeline per (target format, blend mode), sampler, uniform
/// buffer and the uploaded textures.
pub struct PageState {
    shader: wgpu::ShaderModule,
    bind_group_layout: wgpu::BindGroupLayout,
    sampler: wgpu::Sampler,
    pipelines: HashMap<(wgpu::TextureFormat, QuadBlend), wgpu::RenderPipeline>,
    textures: HashMap<TextureId, wgpu::TextureView>,
    next_texture_id: u64,
}

impl PageState {
    pub(crate) fn new(device: &wgpu::Device) -> Self {
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("aris-reader-page-shader"),
            source: wgpu::ShaderSource::Wgsl(PAGE_SHADER.into()),
        });

        let bind_group_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("aris-reader-page-bind-layout"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::VERTEX,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: true },
                        view_dimension: wgpu::TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 2,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
            ],
        });

        // Linear filtering: pages are rasterised at the zoom they are shown at, but a
        // resize or a pinch frame still samples between texels.
        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("aris-reader-page-sampler"),
            address_mode_u: wgpu::AddressMode::ClampToEdge,
            address_mode_v: wgpu::AddressMode::ClampToEdge,
            address_mode_w: wgpu::AddressMode::ClampToEdge,
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            mipmap_filter: wgpu::MipmapFilterMode::Nearest,
            ..Default::default()
        });

        Self {
            shader,
            bind_group_layout,
            sampler,
            pipelines: HashMap::new(),
            textures: HashMap::new(),
            next_texture_id: 1,
        }
    }

    /// Creates, once per (target format, blend mode), the textured-quad pipeline.
    pub(crate) fn ensure_pipeline(
        &mut self,
        device: &wgpu::Device,
        format: wgpu::TextureFormat,
        blend: QuadBlend,
    ) {
        if self.pipelines.contains_key(&(format, blend)) {
            return;
        }
        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("aris-reader-page-pipeline-layout"),
            // wgpu 30 takes optional layouts and "immediates" instead of push constants.
            bind_group_layouts: &[Some(&self.bind_group_layout)],
            immediate_size: 0,
        });
        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("aris-reader-page-pipeline"),
            layout: Some(&pipeline_layout),
            vertex: wgpu::VertexState {
                module: &self.shader,
                entry_point: Some("vs_page"),
                buffers: &[],
                compilation_options: Default::default(),
            },
            fragment: Some(wgpu::FragmentState {
                module: &self.shader,
                entry_point: Some(blend.fragment_entry()),
                targets: &[Some(wgpu::ColorTargetState {
                    format,
                    blend: Some(blend.blend_state()),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
                compilation_options: Default::default(),
            }),
            primitive: wgpu::PrimitiveState::default(),
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview_mask: None,
            cache: None,
        });
        self.pipelines.insert((format, blend), pipeline);
    }

    /// The pipeline for `format`/`blend`; the caller must have called [`Self::ensure_pipeline`].
    fn pipeline(
        &self,
        format: wgpu::TextureFormat,
        blend: QuadBlend,
    ) -> Option<&wgpu::RenderPipeline> {
        self.pipelines.get(&(format, blend))
    }

    fn texture_count(&self) -> usize {
        self.textures.len()
    }
}

impl GpuContext {
    /// Uploads a page bitmap (BGRA, sRGB) and returns its handle.
    ///
    /// The data comes straight from PDFium (`RasterFormat::Bgra8Premultiplied`), so no
    /// conversion happens here — matching the wgpu-side contract in
    /// `docs/03-rendering.md` §5.
    pub fn upload_page_texture(
        &mut self,
        width: u32,
        height: u32,
        bgra: &[u8],
    ) -> Result<TextureId> {
        if width == 0 || height == 0 {
            return Err(ArisError::new(
                ErrorCode::InvalidArgument,
                "page texture must have a non-zero size",
            ));
        }
        let expected = width as usize * height as usize * 4;
        if bgra.len() < expected {
            return Err(ArisError::new(
                ErrorCode::InvalidArgument,
                format!(
                    "page bitmap is too small: {} bytes, expected {expected}",
                    bgra.len()
                ),
            ));
        }

        let texture = self.device.create_texture(&wgpu::TextureDescriptor {
            label: Some("aris-reader-page"),
            size: wgpu::Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            // sRGB, so the sampler decodes exactly what PDFium encoded.
            format: wgpu::TextureFormat::Bgra8UnormSrgb,
            usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });

        self.queue.write_texture(
            wgpu::TexelCopyTextureInfo {
                texture: &texture,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            &bgra[..expected],
            wgpu::TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(width * 4),
                rows_per_image: Some(height),
            },
            wgpu::Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
        );

        let view = texture.create_view(&wgpu::TextureViewDescriptor::default());
        let id = TextureId(self.page.next_texture_id);
        self.page.next_texture_id += 1;
        self.page.textures.insert(id, view);

        Ok(id)
    }

    /// Releases an uploaded texture.
    pub fn release_texture(&mut self, id: TextureId) -> Result<()> {
        self.page.textures.remove(&id).map(|_| ()).ok_or_else(|| {
            ArisError::new(
                ErrorCode::InvalidArgument,
                format!("texture {} is not uploaded", id.0),
            )
        })
    }

    /// Number of uploaded textures (diagnostics and tests).
    pub fn texture_count(&self) -> usize {
        self.page.texture_count()
    }

    /// Draws `texture` into `surface` at `destination` (physical pixels) and presents it.
    ///
    /// `destination` is `[x, y, width, height]`; anything outside the surface is clipped
    /// by the GPU. The rest of the surface is cleared to `clear`.
    pub fn render_page(
        &mut self,
        surface_id: SurfaceId,
        texture_id: TextureId,
        destination: [f32; 4],
        clear: [f64; 4],
    ) -> Result<FrameReport> {
        self.render_pages(
            surface_id,
            &[(texture_id, destination, QuadBlend::Normal)],
            clear,
        )
    }

    /// Draws several textured quads into one frame and presents it.
    ///
    /// This is what continuous scrolling needs: every visible page (later: every visible
    /// tile) goes into a single frame. Each quad gets its own small uniform buffer,
    /// because `Queue::write_buffer` is ordered against submissions, not against draws
    /// inside one encoder — sharing a buffer would make every quad use the last values.
    ///
    /// Each draw carries its own [`QuadBlend`]: a page is painted over the background, while a
    /// PDF highlight loaded from the file is multiplied into the page under it (see
    /// [`QuadBlend::Multiply`]). Draws are composited in the order given.
    pub fn render_pages(
        &mut self,
        surface_id: SurfaceId,
        draws: &[(TextureId, [f32; 4], QuadBlend)],
        clear: [f64; 4],
    ) -> Result<FrameReport> {
        let started = std::time::Instant::now();

        let (frame, format, width, height, settings, surface_frame_index) = {
            let entry = self.surfaces.get(&surface_id).ok_or_else(|| {
                ArisError::new(
                    ErrorCode::InvalidArgument,
                    format!("surface {} is not attached", surface_id.0),
                )
            })?;

            let frame = match entry.surface.get_current_texture() {
                wgpu::CurrentSurfaceTexture::Success(frame)
                | wgpu::CurrentSurfaceTexture::Suboptimal(frame) => frame,
                wgpu::CurrentSurfaceTexture::Occluded => {
                    // Correct power-saving behaviour: nothing to draw, nothing to report.
                    return Ok(FrameReport {
                        surface_id,
                        width: entry.config.width,
                        height: entry.config.height,
                        format_is_srgb: entry.config.format.is_srgb(),
                        color_space: entry.settings.color_space,
                        presented: false,
                        center_pixel_bgra: None,
                        elapsed_us: started.elapsed().as_micros() as u64,
                        frame_index: self.frames_rendered,
                        surface_frame_index: entry.frame_index,
                    });
                }
                other => {
                    return Err(ArisError::new(
                        ErrorCode::RenderFailed,
                        "could not acquire a surface texture",
                    )
                    .with_detail(format!("{other:?}")));
                }
            };

            (
                frame,
                entry.config.format,
                entry.config.width,
                entry.config.height,
                entry.settings,
                entry.frame_index,
            )
        };

        // One pipeline per blend mode in use, created before the shared borrows below.
        for (_, _, blend) in draws {
            self.page.ensure_pipeline(&self.device, format, *blend);
        }

        // Per-quad uniform buffers and bind groups. Each quad needs its own buffer because
        // `Queue::write_buffer` is ordered against submissions, not against the draws
        // inside a single encoder; the buffers stay alive until after the submit below.
        let mut bind_groups = Vec::with_capacity(draws.len());
        let mut uniform_buffers = Vec::with_capacity(draws.len());
        for (texture_id, rect, _) in draws {
            let uniforms: [f32; 8] = [
                rect[0],
                rect[1],
                rect[2],
                rect[3],
                width as f32,
                height as f32,
                0.0,
                0.0,
            ];
            let buffer = self.device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("aris-reader-page-uniforms"),
                size: UNIFORM_BYTES,
                usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
                mapped_at_creation: false,
            });
            self.queue
                .write_buffer(&buffer, 0, &f32s_to_bytes(&uniforms));

            let texture_view = self.page.textures.get(texture_id).ok_or_else(|| {
                ArisError::new(
                    ErrorCode::InvalidArgument,
                    format!("texture {} is not uploaded", texture_id.0),
                )
            })?;
            bind_groups.push(self.device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("aris-reader-page-bind-group"),
                layout: &self.page.bind_group_layout,
                entries: &[
                    wgpu::BindGroupEntry {
                        binding: 0,
                        resource: buffer.as_entire_binding(),
                    },
                    wgpu::BindGroupEntry {
                        binding: 1,
                        resource: wgpu::BindingResource::TextureView(texture_view),
                    },
                    wgpu::BindGroupEntry {
                        binding: 2,
                        resource: wgpu::BindingResource::Sampler(&self.page.sampler),
                    },
                ],
            }));
            uniform_buffers.push(buffer);
        }

        // Resolve one pipeline per draw, in draw order.
        let pipelines = draws
            .iter()
            .map(|(_, _, blend)| {
                self.page
                    .pipeline(format, *blend)
                    .ok_or_else(|| ArisError::new(ErrorCode::Internal, "page pipeline missing"))
            })
            .collect::<Result<Vec<_>>>()?;

        let target = frame
            .texture
            .create_view(&wgpu::TextureViewDescriptor::default());

        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("aris-page-frame"),
            });

        // The first pass clears, the rest load what is already there; with nothing to
        // draw we still clear so the window never shows a stale frame.
        for (index, bind_group) in bind_groups.iter().enumerate() {
            begin_page_pass(
                &mut encoder,
                &target,
                clear,
                index == 0,
                Some((pipelines[index], bind_group)),
            );
        }
        if bind_groups.is_empty() {
            begin_page_pass(&mut encoder, &target, clear, true, None);
        }

        self.queue.submit(Some(encoder.finish()));
        self.queue.present(frame);

        self.frames_rendered += 1;
        if let Some(entry) = self.surfaces.get_mut(&surface_id) {
            entry.frame_index += 1;
        }

        Ok(FrameReport {
            surface_id,
            width,
            height,
            format_is_srgb: format.is_srgb(),
            color_space: settings.color_space,
            presented: true,
            // Reading the drawable back would need COPY_SRC on the surface; the shell's
            // canvas opts in for diagnostics, but the page path does not require it.
            center_pixel_bgra: None,
            elapsed_us: started.elapsed().as_micros() as u64,
            frame_index: self.frames_rendered,
            surface_frame_index: surface_frame_index + 1,
        })
    }

    /// Renders `texture` 1:1 into an offscreen texture and reads the pixels back.
    ///
    /// This is the window-less verification path for the page pipeline: same upload,
    /// same shader, same sampler, no `CAMetalLayer` required. One quad, alpha-over, on black.
    pub fn offscreen_probe_textured(
        &mut self,
        texture_id: TextureId,
        width: u32,
        height: u32,
    ) -> Result<Vec<u8>> {
        let rect = [0.0, 0.0, width as f32, height as f32];
        self.offscreen_probe_layers(&[(texture_id, rect, QuadBlend::Normal)], width, height)
    }

    /// Renders a stack of textured quads offscreen, in order, and reads the pixels back.
    ///
    /// The window-less verification path for anything that depends on how quads composite:
    /// the first draw clears (so a page paints its own background), every later draw blends
    /// into what is already there with its own [`QuadBlend`]. Returns tightly packed RGBA8
    /// rows — no 256-byte padding, unlike the readback buffer itself.
    pub fn offscreen_probe_layers(
        &mut self,
        draws: &[(TextureId, [f32; 4], QuadBlend)],
        width: u32,
        height: u32,
    ) -> Result<Vec<u8>> {
        if width == 0 || height == 0 {
            return Err(ArisError::new(
                ErrorCode::InvalidArgument,
                "an offscreen probe needs a non-zero size",
            ));
        }

        let format = wgpu::TextureFormat::Rgba8UnormSrgb;
        let target = self.device.create_texture(&wgpu::TextureDescriptor {
            label: Some("page-probe-target"),
            size: wgpu::Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
            view_formats: &[],
        });
        let target_view = target.create_view(&wgpu::TextureViewDescriptor::default());

        // bytes_per_row must be a multiple of 256 for buffer copies.
        let bytes_per_row = (width * 4).div_ceil(256) * 256;
        let buffer = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("page-probe-readback"),
            size: u64::from(bytes_per_row) * u64::from(height),
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });

        let mut uniform_buffers = Vec::with_capacity(draws.len());
        let mut bind_groups = Vec::with_capacity(draws.len());
        for (texture_id, rect, _) in draws {
            let uniforms: [f32; 8] = [
                rect[0],
                rect[1],
                rect[2],
                rect[3],
                width as f32,
                height as f32,
                0.0,
                0.0,
            ];
            let uniform_buffer = self.device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("page-probe-uniforms"),
                size: UNIFORM_BYTES,
                usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
                mapped_at_creation: false,
            });
            self.queue
                .write_buffer(&uniform_buffer, 0, &f32s_to_bytes(&uniforms));

            let texture_view = self.page.textures.get(texture_id).ok_or_else(|| {
                ArisError::new(
                    ErrorCode::InvalidArgument,
                    format!("texture {} is not uploaded", texture_id.0),
                )
            })?;
            bind_groups.push(self.device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("page-probe-bind-group"),
                layout: &self.page.bind_group_layout,
                entries: &[
                    wgpu::BindGroupEntry {
                        binding: 0,
                        resource: uniform_buffer.as_entire_binding(),
                    },
                    wgpu::BindGroupEntry {
                        binding: 1,
                        resource: wgpu::BindingResource::TextureView(texture_view),
                    },
                    wgpu::BindGroupEntry {
                        binding: 2,
                        resource: wgpu::BindingResource::Sampler(&self.page.sampler),
                    },
                ],
            }));
            uniform_buffers.push(uniform_buffer);
        }

        for (_, _, blend) in draws {
            self.page.ensure_pipeline(&self.device, format, *blend);
        }
        let pipelines = draws
            .iter()
            .map(|(_, _, blend)| {
                self.page
                    .pipeline(format, *blend)
                    .ok_or_else(|| ArisError::new(ErrorCode::Internal, "page pipeline missing"))
            })
            .collect::<Result<Vec<_>>>()?;

        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("page-probe"),
            });
        {
            let color_attachment = wgpu::RenderPassColorAttachment {
                view: &target_view,
                depth_slice: None,
                resolve_target: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                    store: wgpu::StoreOp::Store,
                },
            };
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("page-probe-pass"),
                color_attachments: &[Some(color_attachment)],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            });
            for (index, bind_group) in bind_groups.iter().enumerate() {
                pass.set_pipeline(pipelines[index]);
                pass.set_bind_group(0, bind_group, &[]);
                pass.draw(0..6, 0..1);
            }
        }
        encoder.copy_texture_to_buffer(
            wgpu::TexelCopyTextureInfo {
                texture: &target,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            wgpu::TexelCopyBufferInfo {
                buffer: &buffer,
                layout: wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(bytes_per_row),
                    rows_per_image: Some(height),
                },
            },
            wgpu::Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
        );
        self.queue.submit(Some(encoder.finish()));

        let slice = buffer.slice(..);
        slice.map_async(wgpu::MapMode::Read, |_| {});
        let _ = self.device.poll(wgpu::PollType::wait_indefinitely());

        let mut pixels = Vec::with_capacity((width * height * 4) as usize);
        {
            let data = slice
                .get_mapped_range()
                .expect("buffer is mapped after poll");
            for row in 0..height {
                let start = (row * bytes_per_row) as usize;
                pixels.extend_from_slice(&data[start..start + (width * 4) as usize]);
            }
        }
        buffer.unmap();
        Ok(pixels)
    }
}

/// Starts one page render pass: clears when `clear_first`, then draws one quad if given.
fn begin_page_pass(
    encoder: &mut wgpu::CommandEncoder,
    target: &wgpu::TextureView,
    clear: [f64; 4],
    clear_first: bool,
    draw: Option<(&wgpu::RenderPipeline, &wgpu::BindGroup)>,
) {
    let color_attachment = wgpu::RenderPassColorAttachment {
        view: target,
        depth_slice: None,
        resolve_target: None,
        ops: wgpu::Operations {
            load: if clear_first {
                wgpu::LoadOp::Clear(wgpu::Color {
                    r: clear[0],
                    g: clear[1],
                    b: clear[2],
                    a: clear[3],
                })
            } else {
                wgpu::LoadOp::Load
            },
            store: wgpu::StoreOp::Store,
        },
    };
    let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
        label: Some("aris-page-pass"),
        color_attachments: &[Some(color_attachment)],
        depth_stencil_attachment: None,
        timestamp_writes: None,
        occlusion_query_set: None,
        multiview_mask: None,
    });
    if let Some((pipeline, bind_group)) = draw {
        pass.set_pipeline(pipeline);
        pass.set_bind_group(0, bind_group, &[]);
        pass.draw(0..6, 0..1);
    }
}

fn f32s_to_bytes(values: &[f32]) -> Vec<u8> {
    values
        .iter()
        .flat_map(|value| value.to_le_bytes())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A 2×2 texture with four distinct colours.
    fn checkerboard() -> (u32, u32, Vec<u8>) {
        // BGRA order: top-left red, top-right green, bottom-left blue, bottom-right white.
        let pixels: [[u8; 4]; 4] = [
            [0, 0, 255, 255],
            [0, 255, 0, 255],
            [255, 0, 0, 255],
            [255, 255, 255, 255],
        ];
        (2, 2, pixels.concat())
    }

    #[test]
    fn upload_rejects_short_buffers() {
        let mut context = match GpuContext::new(false) {
            Ok(context) => context,
            Err(error) => {
                eprintln!("skipping: {error}");
                return;
            }
        };
        let error = context.upload_page_texture(4, 4, &[0u8; 8]).unwrap_err();
        assert_eq!(error.code, ErrorCode::InvalidArgument);
    }

    #[test]
    fn render_page_draws_the_texture_and_round_trips_colour() {
        let mut context = match GpuContext::new(false) {
            Ok(context) => context,
            Err(error) => {
                eprintln!("skipping: {error}");
                return;
            }
        };

        let (width, height, pixels) = checkerboard();
        let texture = context
            .upload_page_texture(width, height, &pixels)
            .expect("upload");
        assert_eq!(context.texture_count(), 1);

        // No CAMetalLayer in a headless test, so exercise upload + shader + sampler
        // through the offscreen helper (the surface path is covered by the app run).
        let rendered = context
            .offscreen_probe_textured(texture, width, height)
            .expect("textured probe");
        assert_eq!(rendered.len(), (width * height * 4) as usize);

        // The probe draws the texture 1:1 in RGBA order.
        assert_eq!(&rendered[0..3], &[255, 0, 0], "top-left should be red");
        assert_eq!(rendered[3], 255, "top-left alpha");
        let last = rendered.len() - 4;
        assert_eq!(
            &rendered[last..last + 3],
            &[255, 255, 255],
            "bottom-right should be white"
        );

        context.release_texture(texture).expect("release");
        assert_eq!(context.texture_count(), 0);
    }

    /// A 1×1 straight-alpha tint texture in the colour the annotation carries.
    ///
    /// The bytes are the sRGB-encoded channels, not premultiplied: the multiply pipeline
    /// premultiplies in its fragment shader (see [`QuadBlend::Multiply`]).
    fn tint(red: u8, green: u8, blue: u8, alpha: u8) -> Vec<u8> {
        // BGRA — the order every texture in this engine is uploaded in.
        vec![blue, green, red, alpha]
    }

    /// A solid page texture, `value` in every channel, opaque.
    fn solid_page(value: u8) -> Vec<u8> {
        vec![value, value, value, 255]
    }

    /// The gamma-space product PDF's multiply blend is defined as, `page × colour / 255`.
    fn gamma_product(page: u8, channel: u8) -> u8 {
        ((u32::from(page) * u32::from(channel) + 127) / 255) as u8
    }

    /// `/BM /Multiply` must *multiply* the page, not cover it.
    ///
    /// The number to check against is the one PDF defines: `page × colour` on the stored
    /// (gamma-encoded) values, which is what Preview shows. An alpha-over draw of the same
    /// colour would land on the stored colour instead.
    #[test]
    fn multiply_blend_darkens_a_light_page() {
        let mut context = match GpuContext::new(false) {
            Ok(context) => context,
            Err(error) => {
                eprintln!("skipping: {error}");
                return;
            }
        };

        // Light grey paper and a mid-tone highlight colour, deliberately far apart so a
        // normal-blend mistake cannot land inside the tolerance.
        let page_value = 0xE0u8;
        let (red, green, blue) = (0xB4u8, 0x8Au8, 0x50u8);
        let page = context
            .upload_page_texture(1, 1, &solid_page(page_value))
            .expect("upload page");
        let highlight = context
            .upload_page_texture(1, 1, &tint(red, green, blue, 0xFF))
            .expect("upload highlight");

        let full = [0.0, 0.0, 1.0, 1.0];
        let pixels = context
            .offscreen_probe_layers(
                &[
                    (page, full, QuadBlend::Normal),
                    (highlight, full, QuadBlend::Multiply),
                ],
                1,
                1,
            )
            .expect("layered probe");

        // ±2 per channel: 8-bit quantisation on both sides of the sRGB transfer function.
        let tolerance = 2i32;
        for (index, expected_channel) in [red, green, blue].into_iter().enumerate() {
            let expected = gamma_product(page_value, expected_channel);
            let actual = pixels[index];
            assert!(
                (i32::from(actual) - i32::from(expected)).abs() <= tolerance,
                "channel {index}: expected about {expected} (page × colour), got {actual}"
            );
            assert!(
                actual < page_value,
                "multiply must darken the page, got {actual} on a {page_value} page"
            );
        }
    }

    /// The regression this feature exists for: multiply and alpha-over are not the same picture.
    #[test]
    fn multiply_and_normal_produce_different_pixels() {
        let mut context = match GpuContext::new(false) {
            Ok(context) => context,
            Err(error) => {
                eprintln!("skipping: {error}");
                return;
            }
        };

        let page_value = 0xE0u8;
        let page = context
            .upload_page_texture(1, 1, &solid_page(page_value))
            .expect("upload page");
        let highlight = context
            .upload_page_texture(1, 1, &tint(0xB4, 0x8A, 0x50, 0xFF))
            .expect("upload highlight");

        let full = [0.0, 0.0, 1.0, 1.0];
        let multiplied = context
            .offscreen_probe_layers(
                &[
                    (page, full, QuadBlend::Normal),
                    (highlight, full, QuadBlend::Multiply),
                ],
                1,
                1,
            )
            .expect("multiply probe");
        let over = context
            .offscreen_probe_layers(
                &[
                    (page, full, QuadBlend::Normal),
                    (highlight, full, QuadBlend::Normal),
                ],
                1,
                1,
            )
            .expect("normal probe");

        // Alpha-over at 255 must land exactly on the stored colour, i.e. the drawn colour must
        // *not* simply be the stored colour in the multiply case.
        assert_eq!(
            &over[0..3],
            &[0xB4, 0x8A, 0x50],
            "opaque over = stored colour"
        );
        let largest = (0..3)
            .map(|index| (i32::from(multiplied[index]) - i32::from(over[index])).abs())
            .max()
            .expect("three channels");
        assert!(
            largest >= 12,
            "multiply and normal must differ visibly, largest channel gap was {largest}: \
             multiply {multiplied:?}, over {over:?}"
        );
    }

    /// The recipe the canvas uses for `/CA`: bake the opacity into the colour, then multiply.
    ///
    /// PDF composites a highlight as `page × (a·colour + (1 − a))` with every value in the stored
    /// (gamma-encoded) space. Baking `a·colour + (1 − a)` into an opaque tint texture before the
    /// multiply reproduces that exactly — and it is the reason the tint texture is uploaded with
    /// alpha 255 rather than with the file's `/CA`.
    #[test]
    fn multiply_with_baked_opacity_matches_pdf() {
        let mut context = match GpuContext::new(false) {
            Ok(context) => context,
            Err(error) => {
                eprintln!("skipping: {error}");
                return;
            }
        };

        let page_value = 0xE0u8;
        let (red, green, blue) = (0xB4u8, 0x8Au8, 0x50u8);
        let a = f64::from(0x80u8) / 255.0;
        let bake = |channel: u8| (a * f64::from(channel) + (1.0 - a) * 255.0).round() as u8;

        let page = context
            .upload_page_texture(1, 1, &solid_page(page_value))
            .expect("upload page");
        let baked = context
            .upload_page_texture(1, 1, &tint(bake(red), bake(green), bake(blue), 0xFF))
            .expect("upload baked highlight");

        let full = [0.0, 0.0, 1.0, 1.0];
        let pixels = context
            .offscreen_probe_layers(
                &[
                    (page, full, QuadBlend::Normal),
                    (baked, full, QuadBlend::Multiply),
                ],
                1,
                1,
            )
            .expect("layered probe");

        let tolerance = 2i32;
        for (index, channel) in [red, green, blue].into_iter().enumerate() {
            let expected = gamma_product(page_value, bake(channel));
            let actual = pixels[index];
            assert!(
                (i32::from(actual) - i32::from(expected)).abs() <= tolerance,
                "channel {index}: expected about {expected} for /CA {a}, got {actual}"
            );
            assert!(
                actual < page_value,
                "a highlight must still darken the page, got {actual} on a {page_value} page"
            );
        }
    }

    /// A translucent multiply tint (opacity left in the alpha channel) still mixes sensibly.
    ///
    /// This is the fallback path for a caller that does not bake `/CA`: the shader premultiplies
    /// by alpha, so the result sits strictly between the untouched page and the fully opaque
    /// multiply. It is *approximately* PDF's value rather than exactly it — the mix happens in
    /// linear light — which is why the canvas bakes instead; the measured gap is asserted only as
    /// a bound so a future pipeline change cannot silently turn "slightly off" into "wrong".
    #[test]
    fn multiply_alpha_mixes_towards_the_page() {
        let mut context = match GpuContext::new(false) {
            Ok(context) => context,
            Err(error) => {
                eprintln!("skipping: {error}");
                return;
            }
        };

        let page_value = 0xE0u8;
        let (red, green, blue) = (0xB4u8, 0x8Au8, 0x50u8);
        let page = context
            .upload_page_texture(1, 1, &solid_page(page_value))
            .expect("upload page");
        let opaque = context
            .upload_page_texture(1, 1, &tint(red, green, blue, 0xFF))
            .expect("upload opaque highlight");
        let translucent = context
            .upload_page_texture(1, 1, &tint(red, green, blue, 0x80))
            .expect("upload translucent highlight");

        let full = [0.0, 0.0, 1.0, 1.0];
        let opaque_pixels = context
            .offscreen_probe_layers(
                &[
                    (page, full, QuadBlend::Normal),
                    (opaque, full, QuadBlend::Multiply),
                ],
                1,
                1,
            )
            .expect("opaque probe");
        let translucent_pixels = context
            .offscreen_probe_layers(
                &[
                    (page, full, QuadBlend::Normal),
                    (translucent, full, QuadBlend::Multiply),
                ],
                1,
                1,
            )
            .expect("translucent probe");

        // PDF's gamma-space value, for the record: `page × (a·colour + (1 − a))`.
        let a = 128.0 / 255.0;
        let mut worst = 0i32;
        for (index, channel) in [red, green, blue].into_iter().enumerate() {
            let ideal =
                f64::from(page_value) * (a * f64::from(channel) + (1.0 - a) * 255.0) / 255.0;
            worst = worst.max((f64::from(translucent_pixels[index]) - ideal).abs().round() as i32);
            assert!(
                translucent_pixels[index] > opaque_pixels[index]
                    && translucent_pixels[index] < page_value,
                "channel {index}: {} must sit between the opaque result {} and the page {page_value}",
                translucent_pixels[index],
                opaque_pixels[index]
            );
        }
        // Measured: 23/255 on the blue channel of this pair (page 0xE0, colour 0x50, /CA 0.5) —
        // i.e. an unbaked translucent highlight is about 9% brighter than the file says. The bound
        // is the measurement plus a small margin, and it exists to keep the gap *documented*: the
        // canvas bakes, so this path is only a safety net for a caller that forgets.
        assert!(
            worst <= 25,
            "an unbaked translucent multiply deviates from PDF's gamma-space value; \
             worst channel gap {worst}/255 (23 was measured for page 0xE0, colour 0x50, /CA 0.5)"
        );
    }
}
