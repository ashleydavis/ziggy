//
// The script every native app injects into the frontend before the frontend's own scripts, which exposes window.ziggy on top of the
// platform's own way of posting to native code. It is embedded here, in the core library, so every native app takes it from the library
// and an app supplies nothing. The text is the file ziggy-inject.js beside this one.
//

// The script's text, NUL terminated.
pub const text = @embedFile("ziggy-inject.js");
