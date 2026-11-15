# Light and dark splash screens

## Decisions not approved by a human

- `.splash` in `app.zon` gains an optional `.dark` with its own `background`, `portrait` and `landscape`. An app without `.dark` behaves exactly as today.
- The template's current purple art (`#1B1035`) becomes its dark splash, and a new light splash is the same drawing on `#FFFFFF` with the Z drawn in `#1B1035`.
- On Android the system's own launch splash follows the system's night mode, not the app's theme setting, because it shows before any app code runs. Ziggy's splash page after it follows the app's setting.
- On iOS the system launch screen follows the system's appearance for the same reason. The backdrop and splash page after it follow the app's setting.
- On Linux the native app reads the theme from the core before it shows the window, so the first frame is in the right theme. The window appears after the core is created instead of before.

## Acceptance criteria

- An app whose `app.zon` has `.splash.dark` shows the dark background and dark art while it starts in the dark theme, and the light ones in the light theme, on Linux and Windows (native picture, splash page and the frontend's overlay) and on macOS, iOS and Android (backdrop or splash page and the overlay).
- With the setting `system`, the splash follows the system's theme.
- An app with no `.dark` builds and shows its splash exactly as before.
- A missing dark file named in `app.zon`, or a missing dark BMP beside a dark PNG, fails the build naming the file.
- `scripts/generate-app-assets.sh` generates the dark splash files and the dark variants in the macOS and iOS asset catalogs and Android night resources when `assets.json` names dark art.
- The template and the test app declare and ship dark splash art.

## Overview

Ziggy's splash screen has one background colour and one pair of images, so an app in the dark theme flashes its light splash while it starts. Ziggy already paints the window in a per-theme background (`.backgrounds` on the `App`) and sets the web view's colour scheme before the page loads, so the splash is the one part of start-up that ignores the theme. This plan adds an optional dark variant of the splash to `app.zon`, carries it through the build into the UI files and the native apps' `splash` module, makes each native app choose the variant by the effective theme before its first frame, makes the generated splash page and the template's frontend overlay choose by `prefers-color-scheme`, extends the asset generator and gives the template and test app dark art.

## Issues

## Steps

1. [ ] **Core: the splash page with a dark variant.** In `packages/ziggy/core/src/lib/splash.zig`:
    - Add `pub const Variant = enum { light, dark };` and `pub fn variant(theme: []const u8, has_dark: bool) Variant`, which returns `.dark` only when `has_dark` is true and `theme` is `"dark"`.
    - Add a `pub const DarkPage = struct { background: []const u8, portrait_path: []const u8, landscape_path: []const u8 };` and an extra parameter `dark: ?DarkPage` to `html`. With `dark` given, the page adds, before the existing `<source>`, a `<source media="(prefers-color-scheme: dark) and (orientation: landscape)" srcset="<dark landscape>">` and a `<source media="(prefers-color-scheme: dark)" srcset="<dark portrait>">`, and the style adds `@media (prefers-color-scheme: dark) { body { background: <dark background>; } }`. Every dark value goes through `appendEscaped`. With `dark` null the page is byte for byte what it is today.
    - Update `packages/ziggy/core/src/test/splash.test.zig` for the new parameter and add the tests listed under Unit Tests. Run `bun run test:zig`. Save the compile and test output to `tmp/evidence/compile/step-1.txt` and `tmp/evidence/tests/step-1.txt`.

2. [ ] **Build: read, check and embed the dark art.** In `build.zig`:
    - Add `pub const ISplashArt = struct { background: []const u8, portrait: []const u8, landscape: []const u8 };` and a field `dark: ?ISplashArt = null` to `ISplash`, with comments in the file's style.
    - `checkSplashFiles` also opens the dark portrait, dark landscape and the BMP beside each (`splashBmpPath`) when `dark` is set, failing with the same panic message.
    - Where the UI files source is generated (the block that adds `ziggy-splash-portrait.png`), add `ziggy-splash-portrait-dark.png` and `ziggy-splash-landscape-dark.png` entries and their `addAnonymousImport` calls (`splash-portrait-dark`, `splash-landscape-dark`) when `dark` is set, and pass a `splash_lib.DarkPage` naming those two paths and the dark background to `splash_lib.html`.
    - In `addSplashModule`, both generated sources (configured and unconfigured) gain `pub const dark_configured`, `pub const dark_background`, `pub const dark_portrait_png`, `pub const dark_landscape_png`, `pub const dark_portrait_bmp` and `pub const dark_landscape_bmp`. Unconfigured or with no `dark`: `false`, `"#000000"` and empty strings. With `dark`: `true`, the colour and `@embedFile` of four new anonymous imports (`splash-portrait-dark-png`, `splash-landscape-dark-png`, `splash-portrait-dark-bmp`, `splash-landscape-dark-bmp`).
    - The three reserved paths in `docs/user-guide/app-icons-and-splash.md` become five; find where the build or core rejects an app file at a reserved path (search `build.zig` and `packages/ziggy/core/src` for `ziggy-splash-portrait.png`) and add the two dark paths there.
    - Run `bun run compile:zig` (or the repository's equivalent build script in `package.json`) and `bun run test:zig`. Save output to `tmp/evidence/compile/step-2.txt` and `tmp/evidence/tests/step-2.txt`.

3. [ ] **Linux native app: pick the art by the theme.** In `packages/ziggy/native/linux/src/lib/native-app.zig`:
    - In `start`, move the block that creates the core (`ziggy_create`), the first `queryTheme` and the `followSystemTheme` call so they run before the window's splash is added (before `addSplashPicture`). The window is still not shown until the splash picture is in place.
    - Compute `const art = splash_lib.variant(theme_call.theme.theme, splash.dark_configured)` (importing core's `splash.zig` the same way the file imports `native_message`), and pass it to `addSplashPicture`, `applySplashBackground` and `configureSplashWindow`, which choose `splash.dark_portrait_png`/`dark_landscape_png` and `splash.dark_background` for `.dark` and the current constants for `.light`.
    - Update the comment above the splash block to say the window appears once the theme is known so its first frame is in that theme.
    - Run `bun run test:zig` and `bun run test:smoke` on Linux. Save output to `tmp/evidence/tests/step-3.txt`.

4. [ ] **Windows native app: pick the art by the theme.** In `packages/ziggy/native/windows/src/lib/native-app.zig`:
    - Leave the window class registration as it is, but after the existing `queryTheme`/`followSystemTheme` and before `ShowWindow`, compute the variant as in step 3. When it is `.dark`, replace `native_app.splash_background_brush` (delete the old brush with `DeleteObject`) with one made from `splash.dark_background`, set it as the class brush with `SetClassLongPtrW(window, GCLP_HBRBACKGROUND, ...)`, and replace `native_app.splash_bitmap` with `splash_windows.bitmap` of `splash.dark_portrait_bmp` or `splash.dark_landscape_bmp` by the same width and height test.
    - Add any new Win32 declarations the file's C import lacks in the same place the existing ones come from.
    - Run `bun run compile:zig` (the Windows compile check) and `bun run test:zig`. Save output to `tmp/evidence/compile/step-4.txt`.

5. [ ] **Asset generator: dark art.** In `scripts/generate-app-assets.sh`:
    - Read optional `darkPortrait`, `darkLandscape` and `darkBackground` from `assets.json` with `jq -r '.darkPortrait // empty'`. All three or none; any other mix stops with a message naming the missing fields.
    - With them: render `splash-portrait-dark.png`, `splash-landscape-dark.png` and their `.bmp` beside them exactly as the light ones are made; add a dark appearance entry (`"appearances": [{"appearance": "luminosity", "value": "dark"}]`) with the dark PNG to the macOS `SplashPortrait.imageset` and `SplashLandscape.imageset`, the iOS `Splash.imageset` and both `SplashBackground.colorset` files; write Android `res/values-night/splash.xml` with the dark colour and `res/drawable-night-port/splash.png` and `res/drawable-night-land/splash.png`.
    - Without them the outputs are unchanged.
    - Update `scripts/generate-app-assets.md` with the new inputs and outputs.

6. [ ] **Template: dark art and the overlay.** In `apps/ziggy-template`:
    - Copy `assets/splash-portrait.svg` and `assets/splash-landscape.svg` to `assets/splash-portrait-dark.svg` and `assets/splash-landscape-dark.svg` unchanged (the current purple art). In the light SVGs change the background `rect` fill to `#FFFFFF` and the Z `path` fill to `#1B1035`.
    - In `assets/assets.json` set `background` to `#FFFFFF` and add `darkPortrait`, `darkLandscape` and `darkBackground` (`#1B1035`). Run `bash scripts/generate-app-assets.sh --app apps/ziggy-template --assets assets` from the repository root.
    - In `app.zon` add `.dark = .{ .background = "#1B1035", .portrait = "assets/splash-portrait-dark.png", .landscape = "assets/splash-landscape-dark.png" }` inside `.splash`.
    - In `frontend/src/lib/splash.ts`: `ISplashOptions` gains optional `dark?: { background: string }`. `IDocumentLike`'s `defaultView` gains `matchMedia(query: string): { matches: boolean }`. When `dark` is given, `installSplashScreen` adds to the `<picture>`, before the existing landscape source, a source with media `(prefers-color-scheme: dark) and (orientation: landscape)` and srcset `/ziggy-splash-landscape-dark.png` and one with media `(prefers-color-scheme: dark)` and srcset `/ziggy-splash-portrait-dark.png`, and sets the overlay's background to `dark.background` when `defaultView.matchMedia("(prefers-color-scheme: dark)").matches`. The overlay's `<img>` gets `data-id="ziggy-splash-dark"` or `data-id="ziggy-splash-light"` by the same test.
    - In `frontend/src/main.ts` pass `background: "#FFFFFF"` and `dark: { background: "#1B1035" }`. In `frontend/index.html` the `html` background rules stay as they are.
    - Update `frontend/src/test/splash.test.ts` (the fake document gets `matchMedia`) with the tests under Unit Tests. Run the template's TypeScript tests and compile through `package.json`. Save output to `tmp/evidence/tests/step-6.txt`.

7. [ ] **Test app: dark art.** In `apps/ziggy-test-app`:
    - Copy the template's generated `assets/splash-portrait-dark.png`, `splash-landscape-dark.png`, `splash-portrait-dark.bmp` and `splash-landscape-dark.bmp` into `apps/ziggy-test-app/assets/`.
    - Add the same `.dark` to `app.zon`, copy the template's `frontend/src/lib/splash.ts` and `frontend/src/test/splash.test.ts` over the test app's (they are identical today) and pass the same `dark` option in `frontend/src/main.ts`.

8. [ ] **Smoke test of the splash theme.** Add `smoke-tests/desktop-only/38-splash-theme/test.sh` (number after the highest existing one) with a `test.md` beside it:
    - `export ZIGGY_THEME=dark`, `start_test_app`, then `control '{"command":"exists","dataId":"ziggy-splash-dark"}'` answers ok and `ziggy-splash-light` does not exist.
    - `export ZIGGY_THEME=light`, `restart_test_app`, then the opposite.
    - Run it alone and then with the whole Linux suite through `bun run test:smoke` (or the `package.json` script for the desktop smoke tests). Save the output to `tmp/evidence/tests/step-8.txt` and a `screenshot` of the test app in each theme to `tmp/evidence/acceptance/`.

9. [ ] **Documentation.**
    - `docs/user-guide/app-icons-and-splash.md`: the `.dark` field with an example, the dark BMPs Windows needs, the five reserved UI files, how each platform picks the variant (Linux and Windows by the theme before the first frame, macOS and iOS through asset catalog appearances, Android's system splash through night resources and Ziggy's splash page by the theme), and the overlay's `dark` option.
    - `docs/user-guide/theme.md`: a line that the splash follows the theme when the app declares `.dark`.
    - `docs/upgrade-notes.md`: under the next version, "New, and optional: `.dark` on `.splash`", the `splash.ts` change to copy, and that `IDocumentLike.defaultView` needs `matchMedia` in an app's own fake.
    - `apps/ziggy-template/README.md` where it describes the splash.

10. [ ] **Verify.** Run every check in the Verify section and save the output under `tmp/evidence/`.

11. [ ] **Self Review.** Check the evidence in `tmp/evidence/` against each Review item and the acceptance criteria. Uncheck any step whose evidence is missing or failing and add a step before Verify for anything missed.

## Unit Tests

- `splash.test.zig`: `variant` returns dark only for theme `"dark"` with a dark variant, and light for `"light"`, for `"dark"` without one and for any other text.
- `splash.test.zig`: `html` with `dark` null is unchanged from today's expected page.
- `splash.test.zig`: `html` with `dark` has both dark sources before the light source, the dark media rule with the dark background, and escapes every dark value.
- `splash.test.ts` (template and test app): with no `dark` option the overlay is unchanged and its image is `ziggy-splash-light`.
- `splash.test.ts`: with `dark` and a matching media query, the overlay's background is the dark one, the image is `ziggy-splash-dark` and the picture lists the two dark sources first.
- `splash.test.ts`: with `dark` and no match, the light background and `ziggy-splash-light`.

## Smoke Tests

- `smoke-tests/desktop-only/38-splash-theme`: the overlay shows the dark art under `ZIGGY_THEME=dark` and the light art under `ZIGGY_THEME=light`.
- The existing suites, including `30-theme`, `30-theme-screenshots` and every test that waits on the splash, still pass on Linux.

## Verify

- The Zig build and Windows compile check pass, and `bun run test:zig` passes.
- The TypeScript compile and unit tests pass for the core frontend package, the template and the test app.
- The Linux smoke tests pass, including `38-splash-theme`.
- `scripts/generate-app-assets.sh` run on the template writes the dark files listed in step 5.
- CI-only (no Windows, Mac or Android device here): the Windows, macOS, iOS and Android builds and smoke tests.

## Review

- [ ] The code compiles (evidence in `tmp/evidence/compile`).
- [ ] All tests have passed (evidence in `tmp/evidence/tests`).
- [ ] Acceptance criteria has been met (evidence in `tmp/evidence/acceptance`, including screenshots for GUI apps).
- [ ] The documentation is updated and accurate to the code. When the plan had a documentation review stop and the human approved the documentation, the code conforms to the approved documentation. Otherwise the documentation conforms to the code. Check the documentation against the rules too.
- [ ] Local project rules have been followed.
- [ ] Global rules have been followed.

## Reviewed

- [ ] The code compiles (evidence in `tmp/evidence/compile`).
- [ ] All tests have passed (evidence in `tmp/evidence/tests`).
- [ ] Acceptance criteria has been met (evidence in `tmp/evidence/acceptance`, including screenshots for GUI apps).
- [ ] The documentation is updated and accurate to the code. When the plan had a documentation review stop and the human approved the documentation, the code conforms to the approved documentation. Otherwise the documentation conforms to the code. Check the documentation against the rules too.
- [ ] Local project rules have been followed.
- [ ] Global rules have been followed.

## Review issues

## Notes

- The human chose no documentation review stop: the documentation is written in step 9.
- Ziggy already sets the web view's colour scheme to the effective theme before a page loads on every platform, so the splash page and the overlay choose by `prefers-color-scheme` and need no new message.
- The native `ThemeCall` already carries the effective `theme` (`"light"` or `"dark"`), so the native apps need no new core call.
- macOS and iOS load the splash art with `NSImage(named:)` and `UIImage(named:)` from the asset catalog, which pick the appearance variant for the view's appearance. `applyTheme` already sets `NSApp.appearance` and `overrideUserInterfaceStyle`, so the backdrop follows the theme with no Swift change. This cannot be run here, so it is CI-only.
- On Linux the core starts before the window now. With the setting `system` the window waits for the desktop portal's answer, which is quick with a session bus. The smoke tests set `ZIGGY_THEME`, so they never wait on the bus.
- The template's `app.zon` named `#FFFFFF` while its art was `#1B1035`; this plan makes the light art white so the two agree.
- Graft (`~/projects/git-client/playbook/project`) already has `splash-*-dark` art. Switching it over is separate work once this change is in a Ziggy release.
