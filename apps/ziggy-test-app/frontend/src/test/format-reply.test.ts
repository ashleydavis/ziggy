import { formatConfigProblem, formatPingReply, formatSettingValue } from "../lib/format-reply";

describe("formatPingReply", () => {
    test("shows the Zig version, platform and the echoed greeting", () => {
        const text = formatPingReply({
            zigVersion: "0.16.0",
            os: "linux",
            arch: "x86_64",
            echo: { greeting: "hi" },
        });
        expect(text).toBe("Zig 0.16.0 on linux x86_64 says: hi");
    });
});

describe("formatSettingValue", () => {
    test("writes a string as it is", () => {
        expect(formatSettingValue("config", "blue")).toBe("config: blue");
    });

    test("writes any other value as its JSON", () => {
        expect(formatSettingValue("state", 3)).toBe("state: 3");
        expect(formatSettingValue("state", { open: true })).toBe("state: {\"open\":true}");
    });

    test("writes none for null and undefined", () => {
        expect(formatSettingValue("config", null)).toBe("config: none");
        expect(formatSettingValue("config", undefined)).toBe("config: none");
    });
});

describe("formatConfigProblem", () => {
    test("writes the line and the reason", () => {
        expect(formatConfigProblem({ path: "config.toml", line: 4, column: 1, reason: "bad value" })).toBe("problem: line 4: bad value");
    });

    test("writes none when there is no problem", () => {
        expect(formatConfigProblem(undefined)).toBe("problem: none");
    });
});
