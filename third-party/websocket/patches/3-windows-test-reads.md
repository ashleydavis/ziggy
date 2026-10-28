# 3-windows-test-reads.patch

Changes the tests in `src/server/server.zig`: they read from their client connection through `Io`, and read a whole frame where they assert one.

The tests connect to the server with `Io.net` and read the replies with `posix.read`. On Windows an `Io.net` socket is an AFD handle, not a Winsock socket, so `posix.read`, which is Winsock's `recv`, failed every test that read with `error.FileDescriptorNotASocket`. `testRead` makes one read through `Io` instead. The tests that check a reply frame read it once and asserted on the whole frame, but the server can send a frame's header and payload separately, and on Windows the first read held only the header. They now read the frame's full length with `readSliceShort`, as the library's `Conn: close` test already does.

Delete the patch, and this file, when the library's tests read through `Io` and read whole frames themselves.
