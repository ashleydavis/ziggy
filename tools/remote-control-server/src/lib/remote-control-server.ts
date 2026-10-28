//
// The remote control server: it listens on two loopback ports and relays between a test script and a Ziggy app started with
// `--remote-control <host:port>`. The app port is an Express server whose WebSocket endpoint the app connects out to. The
// script port is a plain TCP server, because a bash script connects with /dev/tcp and speaks in lines. Each line from the
// script goes to the app as one WebSocket text message, and each text message from the app goes back to the script as one
// line. The server keeps running when the app goes away, so a scenario that restarts the app keeps the same server.
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
    // How long a script line waits for an app to connect before it is answered with AppNotConnected. The app connects only
    // once it has started, which on a phone or a busy CI machine takes many seconds.
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
    // Stops listening, ends both connections and resolves once both ports are closed.
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
// A script line that came while no app was connected, waiting for one.
//
export interface IWaitingLine {
    //
    // The script connection the line came on, which the reply goes back to.
    //
    script: Socket;

    //
    // The line, without its newline.
    //
    text: string;

    //
    // Answers the line with AppNotConnected when no app has connected in time.
    //
    timer: NodeJS.Timeout;
}

//
// What the server holds while it runs.
//
export interface IRelayState {
    //
    // The app's connection, while an app is connected.
    //
    app: WebSocket | undefined;

    //
    // The script's connection, while a script is connected.
    //
    script: Socket | undefined;

    //
    // Lines that came while no app was connected, oldest first.
    //
    waiting: IWaitingLine[];

    //
    // For each line sent to the app and not yet answered, oldest first, the script connection it came on. The app answers
    // in order, so each reply goes to the connection at the head.
    //
    owed: Socket[];
}

//
// The most lines a script may have waiting for the app. A test script sends one command and reads its reply before the
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
        app: undefined,
        script: undefined,
        waiting: [],
        owed: [],
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
            if (state.app) {
                state.app.terminate();
            }
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
// Takes an app's connection and sends it every line that was waiting for one. A new app replaces the one before it: an app
// that restarts connects again, and the server may not yet have seen the old connection end.
//
export function acceptApp(state: IRelayState, options: IRemoteControlServerOptions, app: WebSocket): void {
    const previous = state.app;
    if (previous) {
        releaseApp(state, previous);
        previous.terminate();
    }
    assert(state.app === undefined, "the earlier app is forgotten before the new one is taken");
    state.app = app;
    app.on("message", (data, isBinary) => {
        receiveReply(state, options, app, data, isBinary);
    });
    app.on("close", () => {
        releaseApp(state, app);
    });
    app.on("error", error => {
        options.writeError(`The app's connection to the remote control server on port ${options.appPort} failed: ${error.message}`);
    });

    const waiting = state.waiting;
    state.waiting = [];
    for (const line of waiting) {
        clearTimeout(line.timer);
        sendToApp(state, app, line.script, line.text);
    }
    assert(state.waiting.length === 0, "every waiting line went to the app");
}

//
// Forgets the app once its connection has ended. Every line it was sent and did not answer gets AppDisconnected, so the
// script hears at once instead of waiting out its own timeout.
//
export function releaseApp(state: IRelayState, app: WebSocket): void {
    if (state.app !== app) {
        return;
    }
    state.app = undefined;
    const owed = state.owed;
    state.owed = [];
    for (const script of owed) {
        writeToScript(state, script, '{"ok":false,"error":"AppDisconnected"}');
    }
}

//
// Sends a line to the app and remembers that its reply goes to the script connection it came on.
//
export function sendToApp(state: IRelayState, app: WebSocket, script: Socket, text: string): void {
    assert(state.app === app, "lines go only to the connected app");
    state.owed.push(script);
    app.send(text);
}

//
// Passes a reply from the app back to the script connection the line it answers came on. A reply whose script has gone is
// reported and dropped.
//
export function receiveReply(state: IRelayState, options: IRemoteControlServerOptions, app: WebSocket, data: RawData, isBinary: boolean): void {
    if (isBinary) {
        options.writeError("The app sent the remote control server a binary message. It sends text only, so the message was dropped.");
        return;
    }
    const text = data.toString();
    const script = state.owed.shift();
    if (!script) {
        options.writeError(`The app sent the remote control server a reply to no line it was sent, so it was dropped: ${text}`);
        return;
    }
    if (!writeToScript(state, script, text)) {
        options.writeError(`The script that sent a line had gone when the app's reply came, so the reply was dropped: ${text}`);
    }
    assert(state.app === app, "replies come only from the connected app");
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
// Sends a line from the script to the app, or, when no app is connected, keeps it until one connects or the wait runs out.
//
export function receiveLine(state: IRelayState, options: IRemoteControlServerOptions, script: Socket, text: string): void {
    if (state.app) {
        sendToApp(state, state.app, script, text);
        return;
    }
    if (state.waiting.length >= WAITING_LINES_MAX) {
        options.writeError(`The script sent more than ${WAITING_LINES_MAX} lines while no app was connected, so this one was answered at once: ${text}`);
        writeToScript(state, script, '{"ok":false,"error":"AppNotConnected"}');
        return;
    }
    const line: IWaitingLine = {
        script,
        text,
        timer: setTimeout(() => {
            expireLine(state, options, line);
        }, options.appWaitTimeoutMs),
    };
    state.waiting.push(line);
}

//
// Answers a line no app connected in time for with AppNotConnected.
//
export function expireLine(state: IRelayState, options: IRemoteControlServerOptions, line: IWaitingLine): void {
    const index = state.waiting.indexOf(line);
    assert(index >= 0, "a line that expires is still waiting");
    state.waiting.splice(index, 1);
    options.writeError(`No app connected to port ${options.appPort} within ${options.appWaitTimeoutMs} ms, so this line got AppNotConnected: ${line.text}`);
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
