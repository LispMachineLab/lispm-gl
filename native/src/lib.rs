// lispm-gl: OpenGL drawn into Emacs 32's canvas images.
//
// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Emacs 32 lends a module the pixels of a canvas image (`canvas_data'),
// ARGB32 in rows from the top, and shows them again when Lisp calls
// `canvas-refresh'.  Each canvas gets an OpenGL context of its own,
// without a window (platform.rs), drawing into a framebuffer as large as
// the canvas, multisampled when asked:
//
//   Lisp: clear, draw with programs and buffers   --> framebuffer
//   Lisp: read into CANVAS   framebuffer --resolve, glReadPixels BGRA-->
//         pixels, rows turned over, into the canvas  --> canvas-refresh
//
// OpenGL's BGRA read as 8_8_8_8_REV is a native-endian 0xAARRGGBB, the
// canvas's own format, so a row is copied, not converted.  Programs and
// buffers are the context's, named to Lisp by numbers, and go with it.
//
// Everything runs on Emacs's thread, the context made current at each call.

mod platform;

use std::collections::HashMap;

use emacs::{defun, Env, IntoLisp, Result, Value, Vector};
use glow::HasContext;
use platform::Platform;

emacs::plugin_is_GPL_compatible!();

#[emacs::module(
    name = "lispm-gl-core",
    defun_prefix = "lispm-gl-core",
    separator = "-"
)]
fn init(_: &Env) -> Result<()> {
    Ok(())
}

emacs::define_errors! {
    lispm_gl_error "OpenGL error" (error)
}

/// The largest side of a canvas, in pixels: more than any display shows.
const MAX_SIDE: i64 = 8192;

/// Signal `lispm-gl-error' with MESSAGE.
fn fail<T>(env: &Env, message: impl Into<String>) -> Result<T> {
    env.signal(lispm_gl_error, (message.into(),))
}

/// A uniform of a program: where it is, and its type, as OpenGL names it.
struct Uniform {
    location: glow::UniformLocation,
    kind: u32,
}

/// A linked program and its active uniforms, by name.
struct Program {
    program: glow::Program,
    uniforms: HashMap<String, Uniform>,
}

/// A buffer of vertices, and how many floats it holds.
struct Buffer {
    buffer: glow::Buffer,
    floats: usize,
}

/// A canvas's context, its framebuffer, and what Lisp made in it.
pub struct Gl {
    gl: glow::Context,
    width: i32,
    height: i32,
    framebuffer: glow::Framebuffer,
    renderbuffers: Vec<glow::Renderbuffer>,
    /// The single-sampled framebuffer a multisampled one resolves into, to
    /// be read; none when the framebuffer is not multisampled.
    resolve: Option<glow::Framebuffer>,
    vertex_array: glow::VertexArray,
    programs: HashMap<i64, Program>,
    buffers: HashMap<i64, Buffer>,
    next: i64,
    pixels: Vec<u32>,
    /// Last, so that it is dropped after everything above was deleted in it.
    context: platform::Context,
}

impl Gl {
    fn new(width: i32, height: i32, samples: i32) -> std::result::Result<Gl, String> {
        let context = platform::Context::new()?;
        context.make_current()?;
        // SAFETY: the context is current, and its functions are looked up in it.
        let gl =
            unsafe { glow::Context::from_loader_function_cstr(|name| context.proc_address(name)) };
        // SAFETY: OpenGL calls with the context current, on its objects only.
        unsafe {
            let samples = samples.clamp(0, gl.get_parameter_i32(glow::MAX_SAMPLES));
            let (framebuffer, mut renderbuffers) = Self::framebuffer(&gl, width, height, samples)?;
            let resolve = if samples > 0 {
                let (resolve, resolved) = Self::framebuffer(&gl, width, height, 0)?;
                renderbuffers.extend(resolved);
                Some(resolve)
            } else {
                None
            };
            let vertex_array = gl.create_vertex_array()?;
            gl.bind_vertex_array(Some(vertex_array));
            gl.bind_framebuffer(glow::FRAMEBUFFER, Some(framebuffer));
            gl.viewport(0, 0, width, height);
            gl.enable(glow::DEPTH_TEST);
            gl.enable(glow::BLEND);
            gl.blend_func(glow::SRC_ALPHA, glow::ONE_MINUS_SRC_ALPHA);
            let pixels = vec![0; (width as usize) * (height as usize)];
            Ok(Gl {
                gl,
                width,
                height,
                framebuffer,
                renderbuffers,
                resolve,
                vertex_array,
                programs: HashMap::new(),
                buffers: HashMap::new(),
                next: 1,
                pixels,
                context,
            })
        }
    }

    /// Make a framebuffer of WIDTH by HEIGHT with a colour and a depth
    /// buffer, multisampled when SAMPLES is above 0.
    ///
    /// # Safety
    /// GL's context must be current.
    unsafe fn framebuffer(
        gl: &glow::Context,
        width: i32,
        height: i32,
        samples: i32,
    ) -> std::result::Result<(glow::Framebuffer, Vec<glow::Renderbuffer>), String> {
        let framebuffer = gl.create_framebuffer()?;
        gl.bind_framebuffer(glow::FRAMEBUFFER, Some(framebuffer));
        let mut renderbuffers = Vec::new();
        for (format, attachment) in [
            (glow::RGBA8, glow::COLOR_ATTACHMENT0),
            (glow::DEPTH_COMPONENT24, glow::DEPTH_ATTACHMENT),
        ] {
            let renderbuffer = gl.create_renderbuffer()?;
            gl.bind_renderbuffer(glow::RENDERBUFFER, Some(renderbuffer));
            if samples > 0 {
                gl.renderbuffer_storage_multisample(
                    glow::RENDERBUFFER,
                    samples,
                    format,
                    width,
                    height,
                );
            } else {
                gl.renderbuffer_storage(glow::RENDERBUFFER, format, width, height);
            }
            gl.framebuffer_renderbuffer(
                glow::FRAMEBUFFER,
                attachment,
                glow::RENDERBUFFER,
                Some(renderbuffer),
            );
            renderbuffers.push(renderbuffer);
        }
        let status = gl.check_framebuffer_status(glow::FRAMEBUFFER);
        if status != glow::FRAMEBUFFER_COMPLETE {
            gl.delete_framebuffer(framebuffer);
            for renderbuffer in renderbuffers {
                gl.delete_renderbuffer(renderbuffer);
            }
            return Err(format!("the framebuffer is incomplete (0x{status:x})"));
        }
        Ok((framebuffer, renderbuffers))
    }

    /// Make the context current, drawing into the canvas's framebuffer.
    fn begin(&self, env: &Env) -> Result<&glow::Context> {
        if let Err(problem) = self.context.make_current() {
            return fail(env, problem);
        }
        // SAFETY: the context is current; the framebuffer and vertex array are its.
        unsafe {
            self.gl
                .bind_framebuffer(glow::FRAMEBUFFER, Some(self.framebuffer));
            self.gl.bind_vertex_array(Some(self.vertex_array));
            self.gl.viewport(0, 0, self.width, self.height);
        }
        Ok(&self.gl)
    }

    /// Signal the first error OpenGL recorded since the last check, if any,
    /// saying it came of WHAT.
    fn check(&self, env: &Env, what: &str) -> Result<()> {
        // SAFETY: the context is current (`begin' ran).
        let error = unsafe { self.gl.get_error() };
        // Errors queue up; the rest belong to the same call.
        // SAFETY: as above.
        while unsafe { self.gl.get_error() } != glow::NO_ERROR {}
        match error {
            glow::NO_ERROR => Ok(()),
            glow::INVALID_ENUM => fail(env, format!("{what}: invalid enum")),
            glow::INVALID_VALUE => fail(env, format!("{what}: invalid value")),
            glow::INVALID_OPERATION => fail(env, format!("{what}: invalid operation")),
            glow::OUT_OF_MEMORY => fail(env, format!("{what}: out of memory")),
            glow::INVALID_FRAMEBUFFER_OPERATION => {
                fail(env, format!("{what}: invalid framebuffer operation"))
            }
            other => fail(env, format!("{what}: OpenGL error 0x{other:x}")),
        }
    }

    fn name(&mut self) -> i64 {
        let name = self.next;
        self.next += 1;
        name
    }
}

impl Drop for Gl {
    fn drop(&mut self) {
        if self.context.make_current().is_err() {
            return;
        }
        // SAFETY: the context is current; each object is deleted once, and
        // none is used after.
        unsafe {
            for (_, program) in self.programs.drain() {
                self.gl.delete_program(program.program);
            }
            for (_, buffer) in self.buffers.drain() {
                self.gl.delete_buffer(buffer.buffer);
            }
            self.gl.delete_vertex_array(self.vertex_array);
            self.gl.delete_framebuffer(self.framebuffer);
            if let Some(resolve) = self.resolve {
                self.gl.delete_framebuffer(resolve);
            }
            for renderbuffer in self.renderbuffers.drain(..) {
                self.gl.delete_renderbuffer(renderbuffer);
            }
        }
    }
}

/// Make the OpenGL context of a canvas WIDTH by HEIGHT pixels, its
/// framebuffer multisampled with SAMPLES samples (0 for none; fewer when
/// the renderer has fewer).  Depth testing and alpha blending are on.
#[defun(user_ptr)]
fn new(env: &Env, width: i64, height: i64, samples: i64) -> Result<Gl> {
    if !(1..=MAX_SIDE).contains(&width) || !(1..=MAX_SIDE).contains(&height) {
        return fail(
            env,
            format!("a canvas is 1 to {MAX_SIDE} pixels a side, not {width}x{height}"),
        );
    }
    match Gl::new(width as i32, height as i32, samples.clamp(0, 64) as i32) {
        Ok(gl) => Ok(gl),
        Err(problem) => fail(env, problem),
    }
}

/// Return what draws for GL: the renderer, and the version of OpenGL and
/// of its shading language, on one line.
#[defun]
fn info(env: &Env, gl: &Gl) -> Result<String> {
    let context = gl.begin(env)?;
    // SAFETY: the context is current.
    unsafe {
        Ok(format!(
            "{}; OpenGL {}; GLSL {}",
            context.get_parameter_string(glow::RENDERER),
            context.get_parameter_string(glow::VERSION),
            context.get_parameter_string(glow::SHADING_LANGUAGE_VERSION)
        ))
    }
}

/// Compile the shader of KIND from SOURCE, or signal its log.
///
/// # Safety
/// GL's context must be current.
unsafe fn shader(
    env: &Env,
    context: &glow::Context,
    kind: u32,
    source: &str,
) -> Result<glow::Shader> {
    let shader = match context.create_shader(kind) {
        Ok(shader) => shader,
        Err(problem) => return fail(env, problem),
    };
    context.shader_source(shader, source);
    context.compile_shader(shader);
    if !context.get_shader_compile_status(shader) {
        let log = context.get_shader_info_log(shader);
        context.delete_shader(shader);
        let which = if kind == glow::VERTEX_SHADER {
            "vertex"
        } else {
            "fragment"
        };
        return fail(
            env,
            format!("the {which} shader does not compile: {}", log.trim()),
        );
    }
    Ok(shader)
}

/// Link a program of the shaders compiled from VERTEX and FRAGMENT, GLSL
/// sources, in GL; return its number.  A shader that does not compile, or
/// a program that does not link, signals its log.
#[defun]
fn program(env: &Env, gl: &mut Gl, vertex: String, fragment: String) -> Result<i64> {
    let context = gl.begin(env)?;
    // SAFETY: the context is current; the shaders are deleted once linked.
    let (program, uniforms) = unsafe {
        let vertex = shader(env, context, glow::VERTEX_SHADER, &vertex)?;
        let fragment = match shader(env, context, glow::FRAGMENT_SHADER, &fragment) {
            Ok(fragment) => fragment,
            Err(error) => {
                context.delete_shader(vertex);
                return Err(error);
            }
        };
        let program = match context.create_program() {
            Ok(program) => program,
            Err(problem) => {
                context.delete_shader(vertex);
                context.delete_shader(fragment);
                return fail(env, problem);
            }
        };
        context.attach_shader(program, vertex);
        context.attach_shader(program, fragment);
        context.link_program(program);
        context.detach_shader(program, vertex);
        context.detach_shader(program, fragment);
        context.delete_shader(vertex);
        context.delete_shader(fragment);
        if !context.get_program_link_status(program) {
            let log = context.get_program_info_log(program);
            context.delete_program(program);
            return fail(env, format!("the program does not link: {}", log.trim()));
        }
        let mut uniforms = HashMap::new();
        for index in 0..context.get_active_uniforms(program) {
            if let Some(active) = context.get_active_uniform(program, index) {
                if let Some(location) = context.get_uniform_location(program, &active.name) {
                    // An array's first element is named NAME[0]; NAME is what Lisp says.
                    let name = active
                        .name
                        .strip_suffix("[0]")
                        .unwrap_or(&active.name)
                        .to_owned();
                    uniforms.insert(
                        name,
                        Uniform {
                            location,
                            kind: active.utype,
                        },
                    );
                }
            }
        }
        (program, uniforms)
    };
    let name = gl.name();
    gl.programs.insert(name, Program { program, uniforms });
    Ok(name)
}

/// Return the numbers of VALUE, a number or a vector of numbers, as floats.
fn floats(value: Value) -> Result<Vec<f32>> {
    if let Ok(vector) = value.into_rust::<Vector>() {
        (0..vector.len()).map(|i| number(vector.get(i)?)).collect()
    } else {
        Ok(vec![number(value)?])
    }
}

/// Return VALUE, an integer or a float, as a float.
fn number(value: Value) -> Result<f32> {
    match value.into_rust::<f64>() {
        Ok(float) => Ok(float as f32),
        Err(_) => Ok(value.into_rust::<i64>()? as f32),
    }
}

/// Upload FLOATS into BUFFER of CONTEXT, for USAGE.
///
/// # Safety
/// The context must be current, and BUFFER its own.
unsafe fn upload(context: &glow::Context, buffer: glow::Buffer, floats: &[f32], usage: u32) {
    context.bind_buffer(glow::ARRAY_BUFFER, Some(buffer));
    context.buffer_data_u8_slice(glow::ARRAY_BUFFER, bytemuck::cast_slice(floats), usage);
}

/// Make a buffer of the vertices DATA holds, a vector of numbers, in GL;
/// return its number.
#[defun]
fn buffer(env: &Env, gl: &mut Gl, data: Vector) -> Result<i64> {
    let floats = (0..data.len())
        .map(|i| number(data.get(i)?))
        .collect::<Result<Vec<f32>>>()?;
    let context = gl.begin(env)?;
    // SAFETY: the context is current; the buffer is GL's from now on.
    let buffer = unsafe {
        let buffer = match context.create_buffer() {
            Ok(buffer) => buffer,
            Err(problem) => return fail(env, problem),
        };
        upload(context, buffer, &floats, glow::STATIC_DRAW);
        buffer
    };
    let name = gl.name();
    gl.buffers.insert(
        name,
        Buffer {
            buffer,
            floats: floats.len(),
        },
    );
    gl.check(env, "buffer")?;
    Ok(name)
}

/// Replace what the buffer numbered BUFFER of GL holds by DATA, a vector
/// of numbers.
#[defun]
fn buffer_set(env: &Env, gl: &mut Gl, buffer: i64, data: Vector) -> Result<()> {
    let floats = (0..data.len())
        .map(|i| number(data.get(i)?))
        .collect::<Result<Vec<f32>>>()?;
    let Some(object) = gl.buffers.get(&buffer).map(|b| b.buffer) else {
        return fail(env, format!("no buffer {buffer}"));
    };
    let context = gl.begin(env)?;
    // SAFETY: the context is current and the buffer is its own.
    unsafe { upload(context, object, &floats, glow::DYNAMIC_DRAW) };
    if let Some(entry) = gl.buffers.get_mut(&buffer) {
        entry.floats = floats.len();
    }
    gl.check(env, "buffer-set")
}

/// Delete the program or buffer numbered NAME of GL, if there is one.
#[defun]
fn delete(env: &Env, gl: &mut Gl, name: i64) -> Result<()> {
    gl.begin(env)?;
    // SAFETY: the context is current; the object is removed from the
    // context's tables, so it is not used again.
    unsafe {
        if let Some(program) = gl.programs.remove(&name) {
            gl.gl.delete_program(program.program);
        }
        if let Some(buffer) = gl.buffers.remove(&name) {
            gl.gl.delete_buffer(buffer.buffer);
        }
    }
    Ok(())
}

/// Clear GL's framebuffer to the colour RED GREEN BLUE ALPHA, numbers
/// from 0 to 1, and its depth to the farthest.
#[defun]
fn clear(env: &Env, gl: &Gl, red: Value, green: Value, blue: Value, alpha: Value) -> Result<()> {
    let colour = [number(red)?, number(green)?, number(blue)?, number(alpha)?];
    let context = gl.begin(env)?;
    // SAFETY: the context is current.
    unsafe {
        context.depth_mask(true);
        context.clear_color(colour[0], colour[1], colour[2], colour[3]);
        context.clear(glow::COLOR_BUFFER_BIT | glow::DEPTH_BUFFER_BIT);
    }
    gl.check(env, "clear")
}

fn symbol_name(env: &Env, symbol: Value) -> Result<String> {
    env.call("symbol-name", [symbol])?.into_rust()
}

/// Turn the OpenGL capability CAPABILITY of GL, a symbol, on when ON is
/// non-nil, else off: `depth-test', `blend' or `cull-face'.
#[defun]
fn capability(env: &Env, gl: &Gl, capability: Value, on: Value) -> Result<()> {
    let capability = match symbol_name(env, capability)?.as_str() {
        "depth-test" => glow::DEPTH_TEST,
        "blend" => glow::BLEND,
        "cull-face" => glow::CULL_FACE,
        other => return fail(env, format!("not a capability: {other}")),
    };
    let context = gl.begin(env)?;
    // SAFETY: the context is current.
    unsafe {
        if on.is_not_nil() {
            context.enable(capability);
        } else {
            context.disable(capability);
        }
    }
    Ok(())
}

/// Return the primitive OpenGL draws for MODE, a symbol.
fn mode(env: &Env, mode: Value) -> Result<u32> {
    match symbol_name(env, mode)?.as_str() {
        "triangles" => Ok(glow::TRIANGLES),
        "triangle-strip" => Ok(glow::TRIANGLE_STRIP),
        "triangle-fan" => Ok(glow::TRIANGLE_FAN),
        "lines" => Ok(glow::LINES),
        "line-strip" => Ok(glow::LINE_STRIP),
        "line-loop" => Ok(glow::LINE_LOOP),
        "points" => Ok(glow::POINTS),
        other => fail(env, format!("not a primitive: {other}")),
    }
}

/// Set the uniform NAME, UNIFORM, to VALUE, as its type takes it.
///
/// # Safety
/// GL's context must be current, with the uniform's program in use.
unsafe fn set_uniform(
    env: &Env,
    context: &glow::Context,
    name: &str,
    uniform: &Uniform,
    value: Value,
) -> Result<()> {
    let location = Some(&uniform.location);
    let wanted = |count: usize| -> Result<Vec<f32>> {
        let numbers = floats(value)?;
        if numbers.len() == count {
            Ok(numbers)
        } else {
            fail(
                env,
                format!(
                    "the uniform {name} takes {count} numbers, not {}",
                    numbers.len()
                ),
            )
        }
    };
    match uniform.kind {
        glow::FLOAT => context.uniform_1_f32_slice(location, &wanted(1)?),
        glow::FLOAT_VEC2 => context.uniform_2_f32_slice(location, &wanted(2)?),
        glow::FLOAT_VEC3 => context.uniform_3_f32_slice(location, &wanted(3)?),
        glow::FLOAT_VEC4 => context.uniform_4_f32_slice(location, &wanted(4)?),
        glow::FLOAT_MAT2 => context.uniform_matrix_2_f32_slice(location, false, &wanted(4)?),
        glow::FLOAT_MAT3 => context.uniform_matrix_3_f32_slice(location, false, &wanted(9)?),
        glow::FLOAT_MAT4 => context.uniform_matrix_4_f32_slice(location, false, &wanted(16)?),
        glow::INT | glow::BOOL => {
            let integer = match value.into_rust::<i64>() {
                Ok(integer) => integer as i32,
                Err(_) => i32::from(value.is_not_nil()),
            };
            context.uniform_1_i32(location, integer);
        }
        other => {
            return fail(
                env,
                format!("the uniform {name} is of a type lispm-gl does not set (0x{other:x})"),
            )
        }
    }
    Ok(())
}

/// Draw with the program numbered PROGRAM the vertices of the buffer
/// numbered BUFFER into GL's framebuffer, as MODE: `triangles',
/// `triangle-strip', `triangle-fan', `lines', `line-strip', `line-loop' or
/// `points'.  LAYOUT is a vector of the attributes each vertex holds, in
/// order, a name and a number of floats: [("position" . 3) ("colour" . 3)].
/// UNIFORMS is an alist of a uniform's name and its value: a number, or a
/// vector of numbers, a matrix's by columns.  FIRST and COUNT say which
/// vertices; COUNT nil draws all from FIRST on.
#[defun]
#[allow(clippy::too_many_arguments)]
fn draw(
    env: &Env,
    gl: &Gl,
    program: i64,
    buffer: i64,
    mode_symbol: Value,
    layout: Vector,
    uniforms: Value,
    first: i64,
    count: Value,
) -> Result<()> {
    let Some(program_object) = gl.programs.get(&program) else {
        return fail(env, format!("no program {program}"));
    };
    let Some(buffer_object) = gl.buffers.get(&buffer) else {
        return fail(env, format!("no buffer {buffer}"));
    };
    let primitive = mode(env, mode_symbol)?;
    let mut attributes = Vec::new();
    for i in 0..layout.len() {
        let attribute: Value = layout.get(i)?;
        let name: String = env.call("car", [attribute])?.into_rust()?;
        let size: i64 = env.call("cdr", [attribute])?.into_rust()?;
        if !(1..=4).contains(&size) {
            return fail(
                env,
                format!("the attribute {name} has 1 to 4 floats, not {size}"),
            );
        }
        attributes.push((name, size as i32));
    }
    let floats_per_vertex: i32 = attributes.iter().map(|(_, size)| size).sum();
    if floats_per_vertex == 0 {
        return fail(env, "the layout names no attribute");
    }
    let vertices = (buffer_object.floats / floats_per_vertex as usize) as i64;
    let count = if count.is_not_nil() {
        count.into_rust::<i64>()?
    } else {
        vertices - first
    };
    if first < 0 || count < 0 || first + count > vertices {
        return fail(
            env,
            format!("vertices {first} to {} of {vertices}", first + count),
        );
    }
    let mut settings = Vec::new();
    let mut rest = uniforms;
    while rest.is_not_nil() {
        let pair = env.call("car", [rest])?;
        let name: String = env.call("car", [pair])?.into_rust()?;
        settings.push((name, env.call("cdr", [pair])?));
        rest = env.call("cdr", [rest])?;
    }
    let context = gl.begin(env)?;
    // SAFETY: the context is current; the program and buffer are its own;
    // each attribute array enabled is disabled again.
    unsafe {
        context.use_program(Some(program_object.program));
        context.bind_buffer(glow::ARRAY_BUFFER, Some(buffer_object.buffer));
        let stride = floats_per_vertex * 4;
        let mut offset = 0;
        let mut enabled = Vec::new();
        for (name, size) in &attributes {
            // An attribute the shaders do not use is optimized away.
            if let Some(location) = context.get_attrib_location(program_object.program, name) {
                context.enable_vertex_attrib_array(location);
                context.vertex_attrib_pointer_f32(
                    location,
                    *size,
                    glow::FLOAT,
                    false,
                    stride,
                    offset,
                );
                enabled.push(location);
            }
            offset += size * 4;
        }
        let mut result = Ok(());
        for (name, value) in &settings {
            // A uniform the shaders do not use is optimized away too.
            if let Some(uniform) = program_object.uniforms.get(name) {
                result = set_uniform(env, context, name, uniform, *value);
                if result.is_err() {
                    break;
                }
            }
        }
        if result.is_ok() {
            context.draw_arrays(primitive, first as i32, count as i32);
        }
        for location in enabled {
            context.disable_vertex_attrib_array(location);
        }
        result?;
    }
    gl.check(env, "draw")
}

/// Copy what GL drew into CANVAS, a canvas image spec as large: Emacs
/// shows it once Lisp calls `canvas-refresh' on CANVAS.
#[defun]
fn read(env: &Env, gl: &mut Gl, canvas: Value) -> Result<()> {
    gl.begin(env)?;
    let (width, height) = (gl.width, gl.height);
    // SAFETY: the context is current; the pixels hold width × height of
    // the four bytes BGRA is read as.
    unsafe {
        let context = &gl.gl;
        if let Some(resolve) = gl.resolve {
            context.bind_framebuffer(glow::READ_FRAMEBUFFER, Some(gl.framebuffer));
            context.bind_framebuffer(glow::DRAW_FRAMEBUFFER, Some(resolve));
            context.blit_framebuffer(
                0,
                0,
                width,
                height,
                0,
                0,
                width,
                height,
                glow::COLOR_BUFFER_BIT,
                glow::NEAREST,
            );
            context.bind_framebuffer(glow::READ_FRAMEBUFFER, Some(resolve));
        } else {
            context.bind_framebuffer(glow::READ_FRAMEBUFFER, Some(gl.framebuffer));
        }
        context.pixel_store_i32(glow::PACK_ALIGNMENT, 4);
        context.read_pixels(
            0,
            0,
            width,
            height,
            glow::BGRA,
            glow::UNSIGNED_INT_8_8_8_8_REV,
            glow::PixelPackData::Slice(Some(bytemuck::cast_slice_mut(&mut gl.pixels))),
        );
    }
    gl.check(env, "read")?;
    let pixels = &gl.pixels;
    let (width, height) = (width as usize, height as usize);
    let copied = canvas.with_canvas_data(move |data| {
        if data.width != width || data.height != height {
            return false;
        }
        // OpenGL's rows go up from the bottom, the canvas's down from the
        // top; the canvas is opaque.
        for (row, target) in data.buffer.chunks_exact_mut(width).enumerate() {
            let start = (height - 1 - row) * width;
            if let Some(source) = pixels.get(start..start + width) {
                for (to, from) in target.iter_mut().zip(source) {
                    *to = from | 0xff00_0000;
                }
            }
        }
        true
    })?;
    if copied {
        Ok(())
    } else {
        fail(env, format!("the canvas is not {width}x{height}"))
    }
}

/// Return GL's size, a cons of its width and height in pixels.
#[defun]
fn size<'e>(env: &'e Env, gl: &Gl) -> Result<Value<'e>> {
    env.cons(gl.width.into_lisp(env)?, gl.height.into_lisp(env)?)
}

/// Return the pixel at X, Y of CANVAS, a canvas image spec, counted from
/// its top left: an integer 0xAARRGGBB, or nil outside the canvas.
#[defun]
fn pixel(canvas: Value, x: i64, y: i64) -> Result<Option<i64>> {
    canvas.with_canvas_data(move |data| {
        let (Ok(x), Ok(y)) = (usize::try_from(x), usize::try_from(y)) else {
            return None;
        };
        if x >= data.width || y >= data.height {
            return None;
        }
        data.buffer
            .get(y * data.width + x)
            .map(|pixel| i64::from(*pixel))
    })
}
