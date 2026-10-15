# Plan: one UI address on every platform

## Goal

Every native app serves the bundled UI from `ziggy-app://app/`, as the docs now say. Windows and Android serve it from `https://ziggy-app.invalid/` today and move to the custom scheme. Linux, macOS and iOS already use `ziggy-app://app/` and do not change.

## What is known

- **Windows (WebView2):** a custom scheme is registered when the environment is created, through `ICoreWebView2EnvironmentOptions4::SetCustomSchemeRegistrations` with an `ICoreWebView2CustomSchemeRegistration`. It was introduced in SDK 1.0.1587.40, and the pinned SDK (`WEBVIEW2_VERSION` in `scripts/fetch-webview2.sh`) is 1.0.3856.49, so no version change is needed. With `HasAuthorityComponent` true the origin is `ziggy-app://app`, like an http origin, and with `TreatAsSecure` true the page is a secure context. Registered schemes reach the `WebResourceRequested` handler and take part in CORS, so responses set the access headers. The native app creates the environment with no options today (`CreateCoreWebView2EnvironmentWithOptions(null, ..., null, ...)` in `native/windows/src/lib/shell.zig`).
- **Android (WebView):** Chromium's WebView docs say a custom scheme is an opaque origin, that `shouldInterceptRequest` can serve it, that CORS responses must allow `*` or `null`, and that a custom scheme is not covered by web platform standards, so new web features may behave differently. They recommend virtual `https` addresses instead. Whether the page gets `localStorage`, IndexedDB and a secure context on an opaque origin has not been checked.

## Open questions for the human

1. **Windows options object.** The SDK's `WebView2EnvironmentOptions.h` implements the options and registration objects in C++ (WRL), which Zig cannot use. The Zig native app would implement `ICoreWebView2EnvironmentOptions`, `ICoreWebView2EnvironmentOptions4` and `ICoreWebView2CustomSchemeRegistration` itself, as it already implements the SDK's handler interfaces. That is writing our own implementation of interfaces the SDK ships a helper for. Is that approved?
2. **Android if the custom scheme falls short.** If step 1 shows that storage, `fetch` or a secure context fails on `ziggy-app://app/`, should Android keep `https://ziggy-app.invalid/` (and the docs say so), or is something given up?

No code changes until both are answered.

## Steps

### 1. Prove the custom scheme on Android before changing anything else

- Add a page to Ziggy's test app that reports, as text with `data-id`s: `location.origin`, `window.isSecureContext`, whether `localStorage` keeps a value, whether IndexedDB opens and whether `fetch` of one of the UI's own files succeeds.
- Add smoke scenario `24-ui-address` (a number not yet used) that reads each value with `get-text` and asserts: the address starts with `ziggy-app://app/`, storage works, `fetch` works and the page is a secure context.
- Run it on Linux, Windows, macOS and iOS as they are, to watch it fail on Windows (wrong address) and pass on the others.
- Change only Android's prefix and serving in a branch of the work, run `bun run test:smoke:and` and read each value.
- If any assertion fails on Android, stop and ask the human (open question 2).

### 2. Windows

- Build the environment options in `native/windows/src/lib/shell.zig` and register `ziggy-app` with `HasAuthorityComponent` and `TreatAsSecure` set, then pass the options to `CreateCoreWebView2EnvironmentWithOptions`.
- Set `app_url_prefix` to `ziggy-app://app/` and the request filter to `ziggy-app://app/*`.
- Add `Access-Control-Allow-Origin: ziggy-app://app` to the responses the native app serves.
- Fail loudly, naming the call, when the runtime does not offer `ICoreWebView2EnvironmentOptions4`.

### 3. Android

- Set `APP_URL_PREFIX` in `ZiggyShell.java` to `ziggy-app://app/`.
- Make `shouldInterceptRequest` and `shouldOverrideUrlLoading` handle the scheme, and add the CORS header the Chromium docs call for.

### 4. Everything that names the old address

- `smoke-tests/lib/windows.sh` and `apps/ziggy-template/smoke-tests/lib/windows.sh`: the developer tools window title they look for.
- `core/src/lib/types.zig` and `core/src/lib/ziggy.h`: the example prefix in the `app_url_prefix` comment.
- `core/src/test/origin-check.test.zig`: replace the `https://ziggy-app.invalid/` cases with the custom scheme, keeping a case for a look-alike host. Break the origin check and watch each changed test fail before accepting it.
- The comments beside each prefix in the Windows and Android native apps.

### 5. Tests

- `bun run test:zig` and `bun run test` on Linux.
- The full smoke suites on every platform: `bun run test:smoke` for Linux, the Windows, macOS and iOS suites on those machines, and `bun run test:smoke:and` and `bun run test:zig:android` for Android, with the new `24-ui-address` scenario in each.
- The template's smoke suites on every platform, because the template's Windows and Android native apps take the change through Ziggy.

### 6. Example apps

After a release, move `ziggy-example-vite` and `ziggy-example-rsbuild` to the new tag and run their full test sets, as `CLAUDE.md` requires.
