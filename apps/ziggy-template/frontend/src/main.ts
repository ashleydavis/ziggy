import type { IJsonValue } from "ziggy";
import { greetingLine, IAppEvent, IHelloWorldResponse, logLineForEvent } from "./lib/hello-world";
import { ITestCommand, performTestCommand, testResultToJson } from "./lib/test-commands";

//
// The event the hello-world task sends while it runs.
//
interface IOutputEvent {
    // Always "output".
    type: "output";

    // The text to show.
    text: string;
}

//
// Finds an element of the page by its data-id, and fails when there is none.
//
function element(dataId: string): HTMLElement {
    const found = document.querySelector<HTMLElement>(`[data-id="${dataId}"]`);
    if (!found) {
        throw new Error(`The page has no element with data-id ${dataId}.`);
    }
    return found;
}

//
// Writes a line at the end of the log, and scrolls it so the line can be seen.
//
function log(line: string): void {
    const logElement = element("log");
    logElement.textContent += `${line}\n`;
    logElement.scrollTop = logElement.scrollHeight;
}

//
// Sends the backend the hello-world message when its button is pressed, and logs the message response, or the error when there is
// one.
//
function listenForTheMessageButton(): void {
    element("send-message").addEventListener("click", async () => {
        try {
            const response = await window.ziggy.invoke<IHelloWorldResponse>("hello-world", {
                name: "world",
            });
            log(greetingLine(response));
        }
        catch (error) {
            log(`The backend did not answer: ${(error as Error).message}`);
        }
    });
}

//
// Starts the hello-world task when its button is pressed, and logs what the task sends and how it ends.
//
function listenForTheTask(): void {
    let nextTaskNumber = 1;
    element("start-task").addEventListener("click", () => {
        const data: IJsonValue = null;
        window.ziggy.addTask({
            taskId: `hello-world-task-${nextTaskNumber++}`,
            taskType: "hello-world-task",
            source: "hello-world",
            data,
            priority: "interactive",
        });
    });
    window.ziggy.onTaskEvent<IOutputEvent>(event => {
        log(event.data.text);
    });
    window.ziggy.onTaskCompleted(event => {
        log(`The task ended: ${event.result.status}`);
    });
}

//
// Logs what the Hello menu's items lead to: the event Say Hello From Zig's Zig function sends, and the menu event Say Hello From
// the UI reaches the frontend as.
//
function listenForTheMenu(): void {
    window.ziggy.onEvent<IAppEvent>(event => {
        const line = logLineForEvent(event);
        if (line !== null) {
            log(line);
        }
    });
}

//
// Handles the commands the test control connection forwards, which the smoke tests send. It does nothing unless the native app
// started the frontend in test mode, which it does only in a build with the test hooks, and it tells the backend when it is
// listening so that no command is sent before it can be heard.
//
function listenForTestCommands(): void {
    if (new URLSearchParams(window.location.search).get("testMode") !== "1") {
        return;
    }
    window.ziggy.onTestCommand<ITestCommand>(async event => {
        const finder = {
            find: (dataId: string) => document.querySelector<HTMLElement>(`[data-id="${dataId}"]`) as HTMLInputElement | null,
        };
        await window.ziggy.sendTestResult(event.requestId, testResultToJson(performTestCommand(finder, event.command)));
    });
    window.ziggy.testUiReady();
}

listenForTheMessageButton();
listenForTheTask();
listenForTheMenu();
listenForTestCommands();
