# Choose the bundler when a new app is made

## Overview

The Ziggy template is set up for Vite only: `vite.config.ts`, the `dev:ui` script (`vite`), the `vite build` call inside `scripts/bundle-ui.sh`, the `vite` dev dependency and the `vite.config.ts` entry in `tsconfig.json`. Ziggy itself works with any bundler (its build reads the built UI from `dist`, and dev mode runs the app's `dev:ui` script), and the Rsbuild example shows the same app on Rsbuild. This plan makes the template hold every supported bundler's setup, puts all of a bundler's specifics in one place per bundler, and has `/ziggy:new` ask which bundler to use and keep only that one, so an app starts on the bundler its author chose with nothing left over from the others. Each supported bundler is tested by Ziggy, so a choice offered is a choice that works.

## Issues

## Steps

1. Write the documentation, then STOP for the human's review:
   - `docs/building-your-app.md`: a "Choosing a bundler" section: the supported bundlers, what each one's setup is (its config file, its `dev:ui` and `build:ui` scripts, its dev dependency and what `ui/index.html` needs), what any bundler must do for Ziggy (build `ui/` into the directory `bundle-ui.sh` gives it, with relative paths and a classic deferred script, and serve `ui/` in dev mode on the port and host the supervisor passes it), and how to switch an existing app.
   - `docs/integrating-ziggy.md` "Dev mode (package.json)": point to the new section instead of repeating it.
   - `.claude/commands/ziggy/new.md`: "Ask for the names" asks which supported bundler to use (Vite as the default), and "Make the app" keeps only that bundler's setup.
   - `apps/ziggy-template/README.md`: where each bundler's setup lives in the template.
   - The Rsbuild example's `README.md`: what makes it an Rsbuild app.
   - STOP. Wait for approval. If the human changes the design (the supported bundlers, where their setups live, what `/ziggy:new` asks), revise the later steps to match.
2. Make `apps/ziggy-template/scripts/bundle-ui.sh` bundler-neutral: replace the `vite build --outDir ... --emptyOutDir` call with `bun run build:ui`, passing the build directory in the environment variable `BUNDLE_UI_OUT_DIR` (the name the Rsbuild example already uses). Add the `build:ui` script to `apps/ziggy-template/package.json` (`vite build --outDir "$BUNDLE_UI_OUT_DIR" --emptyOutDir`, or `vite.config.ts` reading the variable, whichever builds the same files). Update `scripts/bundle-ui.md`. `bun run test:zig`, `bun run compile:zig` and the template's smoke test pass, and `dist` holds the same files as before.
3. Add `apps/ziggy-template/bundlers/<bundler>/` for each supported bundler, holding only what differs between bundlers: its config file, the `dev:ui` and `build:ui` scripts and dev dependencies it needs (as a small JSON file the new-app steps merge into `package.json`), and its `ui/index.html` when the bundler needs a different one (Rsbuild injects the script itself, so its page has no script tag). Start with `vite` and `rsbuild`, taking Rsbuild's files from `ziggy-example-rsbuild` (`rsbuild.config.ts`, the `@rsbuild/core` dev dependency at the version it pins, `rsbuild dev` and `rsbuild build`). Keep the template's own files on Vite, so the template runs as it is. Each file gets the same header comment that says what it is for.
4. Add `scripts/apply-bundler.sh <app-dir> <bundler>` (with `scripts/apply-bundler.md`) to the template: copies `bundlers/<bundler>/`'s files into the app, merges its scripts and dev dependencies into `package.json` with `jq`, puts the config file's name in `tsconfig.json`'s `include`, deletes the other bundlers' config files and then the `bundlers` folder. It fails, naming the bundler, when `bundlers/<bundler>/` does not exist. Shell and `jq` only.
5. In Ziggy, add `scripts/test-bundlers.sh` (with `scripts/test-bundlers.md`) and the root script `bun run test:bundlers`: for each folder in `apps/ziggy-template/bundlers`, copy the template into a directory from `ziggy_test_temp_dir`, run `apply-bundler.sh` on it, `bun install`, `bun run compile`, `bun run test`, `bun run test:zig` and `bun run test:smoke`, and fail naming the bundler when any of them fails. Record every process it starts as `CLAUDE.md` requires. Add it to `.github/workflows/release.yml` as a Linux job.
6. Update `.claude/commands/ziggy/new.md` as step 1 described: the bundler question lists the folders of the template's `bundlers` (Vite first), and the bundler step runs `scripts/apply-bundler.sh` instead of describing the swap.
7. Update the Rsbuild example so it is what `apply-bundler.sh rsbuild` makes from the template (its files, scripts and dependencies), so the two cannot drift. Run its `compile`, `test`, `test:zig` and `test:smoke`.
8. Update the documentation from step 1 to match the final code.

## Unit Tests

- None: the change is shell scripts, config and docs, and `CLAUDE.md` forbids tests of shell scripts. The template's existing unit tests run in every bundler's copy through `test-bundlers.sh`.

## Smoke Tests

- `bun run test:bundlers`: for each supported bundler, a copy of the template on that bundler passes its type check, unit tests and the `hello-world-app` smoke test.
- The template's own `bun run test:smoke`, on Vite, still passes.
- `bun run test:smoke:dev` (Ziggy's dev mode smoke tests) still passes.

## Verify

- `bun run compile`, `bun run test`, `bun run test:zig` and `bun run compile:zig` pass in Ziggy.
- `bun run test:bundlers` passes for every bundler under `apps/ziggy-template/bundlers`.
- The template's `bun run test:smoke` and Ziggy's `bun run test:smoke` and `test:smoke:dev` pass.
- A copy made by `apply-bundler.sh` for each bundler contains no file and no dependency of another bundler.
- The Rsbuild example passes its checks.

## Notes

- Whether the template should hold the bundlers' setups at all, or only the docs should (with `/ziggy:new` writing the files), is the human's choice in step 1. Holding them in the template is what lets Ziggy test each choice.
- Rsbuild needs a page with no script tag, so a supported bundler may bring its own `ui/index.html`. Keep the page's content the same, so the hello world smoke test passes on every bundler.
- The template's Vite setup turns module scripts into classic deferred ones (`vite.config.ts`'s `classicScript` plugin); every bundler's setup must produce the same, because some web views cannot load a module script from the app's own address.
- No git operation in this plan without the human's direction in the message being acted on. Never use `rm -r`.
