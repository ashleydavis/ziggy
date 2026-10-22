---
description: Release a new version of Ziggy by tagging the current commit of main and pushing the tag, then check the release workflow published it with the agent quick start and the pinned template archive attached.
---

# Release a new version of Ziggy

Follow [Releasing Ziggy](../../docs/development/releasing-ziggy.md), section "Releasing a version of the package". Read it first.

## Check the commit

1. Run `git status -sb`. Stop and say why if the current branch is not `main`, if it has changes that are not committed or if it is ahead of or behind `origin/main`. Do not commit, push or pull to fix it.
2. Find the latest version tag with `git ls-remote --tags --refs --sort=-version:refname origin 'v*' | head -n 1`.
3. The new version is the one the human gave. When they gave none, it is the latest with its last number one higher (`v0.0.6` becomes `v0.0.7`). Tell the human the version and the commit it will tag.
4. Find the run of the `Release` workflow on the commit with `gh run list --workflow release.yml --commit <sha>`. When it has not finished, wait for it with `gh run watch <id> --exit-status`. When it failed, stop and say which job failed. Do not tag a commit whose run did not pass.

## Release it

1. Tag the commit and push the tag:

   ```bash
   git tag <version>
   git push origin <version>
   ```

2. Pushing the tag starts the `Release version` workflow (`release-version.yml`). Find its run with `gh run list --workflow release-version.yml --limit 1` and wait for it with `gh run watch <id> --exit-status`. When it fails, stop and say which step failed and what its log shows.
3. Check the release with `gh release view <version> --json author,assets,body` and `gh release list --limit 1`: it is marked Latest, its author is `github-actions[bot]` and `agent-quick-start.md` and `ziggy-template-<version>.zip` are attached.
4. Check `https://github.com/ashleydavis/ziggy/releases/latest/download/agent-quick-start.md` returns the quick start, with `curl -fsSL`, and that `https://github.com/ashleydavis/ziggy/releases/latest/download/ziggy-template-<version>.zip` downloads, with `curl -fsSLI`.

Never move or delete a version tag once it is pushed. A mistake is fixed by releasing the next version.

## Report

Say the version, the commit it tags, the link to the release and its notes. When an app has to change something to move to this version, list it and remind the human to add it to the release's notes.
