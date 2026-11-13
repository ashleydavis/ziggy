import fs from "fs";
import path from "path";

//
// A listener the script registers: a listener for a drop or for a key press.
//
type IEventListener = (event: IFakeDropEvent | IFakeKeyEvent) => void;

//
// A fake of the frontend's window, with the native handle of the platform under test.
//
interface IFakeWindow {
    webkit?: { messageHandlers: { ziggy: { postMessage: (text: string) => void } } };
    chrome?: { webview: { postMessage: (text: string) => void; postMessageWithAdditionalObjects?: (text: string, objects: object[]) => void } };
    ZiggyAndroid?: { postMessage: (text: string) => void };
    ziggy?: {
        invoke: (name: string, data: object | null) => Promise<object>;
        send: (name: string, data: object | null) => void;
        onEvent: (callback: (data: object) => void) => void;
        removeEventListener: (callback: (data: object) => void) => void;
        getPlatform: () => Promise<object>;
        addTask: (task: object) => void;
        cancelTasks: (source: string) => void;
        log: (level: string, message: string, errorText?: string, toolOutput?: object) => void;
        sendTestResult: (requestId: number, result: object | null) => Promise<object>;
        testUiReady: () => void;
        getPathForFile: (file: object) => string | undefined;
        registerAction: (name: string, handler: () => void | Promise<void>) => void;
        removeAction: (name: string) => void;
        runAction: (name: string) => Promise<object>;
        listActions: () => Promise<object>;
        [listenerCall: string]: any;
    };
    __ziggyReceive?: (message: object) => void;
    addEventListener?: (type: string, listener: IEventListener, capture: boolean) => void;
    DataTransfer?: new () => IFakeDataTransfer;
    DragEvent?: new (type: string, init: object) => IFakeDropEvent;
    File?: new (parts: unknown[], name: string) => { name: string; size: number };
}

const script = fs.readFileSync(path.join(__dirname, "../../../core/src/lib/ziggy-inject.js"), "utf8");

function inject(fakeWindow: IFakeWindow): void {
    fakeWindow.addEventListener = fakeWindow.addEventListener ?? (() => undefined);
    new Function("window", script)(fakeWindow);
}

function windowWithWebkit(posted: string[]): IFakeWindow {
    return {
        webkit: {
            messageHandlers: {
                ziggy: {
                    postMessage: (text: string) => posted.push(text),
                },
            },
        },
    };
}

//
// A fake drop event as the inject script sees one.
//
interface IFakeDropEvent {
    type: string;
    dataTransfer: IFakeDataTransfer | null;
    target: IFakeTarget;
    clientX: number;
    clientY: number;
    prevented: boolean;
    stopped: boolean;
    preventDefault: () => void;
    stopImmediatePropagation: () => void;
}

//
// A fake of a drop's data.
//
interface IFakeDataTransfer {
    types: string[];
    files: { name: string; size: number }[];
    items: { add: (file: { name: string; size: number }) => void };
    data: Record<string, string>;
    getData: (type: string) => string;
    setData: (type: string, value: string) => void;
}

//
// A fake of the element a drop landed on, which records the events dispatched on it.
//
interface IFakeTarget {
    dispatched: IFakeDropEvent[];
    dispatchEvent: (event: IFakeDropEvent) => void;
}

function fakeTransfer(files: { name: string; size: number }[], data: Record<string, string>, types: string[]): IFakeDataTransfer {
    const transfer: IFakeDataTransfer = {
        types,
        files: [...files],
        data: { ...data },
        items: {
            add: file => {
                transfer.files.push(file);
            },
        },
        getData: type => transfer.data[type] ?? "",
        setData: (type, value) => {
            transfer.data[type] = value;
        },
    };
    return transfer;
}

//
// A window that records the drop listener the script registers and can make the events the script creates.
//
function windowForDrops(posted: string[]): IFakeWindow & { dropListeners: ((event: IFakeDropEvent) => void)[] } {
    const dropListeners: ((event: IFakeDropEvent) => void)[] = [];
    const fakeWindow = windowWithWebkit(posted) as IFakeWindow & { dropListeners: ((event: IFakeDropEvent) => void)[] };
    fakeWindow.dropListeners = dropListeners;
    fakeWindow.addEventListener = (type, listener, capture) => {
        if (type === "drop" && capture) {
            dropListeners.push(listener as (event: IFakeDropEvent) => void);
        }
    };
    fakeWindow.File = function (this: { name: string; size: number }, parts: unknown[], name: string) {
        return { name, size: parts.length };
    } as unknown as new (parts: unknown[], name: string) => { name: string; size: number };
    fakeWindow.DataTransfer = function () {
        return fakeTransfer([], {}, []);
    } as unknown as new () => IFakeDataTransfer;
    fakeWindow.DragEvent = function (this: IFakeDropEvent, type: string, init: { dataTransfer: IFakeDataTransfer; clientX: number; clientY: number }) {
        return makeEvent(type, init.dataTransfer, { dispatched: [], dispatchEvent: () => undefined }, init.clientX, init.clientY);
    } as unknown as new (type: string, init: object) => IFakeDropEvent;
    return fakeWindow;
}

//
// A fake key press as the inject script sees one, carrying the element the press started at and the path it composes.
//
interface IFakeKeyEvent {
    key: string;
    code: string;
    ctrlKey: boolean;
    altKey: boolean;
    shiftKey: boolean;
    metaKey: boolean;
    repeat: boolean;
    isComposing: boolean;
    defaultPrevented: boolean;
    target: object;
    composedPath: () => object[];
    prevented: boolean;
    preventDefault: () => void;
}

//
// A window that records the keydown listener the script registers in the bubbling phase.
//
function windowForKeys(posted: string[]): IFakeWindow & { keyListeners: IEventListener[] } {
    const keyListeners: IEventListener[] = [];
    const fakeWindow = windowWithWebkit(posted) as IFakeWindow & { keyListeners: IEventListener[] };
    fakeWindow.keyListeners = keyListeners;
    fakeWindow.addEventListener = (type, listener, capture) => {
        if (type === "keydown" && !capture) {
            keyListeners.push(listener);
        }
    };
    return fakeWindow;
}

//
// A key press whose path starts at the element given.
//
function makeKeyEvent(path: object[], options: Partial<IFakeKeyEvent>): IFakeKeyEvent {
    const event: IFakeKeyEvent = {
        key: options.key ?? "",
        code: options.code ?? "",
        ctrlKey: options.ctrlKey ?? false,
        altKey: options.altKey ?? false,
        shiftKey: options.shiftKey ?? false,
        metaKey: options.metaKey ?? false,
        repeat: options.repeat ?? false,
        isComposing: options.isComposing ?? false,
        defaultPrevented: options.defaultPrevented ?? false,
        target: path[0],
        composedPath: () => path,
        prevented: false,
        preventDefault: () => {
            event.prevented = true;
        },
    };
    return event;
}

//
// Injects the script, gives the shortcut request its reply and lets the reply's handler run.
//
async function injectWithShortcuts(posted: string[], shortcuts: object[]): Promise<IFakeWindow & { keyListeners: IEventListener[] }> {
    const fakeWindow = windowForKeys(posted);
    inject(fakeWindow);
    fakeWindow.__ziggyReceive!({ id: 1, ok: true, data: shortcuts });
    await new Promise(resolve => setTimeout(resolve, 0));
    return fakeWindow;
}

//
// The element a key press lands on: the page's body, a text box of some kind, or a button, link or checkbox.
//
const body = { tagName: "BODY" };

function elementOf(tagName: string, type?: string): object {
    return { tagName, type: type ?? "" };
}

//
// The shortcuts the tests reply with.
//
const escapeShortcut = { action: "escape-action", standard: false, text_box: true, code: "Escape", ctrl: false, alt: false, shift: false, meta: false, shiftOptional: false, key: "" };
const plusShortcut = { action: "zoom-in", standard: false, text_box: true, code: "", ctrl: false, alt: false, shift: false, meta: false, shiftOptional: true, key: "+" };
const jShortcut = { action: "j-action", standard: false, text_box: true, code: "", ctrl: false, alt: false, shift: false, meta: false, shiftOptional: false, key: "j" };
const shiftJShortcut = { action: "shift-j-action", standard: false, text_box: true, code: "", ctrl: false, alt: false, shift: true, meta: false, shiftOptional: false, key: "j" };
const fiveShortcut = { action: "five-action", standard: false, text_box: true, code: "", ctrl: false, alt: false, shift: false, meta: false, shiftOptional: true, key: "5" };
const askShortcut = { action: "ask", standard: false, text_box: true, code: "", ctrl: false, alt: false, shift: false, meta: false, shiftOptional: true, key: "?" };
const standardShortcut = { action: "zoom-in", standard: true, text_box: false, code: "", ctrl: true, alt: false, shift: false, meta: false, shiftOptional: false, key: "+" };
const controlShortcut = { action: "open", standard: false, text_box: false, code: "", ctrl: true, alt: false, shift: false, meta: false, shiftOptional: false, key: "o" };

function makeEvent(type: string, dataTransfer: IFakeDataTransfer | null, target: IFakeTarget, clientX: number, clientY: number): IFakeDropEvent {
    const event: IFakeDropEvent = {
        type,
        dataTransfer,
        target,
        clientX,
        clientY,
        prevented: false,
        stopped: false,
        preventDefault: () => {
            event.prevented = true;
        },
        stopImmediatePropagation: () => {
            event.stopped = true;
        },
    };
    return event;
}

describe("ziggy-inject", () => {
    test("invoke posts a request with an id and the name and resolves with the reply's data", async () => {
        const posted: string[] = [];
        const fakeWindow = windowWithWebkit(posted);
        inject(fakeWindow);
        const reply = fakeWindow.ziggy!.invoke("ping", { a: 1 });
        expect(JSON.parse(posted[1])).toEqual({ kind: "app", id: 2, name: "ping", data: { a: 1 } });
        fakeWindow.__ziggyReceive!({ id: 2, ok: true, data: { answer: 42 } });
        expect(await reply).toEqual({ answer: 42 });
    });

    test("invoke rejects with the core's error", async () => {
        const posted: string[] = [];
        const fakeWindow = windowWithWebkit(posted);
        inject(fakeWindow);
        const reply = fakeWindow.ziggy!.invoke("fail", null);
        fakeWindow.__ziggyReceive!({ id: 2, ok: false, error: "ExampleFailure" });
        await expect(reply).rejects.toThrow("ExampleFailure");
    });

    test("replies are matched to requests by id, in any order", async () => {
        const posted: string[] = [];
        const fakeWindow = windowWithWebkit(posted);
        inject(fakeWindow);
        const first = fakeWindow.ziggy!.invoke("a", null);
        const second = fakeWindow.ziggy!.invoke("b", null);
        fakeWindow.__ziggyReceive!({ id: 3, ok: true, data: "second" });
        fakeWindow.__ziggyReceive!({ id: 2, ok: true, data: "first" });
        expect(await first).toBe("first");
        expect(await second).toBe("second");
    });

    test("a drop whose file addresses cannot be read asks the core for the paths and is fired again carrying them", async () => {
        const posted: string[] = [];
        const fakeWindow = windowForDrops(posted);
        inject(fakeWindow);
        const target: IFakeTarget = { dispatched: [], dispatchEvent: event => { target.dispatched.push(event); } };
        const drop = makeEvent("drop", fakeTransfer([], { "text/uri-list": "" }, ["text/uri-list", "text/html"]), target, 5, 6);
        fakeWindow.dropListeners[0](drop);
        expect(drop.prevented).toBe(true);
        expect(drop.stopped).toBe(true);
        expect(JSON.parse(posted[1])).toEqual({ kind: "system", id: 2, name: "get-dropped-paths", data: null });
        fakeWindow.__ziggyReceive!({ id: 2, ok: true, data: ["/home/me/two words.txt", "/home/me/a folder"] });
        await new Promise(resolve => setTimeout(resolve, 0));
        expect(target.dispatched.length).toBe(1);
        const made = target.dispatched[0].dataTransfer!.files;
        expect(made.map(file => file.name)).toEqual(["two words.txt", "a folder"]);
        expect(made.map(file => fakeWindow.ziggy!.getPathForFile(file))).toEqual(["/home/me/two words.txt", "/home/me/a folder"]);
        expect(target.dispatched[0].clientX).toBe(5);
        // The event the script fired is not caught by the script again.
        fakeWindow.dropListeners[0](target.dispatched[0]);
        expect(target.dispatched[0].prevented).toBe(false);
    });

    test("a drop of Files is fired again with Files that give the real paths", async () => {
        const posted: string[] = [];
        const fakeWindow = windowForDrops(posted);
        inject(fakeWindow);
        const target: IFakeTarget = { dispatched: [], dispatchEvent: event => { target.dispatched.push(event); } };
        const files = [{ name: "a.txt", size: 3 }, { name: "b.txt", size: 4 }];
        fakeWindow.dropListeners[0](makeEvent("drop", fakeTransfer(files, {}, ["Files"]), target, 0, 0));
        fakeWindow.__ziggyReceive!({ id: 2, ok: true, data: ["/home/me/a.txt", "/home/me/b.txt"] });
        await new Promise(resolve => setTimeout(resolve, 0));
        const made = target.dispatched[0].dataTransfer!.files;
        expect(made.map(file => file.name)).toEqual(["a.txt", "b.txt"]);
        expect(made.map(file => fakeWindow.ziggy!.getPathForFile(file))).toEqual(["/home/me/a.txt", "/home/me/b.txt"]);
        expect(fakeWindow.ziggy!.getPathForFile({ name: "a.txt", size: 3 })).toBeUndefined();
    });

    test("WebView2 is handed the Files themselves before the core is asked for the paths", () => {
        const posted: string[] = [];
        const withObjects: { text: string; objects: object[] }[] = [];
        const fakeWindow = windowForDrops(posted);
        fakeWindow.chrome = {
            webview: {
                postMessage: text => posted.push(text),
                postMessageWithAdditionalObjects: (text, objects) => withObjects.push({ text, objects }),
            },
        };
        fakeWindow.webkit = undefined;
        inject(fakeWindow);
        const files = [{ name: "a.txt", size: 3 }];
        const target: IFakeTarget = { dispatched: [], dispatchEvent: () => undefined };
        fakeWindow.dropListeners[0](makeEvent("drop", fakeTransfer(files, {}, ["Files"]), target, 0, 0));
        expect(withObjects).toEqual([{ text: "ziggy-file", objects: files }]);
        expect(JSON.parse(posted[1])).toEqual({ kind: "system", id: 2, name: "get-dropped-paths", data: null });
    });

    test("a drop of a link or of text is left alone", () => {
        const fakeWindow = windowForDrops([]);
        inject(fakeWindow);
        const target: IFakeTarget = { dispatched: [], dispatchEvent: event => { target.dispatched.push(event); } };
        const link = makeEvent("drop", fakeTransfer([], { "text/uri-list": "https://example.com/a" }, ["text/uri-list"]), target, 0, 0);
        const text = makeEvent("drop", fakeTransfer([], { "text/plain": "hello" }, ["text/plain"]), target, 0, 0);
        fakeWindow.dropListeners[0](link);
        fakeWindow.dropListeners[0](text);
        expect(link.prevented || link.stopped || text.prevented || text.stopped).toBe(false);
        expect(target.dispatched.length).toBe(0);
    });

    test("send posts a message with no id", () => {
        const posted: string[] = [];
        const fakeWindow = windowWithWebkit(posted);
        inject(fakeWindow);
        fakeWindow.ziggy!.send("notify", { source: "s" });
        expect(JSON.parse(posted[1])).toEqual({ kind: "app", name: "notify", data: { source: "s" } });
    });

    test("onEvent gets every app event and none of Ziggy's own", () => {
        const fakeWindow = windowWithWebkit([]);
        inject(fakeWindow);
        const received: object[] = [];
        fakeWindow.ziggy!.onEvent(data => received.push(data));
        fakeWindow.ziggy!.onEvent(data => received.push(data));
        fakeWindow.__ziggyReceive!({ kind: "app", data: { type: "saved" } });
        fakeWindow.__ziggyReceive!({ kind: "system", name: "task-event", data: { taskId: "t" } });
        fakeWindow.__ziggyReceive!({ kind: "system", name: "core-error", data: { error: "E" } });
        expect(received).toEqual([{ type: "saved" }, { type: "saved" }]);
    });

    test("a menu item that runs in the UI reaches the onEvent listeners as the app event menu; window.ziggy has no menu listener of its own", () => {
        const fakeWindow = windowWithWebkit([]);
        inject(fakeWindow);
        const received: object[] = [];
        fakeWindow.ziggy!.onEvent(data => received.push(data));
        fakeWindow.__ziggyReceive!({ kind: "app", data: { type: "menu", item: "about" } });
        expect(received).toEqual([{ type: "menu", item: "about" }]);
        expect(Object.keys(fakeWindow.ziggy!)).not.toContain("onMenuAction");
        expect(Object.keys(fakeWindow.ziggy!)).not.toContain("removeMenuActionListener");
    });

    test("an app event reaches no system listener, even when it carries a system event's name", () => {
        const fakeWindow = windowWithWebkit([]);
        inject(fakeWindow);
        const system: object[] = [];
        const app: object[] = [];
        fakeWindow.ziggy!.onTaskEvent((data: object) => system.push(data));
        fakeWindow.ziggy!.onCoreError((data: object) => system.push(data));
        fakeWindow.ziggy!.onEvent(data => app.push(data));
        fakeWindow.__ziggyReceive!({ kind: "app", name: "task-event", data: { taskId: "t" } });
        fakeWindow.__ziggyReceive!({ kind: "app", name: "core-error", data: { error: "E" } });
        expect(system).toEqual([]);
        expect(app).toEqual([{ taskId: "t" }, { error: "E" }]);
    });

    test("an event with no kind, or an unknown one, reaches no listener and is logged", () => {
        const fakeWindow = windowWithWebkit([]);
        inject(fakeWindow);
        const received: object[] = [];
        fakeWindow.ziggy!.onEvent(data => received.push(data));
        fakeWindow.ziggy!.onTaskEvent((data: object) => received.push(data));
        const logged = jest.spyOn(console, "error").mockImplementation(() => undefined);
        try {
            fakeWindow.__ziggyReceive!({ data: { a: 1 } });
            fakeWindow.__ziggyReceive!({ kind: "other", name: "task-event", data: { a: 2 } });
            expect(received).toEqual([]);
            expect(logged).toHaveBeenCalledTimes(2);
        }
        finally {
            logged.mockRestore();
        }
    });

    test("removeEventListener stops that callback hearing app events, and leaves the others", () => {
        const fakeWindow = windowWithWebkit([]);
        inject(fakeWindow);
        const removed: object[] = [];
        const kept: object[] = [];
        const removedCallback = (data: object) => removed.push(data);
        fakeWindow.ziggy!.onEvent(removedCallback);
        fakeWindow.ziggy!.onEvent(data => kept.push(data));
        fakeWindow.ziggy!.removeEventListener(removedCallback);
        fakeWindow.__ziggyReceive!({ kind: "app", data: 1 });
        expect(removed).toEqual([]);
        expect(kept).toEqual([1]);
    });

    test("each of Ziggy's own calls posts a system message", async () => {
        const posted: string[] = [];
        const fakeWindow = windowWithWebkit(posted);
        inject(fakeWindow);
        const platform = fakeWindow.ziggy!.getPlatform();
        fakeWindow.ziggy!.addTask({ taskId: "t1", taskType: "quick", source: "s", data: null });
        fakeWindow.ziggy!.cancelTasks("s");
        fakeWindow.ziggy!.log("info", "opened");
        fakeWindow.ziggy!.log("exception", "failed", "Error: at line 4");
        fakeWindow.ziggy!.log("tool", "magick", undefined, { stdout: "done" });
        const result = fakeWindow.ziggy!.sendTestResult(4, { ok: true });
        fakeWindow.ziggy!.testUiReady();
        const ran = fakeWindow.ziggy!.runAction("open-database");
        const listed = fakeWindow.ziggy!.listActions();
        expect(posted.map(text => JSON.parse(text))).toEqual([
            { kind: "system", id: 1, name: "list-shortcuts", data: null },
            { kind: "system", id: 2, name: "get-platform", data: null },
            { kind: "system", name: "add-task", data: { taskId: "t1", taskType: "quick", source: "s", data: null } },
            { kind: "system", name: "cancel-tasks", data: "s" },
            { kind: "system", name: "log", data: { level: "info", message: "opened", error: null, toolData: null } },
            { kind: "system", name: "log", data: { level: "exception", message: "failed", error: "Error: at line 4", toolData: null } },
            { kind: "system", name: "log", data: { level: "tool", message: "magick", error: null, toolData: { stdout: "done" } } },
            { kind: "system", id: 3, name: "test-result", data: { requestId: 4, result: { ok: true } } },
            { kind: "system", name: "test-ui-ready", data: null },
            { kind: "system", id: 4, name: "run-action", data: { action: "open-database" } },
            { kind: "system", id: 5, name: "list-actions", data: null },
        ]);
        fakeWindow.__ziggyReceive!({ id: 1, ok: true, data: [] });
        fakeWindow.__ziggyReceive!({ id: 2, ok: true, data: { platformKind: "desktop" } });
        fakeWindow.__ziggyReceive!({ id: 3, ok: true, data: {} });
        expect(await platform).toEqual({ platformKind: "desktop" });
        expect(await result).toEqual({});
        fakeWindow.__ziggyReceive!({ id: 4, ok: true, data: {} });
        fakeWindow.__ziggyReceive!({ id: 5, ok: true, data: [{ name: "open-database", label: "Open Database...", shortcut: "Ctrl+O" }] });
        expect(await ran).toEqual({});
        expect(await listed).toEqual([{ name: "open-database", label: "Open Database...", shortcut: "Ctrl+O" }]);
    });

    test("the config, state and system theme calls post their system messages, turn null into undefined and send null for undefined", async () => {
        const posted: string[] = [];
        const fakeWindow = windowWithWebkit(posted);
        inject(fakeWindow);
        const config = fakeWindow.ziggy!.getConfig("a.b");
        const setConfig = fakeWindow.ziggy!.setConfig("a.b", 3);
        const removedConfig = fakeWindow.ziggy!.setConfig("a.b", undefined);
        const stateValue = fakeWindow.ziggy!.getState("remembered");
        const setState = fakeWindow.ziggy!.setState("remembered", undefined);
        const problem = fakeWindow.ziggy!.getConfigProblem();
        const systemTheme = fakeWindow.ziggy!.getSystemTheme();
        expect(posted.map(text => JSON.parse(text))).toEqual([
            { kind: "system", id: 1, name: "list-shortcuts", data: null },
            { kind: "system", id: 2, name: "get-config", data: "a.b" },
            { kind: "system", id: 3, name: "set-config", data: { path: "a.b", value: 3 } },
            { kind: "system", id: 4, name: "set-config", data: { path: "a.b", value: null } },
            { kind: "system", id: 5, name: "get-state", data: "remembered" },
            { kind: "system", id: 6, name: "set-state", data: { path: "remembered", value: null } },
            { kind: "system", id: 7, name: "get-config-problem", data: null },
            { kind: "system", id: 8, name: "get-system-theme", data: null },
        ]);
        fakeWindow.__ziggyReceive!({ id: 2, ok: true, data: null });
        fakeWindow.__ziggyReceive!({ id: 3, ok: true, data: null });
        fakeWindow.__ziggyReceive!({ id: 4, ok: true, data: null });
        fakeWindow.__ziggyReceive!({ id: 5, ok: true, data: "yes" });
        fakeWindow.__ziggyReceive!({ id: 6, ok: true, data: null });
        fakeWindow.__ziggyReceive!({ id: 7, ok: true, data: { path: "config.toml", line: 2, column: 1, reason: "bad" } });
        fakeWindow.__ziggyReceive!({ id: 8, ok: true, data: "dark" });
        expect(await config).toBeUndefined();
        await setConfig;
        await removedConfig;
        expect(await stateValue).toEqual("yes");
        await setState;
        expect(await problem).toEqual({ path: "config.toml", line: 2, column: 1, reason: "bad" });
        expect(await systemTheme).toEqual("dark");
    });

    test("an action system event runs the handler registered for the action", () => {
        const fakeWindow = windowWithWebkit([]);
        inject(fakeWindow);
        const ran: string[] = [];
        fakeWindow.ziggy!.registerAction("open-database", () => {
            ran.push("open-database");
        });
        fakeWindow.__ziggyReceive!({ kind: "system", name: "action", data: { action: "open-database" } });
        expect(ran).toEqual(["open-database"]);
    });

    test("an action system event with no handler logs an error naming the action and throws", () => {
        const posted: string[] = [];
        const fakeWindow = windowWithWebkit(posted);
        inject(fakeWindow);
        expect(() => fakeWindow.__ziggyReceive!({ kind: "system", name: "action", data: { action: "missing" } })).toThrow("the action missing ran");
        expect(JSON.parse(posted[1])).toEqual({
            kind: "system",
            name: "log",
            data: {
                level: "error",
                message: "The action missing ran, and the frontend has no handler registered for it.",
                error: null,
                toolData: null,
            },
        });
    });

    test("a handler that throws an Error is logged as an exception naming the action, with the error and its stack, and does not throw", () => {
        const posted: string[] = [];
        const fakeWindow = windowWithWebkit(posted);
        inject(fakeWindow);
        const thrown = new Error("the database is locked");
        fakeWindow.ziggy!.registerAction("open-database", () => {
            throw thrown;
        });
        fakeWindow.__ziggyReceive!({ kind: "system", name: "action", data: { action: "open-database" } });
        expect(JSON.parse(posted[1])).toEqual({
            kind: "system",
            name: "log",
            data: {
                level: "exception",
                message: "The handler of the action open-database failed.",
                error: "Error: the database is locked\n" + thrown.stack,
                toolData: null,
            },
        });
    });

    test("a handler that throws something that is not an Error logs it as text", () => {
        const posted: string[] = [];
        const fakeWindow = windowWithWebkit(posted);
        inject(fakeWindow);
        fakeWindow.ziggy!.registerAction("open-database", () => {
            throw "locked";
        });
        fakeWindow.__ziggyReceive!({ kind: "system", name: "action", data: { action: "open-database" } });
        expect(JSON.parse(posted[1]).data.error).toBe("locked");
    });

    test("a handler whose promise rejects is logged as an exception naming the action", async () => {
        const posted: string[] = [];
        const fakeWindow = windowWithWebkit(posted);
        inject(fakeWindow);
        fakeWindow.ziggy!.registerAction("open-database", () => Promise.reject(new Error("the database is locked")));
        fakeWindow.__ziggyReceive!({ kind: "system", name: "action", data: { action: "open-database" } });
        await new Promise(resolve => setTimeout(resolve, 0));
        const logged = JSON.parse(posted[1]);
        expect(logged.data.level).toBe("exception");
        expect(logged.data.message).toBe("The handler of the action open-database failed.");
        expect(logged.data.error).toContain("Error: the database is locked");
    });

    test("registering a second handler for an action throws, and removeAction stops the handler running", () => {
        const fakeWindow = windowWithWebkit([]);
        inject(fakeWindow);
        const ran: string[] = [];
        fakeWindow.ziggy!.registerAction("open-database", () => {
            ran.push("first");
        });
        expect(() => fakeWindow.ziggy!.registerAction("open-database", () => undefined)).toThrow("already has a handler");
        fakeWindow.ziggy!.removeAction("open-database");
        expect(() => fakeWindow.__ziggyReceive!({ kind: "system", name: "action", data: { action: "open-database" } })).toThrow();
        expect(ran).toEqual([]);
    });

    test("each of Ziggy's own listeners gets only its own event, and its remover removes it", () => {
        const fakeWindow = windowWithWebkit([]);
        inject(fakeWindow);
        const pairs: [string, string, string][] = [
            ["task-event", "onTaskEvent", "removeTaskEventListener"],
            ["task-completed", "onTaskCompleted", "removeTaskCompletedListener"],
            ["core-error", "onCoreError", "removeCoreErrorListener"],
            ["test-command", "onTestCommand", "removeTestCommandListener"],
            ["config-changed", "onConfigChanged", "removeConfigChangedListener"],
        ];
        const received = new Map<string, object[]>();
        const callbacks = new Map<string, (data: object) => void>();
        for (const [name, onCall] of pairs) {
            received.set(name, []);
            const callback = (data: object) => received.get(name)!.push(data);
            callbacks.set(name, callback);
            fakeWindow.ziggy![onCall](callback);
        }
        const app: object[] = [];
        fakeWindow.ziggy!.onEvent(data => app.push(data));
        for (const [name] of pairs) {
            fakeWindow.__ziggyReceive!({ kind: "system", name, data: { from: name } });
        }
        for (const [name] of pairs) {
            expect(received.get(name)).toEqual([{ from: name }]);
        }
        expect(app).toEqual([]);
        for (const [name, , removeCall] of pairs) {
            fakeWindow.ziggy![removeCall](callbacks.get(name));
            fakeWindow.__ziggyReceive!({ kind: "system", name, data: { again: name } });
            expect(received.get(name)).toEqual([{ from: name }]);
        }
    });

    test("a core-error goes to the console only when nothing listens for it", () => {
        const fakeWindow = windowWithWebkit([]);
        inject(fakeWindow);
        const logged = jest.spyOn(console, "error").mockImplementation(() => undefined);
        try {
            fakeWindow.__ziggyReceive!({ kind: "system", name: "core-error", data: { error: "InvalidMessage" } });
            expect(logged).toHaveBeenCalledWith("Ziggy core error:", "InvalidMessage");
            logged.mockClear();
            fakeWindow.ziggy!.onCoreError(() => undefined);
            fakeWindow.__ziggyReceive!({ kind: "system", name: "core-error", data: { error: "InvalidMessage" } });
            expect(logged).not.toHaveBeenCalled();
        }
        finally {
            logged.mockRestore();
        }
    });

    test("it posts through WebView2's handle when that is what the web view has", () => {
        const posted: string[] = [];
        const fakeWindow: IFakeWindow = { chrome: { webview: { postMessage: text => posted.push(text) } } };
        inject(fakeWindow);
        fakeWindow.ziggy!.send("notify", null);
        expect(posted.length).toBe(2);
        expect(JSON.parse(posted[1])).toEqual({ kind: "app", name: "notify", data: null });
    });

    test("it posts through the Android interface object when that is what the web view has", () => {
        const posted: string[] = [];
        const fakeWindow: IFakeWindow = { ZiggyAndroid: { postMessage: text => posted.push(text) } };
        inject(fakeWindow);
        fakeWindow.ziggy!.send("notify", null);
        expect(posted.length).toBe(2);
        expect(JSON.parse(posted[1])).toEqual({ kind: "app", name: "notify", data: null });
    });

    test("it throws, naming the problem, when the web view has no native handle", () => {
        expect(() => inject({})).toThrow("no native message handler");
    });

    // window.ziggy has no call that posts a system message the caller names: these are all there is.
    test("window.ziggy exposes exactly these methods and cannot be replaced", () => {
        const fakeWindow = windowWithWebkit([]);
        inject(fakeWindow);
        expect(Object.keys(fakeWindow.ziggy!).sort()).toEqual([
            "addTask",
            "cancelTasks",
            "getConfig",
            "getConfigProblem",
            "getPathForFile",
            "getPlatform",
            "getState",
            "getSystemTheme",
            "invoke",
            "listActions",
            "log",
            "onConfigChanged",
            "onCoreError",
            "onEvent",
            "onTaskCompleted",
            "onTaskEvent",
            "onTestCommand",
            "registerAction",
            "removeAction",
            "removeConfigChangedListener",
            "removeCoreErrorListener",
            "removeEventListener",
            "removeTaskCompletedListener",
            "removeTaskEventListener",
            "removeTestCommandListener",
            "runAction",
            "send",
            "sendTestResult",
            "setConfig",
            "setState",
            "testUiReady",
        ]);
        expect(() => {
            "use strict";
            (fakeWindow as { ziggy: object }).ziggy = {};
        }).toThrow();
    });

    test("injecting twice keeps the first window.ziggy", () => {
        const fakeWindow = windowWithWebkit([]);
        inject(fakeWindow);
        const first = fakeWindow.ziggy;
        inject(fakeWindow);
        expect(fakeWindow.ziggy).toBe(first);
    });

    test("the script asks for the shortcuts when it runs", () => {
        const posted: string[] = [];
        inject(windowWithWebkit(posted));
        expect(JSON.parse(posted[0])).toEqual({ kind: "system", id: 1, name: "list-shortcuts", data: null });
    });

    test("a shortcut runs outside a text box and keeps the browser from the key", async () => {
        const posted: string[] = [];
        const fakeWindow = await injectWithShortcuts(posted, [escapeShortcut]);
        const event = makeKeyEvent([{ tagName: "BODY" }], { key: "Escape", code: "Escape" });
        fakeWindow.keyListeners[0](event);
        expect(event.prevented).toBe(true);
        expect(JSON.parse(posted[1])).toEqual({ kind: "system", name: "menu-action", data: { action: "escape-action" } });
    });

    test("a standard menu item's shortcut posts run-action", async () => {
        const posted: string[] = [];
        const fakeWindow = await injectWithShortcuts(posted, [standardShortcut]);
        const event = makeKeyEvent([{ tagName: "BODY" }], { key: "+", code: "Equal", ctrlKey: true });
        fakeWindow.keyListeners[0](event);
        expect(event.prevented).toBe(true);
        expect(JSON.parse(posted[1])).toEqual({ kind: "system", name: "run-action", data: { action: "zoom-in" } });
    });

    test("a shortcut with Ctrl runs inside a text box", async () => {
        const posted: string[] = [];
        const fakeWindow = await injectWithShortcuts(posted, [controlShortcut]);
        const event = makeKeyEvent([{ tagName: "TEXTAREA" }], { key: "o", code: "KeyO", ctrlKey: true });
        fakeWindow.keyListeners[0](event);
        expect(event.prevented).toBe(true);
        expect(JSON.parse(posted[1])).toEqual({ kind: "system", name: "menu-action", data: { action: "open" } });
    });

    test("a text box keeps the key of a shortcut with no Ctrl, Alt or Cmd", async () => {
        const textBoxes = [
            { tagName: "TEXTAREA" },
            { tagName: "TEXTAREA", isContentEditable: false },
            { tagName: "INPUT", type: "text" },
            { tagName: "INPUT", type: "number" },
            { tagName: "INPUT", type: "radio" },
            { tagName: "INPUT", type: "range" },
            { tagName: "SELECT" },
            { tagName: "DIV", isContentEditable: true },
        ];
        for (const element of textBoxes) {
            const posted: string[] = [];
            const fakeWindow = await injectWithShortcuts(posted, [escapeShortcut]);
            const event = makeKeyEvent([element], { key: "Escape", code: "Escape" });
            fakeWindow.keyListeners[0](event);
            expect(event.prevented).toBe(false);
            expect(posted.length).toBe(1);
        }
    });

    test("a key press the script did not handle itself runs no shortcut", async () => {
        for (const element of [{ tagName: "INPUT", type: "checkbox" }, { tagName: "BUTTON" }, { tagName: "A" }]) {
            const posted: string[] = [];
            const fakeWindow = await injectWithShortcuts(posted, [escapeShortcut]);
            const event = makeKeyEvent([element], { key: "Escape", code: "Escape" });
            fakeWindow.keyListeners[0](event);
            expect(event.prevented).toBe(true);
            expect(JSON.parse(posted[1])).toEqual({ kind: "system", name: "menu-action", data: { action: "escape-action" } });
        }
    });

    test("a text box inside a shadow root keeps the key, though the event's target is the host", async () => {
        const posted: string[] = [];
        const fakeWindow = await injectWithShortcuts(posted, [escapeShortcut]);
        const host = { tagName: "DIV" };
        const input = { tagName: "INPUT", type: "text" };
        const event = makeKeyEvent([input, host, { tagName: "BODY" }], { key: "Escape", code: "Escape" });
        event.target = host;
        fakeWindow.keyListeners[0](event);
        expect(event.prevented).toBe(false);
        expect(posted.length).toBe(1);
    });

    test("a key another listener handled, an input method composing and an auto-repeated press run no shortcut", async () => {
        const cases: Partial<IFakeKeyEvent>[] = [
            { defaultPrevented: true },
            { isComposing: true },
            { repeat: true },
        ];
        for (const options of cases) {
            const posted: string[] = [];
            const fakeWindow = await injectWithShortcuts(posted, [escapeShortcut]);
            const event = makeKeyEvent([{ tagName: "BODY" }], { key: "Escape", code: "Escape", ...options });
            fakeWindow.keyListeners[0](event);
            expect(event.prevented).toBe(false);
            expect(posted.length).toBe(1);
        }
    });

    test("a shortcut whose modifiers do not match runs nothing", async () => {
        const fakeWindow = await injectWithShortcuts([], [escapeShortcut]);
        const event = makeKeyEvent([{ tagName: "BODY" }], { key: "Escape", code: "Escape", ctrlKey: true });
        fakeWindow.keyListeners[0](event);
        expect(event.prevented).toBe(false);
    });

    test("a Plus shortcut runs for + and for =, with Shift held or not, whatever the code", async () => {
        const cases = [
            { key: "+", code: "Equal", shiftKey: true },
            { key: "+", code: "Equal", shiftKey: false },
            { key: "=", code: "Equal", shiftKey: false },
            { key: "=", code: "KeyX", shiftKey: true },
        ];
        for (const options of cases) {
            const posted: string[] = [];
            const fakeWindow = await injectWithShortcuts(posted, [plusShortcut]);
            const event = makeKeyEvent([{ tagName: "BODY" }], options);
            fakeWindow.keyListeners[0](event);
            expect(event.prevented).toBe(true);
            expect(JSON.parse(posted[1])).toEqual({ kind: "system", name: "menu-action", data: { action: "zoom-in" } });
        }
    });

    test("a letter shortcut runs for the character the key types, whatever the code", async () => {
        for (const code of ["KeyJ", "KeyC"]) {
            const posted: string[] = [];
            const fakeWindow = await injectWithShortcuts(posted, [jShortcut]);
            const event = makeKeyEvent([{ tagName: "BODY" }], { key: "j", code });
            fakeWindow.keyListeners[0](event);
            expect(event.prevented).toBe(true);
            expect(JSON.parse(posted[1])).toEqual({ kind: "system", name: "menu-action", data: { action: "j-action" } });
        }
        // A letter shortcut without Shift does not run with Shift held.
        const fakeWindow = await injectWithShortcuts([], [jShortcut]);
        const event = makeKeyEvent([{ tagName: "BODY" }], { key: "J", code: "KeyJ", shiftKey: true });
        fakeWindow.keyListeners[0](event);
        expect(event.prevented).toBe(false);
    });

    test("a Shift+letter shortcut runs for the shifted character with Shift held", async () => {
        const posted: string[] = [];
        const fakeWindow = await injectWithShortcuts(posted, [shiftJShortcut]);
        const event = makeKeyEvent([{ tagName: "BODY" }], { key: "J", code: "KeyJ", shiftKey: true });
        fakeWindow.keyListeners[0](event);
        expect(event.prevented).toBe(true);
        expect(JSON.parse(posted[1])).toEqual({ kind: "system", name: "menu-action", data: { action: "shift-j-action" } });
    });

    test("a digit shortcut runs with Shift held or not, as the layout gives it", async () => {
        for (const shiftKey of [true, false]) {
            const posted: string[] = [];
            const fakeWindow = await injectWithShortcuts(posted, [fiveShortcut]);
            const event = makeKeyEvent([{ tagName: "BODY" }], { key: "5", code: "Digit5", shiftKey });
            fakeWindow.keyListeners[0](event);
            expect(event.prevented).toBe(true);
        }
    });

    test("? runs the action from whichever key types it, and a text box keeps it", async () => {
        const cases = [
            { key: "?", code: "Slash", shiftKey: true },
            { key: "?", code: "Comma", shiftKey: false },
        ];
        for (const options of cases) {
            const posted: string[] = [];
            const fakeWindow = await injectWithShortcuts(posted, [askShortcut]);
            const event = makeKeyEvent([{ tagName: "BODY" }], options);
            fakeWindow.keyListeners[0](event);
            expect(event.prevented).toBe(true);
            expect(JSON.parse(posted[1])).toEqual({ kind: "system", name: "menu-action", data: { action: "ask" } });
        }
        for (const element of [{ tagName: "TEXTAREA" }, { tagName: "INPUT", type: "text" }]) {
            const posted: string[] = [];
            const fakeWindow = await injectWithShortcuts(posted, [askShortcut]);
            const event = makeKeyEvent([element], { key: "?", code: "Slash", shiftKey: true });
            fakeWindow.keyListeners[0](event);
            expect(event.prevented).toBe(false);
            expect(posted.length).toBe(1);
        }
        for (const modifier of [{ ctrlKey: true }, { altKey: true }, { metaKey: true }]) {
            const fakeWindow = await injectWithShortcuts([], [askShortcut]);
            const event = makeKeyEvent([{ tagName: "BODY" }], { key: "?", code: "Slash", shiftKey: true, ...modifier });
            fakeWindow.keyListeners[0](event);
            expect(event.prevented).toBe(false);
        }
        // A / press types no ?.
        const fakeWindow = await injectWithShortcuts([], [askShortcut]);
        const event = makeKeyEvent([{ tagName: "BODY" }], { key: "/", code: "Slash" });
        fakeWindow.keyListeners[0](event);
        expect(event.prevented).toBe(false);
    });

    test("a code-matched entry ignores the event's key", async () => {
        const posted: string[] = [];
        const fakeWindow = await injectWithShortcuts(posted, [escapeShortcut]);
        const event = makeKeyEvent([{ tagName: "BODY" }], { key: "/", code: "Escape" });
        fakeWindow.keyListeners[0](event);
        expect(event.prevented).toBe(true);
    });

    test("a shortcut list the script cannot read is logged and leaves no shortcut working", async () => {
        const badLists: object[] = [
            { not: "an array" },
            [{ action: "a", code: "Escape", ctrl: false, alt: false, shift: false, meta: false }],
            [{ action: 1, code: "Escape", ctrl: false, alt: false, shift: false, meta: false, shiftOptional: false, key: "" }],
            [{ action: "a", code: 1, ctrl: false, alt: false, shift: false, meta: false, shiftOptional: false, key: "" }],
            [{ action: "a", code: "Escape", ctrl: false, alt: false, shift: false, meta: false, shiftOptional: false, key: 1 }],
            [{ action: "a", code: "Escape", ctrl: "no", alt: false, shift: false, meta: false, shiftOptional: false, key: "" }],
            [{ action: "a", code: "Escape", ctrl: false, alt: false, shift: false, meta: false, shiftOptional: "no", key: "" }],
        ];
        for (const badList of badLists) {
            const posted: string[] = [];
            const fakeWindow = windowForKeys(posted);
            inject(fakeWindow);
            fakeWindow.__ziggyReceive!({ id: 1, ok: true, data: badList });
            await new Promise(resolve => setTimeout(resolve, 0));
            expect(JSON.parse(posted[1]).data.message).toBe("Ziggy got a shortcut list it cannot read, so no shortcut works in this page.");
            expect(JSON.parse(posted[1]).data.error).toBe(JSON.stringify(badList));
            const event = makeKeyEvent([{ tagName: "BODY" }], { key: "Escape", code: "Escape" });
            fakeWindow.keyListeners[0](event);
            expect(event.prevented).toBe(false);
            expect(posted.length).toBe(2);
        }
    });

    test("a shortcut request that fails is logged and leaves no shortcut working", async () => {
        const posted: string[] = [];
        const fakeWindow = windowForKeys(posted);
        inject(fakeWindow);
        fakeWindow.__ziggyReceive!({ id: 1, ok: false, error: "ExampleFailure" });
        await new Promise(resolve => setTimeout(resolve, 0));
        expect(JSON.parse(posted[1]).data.message).toBe("Ziggy could not read the shortcuts, so no shortcut works in this page.");
        expect(JSON.parse(posted[1]).data.error).toContain("ExampleFailure");
        const event = makeKeyEvent([{ tagName: "BODY" }], { key: "Escape", code: "Escape" });
        fakeWindow.keyListeners[0](event);
        expect(event.prevented).toBe(false);
    });
});
