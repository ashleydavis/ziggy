#!/usr/bin/env bun
//
// The ziggy-remote-control-server program: starts the remote control server on the ports its command line gives and runs
// until its stdin closes or it receives SIGTERM. A test starts it with a stdin it holds open, so the server ends with the
// test even when the test is killed. See README.md beside this package.
//

import { describeArgumentsError, parseArguments } from "./lib/arguments";
import { describeStartError, startRemoteControlServer } from "./lib/remote-control-server";

//
// How long a script line waits for the app to connect. The app connects once it has started, which takes longest on an
// Android emulator on a busy CI machine, where a start has taken most of a minute.
//
const APP_WAIT_TIMEOUT_MS = 90_000;

//
// Writes a line to stderr, which the test keeps in the server's log.
//
export function writeError(message: string): void {
    process.stderr.write(`${message}\n`);
}

//
// Resolves when stdin ends or SIGTERM arrives, whichever comes first.
//
export function waitForStop(): Promise<void> {
    return new Promise(resolve => {
        process.stdin.on("end", () => {
            resolve();
        });
        process.stdin.on("close", () => {
            resolve();
        });
        process.on("SIGTERM", () => {
            resolve();
        });
        process.stdin.resume();
    });
}

//
// Runs the server and returns the exit code.
//
export async function main(args: string[]): Promise<number> {
    const parsed = parseArguments(args);
    if (!parsed.ok) {
        writeError(describeArgumentsError(parsed.error));
        return 2;
    }
    const started = await startRemoteControlServer({
        appPort: parsed.value.appPort,
        scriptPort: parsed.value.scriptPort,
        appWaitTimeoutMs: APP_WAIT_TIMEOUT_MS,
        writeError,
    });
    if (!started.ok) {
        writeError(describeStartError(started.error));
        return 1;
    }
    // The test that started the server reads the ports from this line, which matters when it gave 0 and the system chose them.
    process.stderr.write(`The remote control server is listening: the app on 127.0.0.1:${started.value.appPort}, the script on 127.0.0.1:${started.value.scriptPort}.\n`);
    await waitForStop();
    await started.value.close();
    return 0;
}

main(process.argv.slice(2))
    .then(code => {
        process.exit(code);
    })
    .catch(error => {
        writeError(`The remote control server failed: ${error instanceof Error ? error.stack : String(error)}`);
        process.exit(1);
    });
