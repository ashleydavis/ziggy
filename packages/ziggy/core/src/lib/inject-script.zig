//
// The script every shell injects into the UI before the UI's own scripts, which exposes window.ziggy on top of the
// platform's own channel to native code. It is embedded here, in the core library, so every shell takes it from the library
// and an app supplies nothing. The text is the file ziggy-inject.js beside this one.
//

// The script's text, NUL terminated.
pub const text = @embedFile("ziggy-inject.js");
