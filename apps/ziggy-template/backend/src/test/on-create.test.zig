//
// The template's log options, which it reads from its command line when its main thread starts.
//

const std = @import("std");
const app = @import("ziggy-template-backend");

test "no log option on the command line turns on no lines" {
    const options = app.on_create.logOptions(&.{"-geometry=800x600"});
    try std.testing.expect(!options.verbose);
    try std.testing.expect(!options.debug);
    try std.testing.expect(!options.tools);
}

test "--verbose, --debug and --tools each turn on their lines" {
    const verbose = app.on_create.logOptions(&.{"--verbose"});
    try std.testing.expect(verbose.verbose);
    try std.testing.expect(!verbose.debug);
    try std.testing.expect(!verbose.tools);
    const all = app.on_create.logOptions(&.{ "--tools", "-geometry=800x600", "--debug", "--verbose" });
    try std.testing.expect(all.verbose);
    try std.testing.expect(all.debug);
    try std.testing.expect(all.tools);
}
