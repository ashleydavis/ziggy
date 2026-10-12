# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Ziggy is a framework for building cross-platform apps with JavaScript/TypeScript, HTML and CSS for the UI and Zig for everything else, using each platform's system web view. This repository holds Ziggy itself (`packages/ziggy`) and the Ziggy example (`apps/ziggy-example`), a small complete app built on it that a new app starts as a copy of. Use the terms "the UI", "the core", "the native app" and "the system web view" as the [glossary](README.md#glossary) defines them.

- `packages/ziggy/core`: the core library every app links, `ziggy-core`, imported as `@import("ziggy-core")`, with the C interface (`core/src/lib/ziggy.h`), the task queue and the script every native app injects to create `window.ziggy`.
- `packages/ziggy/ui`: the TypeScript types of `window.ziggy` and of the messages the core sends (the `ziggy-ui` package).
- `packages/ziggy/native/<platform>`: the part of each native app that Ziggy provides.
- `build.zig`: builds Ziggy, runs its tests and holds the functions an app's own `build.zig` calls. `Package.swift`: the MacOS and iOS native apps as one Swift package.
- Ziggy's code never names the app and never imports its packages. The app uses Ziggy only through its interfaces.

## Platforms

Ziggy and the Ziggy example are developed on Linux and delivered and tested on Linux, Windows, macOS, Android and iOS. Every test and smoke test must work on each platform it runs on.

- Linux: native app in Zig, GTK 3 and WebKitGTK 4.1.
- Windows: native app in Zig and WebView2. The scripts run under Git Bash.
- macOS and iOS: native app in Swift and WKWebView. Built and run on a Mac.
- Android: native app in Java and the Android WebView, with the JNI entry points written in Zig. Built and run on Linux or a Mac.
- The core is the same Zig code on every platform and never touches a window.

## Rules

- When writing plans, do not add any steps for "Human Verification" or "Human Testing", plans you write should be automatically tested by unit tests and smoke tests. No human will be testing your work.
- YOU ARE RESPONSIBLE FOR THE CODE IN THIS REPO. IT DOESN'T MATTER "IF IT WAS ALREADY LIKE THAT": YOU ARE EXPECTED TO FIX IT.
- IF YOU DON'T KNOW WHO WROTE THE CODE, IT MEANS YOU (CLAUDE) WROTE THE CODE.
- IT IS ALWAYS YOUR RESPONSIBILITY TO FIX COMPILE ERRORS AND FAILING TESTS. NEVER USE THE "PREEXISTING" EXCUSE.
- ANY NEW TEST HOOK MUST BE APPROVED BY THE HUMAN FIRST, OR NOT ADDED AT ALL. A test hook is anything shipped in the app that exists only to let tests control it or look inside it: commands, events, injection points, seeding functions or globals. Hooks are compiled in only by the `test-hooks` build option, which the release packages are never built with; never put one outside it. If a test needs state, set it up from outside the app (config files and data placed on disk) wherever it can be done. See "Test hooks" in [the architecture guide](docs/architecture.md).
- NEVER WRITE A WORKAROUND, A FAKE, A MOCK, A STUB OR A HAND-WRITTEN "REPLACEMENT" FOR A THIRD-PARTY SDK OR LIBRARY UNLESS THE HUMAN HAS SPECIFICALLY APPROVED THAT EXACT THING FIRST, IN THE MESSAGE YOU ARE ACTING ON. Approval must be explicit and asked for in advance. Silence is not approval. An earlier approval for one thing is not approval for another, and is not a standing permission. If you are unsure whether something counts, it counts: stop and ask. This bans, among other things: reimplementing a vendor SDK or a platform library, hand-writing a wire protocol, request signing or response parsing that a maintained library already does and aliasing a real package to your own substitute at build time. This repository cannot afford to maintain a copy of somebody else's SDK, and security-critical code must come from upstream so it gets upstream fixes.
- If the real library will not work in an environment, STOP AND ASK THE HUMAN. Do not fill the gap yourself. Say what does not work and what the options are, and wait for an answer. A shim that makes a build succeed while quietly reimplementing the library is worse than a build that fails, because the failure is visible and the shim is not.
- The same applies to tests: do not make a test pass by faking the thing under test, skipping it or running it only when an environment variable that is normally unset is set. A test that reports success without asserting anything is worse than no test. If a test needs real infrastructure, provision it or tell the human it cannot be done.
- NEVER WRITE A FAKE TEST. A fake test is any test that cannot fail when the thing it names is broken. This includes: a test written against a UI, API, element id, channel, function or file that you have not verified exists; a test whose assertions you invented from what you imagined the code does rather than read from the code; a test that skips by default so its body has never executed; and a test you have never watched run. Every one of these reports success for work that was never checked, which is worse than having no test, because a green tick stops anyone looking. If you cannot run a test you have written, say so in that message and say that it is unverified. Do not report it as passing.
- RUN EVERY TEST YOU WRITE, AND WATCH IT FAIL FIRST. A new test that has only ever passed has not been shown to test anything. Break the thing it covers or assert the wrong value, then confirm the test goes red before you accept it.
- DO NOT DELETE A FAILING TEST. GET IT WORKING. A test that fails is doing its job: it is either telling you the code is broken or telling you the test is wrong, and both of those are answers worth having. This covers a test you wrote yourself minutes ago as much as one that has been here for years, and it covers every way of making a failure go away without understanding it: removing the file, commenting the body out, marking it skipped, loosening the assertion until it cannot fail or catching the error and passing anyway. "It was low value" and "it would not run under the test runner" are not reasons to delete; if a test will not run, the runner or the import is what needs fixing. Deleting a test whose subject no longer exists is fine. If you believe a test should go for any other reason, stop and say which test and why, and wait for an answer.
- REMOVING, TRIMMING, LOOSENING, SKIPPING OR WORKING AROUND A TEST TO STOP IT FAILING IS CHEATING AND IS NEVER ALLOWED. That covers deleting the failing assertion and keeping the rest, widening what an assertion accepts, adding a wait or retry so a race passes, ignoring an error line in a check and changing what a port of a test asserts so it differs from the test it ports. A failing test is a bug in the code or in the test: find the cause and fix it. A port of a test asserts what the original asserts.
- NEVER LIE ABOUT WHAT YOU HAVE DONE OR VERIFIED. Do not say a thing works, passes, is tested, is verified or is complete unless you ran it and read the result in this session. Do not describe an intention as an outcome. Do not present a skipped test, a compile that merely succeeded or a code reading as evidence that behaviour is correct. If you are inferring rather than observing, use words that say so, and say what you did not check.
- NEVER SHIP A STUB THAT PRETENDS TO WORK. A function that silently does nothing (returns the argument, returns an empty result, swallows an event or has an empty body) will be called by something eventually and will fail invisibly, often far from the cause. If you cannot implement something now, make it fail with a message naming what is missing. Never leave a no-op in a code path that a caller will treat as success.
- ALL FAILURES MUST BE NOISY. Never write a path that discards an error, drops data or returns a success value when the work did not happen. Errors get thrown or returned, not swallowed. A missing capability fails and names itself. Prefer a loud crash over a quiet wrong answer, always.
- WORKAROUNDS ARE NOT ACCEPTABLE. Fix the cause. Do not change an input, an expected value or a check so that a failure goes away without finding out why it happened: converting a Windows path's backslashes to slashes, loosening an assertion, adding a retry, a wait or a platform special case. If the cause cannot be fixed because it is outside the machine (a network that dropped, a remote service that was down), tell the human and wait. Do not add a retry or any other patch on your own.
- YOU FIND A BUG, YOU FIX IT. A test that failed once and passed the next time is a bug: it is telling you the code or the test has a race, a fixed timeout that load can exceed or a resource it does not own, and every one of those is findable and fixable.
  - "It passed on the retry" is not a result. Neither is "it fails only under load", "it is unrelated to my change" or "it was already like that".
  - Do not write a bug down instead of dealing with it. Do not start a registry, a known-issues list, a section in a doc or a TODO comment naming a test that sometimes fails.
  - "I could not fix it" is not an outcome. The only failures outside your reach are the ones outside the machine: a network that dropped, a disk that filled or failed, a remote service that was down. The code should expect those and fail loudly, naming the cause, when they happen. Everything else is yours: keep going until you have the cause, and if you cannot find it yet, say what you have ruled out and what you will look at next.
- Never use memory.
- All Claude configuration goes in this repository only, not in the home directory.
- Slash commands go in `.claude/commands/`, as a markdown file per command, grouped in a subdirectory where there is more than one of a kind: `.claude/commands/ux/review/create.md` is `/ux:review:create`. A request for a "skill" means one of these. Do not create a `.claude/skills/` directory or a `SKILL.md`, and do not put a command in the home directory. Give each command frontmatter carrying `description` and nothing else, then the prompt as ordinary markdown with a heading and steps. The `description` says what the command does, not when to trigger it.
- Never write `mise exec --` in docs, READMEs, comments or script help text. Users run commands without it. It is only for commands Claude runs itself.
- Never say "you are right", "you're right" or any other agreement as a way to open a reply. Say what was wrong and what you will do about it. Never tell the human untested code can be committed now and tested later: say it is untested, and say what would test it.
- Never stash code unless asked.
- Never use `cd` to permanently change directories within the repo. Use it on a case-by-case and temporary basis as part of a command to run the command from a particular directory.
- Never invoke shell scripts directly (e.g. `bash ./apps/ziggy-example/smoke-tests/run.sh android`). Use the `bun run` equivalent from `package.json` (e.g. `bun run test:ziggy-example:and`).
- HIGH PRIORITY: `rm -r` is banned, in every form and every flag combination that includes it (`-r`, `-R`, `--recursive`, `-rf`, `-fr`), unless I ask for that exact deletion in the message you are acting on. This covers commands you run yourself, commands you ask me to run and any `rm -r` you write into a script, a test, a runner or a hook. A recursive delete takes everything under a path, and the path is often built from a variable: when that variable is empty, wrong or points somewhere shared, what goes is not what you meant to go. If you believe something has to be removed recursively, stop and say what and why, and wait for an answer. Removing a single file by name is not covered by this and is fine.
- NEVER WAIT FOR ANOTHER WORKTREE'S TESTS TO FINISH BEFORE RUNNING YOUR OWN. Start the run you need when you need it. Do not watch for other runs, do not poll for them and never treat another worktree's activity as a reason to hold off. If two runs contend, that is a bug worth knowing about; a run you postponed tells nobody anything.
- EVERY TEST IN THIS REPOSITORY MUST SURVIVE RUNNING BESIDE ANOTHER COPY OF ITSELF AND BESIDE EVERY OTHER SUITE, INCLUDING ONES STARTED FROM A DIFFERENT WORKTREE. I work in several worktrees at once and run tests in all of them at the same time. A test that only works when it is the only thing running is broken, whatever it does on its own.
  - Nothing may claim a machine-wide resource by a fixed name. That means no hardcoded port, no fixed path under `/tmp` or anywhere else, no fixed lock or config path and no fixed device. Let the operating system choose a free port, and give each test a directory from `ziggy_test_temp_dir` (`apps/ziggy-example/scripts/lib/test-lib.sh`) rather than naming a directory yourself.
  - EVERY PROCESS A TEST SUITE STARTS MUST HAVE ITS PID RECORDED AT THE MOMENT IT IS STARTED, so it can be cleaned up reliably at the end. Recording is the launcher's job, not the cleanup's. Start background processes with `launch_in_process_group` (`apps/ziggy-example/scripts/lib/process-control.sh`), which records each one in the file `ZIGGY_LAUNCHED_GROUPS` names, so the runner can report and stop any still running at the end. Never run a long-lived helper in the foreground, because a foreground child has no pid anything else can see.
  - NEVER kill a process by matching its command line. `pkill -f`, `pkill`, `killall` and anything else that selects by name asks the kernel about every process on the machine, and the app's command line is identical whichever checkout launched it, so it kills the identical process belonging to another worktree's run. Kill the pids you started and their descendants, with `kill_process_tree` or `kill_process_group` from `apps/ziggy-example/scripts/lib/process-control.sh`.
  - Interference is not flakiness and must never be dismissed as it. A suite that passes alone and fails in company is telling you it contends on something shared. Running a second copy of the suite beside it is the cheapest way to surface a fixed port or a fixed path.
- When creating a new worktree, never use `EnterWorktree` with a `name` parameter. Instead: (1) run `git branch --show-current` to get the current branch, (2) run `git worktree add -b <new-branch> .claude/worktrees/<name> <current-branch>` to create the worktree explicitly branching from the current branch, (3) then use `EnterWorktree` with the `path` parameter to enter it.
- The `run:ziggy-example:<platform>` commands build the app before they launch it, so the running app is built from current source. A code change that does not show up is never caused by a stale build. Never tell me to rebuild and never blame a missing change on the build being out of date. Find the real cause.
- The Android emulators belong to me. The Android suites (`test:ziggy-example:and`, `test:zig:android`) use the devices named in `ZIGGY_ANDROID_DEVICES` (adb serials, space separated), else every emulator and device adb has attached and ready, whichever project started it. Each run claims one under Ziggy's own per-device lock (`ziggy_android_device_lock_path` in `apps/ziggy-example/scripts/android-common.sh`) and waits for one to come free.
- Never assume whether an Android emulator is attached. Run `adb devices` (from the Android SDK's `platform-tools`) at the point you need the answer and read it: a serial whose state is `device` is ready. I start and stop emulators whenever I like and do not announce it, so a reading taken earlier in the session is stale. This applies as much to saying an emulator is up as to saying it is down, and to anything that follows from either.
- Never start, stop, restart or repair an emulator, never create or remove a network tap or bridge and never run sudo. When an emulator is broken or none is attached, say so and leave it to me.
- Never say something was "intentionally done" unless I explicitly asked for that exact behaviour. State what the code does and own the mistake.
- Something you (the AI) have previously written in a plan does not mean that I approve of or accept that thing. Never use "it was in the plan" as the reason something was done. Whenever I ask "What is the reason for X?" I mean "Why was that change necessary?".
- Plans are transient. Everything under `docs/plans/` is scratch working material that gets cleaned out of the repo once the work is finished, so never reference a plan from anything that stays: not from documentation, not from a slash command, not from code or comments, not from a commit message and not from another doc that outlives it. If a plan contains something worth keeping, copy the content itself into the thing that needs it, or into a permanent doc under `docs/`.
- You are not to commit, stage, push, revert or perform any other dangerous or hard-to-reverse Git operation (including `git add`, `git commit`, `git push`, `git reset`, `git restore`, `git checkout` of changes, `git rebase`, `git merge`, force-push, branch creation/deletion) without an explicit direction to do so in that message. An earlier instruction to do one of these is a one-time direction; it does not authorise repeating the operation after later edits. When in doubt, leave the Git state alone and ask.
- Expect the human to stage things. They often `git add` your work as they review it, and they commit whenever they choose, so the staging area and the working tree change under you without warning. Finding your edits staged, or finding files you never touched appear, disappear or move between staged and unstaged, means the human has been working. Use `git status` and `git diff HEAD` (or `git diff --cached`) rather than a bare `git diff`, which shows only unstaged changes. Do not conclude your edit failed or was lost because `git diff` came back empty, and do not "tidy it up" by unstaging, resetting, checking out or otherwise putting the Git state back how you remember it.
- THIS REPOSITORY USES TYPESCRIPT, ZIG AND SHELL SCRIPT. Zig, declared through `mise.toml`, is the language for the core, the task queue and the Linux and Windows native apps. Swift (the macOS and iOS native apps) and Java with its Gradle build (the Android native app) are an exception because those platforms require them, along with the C headers of the core's C interface and the ones the Zig native apps import platform APIs through. None of that is licence to add more native code than the platform forces. Do not introduce another language. `python3`, perl, Ruby, Go and friends are banned outright, including as an undeclared dependency.
- A SHELL SCRIPT CONTAINS SHELL. Do not embed another language inside one, in any form: not `python3 -c "..."`, not `bun -e "..."`, not a `node -e`, not a heredoc feeding an interpreter, not an awk program that is a program in its own right. Embedded code is a string as far as the shell is concerned: nothing type-checks it, nothing lints it, `bun run compile` never sees it and a syntax error in it surfaces only when that one code path runs. This holds however short the snippet is.
- When a shell script needs something that looks beyond shell, find the shell answer first, because there usually is one: `stat` for a modification time, `cmp` for an exact file comparison, `uuidgen` for a UUID, `od` for a binary field, `jq` for anything JSON. Assume there is a shell answer until you have tried it and watched it fail. Only when there is no shell answer does it become a TypeScript helper: a `.ts` file with a comment block saying what it is for and a documented argument list. See `apps/ziggy-example/scripts/ios-device.ts` for an example.
- EVERY NEW SCRIPT COMES WITH A MARKDOWN FILE BESIDE IT, named after the script, covering what it is for, how it is invoked and what each argument means. Keep it current, and link to a fuller guide under `docs/` rather than repeating one.
- DO NOT WRITE TESTS FOR SHELL SCRIPTS, and do not create `*.test.sh` files. Shell in this repository is the test harness itself, and the thing that proves a harness works is running the real suite it drives. If you believe a piece of shell cannot be trusted without a test, stop and ask, and wait for an answer.
- TEST MARKER FILES ARE BANNED. Do not add a file whose only job is to tag a test directory so a runner treats that test differently. A marker records a judgement made once and nothing ever re-checks it. If a runner needs to know something about a test, it must read it from the test itself or work it out at the time.
- NEVER WRITE A SCRIPT, A FILE OR A HELPER OF ANY KIND TO WORK AROUND A LIMIT OF YOUR OWN HARNESS. Your command timeout, a refusal to run a command it could not parse, a background job being killed: none of those are problems with this repository and none of them get a file committed to it. Run the command directly. If it cannot finish inside your limit, say so in one line, give me the command and wait: I will run it and tell you when it is done.
- MacOS and iOS are built with Xcode 14.2 on macOS 12.7.6, the oldest the docs support. Never require an Xcode or macOS version newer than that. When native code needs a newer API, use an availability guard (`#available`, `#if swift(>=...)`) or a compatible approach. If a version bump seems unavoidable, stop and ask first.
- When I ask for an ETA, give one at once, as a time range with what it depends on. Never refuse, argue or ask a question first.
- When I ask you to record a note or a todo, never change my writing or distort it in any way.
- Keep this file terse. It is loaded into context for every task, so state the rule and stop: no lists of examples, no worked illustrations.

## Writing

- No serial comma. Write "Linux, Windows and macOS", never "Linux, Windows, and macOS". Where a list reads ambiguously without it, rephrase the sentence.
- Never use em dashes. Use a period, comma, colon or parentheses instead.

## Commands

### Setup
- `mise install` (from repo root) - Installs the pinned tools.
- `bun install` (from repo root) - Installs the dependencies. You must do this before you can run any other scripts.
- `bun run setup` - One-time platform toolchain setup: the Android SDK and NDK on Linux and MacOS, a check of Xcode on MacOS and the WebView2 SDK and WiX Toolset on Windows.

### Run from repo root
- `bun run compile` (alias `c`) - Type-check the TypeScript.
- `bun run test` (alias `t`) - The TypeScript unit tests: `ziggy-ui` and the example's UI.
- `bun run test:zig` - Every Zig test (`zig build test`): Ziggy's core, the task queue, the parts of the Linux and Windows native apps that need no platform and the example's core.
- `bun run test:zig:android` / `bun run test:zig:ios` - The Zig unit tests of Ziggy's core and the example's core, run on an Android emulator or device, or on a booted iOS simulator.
- `bun run test:android-shell` - The JUnit tests of the Android native app, on this machine's JVM. Needs no device.
- `bun run compile:zig` - Builds the example's core, cross-builds it for every platform and compiles the Windows native app.
- `bun run test:ziggy-example` - The example's smoke tests on this machine's desktop platform. `bun run test:ziggy-example -- <number|name>` runs one scenario.
- `bun run test:ziggy-example:and` - The example's smoke tests on an attached Android emulator or device. Takes a scenario the same way.
- `bun run test:ziggy-example:ios` - The example's smoke tests on the iOS simulator, or a connected iOS device (MacOS only). Takes a scenario the same way.
- `bun run build:ziggy-example:<platform>` - Builds the UI and the app.
- `bun run run:ziggy-example:<platform>` - Builds the app and launches it (an emulator, simulator or device for a phone).
- `bun run sync:ziggy-example:<platform>` - Builds what the platform's native project packages and puts it where that project expects it.
- `bun run open:ziggy-example:<platform>` - Syncs, then opens the native project in its editor.
- `bun run package:ziggy-example:<platform>` - Packages the release app, without the test hooks, into `apps/ziggy-example/out/<platform>`.
- `bun run distribute:ziggy-example:android` - Builds the Android app and uploads it to Firebase App Distribution.
- `bun run clean:ziggy-example:<platform>` - Removes the platform's build output.

`<platform>` is `linux`, `windows`, `macos`, `android` or `ios`, and each runs on that platform (Windows under Git Bash). A change to the Android or iOS native app, or to the core, is not tested until the suites for that phone platform have run.

## Guides

- [README](README.md) - What Ziggy is, what is in the repository, getting started and the glossary
- [Integrating Ziggy](docs/integrating-ziggy.md) - Using Ziggy from an app, from a local path or a version tag
- [Building your app](docs/building-your-app.md) - Starting a new app from the example, its parts and the commands on each platform
- [Distributing your app](docs/distributing-your-app.md) - Packaging, signing and getting a build to testers and stores
- [Releasing Ziggy](docs/releasing-ziggy.md) - The release workflow and how a version is released
- [Architecture](docs/architecture.md) - How the parts fit, the message protocol, tasks, channels, host callbacks, menus and test hooks
- [Ziggy package](packages/ziggy/README.md) - What is in `packages/ziggy`
- [Ziggy example](apps/ziggy-example/README.md) - The example app, its commands and what each platform needs
- [Smoke tests](apps/ziggy-example/smoke-tests/run.md) - How the example's smoke tests run, and every scenario

## Code Style
- **Types**: Use interfaces with PascalCase (`IStorage`) for types, explicit return types
- **Interface names always start with `I`**. This applies to every TypeScript interface without exception, including ones that describe plain data and ones that describe a function.
- **Naming**: camelCase for variables/methods, PascalCase for classes/interfaces
- **Imports**: Named imports for functions, default imports for modules
- **Functions**: Named functions for top-level methods, arrow functions for callbacks
- **Async**: Use async/await pattern for asynchronous code
- **Formatting**: 4-space indentation, braces on same line as control statements
- **Comments**: Line comments with `//` preceded by blank line, method docs above function. Use `//` comments for method docs.
- All global symbols (functions, types, interfaces, classes, constants) must have a `//` comment block above them explaining their intent.
- All fields in interfaces, classes and structs must have a `//` comment explaining their purpose.
- Never use single-character variable names, including arrow function parameters (e.g. use `fileName => ...` not `f => ...`). Use long descriptive identifiers.
- Do not introduce a constant that is used once. A value used in one place goes inline at that place, where the reader can see it. A constant earns its name when the value is used in more than one place, or when the literal does not explain itself and the name is what says why that value.
- Avoid single line if statements. All if statements should have curly brackets around the body.
- Never put multiple statements on one line. Each statement should be on its own line.
- Never write an object literal on one line. Open the brace, put each property and each spread on its own line ending in a comma and close the brace on its own line. The only exception is an empty `{}`.
- Put `else` and `catch` blocks on a new line.
- Tests go under the directory `src/test` in each package.
- Use `test(` not `it(` in Jest test files.
- UI code is a thin layer. Factor non-trivial UI logic out into a plain function under a `lib/` directory (as `apps/ziggy-example/ui/src/lib` does) and unit test the plain function. Do not extract or test trivial logic only to gain a test.
- You do not have to invent a new file to "get a test on it". When the logic belongs to something that already exists, put it there. When it belongs nowhere and is small enough to read in one go, leave it where it is with a comment saying why, and let the test that exercises the feature cover it.
- Refrain from using the `any` type in normal code, although it's ok sometimes in test code.
- Never use anonymous object types inline (e.g. `Promise<{ foo: number }>`). Always define a named interface instead, unless specifically asked to use an anonymous type.
- Never use IIFE async generator pattern (`(async function* () { ... })()`). Extract to a named `async function*` instead.
- Never use `ReturnType<typeof ...>`. Use the type directly (e.g. `NodeJS.Timeout` instead of `ReturnType<typeof setTimeout>`).
- Never use the `unknown` type. Use the type directly.
- Global variables are generally frowned on. Do not add one (a module-level mutable variable, a Zig top-level or struct-level `var` or a `threadlocal`) unless the human explicitly asks for it. Pass the value down from whoever owns it instead.

## Restrictions
- TypeScript and Zig code should always compile after making changes.
- All tests should pass after making changes.
- Prefer to minimize the size of code changes.
- Prefer not to update test code unless needed.
- Add new tests for new code. Every function that is new, that you edit or that the user asks you about should have unit tests.
- Backward compatibility is not required.
- Use imports instead of requires.
- All imports should be at the top of the file and not inside any functions.
- Don't use dynamic imports.
- Don't add exception handling unless I ask for it.
- Don't use default or optional parameter values unless specifically asked to.
- Never reformat or rewrite entire files. Only edit the specific lines that need to change.
