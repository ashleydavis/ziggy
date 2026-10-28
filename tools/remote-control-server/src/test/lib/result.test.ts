//
// Checks that ok and err make the success and the failure a caller tells apart by the ok field.
//

import { err, ok } from "../../lib/result";

describe("ok", () => {
    test("makes a success carrying the value", () => {
        expect(ok(5)).toEqual({
            ok: true,
            value: 5,
        });
    });
});

describe("err", () => {
    test("makes a failure carrying the error", () => {
        expect(err({
            name: "Broken",
        })).toEqual({
            ok: false,
            error: {
                name: "Broken",
            },
        });
    });
});
