---
description: Test the Ziggy bootstrap end to end as a person would. Make ziggy-bootstrap-test by following the agent quick start, build and test it, put it on GitHub, check its workflows, then hand the human a todo list to review it and delete it locally and on GitHub.
---

# Test the Ziggy bootstrap

Make a new Ziggy app called `ziggy-bootstrap-test` the way a person following Ziggy's guide does it, then build it, test it, put it on GitHub and check its workflows pass. The guide is "Building your app", section "Starting a new app from the template": https://github.com/ashleydavis/ziggy/blob/HEAD/docs/user-guide/building-your-app.md. A reference app made this way is https://github.com/ashleydavis/my-app-2.

The point is to find what is wrong with the bootstrap. So:

- Never fix the app. A step that fails is a finding. Record it with the command, the failing line from its output and what the cause is, then carry on with the next step.
- Follow the guide as written. Where the guide and what happens differ, that is a finding too.

## What running this command authorises

Running this command is the human's permission to create the `ziggy-bootstrap-test` repository on GitHub and push to it.

It authorises no other operation. Never fix, commit to or push anything else, including Ziggy itself. The human deletes the local directory and the GitHub repository: never delete either.

## Steps

### 1. Check the ground is clear

- The base directory is the parent of the current git repository's root, or the current directory when it is not in a git repository. The app goes in `<base>/ziggy-bootstrap-test`.
- Get the GitHub account with `gh api user --jq .login`.
- If `<base>/ziggy-bootstrap-test` exists, or `gh repo view <account>/ziggy-bootstrap-test` finds a repository, a previous run left it behind. Say which exists and stop: the human deletes it.

### 2. Make the app

Make `<base>/ziggy-bootstrap-test` and follow https://github.com/ashleydavis/ziggy/releases/latest/download/agent-quick-start.md yourself to make the app in it, as the guide's "Creating your app with Claude" says Claude does for a person. Never run `claude` to do it.

- Work only from the agent quick start and what it links to, not from this repository.
- Take the default for every detail it asks for.
- Write down the next steps it tells you to give. Steps 4 and 5 use them.

### 3. Check what it made

- `git log` shows one commit and `git status` shows a clean tree.
- `package.json` names the Ziggy release step 2 used.
- A case-insensitive search for `ziggy-template`, `ziggy_template`, `ZiggyTemplate`, `dev.ziggy.template` and "Ziggy template" finds only what the agent quick start says stays: the Claude Code commands in `.claude/commands/ziggy`.
- Compare the file list with https://github.com/ashleydavis/my-app-2, allowing for the name. A file in one and not the other is a finding.

### 4. Build and test it

Run the commands the next steps from step 2 gave, in its directory, one after another, through `mise exec -C <base>/ziggy-bootstrap-test --`:

```bash
bun run compile
bun run test
bun run test:zig
bun run test:smoke
bun run build:linux
```

Use the platform this machine runs on in place of `linux`. Do not run `bun run linux` or `bun run dev`: they open the app and wait, so they are for the human in step 7.

When these have run, tell the human the local directory and the commands from step 7 that let them test it themselves, then carry on without waiting.

### 5. Put it on GitHub

Do what the guide says a person does: create an empty repository, then push with the commands the next steps from step 2 gave.

```bash
gh repo create <account>/ziggy-bootstrap-test --private
git -C <base>/ziggy-bootstrap-test remote add origin git@github.com:<account>/ziggy-bootstrap-test.git
git -C <base>/ziggy-bootstrap-test push -u origin HEAD
```

It is private, as `my-app-2` is.

### 6. Check the workflows pass

- Every workflow in the app's `.github/workflows` that runs on a push must have a run for the pushed commit. List them with `gh run list -R <account>/ziggy-bootstrap-test --commit <sha>`. A run takes a few seconds to appear after the push.
- Wait for every run to finish with the `Monitor` tool, so the result arrives as a notification. These runs take a long time.
- For each failed run, read the failing job's log with `gh run view --job <job-id> --log-failed -R <account>/ziggy-bootstrap-test` and record the failing line and its cause.
- Check each release workflow that passed made its release, with `gh release list -R <account>/ziggy-bootstrap-test`.

### 7. Hand it to the human for review

Report, in this order:

- Whether the bootstrap passed: yes or no.
- Each finding, one line each.
- The Ziggy release it used, the local directory and the repository's Actions and Releases URLs.
Finish with this todo list for the human, with the placeholders filled in. Each command goes in a code block with a comment, without `mise exec --`.

1. Build, test and run it in `<base>/ziggy-bootstrap-test`: the four test commands, `bun run <platform>` and `bun run dev`.
2. Check the results of the workflows at `https://github.com/<account>/ziggy-bootstrap-test/actions`.
3. Review the code in the new app if required.
4. Delete the local repo, and the data running it wrote, using `rm -rf <base>/ziggy-bootstrap-test ~/.local/share/ziggy-bootstrap-test ~/.cache/ziggy-bootstrap-test`.
5. Delete the remote repo through GitHub settings at `https://github.com/<account>/ziggy-bootstrap-test/settings`, under "Danger Zone".

Never delete or clean up anything yourself.
