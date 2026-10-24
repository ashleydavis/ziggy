# Notes

Notes taken during work, each one waiting to be categorised.

## Notes

- The backend's state should not be passed around. The backend's state is not a single thing to be passed around or handles given out.
- Ziggy must not know about ffmpeg or imagemagick. THIS IS A MAJOR FUCK UP. `RunnerMaker` in packages/ziggy/core/src/lib/task-queue/utils/in-process-tools.zig is a massive code smell.
- Extensive changes have been made to the CLI UI which has nothing to do with the threading model. For example adding `threadlocal` to CLI UI variables. I expect all these sort of changes that have nothing to do with threads or the threading module to be reverted. You make use Git readonly, do not use Git to write to the repo, you are not to use git to stage or unstage or revert.
- The term "host request" (and "host reply", and any name built on "host" apart from "dev host") is banned, as the plan's banned words say. The thing is a native call: the app's own native call, named by a method. Every name, string, comment and doc that says host request (`host_request`, `hostRequest`, `IHostRequester`, `HostRequestHandler`, `ZiggyHostRequestHandler`, `HostCallbackMissing` and the rest) is to be renamed to native call terms in Ziggy, Photosphere and both examples.
- Remove the functions named `...Erased` in Ziggy's Zig code (worker-pool.zig, timers.zig, the task queue backends, task-context.zig, the uuid generators and timestamp providers, and the rest). Each is a second copy that only casts the type-erased pointer and passes the call to a typed function. The "Erased" suffix is not a Zig idiom: the standard library writes the vtable function once, taking `*anyopaque`, with a plain name (as `std.heap.ArenaAllocator.alloc` does). Merge each pair into one plainly named function.
