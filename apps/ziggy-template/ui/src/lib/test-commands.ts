import type { IJsonObject } from "ziggy";

//
// The commands the test control connection forwards to the UI, performed on the UI's DOM by data-id. The UI
// replies to each with a result. These exist only so the smoke tests can drive the real app, and the backend sends them only in
// a test hooks build.
//

//
// A command from the test control connection.
//
export interface ITestCommand {
    // What to do: ready, click, type, get-value, get-text, exists, insert, viewport or drop-file.
    command: string;

    // The data-id of the element to act on.
    dataId?: string;

    // The text to type, for the type command.
    text?: string;

    // The name of the file to drop, for the drop-file command.
    fileName?: string;

    // The size in bytes of the file to drop, for the drop-file command.
    fileSize?: number;
}

//
// What the UI replies to a command with.
//
export interface ITestResult {
    // Whether the command succeeded.
    ok: boolean;

    // The value or text read, for the get commands.
    value?: string;

    // Why the command failed, when it did.
    error?: string;
}

//
// What a command needs to find and act on elements. The UI gives the real document and a test gives a stand-in.
//
export interface IElementFinder {
    // Finds the element with the data-id, or null.
    find(dataId: string): IFoundElement | null;
}

//
// An element a command can act on.
//
export interface IFoundElement {
    // The element's text.
    textContent: string | null;

    // The element's value, when it is a control with one.
    value?: string;

    // Clicks the element.
    click(): void;

    // Gives the element the keyboard focus.
    focus(): void;

    // Dispatches an event on the element.
    dispatchEvent(event: Event): boolean;
}

//
// Performs one test command and returns its result. An unknown command or a missing element is a failure with a reason,
// never a silent success.
//
export function performTestCommand(finder: IElementFinder, command: ITestCommand): ITestResult {
    if (command.command === "ready") {
        return { ok: true };
    }
    if (command.dataId === undefined) {
        return { ok: false, error: `The ${command.command} command needs a dataId.` };
    }
    const element = finder.find(command.dataId);
    if (command.command === "exists") {
        return { ok: element !== null };
    }
    if (element === null) {
        return { ok: false, error: `No element has the data-id ${command.dataId}.` };
    }
    if (command.command === "click") {
        element.click();
        return { ok: true };
    }
    if (command.command === "type") {
        if (command.text === undefined) {
            return { ok: false, error: "The type command needs text." };
        }
        element.value = command.text;
        element.dispatchEvent(new Event("input", { bubbles: true }));
        return { ok: true };
    }
    if (command.command === "get-value") {
        return { ok: true, value: element.value ?? "" };
    }
    if (command.command === "get-text") {
        return { ok: true, value: element.textContent ?? "" };
    }
    return { ok: false, error: `Unknown test command ${command.command}.` };
}

//
// Converts a result to the JSON the UI sends back with window.ziggy.sendTestResult. A field with no value is left out.
//
export function testResultToJson(result: ITestResult): IJsonObject {
    const json: IJsonObject = { ok: result.ok };
    if (result.value !== undefined) {
        json.value = result.value;
    }
    if (result.error !== undefined) {
        json.error = result.error;
    }
    return json;
}

