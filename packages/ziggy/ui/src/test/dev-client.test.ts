import fs from "fs";
import path from "path";

//
// A stand-in for the browser's WebSocket, which records what is sent and lets a test fire its events.
//
interface IFakeSocket {
    url: string;
    sent: string[];
    listeners: Record<string, ((event: { data?: string }) => void)[]>;
    addEventListener: (type: string, listener: (event: { data?: string }) => void) => void;
    send: (text: string) => void;
    fire: (type: string, event: { data?: string }) => void;
}

//
// A stand-in for an answer to fetch.
//
interface IFakeResponse {
    ok: boolean;
    status: number;
    text: () => Promise<string>;
}

//
// A request the script made with fetch.
//
interface IFakeRequest {
    url: string;
    options: { method?: string; body?: unknown } | undefined;
}

//
// A stand-in for the page's window, with what the script uses.
//
interface IFakeWindow {
    location: { host: string; reloads: number; reload: () => void };
    WebSocket: new (url: string) => IFakeSocket;
    fetch: (url: string, options?: { method?: string; body?: unknown }) => Promise<IFakeResponse>;
    setTimeout: (callback: () => void, delay: number) => void;
    __ziggyReceive?: (message: object) => void;
    webkit?: { messageHandlers: { ziggy: { postMessage: (text: string) => void } } };
    chrome?: { webview?: { postMessageWithAdditionalObjects: (message: string, files: { name: string }[]) => void } };
}

const script = fs.readFileSync(path.join(__dirname, "../../../dev/src/lib/dev-client.js"), "utf8");

//
// A window for the script, with every request it makes answered by the function given, and the socket and listeners it creates.
//
function makeWindow(answer: (request: IFakeRequest) => IFakeResponse) {
    const sockets: IFakeSocket[] = [];
    const requests: IFakeRequest[] = [];
    const timers: (() => void)[] = [];
    const received: object[] = [];
    const fakeWindow: IFakeWindow = {
        location: {
            host: "127.0.0.1:4000",
            reloads: 0,
            reload: () => {
                fakeWindow.location.reloads += 1;
            },
        },
        WebSocket: function (this: unknown, url: string) {
            const socket: IFakeSocket = {
                url,
                sent: [],
                listeners: {},
                addEventListener: (type, listener) => {
                    (socket.listeners[type] = socket.listeners[type] ?? []).push(listener);
                },
                send: text => {
                    socket.sent.push(text);
                },
                fire: (type, event) => {
                    (socket.listeners[type] ?? []).forEach(listener => listener(event));
                },
            };
            sockets.push(socket);
            return socket;
        } as unknown as new (url: string) => IFakeSocket,
        fetch: (url, options) => {
            const request = { url, options };
            requests.push(request);
            return Promise.resolve(answer(request));
        },
        setTimeout: callback => {
            timers.push(callback);
        },
        __ziggyReceive: message => {
            received.push(message);
        },
    };
    return { fakeWindow, sockets, requests, timers, received };
}

function respond(ok: boolean, text: string): IFakeResponse {
    return {
        ok,
        status: ok ? 200 : 500,
        text: () => Promise.resolve(text),
    };
}

function run(fakeWindow: IFakeWindow): void {
    new Function("window", script)(fakeWindow);
}

async function settle(): Promise<void> {
    for (let turn = 0; turn < 10; turn += 1) {
        await new Promise(resolve => setTimeout(resolve, 0));
    }
}

describe("dev-client", () => {
    test("it connects to the dev host's socket on the page's own host", () => {
        const { fakeWindow, sockets } = makeWindow(() => respond(true, ""));
        run(fakeWindow);
        expect(sockets.map(socket => socket.url)).toEqual(["ws://127.0.0.1:4000/__ziggy/socket"]);
    });

    test("it gives the page the WebKit message handler the inject script posts through", () => {
        const { fakeWindow, sockets } = makeWindow(() => respond(true, ""));
        run(fakeWindow);
        sockets[0].fire("open", {});
        fakeWindow.webkit!.messageHandlers.ziggy.postMessage("{\"channel\":\"x\"}");
        expect(sockets[0].sent).toEqual(["{\"channel\":\"x\"}"]);
    });

    test("messages posted before the socket opens are sent, in order, once it does", () => {
        const { fakeWindow, sockets } = makeWindow(() => respond(true, ""));
        run(fakeWindow);
        fakeWindow.webkit!.messageHandlers.ziggy.postMessage("one");
        fakeWindow.webkit!.messageHandlers.ziggy.postMessage("two");
        expect(sockets[0].sent).toEqual([]);
        sockets[0].fire("open", {});
        fakeWindow.webkit!.messageHandlers.ziggy.postMessage("three");
        expect(sockets[0].sent).toEqual(["one", "two", "three"]);
    });

    test("a message from the core is handed to window.__ziggyReceive as an object", () => {
        const { fakeWindow, sockets, received } = makeWindow(() => respond(true, ""));
        run(fakeWindow);
        sockets[0].fire("message", { data: "{\"id\":1,\"ok\":true,\"data\":\"pong\"}" });
        expect(received).toEqual([{ id: 1, ok: true, data: "pong" }]);
    });

    test("when the socket closes, the page reloads once the dev host answers again", async () => {
        let answering = false;
        const { fakeWindow, sockets, requests, timers } = makeWindow(() => respond(true, "ok"));
        // A dev host that is down refuses the connection, which fetch reports by rejecting.
        fakeWindow.fetch = (url, options) => {
            requests.push({ url, options });
            if (!answering) {
                return Promise.reject(new Error("connection refused"));
            }
            return Promise.resolve(respond(true, "ok"));
        };
        run(fakeWindow);
        sockets[0].fire("close", {});
        await settle();
        expect(fakeWindow.location.reloads).toBe(0);
        expect(timers.length).toBe(1);
        answering = true;
        timers[0]();
        await settle();
        expect(fakeWindow.location.reloads).toBe(1);
        expect(requests.every(request => request.url === "/__ziggy/alive")).toBe(true);
    });

    test("a drop's files handed over as WebView2 takes them are each sent to the dev host and recorded, and messages wait until then", async () => {
        const { fakeWindow, sockets, requests } = makeWindow(request => {
            if (request.url.startsWith("/__ziggy/dropped-file")) {
                return respond(true, "/data/dropped/1/" + decodeURIComponent(request.url.split("name=")[1]));
            }
            return respond(true, "");
        });
        run(fakeWindow);
        sockets[0].fire("open", {});
        const files = [{ name: "a b.txt" }, { name: "c.txt" }];
        fakeWindow.chrome!.webview!.postMessageWithAdditionalObjects("ziggy-file", files);
        fakeWindow.webkit!.messageHandlers.ziggy.postMessage("get the drop's paths");
        expect(sockets[0].sent).toEqual([]);
        await settle();
        expect(requests.map(request => request.url)).toEqual([
            "/__ziggy/dropped-file?name=a%20b.txt",
            "/__ziggy/dropped-file?name=c.txt",
            "/__ziggy/drop",
        ]);
        expect(requests[0].options!.body).toBe(files[0]);
        expect(JSON.parse(requests[2].options!.body as string)).toEqual(["/data/dropped/1/a b.txt", "/data/dropped/1/c.txt"]);
        expect(sockets[0].sent).toEqual(["get the drop's paths"]);
    });

    test("a drop the dev host cannot save is recorded as an empty drop, so the page is not given an earlier drop's paths", async () => {
        const errors: unknown[] = [];
        const consoleError = jest.spyOn(console, "error").mockImplementation(error => {
            errors.push(error);
        });
        const { fakeWindow, sockets, requests } = makeWindow(request => {
            if (request.url.startsWith("/__ziggy/dropped-file")) {
                return respond(false, "disk full");
            }
            return respond(true, "");
        });
        run(fakeWindow);
        sockets[0].fire("open", {});
        fakeWindow.chrome!.webview!.postMessageWithAdditionalObjects("ziggy-file", [{ name: "a.txt" }]);
        fakeWindow.webkit!.messageHandlers.ziggy.postMessage("get the drop's paths");
        await settle();
        consoleError.mockRestore();
        expect(requests.map(request => request.url)).toEqual([
            "/__ziggy/dropped-file?name=a.txt",
            "/__ziggy/drop",
        ]);
        expect(requests[1].options!.body).toBe("[]");
        expect(String(errors[0])).toContain("could not save the dropped file a.txt: disk full");
        expect(sockets[0].sent).toEqual(["get the drop's paths"]);
    });

    test("objects handed over with any message but a drop's are refused", () => {
        const { fakeWindow, requests } = makeWindow(() => respond(true, ""));
        run(fakeWindow);
        expect(() => fakeWindow.chrome!.webview!.postMessageWithAdditionalObjects("other", [{ name: "a.txt" }])).toThrow("only a drop's files");
        expect(requests).toEqual([]);
    });

    test("it refuses to run in a page that already has a web view's handler", () => {
        const { fakeWindow } = makeWindow(() => respond(true, ""));
        fakeWindow.webkit = { messageHandlers: { ziggy: { postMessage: () => undefined } } };
        expect(() => run(fakeWindow)).toThrow("not running in an ordinary browser");
    });

    test("it refuses to run in a page that already has WebView2's handle", () => {
        const { fakeWindow } = makeWindow(() => respond(true, ""));
        fakeWindow.chrome = { webview: { postMessageWithAdditionalObjects: () => undefined } };
        expect(() => run(fakeWindow)).toThrow("not running in an ordinary browser");
    });
});
