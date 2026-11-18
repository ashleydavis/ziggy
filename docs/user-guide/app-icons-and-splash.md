# App icons and splash screens

An app shows its icon in the window, the taskbar, the launcher and the app store, and a splash screen while its frontend loads. Ziggy gives both to every platform from the art the app declares.

## Declaring a splash screen

Add `.splash` to the app's `app.zon`:

```zig
.{
    .name = "my-app",
    .title = "My app",
    .splash = .{
        .background = "#140A24",
        .portrait = "assets/splash-portrait.png",
        .landscape = "assets/splash-landscape.png",
    },
}
```

- `background` is the CSS colour behind the images. It is also the colour the native window and the system launch screen use, so the change from the system splash to the app's is invisible.
- `portrait` is the PNG shown when the window is taller than it is wide.
- `landscape` is the PNG shown when the window is at least as wide as it is tall.

The paths are relative to the app's build root. A 1290x2796 portrait image and a 2796x1290 landscape image match every screen the app runs on.

Two uncompressed 24 bit BMP files must sit beside the PNGs, with the same names and the `.png` suffix replaced by `.bmp`: `assets/splash-portrait.bmp` and `assets/splash-landscape.bmp` in the example above. The Windows native app paints the window with them before WebKit has loaded anything, and a missing one fails the build, naming the file.

## What Ziggy adds to the UI files

When `.splash` is present, Ziggy adds three files to the app's UI files, the list of files the core serves to every web view:

- `ziggy-splash.html`: the generated page, a `<picture>` with the landscape image for a landscape window and the portrait image otherwise, and the background colour.
- `ziggy-splash-portrait.png`: the portrait image.
- `ziggy-splash-landscape.png`: the landscape image.

Those three paths are reserved: an app's own built frontend must not contain files with those names. Every native app serves them through the same path it serves the app's frontend, so the frontend's own overlay shows the same art as the native picture.

## The native sequence

Each platform shows the splash in four steps:

1. The window opens showing the native picture of the splash art. It renders on the first frame, with no solid colour (no white, black or anything else) shown before the image.
2. The app's web view is created behind the native picture and loads the frontend. The frontend sends `frontend-ready` when it has loaded and rendered.
3. The native picture is removed to reveal the app's web view, which shows the frontend's own splash overlay. The native app sends `frontend-visible` to the frontend.
4. On `frontend-visible`, the frontend fades its own splash overlay out over two seconds.

What each platform uses:

- **Linux**: a `GtkDrawingArea` paints the image cover-scaled, because GTK 3 has no `GtkPicture`.
- **Windows**: the window's `WM_PAINT` fills the client area with the background brush and stretches the BMP with `StretchDIBits`.
- **macOS**: the bridge's `view` is an `NSView` containing an `NSImageView` backdrop from `SplashPortrait` and `SplashLandscape` in the app's asset catalog.
- **iOS**: the bridge's `view` is a `UIView` containing a `UIImageView` backdrop from the `Splash` image set. The system launch screen uses the `SplashBackground` colour.
- **Android**: the system splash theme uses the background colour and the launcher foreground.

On macOS and iOS, put `newBridge.view` on screen, not `newBridge.webView`. `webView` remains the app's own web view.

## The frontend overlay

The frontend keeps its own overlay that matches the native splash, and fades it out once the app has painted. It is app code, not part of Ziggy: the template's `frontend/src/lib/splash.ts` is the copy to start from.

```ts
import { installSplashScreen } from "./lib/splash";

const splash = installSplashScreen(document, {
    background: "#140A24",
    minimumDisplayMilliseconds: 2000,
    fadeDurationMilliseconds: 2000,
});

// Once the app has rendered its first frame:
splash.remove().catch(error => {
    console.error(`The splash screen could not be removed: ${error}`);
});
```

`installSplashScreen(documentLike, options)` accepts either the browser's `Document` or the minimal `IDocumentLike` interface its tests use. It creates a `div` with `data-id="ziggy-splash"` at `z-index: 2147483647`, with a `<picture>` holding the portrait image and a landscape `<source>`.

`remove()` waits until `minimumDisplayMilliseconds` has passed since the overlay was installed, fades the overlay's opacity from 1 to 0 over `fadeDurationMilliseconds` with the cubic-bezier(0.4, 0, 0.2, 1) curve, then removes it. Calling it twice, or after the overlay has gone, resolves at once.

In dev mode the frontend runs in an ordinary browser, where the core serves no splash files. The overlay's image request fails, its `error` listener removes the overlay, and the app loads straight into its UI.

## App icons

The icon files each platform needs:

- **Linux**: `assets/<prefix>-512.png`, named by the app's build as `.linux_icon`.
- **Windows**: `assets/<prefix>.ico` at 256, 128, 64, 48, 32, 24 and 16 pixels, named by the app's resource script as `.windows_resource`.
- **macOS**: `AppIcon.appiconset` in the macOS target's `Assets.xcassets`, with PNGs at 16, 32, 64, 128, 256, 512 and 1024 pixels. Each has transparent corners rounded at 22.37 percent of its size.
- **iOS**: `AppIcon.appiconset` in the iOS target's `Assets.xcassets`, with one 1024x1024 universal icon.
- **Android**: `ic_launcher.png`, `ic_launcher_round.png` and `ic_launcher_foreground.png` in `mipmap-mdpi` through `mipmap-xxxhdpi`, the adaptive icon XMLs in `mipmap-anydpi-v26`, and the background colour in `values/ic_launcher_background.xml`.

The macOS and iOS asset catalogs, and the Android resources, are generated by `scripts/generate-app-assets.sh` from the app's SVG art. The Xcode projects must include the asset catalog in their Resources phase and set `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`.

## Generating the assets

An app keeps its art in an assets directory with an `assets.json`:

```json
{
    "name": "My app",
    "prefix": "my-app",
    "icon": "my-app-icon.svg",
    "foreground": "my-app-icon-foreground.svg",
    "portrait": "splash-portrait.svg",
    "landscape": "splash-landscape.svg",
    "background": "#140A24",
    "macosTarget": "MyApp",
    "iosTarget": "MyApp"
}
```

- `name` is the app's name as people read it.
- `prefix` names the generated PNG and ICO icons.
- `icon` is the full-bleed square app icon.
- `foreground` is the Android adaptive icon's foreground, on a transparent canvas.
- `portrait` and `landscape` are the splash images.
- `background` is the splash background colour, `#RRGGBB`.
- `macosTarget` and `iosTarget` are the Xcode targets whose asset catalogs the script writes.

Run the generator from the app's repository:

```
bash <ziggy>/scripts/generate-app-assets.sh --app . --assets assets
```

It needs `jq`, ImageMagick's `convert` and `identify`, and `google-chrome`, `chromium` or `chromium-browser`. It renders each SVG with the browser's headless mode, because ImageMagick's own SVG renderer draws gradient fills black, then uses ImageMagick to resize, mask and write the PNGs, the ICO and the BMPs. See [the script's own document](../../scripts/generate-app-assets.md) for every output.

An existing macOS app icon set keeps the file names its `Contents.json` lists, so regenerating an app's art leaves no unreferenced images.
