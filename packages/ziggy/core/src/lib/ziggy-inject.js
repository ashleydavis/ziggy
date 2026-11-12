// The script every native app injects into the frontend before its own scripts run. It exposes window.ziggy and nothing
// else that a frontend should use, and it finds the web view's own native handle so the frontend never has to:
// WebKitGTK and WKWebView post through window.webkit.messageHandlers.ziggy, WebView2 through window.chrome.webview,
// and the Android WebView through the interface object named ZiggyAndroid.
//
// There are two kinds of message, kept apart from end to end. An app message belongs to the app: the frontend sends it with invoke
// or send, the core hands it to the app's handler for its name and the app sends app events back. A system message belongs to Ziggy
// itself (tasks, the platform, menu actions, the app's actions, dropped files, core errors and remote control): only this script and
// the native app send one, the core handles it without the app ever seeing it, and window.ziggy has no call that sends an arbitrary
// one.
//
// Every message posted to the core is the JSON text of an object whose "kind" names which it is:
//   { "kind": "app", "id", "name", "data" }      an app message that gets a message response (invoke)
//   { "kind": "app", "name", "data" }            an app message that does not (send)
//   { "kind": "system", "id", "name", "data" }   a system message that gets a message response
//   { "kind": "system", "name", "data" }         a system message that does not
// The core refuses a message with no "kind", or any other value, as InvalidMessage, reported as a core-error system event.
//
// The native app delivers a message from the core by calling window.__ziggyReceive with the message as an object:
//   { "id", "ok": true, "data" } or { "id", "ok": false, "error" }   a message response, of either kind, matched by id
//   { "kind": "app", "data" }                                        an app event, for the onEvent listeners (a menu item the
//                                                                    frontend runs is one: { "type": "menu", "item" })
//   { "kind": "system", "name", "data" }                             a system event, for Ziggy's listeners for that name
//                                                                    (the action event, { "action" }, runs the handler registerAction
//                                                                    registered for the action instead)
(function () {
    if (window.ziggy) {
        return;
    }

    var nativePost = findNativePost();
    var nextId = 1;
    var pending = new Map();
    var eventListeners = [];
    var systemListeners = new Map();

    function findNativePost() {
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ziggy) {
            return function (text) {
                window.webkit.messageHandlers.ziggy.postMessage(text);
            };
        }
        if (window.chrome && window.chrome.webview) {
            return function (text) {
                window.chrome.webview.postMessage(text);
            };
        }
        if (window.ZiggyAndroid) {
            return function (text) {
                window.ZiggyAndroid.postMessage(text);
            };
        }
        throw new Error("Ziggy: this web view has no native message handler to post to.");
    }

    // Posts a message of either kind that gets a message response, and resolves with the response's data or rejects with its
    // error.
    function postWithResponse(kind, name, data) {
        return new Promise(function (resolve, reject) {
            var id = nextId++;
            pending.set(id, { resolve: resolve, reject: reject });
            try {
                nativePost(JSON.stringify({ kind: kind, id: id, name: name, data: data }));
            }
            catch (error) {
                pending.delete(id);
                reject(error);
            }
        });
    }

    // The app part: app messages and app events, which is all the app reaches through invoke, send and onEvent.

    // The core refuses an app message with no name, or an empty one, with MissingMessageName: invoke rejects with it, and for
    // send it is a core-error event.
    function invoke(name, data) {
        return postWithResponse("app", name, data);
    }

    function send(name, data) {
        nativePost(JSON.stringify({ kind: "app", name: name, data: data }));
    }

    function onEvent(callback) {
        eventListeners.push(callback);
    }

    function removeEventListener(callback) {
        eventListeners = eventListeners.filter(function (listener) {
            return listener !== callback;
        });
    }

    function receiveAppEvent(message) {
        eventListeners.slice().forEach(function (callback) {
            callback(message.data);
        });
    }

    // The system part: Ziggy's own messages and events. None of these functions is on window.ziggy, so the app cannot send a
    // system message of its choosing: it reaches them only through the fixed calls below, each of which names its own message.

    function invokeSystem(name, data) {
        return postWithResponse("system", name, data);
    }

    function postSystem(name, data) {
        nativePost(JSON.stringify({ kind: "system", name: name, data: data }));
    }

    function addSystemListener(name, callback) {
        var callbacks = systemListeners.get(name);
        if (!callbacks) {
            callbacks = [];
            systemListeners.set(name, callbacks);
        }
        callbacks.push(callback);
    }

    function removeSystemListener(name, callback) {
        var callbacks = systemListeners.get(name);
        if (!callbacks) {
            return;
        }
        systemListeners.set(name, callbacks.filter(function (listener) {
            return listener !== callback;
        }));
    }

    // The frontend's handler of each of the app's actions, by the action's name. The core runs an action by sending the action system
    // event naming it, whatever ran it: a menu item, a shortcut, runAction or the backend.
    var actionHandlers = new Map();

    // Writes an error a handler of an action threw or rejected with to the backend's log, as an exception naming the action, with the
    // error's name, message and stack trace, so it is never lost.
    function logActionError(name, error) {
        var errorText = String(error);
        if (error instanceof Error && error.stack) {
            errorText = errorText + "\n" + error.stack;
        }
        postSystem("log", {
            level: "exception",
            message: "The handler of the action " + name + " failed.",
            error: errorText,
            toolData: null,
        });
    }

    // Runs the handler registered for an action. An error the handler throws, or a promise it returns rejecting, is logged and goes
    // no further, so one failing handler does not stop the next event being handled. An action with no handler is logged as an
    // error and throws, because the frontend declared no way to run it.
    function runActionHandler(name) {
        var handler = actionHandlers.get(name);
        if (!handler) {
            postSystem("log", {
                level: "error",
                message: "The action " + name + " ran, and the frontend has no handler registered for it.",
                error: null,
                toolData: null,
            });
            throw new Error("Ziggy: the action " + name + " ran, and the frontend has no handler registered for it.");
        }
        var result;
        try {
            result = handler();
        }
        catch (error) {
            logActionError(name, error);
            return;
        }
        if (result && typeof result.then === "function") {
            result.then(undefined, function (error) {
                logActionError(name, error);
            });
        }
    }

    function receiveSystemEvent(message) {
        if (message.name === "action") {
            runActionHandler(message.data.action);
            return;
        }
        var callbacks = systemListeners.get(message.name) || [];
        if (callbacks.length === 0 && message.name === "core-error") {
            console.error("Ziggy core error:", message.data && message.data.error);
        }
        callbacks.slice().forEach(function (callback) {
            callback(message.data);
        });
    }

    // Makes the pair of functions that add and remove a listener for one system event.
    function systemEvent(name) {
        return {
            on: function (callback) {
                addSystemListener(name, callback);
            },
            remove: function (callback) {
                removeSystemListener(name, callback);
            },
        };
    }

    var taskEvent = systemEvent("task-event");
    var taskCompleted = systemEvent("task-completed");
    var coreError = systemEvent("core-error");
    var testCommand = systemEvent("test-command");

    // Dropped files. A web view does not give the frontend the real paths of the files dropped on it: WebKitGTK lists file addresses
    // as a type of the drop and gives no way to read them, and no File objects, and the others give Files that have no path readable by
    // the frontend. The native app reads the paths natively and records them with the core. This catches every drop of files before the
    // frontend does, sends the core a get-dropped-paths message for the paths of the last drop, and fires the drop again holding one File per path, which it makes itself and
    // remembers the path of. getPathForFile then returns the path from that memory, as Electron's does, so a frontend written for
    // Electron runs unchanged. The Files are empty: a frontend that wants a dropped file's contents reads the path. WebView2 hands the native app the Files
    // themselves, so there the native app reads their paths first. A drop of something else, such as a link, is left alone.
    var redispatchedDrops = new WeakSet();
    var pathsOfDroppedFiles = new WeakMap();

    function getPathForFile(file) {
        return pathsOfDroppedFiles.get(file);
    }

    function isDropOfFiles(transfer) {
        var types = Array.prototype.slice.call(transfer.types);
        if (transfer.files.length > 0 || types.indexOf("Files") >= 0) {
            return true;
        }
        // A file's address is listed but cannot be read. A link's address can be, and is not a file.
        return types.indexOf("text/uri-list") >= 0 && transfer.getData("text/uri-list").indexOf("http") !== 0;
    }

    function onDrop(event) {
        if (redispatchedDrops.has(event) || !event.dataTransfer || !isDropOfFiles(event.dataTransfer)) {
            return;
        }
        var files = Array.prototype.slice.call(event.dataTransfer.files);
        event.preventDefault();
        event.stopImmediatePropagation();
        var target = event.target;
        if (files.length > 0 && window.chrome && window.chrome.webview && window.chrome.webview.postMessageWithAdditionalObjects) {
            try {
                window.chrome.webview.postMessageWithAdditionalObjects("ziggy-file", files);
            }
            catch (error) {
                // WebView2 takes only Files that came from a drop. The get-dropped-paths message is still sent, and the core's message response holds the last drop it was told of.
                console.warn("Ziggy: WebView2 would not hand the shell these files, so their paths are not known from the files themselves.", error);
            }
        }
        invokeSystem("get-dropped-paths", null).then(function (paths) {
            var transfer = new window.DataTransfer();
            paths.forEach(function (path) {
                var file = new window.File([], path.split(/[\\/]/).pop());
                pathsOfDroppedFiles.set(file, path);
                transfer.items.add(file);
            });
            var again = new window.DragEvent("drop", {
                bubbles: true,
                cancelable: true,
                composed: true,
                clientX: event.clientX,
                clientY: event.clientY,
                dataTransfer: transfer,
            });
            redispatchedDrops.add(again);
            target.dispatchEvent(again);
        });
    }

    window.addEventListener("drop", onDrop, true);


    function receive(message) {
        if (message.id !== undefined && message.ok !== undefined) {
            var request = pending.get(message.id);
            if (!request) {
                console.error("Ziggy: a reply arrived for a request nobody is waiting for", message);
                return;
            }
            pending.delete(message.id);
            if (message.ok) {
                request.resolve(message.data);
            }
            else {
                request.reject(new Error(message.error));
            }
            return;
        }
        if (message.kind === "app") {
            receiveAppEvent(message);
            return;
        }
        if (message.kind === "system") {
            receiveSystemEvent(message);
            return;
        }
        console.error("Ziggy: an event arrived with no kind, or one that is neither app nor system", message);
    }

    Object.defineProperty(window, "ziggy", {
        value: Object.freeze({
            invoke: invoke,
            send: send,
            onEvent: onEvent,
            removeEventListener: removeEventListener,
            getPlatform: function () {
                return invokeSystem("get-platform", null);
            },
            // The value at a dotted key path of the app's config file, or undefined when it is absent.
            getConfig: function (path) {
                return invokeSystem("get-config", path).then(function (value) {
                    return value === null ? undefined : value;
                });
            },
            // Writes a value at a dotted key path of the app's config file. undefined removes the key.
            setConfig: function (path, value) {
                return invokeSystem("set-config", {
                    path: path,
                    value: value === undefined ? null : value,
                });
            },
            // The value at a dotted key path of the app's state file, or undefined when it is absent.
            getState: function (path) {
                return invokeSystem("get-state", path).then(function (value) {
                    return value === null ? undefined : value;
                });
            },
            // Writes a value at a dotted key path of the app's state file. undefined removes the key.
            setState: function (path, value) {
                return invokeSystem("set-state", {
                    path: path,
                    value: value === undefined ? null : value,
                });
            },
            // The problem with a line of the app's config file, or undefined when it reads or is missing.
            getConfigProblem: function () {
                return invokeSystem("get-config-problem", null).then(function (problem) {
                    return problem === null ? undefined : problem;
                });
            },
            addTask: function (task) {
                postSystem("add-task", task);
            },
            cancelTasks: function (source) {
                postSystem("cancel-tasks", source);
            },
            // Writes a line to the backend's log, tagged Frontend. A level the core does not know is a core-error event.
            log: function (level, message, errorText, toolOutput) {
                postSystem("log", {
                    level: level,
                    message: message,
                    error: errorText === undefined ? null : errorText,
                    toolData: toolOutput === undefined ? null : toolOutput,
                });
            },
            onTaskEvent: taskEvent.on,
            removeTaskEventListener: taskEvent.remove,
            onTaskCompleted: taskCompleted.on,
            removeTaskCompletedListener: taskCompleted.remove,
            onCoreError: coreError.on,
            removeCoreErrorListener: coreError.remove,
            onTestCommand: testCommand.on,
            removeTestCommandListener: testCommand.remove,
            sendTestResult: function (requestId, result) {
                return invokeSystem("test-result", {
                    requestId: requestId,
                    result: result,
                });
            },
            testUiReady: function () {
                postSystem("test-ui-ready", null);
            },
            getPathForFile: getPathForFile,
            // Registers the frontend's handler of one of the app's actions. A name that already has a handler throws.
            registerAction: function (name, handler) {
                if (actionHandlers.has(name)) {
                    throw new Error("Ziggy: the action " + name + " already has a handler registered.");
                }
                actionHandlers.set(name, handler);
            },
            // Removes the handler of an action, so it can be registered again.
            removeAction: function (name) {
                actionHandlers.delete(name);
            },
            // Runs one of the app's actions, or a standard action of the app's menu, by its name.
            runAction: function (name) {
                return invokeSystem("run-action", {
                    action: name,
                });
            },
            // Resolves with every action of the app and every standard item of its menu, with its label and its shortcut.
            listActions: function () {
                return invokeSystem("list-actions", null);
            },
        }),
    });
    Object.defineProperty(window, "__ziggyReceive", { value: receive });
})();
