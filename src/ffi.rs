#![allow(unsafe_code)]

use std::ffi::{c_char, c_void};
use std::ptr::NonNull;

unsafe extern "C" {
    fn pipewireao_rtc_context_load_module(
        context: *mut c_void,
        name: *const c_char,
        args: *const c_char,
    ) -> *mut c_void;
    fn pipewireao_rtc_module_destroy(module: *mut c_void);
}

pub(crate) fn load_module(
    context: *mut pipewire::sys::pw_context,
    name: &std::ffi::CStr,
    args: &std::ffi::CStr,
) -> Option<OwnedModule> {
    // SAFETY: Context is borrowed from a live ContextRc. Both C strings remain
    // valid for the duration of the call. The returned module is uniquely owned
    // by OwnedModule and destroyed before that context is released.
    let raw =
        unsafe { pipewireao_rtc_context_load_module(context.cast(), name.as_ptr(), args.as_ptr()) };
    NonNull::new(raw).map(OwnedModule)
}

pub(crate) struct OwnedModule(NonNull<c_void>);

impl Drop for OwnedModule {
    fn drop(&mut self) {
        // SAFETY: OwnedModule is constructed only from a successful
        // pw_context_load_module call and is not cloned. Drop runs once.
        unsafe { pipewireao_rtc_module_destroy(self.0.as_ptr()) };
    }
}
