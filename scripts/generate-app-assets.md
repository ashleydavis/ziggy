# generate-app-assets.sh

Generates an app's icons and splash screens for Linux, Windows, macOS, iOS and Android from the SVG art named in the app's `assets.json`, and writes the macOS, iOS and Android resource files the native apps need.

## Invocation

From the app's repository:

```
bash scripts/generate-app-assets.sh --app <app directory> --assets <assets directory relative to the app>
```

- `--app <app directory>` is the app's directory, relative to the repository root. `.` means the repository root.
- `--assets <assets directory>` is the directory holding `assets.json` and the SVG art, relative to `--app`.

Run it after adding or changing any of the art. It writes every output every time.

## Required commands

`jq`, ImageMagick's `convert` and ImageMagick's `identify` must be on `PATH`. The script stops with the missing command's name when one is not.

`google-chrome`, `chromium` or `chromium-browser` must be on `PATH` too. ImageMagick's own SVG renderer draws no gradient fills, so the script renders each SVG with the browser's headless mode and uses ImageMagick to resize and mask the result.

## Inputs

`<app>/<assets>/assets.json` must hold these fields:

- `name`: the app's name as people read it.
- `prefix`: the file name prefix of the PNG and ICO icons.
- `icon`: the full-bleed app icon SVG, a 1024x1024 square.
- `foreground`: the Android adaptive icon foreground SVG, transparent.
- `portrait`: the portrait splash SVG, 1290x2796.
- `landscape`: the landscape splash SVG, 2796x1290.
- `background`: the splash background colour, `#RRGGBB`.
- `macosTarget`: the macOS Xcode target's directory name.
- `iosTarget`: the iOS Xcode target's directory name.

## Outputs

### In the assets directory

- `<prefix>-1024.png`: the app icon at 1024x1024.
- `<prefix>-512.png`: the app icon at 512x512, for the Linux window icon.
- `<prefix>.ico`: the Windows executable icon at 256, 128, 64, 48, 32, 24 and 16 pixels.
- `splash-portrait.png`: the portrait splash at 1290x2796.
- `splash-landscape.png`: the landscape splash at 2796x1290.
- `splash-portrait.bmp` and `splash-landscape.bmp`: 24 bit uncompressed BMPs the Windows native app paints with.

### In the macOS asset catalog

`<app>/native/macos/<macosTarget>/Assets.xcassets`:

- `Contents.json`: the catalog's index.
- `AppIcon.appiconset/Contents.json` and the icon PNGs at 16, 32, 64, 128, 256, 512 and 1024 pixels. Each PNG has transparent corners with a rounded rectangle at 22.37 percent of its size. An existing icon set's file names are kept.
- `SplashPortrait.imageset/`: `splash-portrait.png` and `Contents.json`.
- `SplashLandscape.imageset/`: `splash-landscape.png` and `Contents.json`.
- `SplashBackground.colorset/Contents.json`: the splash background colour.

### In the iOS asset catalog

`<app>/native/ios/<iosTarget>/Assets.xcassets`:

- `Contents.json`: the catalog's index.
- `AppIcon.appiconset/Contents.json` and `AppIcon-512@2x.png`: one 1024x1024 universal icon.
- `Splash.imageset/`: `splash-portrait.png`, `splash-landscape.png` and a `Contents.json` that picks between them by the size class.
- `SplashBackground.colorset/Contents.json`: the splash background colour.

### In the Android resources

`<app>/native/android/app/src/main/res`:

- `mipmap-mdpi`, `mipmap-hdpi`, `mipmap-xhdpi`, `mipmap-xxhdpi` and `mipmap-xxxhdpi`, each with `ic_launcher.png`, `ic_launcher_round.png` (a circular mask) and `ic_launcher_foreground.png`.
- `mipmap-anydpi-v26/ic_launcher.xml` and `ic_launcher_round.xml`: the adaptive icons.
- `values/ic_launcher_background.xml`: the adaptive icon's background colour.
- `values/splash.xml`: the splash background colour.
- `drawable/splash_background.xml`: the splash layer list.
- `drawable-port/splash.png` and `drawable-land/splash.png`: the splash images.
- `values/styles.xml`: `AppTheme` with the splash background as the window background.
- `values-v31/styles.xml`: `AppTheme` with the Android 12 system splash settings.
