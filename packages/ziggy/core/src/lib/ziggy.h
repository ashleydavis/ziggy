// The C interface to the Ziggy core. Every native app includes this one declaration.

#ifndef ZIGGY_H
#define ZIGGY_H

#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Wakes the native app's UI thread to take the core's messages with ziggy_take_native_message. The core calls it from any of its threads
// after it posts a message for the native app. It does nothing but have the platform run code on the UI thread (g_idle_add, PostMessage,
// DispatchQueue.main.async, a write the main looper watches for), and it is given the config's wake_data unread: the core never touches the
// native app's state, and the native app touches it only on its UI thread.
typedef void (*ziggy_wake_fn)(void *wake_data);

// The kinds of dialog a native app shows for a "pick-paths" call.
enum {
    // A dialog to choose one or more existing files to open.
    ZIGGY_PICK_OPEN_FILES = 0,
    // A dialog to choose where to save a file, with a suggested name.
    ZIGGY_PICK_SAVE_FILE = 1,
    // A dialog to choose a folder.
    ZIGGY_PICK_FOLDER = 2
};

// What the native app passes to ziggy_create. Every pointer is copied by the core, so it need only be valid during the call.
typedef struct ziggy_config {
    // What the core hands wake: a value that reaches the native app's UI thread through the platform (a window handle, a file
    // descriptor), never the native app's state. The core never reads or writes through it.
    void *wake_data;
    // Wakes the native app's UI thread. Required.
    ziggy_wake_fn wake;
    // Whether the native app does "os-version" calls.
    bool has_os_version;
    // Whether the native app does "quit" calls.
    bool has_quit;
    // Whether the native app does "pick-paths" calls.
    bool has_pick_paths;
    // Whether the native app does "menu-action" calls. False on a platform with no menu. Used only by the test control connection.
    bool has_menu_action;
    // Whether the native app does "keep-alive" calls.
    bool has_keep_alive;
    // Whether the native app does "native-call" calls, the app's own native calls.
    bool has_native_call;
    // Whether the native app does "screenshot" calls. Used only by the test control connection.
    bool has_screenshot;
    // The number of worker threads.
    uint32_t worker_threads;
    // The limit on child tasks in flight for any one parent task.
    uint32_t max_concurrent_child_tasks;
    // The URL prefix of the app's own bundled frontend, such as "ziggy-app://app/" or "https://ziggy-app.invalid/", the address the native app serves the frontend from (NUL terminated).
    const char *app_url_prefix;
    // The app's private data directory (NUL terminated).
    const char *data_dir;
    // Non-zero to start the test control connection. Used only in a test hooks build.
    bool test_mode;
    // The file the test control connection writes its port to, or NULL for none. Used only in a test hooks build.
    const char *test_port_file;
    // The number of the native app's command-line arguments in args, after the program's name. 0 for a native app with none (Android,
    // iOS).
    uint32_t arg_count;
    // The native app's command-line arguments after the program's name (NUL terminated), or NULL when arg_count is 0. The app reads them
    // through HandlerServices.arguments.
    const char *const *args;
} ziggy_config;

// The kinds of message ziggy_take_native_message gives.
enum {
    // A JSON message for the frontend, which the native app passes to the web view unread.
    ZIGGY_NATIVE_DELIVER = 0,
    // A call: a JSON object whose "type" names what the native app is to do. The calls are
    //   {"type":"quit"}                                         quit the application
    //   {"type":"menu-action","action":"reload"}                do a menu action as if its menu item had been chosen, by the path the menu
    //                                                           item takes in the native app, so the native app's own actions (reload, zoom,
    //                                                           developer tools, full screen, the editing commands, quit) really happen and
    //                                                           any other action reaches the frontend
    //   {"type":"keep-alive","keepRunning":true}                keep the app running because tasks marked keep-alive are queued or running
    //                                                           (true when the first is queued, false when the last ends)
    //   {"type":"os-version"}                                   the result is the operating system's version, as the JSON text of a string
    //   {"type":"pick-paths","kind":0,"title":"...","initialName":"..."}
    //                                                           show a native file or folder dialog of a ZIGGY_PICK_ kind; the result is the
    //                                                           JSON text of an array of the paths chosen, "[]" when the user cancelled.
    //                                                           The title and the initial name may be missing. The initial name is the
    //                                                           suggested file name of a save, and the folder the others start in.
    //   {"type":"native-call","method":"...","request":"..."}   the app's own native call: do one thing only the platform can do, named by method ("exportFile",
    //                                                           "secureStoreGet", ...), with the JSON text of its argument; the result is
    //                                                           the JSON text the method gives, and a failure's reason is in words the user
    //                                                           can act on
    //   {"type":"screenshot","outputPath":"..."}                write a PNG of the app's window to the file; the result is empty
    // A call that has a result also carries "callId", which the native app ignores.
    ZIGGY_NATIVE_CALL = 1
};

// Takes the next message the core sent the native app, on the native app's UI thread, or returns NULL when there is none. Each
// wake is handled by taking messages until there are none. The text is valid until the next call or ziggy_destroy, and its length
// is written to the pointer given. Its kind, a ZIGGY_NATIVE_ value, is written to kind, and the number to send its result with to reply:
// 0 for a message that has no result. The native app may take its time over a call, showing native interface and waiting for the
// user, as long as it does not hold up its UI thread.
const char *ziggy_take_native_message(void *handle, size_t *length, int32_t *kind, uint64_t *reply);

// Gives the core the result of the call taken under the number reply, on the native app's UI thread: ok and the result's text when the native app did what
// the call names, or not ok and the text of the reason when it could not. Each call that has a result gets it once.
void ziggy_native_result(void *handle, uint64_t reply, bool ok, const char *text, size_t text_len);


// The result of ziggy_check_url.
enum {
    // The address is the app's own frontend.
    ZIGGY_URL_ALLOW = 0,
    // The address is an external link, to open in the system browser.
    ZIGGY_URL_OPEN_EXTERNALLY = 1,
    // The address must not be loaded.
    ZIGGY_URL_BLOCK = 2
};

// Creates a core and returns the pointer every other function takes, the core's main thread's queue, or NULL on failure (the reason is
// printed to standard error). A process runs one core at a time: a second call before ziggy_destroy fails.
void *ziggy_create(const ziggy_config *config);

// Stops the core's main thread and waits for it: the main thread cancels every running task, waits for the workers and the test
// control connection to stop and releases everything. Every call the native app has taken and not given a result, and every call made while
// the core stops, gets the reason "ShuttingDown" as its result, so a native app closes any open file dialog with no result, and
// gives no result after this. No task runs and nothing is delivered after it returns.
void ziggy_destroy(void *handle);

// Passes a JSON message from the frontend, sent with the frontend's send or invoke, to the core's main thread and returns at once.
// The message is valid only while the call runs. Each native app calls it in the order the messages arrived, and the message's
// handler runs later, on the core's main thread, in that order.
void ziggy_send_message(void *handle, const char *message, size_t message_len);

// Decides what to do with an address the web view is about to load: a ZIGGY_URL_ value.
int32_t ziggy_check_url(void *handle, const char *url, size_t url_len);

// The modifier bits of a parsed keyboard shortcut.
enum {
    ZIGGY_MOD_CTRL = 1,
    ZIGGY_MOD_SHIFT = 2,
    ZIGGY_MOD_ALT = 4,
    // Command on MacOS, and the Windows or Super key elsewhere.
    ZIGGY_MOD_META = 8
};

// A keyboard shortcut, parsed.
typedef struct ziggy_accelerator {
    // Which modifier keys are held, as a mix of the ZIGGY_MOD_ bits.
    uint32_t modifiers;
    // The key's name, NUL terminated: a lower case letter or digit, a function key name such as "f12", or a name such as
    // "plus", "minus", "equal", "space", "enter", "tab", "escape", "up", "down", "left", "right", "home", "end", "pageup",
    // "pagedown", "delete" or "backspace".
    char key[16];
} ziggy_accelerator;

// Returns the desktop menu as JSON text, valid until ziggy_destroy: an array of menus, each {"label", "items"}, where an item
// is {"label", "action", "accelerator"} or {"separator": true} and may hold its own "items" for a submenu. Desktop native apps
// show it, and a phone's native app never calls this. The length is written to the pointer given.
const char *ziggy_menu_json(void *handle, size_t *length);

// A file of the app's bundled frontend, as ziggy_ui_file gives it.
typedef struct ziggy_ui_file_result {
    // The file's bytes, valid for as long as the library is loaded.
    const uint8_t *content;
    // The number of bytes.
    size_t content_length;
    // The file's content type, such as "text/html; charset=utf-8" (NUL terminated), valid for as long as the library is loaded.
    const char *content_type;
} ziggy_ui_file_result;

// Finds a file of the app's bundled frontend by the path of a request, which starts with a slash ("/" is the frontend
// itself), and writes it into the struct given. Returns false, leaving the struct unchanged, when the frontend has no such
// file. Used by the native apps to serve the frontend, by calling it for each file.
bool ziggy_ui_file(void *handle, const char *path, size_t path_len, ziggy_ui_file_result *result);

// The script a native app injects into the frontend before the frontend's own scripts, which exposes window.ziggy (NUL
// terminated, valid for as long as the library is loaded). It is embedded in the library, so an app supplies nothing. The
// length, not counting the terminator, is written to the pointer given.
const char *ziggy_inject_script(size_t *length);

// Reads keyboard shortcut text such as "CmdOrCtrl+Shift+I" into the struct given. CmdOrCtrl becomes Command on MacOS and
// Control elsewhere. Returns false, leaving the struct unchanged, when the text is not a shortcut.
bool ziggy_parse_accelerator(const char *text, size_t text_len, ziggy_accelerator *result);

// Records the files the user dropped on the window, replacing the last drop, so the frontend can get each one's path with
// getPathForFile. The native app calls it when the drop happens, before the frontend's own drop event. The paths are the JSON text of an array
// of strings, checked on the calling thread: it returns false, after logging why, when a path is not a readable file or the text is
// not such an array. The core's main thread records the drop, and reads it before any message sent after this returns.
bool ziggy_files_dropped(void *handle, const char *paths_json, size_t paths_len);

// Returns the query of the frontend's address, which the app supplies on the core's main thread, as the text after the question mark
// (NUL terminated, empty when the app has none), valid until the next call or ziggy_destroy. The native app appends a question mark and this text to the
// frontend's address and passes it through unread. The length, not counting the terminator, is written to the pointer given. Returns
// NULL, after printing why, when the app could not make it, and the native app then does not load the frontend.
const char *ziggy_ui_query(void *handle, size_t *length);

// Returns true when the library was built with the test hooks.
bool ziggy_test_hooks_enabled(void);

#ifdef __cplusplus
}
#endif

#endif
