//
// The root of every app's backend library, which addAppBackend in Ziggy's build.zig builds. The app's backend source file is
// imported as "app-backend", and the app it declares there (`pub const app = ziggy.core.App(...)`) is the one the library serves:
// this file exports Ziggy's C interface for it and, for an Android target, the JNI entry points of Ziggy's Android native app, so the app
// writes neither itself.
//

const builtin = @import("builtin");
const ziggy = @import("ziggy");
const app_backend = @import("app-backend");

//
// Zig's MachO stack trace symbolizer calls _dyld_get_image_header_containing_address, which the iOS SDK does not
// export, so on iOS it is switched off and a stack trace prints addresses only.
//
pub const debug = if (builtin.os.tag == .ios) struct {
    pub const SelfInfo = void;
} else struct {};

comptime {
    if (!@hasDecl(app_backend, "app")) {
        @compileError("The app's backend source file must declare `pub const app = ziggy.core.App(.{ ... });`.");
    }
    ziggy.ziggy_api.exportApi(app_backend.app);
    if (builtin.abi.isAndroid()) {
        ziggy.jni.exportJni(app_backend.app);
    }
}
