//
// Checks the command line is read into the two ports, and that every way of getting it wrong is refused with an error that
// names the option at fault. Each test calls the parser with a command line and compares the result.
//

import { describeArgumentsError, parseArguments, parsePort } from "../../lib/arguments";

describe("parseArguments", () => {
    test("reads both ports in either order", () => {
        expect(parseArguments(["--app-port", "4001", "--script-port", "4002"])).toEqual({
            ok: true,
            value: {
                appPort: 4001,
                scriptPort: 4002,
            },
        });
        expect(parseArguments(["--script-port", "4002", "--app-port", "4001"])).toEqual({
            ok: true,
            value: {
                appPort: 4001,
                scriptPort: 4002,
            },
        });
    });

    test("refuses an option it does not know", () => {
        expect(parseArguments(["--verbose"])).toEqual({
            ok: false,
            error: {
                name: "UnknownOption",
                option: "--verbose",
            },
        });
    });

    test("refuses an option with no value after it", () => {
        expect(parseArguments(["--app-port", "4001", "--script-port"])).toEqual({
            ok: false,
            error: {
                name: "MissingValue",
                option: "--script-port",
            },
        });
    });

    test("refuses a port that is not a port", () => {
        expect(parseArguments(["--app-port", "70000", "--script-port", "4002"])).toEqual({
            ok: false,
            error: {
                name: "BadPort",
                option: "--app-port",
                value: "70000",
            },
        });
    });

    test("takes 0 for both ports, and refuses the same port other than 0 for the app and the script", () => {
        expect(parseArguments(["--app-port", "0", "--script-port", "0"])).toEqual({
            ok: true,
            value: {
                appPort: 0,
                scriptPort: 0,
            },
        });
        expect(parseArguments(["--app-port", "4001", "--script-port", "4001"])).toEqual({
            ok: false,
            error: {
                name: "SamePort",
                port: 4001,
            },
        });
    });

    test("refuses a command line without both ports", () => {
        expect(parseArguments(["--script-port", "4002"])).toEqual({
            ok: false,
            error: {
                name: "MissingOption",
                option: "--app-port",
            },
        });
        expect(parseArguments(["--app-port", "4001"])).toEqual({
            ok: false,
            error: {
                name: "MissingOption",
                option: "--script-port",
            },
        });
    });
});

describe("parsePort", () => {
    test("reads a port up to 65535", () => {
        expect(parsePort("1")).toBe(1);
        expect(parsePort("65535")).toBe(65535);
    });

    test("reads 0, which lets the system choose a port", () => {
        expect(parsePort("0")).toBe(0);
    });

    test("refuses a port too high and text that is not a whole number", () => {
        expect(parsePort("65536")).toBeUndefined();
        expect(parsePort("-1")).toBeUndefined();
        expect(parsePort("12.5")).toBeUndefined();
        expect(parsePort("")).toBeUndefined();
        expect(parsePort("port")).toBeUndefined();
    });
});

describe("describeArgumentsError", () => {
    test("names the option at fault and gives the usage", () => {
        expect(describeArgumentsError({
            name: "UnknownOption",
            option: "--verbose",
        })).toBe('Unknown option "--verbose". Usage: ziggy-remote-control-server --app-port <port> --script-port <port>.');
        expect(describeArgumentsError({
            name: "MissingValue",
            option: "--app-port",
        })).toContain("The option --app-port needs a port after it.");
        expect(describeArgumentsError({
            name: "BadPort",
            option: "--script-port",
            value: "x",
        })).toContain('The --script-port value "x" is not a port from 0 to 65535.');
        expect(describeArgumentsError({
            name: "MissingOption",
            option: "--script-port",
        })).toContain("The option --script-port is required.");
        expect(describeArgumentsError({
            name: "SamePort",
            port: 4001,
        })).toContain("The app and the script need a port each, but both were given port 4001.");
    });
});
