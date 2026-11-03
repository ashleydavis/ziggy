//
// What the frontend does for each item of the test app's menu that runs in the frontend, which reaches it as a menu
// event. The native apps do the standard items themselves (quit, reload, developer tools, zoom, full screen and the editing
// commands).
//

import type { IActionInfo } from "ziggy";

//
// The data-id of the button an action presses, so the menu and the buttons do exactly the same thing.
//
const buttonForAction: { [action: string]: string } = {
    "start-short": "start-short",
    "start-long": "start-long",
    "start-many": "start-many",
    "cancel-long": "cancel-source",
};

//
// The text the About item shows.
//
export const aboutText = "Ziggy test app: a small app built on Ziggy.";

//
// The data-id of the button an action presses, or null when the action does not press one.
//
export function buttonForMenuAction(action: string): string | null {
    return buttonForAction[action] ?? null;
}

//
// The text the handler of the action say-action writes, so a smoke test can tell the handler ran.
//
export const sayActionText = "said by an action";

//
// Writes the actions listActions gave, one line each: the name, the label and the shortcut, or "none" when there is none.
//
export function formatActionList(actions: IActionInfo[]): string {
    return actions.map(action => `${action.name} ${action.label} ${action.shortcut ?? "none"}`).join("\n");
}
