# 2-windows-setsockopt-without-winsock.patch

Changes `src/posix.zig`: on Windows, `setsockopt` returns without setting the option when Winsock's `setsockopt` fails with `WSANOTINITIALISED`, as it already does for `WSAENOTSOCK`, instead of reaching `unreachable`.

On Windows, Zig's `Io.net` sockets are AFD handles, not Winsock sockets, and the library's client connects with `Io.net`. `setsockopt` first tries the option through AFD and, when AFD does not support it, falls back to Winsock. AFD does not support `SO_SNDTIMEO`, which the client's handshake sets. In a process that has opened no Winsock socket, nothing has called `WSAStartup`, so the fallback fails with `WSANOTINITIALISED`, which the library marked `unreachable`. Every native app on Windows panicked there as it connected to the remote control server. A process with no Winsock started has no Winsock socket, so the handle is an AFD one, the case the library already handles for `WSAENOTSOCK` by leaving the option unset.

Delete the patch, and this file, when the library handles `WSANOTINITIALISED` itself.
