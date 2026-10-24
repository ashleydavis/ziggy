const std = @import("std");
const ziggy = @import("ziggy");

const messages = ziggy.worker_messages;
const task_queue_types = ziggy.task_queue.types;

//
// Fails unless the JSON text the message encodes to holds the same JSON as what the TypeScript sends, key order aside (a JSON object
// has none).
//
fn expectSameJson(arena: std.mem.Allocator, typescript_sends: []const u8, message: anytype) !void {
    const encoded = try messages.encode(arena, message);
    const expected = try std.json.parseFromSliceLeaky(std.json.Value, arena, typescript_sends, .{});
    const actual = try std.json.parseFromSliceLeaky(std.json.Value, arena, encoded, .{});
    if (!jsonEqual(expected, actual)) {
        std.debug.print("expected {s}\nencoded  {s}\n", .{ typescript_sends, encoded });
        return error.NotTheSameJson;
    }
}

//
// Whether two JSON values are the same, key order aside.
//
fn jsonEqual(a: std.json.Value, b: std.json.Value) bool {
    switch (a) {
        .null => return b == .null,
        .bool => |value| return b == .bool and b.bool == value,
        .integer => |value| return b == .integer and b.integer == value,
        .float => |value| return b == .float and b.float == value,
        .number_string => |value| return b == .number_string and std.mem.eql(u8, value, b.number_string),
        .string => |value| return b == .string and std.mem.eql(u8, value, b.string),
        .array => |items| {
            if (b != .array or b.array.items.len != items.items.len) {
                return false;
            }
            for (items.items, b.array.items) |left, right| {
                if (!jsonEqual(left, right)) {
                    return false;
                }
            }
            return true;
        },
        .object => |object| {
            if (b != .object or b.object.count() != object.count()) {
                return false;
            }
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const other = b.object.get(entry.key_ptr.*) orelse {
                    return false;
                };
                if (!jsonEqual(entry.value_ptr.*, other)) {
                    return false;
                }
            }
            return true;
        },
    }
}

test "execute encodes to the IWorkerMessage the TypeScript sends" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try expectSameJson(arena, "{\"type\":\"execute\",\"taskId\":\"t1\",\"taskType\":\"hash\",\"data\":{\"path\":\"a.jpg\"},\"source\":\"db\"}", messages.IWorkerMessage{
        .taskId = "t1",
        .taskType = "hash",
        .data = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"path\":\"a.jpg\"}", .{}),
        .source = "db",
    });
}

test "cancel-tasks, shutdown and worker-ready encode to the messages the TypeScript sends" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try expectSameJson(arena, "{\"type\":\"cancel-tasks\",\"source\":\"db\"}", messages.IWorkerCancelTasksMessage{
        .source = "db",
    });
    try expectSameJson(arena, "{\"type\":\"shutdown\"}", messages.IWorkerShutdownMessage{});
    try expectSameJson(arena, "{\"type\":\"worker-ready\"}", messages.IWorkerReadyMessage{});
}

test "task-completed encodes to the IWorkerTaskCompletedMessage the TypeScript sends, for a task that succeeded and one that failed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try expectSameJson(arena, "{\"type\":\"task-completed\",\"taskId\":\"t1\",\"result\":{\"taskId\":\"t1\",\"type\":\"hash\",\"inputs\":{\"n\":1},\"status\":\"succeeded\",\"outputs\":\"abc\"}}", messages.IWorkerTaskCompletedMessage{
        .taskId = "t1",
        .result = .{
            .taskId = "t1",
            .status = .Succeeded,
            .outputs = .{ .string = "abc" },
            .type = "hash",
            .inputs = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"n\":1}", .{}),
        },
    });
    try expectSameJson(arena, "{\"type\":\"task-completed\",\"taskId\":\"t2\",\"result\":{\"taskId\":\"t2\",\"type\":\"hash\",\"inputs\":null,\"status\":\"failed\",\"error\":{\"name\":\"Error\",\"message\":\"boom\"},\"errorMessage\":\"boom\"}}", messages.IWorkerTaskCompletedMessage{
        .taskId = "t2",
        .result = .{
            .taskId = "t2",
            .status = .Failed,
            .@"error" = .{
                .name = "Error",
                .message = "boom",
            },
            .errorMessage = "boom",
            .type = "hash",
            .inputs = .null,
        },
    });
}

test "task-message encodes to the IWorkerTaskMessage the TypeScript sends" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try expectSameJson(arena, "{\"type\":\"task-message\",\"taskId\":\"t1\",\"message\":{\"type\":\"progress\",\"done\":3}}", messages.IWorkerTaskMessage{
        .taskId = "t1",
        .message = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"type\":\"progress\",\"done\":3}", .{}),
    });
}

test "queue-task encodes to the IWorkerQueueTaskMessage the TypeScript sends, with the priority's string and none left out" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try expectSameJson(arena, "{\"type\":\"queue-task\",\"taskId\":\"c1\",\"taskType\":\"hash\",\"data\":null,\"source\":\"db\",\"priority\":\"interactive\"}", messages.IWorkerQueueTaskMessage{
        .taskId = "c1",
        .taskType = "hash",
        .data = .null,
        .source = "db",
        .priority = .Interactive,
    });
    // JSON.stringify leaves out an undefined priority.
    try expectSameJson(arena, "{\"type\":\"queue-task\",\"taskId\":\"c2\",\"taskType\":\"hash\",\"data\":null,\"source\":\"db\"}", messages.IWorkerQueueTaskMessage{
        .taskId = "c2",
        .taskType = "hash",
        .data = .null,
        .source = "db",
    });
}

test "log encodes to the IWorkerLogMessage the TypeScript sends, with the error and the tool's output only when they are given" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try expectSameJson(arena, "{\"type\":\"log\",\"level\":\"info\",\"message\":\"hello\"}", messages.IWorkerLogMessage{
        .level = .info,
        .message = "hello",
    });
    try expectSameJson(arena, "{\"type\":\"log\",\"level\":\"exception\",\"message\":\"failed\",\"error\":\"Error: boom\"}", messages.IWorkerLogMessage{
        .level = .exception,
        .message = "failed",
        .@"error" = "Error: boom",
    });
    try expectSameJson(arena, "{\"type\":\"log\",\"level\":\"tool\",\"message\":\"some-tool\",\"toolData\":{\"stdout\":\"out\"}}", messages.IWorkerLogMessage{
        .level = .tool,
        .message = "some-tool",
        .toolData = .{
            .stdout = "out",
        },
    });
    try expectSameJson(arena, "{\"type\":\"log\",\"level\":\"error\",\"message\":\"bad\"}", messages.IWorkerLogMessage{
        .level = .@"error",
        .message = "bad",
    });
}

test "native-app-request carries the request's id, the native function and its input, and native-app-response the same id and the result or the reason" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try expectSameJson(arena, "{\"type\":\"native-app-request\",\"requestId\":4,\"function\":\"pick-paths\",\"input\":{\"kind\":2,\"title\":\"Choose\"}}", messages.INativeAppRequestMessage{
        .requestId = 4,
        .function = messages.NativeAppFunction.pick_paths,
        .input = try std.json.parseFromSliceLeaky(std.json.Value, arena, try messages.encode(arena, messages.PickPathsInput{
            .kind = 2,
            .title = "Choose",
        }), .{}),
    });
    try expectSameJson(arena, "{\"type\":\"native-app-response\",\"requestId\":4,\"result\":\"[\\\"/a\\\"]\"}", messages.INativeAppResponseMessage{
        .requestId = 4,
        .result = .{ .string = "[\"/a\"]" },
    });
    try expectSameJson(arena, "{\"type\":\"native-app-response\",\"requestId\":5,\"error\":\"NativeCallMissing\"}", messages.INativeAppResponseMessage{
        .requestId = 5,
        .@"error" = "NativeCallMissing",
    });
}

test "a message's text decodes back to the struct of its type, and typeOf names the type" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The text the TypeScript sends, with its own key order and a field the struct does not have.
    const text = "{\"source\":\"db\",\"taskType\":\"hash\",\"data\":[1],\"taskId\":\"c1\",\"priority\":\"background\",\"type\":\"queue-task\",\"extra\":true}";
    const decoded = try messages.decode(messages.IWorkerQueueTaskMessage, arena, text);
    try std.testing.expectEqualStrings("c1", decoded.taskId);
    try std.testing.expectEqualStrings("hash", decoded.taskType);
    try std.testing.expectEqualStrings("db", decoded.source);
    try std.testing.expectEqual(task_queue_types.TaskPriority.Background, decoded.priority.?);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    try std.testing.expectEqualStrings("queue-task", messages.typeOf(parsed).?);
    const from_value = try messages.decodeValue(messages.IWorkerQueueTaskMessage, arena, parsed);
    try std.testing.expectEqualStrings("c1", from_value.taskId);
    try std.testing.expect(messages.typeOf(.{ .integer = 1 }) == null);
}

test "TaskStatus and TaskPriority are written and read as the TypeScript enums' strings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("\"failed\"", try messages.encode(arena, task_queue_types.TaskStatus.Failed));
    try std.testing.expectEqualStrings("\"interactive\"", try messages.encode(arena, task_queue_types.TaskPriority.Interactive));
    try std.testing.expectEqual(task_queue_types.TaskStatus.Succeeded, try std.json.parseFromSliceLeaky(task_queue_types.TaskStatus, arena, "\"succeeded\"", .{}));
    try std.testing.expectEqual(task_queue_types.TaskPriority.Background, try std.json.parseFromValueLeaky(task_queue_types.TaskPriority, arena, .{ .string = "background" }, .{}));
    try std.testing.expectError(error.InvalidEnumTag, std.json.parseFromSliceLeaky(task_queue_types.TaskStatus, arena, "\"Succeeded\"", .{}));
}
