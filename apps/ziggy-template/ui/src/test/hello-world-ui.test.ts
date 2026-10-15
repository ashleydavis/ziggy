//
// Hello world example: change it into your own tests, or delete it.
//

import { greetingLine } from "../lib/hello-world-ui";

test("the greeting line shows what the backend said", () => {
    expect(greetingLine({
        greeting: "Hello world, from Zig on linux",
    })).toBe("The backend says: Hello world, from Zig on linux");
});
