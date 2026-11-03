import { aboutText, buttonForMenuAction, formatActionList } from "../lib/menu-actions";

describe("buttonForMenuAction", () => {
    test("each task action presses the button of the same task", () => {
        expect(buttonForMenuAction("start-short")).toBe("start-short");
        expect(buttonForMenuAction("start-long")).toBe("start-long");
        expect(buttonForMenuAction("start-many")).toBe("start-many");
    });

    test("cancel presses the cancel button", () => {
        expect(buttonForMenuAction("cancel-long")).toBe("cancel-source");
    });

    test("an action with no button, and an unknown one, press nothing", () => {
        expect(buttonForMenuAction("about")).toBeNull();
        expect(buttonForMenuAction("nonsense")).toBeNull();
    });

    test("the about text names the app", () => {
        expect(aboutText).toContain("Ziggy test app");
    });
});

describe("formatActionList", () => {
    test("each action is a line of its name, its label and its shortcut, or none", () => {
        expect(formatActionList([
            {
                name: "say-action",
                label: "Say From an Action",
                shortcut: "Ctrl+5",
            },
            {
                name: "quit",
                label: "Quit",
                shortcut: null,
            },
        ])).toBe("say-action Say From an Action Ctrl+5\nquit Quit none");
    });

    test("no actions is no lines", () => {
        expect(formatActionList([])).toBe("");
    });
});
