import type { IJsonValue, ITaskCompletedEvent, ITaskMessageEvent } from "ziggy-ui";
import { greetingLine, IHelloWorldResponse } from "./lib/hello-world-ui";
import { ITestCommand, performTestCommand, testResultToJson } from "./lib/test-commands";

//
// The message the hello-world task sends while it runs.
//
interface IOutputMessage {
    // Always "output".
    type: "output";

    // The text to show.
    text: string;
}

//
// A command from the test control connection, with the id the answer must carry.
//
interface ITestCommandEvent {
    // Identifies the command so its answer reaches the right waiting connection.
    requestId: number;

    // The command to perform.
    command: ITestCommand;
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
// Sends the backend the hello-world message and shows its answer.
//
async function sayHello(): Promise<void> {
    const response = await window.ziggy.invoke<IHelloWorldResponse>("hello-world", {
        name: "world",
    });
    element("greeting").textContent = greetingLine(response);
}

//
// Starts the hello-world task when its button is pressed, and shows what the task sends and how it ends.
//
function listenForTheTask(): void {
    let nextTaskNumber = 1;
    element("start-task").addEventListener("click", () => {
        const data: IJsonValue = null;
        window.ziggy.send("add-task", {
            taskId: `hello-world-task-${nextTaskNumber++}`,
            taskType: "hello-world-task",
            source: "hello-world",
            data,
            priority: "interactive",
        });
    });
    window.ziggy.onMessage<ITaskMessageEvent<IOutputMessage>>("task-message", event => {
        element("task-output").textContent += `${event.message.text}\n`;
    });
    window.ziggy.onMessage<ITaskCompletedEvent>("task-completed", event => {
        element("task-output").textContent += `The task ended: ${event.result.status}\n`;
    });
}

//
// Answers the commands the test control connection forwards, which the smoke tests send. It does nothing unless the native app
// started the UI in test mode, which it does only in a build with the test hooks, and it tells the backend when it is listening so
// that no command is sent before it can be heard.
//
function listenForTestCommands(): void {
    if (new URLSearchParams(window.location.search).get("testMode") !== "1") {
        return;
    }
    window.ziggy.onMessage<ITestCommandEvent>("test-command", async event => {
        const finder = {
            find: (dataId: string) => document.querySelector<HTMLElement>(`[data-id="${dataId}"]`) as HTMLInputElement | null,
        };
        await window.ziggy.invoke<IJsonValue>("test-result", {
            requestId: event.requestId,
            result: testResultToJson(performTestCommand(finder, event.command)),
        });
    });
    window.ziggy.send("test-ui-ready", null);
}

listenForTheTask();
listenForTestCommands();
sayHello().catch(error => {
    element("greeting").textContent = `The backend did not answer: ${(error as Error).message}`;
});
