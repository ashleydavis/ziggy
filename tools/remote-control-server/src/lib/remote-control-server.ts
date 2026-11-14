//
// The remote control server: it listens on two loopback ports and relays between a test script and the Ziggy apps started
// with `--remote-control <host:port>`. The app port is an Express server whose WebSocket endpoint the app connects out to.
// The script port is a plain TCP server, because a bash script connects with /dev/tcp and speaks in lines. Each line from
// the script goes to the window its `window` field names, or window 1 when it has none, as one WebSocket text message, and
// each text message from the app goes back to the script as one line.
//
// The server takes many app connections at once and numbers each with the lowest number from 1 that no connected app has,
// so numbers follow connect order while no window closes. A number is free again once the server has seen that app's
// connection end. A line for a window that is not connected waits for it, as a line waits for the first app.
//

import assert from "node:assert";
import { createServer as createHttpServer } from "node:http";
import type { Server as HttpServer } from "node:http";
import { createServer as createTcpServer } from "node:net";
import type { Server as TcpServer, Socket } from "node:net";
import express from "express";
import { WebSocketServer } from "ws";
import type { RawData, WebSocket } from "ws";
import { splitLines } from "./lines";
import { err, ok } from "./result";
import type { Result } from "./result";

//
// What the server is started with.
//
export interface IRemoteControlServerOptions {
    //
    // The loopback port the app connects to.
    //
    appPort: number;

    //
    // The loopback port the test script connects to.
    //
    scriptPort: number;

    //
    // How long a script line waits for the window it names to connect before it is answered with AppNotConnected. A window
    // connects only once its process has started, which on a phone or a busy CI machine takes many seconds.
    //
    appWaitTimeoutMs: number;

    //
    // Writes a line about something that went wrong, for the person reading the test's log.
    //
    writeError(message: string): void;
}

//
// A running server.
//
export interface IRemoteControlServer {
    //
    // The port the app connects to, the one the system chose when the app port given was 0.
    //
    appPort: number;

    //
    // The port the test script connects to, the one the system chose when the script port given was 0.
    //
    scriptPort: number;

    //
    // Stops listening, ends every app connection and the script connection, and resolves once both ports are closed.
    //
    close(): Promise<void>;
}

//
// A port another process is already listening on.
//
export interface IPortInUseError {
    //
    // Which error this is.
    //
    name: "PortInUse";

    //
    // The port that was in use.
    //
    port: number;
}

//
// Listening on a port failed for a reason other than the port being in use.
//
export interface IListenFailedError {
    //
    // Which error this is.
    //
    name: "ListenFailed";

    //
    // The port that could not be listened on.
    //
    port: number;

    //
    // What the system said.
    //
    message: string;
}

//
// Every way starting the server can fail.
//
export type StartError = IPortInUseError | IListenFailedError;

//
// The address both ports listen on. The script and the app run on this machine (a phone reaches it through adb reverse), so
// nothing outside the machine can reach the server.
//
const LOOPBACK_HOST = "127.0.0.1";

//
// A script line that came while its window was not connected, waiting for that window's app.
//
export interface IWaitingLine {
    //
    // The script connection the line came on, which the reply goes back to.
    //
    script: Socket;

    //
    // The window the line waits for.
    //
    window: number;

    //
    // The text to send the app, without its newline, with the `window` field taken off.
    //
    text: string;

    //
    // The line as the script sent it, which the AppNotConnected error names.
    //
    line: string;

    //
    // Answers the line with AppNotConnected when its window has not connected in time.
    //
    timer: NodeJS.Timeout;
}

//
// An app connected to the server, which is one window of the app.
//
export interface IConnectedApp {
    //
    // The number the server gave the app, which a line names to reach it.
    //
    window: number;

    //
    // The app's connection.
    //
    socket: WebSocket;

    //
    // For each line sent to this app and not yet answered, oldest first, the script connection it came on. The app answers
    // in order, so each reply goes to the connection at the head.
    //
    owed: Socket[];
}

//
// What the server holds while it runs.
//
export interface IRelayState {
    //
    // The connected apps, by window number.
    //
    apps: Map<number, IConnectedApp>;

    //
    // The script's connection, while a script is connected.
    //
    script: Socket | undefined;

    //
    // Lines waiting for a window that is not connected, oldest first.
    //
    waiting: IWaitingLine[];
}

//
// The most lines a script may have waiting for a window. A test script sends one command and reads its reply before the
// next, so more than this means the script is not speaking the protocol.
//
const WAITING_LINES_MAX = 1000;

//
// Starts listening on both ports. Fails, naming the port, when either cannot be listened on, and then listens on neither.
//
export async function startRemoteControlServer(options: IRemoteControlServerOptions): Promise<Result<IRemoteControlServer, StartError>> {
    assert(Number.isInteger(options.appPort), "the app port is a whole number");
    assert(Number.isInteger(options.scriptPort), "the script port is a whole number");
    if (options.appPort !== 0) assert(options.appPort !== options.scriptPort, "the app and the script have a port each");
    assert(options.appWaitTimeoutMs > 0, "a line waits a while for the app");

    // The options with the ports the servers listen on, which differ from those given when a port of 0 let the system choose.
    // The handlers are given these, so every message names the port in use.
    const bound: IRemoteControlServerOptions = {
        ...options,
    };
    const state: IRelayState = {
        apps: new Map(),
        script: undefined,
        waiting: [],
    };

    const httpServer = createHttpServer(express());
    const webSocketServer = new WebSocketServer({
        server: httpServer,
        path: "/",
    });
    webSocketServer.on("connection", app => {
        acceptApp(state, bound, app);
    });
    // The WebSocket server passes on every error of the HTTP server it is attached to, and an error with no listener ends the
    // process. A failure to listen is what listen returns, so an error is written here only while the port is listening.
    webSocketServer.on("error", error => {
        if (httpServer.listening) {
            options.writeError(`The remote control server's app port ${bound.appPort} failed: ${error.message}`);
        }
    });
    const appListened = await listen(httpServer, options.appPort);
    if (!appListened.ok) {
        webSocketServer.close();
        return err(appListened.error);
    }

    const tcpServer = createTcpServer(script => {
        acceptScript(state, bound, script);
    });
    const scriptListened = await listen(tcpServer, options.scriptPort);
    if (!scriptListened.ok) {
        webSocketServer.close();
        await closeServer(httpServer);
        return err(scriptListened.error);
    }

    bound.appPort = listeningPort(httpServer);
    bound.scriptPort = listeningPort(tcpServer);

    // The servers are listening, so an error now is not about starting. Each is reported: the person reading the log sees
    // what failed and on which port.
    tcpServer.on("error", error => {
        options.writeError(`The remote control server's script port ${bound.scriptPort} failed: ${error.message}`);
    });

    return ok({
        appPort: bound.appPort,
        scriptPort: bound.scriptPort,
        close: async () => {
            for (const line of state.waiting) {
                clearTimeout(line.timer);
            }
            state.waiting = [];
            for (const connected of state.apps.values()) {
                connected.socket.terminate();
            }
            state.apps.clear();
            if (state.script) {
                state.script.destroy();
            }
            webSocketServer.close();
            await closeServer(httpServer);
            await closeServer(tcpServer);
        },
    });
}

//
// Listens on the loopback port, or fails naming the port.
//
export function listen(server: HttpServer | TcpServer, port: number): Promise<Result<void, StartError>> {
    return new Promise(resolve => {
        function onError(error: NodeJS.ErrnoException): void {
            if (error.code === "EADDRINUSE") {
                resolve(err({
                    name: "PortInUse",
                    port,
                }));
            }
            else {
                resolve(err({
                    name: "ListenFailed",
                    port,
                    message: error.message,
                }));
            }
        }
        server.once("error", onError);
        // Node reports most failures through the error event, but throws for a port number out of range.
        try {
            server.listen(port, LOOPBACK_HOST, () => {
                server.removeListener("error", onError);
                resolve(ok(undefined));
            });
        }
        catch (error) {
            server.removeListener("error", onError);
            resolve(err({
                name: "ListenFailed",
                port,
                message: error instanceof Error ? error.message : String(error),
            }));
        }
    });
}

//
// Stops the server listening and resolves once every connection it had is gone.
//
export function closeServer(server: HttpServer | TcpServer): Promise<void> {
    return new Promise(resolve => {
        if (!server.listening) {
            resolve();
            return;
        }
        server.close(() => {
            resolve();
        });
    });
}

//
// The error as a sentence for the person who ran the server.
//
export function describeStartError(error: StartError): string {
    switch (error.name) {
        case "PortInUse": {
            return `The remote control server could not listen on port ${error.port}: another program is using it.`;
        }
        case "ListenFailed": {
            return `The remote control server could not listen on port ${error.port}: ${error.message}`;
        }
    }
}

//
// The lowest number from 1 to WINDOW_COUNT_MAX that no connected app holds, or undefined when every one of them is held.
// It is generic over the connected app so a test can fill a map with plain values instead of WebSocket connections.
//
export function lowestFreeWindow<TApp>(apps: Map<number, TApp>): number | undefined {
    for (let window = 1; window <= WINDOW_COUNT_MAX; window++) {
        if (!apps.has(window)) {
            assert(!apps.has(window), "the window a new app takes is free");
            return window;
        }
    }
    return undefined;
}

//
// Takes an app's connection as the lowest free window and sends it every line that was waiting for that window. Lines
// waiting for other windows keep their timers. An app beyond WINDOW_COUNT_MAX is turned away, because a test that starts
// that many apps is starting them in a loop.
//
export function acceptApp(state: IRelayState, options: IRemoteControlServerOptions, app: WebSocket): void {
    const window = lowestFreeWindow(state.apps);
    if (window === undefined) {
        options.writeError(`More than ${WINDOW_COUNT_MAX} apps connected to the remote control server on port ${options.appPort}, so this one was closed.`);
        app.terminate();
        return;
    }
    assert(!state.apps.has(window), "the window is free before the app is taken");
    const connected: IConnectedApp = {
        window,
        socket: app,
        owed: [],
    };
    state.apps.set(window, connected);
    app.on("message", (data, isBinary) => {
        receiveReply(state, options, window, app, data, isBinary);
    });
    app.on("close", () => {
        releaseApp(state, window, app);
    });
    app.on("error", error => {
        options.writeError(`The app's connection to the remote control server on port ${options.appPort} as window ${window} failed: ${error.message}`);
    });

    const remaining: IWaitingLine[] = [];
    for (const line of state.waiting) {
        if (line.window === window) {
            clearTimeout(line.timer);
            sendToApp(connected, line.script, line.text);
        }
        else {
            remaining.push(line);
        }
    }
    state.waiting = remaining;
    assert(state.apps.has(window), "the app is held under the window it took");
    assert(state.waiting.every(line => line.window !== window), "no waiting line is for the window that just connected");
}

//
// Forgets the app once its connection has ended. Every line it was sent and did not answer gets AppDisconnected, so the
// script hears at once instead of waiting out its own timeout. Its number is free for the next app.
//
export function releaseApp(state: IRelayState, window: number, app: WebSocket): void {
    const connected = state.apps.get(window);
    if (connected?.socket !== app) {
        return;
    }
    state.apps.delete(window);
    for (const script of connected.owed) {
        writeToScript(state, script, '{"ok":false,"error":"AppDisconnected"}');
    }
}

//
// Sends a line to the app and remembers that its reply goes to the script connection it came on.
//
export function sendToApp(connected: IConnectedApp, script: Socket, text: string): void {
    assert(!text.includes("\n"), "a line sent to the app holds no newline");
    connected.owed.push(script);
    connected.socket.send(text);
}

//
// Passes a reply from the app back to the script connection the line it answers came on. A reply whose script has gone is
// reported and dropped.
//
export function receiveReply(state: IRelayState, options: IRemoteControlServerOptions, window: number, app: WebSocket, data: RawData, isBinary: boolean): void {
    const connected = state.apps.get(window);
    assert(connected?.socket === app, "replies come only from a connected app, under its own number");
    if (isBinary) {
        options.writeError("The app sent the remote control server a binary message. It sends text only, so the message was dropped.");
        return;
    }
    const text = data.toString();
    const script = connected.owed.shift();
    if (!script) {
        options.writeError(`The app connected as window ${window} sent the remote control server a reply to no line it was sent, so it was dropped: ${text}`);
        return;
    }
    if (!writeToScript(state, script, text)) {
        options.writeError(`The script that sent a line had gone when the app's reply came, so the reply was dropped: ${text}`);
    }
}

//
// Writes a reply line to the script connection, when it is still the one connected. Returns whether it was written.
//
export function writeToScript(state: IRelayState, script: Socket, text: string): boolean {
    if (state.script !== script) {
        return false;
    }
    if (script.destroyed) {
        return false;
    }
    script.write(`${text}\n`);
    return true;
}

//
// Takes a script's connection and reads it line by line. A new script connection replaces the one before it: a scenario that
// restarts the app closes its connection and opens another, and the server may not yet have seen the old one end.
//
export function acceptScript(state: IRelayState, options: IRemoteControlServerOptions, script: Socket): void {
    const previous = state.script;
    if (previous) {
        releaseScript(state, previous);
        previous.destroy();
    }
    assert(state.script === undefined, "the earlier script is forgotten before the new one is taken");
    state.script = script;
    script.setEncoding("utf8");
    let rest = "";
    script.on("data", chunk => {
        assert(typeof chunk === "string", "the script's connection is read as text");
        const split = splitLines(rest, chunk);
        rest = split.rest;
        for (const line of split.lines) {
            receiveLine(state, options, script, line);
        }
    });
    script.on("close", () => {
        releaseScript(state, script);
    });
    script.on("error", error => {
        options.writeError(`The script's connection to the remote control server on port ${options.scriptPort} failed: ${error.message}`);
    });
}

//
// Forgets the script once its connection has ended, with every line it sent that was still waiting for an app.
//
export function releaseScript(state: IRelayState, script: Socket): void {
    if (state.script !== script) {
        return;
    }
    state.script = undefined;
    // Only the connected script's lines wait, because a new script connection releases the one before it.
    for (const line of state.waiting) {
        assert(line.script === script, "only the connected script's lines wait");
        clearTimeout(line.timer);
    }
    state.waiting = [];
}

//
// Sends a line from the script to the window it names, or, when that window is not connected, keeps it until the window
// connects or the wait runs out. A line whose `window` no app could ever have is answered at once with InvalidWindow.
//
export function receiveLine(state: IRelayState, options: IRemoteControlServerOptions, script: Socket, text: string): void {
    const target = readTarget(text);
    if (!target.ok) {
        options.writeError(`The script sent a line whose window is not a whole number from 1 to ${WINDOW_COUNT_MAX}, so it got InvalidWindow: ${text}`);
        writeToScript(state, script, '{"ok":false,"error":"InvalidWindow"}');
        return;
    }
    const connected = state.apps.get(target.value.window);
    if (connected) {
        sendToApp(connected, script, target.value.text);
        return;
    }
    if (state.waiting.length >= WAITING_LINES_MAX) {
        options.writeError(`The script sent more than ${WAITING_LINES_MAX} lines for windows that were not connected, so this one was answered at once: ${text}`);
        writeToScript(state, script, '{"ok":false,"error":"AppNotConnected"}');
        return;
    }
    const line: IWaitingLine = {
        script,
        window: target.value.window,
        text: target.value.text,
        line: text,
        timer: setTimeout(() => {
            expireLine(state, options, line);
        }, options.appWaitTimeoutMs),
    };
    state.waiting.push(line);
}

//
// Answers a line whose window did not connect in time with AppNotConnected, naming the window and the line as the script
// sent it.
//
export function expireLine(state: IRelayState, options: IRemoteControlServerOptions, line: IWaitingLine): void {
    const index = state.waiting.indexOf(line);
    assert(index >= 0, "a line that expires is still waiting");
    state.waiting.splice(index, 1);
    options.writeError(`No app connected to port ${options.appPort} as window ${line.window} within ${options.appWaitTimeoutMs} ms, so this line got AppNotConnected: ${line.line}`);
    writeToScript(state, line.script, '{"ok":false,"error":"AppNotConnected"}');
}

//
// The port a listening server is bound to.
//
export function listeningPort(server: HttpServer | TcpServer): number {
    const address = server.address();
    assert(address !== null, "the server is listening");
    assert(typeof address !== "string", "the server listens on a TCP port, not a pipe");
    assert(address.port > 0, "a listening server has a port");
    return address.port;
}

//
// The most windows a server holds and the highest window number a line may name. A smoke test opens a few windows, so more
// than this many apps means a test is starting apps in a loop. It limits both the window numbers a line may name and the
// apps the server holds, so every window number a line can name is one an app can have.
//
export const WINDOW_COUNT_MAX = 100;

//
// The window a script line goes to and the text the app is sent.
//
export interface ILineTarget {
    //
    // The number of the window the line is for.
    //
    window: number;

    //
    // The text to send the app.
    //
    text: string;
}

//
// A script line whose `window` is not a whole number from 1 to WINDOW_COUNT_MAX.
//
export interface IInvalidWindowError {
    //
    // Which error this is.
    //
    name: "InvalidWindow";

    //
    // The line as the script sent it, for the error.
    //
    text: string;
}

//
// What `JSON.parse` can return: a plain object, a string, a number, a boolean or null. Named so the parsed value is typed
// without `any`, `unknown` or a cast.
//
type JsonValue = object | string | number | boolean | null;

//
// Reads the window a script line is for and the text to send that app. A line that is not a plain object, or is a plain
// object with no `window` key, goes to window 1 with its text unchanged, byte for byte, so the app answers it as it does
// today. A line that names a whole number from 1 to WINDOW_COUNT_MAX goes to that window, with the `window` key taken off.
// Any other `window` value gets InvalidWindow at once, because no app can ever connect as that window.
//
// The text sent for a line that names a window is the parsed value written again, so it can differ from the script's bytes:
// an integer beyond 2^53 comes out rounded, a number spelling (`1.0`, `1e2`) comes out as `JSON.stringify` writes the
// number (`1`, `100`), a string escape comes out as `JSON.stringify` writes it, a key given twice comes out once with its
// last value, a number outside the double range (`1e999`) becomes `Infinity` and is written as `null`, and a key whose name
// is an integer-like string comes out before the other keys. Taking the key out of the text needs a JSON parser, and
// `JSON.parse` with `JSON.stringify` is the one the server has. The app's commands read no such value, and no existing
// script sends a line that names a window.
//
export function readTarget(text: string): Result<ILineTarget, IInvalidWindowError> {
    assert(!text.includes("\n"), "a script line holds no newline");
    let parsed: JsonValue;
    try {
        parsed = JSON.parse(text);
    }
    catch {
        return ok({
            window: 1,
            text,
        });
    }
    if (typeof parsed !== "object") {
        return ok({
            window: 1,
            text,
        });
    }
    if (parsed === null) {
        return ok({
            window: 1,
            text,
        });
    }
    if (Array.isArray(parsed)) {
        return ok({
            window: 1,
            text,
        });
    }
    const fields: Map<string, JsonValue> = new Map(Object.entries(parsed));
    if (!fields.has("window")) {
        return ok({
            window: 1,
            text,
        });
    }
    const windowValue: JsonValue | undefined = fields.get("window");
    if (typeof windowValue !== "number") {
        return err({
            name: "InvalidWindow",
            text,
        });
    }
    if (!Number.isInteger(windowValue)) {
        return err({
            name: "InvalidWindow",
            text,
        });
    }
    if (windowValue < 1) {
        return err({
            name: "InvalidWindow",
            text,
        });
    }
    if (windowValue > WINDOW_COUNT_MAX) {
        return err({
            name: "InvalidWindow",
            text,
        });
    }
    fields.delete("window");
    const targetText: string | undefined = JSON.stringify(Object.fromEntries(fields));
    assert(targetText !== undefined, "a line that names a window has text to send");
    const target: ILineTarget = {
        window: windowValue,
        text: targetText,
    };
    assert(Number.isInteger(target.window), "a line's window is a whole number");
    assert(target.window >= 1, "a line's window is from 1");
    assert(target.window <= WINDOW_COUNT_MAX, "a line's window is within the count");
    return ok(target);
}
