//
// The UI's view of Ziggy: the methods every shell exposes as window.ziggy, and the JSON types messages are made of.
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
// Called with the data of an event the core sends on a channel.
//
export type IMessageCallback<TData> = (data: TData) => void;

//
// What a task-message event carries: a message a task sent while it ran.
//
export interface ITaskMessageEvent<TMessage> {
    // The task that sent the message.
    taskId: string;

    // The source the task was queued under.
    source: string;

    // The message the task sent.
    message: TMessage;
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
// What every shell injects into the UI as window.ziggy. Nothing wider than these methods is exposed, and the
// web view's own native handle is never used by the UI directly.
//
export interface IZiggyBridge {
    //
    // Sends a request on a channel and resolves with the core's reply, or rejects with the core's error.
    //
    invoke<TReply>(channel: string, data: IJsonValue): Promise<TReply>;

    //
    // Sends a one-way message on a channel. There is no reply.
    //
    send(channel: string, data: IJsonValue): void;

    //
    // Registers a callback for the events the core sends on a channel.
    //
    onMessage<TData>(channel: string, callback: IMessageCallback<TData>): void;

    //
    // Removes every callback registered for a channel.
    //
    removeAllListeners(channel: string): void;

    //
    // Returns the absolute path of a file from the drop event of a file dropped on the window, or undefined for a File that was not dropped. The same as
    // Electron's webUtils.getPathForFile, and synchronous like it.
    //
    getPathForFile(file: File): string | undefined;
}

declare global {
    interface Window {
        // Injected by the shell before the UI's scripts run.
        ziggy: IZiggyBridge;
    }
}
