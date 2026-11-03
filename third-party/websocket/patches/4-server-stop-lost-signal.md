# 4-server-stop-lost-signal.patch

Changes `src/server/server.zig`: `Server.stop` waits until `listen` has ended, which `listen` records in `_listen_ended` under the server's lock, instead of waiting for one signal.

`stop` closes the workers' signals while it holds the lock, then waits on the condition. `listen` joins the workers and signalled the condition without taking the lock, so on a busy machine the signal could come after the last signal was closed and before `stop` waited. The signal was then lost and `stop` waited forever, with every other thread ended. It hung Ziggy's core unit tests, each of which stops a remote control server it started: one run of the Linux unit tests in the v0.0.23 release timed out after 20 minutes, and 9 of 40 local runs hung with the tests held to two CPUs.

Delete the patch, and this file, when the library's `stop` waits for a state `listen` sets under the lock.
