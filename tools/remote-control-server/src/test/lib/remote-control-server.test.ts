//
// Checks the remote control server relays between a test script and an app as the smoke tests use it. Each test starts a real
// server on free loopback ports, connects a script over TCP as bash's /dev/tcp does and an app over WebSocket as Ziggy's core
// does, and checks what each side receives. Everything stays on the loopback address inside this process.
//

import assert from "node:assert";
import { createServer, connect, Socket } from "node:net";
import type { AddressInfo } from "node:net";
import { WebSocket } from "ws";
import { closeServer, describeStartError, listen, releaseScript, startRemoteControlServer, writeToScript } from "../../lib/remote-control-server";
import type { IRelayState, IRemoteControlServer } from "../../lib/remote-control-server";

//
// A started server and what it reported.
//
interface IStartedServer {
    //
    // The running server.
    //
    server: IRemoteControlServer;

    //
    // The port the app connects to.
    //
    appPort: number;

    //
    // The port the script connects to.
    //
    scriptPort: number;

    //
    // Every error line the server wrote.
    //
    errors: string[];

    //
    // Resolves with the next error line the server writes, in order, so a test waits for the server instead of for a time.
    //
    nextError(): Promise<string>;
}

//
// A script's connection and the lines it has read.
//
interface IScriptClient {
    //
    // The TCP connection.
    //
    socket: Socket;

    //
    // Resolves with the next line the server writes.
    //
    nextLine(): Promise<string>;
}

//
// An app's connection and the messages it has received.
//
interface IAppClient {
    //
    // The WebSocket connection.
    //
    socket: WebSocket;

    //
    // Resolves with the next text message the server sends.
    //
    nextMessage(): Promise<string>;
}

//
// Asks the system for a loopback port that is free now.
//
async function freePort(): Promise<number> {
    const server = createServer();
    const listened = await listen(server, 0);
    assert(listened.ok);
    const port = (server.address() as AddressInfo).port;
    await closeServer(server);
    return port;
}

//
// Starts a server on two free ports, with the given wait for the app.
//
async function startServer(appWaitTimeoutMs: number): Promise<IStartedServer> {
    const appPort = await freePort();
    const scriptPort = await freePort();
    const errors: string[] = [];
    const errorQueue = createQueue();
    const started = await startRemoteControlServer({
        appPort,
        scriptPort,
        appWaitTimeoutMs,
        writeError: message => {
            errors.push(message);
            errorQueue.add(message);
        },
    });
    assert(started.ok);
    return {
        server: started.value,
        appPort,
        scriptPort,
        errors,
        nextError: () => errorQueue.next(),
    };
}

//
// Text received on a connection, handed out in the order it came.
//
interface IQueue {
    //
    // Adds an item that came.
    //
    add(item: string): void;

    //
    // Resolves with the oldest item not yet handed out, waiting for one when there is none.
    //
    next(): Promise<string>;
}

//
// Makes a queue that hands out items in the order they were added, waiting for one when it is empty.
//
function createQueue(): IQueue {
    const items: string[] = [];
    const waiters: ((item: string) => void)[] = [];
    return {
        add(item: string): void {
            const waiter = waiters.shift();
            if (waiter) {
                waiter(item);
            }
            else {
                items.push(item);
            }
        },
        next(): Promise<string> {
            const item = items.shift();
            if (item !== undefined) {
                return Promise.resolve(item);
            }
            return new Promise(resolve => {
                waiters.push(resolve);
            });
        },
    };
}

//
// Connects a script to the port.
//
async function connectScript(port: number): Promise<IScriptClient> {
    const lines = createQueue();
    const socket = connect(port, "127.0.0.1");
    socket.setEncoding("utf8");
    let rest = "";
    // A server that replaces this connection with a newer one resets it, which a test of the replacement expects.
    socket.on("error", () => {});
    socket.on("data", chunk => {
        const pieces = (rest + String(chunk)).split("\n");
        rest = pieces.pop() ?? "";
        for (const line of pieces) {
            lines.add(line);
        }
    });
    await new Promise<void>(resolve => {
        socket.once("connect", () => {
            resolve();
        });
    });
    return {
        socket,
        nextLine: () => lines.next(),
    };
}

//
// Connects an app to the port.
//
async function connectApp(port: number): Promise<IAppClient> {
    const messages = createQueue();
    const socket = new WebSocket(`ws://127.0.0.1:${port}/`);
    // A server that replaces this connection with a newer one ends it at once, which a test of the replacement expects.
    socket.on("error", () => {});
    socket.on("message", data => {
        messages.add(data.toString());
    });
    await new Promise<void>(resolve => {
        socket.once("open", () => {
            resolve();
        });
    });
    return {
        socket,
        nextMessage: () => messages.next(),
    };
}

//
// Resolves once the socket has closed.
//
function closed(socket: Socket | WebSocket): Promise<void> {
    return new Promise(resolve => {
        socket.once("close", () => {
            resolve();
        });
    });
}

//
// Resolves after the time has passed.
//
function delay(timeMs: number): Promise<void> {
    return new Promise(resolve => {
        setTimeout(resolve, timeMs);
    });
}

describe("startRemoteControlServer", () => {
    test("listens on the two ports it is given", async () => {
        const started = await startServer(1000);
        const script = await connectScript(started.scriptPort);
        const app = await connectApp(started.appPort);
        expect(script.socket.remotePort).toBe(started.scriptPort);
        expect(app.socket.url).toBe(`ws://127.0.0.1:${started.appPort}/`);
        script.socket.destroy();
        app.socket.close();
        await started.server.close();
    });

    test("reports the ports it was given, and the ports the system chose for ports of 0", async () => {
        const given = await startServer(1000);
        expect(given.server.appPort).toBe(given.appPort);
        expect(given.server.scriptPort).toBe(given.scriptPort);
        await given.server.close();
        const chosen = await startRemoteControlServer({
            appPort: 0,
            scriptPort: 0,
            appWaitTimeoutMs: 1000,
            writeError: () => {},
        });
        assert(chosen.ok);
        expect(chosen.value.appPort).toBeGreaterThan(0);
        expect(chosen.value.scriptPort).toBeGreaterThan(0);
        expect(chosen.value.appPort).not.toBe(chosen.value.scriptPort);
        const script = await connectScript(chosen.value.scriptPort);
        const app = await connectApp(chosen.value.appPort);
        script.socket.write("over chosen ports\n");
        expect(await app.nextMessage()).toBe("over chosen ports");
        script.socket.destroy();
        app.socket.close();
        await chosen.value.close();
    });

    test("fails naming the port when a port is in use, and leaves the other port free", async () => {
        const busy = createServer();
        const busyPort = await freePort();
        assert((await listen(busy, busyPort)).ok);
        const appPort = await freePort();
        const started = await startRemoteControlServer({
            appPort,
            scriptPort: busyPort,
            appWaitTimeoutMs: 1000,
            writeError: () => {},
        });
        expect(started).toEqual({
            ok: false,
            error: {
                name: "PortInUse",
                port: busyPort,
            },
        });
        const free = createServer();
        expect((await listen(free, appPort)).ok).toBe(true);
        await closeServer(free);
        await closeServer(busy);
    });

    test("relays a script line to the app and the app's reply back to the script", async () => {
        const started = await startServer(1000);
        const app = await connectApp(started.appPort);
        const script = await connectScript(started.scriptPort);
        script.socket.write("{\"command\":\"ready\"}\n");
        expect(await app.nextMessage()).toBe("{\"command\":\"ready\"}");
        app.socket.send("{\"ok\":true}");
        expect(await script.nextLine()).toBe("{\"ok\":true}");
        expect(started.errors).toEqual([]);
        script.socket.destroy();
        app.socket.close();
        await started.server.close();
    });

    test("sends a line that came before the app connected once it connects", async () => {
        const started = await startServer(5000);
        const script = await connectScript(started.scriptPort);
        script.socket.write("first\n");
        await delay(50);
        const app = await connectApp(started.appPort);
        expect(await app.nextMessage()).toBe("first");
        app.socket.send("answer");
        expect(await script.nextLine()).toBe("answer");
        script.socket.destroy();
        app.socket.close();
        await started.server.close();
    });

    test("accepts a second app after the first disconnects", async () => {
        const started = await startServer(1000);
        const script = await connectScript(started.scriptPort);
        const first = await connectApp(started.appPort);
        first.socket.close();
        await closed(first.socket);
        const second = await connectApp(started.appPort);
        script.socket.write("to the second\n");
        expect(await second.nextMessage()).toBe("to the second");
        second.socket.send("from the second");
        expect(await script.nextLine()).toBe("from the second");
        expect(started.errors).toEqual([]);
        script.socket.destroy();
        second.socket.close();
        await started.server.close();
    });

    test("a new app replaces a connected one, whose unanswered line gets AppDisconnected", async () => {
        const started = await startServer(1000);
        const script = await connectScript(started.scriptPort);
        const first = await connectApp(started.appPort);
        script.socket.write("to the first\n");
        expect(await first.nextMessage()).toBe("to the first");
        const firstClosed = closed(first.socket);
        const second = await connectApp(started.appPort);
        await firstClosed;
        expect(await script.nextLine()).toBe("{\"ok\":false,\"error\":\"AppDisconnected\"}");
        script.socket.write("to the second\n");
        expect(await second.nextMessage()).toBe("to the second");
        second.socket.close();
        script.socket.destroy();
        await started.server.close();
    });

    test("answers AppNotConnected when no app connects within the wait", async () => {
        const started = await startServer(100);
        const script = await connectScript(started.scriptPort);
        script.socket.write("{\"command\":\"ready\"}\n");
        expect(await script.nextLine()).toBe("{\"ok\":false,\"error\":\"AppNotConnected\"}");
        expect(started.errors).toEqual([
            `No app connected to port ${started.appPort} within 100 ms, so this line got AppNotConnected: {"command":"ready"}`,
        ]);
        script.socket.destroy();
        await started.server.close();
    });

    test("answers AppDisconnected for a line the app was sent and did not answer before it went", async () => {
        const started = await startServer(1000);
        const app = await connectApp(started.appPort);
        const script = await connectScript(started.scriptPort);
        script.socket.write("quit\n");
        expect(await app.nextMessage()).toBe("quit");
        app.socket.close();
        expect(await script.nextLine()).toBe("{\"ok\":false,\"error\":\"AppDisconnected\"}");
        script.socket.destroy();
        await started.server.close();
    });

    test("drops the reply to a script that disconnected mid-command and serves the next script", async () => {
        const started = await startServer(1000);
        const app = await connectApp(started.appPort);
        const first = await connectScript(started.scriptPort);
        first.socket.write("slow\n");
        expect(await app.nextMessage()).toBe("slow");
        first.socket.destroy();
        await closed(first.socket);
        const second = await connectScript(started.scriptPort);
        app.socket.send("late reply");
        second.socket.write("next\n");
        expect(await app.nextMessage()).toBe("next");
        app.socket.send("reply to next");
        expect(await second.nextLine()).toBe("reply to next");
        expect(started.errors).toEqual([
            "The script that sent a line had gone when the app's reply came, so the reply was dropped: late reply",
        ]);
        second.socket.destroy();
        app.socket.close();
        await started.server.close();
    });

    test("a new script connection replaces a connected one, whose replies are dropped", async () => {
        const started = await startServer(1000);
        const app = await connectApp(started.appPort);
        const first = await connectScript(started.scriptPort);
        first.socket.write("from the first\n");
        expect(await app.nextMessage()).toBe("from the first");
        const firstClosed = closed(first.socket);
        const second = await connectScript(started.scriptPort);
        await firstClosed;
        app.socket.send("to the first");
        expect(await started.nextError()).toBe("The script that sent a line had gone when the app's reply came, so the reply was dropped: to the first");
        second.socket.write("from the second\n");
        expect(await app.nextMessage()).toBe("from the second");
        app.socket.send("to the second");
        expect(await second.nextLine()).toBe("to the second");
        second.socket.destroy();
        app.socket.close();
        await started.server.close();
    });

    test("reports and drops a binary message and a reply to no line", async () => {
        const started = await startServer(1000);
        const app = await connectApp(started.appPort);
        app.socket.send(Buffer.from([1, 2, 3]), {
            binary: true,
        });
        app.socket.send("unasked");
        expect(await started.nextError()).toBe("The app sent the remote control server a binary message. It sends text only, so the message was dropped.");
        expect(await started.nextError()).toBe("The app sent the remote control server a reply to no line it was sent, so it was dropped: unasked");
        app.socket.close();
        await started.server.close();
    });

    test("close ends both connections and frees both ports", async () => {
        const started = await startServer(1000);
        const app = await connectApp(started.appPort);
        const script = await connectScript(started.scriptPort);
        const appClosed = closed(app.socket);
        const scriptClosed = closed(script.socket);
        await started.server.close();
        await appClosed;
        await scriptClosed;
        for (const port of [started.appPort, started.scriptPort]) {
            const server = createServer();
            expect((await listen(server, port)).ok).toBe(true);
            await closeServer(server);
        }
    });
});

describe("receiveLine", () => {
    test("answers at once a line that would take the waiting lines past their limit", async () => {
        const started = await startServer(60_000);
        const script = await connectScript(started.scriptPort);
        script.socket.write("line\n".repeat(1001));
        expect(await script.nextLine()).toBe("{\"ok\":false,\"error\":\"AppNotConnected\"}");
        expect(await started.nextError()).toBe("The script sent more than 1000 lines while no app was connected, so this one was answered at once: line");
        script.socket.destroy();
        await started.server.close();
    });
});

describe("startRemoteControlServer failures and disconnects", () => {
    test("fails naming the app port when it is in use", async () => {
        const busy = createServer();
        const busyPort = await freePort();
        assert((await listen(busy, busyPort)).ok);
        const started = await startRemoteControlServer({
            appPort: busyPort,
            scriptPort: await freePort(),
            appWaitTimeoutMs: 1000,
            writeError: () => {},
        });
        expect(started).toEqual({
            ok: false,
            error: {
                name: "PortInUse",
                port: busyPort,
            },
        });
        await closeServer(busy);
    });

    test("forgets the lines a script left waiting when it disconnects", async () => {
        const started = await startServer(60_000);
        const first = await connectScript(started.scriptPort);
        first.socket.write("left behind\n");
        const firstClosed = closed(first.socket);
        const second = await connectScript(started.scriptPort);
        await firstClosed;
        second.socket.write("wanted\n");
        const app = await connectApp(started.appPort);
        expect(await app.nextMessage()).toBe("wanted");
        app.socket.send("reply");
        expect(await second.nextLine()).toBe("reply");
        second.socket.destroy();
        app.socket.close();
        await started.server.close();
    });
});

describe("writeToScript", () => {
    test("writes only to the connected script, and only while its connection is open", async () => {
        const started = await startServer(1000);
        const script = await connectScript(started.scriptPort);
        const other = new Socket();
        const state: IRelayState = {
            app: undefined,
            script: other,
            waiting: [],
            owed: [],
        };
        expect(writeToScript(state, script.socket, "text")).toBe(false);
        other.destroy();
        expect(writeToScript(state, other, "text")).toBe(false);
        script.socket.destroy();
        await started.server.close();
    });
});

describe("releaseScript", () => {
    test("leaves the state alone for a script that is not the connected one", () => {
        const connected = new Socket();
        const state: IRelayState = {
            app: undefined,
            script: connected,
            waiting: [],
            owed: [],
        };
        releaseScript(state, new Socket());
        expect(state.script).toBe(connected);
    });
});

describe("listen", () => {
    test("fails with ListenFailed for an error other than the port being in use", async () => {
        const server = createServer();
        const listened = await listen(server, 70000);
        expect(listened.ok).toBe(false);
        assert(!listened.ok);
        expect(listened.error.name).toBe("ListenFailed");
        expect(listened.error.port).toBe(70000);
    });
});

describe("closeServer", () => {
    test("resolves at once for a server that is not listening", async () => {
        await closeServer(createServer());
    });
});

describe("describeStartError", () => {
    test("names the port", () => {
        expect(describeStartError({
            name: "PortInUse",
            port: 4001,
        })).toBe("The remote control server could not listen on port 4001: another program is using it.");
        expect(describeStartError({
            name: "ListenFailed",
            port: 4002,
            message: "EACCES",
        })).toBe("The remote control server could not listen on port 4002: EACCES");
    });
});
