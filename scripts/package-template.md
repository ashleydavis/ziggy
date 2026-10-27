# package-template.sh

Packages the Ziggy template of a version tag as `ziggy-template-<tag>.zip`, a new app ready to unpack: the template (`apps/ziggy-template`) as it is at the tag, with every reference to Ziggy pinned to that tag in the same form the [Vite example](https://github.com/ashleydavis/ziggy-example-vite) uses, and Ziggy's top-level `mise.toml` added. The release workflow `.github/workflows/release.yml` runs it for each version tag and attaches the archive to the release (see [Releasing Ziggy](../docs/development/releasing-ziggy.md)).

What it changes in the copy of the template:

- `build.zig.zon`: the `ziggy` dependency is fetched with `zig fetch --save=ziggy "git+https://github.com/ashleydavis/ziggy.git#<tag>"`, which writes its URL and hash. The path dependency is removed first, because `zig fetch --save` writes a broken entry over a dependency that has a path.
- `package.json`: `ziggy` is `git+https://github.com/ashleydavis/ziggy.git#<tag>`.
- `native/android/app/build.gradle`: the version of `dev.ziggy:ziggy-native-android` is the tag.
- `native/android/settings.gradle`: the `includeBuild` of Ziggy's Android native app is replaced by a `sourceControl` block naming Ziggy's repository.
- `native/macos` and `native/ios` Xcode projects: the local folder reference to Ziggy's Swift package is replaced by an `XCRemoteSwiftPackageReference` to Ziggy's repository at the exact version (the tag without its `v`).
- `jest.config.js`: Jest skips `<rootDir>/zig-pkg/` and `<rootDir>/native/android/.gradle/`, where the Zig and Gradle builds put copies of Ziggy with Ziggy's own tests.

The template's names (`ziggy-template` and the rest) are kept: renaming is the app developer's step. The archive holds only the template's tracked files at the tag and `mise.toml`, at its top level, so nothing a build or a test writes gets in.

The script fails, naming the file, when a line it pins is not in the template as it expects, when anything still points at the copy of Ziggy in Ziggy's repository afterwards or when the archive does not hold exactly the files it should.

## Usage

From the root of Ziggy's repository:

```bash
bun run package:ziggy-template:archive <tag> <output-dir>
```

It needs `git`, `tar`, `zig`, `zip` and `unzip`, and network access to Ziggy's repository on GitHub, where `zig fetch` fetches the tag. The tag must exist in the local repository.

## Arguments

- `<tag>`: the version tag to package, such as `v0.1.0`. The template and `mise.toml` are taken from the tag, not from the working tree, so the template always matches the version of Ziggy it is pinned to. The tag must already be pushed to GitHub, because `zig fetch` fetches it from there.
- `<output-dir>`: the directory to write to, made when it does not exist. The script writes `ziggy-template-<tag>.zip` there and leaves beside it the directory `ziggy-template-<tag>` the archive was made from (with the `zig-pkg` that `zig fetch` filled, which the archive leaves out). It refuses to run when either already exists.
