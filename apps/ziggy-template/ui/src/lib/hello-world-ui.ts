//
// Hello world example: change it into your own code, or delete it.
//
// A plain function the UI uses, kept out of main.ts so it can be unit tested on its own.
//

//
// What the backend answers the hello-world message with.
//
export interface IHelloWorldResponse {
    // The greeting the backend made for the name the UI sent.
    greeting: string;
}

//
// The line the app shows for the backend's answer to the hello-world message.
//
export function greetingLine(response: IHelloWorldResponse): string {
    return `The backend says: ${response.greeting}`;
}
