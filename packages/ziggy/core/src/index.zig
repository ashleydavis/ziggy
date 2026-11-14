//
// Ziggy core: the C interface, the main thread, the worker pool and its workers, the messages they send each other, the origin check,
// native calls, the remote control connection and running a command.
//

pub const types = @import("lib/types.zig");
pub const json = @import("lib/json.zig");
pub const origin_check = @import("lib/origin-check.zig");
pub const task_runner = @import("lib/task-runner.zig");
pub const worker = @import("lib/worker.zig");
pub const worker_pool = @import("lib/worker-pool.zig");
pub const worker_messages = @import("lib/worker-messages.zig");
pub const message_queue = @import("lib/message-queue.zig");
pub const timers = @import("lib/timers.zig");
pub const core = @import("lib/core.zig");
pub const ziggy_api = @import("lib/ziggy-api.zig");
pub const jni = @import("lib/jni.zig");
pub const remote_control = @import("lib/remote-control.zig");
pub const remote_control_arguments = @import("lib/remote-control-arguments.zig");
pub const new_instance = @import("lib/new_instance.zig");
pub const app_windows = @import("lib/app_windows.zig");
pub const theme = @import("lib/theme.zig");
pub const native_message = @import("lib/native-message.zig");
pub const native_call_result = @import("lib/native-call-result.zig");
pub const fake_native_app = @import("lib/fake-native-app.zig");
pub const shortcut = @import("lib/shortcut.zig");
pub const menu = @import("lib/menu.zig");
pub const action = @import("lib/action.zig");
pub const shortcuts = @import("lib/shortcuts.zig");
pub const inject_script = @import("lib/inject-script.zig");
pub const ui_files = @import("lib/ui-files.zig");
pub const dropped_files = @import("lib/dropped-files.zig");
pub const task_queue = @import("lib/task-queue.zig");
pub const exec = @import("lib/exec.zig");

//
// Ziggy's utils and its log, which are packages of their own, given here so the app reaches them through @import("ziggy") as it
// reaches the rest of Ziggy.
//
pub const utils = @import("utils");
pub const log = @import("log");
pub const UiFile = ui_files.UiFile;

//
// Where the running app's config file and state file are, each in its own module, and the typed key-path API the app reads and writes
// them through. The config-state module's TOML and JSON values stay inside this package: an app reaches only the typed API, so no file
// format's type reaches its code.
//
pub const config_path = @import("lib/config-path.zig");
pub const state_path = @import("lib/state-path.zig");

const config_state_lib = @import("config_state");

pub const config_state = struct {
    pub const platform = config_state_lib.platform;
    pub const config = struct {
        pub const get = config_state_lib.config.get;
        pub const set = config_state_lib.config.set;
        pub const update = config_state_lib.config.update;
        pub const has = config_state_lib.config.has;
        pub const Values = config_state_lib.config.Values;
        pub const problem = config_state_lib.config.problem;
        pub const ConfigProblem = config_state_lib.config.ConfigProblem;
    };
    pub const state = struct {
        pub const get = config_state_lib.state.get;
        pub const set = config_state_lib.state.set;
        pub const update = config_state_lib.state.update;
        pub const Values = config_state_lib.state.Values;
        pub const status = config_state_lib.state.status;
        pub const StateStatus = config_state_lib.state.StateStatus;
    };
};
