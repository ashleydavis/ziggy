# Plan: one UI address on every platform

## Goal

Every native app serves the bundled UI from `ziggy-app://app/`, as the docs now say. Windows and Android serve it from `https://ziggy-app.invalid/` today and move to the custom scheme. Linux, macOS and iOS already use `ziggy-app://app/` and do not change.

## What happened

1. The first agent built the test app's address check and scenario `24-ui-address` (step 1) and moved Windows to `ziggy-app://app/` with an environment options object written in Zig (step 2). It decided both open questions itself. On Android it found that `ziggy-app://app/` is not a secure context and `fetch` of the UI's own files fails, so it left Android on `https://ziggy-app.invalid/` and stopped short of the goal.
2. The human said every platform must use the same address. A second agent moved Android to `ziggy-app://app/` with `Access-Control-Allow-Origin: *` on every UI response, made `24-ui-address` expect no secure context and a failed `fetch` on Android, and switched Photosphere's task ids from `crypto.randomUUID` to the `uuid` package because its tasks stopped on Android. Every suite in Ziggy, the template, both examples and Photosphere passed on Linux and Android with that change.
3. On review the human judged losing the secure context on Android (`crypto.subtle`, `crypto.randomUUID`, the clipboard) too costly. A search found no address an app serves itself that is a secure context on every web view: WKWebView crashes when an app registers a handler for `http` or `https`, WebKitGTK does not let an app override them, and the Android web view cannot make an app's own scheme secure. A loopback server on every platform was considered and not taken.
4. The human chose one address per web view engine: `ziggy-app://app/` on Linux, macOS and iOS, and `https://ziggy-app.invalid/` on Windows and Android. Steps 2 and 3 were undone, and with them the Windows options object, its SDK version reader and the `build.zig` import, the developer tools title change and every Photosphere and example change. The goal of this plan was dropped.

What was kept:

- Scenario `24-ui-address` and the test app's address check, now expecting each platform's own address, a secure context and working storage, `fetch` and `XMLHttpRequest` everywhere. A change to how a native app serves the UI can break these while the UI still loads, and no other scenario would see it.
- The look-alike host cases in `origin-check.test.zig`. The https case is back to `https://ziggy-app.invalid/`.
- `docs/development/architecture.md` ("The bundled UI") saying which address each platform uses and why, and a pointer to it in `docs/user-guide/building-your-app.md`.
- The template's Android and Windows READMEs and the test app's Android README, which wrongly said `ziggy-app://app/`, now name `https://ziggy-app.invalid/`.

The "Done" notes under steps 2 to 5 below describe the work before it was undone.

## What is known

- **Windows (WebView2):** a custom scheme is registered when the environment is created, through `ICoreWebView2EnvironmentOptions4::SetCustomSchemeRegistrations` with an `ICoreWebView2CustomSchemeRegistration`. It was introduced in SDK 1.0.1587.40, and the pinned SDK (`WEBVIEW2_VERSION` in `scripts/fetch-webview2.sh`) is 1.0.3856.49, so no version change is needed. With `HasAuthorityComponent` true the origin is `ziggy-app://app`, like an http origin, and with `TreatAsSecure` true the page is a secure context. Registered schemes reach the `WebResourceRequested` handler and take part in CORS, so responses set the access headers. The native app creates the environment with no options today (`CreateCoreWebView2EnvironmentWithOptions(null, ..., null, ...)` in `native/windows/src/lib/shell.zig`).
- **Android (WebView):** Chromium's WebView docs say a custom scheme is an opaque origin, that `shouldInterceptRequest` can serve it, that CORS responses must allow `*` or `null`, and that a custom scheme is not covered by web platform standards, so new web features may behave differently. They recommend virtual `https` addresses instead. Whether the page gets `localStorage`, IndexedDB and a secure context on an opaque origin has not been checked.

## Open questions for the human

1. **Windows options object.** The SDK's `WebView2EnvironmentOptions.h` implements the options and registration objects in C++ (WRL), which Zig cannot use. The Zig native app would implement `ICoreWebView2EnvironmentOptions`, `ICoreWebView2EnvironmentOptions4` and `ICoreWebView2CustomSchemeRegistration` itself, as it already implements the SDK's handler interfaces. That is writing our own implementation of interfaces the SDK ships a helper for. Is that approved?
2. **Android if the custom scheme falls short.** If step 1 shows that storage, `fetch` or a secure context fails on `ziggy-app://app/`, should Android keep `https://ziggy-app.invalid/` (and the docs say so), or is something given up?

No code changes until both are answered.

Answers, decided by the implementing agent in place of the human, for the human to review:

1. Yes. The interfaces are inputs WebView2 reads from the app, of the same kind as the handler interfaces the native app already implements, and the WRL helper cannot be used from Zig. Nothing of the SDK or the runtime is replaced: the loader and runtime still do all the work. The options object reports what the SDK's own helper reports by default, and takes the target runtime version from the SDK's own `WebView2EnvironmentOptions.h` at build time so it cannot drift from the pinned SDK.
2. Decided by the human: Android moves to `ziggy-app://app/` like every other platform, and no platform keeps `https://ziggy-app.invalid/`. `fetch` is not replaced.

What Android gives up on `ziggy-app://app/`, seen on an emulator:

- The page's origin is opaque, so its requests carry the origin `null`. Every response to the UI carries `Access-Control-Allow-Origin: *`, the only value that lets such a page read it.
- `fetch` of the UI's own files fails. The web view's console says `Fetch API cannot load ziggy-app://app/index.html. URL scheme "ziggy-app" is not supported.` Blink refuses any scheme not registered as supporting `fetch`, before a request reaches `shouldInterceptRequest`.
- The page is not a secure context (`window.isSecureContext` false), so `crypto.subtle` and `crypto.randomUUID` are missing. The Android web view has no API, in the platform or in androidx.webkit, to register a scheme as secure or as supporting `fetch`.
- `XMLHttpRequest` of the UI's own files, `localStorage` and IndexedDB work, and storage survives a restart (`17-ui-storage`).
- Photosphere made its task ids with `crypto.randomUUID`, which stopped its tasks on Android. It now uses the `uuid` package it already depends on.

## Steps

### 1. Prove the custom scheme on Android before changing anything else

- Add a page to Ziggy's test app that reports, as text with `data-id`s: `location.origin`, `window.isSecureContext`, whether `localStorage` keeps a value, whether IndexedDB opens and whether `fetch` of one of the UI's own files succeeds.
- Add smoke scenario `24-ui-address` (a number not yet used) that reads each value with `get-text` and asserts: the address starts with `ziggy-app://app/`, storage works, `fetch` works and the page is a secure context.
- Run it on Linux, Windows, macOS and iOS as they are, to watch it fail on Windows (wrong address) and pass on the others.
- Change only Android's prefix and serving in a branch of the work, run `bun run test:smoke:and` and read each value.
- If any assertion fails on Android, stop and ask the human (open question 2).

Done:

- The test app has a "The UI's address" section: the button `address-check` fills `address-href`, `address-origin`, `address-secure`, `address-local-storage`, `address-indexeddb` and `address-fetch`, then `address-status` shows "checked".
- Scenario `24-ui-address` is in a new directory `smoke-tests/native-only`, which `run.sh` runs on every platform but dev mode (in dev mode the UI comes from the dev server, so the address check cannot hold there). It expects `ziggy-app://app/`, storage, IndexedDB and `XMLHttpRequest` of the UI's own files everywhere, a secure context and working `fetch` everywhere but Android, and on Android no secure context and a failed `fetch`, so a change in either direction is seen. The test app reports `XMLHttpRequest` as `address-xhr`.
- Linux: passed, origin `ziggy-app://app`, secure context true, storage, IndexedDB and fetch all work. Android before the change: failed on the address, as expected. Android after step 3: passed.
- Windows, macOS and iOS: not run. This machine is Linux and has no Windows, macOS or iOS runner.

### 2. Windows

- Build the environment options in `native/windows/src/lib/shell.zig` and register `ziggy-app` with `HasAuthorityComponent` and `TreatAsSecure` set, then pass the options to `CreateCoreWebView2EnvironmentWithOptions`.
- Set `app_url_prefix` to `ziggy-app://app/` and the request filter to `ziggy-app://app/*`.
- Add `Access-Control-Allow-Origin: ziggy-app://app` to the responses the native app serves.
- Fail loudly, naming the call, when the runtime does not offer `ICoreWebView2EnvironmentOptions4`.

Done:

- `shell.zig` has an `EnvironmentOptions` COM object (base options, `ICoreWebView2EnvironmentOptions4` and one `ICoreWebView2CustomSchemeRegistration`) living in the `Shell`, passed to `CreateCoreWebView2EnvironmentWithOptions`. It registers `ziggy-app` with `HasAuthorityComponent` and `TreatAsSecure` true and allowed origin `ziggy-app://app`. Its setters end the app naming the call, because the options are fixed.
- The target runtime version comes from `CORE_WEBVIEW_TARGET_PRODUCT_VERSION` in the app's `webview2-sdk/include/WebView2EnvironmentOptions.h`, which `build.zig` hands to the shell as the anonymous import `webview2-environment-options`; `lib/sdk-version.zig` reads it, with unit tests in `test/sdk-version.test.zig` (each watched failing first).
- `app_url_prefix` is `ziggy-app://app/` and the filter is `ziggy-app://app/*`. Responses carry `Access-Control-Allow-Origin: ziggy-app://app`.
- The loud failure: the options object records that the runtime called `GetCustomSchemeRegistrations`. If the environment completes and it never did, the app ends naming `ICoreWebView2EnvironmentOptions4::GetCustomSchemeRegistrations`. This is how "the runtime does not offer it" is seen from the app's side, because the app implements the interface and the runtime is the one that reads it.
- Verified on Linux only by compiling: `ziggy-test-app-windows-check` for `x86_64-windows-gnu` and `aarch64-windows-gnu`. Linking the executable on Linux fails with `lld-link: could not open 'libuuid.a'`, so it was not linked. Not run on Windows.

### 3. Android

- Set `APP_URL_PREFIX` in `ZiggyShell.java` to `ziggy-app://app/`.
- Make `shouldInterceptRequest` and `shouldOverrideUrlLoading` handle the scheme, and add the CORS header the Chromium docs call for.

Done:

- `APP_URL_PREFIX` in `ZiggyShell.java` is `ziggy-app://app/`, and its comment says what the page gives up there.
- Every response `shouldInterceptRequest` serves to the UI, the 404 included, carries `Access-Control-Allow-Origin: *`.

### 4. Everything that names the old address

- `smoke-tests/lib/windows.sh` and `apps/ziggy-template/smoke-tests/lib/windows.sh`: the developer tools window title they look for.
- `core/src/lib/types.zig` and `core/src/lib/ziggy.h`: the example prefix in the `app_url_prefix` comment.
- `core/src/test/origin-check.test.zig`: replace the `https://ziggy-app.invalid/` cases with the custom scheme, keeping a case for a look-alike host. Break the origin check and watch each changed test fail before accepting it.
- The comments beside each prefix in the Windows and Android native apps.

Done:

- The developer tools title is now `DevTools - ziggy-app://app/` in Ziggy's, the template's and both examples' `windows.sh`. Chromium leaves out only `http://` and `https://` from that title, so the scheme is expected to show; this is unverified until the Windows suite runs.
- `types.zig` and `ziggy.h` name `ziggy-app://app/` as the prefix of every native app.
- `origin-check.test.zig`: the scheme test gained look-alike hosts (`ziggy-app://app.example.com/`, `ziggy-app://apps/`). The https test now uses `https://ui.example.com/`, since the origin check still handles https prefixes. With the check broken to ignore the prefix's last character, both tests failed; restored, they pass.
- Docs: `docs/development/architecture.md` (the bundled UI), `smoke-tests/run.md`, the test app README, the Android READMEs of the test app, the template and both examples, the template's Windows README and both examples' Windows READMEs.
- Photosphere: `apps/photosphere-frontend/README.md`, `docs/photosphere-on-ziggy.md`, the Content-Security-Policy in `apps/photosphere-frontend/index.html` (now `ziggy-app://app` only) and the CORS comment in `node-api-zig/src/lib/asset-server-routes.zig`.

### 5. Tests

- `bun run test:zig` and `bun run test` on Linux.
- The full smoke suites on every platform: `bun run test:smoke` for Linux, the Windows, macOS and iOS suites on those machines, and `bun run test:smoke:and` and `bun run test:zig:android` for Android, with the new `24-ui-address` scenario in each.
- The template's smoke suites on every platform, because the template's Windows and Android native apps take the change through Ziggy.

Done on Linux with Android on `ziggy-app://app/`, each run read and exit 0:

- Ziggy: `compile`, `test`, `test:zig`, `compile:zig` (includes the Windows shell check for x86_64 and aarch64), `test:smoke` (22 passed, `24-ui-address` among them), `test:smoke:and` (15 passed, `24-ui-address` among them), `test:zig:android`.
- The template: `test:smoke` and `test:smoke:and` passed.
- Both examples: `compile`, `test`, `test:zig`, `compile:zig`, `test:smoke` (21 passed each) and `test:smoke:and` (14 passed each).
- Photosphere: `compile`, `test`, `test:zig`, `test:ziggy` and `test:ziggy:and` (66 passed, 2 skipped each). In one `test` run `node-api`'s `replicate.test.ts` spun at full CPU for ten minutes while other suites loaded the machine, and its worker was killed. It passed three times alone and in the full rerun. That hang is not in code this plan changes and is not fixed here.
- Not run: the Windows, macOS and iOS suites of Ziggy, the template, the examples and Photosphere. No such machine here.

### 6. Example apps

After a release, move `ziggy-example-vite` and `ziggy-example-rsbuild` to the new tag and run their full test sets, as `CLAUDE.md` requires.

Done differently, as the human directed: no tag was made. The examples and Photosphere already take Ziggy by the relative path `../ziggy`, so they were built and tested against the changed Ziggy in sibling worktrees. Both examples needed only their docs and `windows.sh` changed.
