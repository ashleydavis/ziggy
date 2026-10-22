//
// Hello world example: change it into your own code, or delete it.
//
// Plain functions the frontend uses, kept out of main.ts so they can be unit tested on their own.
//

import type { IMenuEvent } from "ziggy";

//
// The backend's message response to the hello-world message.
//
export interface IHelloWorldResponse {
    // The greeting the backend made for the name the frontend sent.
    greeting: string;
}

//
// The app event the Hello menu's Say Hello From Zig item sends from its Zig function.
//
export interface IHelloFromZigEvent {
    // Always "hello-from-zig".
    type: "hello-from-zig";

    // The text the Zig function sent.
    text: string;
}

//
// Every app event the frontend listens for.
//
export type IAppEvent = IMenuEvent | IHelloFromZigEvent;

//
// The line the app logs for the backend's message response to the hello-world message.
//
export function greetingLine(response: IHelloWorldResponse): string {
    return `The backend says: ${response.greeting}`;
}

//
// The line the frontend logs for an app event from the Hello menu, or null when the event is not one it logs.
//
export function logLineForEvent(event: IAppEvent): string | null {
    if (event.type === "hello-from-zig") {
        return event.text;
    }
    if (event.type === "menu" && event.item === "hello-from-ui") {
        return "Hello from the UI, run from the menu";
    }
    return null;
}
