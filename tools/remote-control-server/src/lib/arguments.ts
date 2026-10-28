//
// Reads the remote control server's command line: `--app-port <n> --script-port <n>`. Both are required. A port of 0 lets the
// system choose a free one, which the server reports when it is listening.
//

import { err, ok } from "./result";
import type { Result } from "./result";

//
// The ports the command line gives.
//
export interface IArguments {
    //
    // The loopback port the app's WebSocket connection comes to.
    //
    appPort: number;

    //
    // The loopback port the test script's TCP connection comes to.
    //
    scriptPort: number;
}

//
// An option the server does not know.
//
export interface IUnknownOptionError {
    //
    // Which error this is.
    //
    name: "UnknownOption";

    //
    // The option as it was written.
    //
    option: string;
}

//
// An option given as the last argument, with no value after it.
//
export interface IMissingValueError {
    //
    // Which error this is.
    //
    name: "MissingValue";

    //
    // The option that has no value.
    //
    option: string;
}

//
// A port that is not a whole number from 0 to 65535.
//
export interface IBadPortError {
    //
    // Which error this is.
    //
    name: "BadPort";

    //
    // The option the port was given for.
    //
    option: string;

    //
    // The value as it was written.
    //
    value: string;
}

//
// A required option that was not given.
//
export interface IMissingOptionError {
    //
    // Which error this is.
    //
    name: "MissingOption";

    //
    // The option that is missing.
    //
    option: string;
}

//
// The same port, other than 0, given for the app and the script, which cannot both listen on it.
//
export interface ISamePortError {
    //
    // Which error this is.
    //
    name: "SamePort";

    //
    // The port given for both.
    //
    port: number;
}

//
// Every way the command line can be wrong.
//
export type ArgumentsError = IUnknownOptionError | IMissingValueError | IBadPortError | IMissingOptionError | ISamePortError;

//
// The highest TCP port number.
//
const PORT_MAX = 65535;

//
// Reads the command line, not counting the program's name.
//
export function parseArguments(args: string[]): Result<IArguments, ArgumentsError> {
    let appPort: number | undefined;
    let scriptPort: number | undefined;
    let index = 0;
    while (index < args.length) {
        const option = args[index];
        if (option !== "--app-port" && option !== "--script-port") {
            return err({
                name: "UnknownOption",
                option,
            });
        }
        if (index + 1 >= args.length) {
            return err({
                name: "MissingValue",
                option,
            });
        }
        const port = parsePort(args[index + 1]);
        if (port === undefined) {
            return err({
                name: "BadPort",
                option,
                value: args[index + 1],
            });
        }
        if (option === "--app-port") {
            appPort = port;
        }
        else {
            scriptPort = port;
        }
        index += 2;
    }
    if (appPort === undefined) {
        return err({
            name: "MissingOption",
            option: "--app-port",
        });
    }
    if (scriptPort === undefined) {
        return err({
            name: "MissingOption",
            option: "--script-port",
        });
    }
    if (appPort === scriptPort && appPort !== 0) {
        return err({
            name: "SamePort",
            port: appPort,
        });
    }
    return ok({
        appPort,
        scriptPort,
    });
}

//
// The port the text names, or undefined when it is not a whole number from 0 to 65535. Port 0 lets the system choose a free
// port.
//
export function parsePort(text: string): number | undefined {
    if (!/^[0-9]+$/.test(text)) {
        return undefined;
    }
    const port = Number(text);
    if (port > PORT_MAX) {
        return undefined;
    }
    return port;
}

//
// The error as a sentence for the person who ran the server.
//
export function describeArgumentsError(error: ArgumentsError): string {
    const usage = "Usage: ziggy-remote-control-server --app-port <port> --script-port <port>.";
    switch (error.name) {
        case "UnknownOption": {
            return `Unknown option "${error.option}". ${usage}`;
        }
        case "MissingValue": {
            return `The option ${error.option} needs a port after it. ${usage}`;
        }
        case "BadPort": {
            return `The ${error.option} value "${error.value}" is not a port from 0 to ${PORT_MAX}. ${usage}`;
        }
        case "MissingOption": {
            return `The option ${error.option} is required. ${usage}`;
        }
        case "SamePort": {
            return `The app and the script need a port each, but both were given port ${error.port}. ${usage}`;
        }
    }
}
