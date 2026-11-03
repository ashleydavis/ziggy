//
// The template's actions: named pieces of its functionality that take no arguments, whose handlers are in the frontend. A menu item,
// a shortcut, the frontend or the backend runs one by its name. Hello world example: change it into your own actions, or delete it.
// See Ziggy's guide "Actions".
//

const ziggy = @import("ziggy");

//
// The actions the template passes to ziggy.core.App as `.actions`. Say Hello From an Action is on the Hello menu, and the frontend's
// "Say hello from an action" button runs it too.
//
pub const actions: []const ziggy.action.Action = &.{
    .{
        .name = "hello-from-action",
        .label = "Say Hello From an Action",
        .shortcut = "CmdOrCtrl+Shift+H",
    },
};
