# Ziggy template

An app built on [Ziggy](https://github.com/ashleydavis/ziggy), with JavaScript/TypeScript, HTML and CSS for the frontend and Zig for everything else.

The same code-base builds for Linux, Windows, macOS, Android and iOS, using each platform's system web view for the frontend. It starts from Ziggy's template, with a hello world of a message, a task and a menu, each with its tests, for you to change into your own code.

Check Ziggy's [glossary](https://github.com/ashleydavis/ziggy/blob/main/docs/glossary.md) to understand the jargon.

## Set up, test and run

Install what your platform needs first: see Ziggy's [Dependencies](https://github.com/ashleydavis/ziggy/blob/main/docs/user-guide/dependencies.md).

```bash
bun run setup       # Once per machine, only to build for Windows, Android or iOS.

bun run compile     # Type-checks the frontend.
bun run test        # Runs the frontend's unit tests.
bun run test:zig    # Builds the backend and runs its unit tests.
bun run test:smoke  # Builds your app and runs its smoke tests in a hidden window.

bun run linux       # Builds and runs your app on Linux.
bun run windows     # Builds and runs your app on Windows.
bun run macos       # Builds and runs your app on macOS.

bun run dev         # Runs the frontend in your browser with dev mode, which reloads as you save.
```

## Where things are

- `frontend/`: the frontend (TypeScript and HTML), which runs in the system web view.
- `backend/`: the Zig backend, with its message handlers, task handlers and menu.
- `native/`: the native project for each platform.
- `scripts/`: the scripts to set up, build, run and package the app, each with a markdown file beside it.
- `smoke-tests/`: the smoke tests, which drive the real app.
- `.github/workflows/`: the GitHub Actions workflows that test the app and publish a release for each platform.

## Icons and splash screens

The app's icon and splash art are the SVGs in `assets/`, named by `assets.json`. `.splash` in `app.zon` gives every native app and the frontend the background colour and the portrait and landscape splash images. Regenerate the icons and splash images for every platform with `bash scripts/generate-app-assets.sh --app apps/ziggy-template --assets assets` from the root of this repository. See Ziggy's [App icons and splash screens](https://github.com/ashleydavis/ziggy/blob/main/docs/user-guide/app-icons-and-splash.md).

Everything else is in Ziggy's [user guide](https://github.com/ashleydavis/ziggy/blob/main/docs/user-guide.md).
