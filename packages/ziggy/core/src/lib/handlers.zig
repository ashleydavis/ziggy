//
// The message handlers of both kinds of message, app and system: the forms a handler takes, the Answer it returns and the Reply it
// answers later with, and the wrapper that turns a handler of any form into the one function the core calls. The core parses a
// message's data into the handler's request type before it calls the handler, and turns what the handler returns into the message
// response.
//

const std = @import("std");
const core_lib = @import("core.zig");
const json = @import("json.zig");

const Core = core_lib.Core;
const Message = core_lib.Message;
const MessageResult = core_lib.MessageResult;

//
// What a message handler, as wrapNamed made it, did with a message: what the handler returned, or the text of the error reply for
// data that did not fit the handler's request type (the handler then did not run).
//
pub const HandlerOutcome = union(enum) {
    // What the handler returned.
    result: MessageResult,
    // The data did not fit the handler's request type, and this says how, starting with InvalidMessageData. Allocated with the arena.
    invalid_data: []const u8,
    // The handler answered through its reply and then again, by what it returned or by failing. The message has had its answer, so
    // this is reported as a core-error system event, with no id, rather than as a second answer. Allocated with the arena.
    answered_twice: []const u8,
};

//
// A message handler, of either kind of message, as the core calls it: wrapNamed turns a handler of any form into one, which parses the
// message's data into the handler's request type and turns what the handler returns into the message response.
//
pub const WrappedHandler = *const fn (core: *Core, arena: std.mem.Allocator, message: Message) anyerror!HandlerOutcome;

//
// A message name and its wrapped handler, as App lists the app's messages.
//
pub const MessageEntry = struct {
    // The message's name.
    name: []const u8,
    // Its handler, wrapped.
    handler: WrappedHandler,
};

//
// What a message handler returns when it does not answer at once with its response: Answer(T), where T is the type of the
// response.
//
//   .now = value      the response, sent at once
//   .task = .{ .task_type = ..., .data = ... }
//                     queued as a task of that type whose input is `data`, JSON text (ziggy.json.stringify makes it from any value);
//                     the task's result is the response, sent when the task ends, and a task that fails or is cancelled gives an
//                     error response
//   .later            answered afterwards through the handler's reply (see Reply), which the handler keeps
//
pub fn Answer(comptime T: type) type {
    return union(enum) {
        // The type of the response, which App checks against the handler's reply.
        pub const ziggy_answer_of = T;

        // The response, sent at once.
        now: T,
        // The task whose result is the response.
        task: AnswerTask,
        // The handler's reply answers later.
        later,
    };
}

//
// The task that answers a message, in Answer's `.task`.
//
pub const AnswerTask = struct {
    // The task type, one of the app's `.tasks`.
    task_type: []const u8,
    // The task's input, as JSON text.
    data: []const u8,
};

//
// The handle a message handler that answers later takes as its fourth parameter, where T is the type of the response. The handler
// keeps it (it is a small value that may be copied and stored anywhere) and returns `.later`, and the message is answered once, from
// any thread, with send or fail. Answering a second time is the error MessageAlreadyAnswered. A reply never answered is reported as a
// core-error event naming MessageNotAnswered and the message when the core is destroyed. The reply must not be used after that.
//
pub fn Reply(comptime T: type) type {
    return struct {
        // The type of the response, which App checks against the handler's answer.
        pub const ziggy_reply_of = T;

        // The core the message came to.
        core: *Core,
        // Which of the core's replies still to be answered this is.
        serial: u64,

        //
        // Answers the message with the response `value`.
        //
        pub fn send(self: @This(), value: T) !void {
            var arena_state = std.heap.ArenaAllocator.init(self.core.allocator);
            defer arena_state.deinit();
            const response_json = if (T == void) "null" else try json.stringify(arena_state.allocator(), value);
            try self.core.sendLaterReply(self.serial, response_json);
        }

        //
        // Answers the message with an error response: the text the app's describe_error gives for the error, or else its name.
        //
        pub fn fail(self: @This(), err: anyerror) !void {
            try self.core.failLaterReply(self.serial, err);
        }
    };
}

//
// Wraps a message handler, app or system, in the function the core calls. `label` names the handler in a compile error, such as
// `the message "hello-world"`. A handler is one of
//
//   fn (core: *ziggy.core.Core, arena: std.mem.Allocator, request: Request) !Response
//   fn (core: *ziggy.core.Core, arena: std.mem.Allocator, request: Request) !ziggy.core.Answer(Response)
//   fn (core: *ziggy.core.Core, arena: std.mem.Allocator, request: Request, reply: ziggy.core.Reply(Response)) !ziggy.core.Answer(Response)
//   fn (core: *ziggy.core.Core, arena: std.mem.Allocator, message: ziggy.core.Message) !ziggy.core.MessageResult
//
// Request is the type the message's data is parsed into (a struct, or any type std.json can parse into). A Response is turned into the
// JSON of the message response, and void is a response holding null. An Answer answers at once, with a task or later (see Answer),
// and only a handler that takes a reply may answer later. Fields of the data that Request does not have are ignored, and data that is
// null is parsed as an empty object when Request is a struct, so a request with no fields, or with every field optional or given a
// default, needs no data. The last form gets the message unparsed, with its name and id, and answers with a MessageResult.
//
pub fn wrapNamed(comptime label: []const u8, comptime handler: anytype) WrappedHandler {
    const Handler = @TypeOf(handler);
    const forms = "fn (core: *ziggy.core.Core, arena: std.mem.Allocator, request: YourRequest) !YourResponse, the same returning !ziggy.core.Answer(YourResponse), the same with a fourth parameter reply: ziggy.core.Reply(YourResponse), or fn (core: *ziggy.core.Core, arena: std.mem.Allocator, message: ziggy.core.Message) !ziggy.core.MessageResult";
    if (@typeInfo(Handler) != .@"fn") {
        @compileError("ziggy.core: the handler of " ++ label ++ " is not a function. A message handler is " ++ forms ++ ".");
    }
    const info = @typeInfo(Handler).@"fn";
    const takes_reply = info.params.len == 4 and info.params[3].type != null and @typeInfo(info.params[3].type.?) == .@"struct" and @hasDecl(info.params[3].type.?, "ziggy_reply_of");
    if ((info.params.len != 3 and !takes_reply) or info.params[0].type != *Core or info.params[1].type != std.mem.Allocator or info.params[2].type == null) {
        @compileError("ziggy.core: the handler of " ++ label ++ " has the wrong parameters. A message handler is " ++ forms ++ ".");
    }
    const Request = info.params[2].type.?;
    const Return = info.return_type orelse {
        @compileError("ziggy.core: the handler of " ++ label ++ " must name its return type.");
    };
    const returns_error = @typeInfo(Return) == .error_union;
    const Response = if (returns_error) @typeInfo(Return).error_union.payload else Return;
    const returns_answer = @typeInfo(Response) == .@"union" and @hasDecl(Response, "ziggy_answer_of");
    if (Request == Message and (takes_reply or Response != MessageResult)) {
        @compileError("ziggy.core: the handler of " ++ label ++ " takes ziggy.core.Message, so it takes no reply and must return ziggy.core.MessageResult.");
    }
    if (takes_reply and !(returns_answer and Response.ziggy_answer_of == info.params[3].type.?.ziggy_reply_of)) {
        @compileError("ziggy.core: the handler of " ++ label ++ " takes a ziggy.core.Reply(T), so it must return ziggy.core.Answer(T) of the same T.");
    }
    return &struct {
        fn call(core: *Core, arena: std.mem.Allocator, message: Message) anyerror!HandlerOutcome {
            if (Request == Message) {
                return .{
                    .result = if (returns_error) try handler(core, arena, message) else handler(core, arena, message),
                };
            }
            const data: std.json.Value = if (message.data == .null and @typeInfo(Request) == .@"struct") .{
                .object = .empty,
            } else message.data;
            const request = std.json.parseFromValueLeaky(Request, arena, data, .{
                .ignore_unknown_fields = true,
            }) catch |err| {
                if (err == error.OutOfMemory) {
                    return err;
                }
                return .{
                    .invalid_data = try describeInvalidData(Request, arena, data, err),
                };
            };
            if (takes_reply) {
                const ReplyType = info.params[3].type.?;
                const serial = try core.openLaterReply(message);
                const reply: ReplyType = .{
                    .core = core,
                    .serial = serial,
                };
                const answer = if (returns_error) handler(core, arena, request, reply) catch |err| {
                    core.closeLaterReply(serial) catch {
                        return .{
                            .answered_twice = try std.fmt.allocPrint(arena, "MessageAlreadyAnswered: {s} failed with {s} after it answered", .{ message.name, @errorName(err) }),
                        };
                    };
                    return err;
                } else handler(core, arena, request, reply);
                if (answer != .later) {
                    core.closeLaterReply(serial) catch {
                        return .{
                            .answered_twice = try std.fmt.allocPrint(arena, "MessageAlreadyAnswered: {s} answered through its reply and again by what it returned", .{message.name}),
                        };
                    };
                }
                return .{
                    .result = try answerResult(Response, core, arena, message, answer, true),
                };
            }
            const response = if (returns_error) try handler(core, arena, request) else handler(core, arena, request);
            if (returns_answer) {
                return .{
                    .result = try answerResult(Response, core, arena, message, response, false),
                };
            }
            if (Response == void) {
                return .{
                    .result = .none,
                };
            }
            return .{
                .result = .{
                    .response = try json.stringify(arena, response),
                },
            };
        }
    }.call;
}

//
// Wraps a message handler that has no name known when Ziggy is built, such as one registered while the core runs: see wrapNamed.
//
pub fn wrap(comptime handler: anytype) WrappedHandler {
    return wrapNamed("a message registered while the core runs", handler);
}

//
// What the core does about an Answer a handler returned: sends `.now` at once, queues `.task`, and for `.later` sends nothing now,
// which only a handler that took a reply may do: for any other, `.later` would leave the message unanswered, so it is the error
// MessageNotAnswered.
//
fn answerResult(comptime AnswerType: type, core: *Core, arena: std.mem.Allocator, message: Message, answer: AnswerType, took_reply: bool) !MessageResult {
    switch (answer) {
        .now => |value| {
            if (AnswerType.ziggy_answer_of == void) {
                return .none;
            }
            return .{
                .response = try json.stringify(arena, value),
            };
        },
        .task => |task| {
            return try core.answerWithTask(message, task.task_type, task.data);
        },
        .later => {
            if (!took_reply) {
                return error.MessageNotAnswered;
            }
            return .answered_by_task;
        },
    }
}

//
// The text of the error reply for data that did not parse into Request: InvalidMessageData, then, for a struct, the first field that
// is missing or does not fit, and otherwise the error the parse ended with.
//
fn describeInvalidData(comptime Request: type, arena: std.mem.Allocator, data: std.json.Value, parse_error: anyerror) ![]const u8 {
    if (@typeInfo(Request) == .@"struct") {
        if (data != .object) {
            return try arena.dupe(u8, "InvalidMessageData: the data is not an object");
        }
        inline for (@typeInfo(Request).@"struct".fields) |field| {
            if (data.object.get(field.name)) |value| {
                _ = std.json.parseFromValueLeaky(field.type, arena, value, .{
                    .ignore_unknown_fields = true,
                }) catch |field_error| {
                    if (field_error == error.OutOfMemory) {
                        return field_error;
                    }
                    return try std.fmt.allocPrint(arena, "InvalidMessageData: the field \"{s}\" does not fit ({s})", .{ field.name, @errorName(field_error) });
                };
            }
            else if (field.defaultValue() == null and @typeInfo(field.type) != .optional) {
                return try std.fmt.allocPrint(arena, "InvalidMessageData: the field \"{s}\" is missing", .{field.name});
            }
        }
    }
    return try std.fmt.allocPrint(arena, "InvalidMessageData: {s}", .{@errorName(parse_error)});
}

