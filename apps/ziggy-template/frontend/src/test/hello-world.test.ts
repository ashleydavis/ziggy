//
// Hello world example: change it into your own tests, or delete it.
//

import { greetingLine, logLineForEvent } from "../lib/hello-world";

test("the greeting line shows what the backend said", () => {
    expect(greetingLine({
        greeting: "Hello world, from Zig on linux",
    })).toBe("The backend says: Hello world, from Zig on linux");
});

test("the hello-from-zig event is logged as the text the Zig function sent", () => {
    expect(logLineForEvent({
        type: "hello-from-zig",
        text: "Hello from Zig, run from the menu",
    })).toBe("Hello from Zig, run from the menu");
});

test("the Say Hello From the UI menu item is logged by the UI", () => {
    expect(logLineForEvent({
        type: "menu",
        item: "hello-from-ui",
    })).toBe("Hello from the UI, run from the menu");
});

test("a menu item the UI does not know is not logged", () => {
    expect(logLineForEvent({
        type: "menu",
        item: "something-else",
    })).toBeNull();
});
