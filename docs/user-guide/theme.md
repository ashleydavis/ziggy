# The theme

Ziggy's theme is a setting the user chooses: `light`, `dark` or `system`, where `system` follows the operating system. It is stored in the app's [config file](config-file.md) as the top-level key `theme`, and each native app reads the system's theme and follows its changes.

## The setting

- `light`: the light theme.
- `dark`: the dark theme.
- `system`: follows the operating system.

A missing key means `system`. An unknown value is logged and the app runs with `system`.

`--theme <light|dark|system>` on the app's command line sets the setting for one run, whatever the config file holds, without writing it to the config file. `--light`, `--dark` and `--system` are short for `--theme light`, `--theme dark` and `--theme system`. Giving more than one of these fails the start with `ThemeGivenTwice`. On Android the extra `ziggy.theme` does the same, because an Android app is started with an Intent. A bad value fails the start with `UnknownTheme`. Ziggy takes these options out of the arguments before the app's `on_create` gets them.

The environment variable `ZIGGY_THEME` (`light`, `dark` or `system`) sets the setting for a run in the same way when the command line has none of these options. An empty value counts as unset, and any other value fails the start with `UnknownTheme`. A window the app starts inherits the environment, so it takes the same setting. The order is: the command line, then `ZIGGY_THEME`, then the config file, then `system`.

On Linux the app reads the system's theme from the desktop portal, over the session bus, only once the setting is `system`, at the start or when the setting changes to it, and then follows its changes. With the setting `light` or `dark` it never connects to the session bus. Until it has read the system's theme, `getSystemTheme()` answers `light`. Reading it blocks the start, and with no session bus, as on a CI runner, it waits out D-Bus's 25-second timeout. The other platforms read the system's theme at every start.

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

`window.ziggy.getSystemTheme()` resolves with the operating system's theme, `light` or `dark`, whatever the setting is (except on Linux before the setting has first been `system`, see above). It is the value the setting `system` resolves to, and it is not a config key: a page reads it and cannot write it.

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

A smoke test takes light and dark screenshots by starting the app with `--theme` and using the remote control's `screenshot` command. Ziggy's own tests set `ZIGGY_THEME`; Photosphere's set `PHOTOSPHERE_SMOKE_THEME`. Ziggy's smoke tests run every app in the light theme unless a scenario sets `ZIGGY_THEME` itself, so none depends on the system's theme and the Linux app never connects to the session bus. Only the extras, which check the system's theme, set it to `system` (see `smoke-tests/run.md`).
