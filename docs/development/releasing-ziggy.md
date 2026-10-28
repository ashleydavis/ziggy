# Releasing Ziggy

Two workflows build and test this repository: CI tests every push, and the release workflow tests the commit again and publishes its release when a version of the Ziggy package is released by cutting a version tag.

## The CI workflow

`.github/workflows/ci.yml` runs on every push to every branch, on every pull request to `main` and when started from the Actions tab. Its jobs:

- **app-build**: on each platform's own runner, builds the test app once with its build script (`build:<platform>`, the simulator build on iOS) into a directory of its own. It saves that build and the Zig build caches, which the later jobs restore.
- **unit-tests**: on Linux, MacOS and Windows, the TypeScript unit tests (`bun run test`) and every Zig test (`zig build test`); on Android, the Android native app's JUnit tests (`bun run test:android-shell`) and the Zig tests run on an emulator; on iOS, the Zig tests run on a simulator.
- **smoke-tests**: Ziggy's smoke tests, which drive the app app-build built (`ZIGGY_SMOKE_BUILD`), on Linux, Windows, MacOS, an Android emulator and an iOS simulator.

It packages nothing and creates no release.

## The release workflow

`.github/workflows/release.yml` runs when a version tag is pushed, and when started from the Actions tab. It runs the same jobs as CI, then:

- **publish**: only when every job passed, and only for a pushed version tag or a tag given when the run is started: the GitHub release of the tag (see [Releasing a version of the package](#releasing-a-version-of-the-package)).

A run started from the Actions tab without a tag only tests. A run that fails anywhere publishes nothing.

### Reading a failed run

Open the run in the Actions tab. The summary shows which job failed and, for a job with a matrix, on which platform. Each step's log is in the job; a test step's log ends with the failures (`FAILED:` lines and a summary from the smoke tests, Zig's build summary from `zig build test`, Jest's summary from `bun run test`). A smoke test that ran out of time reports it and names the variable that raises its limit. A step that hit its own timeout fails normally and keeps its log. Run the same command on the same platform locally to reproduce it: every step runs a `bun run` script or a `zig build` command from the root of the repository.

## Releasing a version of the package

An app pins Ziggy to a version tag. A version tag is `v` followed by the version, such as `v0.1.0`, and the tag alone carries the version: the `version` fields in `build.zig.zon`, `package.json` and `packages/ziggy/native/android/build.gradle` stay at `0.0.0` and are not changed for a release. The `/release` Claude Code command follows these steps. To release one:

1. Make sure the CI workflow passed on the commit to be released.
2. Tag the commit and push the tag:

   ```bash
   git tag v0.1.0
   git push origin v0.1.0
   ```

   Pushing the tag starts `.github/workflows/release.yml` (above), which, once every build and test has passed, publishes the GitHub release on the tag, with notes listing the commits since the version tag before it and with the tag's `docs/agent-quick-start.md` and the template archive `ziggy-template-<tag>.zip` attached. The archive is the template of the tag with every reference to Ziggy pinned to the tag and Ziggy's `mise.toml` added, made by `scripts/package-template.sh` (see [package-template.md](../../scripts/package-template.md)). A new app starts from that archive, so it needs no pinning of its own. The docs tell app developers to point their agent at `https://github.com/ashleydavis/ziggy/releases/latest/download/agent-quick-start.md`, which GitHub serves only from the files attached to the newest release.

3. When an app has to change something to move to the new version, add it to the release's notes.

A version tag is never moved or deleted once pushed: an app that pinned it, and the hash in its `build.zig.zon`, depend on it staying the same. A mistake is fixed by releasing the next version.

When the workflow failed for a reason outside the tag, such as a broken step, fix the workflow on `main` and start it again with `gh workflow run release.yml --ref main -f tag=<tag>`. That run tests `main`, takes the workflow and its actions from `main` and publishes everything else from the tag.
