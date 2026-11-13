# The theme

Ziggy's theme is a setting the user chooses: `light`, `dark` or `system`, where `system` follows the operating system. It is stored in the app's [config file](config-file.md) as the top-level key `theme`, and each native app reads the system's theme and follows its changes.

## The setting

- `light`: the light theme.
- `dark`: the dark theme.
- `system`: follows the operating system.

A missing key means `system`. An unknown value is logged and the app runs with `system`.

`--theme <light|dark|system>` on the app's command line sets the setting for one run, without writing it to the config file. On Android the extra `ziggy.theme` does the same, because an Android app is started with an Intent. A bad value fails the start with `UnknownTheme`.

The frontend reads and writes the setting through the config system:

```ts
const setting = await window.ziggy.getConfig("theme");
await window.ziggy.setConfig("theme", "dark");
window.ziggy.onConfigChanged(event => {
    if (event.path === "theme") {
        // event.value is the setting just written.
    }
});
```

`getConfig("theme")` resolves with the setting, or `undefined` when nothing is stored. `setConfig("theme", value)` writes it, and the core applies it at once. `config-changed` carries `{ path, value }` for every change of a config value.

`window.ziggy.getSystemTheme()` resolves with the operating system's theme, `light` or `dark`, whatever the setting is. It is the value the setting `system` resolves to, and it is not a config key: a page reads it and cannot write it.

## How a page follows the theme

A page styles itself with the web standard, so it needs no Ziggy call to draw in the right theme:

```css
:root { color-scheme: light dark; }
@media (prefers-color-scheme: dark) { /* the dark theme's colours */ }
```

```ts
const media = window.matchMedia("(prefers-color-scheme: dark)");
media.addEventListener("change", () => { /* the theme changed */ });
```

Each native app sets its web view's colour scheme to the effective theme before it loads the page, and again on every change, so `prefers-color-scheme` is right from the first paint. A page that sets something from script in `<head>` reads `matchMedia("(prefers-color-scheme: dark)").matches` there, and the first paint is still right.

The native app also paints the window and web view in the theme's background colour before the page draws, so there is no flash of the wrong theme. An app declares those colours with `.backgrounds` on its `App` (white and black by default).

## Where `prefers-color-scheme` does not follow the theme

- On Android 7 to 9 the web view is always light; the page sees the theme only through `getConfig("theme")` and `config-changed`.
- In dev mode the browser's own colour scheme is the page's; a `light` or `dark` setting that differs from it reaches the page only through `getConfig` and `config-changed`.
- On Linux, when `GTK_THEME` names a dark theme, WebKitGTK reports dark even when Ziggy's theme is light.

## Screenshots in smoke tests

A smoke test takes light and dark screenshots by starting the app with `--theme` and using the remote control's `screenshot` command. Ziggy's own tests set `ZIGGY_THEME`; Photosphere's set `PHOTOSPHERE_SMOKE_THEME`.
