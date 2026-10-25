---
description: Test the Ziggy bootstrap end to end as a person would. Make ziggy-bootstrap-test with Claude, build and test it, put it on GitHub, check its workflows, then wait for the human's review before deleting it locally and on GitHub.
---

# Test the Ziggy bootstrap

Make a new Ziggy app called `ziggy-bootstrap-test` the way a person following Ziggy's guide does it, then build it, test it, put it on GitHub and check its workflows pass. The guide is "Building your app", section "Starting a new app from the template": https://github.com/ashleydavis/ziggy/blob/HEAD/docs/user-guide/building-your-app.md. A reference app made this way is https://github.com/ashleydavis/my-app-2.

The point is to find what is wrong with the bootstrap. So:

- Never fix the app. A step that fails is a finding. Record it with the command, the failing line from its output and what the cause is, then carry on with the next step.
- Follow the guide as written. Where the guide and what happens differ, that is a finding too.

## What running this command authorises

Running this command is the human's permission for these operations, on `ziggy-bootstrap-test` only:

- Creating the `ziggy-bootstrap-test` repository on GitHub and pushing to it.
- Deleting the local directory and the GitHub repository, but only in step 8, after the human has told you to clean up in a message of their own.

It authorises no other operation. Never fix, commit to or push anything else, including Ziggy itself.

## Steps

### 1. Check the ground is clear

- The base directory is the parent of the current git repository's root, or the current directory when it is not in a git repository. The app goes in `<base>/ziggy-bootstrap-test`.
- Get the GitHub account with `gh api user --jq .login`.
- If `<base>/ziggy-bootstrap-test` exists, or `gh repo view <account>/ziggy-bootstrap-test` finds a repository, a previous run left it behind. Say which exists and stop: deleting it needs the human's word.
- Check `gh auth status` lists the `delete_repo` scope. When it does not, tell the human now that step 8 needs it and that they can add it with `gh auth refresh -h github.com -s delete_repo`. Then carry on.

### 2. Make the app with Claude

Do what the guide's "Creating your app with Claude" says a person does: make the directory, start Claude in it and give it the guide's sentence. Run a separate Claude in the directory, so it starts with no knowledge of this conversation, just as the person's would:

```bash
mkdir <base>/ziggy-bootstrap-test
env -C <base>/ziggy-bootstrap-test claude -p --permission-mode bypassPermissions "Make a new Ziggy app here by following https://github.com/ashleydavis/ziggy/releases/latest/download/agent-quick-start.md"
```

- It asks for the app's details one question at a time. Answer each with `env -C <base>/ziggy-bootstrap-test claude -p -c --permission-mode bypassPermissions "<answer>"`, which continues the same conversation. Answer the first question with `use the defaults`.
- Reply to anything else it asks the way a person following the guide would, and record the question as a finding: the agent quick start says it asks only for the names.
- Making the app takes several minutes. Run each call in the background and wait for it to finish.
- Keep its final message. It holds the next steps the agent quick start tells it to give.

### 3. Check what it made

- `git log` shows one commit and `git status` shows a clean tree.
- `package.json` names the Ziggy release the agent said it used.
- A case-insensitive search for `ziggy-template`, `ziggy_template`, `ZiggyTemplate`, `dev.ziggy.template` and "Ziggy template" finds only what the agent quick start says stays: the Claude Code commands in `.claude/commands/ziggy`.
- Compare the file list with https://github.com/ashleydavis/my-app-2, allowing for the name. A file in one and not the other is a finding.

### 4. Build and test it

Run the commands the agent's next steps gave, in its directory, one after another, through `mise exec -C <base>/ziggy-bootstrap-test --`:

```bash
bun run compile
bun run test
bun run test:zig
bun run test:smoke
bun run build:linux
```

Use the platform this machine runs on in place of `linux`. Do not run `bun run linux` or `bun run dev`: they open the app and wait, so they are for the human in step 7.

### 5. Put it on GitHub

Do what the guide says a person does: create an empty repository, then push with the commands the agent's next steps gave.

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
- The commands the human can run in the app's directory to review it, each in a code block with a comment, without `mise exec --`: the four test commands, `bun run <platform>` and `bun run dev`.
- That when they have finished, they tell you to clean up.

Then wait. Do not clean up until the human says so in a message of their own.

### 8. Clean up

Only after the human has told you to clean up:

```bash
gh repo delete <account>/ziggy-bootstrap-test --yes
rm -rf <base>/ziggy-bootstrap-test
```

- When `gh repo delete` fails for want of the `delete_repo` scope, give the human `gh auth refresh -h github.com -s delete_repo` to run, then run the delete again when they say it is done.
- Running the app and its tests writes its data to `~/.local/share/ziggy-bootstrap-test` and `~/.cache/ziggy-bootstrap-test`. List what is there under those two names and remove it.
- Report in one line what was deleted.
