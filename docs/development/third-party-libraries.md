# Third-party libraries

A library Ziggy has to change is kept in the repository, in `third-party/<library>`, instead of being fetched. Ziggy's `build.zig.zon` takes it from there by path. Ziggy's changes are never made to the library's files by hand: each is a patch, so that the next version of the library can be taken without losing them.

Each library's directory holds:

- The library's own files at one commit of its repository, with its licence.
- `update.sh` and `update.md`: replaces the library's files with those of another commit and applies Ziggy's patches again. It is run as `bun run update:<library> <commit>`.
- `patches/`: Ziggy's changes to the library, as described below.

## Patches

Every change Ziggy makes to a library's files is a patch in its `patches/` directory, and the library's files in the repository are always the library's own with every patch applied.

- Each patch is `<number>-<name>.patch`, a unified diff with paths relative to the library's directory (`a/src/...`, `b/src/...`), applied with `patch -p1` in that directory.
- Beside it, `<number>-<name>.md` says what the patch changes, why Ziggy needs it and when it can be deleted.
- The number gives the patch its place in the order: `update.sh` applies the patches by number, lowest first, so a patch can rely on every patch before it. Each patch has its own number, and a new patch takes the number after the last one.
- Before it replaces anything, `update.sh` checks that every patch starts with a number and that no two share one, and stops naming the patch that does not.

To change a library:

1. Change the library's file in `third-party/<library>`.
2. Write the difference against the file as it was, the library's own with the earlier patches applied, into `patches/<number>-<name>.patch` with `diff -u --label a/<path> --label b/<path> <original> <changed>`.
3. Describe it in `patches/<number>-<name>.md`.

When a patch does not apply to a new version of the library, `update.sh` stops and names it: make the patch again against the new version, or delete it and its description when the library has fixed the problem itself. A deleted patch leaves a gap in the numbers, which is fine: only the order matters.

## Libraries

- `third-party/websocket`: [websocket.zig](https://github.com/karlseguin/websocket.zig), the WebSocket library of the remote control connection. See [update.md](../../third-party/websocket/update.md).
