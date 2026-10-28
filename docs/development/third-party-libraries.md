# Third-party libraries

A library Ziggy has to change is kept in the repository, in `third-party/<library>`, instead of being fetched. Ziggy's `build.zig.zon` takes it from there by path. Ziggy's changes are never made to the library's files by hand: each is a patch, so that the next version of the library can be taken without losing them.

Each library's directory holds:

- The library's own files at one commit of its repository, with its licence.
- `update.sh` and `update.md`: replaces the library's files with those of another commit and applies Ziggy's patches again. It is run as `bun run update:<library> <commit>`.
- `patches/`: one `<name>.patch` per change, applied in name order with `patch -p1` in the library's directory, and a `<name>.md` beside it saying what the patch changes, why Ziggy needs it and when it can be deleted.

To change a library, change its file, write the difference against the library's own file with `diff -u --label a/<path> --label b/<path> <original> <changed>` into `patches/<name>.patch`, and describe it in `patches/<name>.md`. When a patch does not apply to a new version, `update.sh` stops and names it: make the patch again against the new version, or delete it and its description when the library has fixed the problem itself.

The libraries kept this way:

- `third-party/websocket`: [websocket.zig](https://github.com/karlseguin/websocket.zig), the WebSocket library of the remote control connection. See [update.md](../../third-party/websocket/update.md).
