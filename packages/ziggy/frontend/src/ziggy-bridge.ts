//
// The frontend's view of Ziggy: the methods every native app exposes as window.ziggy, and the JSON types messages are made of.
//

//
// A JSON object.
//
export interface IJsonObject {
    [key: string]: IJsonValue;
}

//
// Any JSON value.
//
export type IJsonValue = string | number | boolean | null | IJsonValue[] | IJsonObject;

//
// Called with the data of an event the core sends.
//
export type IMessageCallback<TData> = (data: TData) => void;

//
// What a task-event event carries: an event a task sent while it ran.
//
export interface ITaskEvent<TData> {
    // The task that sent the event.
    taskId: string;

    // The source the task was queued under.
    source: string;

    // The event the task sent.
    data: TData;
}

//
// Why a task failed, inside its result.
//
export interface ITaskError {
    // The text of the error: the Zig error's name, the text the app's describe_error gave, or "Cancelled".
    message: string;
}

//
// The result of a task inside a task-completed event.
//
export interface ITaskResult {
    // The task that ended.
    taskId: string;

    // How it ended. A cancelled task is reported as failed with the error message "Cancelled".
    status: "succeeded" | "failed";

    // Why it failed, when it did.
    errorMessage?: string;

    // The same text as errorMessage, as an object, when it failed.
    error?: ITaskError;

    // What it returned, when it succeeded with a result.
    outputs?: IJsonValue;

    // The task type.
    type: string;

    // The data the task was queued with.
    inputs: IJsonValue;
}

//
// What a task-completed event carries.
//
export interface ITaskCompletedEvent {
    // The task that ended.
    taskId: string;

    // The full result of the task.
    result: ITaskResult;
}

//
// The app event the onEvent listeners receive when a menu item that runs in the frontend (a `.ui` item of the app's menu) is
// chosen.
//
export interface IMenuEvent {
    // Always "menu": the one event type Ziggy sends among the app's own events.
    type: "menu";

    // The item's name, as the app's menu names it.
    item: string;
}

//
// What a core-error event carries: a message failed and had no message response to carry the error.
//
export interface ICoreErrorEvent {
    // The error's name, or the text the app's describe_error gave for it.
    error: string;
}

//
// What a test-command event carries, in a test hooks build only: a command from the test control connection for the frontend
// to perform.
//
export interface ITestCommandEvent<TCommand> {
    // Identifies the command, so the result the frontend sends with sendTestResult reaches the connection waiting for it.
    requestId: number;

    // The command to perform.
    command: TCommand;
}

//
// What the core answers getPlatform with.
//
export interface IPlatformInfo {
    // Whether the app is on a desktop or on a mobile device.
    platformKind: "desktop" | "mobile";

    // The operating system's name as Zig spells it, such as "linux", "windows", "macos" or "ios". Android reports "linux".
    os: string;

    // The processor architecture's name as Zig spells it, such as "x86_64" or "aarch64".
    arch: string;
}

//
// The level of a line the frontend writes to the backend's log with log.
//
export type LogLevel = "info" | "verbose" | "error" | "exception" | "warn" | "debug" | "tool" | "event";

//
// What a tool wrote, for a line of the tool level written with log.
//
export interface IToolOutput {
    // What the tool wrote to its standard output.
    stdout?: string;

    // What the tool wrote to its standard error.
    stderr?: string;
}

//
// A task for addTask to queue.
//
export interface IAddTask {
    // The id the frontend gives the task. The task's events carry it.
    taskId: string;

    // The task type: the name the task's handler is registered under.
    taskType: string;

    // The group the task belongs to, which cancelTasks cancels together.
    source: string;

    // The task's input, which its handler is given.
    data: IJsonValue;

    // "interactive" for work the user is waiting on, which runs before the rest, or "background". Left out, it is background.
    priority?: "interactive" | "background";
}

//
// What every native app injects into the frontend as window.ziggy. Nothing wider than these methods is exposed, and the
// web view's own native handle is never used by the frontend directly.
//
export interface IZiggyBridge {
    // The app calls. These send app messages ({ kind: "app" } on the wire), which reach the app's own handlers, and receive app
    // events. They are all an app has for its own messages.

    //
    // Sends a message of the app's own, which the app's message handler receives and dispatches on its name, and resolves with the
    // data of its message response, or rejects with the error it ended with. The name must not be empty: the core refuses a message
    // without one with MissingMessageName. The data is the app's own to lay out.
    //
    invoke<TResponse>(name: string, data: IJsonValue): Promise<TResponse>;

    //
    // Sends a message of the app's own, by name, that gets no message response. The name must not be empty: the core reports a
    // message without one as a core-error event naming MissingMessageName.
    //
    send(name: string, data: IJsonValue): void;

    //
    // Registers a callback for every event of the app's own the backend sends and for each menu item that runs in the frontend,
    // as an IMenuEvent. Ziggy's own events never reach it.
    //
    onEvent<TData>(callback: IMessageCallback<TData>): void;

    //
    // Removes a callback onEvent registered.
    //
    removeEventListener<TData>(callback: IMessageCallback<TData>): void;

    // Ziggy's own calls. These send system messages ({ kind: "system" } on the wire), which Ziggy handles itself and the app's
    // handlers never see, and receive system events. Each names its own system message: there is no call that sends any other.

    //
    // Resolves with what the backend reports about the platform the app runs on.
    //
    getPlatform(): Promise<IPlatformInfo>;

    //
    // Queues a task. There is no message response: the task's events report what became of it, and a task that could not be queued is
    // reported as a core-error event.
    //
    addTask(task: IAddTask): void;

    //
    // Cancels every task queued under the source, children included.
    //
    cancelTasks(source: string): void;

    //
    // Writes a line to the backend's log, tagged Frontend: to its log files when it has a file log, else to its console. For the
    // exception level, errorText is the text of the error. For the tool level, message is the tool's name and toolOutput what it
    // wrote. A level the core does not know is reported as a core-error event.
    //
    log(level: LogLevel, message: string, errorText?: string, toolOutput?: IToolOutput): void;

    //
    // Registers a callback for the events tasks send while they run.
    //
    onTaskEvent<TData>(callback: IMessageCallback<ITaskEvent<TData>>): void;

    //
    // Removes a callback onTaskEvent registered.
    //
    removeTaskEventListener<TData>(callback: IMessageCallback<ITaskEvent<TData>>): void;

    //
    // Registers a callback for the end of each task the frontend queued.
    //
    onTaskCompleted(callback: IMessageCallback<ITaskCompletedEvent>): void;

    //
    // Removes a callback onTaskCompleted registered.
    //
    removeTaskCompletedListener(callback: IMessageCallback<ITaskCompletedEvent>): void;

    //
    // Registers a callback for a message that failed with no message response to carry the error. With no callback registered,
    // the error is logged to the console.
    //
    onCoreError(callback: IMessageCallback<ICoreErrorEvent>): void;

    //
    // Removes a callback onCoreError registered.
    //
    removeCoreErrorListener(callback: IMessageCallback<ICoreErrorEvent>): void;

    //
    // Registers a callback for the commands of the test control connection. Test hooks builds only.
    //
    onTestCommand<TCommand>(callback: IMessageCallback<ITestCommandEvent<TCommand>>): void;

    //
    // Removes a callback onTestCommand registered.
    //
    removeTestCommandListener<TCommand>(callback: IMessageCallback<ITestCommandEvent<TCommand>>): void;

    //
    // Sends the result of a test command to the connection waiting for it. Test hooks builds only.
    //
    sendTestResult(requestId: number, result: IJsonValue): Promise<void>;

    //
    // Tells the test control connection the frontend is listening for test commands, which are held until it does. Test hooks
    // builds only.
    //
    testUiReady(): void;

    //
    // Returns the absolute path of a file from the drop event of a file dropped on the window, or undefined for a File that was not dropped. The same as
    // Electron's webUtils.getPathForFile, and synchronous like it.
    //
    getPathForFile(file: File): string | undefined;
}

declare global {
    interface Window {
        // Injected by the native app before the frontend's scripts run.
        ziggy: IZiggyBridge;
    }
}
