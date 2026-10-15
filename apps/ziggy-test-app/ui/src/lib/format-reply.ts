//
// The reply the test app's ping channel gives.
//
export interface IPingReply {
    // The Zig version the backend was built with.
    zigVersion: string;

    // The operating system the backend was built for.
    os: string;

    // The CPU architecture the backend was built for.
    arch: string;

    // What the UI sent, echoed back.
    echo: { greeting: string };
}

//
// Formats the ping reply for display in the UI.
//
export function formatPingReply(reply: IPingReply): string {
    return `Zig ${reply.zigVersion} on ${reply.os} ${reply.arch} says: ${reply.echo.greeting}`;
}
