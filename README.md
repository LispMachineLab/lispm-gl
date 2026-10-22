# lispm-gl

OpenGL drawn in an Emacs buffer, as an image among the text that scrolls with it, for
[LispM](https://lispm.ai) and any Emacs 32.

Emacs 32 adds canvas images, whose pixels a module may write. lispm-gl's Rust module gives
each canvas an OpenGL context without a window (CGL on macOS, EGL on GNU/Linux), draws into a
framebuffer as large as the canvas, and copies what it drew into the canvas, which Emacs then
shows. Lisp compiles the shaders, fills the buffers and draws:

```elisp
(let* ((gl (lispm-gl-create 320 240))
       (program (lispm-gl-program gl "#version 330 core
in vec2 position;
void main() { gl_Position = vec4(position, 0.0, 1.0); }" "#version 330 core
uniform vec3 tint;
out vec4 colour;
void main() { colour = vec4(tint, 1.0); }"))
       (triangle (lispm-gl-buffer gl [0 0.8  -0.8 -0.8  0.8 -0.8])))
  (lispm-gl-insert gl)
  (lispm-gl-clear gl [0.1 0.1 0.12 1])
  (lispm-gl-draw gl program triangle :layout [("position" . 2)] :uniforms '(("tint" . [1 0.5 0.2])))
  (lispm-gl-present gl))
```

`M-x lispm-gl-demo` spins a cube; `lispm-gl-animate` draws a canvas again and again while it
is shown. Shaders are GLSL 3.30 (`#version 330 core`).

## Emacs 32 only

Emacs 30 and 31 have no canvas images. There `lispm-gl-supported-p` is nil and every canvas
refuses at once with `lispm-gl-unsupported`, saying why; nothing is downloaded or loaded. The
module itself speaks Emacs 32's module interface and refuses to load in an older Emacs.

Emacs 32 is not released yet. LispM's experimental install puts LispM.app on a build of its
development branch:

```sh
curl -fsSL https://lispm.ai/install.sh | LISPM_EMACS=32 sh
```

## The module

Nobody has to build it. The one the `gl module` workflow built for your computer from these
sources is downloaded the first time a canvas is made, and kept only when its SHA-256 is the one
`lisp/lispm-gl-module-sums.eld` pins; the checksums come with the Lisp, from this repository's
signed history. Set `lispm-gl-module-source` to `build` to build it with Cargo instead.

```sh
make            # build the module for this computer
make test       # refusals on Emacs 30 and 31, drawing on 32
make compile    # byte-compile, warnings failing it
make pin        # pin the published modules, for a release
```

On macOS OpenGL stops at 4.1, which Apple runs on Metal; it is deprecated there but works.
Emacs shows a canvas by copying its pixels; on macOS that copy is the slow part, a few
milliseconds for a 480×360 canvas, which leaves 30 frames a second plenty of room.

## License

GNU Affero General Public License, version 3 or later. See [LICENSE](LICENSE).
