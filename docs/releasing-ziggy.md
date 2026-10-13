# Releasing Ziggy

Separate things happen to this repository: the release workflow builds, tests and publishes the Ziggy template on every push, and a version of the Ziggy package is released by cutting a version tag. The workflow has nothing to do with version tags, and a version tag does not start the workflow.

## The release workflow

`.github/workflows/release.yml` runs on every push to every branch, on every pull request to `main` and by hand from the Actions tab. Its jobs:

- **zig-build**: builds the template's core and cross-builds it for every platform, with and without the test hooks, and compiles the Windows native app, on Linux, MacOS and Windows (`bun run compile:zig`).
- **unit-tests**: on Linux, MacOS and Windows, the TypeScript unit tests (`bun run test`) and every Zig test (`zig build test`); on Android, the Android native app's JUnit tests (`bun run test:android-shell`) and the Zig tests run on an emulator; on iOS, the Zig tests run on a simulator.
- **smoke-tests**: the template's smoke tests on Linux, Windows, MacOS, an Android emulator and an iOS simulator, and on Linux in dev mode too.
- **package**: the template's packages for every platform, uploaded as artifacts of the run.
- **publish**: only when every job above passed, and only for a push to the default branch: the GitHub release named "Ziggy template" is replaced by one holding this run's packages for every platform, with release notes listing the commits since the last version tag. A GitHub release is always attached to a git tag, so this one sits on the tag `template`, which the workflow deletes and makes again on the commit it built. `template` is not a version tag, and nothing should pin it.

A run on another branch, or for a pull request, runs every build and test and publishes nothing. A run that fails anywhere publishes nothing, and the previous release of the template stays.

### Reading a failed run

Open the run in the Actions tab. The summary shows which job failed and, for a job with a matrix, on which platform. Each step's log is in the job; a test step's log ends with the failures (`FAILED:` lines and a summary from the smoke tests, Zig's build summary from `zig build test`, Jest's summary from `bun run test`). A smoke test that ran out of time says so and names the variable that raises its limit. A step that hit its own timeout fails normally and keeps its log. Run the same command on the same platform locally to reproduce it: every step runs a `bun run` script or a `zig build` command from the root of the repository.

## Releasing a version of the package

An app pins Ziggy to a version tag (see [Integrating Ziggy](integrating-ziggy.md)). A version tag is `v` followed by the version, such as `v0.1.0`. To release one:

1. Make sure the release workflow passed on the commit to be released.
2. Set the version in the places that carry it, all to the same version: `version` in `build.zig.zon`, `version` in `package.json` and `version` in `packages/ziggy/native/android/build.gradle`. Commit that, push it and wait for the release workflow to pass on that commit.
3. Tag the commit and push the tag:

   ```bash
   git tag v0.1.0
   git push origin v0.1.0
   ```

4. Write what changed for apps since the last version, and what an app has to change, in a GitHub release on the tag, so an app moving to it knows.

A version tag is never moved or deleted once pushed: an app that pinned it, and the hash in its `build.zig.zon`, depend on it staying the same. A mistake is fixed by releasing the next version.
