//
// Checks that text arriving in chunks is cut into the lines it was written as, whatever the chunks' boundaries. Each test
// feeds chunks through splitLines as the server does and compares the lines and the text left over.
//

import { splitLines } from "../../lib/lines";

describe("splitLines", () => {
    test("cuts a chunk of whole lines into lines and leaves nothing over", () => {
        expect(splitLines("", "one\ntwo\n")).toEqual({
            lines: [
                "one",
                "two",
            ],
            rest: "",
        });
    });

    test("keeps an unfinished line until the chunk that ends it", () => {
        const first = splitLines("", "{\"command\":");
        expect(first).toEqual({
            lines: [],
            rest: "{\"command\":",
        });
        const second = splitLines(first.rest, "\"ready\"}\nnext");
        expect(second).toEqual({
            lines: [
                "{\"command\":\"ready\"}",
            ],
            rest: "next",
        });
    });

    test("gives an empty line for two newlines in a row", () => {
        expect(splitLines("", "\n\n")).toEqual({
            lines: [
                "",
                "",
            ],
            rest: "",
        });
    });
});
