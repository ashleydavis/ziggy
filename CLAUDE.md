# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Ziggy is a framework for building cross-platform apps with JavaScript/TypeScript, HTML and CSS for the frontend and Zig for everything else, using each platform's system web view. This repository holds Ziggy itself (`packages/ziggy`) and the Ziggy template (`apps/ziggy-template`), a small complete app built on it that a new app starts as a copy of. Use the terms "the frontend", "the backend", "the native app" and "the system web view" as the [glossary](docs/glossary.md) defines them.

- `packages/ziggy/core`: the core library every app links, imported as `@import("ziggy")`, with the C interface (`core/src/lib/ziggy.h`), the task queue and the script every native app injects to create `window.ziggy`.
- `packages/ziggy/frontend`: the TypeScript types of `window.ziggy` and of the messages the backend sends (the `ziggy` package).
- `packages/ziggy/native/<platform>`: the part of each native app that Ziggy provides.
- `packages/ziggy/dev`: dev mode: the dev backend, which runs the app's backend in front of the app's own dev server, and the supervisor that starts them and rebuilds it. Never part of a native app or a release build.
- `build.zig`: builds Ziggy, runs its tests and holds the functions an app's own `build.zig` calls. `Package.swift`: the MacOS and iOS native apps as one Swift package.
- Ziggy's code never names the app and never imports its packages. The app uses Ziggy only through its interfaces.

## Platforms

Ziggy and the Ziggy template are developed on Linux and delivered and tested on Linux, Windows, macOS, Android and iOS. Every test and smoke test must work on each platform it runs on.

- Linux: native app in Zig, GTK 3 and WebKitGTK 4.1.
- Windows: native app in Zig and WebView2. The scripts run under Git Bash.
- macOS and iOS: native app in Swift and WKWebView. Built and run on a Mac.
- Android: native app in Java and the Android WebView, with the JNI entry points written in Zig. Built and run on Linux or a Mac.
- The backend is the same Zig code on every platform and never touches a window.

## Rules

- HIGH PRIORITY: Before changing anything in this repository, check the pre-commit hook is installed: `$(git rev-parse --git-common-dir)/hooks/pre-commit` links to `.githooks/pre-commit`. If it is not, run `bun run install-hooks` without asking. Never bypass the hook.
- SHARED STATE BETWEEN ZIG THREADS IS BANNED. All communication between threads is done with JSON messages: the only thing two threads both touch is a message queue, and the only thing that crosses it is a copy of JSON text.
  - Never add a mutex or lock to Ziggy's Zig code unless the human explicitly asks for it.
  - Memory allocated on one thread is never freed on another, and no allocator is used by two threads: each thread makes its own.
  - System services (an Io, an allocator, the timers, the handler, menu and task services) are never stored in a struct: each function that uses one takes it as an argument.
- When writing plans, do not add any steps for "Human Verification" or "Human Testing", plans you write should be automatically tested by unit tests and smoke tests. No human will be testing your work.
- YOU ARE RESPONSIBLE FOR ALL THE CODE IN THIS REPO. Code of unknown authorship is yours. Compile errors and failing tests are always yours to fix: never use "it was already like that" or "preexisting" as an excuse.
- ANY NEW TEST HOOK MUST BE APPROVED BY THE HUMAN FIRST, OR NOT ADDED AT ALL. A test hook is anything shipped in the app that exists only to let tests control it or look inside it: commands, events, injection points, seeding functions or globals. Hooks act only when the app is started with `--remote-control`; never put one that acts without it. If a test needs state, set it up from outside the app (config files and data placed on disk) wherever it can be done.
- NEVER WRITE A WORKAROUND, A FAKE, A MOCK, A STUB OR A HAND-WRITTEN "REPLACEMENT" FOR A THIRD-PARTY SDK OR LIBRARY UNLESS THE HUMAN HAS SPECIFICALLY APPROVED THAT EXACT THING FIRST, IN THE MESSAGE YOU ARE ACTING ON. Approval must be explicit and asked for in advance. Silence is not approval. An earlier approval for one thing is not approval for another, and is not a standing permission. If you are unsure whether something counts, it counts: stop and ask. This bans, among other things: reimplementing a vendor SDK or a platform library, hand-writing a wire protocol, request signing or response parsing that a maintained library already does and aliasing a real package to your own substitute at build time. This repository cannot afford to maintain a copy of somebody else's SDK, and security-critical code must come from upstream so it gets upstream fixes.
- If the real library will not work in an environment, STOP AND ASK THE HUMAN. Do not fill the gap yourself. Say what does not work and what the options are, and wait for an answer. A shim that makes a build succeed while quietly reimplementing the library is worse than a build that fails, because the failure is visible and the shim is not.
- NEVER WRITE A FAKE TEST: one that cannot fail when the thing it names is broken. That includes a test against a UI, API, id, channel, function or file you have not verified exists, assertions invented rather than read from the code, a test that fakes the thing under test, one that skips by default or runs only when a normally unset environment variable is set, and a test you have never watched run. If a test needs real infrastructure, provision it or say it cannot be done.
- RUN EVERY TEST YOU WRITE. If you cannot run it, say it is unverified.
- NEVER MAKE A FAILING TEST GO AWAY WITHOUT FIXING THE CAUSE. No deleting it or its failing assertion, commenting it out, skipping it, loosening or widening an assertion, adding a wait or retry, ignoring an error line or catching the error. This covers a test you wrote minutes ago as much as an old one. "It was low value" is not a reason to delete. If it will not run, fix the runner or the import. A port of a test asserts what the original asserts. Deleting a test whose subject no longer exists is fine; for any other reason, stop, say which test and why, and wait.
- NEVER LIE ABOUT WHAT YOU HAVE DONE OR VERIFIED. Do not say a thing works, passes, is tested, is verified or is complete unless you ran it and read the result in this session. Do not describe an intention as an outcome. Do not present a skipped test, a compile that merely succeeded or a code reading as evidence that behaviour is correct. If you are inferring rather than observing, use words that show it, and say what you did not check.
- Something not implemented yet fails with a message naming what is missing.
- WORKAROUNDS ARE NOT ACCEPTABLE. Fix the cause. Do not change an input, an expected value or a check to make a failure go away (converting backslashes to slashes, a retry, a wait, a platform special case).
- YOU FIND A BUG, YOU FIX IT. A test that failed once and passed the next time is a bug (a race, a timeout load can exceed, a resource it does not own). "It passed on the retry", "only under load" and "unrelated to my change" are not results. Do not record a bug in a known-issues list, doc or TODO instead of fixing it. The only failures outside your reach are outside the machine (network, disk, remote service): the code must fail loudly naming them, and you tell the human and wait rather than add a retry or any other patch. Otherwise keep going, and if you have no cause yet, say what you have ruled out and what you will look at next.
- All Claude configuration goes in this repository only, not in the home directory.
- Slash commands go in `.claude/commands/`, as a markdown file per command, grouped in a subdirectory where there is more than one of a kind: `.claude/commands/ux/review/create.md` is `/ux:review:create`. A request for a "skill" means one of these. Do not create a `.claude/skills/` directory or a `SKILL.md`, and do not put a command in the home directory. Give each command frontmatter carrying `description` and nothing else, then the prompt as ordinary markdown with a heading and steps. The `description` describes what the command does, not when to trigger it.
- Never say "you are right", "you're right" or any other agreement as a way to open a reply. Say what was wrong and what you will do about it. Never tell the human untested code can be committed now and tested later: say it is untested, and say what would test it.
- Never use `cd` to permanently change directories within the repo. Use it on a case-by-case and temporary basis as part of a command to run the command from a particular directory.
- Never invoke shell scripts directly (e.g. `bash ./smoke-tests/run.sh android`). Use the `bun run` equivalent from `package.json` (e.g. `bun run test:smoke:android`).
- HIGH PRIORITY: `rm -r` is banned, in every form and every flag combination that includes it (`-r`, `-R`, `--recursive`, `-rf`, `-fr`), unless I ask for that exact deletion in the message you are acting on. This covers commands you run, commands you ask me to run and any `rm -r` you write into a script, test, runner or hook. If something has to be removed recursively, stop, say what and why, and wait. Removing a single file by name is not covered by this and is fine.
- NEVER WAIT FOR ANOTHER WORKTREE'S TESTS TO FINISH BEFORE RUNNING YOUR OWN. Do not watch or poll for other runs. If two runs contend, that is a bug.
- EVERY TEST MUST SURVIVE RUNNING BESIDE ANOTHER COPY OF ITSELF AND BESIDE EVERY OTHER SUITE, INCLUDING ONES FROM OTHER WORKTREES. A suite that passes alone and fails in company contends on something shared: that is a bug, not flakiness. Running a second copy of the suite beside it is the cheapest way to surface a fixed port or path.
  - No fixed port, path, lock, config path or device. Let the OS pick a free port and get each test's directory from `ziggy_test_temp_dir` (`smoke-tests/lib/test-lib.sh`).
  - Start every background process with `launch_in_process_group` (`smoke-tests/lib/process-control.sh`) so its pid is recorded in the file `ZIGGY_LAUNCHED_GROUPS` names when it starts. Never run a long-lived helper in the foreground.
  - Never kill by name or command line (`pkill`, `pkill -f`, `killall`): it kills other worktrees' identical processes. Kill the pids you started and their descendants with `kill_process_tree` or `kill_process_group`.
- When creating a new worktree, never use `EnterWorktree` with a `name` parameter. Instead: (1) run `git branch --show-current` to get the current branch, (2) run `git worktree add -b <new-branch> .claude/worktrees/<name> <current-branch>` to create the worktree explicitly branching from the current branch, (3) then use `EnterWorktree` with the `path` parameter to enter it.
- The `run:ziggy-template:<platform>` commands build the app before they launch it, so the running app is built from current source. A code change that does not show up is never caused by a stale build. Never tell me to rebuild and never blame a missing change on the build being out of date. Find the real cause.
- The Android emulators belong to me. The Android suites (`test:smoke:android`, `test:zig:android`) use the devices named in `ZIGGY_ANDROID_DEVICES` (adb serials, space separated), else every plugged-in device adb has attached and ready when there is one, else every attached emulator, whichever project started it. Each run claims one and waits for one to come free.
- Never assume whether an Android emulator is attached. Run `adb devices` at the point you need the answer: a serial whose state is `device` is ready. I start and stop emulators without announcing it, so an earlier reading is stale.
- Never start, stop, restart or repair an emulator, never create or remove a network tap or bridge and never run sudo. When an emulator is broken or none is attached, say so and leave it to me.
- Never say something was "intentionally done" unless I explicitly asked for that exact behaviour. State what the code does and own the mistake.
- Something you (the AI) have previously written in a plan does not mean that I approve of or accept that thing. Never use "it was in the plan" as the reason something was done. Whenever I ask "What is the reason for X?" I mean "Why was that change necessary?".
- If a plan contains something worth keeping, copy the content itself into the thing that needs it, or into a permanent doc under `docs/`.
- Expect the human to stage and commit your work as they review it, so the staging area changes under you. Use `git status` and `git diff HEAD`, not a bare `git diff`. An empty `git diff` does not mean your edit failed or was lost. Never put the Git state back how you remember it.
- THIS REPOSITORY USES TYPESCRIPT, ZIG AND SHELL SCRIPT, plus Swift, Java and C headers only where a platform requires them. Do not add more native code than the platform forces and do not introduce another language (`python3`, perl, Ruby, Go and so on), even as an undeclared dependency.
- A SHELL SCRIPT CONTAINS SHELL. Never embed another language in one (`python3 -c`, `bun -e`, `node -e`, a heredoc into an interpreter, an awk program), however short.
- When a shell script needs something that looks beyond shell, find the shell answer first (`stat`, `cmp`, `uuidgen`, `od`, `jq`). Assume there is one until you have tried it and watched it fail. Only when none works does it become a TypeScript helper with a comment block and documented arguments, like `apps/ziggy-template/scripts/ios-device.ts`.
- EVERY NEW SCRIPT COMES WITH A MARKDOWN FILE BESIDE IT, named after the script, covering what it is for, how it is invoked and what each argument means. Keep it current, and link to a fuller guide under `docs/` rather than repeating one.
- Shell in this repository is the test harness itself, and the thing that proves a harness works is running the real suite it drives. If you believe a piece of shell cannot be trusted without a test, stop and ask, and wait for an answer.
- TEST MARKER FILES ARE BANNED. Do not add a file whose only job is to tag a test directory so a runner treats that test differently. A marker records a judgement made once and nothing ever re-checks it. If a runner needs to know something about a test, it must read it from the test itself or work it out at the time.
- NEVER WRITE A SCRIPT, A FILE OR A HELPER OF ANY KIND TO WORK AROUND A LIMIT OF YOUR OWN HARNESS. Your command timeout, a refusal to run a command it could not parse, a background job being killed: none of those are problems with this repository and none of them get a file committed to it. Run the command directly. If it cannot finish inside your limit, say so in one line, give me the command and wait: I will run it and tell you when it is done.
- MacOS and iOS are built with Xcode 14.2 on macOS 12.7.6, the oldest the docs support. Never require an Xcode or macOS version newer than that. When native code needs a newer API, use an availability guard (`#available`, `#if swift(>=...)`) or a compatible approach. If a version bump seems unavoidable, stop and ask first.
- The example apps `ziggy-example-vite` and `ziggy-example-rsbuild` (separate repositories under `https://github.com/ashleydavis`) each pin Ziggy to a version tag. When Ziggy has changed and a new version is released, update both to the new tag (`build.zig.zon`, `package.json`, the Xcode projects and `native/android/app/build.gradle`), carry over any change an app has to make (the template shows it) and run each example's full test set against it.
- When I ask for an ETA, give one at once, as a time range with what it depends on. Never refuse, argue or ask a question first.
- When I ask you to record a note or a todo, never change my writing or distort it in any way.
- Keep this file terse. It is loaded into context for every task, so state the rule and stop: no lists of examples, no worked illustrations.
- A change to the Android or iOS native app, or to Ziggy's core library or the backend, is not tested until the suites for that mobile platform have run.

## Code Style
- **Imports**: Named imports for functions, default imports for modules
- **Formatting**: 4-space indentation, braces on same line as control statements
- Put `else` and `catch` blocks on a new line.
- Tests go under the directory `src/test` in each package.
- Frontend code is a thin layer. Factor non-trivial frontend logic out into a plain function under a `lib/` directory (as `apps/ziggy-template/frontend/src/lib` does) and unit test the plain function. Do not extract or test trivial logic only to gain a test.
- You do not have to invent a new file to "get a test on it". When the logic belongs to something that already exists, put it there. When it belongs nowhere and is small enough to read in one go, leave it where it is with a comment explaining why, and let the test that exercises the feature cover it.
- Never use the `unknown` type. Use the type directly.

## Restrictions
- Prefer not to update test code unless needed.
- Backward compatibility is not required.
- Don't add exception handling unless I ask for it.
