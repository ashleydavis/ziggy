//
// The app's message handlers: the forms a handler takes, the Response it returns and the Reply it sends its response later with, and the
// wrapper that turns a handler of any form into the one function the main thread calls. Every message handler takes the same standard
// arguments: the handler services, the main thread's timers, the main thread's Io and an allocator, then the payload. The main thread
// parses a message's data into the handler's payload type before it calls the handler, and turns what the handler returns into the
// message response.
//

const std = @import("std");
const json = @import("json.zig");
const types = @import("types.zig");
const message_queue = @import("message-queue.zig");
const services_lib = @import("services.zig");
const timers_lib = @import("timers.zig");

const HandlerServices = services_lib.HandlerServices;
const Timers = timers_lib.Timers;
const MessageQueue = message_queue.MessageQueue;

//
// The number the main thread's own messages (a stop, a drop, a response a handler sends later) reach its queue under.
//
pub const from_core: u32 = 0xFFFF_FFF1;

//
// One app message from the frontend, unparsed, as the main thread gives it to a message handler whose payload is ziggy.core.Message.
//
pub const Message = struct {
    // The message's id, which its message response carries back to the frontend, or null for a message sent with send, which
    // gets no message response.
    id: ?std.json.Value,
    // The message's name, which the frontend gave as the first argument of invoke or send and which chose the handler. It is
    // never empty: the main thread refuses a message without one, with MissingMessageName, before any handler runs. It lives in the
    // allocator the handler is given.
    name: []const u8,
    // The data the frontend sent, the app's own to lay out, or null when it sent none. It lives in the allocator the handler is given.
    data: std.json.Value,
};

//
// What a message handler that takes ziggy.core.Message did about the message response.
//
pub const MessageResult = union(enum) {
    // The JSON text of the message response, allocated with the allocator the handler was given. It is sent when the message has an
    // id.
    response: []const u8,
    // There is nothing to send back. A message with an id still gets a successful message response holding null, so the
    // frontend's invoke never waits for ever.
    none,
    // The response is the result of this task, which the main thread queues under the source "request" and whose result it sends when
    // the task ends. A task that fails or is cancelled gives an error message response. A message with no id is refused with
    // MessageHasNoId and nothing is queued.
    task: ResponseTask,
    // Nothing is sent now: the handler's Reply sends the response later.
    later,
};

//
// What a message handler, as wrapNamed made it, did with a message: what the handler returned, or the text of the error response for
// data that did not fit the handler's payload type (the handler then did not run).
//
pub const HandlerOutcome = union(enum) {
    // What the handler returned.
    result: MessageResult,
    // The data did not fit the handler's payload type, and this describes how, starting with InvalidMessageData. Allocated with the
    // allocator.
    invalid_data: []const u8,
};

//
// Where a handler that takes a Reply sends its response: the main thread's queue and the serial the main thread recorded the message
// under before the handler ran.
//
pub const ReplyTarget = struct {
    // The main thread's queue.
    queue: *MessageQueue,
    // Gives the text of an error response, or null to use the error's name. A constant of the app's code.
    describe_error: ?types.ErrorDescriber,
    // Which of the main thread's recorded messages this is.
    serial: u64,
};

//
// A message handler as the main thread calls it: wrapNamed turns a handler of any form into one, which parses the message's data into
// the handler's payload type and turns what the handler returns into the message response. `reply` is given only to a handler whose
// entry takes a reply (see MessageEntry), and is null for every other.
//
pub const WrappedHandler = *const fn (services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, message: Message, reply: ?ReplyTarget) anyerror!HandlerOutcome;

//
// A message name and its wrapped handler, as App lists the app's messages.
//
pub const MessageEntry = struct {
    // The message's name.
    name: []const u8,
    // Its handler, wrapped.
    handler: WrappedHandler,
    // Whether the handler takes a Reply, so the main thread records the message before it runs.
    takes_reply: bool,
};

//
// What a message handler returns when it does not give its response at once: Response(T), where T is the type of the response.
//
//   .now = value      the response, sent at once
//   .task = .{ .task_type = ..., .data = ... }
//                     queued as a task of that type whose input is `data`, JSON text (ziggy.json.stringify makes it from any value);
//                     the task's result is the response, sent when the task ends, and a task that fails or is cancelled gives an
//                     error response
//   .later            sent afterwards through the handler's reply (see Reply), which the handler keeps
//
pub fn Response(comptime T: type) type {
    return union(enum) {
        // The type of the response, which App checks against the handler's reply.
        pub const ziggy_response_of = T;

        // The response, sent at once.
        now: T,
        // The task whose result is the response.
        task: ResponseTask,
        // The handler's reply sends the response later.
        later,
    };
}

//
// The task whose result is a message's response, in Response's `.task` or MessageResult's `.task`.
//
pub const ResponseTask = struct {
    // The task type, one of the app's `.tasks`.
    task_type: []const u8,
    // The task's input, as JSON text.
    data: []const u8,
};

//
// The handle a message handler that sends its response later takes after its payload, where T is the type of the response. The handler
// keeps it (it is a small value that may be copied and stored anywhere) and returns `.later`, and the response is sent once, from any
// thread, with send or fail, which post it to the main thread's queue. It holds no part of the main thread's state: only the main
// thread's queue and constants. A second response is reported as a core-error event naming MessageAlreadyAnswered, and a message that
// never gets one as a core-error event naming MessageNotAnswered and the message when the main thread stops. The reply must not be used
// after that.
//
pub fn Reply(comptime T: type) type {
    return struct {
        // The type of the response, which App checks against the handler's Response.
        pub const ziggy_reply_of = T;

        // Where the response goes.
        target: ReplyTarget,

        //
        // Sends the response `value`. The Io and the allocator are the calling thread's own, and the allocator is used only during the call.
        //
        pub fn send(self: @This(), io: std.Io, allocator: std.mem.Allocator, value: T) !void {
            var arena_state = std.heap.ArenaAllocator.init(allocator);
            defer arena_state.deinit();
            const response_json = if (T == void) "null" else try json.stringify(arena_state.allocator(), value);
            try postLaterReply(io, self.target, arena_state.allocator(), json.Raw{
                .text = response_json,
            }, null);
        }

        //
        // Sends an error response: the text the app's describe_error gives for the error, or else its name. The Io and the allocator are the calling
        // thread's own, used only during the call.
        //
        pub fn fail(self: @This(), io: std.Io, allocator: std.mem.Allocator, err: anyerror) !void {
            var arena_state = std.heap.ArenaAllocator.init(allocator);
            defer arena_state.deinit();
            const described: ?[]const u8 = if (self.target.describe_error) |describe| describe(err) else null;
            try postLaterReply(io, self.target, arena_state.allocator(), null, described orelse @errorName(err));
        }
    };
}

//
// Posts a later response to the main thread's queue, with the calling thread's Io: the data, or the error text.
//
fn postLaterReply(io: std.Io, target: ReplyTarget, arena: std.mem.Allocator, data: ?json.Raw, error_text: ?[]const u8) !void {
    const text = if (error_text) |reason| try json.stringify(arena, .{
        .type = "later-reply",
        .serial = target.serial,
        .@"error" = reason,
    }) else try json.stringify(arena, .{
        .type = "later-reply",
        .serial = target.serial,
        .data = data.?,
    });
    try target.queue.post(io, from_core, text);
}

//
// Wraps a message handler in the function the main thread calls. `label` names the handler in a compile error, such as
// `the message "hello-world"`. Every handler takes the standard arguments (services, timers, io, allocator), then its payload, and is
// one of
//
//   fn (services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, payload: Payload) !Result
//   the same returning !ziggy.core.Response(Result)
//   the same with a reply after the payload, reply: ziggy.core.Reply(Result), returning !ziggy.core.Response(Result)
//   the same with the payload message: ziggy.core.Message, returning !ziggy.core.MessageResult
//
// Payload is the type the message's data is parsed into (a struct, or any type std.json can parse into). A Result is turned into the
// JSON of the message response, and void is a response holding null. An Response gives the response at once, with a task or later (see
// Response), and only a handler that takes a reply may give it later. Fields of the data that Payload does not have are ignored, and data
// that is null is parsed as an empty object when Payload is a struct, so a payload with no fields, or with every field optional or given
// a default, needs no data. The last form gets the message unparsed, with its name and id, and returns a MessageResult.
//
pub fn wrapNamed(comptime label: []const u8, comptime handler: anytype) MessageEntry {
    const Handler = @TypeOf(handler);
    const forms = "fn (services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, payload: YourPayload) !YourResult, the same returning !ziggy.core.Response(YourResult), the same with a sixth parameter reply: ziggy.core.Reply(YourResult), or the same with the payload message: ziggy.core.Message returning !ziggy.core.MessageResult";
    if (@typeInfo(Handler) != .@"fn") {
        @compileError("ziggy.core: the handler of " ++ label ++ " is not a function. A message handler is " ++ forms ++ ".");
    }
    const info = @typeInfo(Handler).@"fn";
    const takes_reply = info.params.len == 6 and info.params[5].type != null and @typeInfo(info.params[5].type.?) == .@"struct" and @hasDecl(info.params[5].type.?, "ziggy_reply_of");
    if ((info.params.len != 5 and !takes_reply) or info.params[0].type != HandlerServices or info.params[1].type != Timers or info.params[2].type != std.Io or info.params[3].type != std.mem.Allocator or info.params[4].type == null) {
        @compileError("ziggy.core: the handler of " ++ label ++ " has the wrong parameters. A message handler is " ++ forms ++ ".");
    }
    const Payload = info.params[4].type.?;
    const Return = info.return_type orelse {
        @compileError("ziggy.core: the handler of " ++ label ++ " must name its return type.");
    };
    const returns_error = @typeInfo(Return) == .error_union;
    const Result = if (returns_error) @typeInfo(Return).error_union.payload else Return;
    const returns_answer = @typeInfo(Result) == .@"union" and @hasDecl(Result, "ziggy_response_of");
    if (Payload == Message and (takes_reply or Result != MessageResult)) {
        @compileError("ziggy.core: the handler of " ++ label ++ " takes ziggy.core.Message, so it takes no reply and must return ziggy.core.MessageResult.");
    }
    if (takes_reply and !(returns_answer and Result.ziggy_response_of == info.params[5].type.?.ziggy_reply_of)) {
        @compileError("ziggy.core: the handler of " ++ label ++ " takes a ziggy.core.Reply(T), so it must return ziggy.core.Response(T) of the same T.");
    }
    const wrapped = struct {
        fn call(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, message: Message, reply: ?ReplyTarget) anyerror!HandlerOutcome {
            if (Payload == Message) {
                return .{
                    .result = if (returns_error) try handler(services, timers, io, allocator, message) else handler(services, timers, io, allocator, message),
                };
            }
            const payload = switch (try parsePayload(Payload, allocator, message.data)) {
                .parsed => |value| value,
                .invalid => |text| {
                    return .{
                        .invalid_data = text,
                    };
                },
            };
            if (takes_reply) {
                const ReplyType = info.params[5].type.?;
                const handle: ReplyType = .{
                    .target = reply.?,
                };
                const returned = if (returns_error) try handler(services, timers, io, allocator, payload, handle) else handler(services, timers, io, allocator, payload, handle);
                return .{
                    .result = try responseResult(Result, allocator, returned, true),
                };
            }
            const result = if (returns_error) try handler(services, timers, io, allocator, payload) else handler(services, timers, io, allocator, payload);
            if (returns_answer) {
                return .{
                    .result = try responseResult(Result, allocator, result, false),
                };
            }
            if (Result == void) {
                return .{
                    .result = .none,
                };
            }
            return .{
                .result = .{
                    .response = try json.stringify(allocator, result),
                },
            };
        }
    };
    return .{
        .name = "",
        .handler = wrapped.call,
        .takes_reply = takes_reply,
    };
}

//
// A payload parsed from a message's data, or the text of the error response when the data did not fit.
//
pub fn Parsed(comptime Payload: type) type {
    return union(enum) {
        // The payload.
        parsed: Payload,
        // How the data did not fit, starting with InvalidMessageData, allocated with the allocator.
        invalid: []const u8,
    };
}

//
// Parses a message's data into the payload type, as wrapNamed does for a handler: data that is null is an empty object when Payload is
// a struct, and fields Payload does not have are ignored.
//
pub fn parsePayload(comptime Payload: type, allocator: std.mem.Allocator, message_data: std.json.Value) !Parsed(Payload) {
    const data: std.json.Value = if (message_data == .null and @typeInfo(Payload) == .@"struct") .{
        .object = .empty,
    } else message_data;
    const payload = std.json.parseFromValueLeaky(Payload, allocator, data, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        if (err == error.OutOfMemory) {
            return err;
        }
        return .{
            .invalid = try describeInvalidData(Payload, allocator, data, err),
        };
    };
    return .{
        .parsed = payload,
    };
}

//
// What the main thread does about an Response a handler returned: sends `.now` at once, queues `.task`, and for `.later` sends nothing
// now, which only a handler that took a reply may do: for any other, `.later` would leave the message with no response, so it is the
// error MessageNotAnswered.
//
fn responseResult(comptime AnswerType: type, allocator: std.mem.Allocator, answer: AnswerType, took_reply: bool) !MessageResult {
    switch (answer) {
        .now => |value| {
            if (AnswerType.ziggy_response_of == void) {
                return .none;
            }
            return .{
                .response = try json.stringify(allocator, value),
            };
        },
        .task => |task| {
            return .{
                .task = task,
            };
        },
        .later => {
            if (!took_reply) {
                return error.MessageNotAnswered;
            }
            return .later;
        },
    }
}

//
// The text of the error response for data that did not parse into Payload: InvalidMessageData, then, for a struct, the first field
// that is missing or does not fit, and otherwise the error the parse ended with.
//
fn describeInvalidData(comptime Payload: type, allocator: std.mem.Allocator, data: std.json.Value, parse_error: anyerror) ![]const u8 {
    if (@typeInfo(Payload) == .@"struct") {
        if (data != .object) {
            return try allocator.dupe(u8, "InvalidMessageData: the data is not an object");
        }
        inline for (@typeInfo(Payload).@"struct".fields) |field| {
            if (data.object.get(field.name)) |value| {
                _ = std.json.parseFromValueLeaky(field.type, allocator, value, .{
                    .ignore_unknown_fields = true,
                }) catch |field_error| {
                    if (field_error == error.OutOfMemory) {
                        return field_error;
                    }
                    return try std.fmt.allocPrint(allocator, "InvalidMessageData: the field \"{s}\" does not fit ({s})", .{ field.name, @errorName(field_error) });
                };
            }
            else if (field.defaultValue() == null and @typeInfo(field.type) != .optional) {
                return try std.fmt.allocPrint(allocator, "InvalidMessageData: the field \"{s}\" is missing", .{field.name});
            }
        }
    }
    return try std.fmt.allocPrint(allocator, "InvalidMessageData: {s}", .{@errorName(parse_error)});
}
