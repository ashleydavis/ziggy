import type { IConfigProblem, IJsonValue } from "ziggy";

//
// The message response the test app's ping message gets.
//
export interface IPingReply {
    // The Zig version the backend was built with.
    zigVersion: string;

    // The operating system the backend was built for.
    os: string;

    // The CPU architecture the backend was built for.
    arch: string;

    // What the frontend sent, echoed back.
    echo: { greeting: string };
}

//
// Formats the ping reply for display in the frontend.
//
export function formatPingReply(reply: IPingReply): string {
    return `Zig ${reply.zigVersion} on ${reply.os} ${reply.arch} says: ${reply.echo.greeting}`;
}

//
// Formats a value read from the config or state file: a string is written as it is, any other value as its JSON, and undefined or null
// as "none".
//
export function formatSettingValue(label: string, value: IJsonValue | undefined): string {
    if (value === undefined || value === null) {
        return `${label}: none`;
    }
    if (typeof value === "string") {
        return `${label}: ${value}`;
    }
    return `${label}: ${JSON.stringify(value)}`;
}

//
// Formats the problem the config file has, or says that it has none.
//
export function formatConfigProblem(problem: IConfigProblem | undefined): string {
    if (problem === undefined) {
        return "problem: none";
    }
    return `problem: line ${problem.line}: ${problem.reason}`;
}
