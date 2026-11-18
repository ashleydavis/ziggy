import type { IJsonValue } from "ziggy";
import { greetingLine, IAppEvent, IHelloWorldResponse, logLineForEvent } from "./lib/hello-world";
import { installSplashScreen } from "./lib/splash";
import { ITestCommand, performTestCommand, testResultToJson } from "./lib/test-commands";

const splash = installSplashScreen(document, {
    background: "#FFFFFF",
    minimumDisplayMilliseconds: 2000,
    fadeDurationMilliseconds: 2000,
});
window.ziggy.onEvent((event: { type?: string } | null) => {
    if (event !== null && event.type === "frontend-visible") {
        splash.remove();
    }
});

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
// The handler of the template's action Say Hello From an Action, which its Hello menu item, its shortcut and the "Say hello from an
// action" button all run: it logs a line.
//
function helloFromAction(): void {
    log("Hello from an action");
}

//
// Registers the handlers of the template's actions.
//
function registerActions(): void {
    window.ziggy.registerAction("hello-from-action", helloFromAction);
    window.ziggy.registerAction("new-window", openNewWindow);
}

//
// The handler of the template's action New Window: opens another window of the template as a process of its own, and logs why when
// it does not open.
//
function openNewWindow(): Promise<void> {
    return window.ziggy.newWindow([]).catch((error: Error) => {
        log(`The new window did not open: ${error.message}`);
    });
}

//
// Has the "Say hello from an action" button run the action by its name, and shows why when it does not run.
//
function listenForTheActionButton(): void {
    element("run-hello-action").addEventListener("click", () => {
        window.ziggy.runAction("hello-from-action").catch((error: Error) => {
            log(`The action did not run: ${error.message}`);
        });
    });
}

//
// Shows the theme setting in the dropdown and applies it to the page. The setting is Ziggy's, read and written through the config
// system.
//
function listenForTheme(): void {
    const mediaTheme = window.matchMedia("(prefers-color-scheme: dark)");
    const select = element("theme-select") as HTMLSelectElement;
    const showSetting = async (): Promise<void> => {
        const setting = await window.ziggy.getConfig<string>("theme");
        const current = setting === "light" || setting === "dark" ? setting : "system";
        select.value = current;
        const system = await window.ziggy.getSystemTheme();
        const effective = current === "system" ? system : current;
        document.documentElement.dataset.themeSetting = effective;
        document.documentElement.style.colorScheme = effective;
        element("theme-setting").textContent = current;
    };
    const showSettingOrError = (): void => {
        showSetting().catch((error: Error) => {
            element("theme-setting").textContent = `theme: ${error.message}`;
        });
    };
    showSettingOrError();
    mediaTheme.addEventListener("change", showSettingOrError);
    window.ziggy.onConfigChanged(event => {
        if (event.path === "theme") {
            showSettingOrError();
        }
    });
    select.addEventListener("change", () => {
        window.ziggy.setConfig("theme", select.value).catch((error: Error) => {
            element("theme-setting").textContent = `theme not set: ${error.message}`;
        });
    });
}

//
// Handles the commands the remote control connection forwards, which the smoke tests send. It does nothing unless the native app
// started the frontend in test mode, which it does only when the app was started with --remote-control, and it tells the backend when it is
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
registerActions();
listenForTheActionButton();
listenForTheme();
listenForTestCommands();
window.ziggy.frontendReady();
