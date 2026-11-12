//
// Gives a test's core directories of its own, so no test reads or writes the developer's own files.
//

const std = @import("std");
const ziggy = @import("ziggy");

//
// An environment of the test's own, set as the process environment, with the app's config and state directories under the test's
// temporary directory.
//
pub const TestEnvironment = struct {
    // Holds the environment's names and paths, so they live as long as the map does.
    arena: std.heap.ArenaAllocator,
    // The environment the core reads.
    map: std.process.Environ.Map,
};

//
// Makes the test's environment and sets it as the process environment. The caller frees it with freeTestEnvironment.
//
pub fn useTestEnvironment(allocator: std.mem.Allocator, tmp_dir: std.testing.TmpDir) !*TestEnvironment {
    const environment = try allocator.create(TestEnvironment);
    errdefer allocator.destroy(environment);
    environment.arena = .init(allocator);
    errdefer environment.arena.deinit();
    const arena = environment.arena.allocator();
    environment.map = try std.testing.environ.createMap(allocator);
    errdefer environment.map.deinit();

    const directory_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", arena);
    try environment.map.put(
        try ziggy.config_state.platform.appVariableName(arena, "ziggy-test-app", "_CONFIG_DIR"),
        try std.fs.path.join(arena, &.{ directory_path, "config" }),
    );
    try environment.map.put(
        try ziggy.config_state.platform.appVariableName(arena, "ziggy-test-app", "_STATE_DIR"),
        try std.fs.path.join(arena, &.{ directory_path, "state" }),
    );
    ziggy.utils.process_env.setEnvironMap(&environment.map);
    return environment;
}

//
// Clears the process environment and frees the test's environment.
//
pub fn freeTestEnvironment(allocator: std.mem.Allocator, environment: *TestEnvironment) void {
    ziggy.utils.process_env.setEnvironMap(null);
    environment.map.deinit();
    environment.arena.deinit();
    allocator.destroy(environment);
}
