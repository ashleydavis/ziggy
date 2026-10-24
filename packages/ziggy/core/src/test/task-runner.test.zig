const std = @import("std");
const ziggy = @import("ziggy");
const helpers = @import("helpers.zig");
const utils = @import("ziggy").task_queue.utils;

fn addTask(native_app: *helpers.FakeNativeApp, id: []const u8, task_type: []const u8, source: []const u8, data: []const u8, priority: []const u8) !void {
    const message = try ziggy.json.stringify(std.testing.allocator, .{
        .kind = "system",
        .name = "add-task",
        .data = .{
            .taskId = id,
            .taskType = task_type,
            .source = source,
            .data = ziggy.json.Raw{ .text = data },
            .priority = priority,
        },
    });
    defer std.testing.allocator.free(message);
    native_app.sendMessage(std.testing.allocator, message);
}

fn cancelSource(native_app: *helpers.FakeNativeApp, source: []const u8) !void {
    const message = try ziggy.json.stringify(std.testing.allocator, .{
        .kind = "system",
        .name = "cancel-tasks",
        .data = source,
    });
    defer std.testing.allocator.free(message);
    native_app.sendMessage(std.testing.allocator, message);
}


fn expectCompleted(native_app: *helpers.FakeNativeApp, id: []const u8, status: []const u8) !void {
    var buffer: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "task-completed\",\"data\":{{\"taskId\":\"{s}\",", .{id});
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, text);
    const index = native_app.indexOfContaining(std.testing.io, std.testing.allocator, text).?;
    const message = try native_app.messageAt(std.testing.io, std.testing.allocator, index);
    defer std.testing.allocator.free(message);
    // TaskStatus has no cancelled, so a cancelled task is reported as failed with the error message "Cancelled".
    const is_cancelled = std.mem.eql(u8, status, "cancelled");
    var status_buffer: [64]u8 = undefined;
    const status_text = try std.fmt.bufPrint(&status_buffer, "\"status\":\"{s}\"", .{if (is_cancelled) "failed" else status});
    const cancelled_ok = !is_cancelled or std.mem.indexOf(u8, message, "\"errorMessage\":\"Cancelled\"") != null;
    if (std.mem.indexOf(u8, message, status_text) == null or !cancelled_ok) {
        std.debug.print("task {s} completed as: {s}\n", .{ id, message });
        return error.WrongStatus;
    }
}

test "a short task sends its event and completes as succeeded with its result" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 2, 2);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "t1", "quick", "s", "null", "background");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"status\":\"succeeded\",\"outputs\":\"done\"");
    const event_index = native_app.indexOfContaining(std.testing.io, std.testing.allocator, "\"kind\":\"system\",\"name\":\"task-event\"").?;
    const completed_index = native_app.indexOfContaining(std.testing.io, std.testing.allocator, "\"kind\":\"system\",\"name\":\"task-completed\"").?;
    try std.testing.expect(event_index < completed_index);
    const event = try native_app.messageAt(std.testing.io, std.testing.allocator, event_index);
    defer std.testing.allocator.free(event);
    try std.testing.expectEqualStrings("{\"kind\":\"system\",\"name\":\"task-event\",\"data\":{\"taskId\":\"t1\",\"source\":\"s\",\"data\":{\"text\":\"hello\"}}}", event);
}

test "a failing task completes as failed with its error" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "t1", "fail", "s", "null", "background");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"status\":\"failed\",\"error\":{\"message\":\"TestFailure\"},\"errorMessage\":\"TestFailure\"");
}

test "an unknown task type completes as failed" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "t1", "nothing-like-this", "s", "null", "background");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"status\":\"failed\",\"error\":{\"message\":\"UnknownTaskType\"},\"errorMessage\":\"UnknownTaskType\"");
}

test "cancelling a running task stops it early and completes it as cancelled" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 2, 2);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "t1", "spin", "s", "null", "background");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"step\":3");
    try cancelSource(&native_app, "s");
    try expectCompleted(&native_app, "t1", "cancelled");
}

test "cancelling a queued task means it never starts" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "blocker", "sleep", "blocker-source", "{\"ms\":300,\"name\":\"blocker\"}", "background");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"start\":\"blocker\"");
    try addTask(&native_app, "queued", "sleep", "queued-source", "{\"ms\":10,\"name\":\"queued\"}", "background");
    try cancelSource(&native_app, "queued-source");
    try expectCompleted(&native_app, "queued", "cancelled");
    try expectCompleted(&native_app, "blocker", "succeeded");
    try std.testing.expectEqual(@as(usize, 0), native_app.countContaining(std.testing.io, std.testing.allocator, "\"start\":\"queued\""));
}

test "cancelling one source leaves another source's tasks running" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 3, 2);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "a", "spin", "source-a", "null", "background");
    try addTask(&native_app, "b", "spin", "source-b", "null", "background");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"taskId\":\"a\",\"source\":\"source-a\",\"data\":{\"step\":2}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"taskId\":\"b\",\"source\":\"source-b\",\"data\":{\"step\":2}");
    try cancelSource(&native_app, "source-a");
    try expectCompleted(&native_app, "a", "cancelled");
    ziggy.fake_native_app.sleepMs(std.testing.io, 50);
    try std.testing.expectEqual(@as(usize, 0), native_app.countContaining(std.testing.io, std.testing.allocator, "task-completed\",\"data\":{\"taskId\":\"b\""));
    try cancelSource(&native_app, "source-b");
    try expectCompleted(&native_app, "b", "cancelled");
}

test "a task queued under a source after it was cancelled is not cancelled" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 2, 2);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "first", "spin", "s", "null", "background");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"step\":1");
    try cancelSource(&native_app, "s");
    try expectCompleted(&native_app, "first", "cancelled");
    try addTask(&native_app, "second", "quick", "s", "null", "background");
    try expectCompleted(&native_app, "second", "succeeded");
}

test "a cancel for an unknown source is harmless" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try cancelSource(&native_app, "nobody");
    try addTask(&native_app, "t1", "quick", "s", "null", "background");
    try expectCompleted(&native_app, "t1", "succeeded");
}

test "a higher priority task starts before a lower priority one queued earlier" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "blocker", "sleep", "s", "{\"ms\":150,\"name\":\"blocker\"}", "background");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"start\":\"blocker\"");
    try addTask(&native_app, "low", "sleep", "s", "{\"ms\":5,\"name\":\"low\"}", "background");
    try addTask(&native_app, "high", "sleep", "s", "{\"ms\":5,\"name\":\"high\"}", "interactive");
    try expectCompleted(&native_app, "low", "succeeded");
    try expectCompleted(&native_app, "high", "succeeded");
    const high = native_app.indexOfContaining(std.testing.io, std.testing.allocator, "\"start\":\"high\"").?;
    const low = native_app.indexOfContaining(std.testing.io, std.testing.allocator, "\"start\":\"low\"").?;
    try std.testing.expect(high < low);
}

test "tasks of equal priority start in the order they were queued" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "blocker", "sleep", "s", "{\"ms\":100,\"name\":\"blocker\"}", "background");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"start\":\"blocker\"");
    try addTask(&native_app, "one", "sleep", "s", "{\"ms\":2,\"name\":\"one\"}", "background");
    try addTask(&native_app, "two", "sleep", "s", "{\"ms\":2,\"name\":\"two\"}", "background");
    try expectCompleted(&native_app, "two", "succeeded");
    try std.testing.expect(native_app.indexOfContaining(std.testing.io, std.testing.allocator, "\"start\":\"one\"").? < native_app.indexOfContaining(std.testing.io, std.testing.allocator, "\"start\":\"two\"").?);
}

test "several tasks run at the same time up to the pool size and the rest wait their turn" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 2, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "t1", "sleep", "s", "{\"ms\":150,\"name\":\"t1\"}", "background");
    try addTask(&native_app, "t2", "sleep", "s", "{\"ms\":150,\"name\":\"t2\"}", "background");
    try addTask(&native_app, "t3", "sleep", "s", "{\"ms\":5,\"name\":\"t3\"}", "background");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"start\":\"t2\"");
    ziggy.fake_native_app.sleepMs(std.testing.io, 40);
    try std.testing.expectEqual(@as(usize, 0), native_app.countContaining(std.testing.io, std.testing.allocator, "\"start\":\"t3\""));
    try expectCompleted(&native_app, "t3", "succeeded");
}

test "two live tasks with the same id both run and each reports its completion" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 2, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "same", "sleep", "s", "{\"ms\":30,\"name\":\"first\"}", "background");
    try addTask(&native_app, "same", "quick", "s", "null", "background");
    var attempts: usize = 0;
    while (native_app.countContaining(std.testing.io, std.testing.allocator, "task-completed\",\"data\":{\"taskId\":\"same\"") < 2 and attempts < 400) {
        ziggy.fake_native_app.sleepMs(std.testing.io, 5);
        attempts += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), native_app.countContaining(std.testing.io, std.testing.allocator, "task-completed\",\"data\":{\"taskId\":\"same\""));
    try std.testing.expectEqual(@as(usize, 0), native_app.countContaining(std.testing.io, std.testing.allocator, "DuplicateTaskId"));
}

test "add-task without a task type is an error reply" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"add-task\",\"data\":{\"taskId\":\"x\",\"source\":\"s\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":false,\"error\":\"InvalidMessageData: the field \\\"taskType\\\" is missing\"}");
}

test "add-task without a task id is an error reply" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"add-task\",\"data\":{\"taskType\":\"quick\",\"source\":\"s\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":false,\"error\":\"InvalidMessageData: the field \\\"taskId\\\" is missing\"}");
}

test "add-task without a source is an error reply" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"add-task\",\"data\":{\"taskType\":\"quick\",\"taskId\":\"x\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":false,\"error\":\"InvalidMessageData: the field \\\"source\\\" is missing\"}");
}

test "events sent from several tasks at once all arrive, in order within each task" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 4, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    const count = 300;
    try addTask(&native_app, "f1", "flooder", "s", "{\"count\":300}", "background");
    try addTask(&native_app, "f2", "flooder", "s", "{\"count\":300}", "background");
    try addTask(&native_app, "f3", "flooder", "s", "{\"count\":300}", "background");
    try addTask(&native_app, "f4", "flooder", "s", "{\"count\":300}", "background");
    try expectCompleted(&native_app, "f1", "succeeded");
    try expectCompleted(&native_app, "f2", "succeeded");
    try expectCompleted(&native_app, "f3", "succeeded");
    try expectCompleted(&native_app, "f4", "succeeded");
    for ([_][]const u8{ "f1", "f2", "f3", "f4" }) |id| {
        var previous: i64 = -1;
        var seen: usize = 0;
        var index: usize = 0;
        while (index < native_app.count(std.testing.io, std.testing.allocator)) : (index += 1) {
            const message = try native_app.messageAt(std.testing.io, std.testing.allocator, index);
            defer std.testing.allocator.free(message);
            var marker_buffer: [64]u8 = undefined;
            const marker = try std.fmt.bufPrint(&marker_buffer, "\"taskId\":\"{s}\",", .{id});
            if (std.mem.indexOf(u8, message, marker) == null or std.mem.indexOf(u8, message, "\"seq\":") == null) {
                continue;
            }
            const seq_start = std.mem.indexOf(u8, message, "\"seq\":").? + 6;
            const seq_end = std.mem.indexOfScalarPos(u8, message, seq_start, '}').?;
            const sequence = try std.fmt.parseInt(i64, message[seq_start..seq_end], 10);
            try std.testing.expect(sequence == previous + 1);
            previous = sequence;
            seen += 1;
        }
        try std.testing.expectEqual(@as(usize, count), seen);
    }
}

test "destroy with tasks still running cancels them, waits and leaves no leak" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 2, 2);
    try addTask(&native_app, "t1", "spin", "s", "null", "background");
    try addTask(&native_app, "t2", "spin", "s", "null", "background");
    try addTask(&native_app, "t3", "sleep", "s", "{\"ms\":100000,\"name\":\"queued\"}", "background");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"taskId\":\"t2\",\"source\":\"s\",\"data\":{\"step\":1}");
    native_app.stop(std.testing.io, std.testing.allocator);
}

test "a parent that queues children waits for all of them" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 3, 4);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "p", "parent", "s", "{\"children\":6,\"childMs\":10,\"name\":\"p\"}", "background");
    try expectCompleted(&native_app, "p", "succeeded");
    try std.testing.expectEqual(@as(usize, 6), native_app.countContaining(std.testing.io, std.testing.allocator, "\"childEnd\":\"p\""));
    try std.testing.expect(native_app.indexOfContaining(std.testing.io, std.testing.allocator, "\"allChildrenDone\":\"p\"").? > native_app.indexOfContaining(std.testing.io, std.testing.allocator, "\"childEnd\":\"p\"").?);
    // Each child completes on its own and carries the parent's source.
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "task-completed\",\"data\":{\"taskId\":\"p.c5\",\"result\":{\"taskId\":\"p.c5\",\"status\":\"succeeded\"");
}

test "a parent with no children completes normally" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "p", "parent", "s", "{\"children\":0,\"name\":\"p\"}", "background");
    try expectCompleted(&native_app, "p", "succeeded");
}

test "awaitTask returns the result of one child and a failed child is returned as a failure" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 2, 2);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "p", "await-one", "s", "null", "background");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"first\":\"succeeded\",\"firstResult\":\"child result\",\"second\":\"failed\",\"secondError\":\"TestFailure\"");
}

test "runChild runs children one after another and returns each one's completion" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 2, 2);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "p", "run-children-in-turn", "s", "null", "background");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"first\":\"succeeded\",\"firstResult\":\"child result\",\"second\":\"failed\",\"secondError\":\"TestFailure\",\"third\":\"succeeded\",\"thirdResult\":\"child result\"");
}

test "no more than the child task limit run at once" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 6, 2);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "p", "parent", "s", "{\"children\":8,\"childMs\":20,\"name\":\"p\"}", "background");
    try expectCompleted(&native_app, "p", "succeeded");
    var running: i32 = 0;
    var most: i32 = 0;
    var index: usize = 0;
    while (index < native_app.count(std.testing.io, std.testing.allocator)) : (index += 1) {
        const message = try native_app.messageAt(std.testing.io, std.testing.allocator, index);
        defer std.testing.allocator.free(message);
        if (std.mem.indexOf(u8, message, "\"childStart\"") != null) {
            running += 1;
            most = @max(most, running);
        }
        else if (std.mem.indexOf(u8, message, "\"childEnd\"") != null) {
            running -= 1;
        }
    }
    try std.testing.expect(most <= 2);
    try std.testing.expect(most >= 1);
}

test "children of two parents do not run more at once than the pool has workers" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 3, 10);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "p1", "parent", "s", "{\"children\":6,\"childMs\":20,\"name\":\"p1\"}", "background");
    try addTask(&native_app, "p2", "parent", "s", "{\"children\":6,\"childMs\":20,\"name\":\"p2\"}", "background");
    try expectCompleted(&native_app, "p1", "succeeded");
    try expectCompleted(&native_app, "p2", "succeeded");
    var running: i32 = 0;
    var most: i32 = 0;
    var index: usize = 0;
    while (index < native_app.count(std.testing.io, std.testing.allocator)) : (index += 1) {
        const message = try native_app.messageAt(std.testing.io, std.testing.allocator, index);
        defer std.testing.allocator.free(message);
        if (std.mem.indexOf(u8, message, "\"childStart\"") != null) {
            running += 1;
            most = @max(most, running);
        }
        else if (std.mem.indexOf(u8, message, "\"childEnd\"") != null) {
            running -= 1;
        }
    }
    // Two parents hold two of the three workers while they wait, so the children run on the third, and never more than three tasks run.
    try std.testing.expect(most <= 3);
}

test "cancelling the parent's source cancels its children and the parent completes as cancelled" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 3, 2);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "p", "blocked-parent", "s", "null", "background");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"childStart\":\"blocked\"");
    try cancelSource(&native_app, "s");
    try expectCompleted(&native_app, "p", "cancelled");
    try expectCompleted(&native_app, "p.c0", "cancelled");
    try expectCompleted(&native_app, "p.c1", "cancelled");
}

//
// Waits until the fake native app has been told the given number of keep-alive changes, and returns what it was told.
//
fn keepAliveCalls(native_app: *helpers.FakeNativeApp, count: usize) ![]bool {
    var waited: u32 = 0;
    while (true) : (waited += 1) {
        const text = try native_app.keepAliveCalls(std.testing.io, std.testing.allocator);
        defer std.testing.allocator.free(text);
        const parsed = try std.json.parseFromSlice([]bool, std.testing.allocator, text, .{});
        defer parsed.deinit();
        if (parsed.value.len >= count or waited >= 2000) {
            return try std.testing.allocator.dupe(bool, parsed.value);
        }
        ziggy.fake_native_app.sleepMs(std.testing.io, 1);
    }
}

test "a keep-alive task has the native app keep the app running while it is queued or running, and to stop when it ends" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 2, 2);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "k1", "keep-sleep", "s", "{\"ms\":30}", "background");
    const during = try keepAliveCalls(&native_app, 1);
    defer std.testing.allocator.free(during);
    try std.testing.expectEqualSlices(bool, &[_]bool{true}, during[0..1]);
    try expectCompleted(&native_app, "k1", "succeeded");
    const after = try keepAliveCalls(&native_app, 2);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualSlices(bool, &[_]bool{ true, false }, after);
}

test "several keep-alive tasks send one keep-alive call, and the native app is told to stop only when the last one ends" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 3, 2);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "k1", "keep-sleep", "s1", "{\"ms\":20}", "background");
    try addTask(&native_app, "k2", "keep-sleep", "s2", "{\"ms\":100000}", "background");
    try expectCompleted(&native_app, "k1", "succeeded");
    const calls = try keepAliveCalls(&native_app, 1);
    defer std.testing.allocator.free(calls);
    try std.testing.expectEqualSlices(bool, &[_]bool{true}, calls);
    try cancelSource(&native_app, "s2");
    try expectCompleted(&native_app, "k2", "cancelled");
    const done = try keepAliveCalls(&native_app, 2);
    defer std.testing.allocator.free(done);
    try std.testing.expectEqualSlices(bool, &[_]bool{ true, false }, done);
}

//
// hold: holds the app running with or without a task, or lets it go, as the app's own code on the main thread does.
//
fn holdHandler(services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, keep_running: bool) !void {
    _ = timers;
    services.holdKeepAlive(io, allocator, keep_running);
}

//
// The app of the hold test: the helpers' app with the message hold.
//
const hold_app = registered: {
    var registered = ziggy.core.App(.{
        .messages = .{
            .hold = holdHandler,
        },
        .tasks = .{},
        .menu = &.{},
        .ui_files = &[_]ziggy.ui_files.UiFile{},
    });
    registered.tasks = &helpers.task_handlers;
    break :registered registered;
};

//
// Has the main thread of the core hold the app running, or let it go.
//
fn hold(native_app: *helpers.FakeNativeApp, keep_running: bool) void {
    native_app.sendMessage(std.testing.allocator, if (keep_running) "{\"kind\":\"app\",\"name\":\"hold\",\"data\":true}" else "{\"kind\":\"app\",\"name\":\"hold\",\"data\":false}");
}

test "a hold keeps the app running with no task, and the native app is told to stop only when the hold and the last keep-alive task have both ended" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(3, 2), hold_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    hold(&native_app, true);
    const held = try keepAliveCalls(&native_app, 1);
    defer std.testing.allocator.free(held);
    try std.testing.expectEqualSlices(bool, &[_]bool{true}, held);
    try addTask(&native_app, "k1", "keep-sleep", "s1", "{\"ms\":20}", "background");
    try expectCompleted(&native_app, "k1", "succeeded");
    hold(&native_app, true);
    try addTask(&native_app, "k2", "keep-sleep", "s2", "{\"ms\":100000}", "background");
    hold(&native_app, false);
    const while_task_runs = try keepAliveCalls(&native_app, 1);
    defer std.testing.allocator.free(while_task_runs);
    try std.testing.expectEqualSlices(bool, &[_]bool{true}, while_task_runs);
    try cancelSource(&native_app, "s2");
    try expectCompleted(&native_app, "k2", "cancelled");
    hold(&native_app, false);
    const done = try keepAliveCalls(&native_app, 2);
    defer std.testing.allocator.free(done);
    try std.testing.expectEqualSlices(bool, &[_]bool{ true, false }, done);
}

test "a normal task never has the native app keep the app running" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 2, 2);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "n1", "sleep", "s", "{\"ms\":10}", "background");
    try expectCompleted(&native_app, "n1", "succeeded");
    try std.Io.sleep(std.testing.io, .fromMilliseconds(50), .awake);
    const calls = try keepAliveCalls(&native_app, 0);
    defer std.testing.allocator.free(calls);
    try std.testing.expectEqual(@as(usize, 0), calls.len);
}

test "a keep-alive parent keeps the app running until its children are done and it ends" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 3, 2);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "p1", "keep-parent", "s", "{\"children\":2,\"childMs\":20}", "background");
    try expectCompleted(&native_app, "p1", "succeeded");
    const calls = try keepAliveCalls(&native_app, 2);
    defer std.testing.allocator.free(calls);
    try std.testing.expectEqualSlices(bool, &[_]bool{ true, false }, calls);
}

fn nativeCallTask(services: ziggy.task_runner.TaskServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, context: ziggy.task_runner.TaskContext, payload: std.json.Value) !ziggy.json.Raw {
    _ = context;
    const method = ziggy.json.getString(payload, "method").?;
    const reply = try services.nativeCall(io, allocator, timers, method, "{\"key\":\"value\"}");
    if (!reply.succeeded) {
        return .{
            .text = try ziggy.json.stringify(allocator, .{
                .failedBecause = reply.text,
            }),
        };
    }
    return .{
        .text = reply.text,
    };
}

test "a task has the native app do something only the platform can do, and gets its result" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    const native_call_tasks = helpers.task_handlers ++ [_]ziggy.task_runner.TaskHandlerEntry{
        .{ .name = "native-call", .handler = ziggy.task_runner.wrapTask("native-call", nativeCallTask) },
    };
    var native_call_app = helpers.app;
    native_call_app.tasks = &native_call_tasks;
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), native_call_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"h1\",\"taskType\":\"native-call\",\"source\":\"src\",\"data\":{\"method\":\"exportFile\"},\"priority\":\"background\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"outputs\":{\"method\":\"exportFile\",\"request\":{\"key\":\"value\"}}");
}

test "a task is told why the native app could not do the native call" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    const native_call_tasks = helpers.task_handlers ++ [_]ziggy.task_runner.TaskHandlerEntry{
        .{ .name = "native-call", .handler = ziggy.task_runner.wrapTask("native-call", nativeCallTask) },
    };
    var native_call_app = helpers.app;
    native_call_app.tasks = &native_call_tasks;
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), native_call_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"h2\",\"taskType\":\"native-call\",\"source\":\"src\",\"data\":{\"method\":\"fail\"},\"priority\":\"background\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"outputs\":{\"failedBecause\":\"The phone refused.\"}");
}

test "a task on a platform with no native call callback gets NativeCallMissing" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    const native_call_tasks = helpers.task_handlers ++ [_]ziggy.task_runner.TaskHandlerEntry{
        .{ .name = "native-call", .handler = ziggy.task_runner.wrapTask("native-call", nativeCallTask) },
    };
    var native_call_app = helpers.app;
    native_call_app.tasks = &native_call_tasks;
    var config = native_app.config(1, 1);
    config.has_native_call = false;
    try native_app.start(std.testing.io, std.testing.allocator, config, native_call_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"h3\",\"taskType\":\"native-call\",\"source\":\"src\",\"data\":{\"method\":\"exportFile\"},\"priority\":\"background\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "NativeCallMissing");
}

fn nativeCallerTask(services: ziggy.task_runner.TaskServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, context: ziggy.task_runner.TaskContext, payload: std.json.Value) !ziggy.json.Raw {
    _ = timers;
    _ = context;
    _ = payload;
    var storage: ziggy.task_runner.TaskNativeCaller = undefined;
    const requester = services.nativeCaller(&storage) orelse {
        return .{
            .text = "\"no requester\"",
        };
    };
    return .{
        .text = try requester.call(io, allocator, "shareFile", "{\"name\":\"a.jpg\"}"),
    };
}

test "a task's native caller reaches the native app through the native call callback" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    const native_call_tasks = helpers.task_handlers ++ [_]ziggy.task_runner.TaskHandlerEntry{
        .{ .name = "native-caller", .handler = ziggy.task_runner.wrapTask("native-caller", nativeCallerTask) },
    };
    var native_call_app = helpers.app;
    native_call_app.tasks = &native_call_tasks;
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), native_call_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"r1\",\"taskType\":\"native-caller\",\"source\":\"src\",\"data\":null,\"priority\":\"background\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"outputs\":{\"method\":\"shareFile\",\"request\":{\"name\":\"a.jpg\"}}");
}

test "a task has no native caller when the native app gave no native call callback" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    const native_call_tasks = helpers.task_handlers ++ [_]ziggy.task_runner.TaskHandlerEntry{
        .{ .name = "native-caller", .handler = ziggy.task_runner.wrapTask("native-caller", nativeCallerTask) },
    };
    var native_call_app = helpers.app;
    native_call_app.tasks = &native_call_tasks;
    var config = native_app.config(1, 1);
    config.has_native_call = false;
    try native_app.start(std.testing.io, std.testing.allocator, config, native_call_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"r2\",\"taskType\":\"native-caller\",\"source\":\"src\",\"data\":null,\"priority\":\"background\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"outputs\":\"no requester\"");
}

test "a dialog the native app could not show fails the task with NativeCallFailed" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), helpers.app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    native_app.setResult(std.testing.io, std.testing.allocator, "pick-paths", false, "The dialog could not be shown.");
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"p1\",\"taskType\":\"pick-open\",\"source\":\"src\",\"data\":null,\"priority\":\"background\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"errorMessage\":\"NativeCallFailed\"");
}

test "task-completed carries the full task result: the task's type and its input" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "t1", "quick", "s", "{\"a\":1}", "background");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"kind\":\"system\",\"name\":\"task-completed\",\"data\":{\"taskId\":\"t1\",\"result\":{\"taskId\":\"t1\",\"status\":\"succeeded\",\"outputs\":\"done\",\"type\":\"quick\",\"inputs\":{\"a\":1}}}}");
}

test "add-task with a priority that is not interactive or background is an error reply" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"add-task\",\"data\":{\"taskId\":\"x\",\"taskType\":\"quick\",\"source\":\"s\",\"data\":null,\"priority\":\"urgent\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":false,\"error\":\"InvalidMessageData: the field \\\"priority\\\" does not fit (");
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"id\":2,\"name\":\"add-task\",\"data\":{\"taskId\":\"y\",\"taskType\":\"quick\",\"source\":\"s\",\"data\":null,\"priority\":5}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":2,\"ok\":false,\"error\":\"InvalidMessageData: the field \\\"priority\\\" does not fit (");
}

test "add-task without a priority runs the task as background" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"t1\",\"taskType\":\"quick\",\"source\":\"s\",\"data\":null}}");
    try expectCompleted(&native_app, "t1", "succeeded");
}

test "cancel-tasks with the source as an object instead of a bare string is an error reply" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"cancel-tasks\",\"data\":{\"source\":\"s\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":false,\"error\":\"InvalidMessageData: ");
}

test "add-task takes the priority interactive or background, or none, and refuses anything else" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"id\":1,\"name\":\"add-task\",\"data\":{\"taskId\":\"a\",\"taskType\":\"quick\",\"source\":\"s\",\"data\":null,\"priority\":\"interactive\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":1,\"ok\":true,\"data\":{}}");
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"id\":2,\"name\":\"add-task\",\"data\":{\"taskId\":\"b\",\"taskType\":\"quick\",\"source\":\"s\",\"data\":null,\"priority\":\"background\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":2,\"ok\":true,\"data\":{}}");
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"id\":3,\"name\":\"add-task\",\"data\":{\"taskId\":\"c\",\"taskType\":\"quick\",\"source\":\"s\",\"data\":null}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":3,\"ok\":true,\"data\":{}}");
    native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"id\":4,\"name\":\"add-task\",\"data\":{\"taskId\":\"d\",\"taskType\":\"quick\",\"source\":\"s\",\"data\":null,\"priority\":\"Interactive\"}}");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "{\"id\":4,\"ok\":false,\"error\":\"InvalidMessageData: the field \\\"priority\\\" does not fit (");
}

test "a second interactive task goes in front of the first one still waiting, and background tasks keep their arrival order" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    try helpers.createCore(&native_app, 1, 1);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "blocker", "sleep", "s", "{\"ms\":150,\"name\":\"blocker\"}", "background");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"start\":\"blocker\"");
    try addTask(&native_app, "background-1", "sleep", "s", "{\"ms\":2,\"name\":\"background-1\"}", "background");
    try addTask(&native_app, "interactive-1", "sleep", "s", "{\"ms\":2,\"name\":\"interactive-1\"}", "interactive");
    try addTask(&native_app, "background-2", "sleep", "s", "{\"ms\":2,\"name\":\"background-2\"}", "background");
    try addTask(&native_app, "interactive-2", "sleep", "s", "{\"ms\":2,\"name\":\"interactive-2\"}", "interactive");
    try expectCompleted(&native_app, "background-2", "succeeded");
    const order = [_][]const u8{ "interactive-2", "interactive-1", "background-1", "background-2" };
    var previous: usize = 0;
    for (order) |name| {
        var buffer: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "\"start\":\"{s}\"", .{name});
        const index = native_app.indexOfContaining(std.testing.io, std.testing.allocator, text).?;
        try std.testing.expect(index >= previous);
        previous = index;
    }
}

//
// The payload of the greet task.
//
const GreetPayload = struct {
    // Who to greet.
    name: []const u8,
};

//
// The result of the greet task.
//
const GreetResult = struct {
    // The greeting, naming the task it came from.
    greeting: []const u8,
};

//
// greet: a task with a typed payload and result, whose result is a greeting built from the payload and the task's context.
//
fn greetTask(services: ziggy.task_runner.TaskServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, context: ziggy.task_runner.TaskContext, payload: GreetPayload) !GreetResult {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .greeting = try std.fmt.allocPrint(allocator, "Hello {s} from {s} of {s}", .{ payload.name, context.task_id, context.source }),
    };
}

test "a task's data is parsed into its payload type and its result turned into JSON, and data that does not fit fails the task" {
    var native_app: helpers.FakeNativeApp = undefined;
    native_app.init();
    defer native_app.deinit(std.testing.io, std.testing.allocator);
    const greet_tasks = helpers.task_handlers ++ [_]ziggy.task_runner.TaskHandlerEntry{
        .{ .name = "greet", .handler = ziggy.task_runner.wrapTask("greet", greetTask) },
    };
    var greet_app = helpers.app;
    greet_app.tasks = &greet_tasks;
    try native_app.start(std.testing.io, std.testing.allocator, native_app.config(1, 1), greet_app);
    defer native_app.stop(std.testing.io, std.testing.allocator);
    try addTask(&native_app, "g1", "greet", "src", "{\"name\":\"Ada\",\"unknown\":1}", "background");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"taskId\":\"g1\",\"status\":\"succeeded\",\"outputs\":{\"greeting\":\"Hello Ada from g1 of src\"}");
    try addTask(&native_app, "g2", "greet", "src", "{}", "background");
    try native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"taskId\":\"g2\",\"status\":\"failed\",\"error\":{\"message\":\"MissingField\"}");
}

test "a child runs at the priority it asks for, and otherwise at its parent's" {
    const interactive = ziggy.task_runner.TaskPriority.interactive;
    const background = ziggy.task_runner.TaskPriority.background;
    try std.testing.expectEqual(background, ziggy.task_runner.resolveTaskPriority(background, interactive));
    try std.testing.expectEqual(interactive, ziggy.task_runner.resolveTaskPriority(interactive, background));
    try std.testing.expectEqual(interactive, ziggy.task_runner.resolveTaskPriority(null, interactive));
    try std.testing.expectEqual(background, ziggy.task_runner.resolveTaskPriority(null, background));
}
