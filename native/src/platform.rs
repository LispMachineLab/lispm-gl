// platform.rs --- an OpenGL context that draws off screen
//
// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A canvas is drawn into a framebuffer of its own, never into a window,
// so the context needs no window either: CGL on macOS, EGL elsewhere.
// Either gives OpenGL 3.2's core profile or later (macOS stops at 4.1),
// and its functions, for glow to call.

use std::ffi::{c_void, CStr};

/// An OpenGL context, and how to reach its functions.
pub trait Platform {
    /// Makes the context the thread's current one, which every OpenGL call
    /// draws with.
    fn make_current(&self) -> Result<(), String>;

    /// Returns the address of the OpenGL function NAME, or null.
    fn proc_address(&self, name: &CStr) -> *const c_void;
}

#[cfg(target_os = "macos")]
pub use cgl::Cgl as Context;

#[cfg(target_os = "linux")]
pub use egl::Egl as Context;

#[cfg(target_os = "macos")]
mod cgl {
    use super::Platform;
    use std::ffi::{c_char, c_int, c_void, CStr};
    use std::ptr;

    type CGLPixelFormatObj = *mut c_void;
    type CGLContextObj = *mut c_void;
    type CGLError = c_int;

    // From CGLTypes.h.
    const K_CGLPFA_COLOR_SIZE: c_int = 8;
    const K_CGLPFA_ALPHA_SIZE: c_int = 11;
    const K_CGLPFA_DEPTH_SIZE: c_int = 12;
    const K_CGLPFA_ALLOW_OFFLINE_RENDERERS: c_int = 96;
    const K_CGLPFA_OPENGL_PROFILE: c_int = 99;
    const K_CGLOGLP_VERSION_3_2_CORE: c_int = 0x3200;

    #[link(name = "OpenGL", kind = "framework")]
    extern "C" {
        fn CGLChoosePixelFormat(
            attributes: *const c_int,
            format: *mut CGLPixelFormatObj,
            count: *mut c_int,
        ) -> CGLError;
        fn CGLDestroyPixelFormat(format: CGLPixelFormatObj) -> CGLError;
        fn CGLCreateContext(
            format: CGLPixelFormatObj,
            share: CGLContextObj,
            context: *mut CGLContextObj,
        ) -> CGLError;
        fn CGLDestroyContext(context: CGLContextObj) -> CGLError;
        fn CGLSetCurrentContext(context: CGLContextObj) -> CGLError;
        fn CGLGetCurrentContext() -> CGLContextObj;
        fn CGLErrorString(error: CGLError) -> *const c_char;
    }

    fn describe(error: CGLError) -> String {
        // SAFETY: CGLErrorString returns a static string for any code.
        let text = unsafe { CGLErrorString(error) };
        if text.is_null() {
            format!("CGL error {error}")
        } else {
            // SAFETY: a NUL-terminated static string, see above.
            unsafe { CStr::from_ptr(text) }
                .to_string_lossy()
                .into_owned()
        }
    }

    /// A CGL context with no drawable, and the framework its functions are in.
    pub struct Cgl {
        context: CGLContextObj,
        library: *mut c_void,
    }

    impl Cgl {
        /// Makes a context of OpenGL 3.2's core profile, the latest the system
        /// has (4.1); a software renderer does when no GPU is there.
        pub fn new() -> Result<Self, String> {
            let attributes = [
                K_CGLPFA_OPENGL_PROFILE,
                K_CGLOGLP_VERSION_3_2_CORE,
                K_CGLPFA_COLOR_SIZE,
                24,
                K_CGLPFA_ALPHA_SIZE,
                8,
                K_CGLPFA_DEPTH_SIZE,
                24,
                K_CGLPFA_ALLOW_OFFLINE_RENDERERS,
                0,
            ];
            let mut format: CGLPixelFormatObj = ptr::null_mut();
            let mut count: c_int = 0;
            // SAFETY: a zero-terminated attribute list and valid out pointers.
            let error =
                unsafe { CGLChoosePixelFormat(attributes.as_ptr(), &mut format, &mut count) };
            if error != 0 {
                return Err(format!("no OpenGL pixel format: {}", describe(error)));
            }
            if format.is_null() {
                return Err("no OpenGL renderer offers OpenGL 3.2".into());
            }
            let mut context: CGLContextObj = ptr::null_mut();
            // SAFETY: format is a pixel format CGL just made; no share context.
            let error = unsafe { CGLCreateContext(format, ptr::null_mut(), &mut context) };
            // SAFETY: the context keeps what it needs of the format.
            unsafe { CGLDestroyPixelFormat(format) };
            if error != 0 || context.is_null() {
                return Err(format!("no OpenGL context: {}", describe(error)));
            }
            let path = c"/System/Library/Frameworks/OpenGL.framework/OpenGL";
            // SAFETY: a NUL-terminated path; the framework is linked already.
            let library =
                unsafe { libc::dlopen(path.as_ptr(), libc::RTLD_LAZY | libc::RTLD_LOCAL) };
            if library.is_null() {
                // SAFETY: the context made above, used by nothing yet.
                unsafe { CGLDestroyContext(context) };
                return Err("OpenGL.framework does not open".into());
            }
            Ok(Cgl { context, library })
        }
    }

    impl Platform for Cgl {
        fn make_current(&self) -> Result<(), String> {
            // SAFETY: a live context; CGL's current context is per thread.
            let error = unsafe {
                if CGLGetCurrentContext() == self.context {
                    0
                } else {
                    CGLSetCurrentContext(self.context)
                }
            };
            if error == 0 {
                Ok(())
            } else {
                Err(format!(
                    "the OpenGL context cannot be used: {}",
                    describe(error)
                ))
            }
        }

        fn proc_address(&self, name: &CStr) -> *const c_void {
            // SAFETY: the framework's handle, open for the context's life.
            unsafe { libc::dlsym(self.library, name.as_ptr()) as *const c_void }
        }
    }

    impl Drop for Cgl {
        fn drop(&mut self) {
            // SAFETY: the context is not used after this; a current context
            // is released first, as CGL wants.
            unsafe {
                if CGLGetCurrentContext() == self.context {
                    CGLSetCurrentContext(ptr::null_mut());
                }
                CGLDestroyContext(self.context);
                libc::dlclose(self.library);
            }
        }
    }
}

#[cfg(target_os = "linux")]
mod egl {
    use super::Platform;
    use khronos_egl as egl;
    use std::ffi::{c_void, CStr};

    type Instance = egl::DynamicInstance<egl::EGL1_4>;

    /// An EGL context of the default display, current on a 1×1 pbuffer, or
    /// on none where the display allows that.
    pub struct Egl {
        instance: Instance,
        display: egl::Display,
        context: egl::Context,
        surface: Option<egl::Surface>,
    }

    impl Egl {
        /// Makes a context of OpenGL 3.3's core profile.
        pub fn new() -> Result<Self, String> {
            // SAFETY: libEGL is loaded as a library, nothing of it run yet.
            let instance = unsafe { Instance::load_required() }
                .map_err(|error| format!("EGL does not load: {error}"))?;
            // SAFETY: EGL_DEFAULT_DISPLAY, which any EGL accepts.
            let display = unsafe { instance.get_display(egl::DEFAULT_DISPLAY) }
                .ok_or("EGL has no display")?;
            instance
                .initialize(display)
                .map_err(|error| format!("EGL does not start: {error}"))?;
            // The display stays initialized: EGL counts no initializations,
            // so terminating it would end every other canvas's context too.
            let (context, surface) = Self::context(&instance, display)?;
            Ok(Egl {
                instance,
                display,
                context,
                surface,
            })
        }

        fn context(
            instance: &Instance,
            display: egl::Display,
        ) -> Result<(egl::Context, Option<egl::Surface>), String> {
            instance
                .bind_api(egl::OPENGL_API)
                .map_err(|error| format!("EGL has no OpenGL: {error}"))?;
            let attributes = [
                egl::RENDERABLE_TYPE,
                egl::OPENGL_BIT,
                egl::SURFACE_TYPE,
                egl::PBUFFER_BIT,
                egl::RED_SIZE,
                8,
                egl::GREEN_SIZE,
                8,
                egl::BLUE_SIZE,
                8,
                egl::ALPHA_SIZE,
                8,
                egl::DEPTH_SIZE,
                24,
                egl::NONE,
            ];
            let config = instance
                .choose_first_config(display, &attributes)
                .map_err(|error| format!("EGL has no configuration: {error}"))?
                .ok_or("EGL has no configuration for OpenGL 3.3")?;
            let context_attributes = [
                egl::CONTEXT_MAJOR_VERSION,
                3,
                egl::CONTEXT_MINOR_VERSION,
                3,
                egl::CONTEXT_OPENGL_PROFILE_MASK,
                egl::CONTEXT_OPENGL_CORE_PROFILE_BIT,
                egl::NONE,
            ];
            let context = instance
                .create_context(display, config, None, &context_attributes)
                .map_err(|error| format!("no OpenGL 3.3 context: {error}"))?;
            let surface = instance
                .create_pbuffer_surface(
                    display,
                    config,
                    &[egl::WIDTH, 1, egl::HEIGHT, 1, egl::NONE],
                )
                .ok();
            Ok((context, surface))
        }
    }

    impl Platform for Egl {
        fn make_current(&self) -> Result<(), String> {
            if self.instance.get_current_context() == Some(self.context) {
                return Ok(());
            }
            self.instance
                .make_current(self.display, self.surface, self.surface, Some(self.context))
                .map_err(|error| format!("the OpenGL context cannot be used: {error}"))
        }

        fn proc_address(&self, name: &CStr) -> *const c_void {
            name.to_str()
                .ok()
                .and_then(|name| self.instance.get_proc_address(name))
                .map_or(std::ptr::null(), |address| address as *const c_void)
        }
    }

    impl Drop for Egl {
        fn drop(&mut self) {
            if self.instance.get_current_context() == Some(self.context) {
                let _ = self.instance.make_current(self.display, None, None, None);
            }
            if let Some(surface) = self.surface {
                let _ = self.instance.destroy_surface(self.display, surface);
            }
            let _ = self.instance.destroy_context(self.display, self.context);
        }
    }
}
