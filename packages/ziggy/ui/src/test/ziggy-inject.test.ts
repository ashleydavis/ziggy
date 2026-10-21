import fs from "fs";
import path from "path";

//
// A stand-in for the UI's window, with the native handle of the platform under test.
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
        sendTestResult: (requestId: number, result: object | null) => Promise<object>;
        testUiReady: () => void;
        getPathForFile: (file: object) => string | undefined;
        [listenerCall: string]: any;
    };
    __ziggyReceive?: (message: object) => void;
    addEventListener?: (type: string, listener: (event: IFakeDropEvent) => void, capture: boolean) => void;
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
// A stand-in for a drop event as the inject script sees one.
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
// A stand-in for a drop's data.
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
// A stand-in for the element a drop landed on, which records the events dispatched on it.
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
            dropListeners.push(listener);
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
        expect(JSON.parse(posted[0])).toEqual({ kind: "app", id: 1, name: "ping", data: { a: 1 } });
        fakeWindow.__ziggyReceive!({ id: 1, ok: true, data: { answer: 42 } });
        expect(await reply).toEqual({ answer: 42 });
    });

    test("invoke rejects with the core's error", async () => {
        const posted: string[] = [];
        const fakeWindow = windowWithWebkit(posted);
        inject(fakeWindow);
        const reply = fakeWindow.ziggy!.invoke("fail", null);
        fakeWindow.__ziggyReceive!({ id: 1, ok: false, error: "ExampleFailure" });
        await expect(reply).rejects.toThrow("ExampleFailure");
    });

    test("replies are matched to requests by id, in any order", async () => {
        const posted: string[] = [];
        const fakeWindow = windowWithWebkit(posted);
        inject(fakeWindow);
        const first = fakeWindow.ziggy!.invoke("a", null);
        const second = fakeWindow.ziggy!.invoke("b", null);
        fakeWindow.__ziggyReceive!({ id: 2, ok: true, data: "second" });
        fakeWindow.__ziggyReceive!({ id: 1, ok: true, data: "first" });
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
        expect(JSON.parse(posted[0])).toEqual({ kind: "system", id: 1, name: "get-dropped-paths", data: null });
        fakeWindow.__ziggyReceive!({ id: 1, ok: true, data: ["/home/me/two words.txt", "/home/me/a folder"] });
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
        fakeWindow.__ziggyReceive!({ id: 1, ok: true, data: ["/home/me/a.txt", "/home/me/b.txt"] });
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
        expect(JSON.parse(posted[0])).toEqual({ kind: "system", id: 1, name: "get-dropped-paths", data: null });
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
        expect(JSON.parse(posted[0])).toEqual({ kind: "app", name: "notify", data: { source: "s" } });
    });

    test("onEvent gets every app event and none of Ziggy's own", () => {
        const fakeWindow = windowWithWebkit([]);
        inject(fakeWindow);
        const received: object[] = [];
        fakeWindow.ziggy!.onEvent(data => received.push(data));
        fakeWindow.ziggy!.onEvent(data => received.push(data));
        fakeWindow.__ziggyReceive!({ kind: "app", data: { type: "saved" } });
        fakeWindow.__ziggyReceive!({ kind: "system", name: "task-message", data: { taskId: "t" } });
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
        fakeWindow.ziggy!.onTaskMessage((data: object) => system.push(data));
        fakeWindow.ziggy!.onCoreError((data: object) => system.push(data));
        fakeWindow.ziggy!.onEvent(data => app.push(data));
        fakeWindow.__ziggyReceive!({ kind: "app", name: "task-message", data: { taskId: "t" } });
        fakeWindow.__ziggyReceive!({ kind: "app", name: "core-error", data: { error: "E" } });
        expect(system).toEqual([]);
        expect(app).toEqual([{ taskId: "t" }, { error: "E" }]);
    });

    test("an event with no kind, or an unknown one, reaches no listener and is logged", () => {
        const fakeWindow = windowWithWebkit([]);
        inject(fakeWindow);
        const received: object[] = [];
        fakeWindow.ziggy!.onEvent(data => received.push(data));
        fakeWindow.ziggy!.onTaskMessage((data: object) => received.push(data));
        const logged = jest.spyOn(console, "error").mockImplementation(() => undefined);
        try {
            fakeWindow.__ziggyReceive!({ data: { a: 1 } });
            fakeWindow.__ziggyReceive!({ kind: "other", name: "task-message", data: { a: 2 } });
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
        const result = fakeWindow.ziggy!.sendTestResult(4, { ok: true });
        fakeWindow.ziggy!.testUiReady();
        expect(posted.map(text => JSON.parse(text))).toEqual([
            { kind: "system", id: 1, name: "get-platform", data: null },
            { kind: "system", name: "add-task", data: { taskId: "t1", taskType: "quick", source: "s", data: null } },
            { kind: "system", name: "cancel-tasks", data: "s" },
            { kind: "system", id: 2, name: "test-result", data: { requestId: 4, result: { ok: true } } },
            { kind: "system", name: "test-ui-ready", data: null },
        ]);
        fakeWindow.__ziggyReceive!({ id: 1, ok: true, data: { platformKind: "desktop" } });
        fakeWindow.__ziggyReceive!({ id: 2, ok: true, data: {} });
        expect(await platform).toEqual({ platformKind: "desktop" });
        expect(await result).toEqual({});
    });

    test("each of Ziggy's own listeners gets only its own event, and its remover removes it", () => {
        const fakeWindow = windowWithWebkit([]);
        inject(fakeWindow);
        const pairs: [string, string, string][] = [
            ["task-message", "onTaskMessage", "removeTaskMessageListener"],
            ["task-completed", "onTaskCompleted", "removeTaskCompletedListener"],
            ["core-error", "onCoreError", "removeCoreErrorListener"],
            ["test-command", "onTestCommand", "removeTestCommandListener"],
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
        expect(posted.length).toBe(1);
    });

    test("it posts through the Android interface object when that is what the web view has", () => {
        const posted: string[] = [];
        const fakeWindow: IFakeWindow = { ZiggyAndroid: { postMessage: text => posted.push(text) } };
        inject(fakeWindow);
        fakeWindow.ziggy!.send("notify", null);
        expect(posted.length).toBe(1);
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
            "getPathForFile",
            "getPlatform",
            "invoke",
            "onCoreError",
            "onEvent",
            "onTaskCompleted",
            "onTaskMessage",
            "onTestCommand",
            "removeCoreErrorListener",
            "removeEventListener",
            "removeTaskCompletedListener",
            "removeTaskMessageListener",
            "removeTestCommandListener",
            "send",
            "sendTestResult",
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
});
