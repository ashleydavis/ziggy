# 1-windows-accept-shutdown.patch

Changes `src/posix.zig`: on Windows, `accept` maps `WSAEINTR` to `error.SocketNotListening`.

The blocking server, which websocket.zig uses on Windows, stops by closing its listening socket while its accept loop waits in `accept`, and Windows ends that `accept` with `WSAEINTR`. The library did not know the code, so it returned `error.Unexpected`, and the accept loop logged its own normal shutdown as "failed to accept socket: error.Unexpected". That failed every unit test of Ziggy's core that starts the library's server, because Zig's test runner fails a test that logs an error. `SocketNotListening` is a shutdown the accept loop already ends on quietly.

Delete the patch, and this file, when the library maps `WSAEINTR` itself.
