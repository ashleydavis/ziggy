# Splash screens and app icons for Ziggy, its examples and Photosphere

## Decisions not approved by a human

- Ziggy apps configure a splash screen in `app.zon` with `.splash = .{ .background, .portrait, .landscape }`, and Ziggy embeds both images and a generated `ziggy-splash.html` into the app's UI files.
- Every native app shows a splash web view before the main web view, and the frontend also installs an in-page splash overlay that fades out with an ease-out cubic curve.
- The frontend API is `installSplashScreen(document, options)`, which returns an `ISplashScreen` whose `remove()` fades and removes the overlay.
- The art direction is a gradient zigzag mark for the Ziggy template and its two examples, and a purple, coral and amber photo-sphere mark for Photosphere, with portrait and landscape splash compositions.
- The two examples and Photosphere take Ziggy from the sibling checkout (`../ziggy`) for every part: Zig, npm, the Xcode projects and the Android Gradle build. No Ziggy release is made.

## Acceptance criteria

- An app can add `.splash` to its `app.zon`, add the art and the platform assets, and get a native splash background, a splash web view, an in-page splash overlay and a non-linear fade without editing native code.
- The Ziggy template, the Vite example, the Rsbuild example and Photosphere each have a new app icon on Linux, Windows, macOS, iOS and Android.
- The same four apps each have portrait and landscape splash screens on every platform, including the iOS launch screen and the Android system splash theme.
- All unit tests and every desktop smoke test pass in all four repositories, and the Linux apps show the splash and then the loaded UI in captured screenshots.

## Overview

Startup currently shows a blank native window and then a blank web view until the frontend has parsed, bundled and rendered. This plan adds a first-class splash screen to Ziggy: an app declares its art in `app.zon`, Ziggy embeds the art and a generated splash page into the core's UI files, and each native app shows the splash in the window background, then in a dedicated splash web view, then swaps to the main web view while the frontend fades its own matching overlay. It also gives the Ziggy template, both examples and Photosphere real app icons and splash art, replacing the placeholder macOS and iOS icons and the missing icons in the template and examples.

## Issues

None.

## Steps

### Step 1: Add the splash page generator and orientation helper to Ziggy's core

1. Create `~/projects/photosphere/ziggy/packages/ziggy/core/src/lib/splash.zig`.
2. It exports `pub const Orientation = enum { portrait, landscape };` and `pub fn orientation(width: u32, height: u32) Orientation`, which returns `.landscape` when `width >= height` and `.portrait` otherwise.
3. It exports `pub fn html(allocator: std.mem.Allocator, background: []const u8, portrait_path: []const u8, landscape_path: []const u8) ![]u8`.
4. The returned document is a complete HTML page with:
   - a `<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">`;
   - a `<style>` block setting `html`, `body`, `picture` and `img` to `margin: 0; padding: 0; width: 100%; height: 100%; overflow: hidden`, `img` to `display: block; object-fit: cover; object-position: center`, and `body` to the given `background`;
   - a `<picture>` with `<source media="(orientation: landscape)" srcset="{landscape_path}">` and `<img src="{portrait_path}" alt="">`.
5. Create `~/projects/photosphere/ziggy/packages/ziggy/core/src/test/splash.test.zig` with tests for:
   - `orientation(800, 1200) == .portrait`;
   - `orientation(1200, 800) == .landscape`;
   - `orientation(1000, 1000) == .landscape`;
   - `html` contains the background colour, the portrait path, the landscape path and the `(orientation: landscape)` media query;
   - `html` escapes `&`, `<`, `>` and `"` in every input, including a background such as `#fff" onload="x`.
6. Run `mise exec -- bun run test:zig` in `~/projects/photosphere/ziggy`.
7. Write the command, its exit status and its final summary lines to `~/projects/photosphere/ziggy/tmp/evidence/tests/splash-core.txt` with the Write tool. Write the compile result to `~/projects/photosphere/ziggy/tmp/evidence/compile/splash-core.txt`.

### Step 2: Read `.splash` from `app.zon` in Ziggy's build

1. In `~/projects/photosphere/ziggy/build.zig`, add:
   - `pub const ISplash = struct { background: []const u8, portrait: []const u8, landscape: []const u8 };`
   - a field `splash: ?ISplash = null` to `IAppDetails`.
2. In `readAppDetails`, keep `std.zon.parse.fromSliceAlloc(IAppDetails, ...)`; the optional field already parses with a default.
3. In `embedUi`, call `const details = readAppDetails(b);` at the start.
4. When `details.splash` is not null, open `splash.portrait`, `splash.landscape` and the two Windows BMP files described in Step 4 with `b.build_root.handle.openFile(b.graph.io, path, .{})`. When any is missing, fail the build with `std.debug.panic` naming the path and the app's `app.zon`.
5. Run `mise exec -- bun run test:zig` in `~/projects/photosphere/ziggy`. Step 14 runs the template's own test again once its `app.zon` has `.splash`.
6. Write the evidence to `tmp/evidence/compile/ziggy-build-splash.txt`.

### Step 3: Embed the splash assets into every app's UI files

1. In `embedUi` in `~/projects/photosphere/ziggy/build.zig`, when `details.splash` is present:
   - add an anonymous import named `splash-portrait` whose `root_source_file` is `b.path(details.splash.?.portrait)`;
   - add an anonymous import named `splash-landscape` whose `root_source_file` is `b.path(details.splash.?.landscape)`;
   - write the generated HTML with `const generated_html = b.addWriteFiles(); const html_file = generated_html.add("ziggy-splash.html", try splash_lib.html(b.allocator, details.splash.?.background, "ziggy-splash-portrait.png", "ziggy-splash-landscape.png"));`;
   - add an anonymous import named `splash-html` whose `root_source_file` is `html_file`;
   - append these three entries to the `files` list emitted into the generated `ui-files.zig`:
     - `.path = "ziggy-splash-portrait.png"`, `.content = @embedFile("splash-portrait")`;
     - `.path = "ziggy-splash-landscape.png"`, `.content = @embedFile("splash-landscape")`;
     - `.path = "ziggy-splash.html"`, `.content = @embedFile("splash-html")`.
2. When `details.splash` is null, append no splash entries.
3. Keep the existing compile error when the UI directory or `index.html` is missing.
4. Add `const splash_lib = @import("packages/ziggy/core/src/lib/splash.zig");` near the top of `build.zig`.
5. Run `mise exec -- bun run test:zig` in `~/projects/photosphere/ziggy`.
6. Write the evidence to `tmp/evidence/compile/ziggy-embed-splash.txt` and `tmp/evidence/tests/ziggy-embed-splash.txt`.

### Step 4: Add a splash module to the Linux and Windows native app builds

1. In `~/projects/photosphere/ziggy/build.zig`, add `fn addSplashModule(b: *std.Build, details: IAppDetails) !*std.Build.Module`.
2. When `details.splash` is null, the module's root source is a generated `splash.zig` containing:
   - `pub const configured = false;`
   - `pub const background = "#000000";`
   - `pub const portrait_png = "";`
   - `pub const landscape_png = "";`
   - `pub const portrait_bmp = "";`
   - `pub const landscape_bmp = "";`
3. When `details.splash` is not null, the module's root source contains:
   - `pub const configured = true;`
   - `pub const background = "<the app.zon colour>";`
   - `pub const portrait_png = @embedFile("splash-portrait-png");`
   - `pub const landscape_png = @embedFile("splash-landscape-png");`
   - `pub const portrait_bmp = @embedFile("splash-portrait-bmp");`
   - `pub const landscape_bmp = @embedFile("splash-landscape-bmp");`
4. Add anonymous imports for:
   - `splash-portrait-png` from `details.splash.portrait`;
   - `splash-landscape-png` from `details.splash.landscape`;
   - `splash-portrait-bmp` from the portrait path with its `.png` suffix replaced by `.bmp`;
   - `splash-landscape-bmp` from the landscape path with its `.png` suffix replaced by `.bmp`.
5. In `addLinuxNativeApp`, call `const splash_module = try addSplashModule(b, readAppDetails(b));` and `native_app.addImport("splash", splash_module);`.
6. In `addWindowsNativeApp`, do the same on its `native_app` module.
7. Run `mise exec -- bun run test:zig`, `mise exec -- bun run build:ziggy-template:linux` and `mise exec -- bun run --filter=ziggy-template compile:zig`. The template has no `.splash` yet, so these prove the `configured = false` path compiles. Step 14 runs them again with the splash configured.
8. Write the evidence to `tmp/evidence/compile/ziggy-splash-module.txt`.

### Step 5: Add the frontend splash API

1. Create `~/projects/photosphere/ziggy/packages/ziggy/frontend/src/splash.ts` with these exports:
   - `export interface ISplashOptions { background: string; minimumDisplayMilliseconds: number; fadeDurationMilliseconds: number; }`
   - `export interface ISplashScreen { remove(): Promise<void>; }`
   - `export function easeOutCubic(progress: number): number`, returning `1 - Math.pow(1 - progress, 3)`.
   - `export function installSplashScreen(documentLike: IDocumentLike, options: ISplashOptions): ISplashScreen`.
2. `IDocumentLike` and the element interfaces describe only the DOM members the function uses: `createElement`, `body.appendChild`, `style`, `setAttribute`, `remove`, `addEventListener`, `defaultView.setTimeout` and `defaultView.requestAnimationFrame`. Do not use `unknown`.
3. `installSplashScreen` creates a `<div data-id="ziggy-splash">` with fixed positioning, `inset: 0`, the given background, `z-index: 2147483647`, `overflow: hidden`, and a `<picture>` containing:
   - `<source media="(orientation: landscape)" srcset="/ziggy-splash-landscape.png">`;
   - `<img src="/ziggy-splash-portrait.png" alt="">` with `width: 100%; height: 100%; object-fit: cover; object-position: center; display: block`.
   It also adds an `error` listener to the `<img>` that removes the overlay, so in dev mode, where the core serves no splash files, the app loads straight into its UI.
4. It records the start time with `Date.now()`. `remove()` resolves immediately when the overlay is already gone.
5. `remove()` waits until `minimumDisplayMilliseconds` has passed since installation, then fades the overlay's `opacity` from 1 to 0 over `fadeDurationMilliseconds` using `requestAnimationFrame` and `easeOutCubic`, then calls `element.remove()`.
6. Export the module from `~/projects/photosphere/ziggy/packages/ziggy/frontend/src/index.ts` with `export * from "./splash";`.
7. Create `~/projects/photosphere/ziggy/packages/ziggy/frontend/src/test/splash.test.ts` with:
   - `easeOutCubic(0) === 0`, `easeOutCubic(0.5) === 0.875`, `easeOutCubic(1) === 1`;
   - a fake document test that `installSplashScreen` appends one element with `data-id="ziggy-splash"`, the given background and a `<picture>` with both image paths;
   - a fake document and fake clock test that `remove()` removes the element only after the minimum time and the fade, and that the opacity values follow `easeOutCubic`.
8. Run `mise exec -- bun run --filter=ziggy test` and `mise exec -- bun run --filter=ziggy compile` in `~/projects/photosphere/ziggy`.
9. Write the evidence to `tmp/evidence/tests/frontend-splash.txt` and `tmp/evidence/compile/frontend-splash.txt`.

### Step 6: Show the splash in the Linux native app

1. In `~/projects/photosphere/ziggy/packages/ziggy/native/linux/src/lib/gtk.zig`, declare:
   - `GtkOverlay`, `GtkPicture`;
   - `gtk_overlay_new`, `gtk_overlay_add_overlay`;
   - `gtk_picture_new_for_pixbuf`, `gtk_picture_set_content_fit`;
   - `GTK_CONTENT_FIT_COVER`;
   - `gtk_widget_set_hexpand`, `gtk_widget_set_vexpand`, `gtk_widget_set_halign`, `gtk_widget_set_valign`, `GTK_ALIGN_FILL`;
   - `gtk_widget_set_no_show_all`, `gtk_widget_show`, `gtk_widget_hide`, `gtk_widget_destroy`;
   - `WEBKIT_LOAD_FINISHED`.
2. In `~/projects/photosphere/ziggy/packages/ziggy/native/linux/src/lib/native-app.zig`, import `const splash = @import("splash");`.
3. Add `splash_web_view: ?*c.WebKitWebView`, `splash_picture: ?*c.GtkWidget`, `splash_loaded: bool` and `main_loaded: bool` to `NativeApp`, and initialize them in `run`.
4. Refactor the PNG decoding in `setWindowIcon` into `fn pixbufFromPng(png: []const u8) ?*c.GdkPixbuf`, which finishes the loader, takes a reference on the pixbuf with `g_object_ref`, releases the loader and returns the referenced pixbuf. Declare `g_object_ref` in `gtk.zig`. The caller releases the pixbuf with `g_object_unref` after use. Use it for both the icon and the splash.
5. In `start`, create a `GtkOverlay` and add the existing vertical box as its main child. Add the overlay to the window instead of the box.
6. When `splash.configured` is true:
   - choose `splash.portrait_png` when `width < height`, else `splash.landscape_png`;
   - create a `GtkPicture` with that pixbuf, set `GTK_CONTENT_FIT_COVER`, make it expand and fill in both directions, and add it as an overlay;
   - create a second `WebKitWebView` for the splash, with no injected script and no `ziggy` message handler, add it as an overlay, set it to expand and fill, call `gtk_widget_set_no_show_all(widget, 1)` and hide it;
   - connect its `load-changed` signal to `onSplashLoadChanged`, and load `ziggy-app://app/ziggy-splash.html` into it.
7. Connect the main web view's `load-changed` signal to `onMainLoadChanged`.
8. In `onSplashLoadChanged`, when the event is `WEBKIT_LOAD_FINISHED`: set `splash_loaded = true`; if `main_loaded` is false, call `gtk_widget_show` on the splash web view and `gtk_widget_destroy` on the splash picture; if `main_loaded` is true, destroy the splash web view and the picture.
9. In `onMainLoadChanged`, when the event is `WEBKIT_LOAD_FINISHED`: set `main_loaded = true` and destroy the splash web view and the splash picture when they still exist. The main web view is already in the window underneath, and the frontend's own overlay covers it, so skipping a splash web view that has not finished is seamless.
10. Keep the existing window show and present call after loading `index.html`.
11. Run `mise exec -- bun run --filter=ziggy-template build:linux`, `mise exec -- bun run --filter=ziggy-template test:smoke`, `mise exec -- bun run --filter=ziggy-test-app build:linux` and `mise exec -- bun run test:smoke`. The template has no `.splash` yet, so the Linux splash code takes the `configured = false` path. Step 14 runs the template checks again with the splash configured.
12. Write the evidence to `tmp/evidence/compile/linux-splash.txt` and `tmp/evidence/tests/linux-splash.txt`.

### Step 7: Show the splash in the Windows native app

1. Create `~/projects/photosphere/ziggy/packages/ziggy/native/windows/src/lib/splash-windows.zig` with:
   - `pub const Color = struct { red: u8, green: u8, blue: u8 };`
   - `pub fn parseColor(text: []const u8) !Color`, accepting `#RRGGBB` and failing otherwise;
   - `pub const Bitmap = struct { width: i32, height: i32, pixel_offset: usize, bytes: []const u8 };`
   - `pub fn bitmap(bytes: []const u8) !Bitmap`, reading the 14 byte file header and 40 byte info header of an uncompressed 24 or 32 bit BMP, and failing with a message naming the problem.
2. Create `~/projects/photosphere/ziggy/packages/ziggy/native/windows/src/test/splash-windows.test.zig` with tests for valid and invalid colours and for a small hand-built BMP header.
3. Add `_ = @import("test/splash-windows.test.zig");` to `~/projects/photosphere/ziggy/packages/ziggy/native/windows/src/tests.zig`.
4. In `~/projects/photosphere/ziggy/packages/ziggy/native/windows/src/lib/native-app.zig`, import `const splash = @import("splash");` and `const splash_windows = @import("splash-windows.zig");`.
5. Add to `NativeApp`: `splash_controller: ?*c.ICoreWebView2Controller`, `splash_web_view: ?*c.ICoreWebView2`, `splash_controller_handler: SplashControllerHandler`, `splash_navigation_completed_handler: NavigationCompletedHandler`, `main_navigation_completed_handler: NavigationCompletedHandler`, `splash_load_finished: bool`, `main_load_finished: bool`, `splash_bitmap: ?splash_windows.Bitmap`, `splash_background_brush: c.HBRUSH`, and `splash_painted: bool`.
6. Add `const NavigationCompletedHandler = ComHandler(c.ICoreWebView2NavigationCompletedEventHandler, c.IID_ICoreWebView2NavigationCompletedEventHandler);` and `const SplashControllerHandler = ComHandler(c.ICoreWebView2CreateCoreWebView2ControllerCompletedHandler, c.IID_ICoreWebView2CreateCoreWebView2ControllerCompletedHandler);`.
7. Add three vtables beside the existing ones: `splash_controller_vtable` whose `Invoke` is `splashControllerInvoke`, `splash_navigation_completed_vtable` whose `Invoke` is `splashNavigationCompletedInvoke`, and `main_navigation_completed_vtable` whose `Invoke` is `mainNavigationCompletedInvoke`. Register all three in `initHandlers` with their handler fields.
8. In `start`, when `splash.configured` is true:
   - parse `splash.background` with `splash_windows.parseColor` and create a solid brush for the window class's `hbrBackground`;
   - store `splash_windows.bitmap(splash.portrait_bmp)` or `splash_windows.bitmap(splash.landscape_bmp)`, whichever matches the initial `width` and `height`.
9. Handle `WM_PAINT` in `windowProc`: when `splash.configured` is true and `splash_painted` is false, `BeginPaint`, fill with the background brush, draw the stored bitmap stretched over the client rect with `StretchDIBits` and `HALFTONE`, then `EndPaint`; otherwise call `DefWindowProcW`.
10. In `onControllerCreated`, after the core exists:
   - keep the main controller hidden with `put_IsVisible(controller, 0)`;
   - add `add_NavigationCompleted` to the main web view with `main_navigation_completed_handler`;
   - call `native_app.environment.?.CreateCoreWebView2Controller(native_app.window, &native_app.splash_controller_handler.interface)` to start the splash controller;
   - load the app's `index.html` into the main web view as today.
11. In `splashControllerInvoke`, after `check` and the null check: store and `AddRef` the splash controller; get its web view; set the main bounds with `resizeSplashWebView`; `put_IsVisible(splash_controller, 0)`; add `AddWebResourceRequestedFilter`, `add_WebResourceRequested`, `add_NavigationStarting`, `add_NewWindowRequested` and `add_NavigationCompleted` with the splash navigation completed handler; load `ziggy-app://app/ziggy-splash.html`.
12. In `splashNavigationCompletedInvoke`: set `splash_load_finished = true`; if `main_load_finished` is false, `put_IsVisible` true on the splash controller, set `splash_painted = true` and `InvalidateRect`; otherwise close and release the splash controller.
13. In `mainNavigationCompletedInvoke`: set `main_load_finished = true`; `put_IsVisible` true on the main controller; close and release the splash controller when it still exists; set `splash_painted = true` and `InvalidateRect`.
14. In `resizeWebView`, also resize the splash controller when it exists, with the same client bounds.
15. In `closeWebView`, close and release the splash controller and release the background brush when one exists.
16. Run `mise exec -- bun run test:zig`, `mise exec -- bun run --filter=ziggy-template compile:zig` and `mise exec -- bun run --filter=ziggy-test-app compile:zig`. The template has no `.splash` yet, so the Windows splash code takes the `configured = false` path. Step 14 runs the template check again with the splash configured.
17. Write the evidence to `tmp/evidence/compile/windows-splash.txt` and `tmp/evidence/tests/windows-splash.txt`.

### Step 8: Show the splash in the macOS native app

1. In `~/projects/photosphere/ziggy/packages/ziggy/native/macos/Sources/ZiggyNativeMacOS/ZiggyBridge.swift`, add:
   - `public let view: NSView`, a container whose subviews are the backdrop, the splash web view and the main web view;
   - `private let splashWebView: WKWebView?`;
   - `private let splashUiHandler = ZiggyUiSchemeHandler()`;
   - `private let backdrop: NSImageView`.
2. In `init`, after the main web view is created:
   - create `view`, add the main web view, set `autoresizingMask = [.width, .height]` and pin its frame to the container;
   - when `NSImage(named: "SplashLandscape")` or `NSImage(named: "SplashPortrait")` exists, create the backdrop image view with the image that matches the frame's aspect ratio, set `imageScaling = .scaleAxesIndependently` and `autoresizingMask = [.width, .height]`, add it, and create a second `ZiggyWebView` with `splashUiHandler` for the splash page. The splash web view's configuration has no `WKUserScript` and no `ziggy` message handler. Keep the backdrop visible and the splash web view hidden.
3. In `start`, after the core exists:
   - set `splashUiHandler.core` to the core;
   - when the splash web view exists, load `ziggy-app://app/ziggy-splash.html` into it and set its navigation delegate to the bridge; it stays hidden until its navigation finishes;
   - keep the main web view hidden until its navigation finishes;
   - load `index.html` as today.
4. In `webView(_:didFinish:)`, branch on whether `webView` is the splash web view:
   - splash: show the splash web view, hide the backdrop, and if the main web view already finished, remove the splash web view;
   - main: show the main web view, remove the splash web view and hide the backdrop. The main web view's frontend overlay covers the first paint, so a splash web view that has not finished is skipped.
5. Keep the existing failure reporting for both web views.
6. Compiling and running the macOS app is CI-only. Write the review note in `tmp/evidence/compile/macos-splash-ci-only.txt` stating that this step is verified by the macOS CI build and smoke suite.
7. Update `~/projects/photosphere/ziggy/apps/ziggy-template/native/macos/ZiggyTemplate/AppDelegate.swift`, both examples' macOS `AppDelegate.swift` and Photosphere's macOS `AppDelegate.swift` to set `newWindow.contentView = newBridge.view` instead of `newBridge.webView`.

### Step 9: Show the splash in the iOS native app

1. In `~/projects/photosphere/ziggy/packages/ziggy/native/ios/Sources/ZiggyNativeIOS/ZiggyBridge.swift`, make the same change as the macOS bridge, with a `UIView` container, a `UIImageView` backdrop using `UIImage(named: "Splash")`, a separate splash scheme handler, and no injected script or `ziggy` message handler on the splash web view.
2. Set `backdrop.contentMode = .scaleAspectFill`, `backdrop.clipsToBounds = true` and `autoresizingMask = [.flexibleWidth, .flexibleHeight]`. Set the same autoresizing mask on the main and splash web views. The backdrop is visible from `init`, and the splash web view is hidden until its navigation finishes.
3. Use `WKNavigationDelegate` completion callbacks in the same splash before main order, and on the main web view's completion show the main web view, remove the splash web view and hide the backdrop.
4. Compiling and running the iOS app is CI-only. Write the review note in `tmp/evidence/compile/ios-splash-ci-only.txt`.
5. Update `~/projects/photosphere/ziggy/apps/ziggy-template/native/ios/ZiggyTemplate/ViewController.swift`, both examples' iOS `ViewController.swift` and Photosphere's iOS `ViewController.swift` to set `view = newBridge.view` instead of `view = newBridge.webView`.

### Step 10: Show the splash in the Android native app

1. In `~/projects/photosphere/ziggy/packages/ziggy/native/android/src/main/java/dev/ziggy/nativeapp/ZiggyNativeApp.java`, add `import android.view.View;` and `import android.widget.FrameLayout;`, and add fields for the splash WebView, the container, and the main and splash page-finished flags.
2. In `start`, after the core exists and `configureWebView` runs, check `ZiggyNative.uiFileContent("/ziggy-splash.html".getBytes(StandardCharsets.UTF_8)) != null`.
3. When the check is non-null:
   - create a `FrameLayout` and set it as the activity's content view;
   - when the main `webView` has a parent, remove it with `((ViewGroup) webView.getParent()).removeView(webView)`, add it to the container, hidden with `setVisibility(View.INVISIBLE)`;
   - create a second `WebView`, disable JavaScript, give it a `WebViewClient` whose `shouldInterceptRequest` serves `APP_URL_PREFIX` through the existing `uiResponse`, and add it above the main web view;
   - load `APP_URL_PREFIX + "ziggy-splash.html"` into the splash WebView.
4. In the main WebView's `onPageFinished`, when the splash WebView exists: set the main WebView visible, remove the splash WebView from the container and call `destroy()` on it, then set the splash field to null.
5. In the splash WebView's `onPageFinished`, set the splash WebView visible when it is still attached.
6. In `destroy`, destroy the splash WebView when it still exists.
7. When the check is null, keep the current single WebView behavior.
8. Compiling the Android app and running its smoke suite is CI-only. Write the review note in `tmp/evidence/compile/android-splash-ci-only.txt`.

### Step 11: Add the asset generator script

1. Create `~/projects/photosphere/ziggy/scripts/generate-app-assets.sh`, which takes two arguments: `--app <app directory>` and `--assets <assets directory relative to the app>`.
2. It reads `<app>/<assets>/assets.json` with `jq`, requiring:
   - `name`, `prefix`, `icon`, `foreground`, `portrait`, `landscape`, `background`, `macosTarget`, `iosTarget`.
3. It fails with a message naming the missing command when `jq`, `convert` or `identify` is not on `PATH`, and names any missing input file.
4. It writes these files with ImageMagick's `convert`:
   - `<assets>/<prefix>-1024.png` from `<icon>` at 1024x1024;
   - `<assets>/<prefix>-512.png` from `<icon>` at 512x512;
   - `<assets>/<prefix>.ico` from `<icon>` with `-define icon:auto-resize=256,128,64,48,32,24,16`;
   - `<assets>/splash-portrait.png` from `<portrait>` at 1290x2796;
   - `<assets>/splash-landscape.png` from `<landscape>` at 2796x1290;
   - `<assets>/splash-portrait.bmp` and `<assets>/splash-landscape.bmp` with `BMP3:`, a 24 bit uncompressed BMP from each splash PNG.
5. It writes the macOS and iOS asset catalogs under `<app>/native/macos/<macosTarget>/Assets.xcassets` and `<app>/native/ios/<iosTarget>/Assets.xcassets`:
   - the catalog root `Contents.json`;
   - the macOS `AppIcon.appiconset` with the sizes 16, 32, 64, 128, 256, 512 and 1024 pixels and a valid `Contents.json`; when an app iconset already exists, reuse the file names its `Contents.json` lists, so no unreferenced images remain;
   - the iOS `AppIcon.appiconset` with one 1024x1024 universal icon, `"platform": "ios"`, as the existing Photosphere iOS catalog does;
   - the macOS app icon PNGs have transparent corners with a rounded rectangle alpha mask at a 22.37 percent corner radius;
   - `ic_launcher_round.png` on Android has a circular alpha mask;
   - `SplashPortrait.imageset` and `SplashLandscape.imageset` for macOS, each with one 1x image;
   - `Splash.imageset` for iOS with portrait and landscape images in `Contents.json`, used by the bridge backdrop;
   - `SplashBackground.colorset` with the background colour, used by the system launch screen.
6. It writes the Android resources under `<app>/native/android/app/src/main/res`:
   - `mipmap-mdpi` through `mipmap-xxxhdpi` with `ic_launcher.png`, `ic_launcher_round.png` and `ic_launcher_foreground.png`;
   - `mipmap-anydpi-v26/ic_launcher.xml` and `ic_launcher_round.xml` using `<foreground android:drawable="@mipmap/ic_launcher_foreground"/>` and `<background android:drawable="@color/ic_launcher_background"/>`;
   - `values/ic_launcher_background.xml`, `values/splash.xml` with the background colour, `drawable/splash_background.xml` (a layer list with a solid `@color/splash_background` item and a `@drawable/splash` bitmap item with `android:gravity="fill"`), `drawable-port/splash.png` and `drawable-land/splash.png`;
   - `values/styles.xml` with `AppTheme` (parent `@android:style/Theme.DeviceDefault.NoActionBar`, `android:windowBackground` = `@drawable/splash_background`);
   - `values-v31/styles.xml` with `AppTheme` (same parent, `android:windowSplashScreenBackground` = `@color/splash_background`, `android:windowSplashScreenAnimatedIcon` = `@mipmap/ic_launcher_foreground`, `android:postSplashScreenTheme` = `@android:style/Theme.DeviceDefault.NoActionBar`).
7. The script writes every file with `printf` or `convert`, sets `-strip` on every PNG, and never calls `rm`.
8. Every generated `Contents.json` is formatted with 4 space indentation and ends with a newline.
9. Create `~/projects/photosphere/ziggy/scripts/generate-app-assets.md` describing the purpose, arguments, required commands and every output.
10. Run `mise exec -- bash scripts/generate-app-assets.sh --app apps/ziggy-template --assets assets` from `~/projects/photosphere/ziggy` after Step 12 adds the inputs, and run it for every app in Steps 12 and 13.
11. Check each output's dimensions with `identify` and write the output to `tmp/evidence/acceptance/assets.txt`.

### Step 12: Create the Ziggy template and example art, and generate their assets

1. In `~/projects/photosphere/ziggy/apps/ziggy-template/assets/`, create:
   - `assets.json`;
   - `app-icon.svg`;
   - `app-icon-foreground.svg`;
   - `splash-portrait.svg`;
   - `splash-landscape.svg`.
2. Use these values for the template:
   - background `#1B1035`;
   - gradient `#8B5CF6` to `#22D3EE`;
   - a bold geometric zigzag mark that reads as a `Z`, made from one filled path about 90 pixels wide at 1024 pixels;
   - a small amber `#FBBF24` dot at the lower right of the mark.
3. `app-icon.svg` is a full-bleed 1024x1024 square with the gradient background and the mark centred at 62 percent of the canvas.
4. `app-icon-foreground.svg` has a transparent background and the same mark centred at 58 percent of the canvas, within Android's safe zone.
5. `splash-portrait.svg` is 1290x2796: the same background, the mark at 40 percent of the width centred at 38 percent of the height, the title `Ziggy template` in `DejaVu Sans` at 86 pixels in white below it, and a 240x8 pixel gradient rule under the title.
6. `splash-landscape.svg` is 2796x1290: the mark at 30 percent of the height on the left, and the title plus the rule on the right.
7. Do not use SVG filters, masks or external references. Use only paths, rects, circles, linear gradients and text.
8. Write `assets.json` as:
```
{
    "name": "Ziggy template",
    "prefix": "app-icon",
    "icon": "app-icon.svg",
    "foreground": "app-icon-foreground.svg",
    "portrait": "splash-portrait.svg",
    "landscape": "splash-landscape.svg",
    "background": "#1B1035",
    "macosTarget": "ZiggyTemplate",
    "iosTarget": "ZiggyTemplate"
}
```
9. In `~/projects/photosphere/ziggy-example-vite/assets/` and `~/projects/photosphere/ziggy-example-rsbuild/assets/`, create the same five files with these differences:
   - Vite example: name `Ziggy Vite example`, background `#241B0A`, gradient `#FDE047` to `#A855F7`, title `Ziggy Vite example`, macOS and iOS targets `ZiggyExampleVite`;
   - Rsbuild example: name `Ziggy Rsbuild example`, background `#0B1B2E`, gradient `#3B82F6` to `#FB923C`, title `Ziggy Rsbuild example`, macOS and iOS targets `ZiggyExampleRsbuild`.
10. Run the generator for the template and both examples:
    - from `~/projects/photosphere/ziggy`, `mise exec -- bash scripts/generate-app-assets.sh --app apps/ziggy-template --assets assets`;
    - from `~/projects/photosphere/ziggy-example-vite`, `mise exec -- bash ../ziggy/scripts/generate-app-assets.sh --app . --assets assets`;
    - from `~/projects/photosphere/ziggy-example-rsbuild`, `mise exec -- bash ../ziggy/scripts/generate-app-assets.sh --app . --assets assets`.
11. Run `identify` on every PNG and `file` on every ICO, and write the results to each repository's `tmp/evidence/acceptance/assets.txt`.

### Step 13: Create the Photosphere art and generate its assets

1. In `~/projects/photosphere/photosphere/apps/photosphere/icons/`, create `assets.json`, `photosphere-icon.svg`, `photosphere-icon-foreground.svg`, `splash-portrait.svg` and `splash-landscape.svg`.
2. Copy the existing `photosphere_logo.svg` path data from `~/projects/photosphere/photosphere-web-page/assets/photosphere_logo.svg` into the icon and splash SVGs, and scale it to fit the canvas.
3. Use the brand colours from that logo:
   - background `#140A24` to `#2A0F3D`;
   - gradient stops `#6C25A7`, `#FB7185` and `#FBBF24`.
4. `photosphere-icon.svg` is a full-bleed 1024x1024 square with the brand gradient, a white aperture ring at the centre, and the existing logo path scaled inside it.
5. `photosphere-icon-foreground.svg` is the same mark on a transparent canvas at 58 percent of the width.
6. `splash-portrait.svg` is 1290x2796: the brand gradient background, the logo at 55 percent of the width centred at 38 percent of the height, the word `Photosphere` in `DejaVu Sans` at 92 pixels in white, and the line `Your photos. Under your control.` in 44 pixel white at 75 percent opacity.
7. `splash-landscape.svg` is 2796x1290: the logo at 30 percent of the height on the left, and the wordmark and line on the right.
8. Write `assets.json` as:
```
{
    "name": "Photosphere",
    "prefix": "photosphere",
    "icon": "photosphere-icon.svg",
    "foreground": "photosphere-icon-foreground.svg",
    "portrait": "splash-portrait.svg",
    "landscape": "splash-landscape.svg",
    "background": "#140A24",
    "macosTarget": "Photosphere",
    "iosTarget": "Photosphere"
}
```
9. Run `mise exec -- bash ~/projects/photosphere/ziggy/scripts/generate-app-assets.sh --app . --assets icons` from `~/projects/photosphere/photosphere/apps/photosphere`.
10. Run `identify` on every PNG and `file` on the ICO, and write the results to `~/projects/photosphere/photosphere/tmp/evidence/acceptance/assets.txt`.

### Step 14: Wire the Ziggy template's icons and splash

1. In `~/projects/photosphere/ziggy/apps/ziggy-template/app.zon`, add:
```
    .splash = .{
        .background = "#1B1035",
        .portrait = "assets/splash-portrait.png",
        .landscape = "assets/splash-landscape.png",
    },
```
2. In `~/projects/photosphere/ziggy/apps/ziggy-template/build.zig`, set:
   - `.linux_icon = "assets/app-icon-512.png"`;
   - `.windows_resource = "native/windows/ziggy-template.rc"`.
3. Create `~/projects/photosphere/ziggy/apps/ziggy-template/native/windows/ziggy-template.rc` containing:
```
// The icon of the Ziggy template's executable. The id is even because Ziggy's native app passes it to
// LoadIconW as an integer resource id.
2 ICON "../../assets/app-icon.ico"
```
4. In `~/projects/photosphere/ziggy/apps/ziggy-template/native/linux/src/main.zig`, set `.icon_png = @embedFile("app-icon")`.
5. In `~/projects/photosphere/ziggy/apps/ziggy-template/native/windows/src/main.zig`, set `.icon_resource = 2`.
6. In `~/projects/photosphere/ziggy/apps/ziggy-template/native/macos/ZiggyTemplate.xcodeproj/project.pbxproj`:
   - add a `PBXFileReference` for `Assets.xcassets` with `lastKnownFileType = folder.assetcatalog`;
   - add a `PBXBuildFile` and a `PBXResourcesBuildPhase` entry;
   - add the file reference to the app's group;
   - set `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` in both build configurations.
7. Do the same in `~/projects/photosphere/ziggy/apps/ziggy-template/native/ios/ZiggyTemplate.xcodeproj/project.pbxproj`.
8. In `~/projects/photosphere/ziggy/apps/ziggy-template/native/ios/ZiggyTemplate/Info.plist`, replace the empty `UILaunchScreen` dictionary with:
```
    <key>UILaunchScreen</key>
    <dict>
        <key>UIColorName</key>
        <string>SplashBackground</string>
    </dict>
```
The system launch screen is the brand colour. The bridge's backdrop image and the splash web view show the full art immediately after, and the matching background makes the change invisible.
9. In `~/projects/photosphere/ziggy/apps/ziggy-template/native/android/app/src/main/AndroidManifest.xml`, set `android:icon="@mipmap/ic_launcher"`, `android:roundIcon="@mipmap/ic_launcher_round"` and `android:theme="@style/AppTheme"` on the `<application>` element.
10. In `~/projects/photosphere/ziggy/apps/ziggy-template/frontend/src/main.ts`, add:
    - `import { installSplashScreen } from "ziggy";`
    - `const splash = installSplashScreen(document, { background: "#1B1035", minimumDisplayMilliseconds: 600, fadeDurationMilliseconds: 400 });` as the first statement;
    - `void splash.remove();` after the existing listeners and test-command setup.
11. Run `mise exec -- bun run compile`, `mise exec -- bun run test`, `mise exec -- bun run test:zig`, `mise exec -- bun run --filter=ziggy-template compile:zig`, `mise exec -- bun run build:ziggy-template:linux` and `mise exec -- bun run --filter=ziggy-template test:smoke` in `~/projects/photosphere/ziggy`.
12. Write the evidence to `tmp/evidence/compile/ziggy-template.txt` and `tmp/evidence/tests/ziggy-template.txt`.

### Step 15: Wire the Vite example's icons and splash

1. In `~/projects/photosphere/ziggy-example-vite/app.zon`, add the same `.splash` block, with paths `assets/splash-portrait.png` and `assets/splash-landscape.png` and background `#241B0A`.
2. In `~/projects/photosphere/ziggy-example-vite/build.zig`, set `.linux_icon = "assets/app-icon-512.png"` and `.windows_resource = "native/windows/ziggy-example-vite.rc"`.
3. Create `~/projects/photosphere/ziggy-example-vite/native/windows/ziggy-example-vite.rc` with `2 ICON "../../assets/app-icon.ico"` and the same two comment lines as the template's `.rc`.
4. Set `.icon_png = @embedFile("app-icon")` in `native/linux/src/main.zig` and `.icon_resource = 2` in `native/windows/src/main.zig`.
5. Add `Assets.xcassets` to both Xcode projects as in Step 14, including `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`.
6. Update `native/ios/ZiggyExampleVite/Info.plist` with the `UILaunchScreen` dictionary from Step 14.
7. In `native/android/app/src/main/AndroidManifest.xml`, set the icon, round icon and `@style/AppTheme` as in Step 14.
8. In `frontend/src/main.ts`, install the splash first with background `#241B0A`, the same 600 and 400 millisecond values, and call `remove()` after the listeners and `listenForTestCommands()`.
9. Replace the Ziggy links with the sibling checkout:
   - in `build.zig.zon`, set `.ziggy = .{ .path = "../ziggy" }`;
   - in `package.json`, set `"ziggy": "file:../ziggy/packages/ziggy/frontend"` and `"ziggy-remote-control-server": "file:../ziggy/tools/remote-control-server"`;
   - in both Xcode projects, replace the `XCRemoteSwiftPackageReference` with an `XCLocalSwiftPackageReference` whose `relativePath` is `../../../ziggy`, keeping the same object id and product dependencies;
   - in `native/android/settings.gradle`, replace the `sourceControl` block with:
```
includeBuild('../../../ziggy/packages/ziggy/native/android') {
    dependencySubstitution {
        substitute module('dev.ziggy:ziggy-native-android') using project(':')
    }
}
```
10. In `native/macos/ZiggyExampleVite/AppDelegate.swift` and `native/ios/ZiggyExampleVite/ViewController.swift`, set the window or controller content to `newBridge.view`.
11. Run `mise exec -- bun install`, `mise exec -- bun run compile`, `mise exec -- bun run test`, `mise exec -- bun run test:zig`, `mise exec -- bun run compile:zig`, `mise exec -- bun run build:linux` and `mise exec -- bun run test:smoke` in `~/projects/photosphere/ziggy-example-vite`.
12. Write the evidence to `tmp/evidence/{compile,tests}/vite-example.txt`.

### Step 16: Wire the Rsbuild example's icons and splash

1. Repeat Step 15 in `~/projects/photosphere/ziggy-example-rsbuild` with these names and values:
   - background `#0B1B2E`;
   - Windows resource `native/windows/ziggy-example-rsbuild.rc`;
   - Xcode target `ZiggyExampleRsbuild`;
   - the same local Ziggy paths (`../ziggy` for `build.zig.zon` and `package.json`, `../../../ziggy` for Xcode and Gradle).
2. Run the same commands in `~/projects/photosphere/ziggy-example-rsbuild`.
3. Write the evidence to `tmp/evidence/{compile,tests}/rsbuild-example.txt`.

### Step 17: Wire Photosphere's icons and splash

1. In `~/projects/photosphere/photosphere/app.zon`, add:
```
    .splash = .{
        .background = "#140A24",
        .portrait = "apps/photosphere/icons/splash-portrait.png",
        .landscape = "apps/photosphere/icons/splash-landscape.png",
    },
```
2. Keep `build.zig`'s `.linux_icon = "apps/photosphere/icons/photosphere-512.png"` and `.windows_resource = "apps/photosphere/native/windows/photosphere.rc"`; the generator overwrites both files.
3. In `apps/photosphere/native/macos/Photosphere/AppDelegate.swift` and `apps/photosphere/native/ios/Photosphere/ViewController.swift`, set the window or controller content to `newBridge.view`.
4. In both Photosphere Xcode projects, replace the `XCRemoteSwiftPackageReference` with an `XCLocalSwiftPackageReference` whose `relativePath` is `../../../../../ziggy`, keeping the same object id and product dependencies.
5. In `apps/photosphere/native/ios/Photosphere/Info.plist`, replace the empty `UILaunchScreen` dictionary with the `SplashBackground` dictionary from Step 14.
6. In `apps/photosphere/native/android/settings.gradle`, replace the `sourceControl` block with an `includeBuild` whose path is `../../../../../ziggy/packages/ziggy/native/android` and the same `dependencySubstitution` as Step 15.
7. In `apps/photosphere/native/android/app/src/main/AndroidManifest.xml`, set `android:icon="@mipmap/ic_launcher"`, `android:roundIcon="@mipmap/ic_launcher_round"` and `android:theme="@style/AppTheme"` on the `<application>` element.
8. In `apps/photosphere-frontend/src/main.tsx`:
   - import `installSplashScreen` from `ziggy`;
   - after the `ziggy` bridge check, create `const splash = installSplashScreen(document, { background: "#140A24", minimumDisplayMilliseconds: 600, fadeDurationMilliseconds: 400 });`;
   - after `root.render(...)`, wait for two `requestAnimationFrame` callbacks and then call `void splash.remove();`, so React has painted the first frame under the overlay.
9. In `photosphere/package.json`, set `"ziggy-remote-control-server": "file:../ziggy/tools/remote-control-server"`.
10. Run `mise exec -- bun install`, `mise exec -- bun run compile`, `mise exec -- bun run test`, `mise exec -- bun run test:zig`, `mise exec -- bun run --filter=ziggy build:linux` and `mise exec -- bun run test:ziggy` in `~/projects/photosphere/photosphere`.
11. Write the evidence to `tmp/evidence/{compile,tests}/photosphere.txt`.

### Step 18: Write the documentation

1. Create `~/projects/photosphere/ziggy/docs/user-guide/app-icons-and-splash.md` describing:
   - the `.splash` field of `app.zon`, with an example and the meaning of `background`, `portrait` and `landscape`;
   - the requirement that `<portrait>.bmp` and `<landscape>.bmp` sit beside the PNGs;
   - the `ziggy-splash.html`, `ziggy-splash-portrait.png` and `ziggy-splash-landscape.png` files Ziggy adds to the UI files, and the reserved paths;
   - the native sequence on each platform;
   - the frontend API `installSplashScreen` and `ISplashScreen.remove`, with the minimum display and fade behaviour;
   - the app icon layout for Linux, Windows, macOS, iOS and Android;
   - the `scripts/generate-app-assets.sh` invocation and `assets.json` fields;
   - that dev mode runs in a browser and loads straight into the UI, and that `installSplashScreen` removes the overlay when the image fails to load.
2. Add the new document to the guide index in `~/projects/photosphere/ziggy/docs/user-guide.md`.
3. Add a v0.0.24 entry to `~/projects/photosphere/ziggy/docs/upgrade-notes.md`:
   - `ZiggyBridge.view` is the window or controller content for macOS and iOS apps; `ZiggyBridge.webView` remains the main web view;
   - `.splash` is new and optional.
4. Update `~/projects/photosphere/ziggy/apps/ziggy-template/README.md`, `~/projects/photosphere/ziggy-example-vite/README.md`, `~/projects/photosphere/ziggy-example-rsbuild/README.md` and `~/projects/photosphere/photosphere/docs/photosphere-on-ziggy.md` with one short section each naming their icon and splash assets and the local Ziggy paths.
5. Check every edited document for em dashes, absolute paths containing a user name and stale version references.
6. Write the documentation diff summary to each repository's `tmp/evidence/acceptance/documentation.txt`.

### Step 19: Verify

1. In `~/projects/photosphere/ziggy`, run each command and write its exit status and final summary lines to `tmp/evidence/`:
   - `mise exec -- bun run compile` to `tmp/evidence/compile/ziggy.txt`;
   - `mise exec -- bun run test` to `tmp/evidence/tests/ziggy.txt`;
   - `mise exec -- bun run test:zig` to `tmp/evidence/tests/ziggy-zig.txt`;
   - `mise exec -- bun run test:smoke` to `tmp/evidence/tests/ziggy-smoke.txt`;
   - `mise exec -- bun run --filter=ziggy-template test:smoke` to `tmp/evidence/tests/ziggy-template-smoke.txt`;
   - `mise exec -- bun run --filter=ziggy-template compile:zig` to `tmp/evidence/compile/ziggy-template-cross.txt`;
   - `mise exec -- bun run build:ziggy-template:linux` to `tmp/evidence/compile/ziggy-template-linux.txt`.
2. In `~/projects/photosphere/ziggy-example-vite`, run and record:
   - `mise exec -- bun run compile`;
   - `mise exec -- bun run test`;
   - `mise exec -- bun run test:zig`;
   - `mise exec -- bun run compile:zig`;
   - `mise exec -- bun run build:linux`;
   - `mise exec -- bun run test:smoke`.
3. In `~/projects/photosphere/ziggy-example-rsbuild`, run the same six commands and record them.
4. In `~/projects/photosphere/photosphere`, run and record:
   - `mise exec -- bun run compile`;
   - `mise exec -- bun run test`;
   - `mise exec -- bun run test:zig`;
   - `mise exec -- bun run --filter=ziggy build:linux`;
   - `mise exec -- bun run test:ziggy`.
5. Capture acceptance screenshots on this Linux machine:
   - start each built Linux binary in the background and keep its pid:
     - `~/projects/photosphere/ziggy/apps/ziggy-template/native/linux/zig-out/bin/ziggy-template`;
     - `~/projects/photosphere/ziggy-example-vite/native/linux/zig-out/bin/ziggy-example-vite`;
     - `~/projects/photosphere/ziggy-example-rsbuild/native/linux/zig-out/bin/ziggy-example-rsbuild`;
     - `~/projects/photosphere/photosphere/apps/photosphere/native/linux/zig-out/bin/photosphere`;
   - poll every 0.1 seconds for up to 10 seconds with `wmctrl -l` (or `xwininfo -root -tree` when `wmctrl` lists no window) for the window whose title is the app's title from its `app.zon`; capture it at once with `import -window <id> <repo>/tmp/evidence/acceptance/<app>-splash.png`;
   - wait 2 seconds and capture the same window to `<app>-loaded.png`;
   - stop the process with `kill` on the pid that was started.
   - Do this for the Ziggy template, the Vite example, the Rsbuild example and Photosphere.
6. Inspect every screenshot with the Read tool. The splash screenshot must show the splash art and no UI. The loaded screenshot must show the app's normal UI. If a screenshot does not show the expected state, adjust the sleep and capture again.
7. Record the CI-only checks in `tmp/evidence/compile/ci-only.txt`: the macOS and iOS Swift builds and smoke suites, and the Android Java, Gradle and smoke suites. Local checks use the Linux builds only.

### Step 20: Self Review

1. Read every file under `tmp/evidence/` in all four repositories.
2. Check each item in the `Review` checklist below and tick it only when the evidence confirms it.
3. If any step is incomplete, uncheck it, add the missing step before `Verify`, and restart from the first unchecked step.
4. Do not collect new evidence in this step. Use the evidence the earlier steps saved.

## Unit Tests

- `packages/ziggy/core/src/test/splash.test.zig`: `orientation` for portrait, landscape and square sizes; `html` includes the colour, both paths, the landscape media query and valid HTML escaping.
- `packages/ziggy/frontend/src/test/splash.test.ts`: `easeOutCubic` at 0, 0.5 and 1; overlay creation with a fake document; `remove()` waits for the minimum display, follows the eased opacity and removes the element.
- `packages/ziggy/native/windows/src/test/splash-windows.test.zig`: `parseColor` accepts `#RRGGBB` and rejects malformed values; `bitmap` reads a valid BMP header and rejects a truncated or unsupported one.
- Build-script helpers in `build.zig` have no unit test because a build script is not part of a test program. They are exercised by every app build and by the cross-build checks.
- The native Linux, Windows, macOS, iOS and Android splash callbacks are platform shell code and are covered by the desktop smoke tests and the acceptance screenshots. The Swift and Java shells are compiled by CI.

## Smoke Tests

- Ziggy test app: `mise exec -- bun run test:smoke` proves the native app still runs with no splash configured.
- Ziggy template: `mise exec -- bun run --filter=ziggy-template test:smoke` proves the hello-world UI works with the splash enabled.
- Vite example: `mise exec -- bun run test:smoke`.
- Rsbuild example: `mise exec -- bun run test:smoke`.
- Photosphere: `mise exec -- bun run test:ziggy`.
- Screenshot acceptance for the Ziggy template, both examples and Photosphere: `<app>-splash.png` shows the splash art, and `<app>-loaded.png` shows the normal UI.
- CI-only: the macOS, iOS and Android smoke suites.

## Verify

- The code compiles in all four repositories: Ziggy (`bun run compile`, `bun run test:zig`, `compile:zig` for the template), both examples (`bun run compile`, `bun run test:zig`, `bun run compile:zig`) and Photosphere (`bun run compile`, `bun run test:zig`, `bun run --filter=ziggy build:linux`).
- All unit tests pass: Ziggy (`bun run test`, `bun run test:zig`), both examples (`bun run test`, `bun run test:zig`) and Photosphere (`bun run test`, `bun run test:zig`).
- All smoke tests pass: Ziggy (`bun run test:smoke`, `bun run --filter=ziggy-template test:smoke`), both examples (`bun run test:smoke`) and Photosphere (`bun run test:ziggy`).
- The Linux apps build and launch, and the acceptance screenshots exist for each app and show the splash and loaded states.
- The generated icon files exist for every app on every platform: Linux PNG, Windows ICO, macOS and iOS app icon sets, and Android mipmaps.
- CI-only: the macOS and iOS Swift builds and smoke suites, and the Android Gradle build and smoke suite. Local checks use the Linux builds only.
- Evidence is in each repository's `tmp/evidence/compile`, `tmp/evidence/tests` and `tmp/evidence/acceptance`.

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

None.

## Notes

- `app.zon` is read by `readAppDetails` in `build.zig` with Zig's ZON parser, and an unknown field fails the build. `.splash` is added to `IAppDetails` before any app uses it.
- The core's UI file list is the single source for the splash page and its images. `embedUi` adds `ziggy-splash.html`, `ziggy-splash-portrait.png` and `ziggy-splash-landscape.png` to that list, and every native app serves them through the existing `ziggy_ui_file`, URI scheme and JNI paths. The frontend overlay and the splash web view therefore use the same files.
- The native flow is: paint the splash colour and image in the window, show a splash web view over it, load the main web view hidden underneath, show the main web view when it has loaded, destroy the splash web view, then fade the frontend's matching overlay and remove it.
- Linux uses a `GtkOverlay` with a `GtkPicture` and a second `WebKitWebView`. Windows uses a second WebView2 controller and paints the native window with an embedded BMP. macOS and iOS use a container view with a second `WKWebView` and a bundle `Splash` image set. Android uses a `FrameLayout` with a second `WebView` and the existing system splash theme.
- The Windows native background uses uncompressed BMPs because the app already includes `windows.h` and can draw a DIB with `StretchDIBits` without a new decoder. The PNGs remain the source for every other platform and for both web views.
- The frontend `installSplashScreen` uses a 600 millisecond minimum display and a 400 millisecond fade in every app. The fade uses `easeOutCubic`, so it is not linear.
- Dev mode runs the frontend in an ordinary browser, where the overlay's image request reaches the dev server and fails; the error handler removes the overlay, and the app loads without a splash.
- `convert` is ImageMagick 6.9.12 on this machine and renders SVG through its internal MSVG renderer. The art uses paths, rects, circles, linear gradients and text, which that renderer supports.
- The examples' `build.zig.zon` and `package.json` currently point at a stale Ziggy worktree. The plan replaces those with the sibling checkout, and also replaces the remote Xcode and Gradle references, so every part of each example builds against the same local Ziggy.
- Photosphere already takes Ziggy from `../ziggy` in `build.zig.zon` and in `apps/photosphere-frontend/package.json`. The plan extends that to the Xcode projects, the Android Gradle build and the remote control server.
- The macOS and iOS Swift changes and the Android Java changes are verified by CI, because this machine runs Linux. The plan records the CI-only checks explicitly.
- The plan ends with local changes in the four checkouts.