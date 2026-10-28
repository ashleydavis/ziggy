# update.sh

Replaces the copy of [websocket.zig](https://github.com/karlseguin/websocket.zig) in `third-party/websocket` with the library at a commit of its repository. Ziggy's core uses it for the remote control connection, and Ziggy's `build.zig.zon` takes it from this directory by path (see [Packages](../../docs/development/packages.md)).

It downloads the commit's archive from GitHub and keeps every file of the library's repository at that commit, so a file the library adds is never left out. A file the old version had and the new one does not is removed. `update.sh`, `update.md` and the output of a build of the library are left as they are.

Any change made to the copy in this directory is lost: the files are replaced by the library's own.

## Tests

The library's unit tests run in their own jobs of Ziggy's CI and Release workflows, `websocket-unit-tests-<platform>` on Linux, Windows and macOS (`zig build test` in this directory). They are not part of Ziggy's own `zig build test`, because they listen on fixed ports, so two runs on one machine would collide.

## Usage

From the root of Ziggy's repository:

```bash
bun run update:websocket <commit>
```

It needs `curl` and `tar`, and network access to GitHub. Afterwards, put the new commit in [Packages](../../docs/development/packages.md) and run Ziggy's tests.

## Arguments

- `<commit>`: the commit of websocket.zig to take, as a full hash, such as `efa879736bd438bea8b86a91f220ba408de57273`.
