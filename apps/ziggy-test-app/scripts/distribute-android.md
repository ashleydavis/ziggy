# distribute-android.sh

Builds the test app's Android app and uploads it to Firebase App Distribution, which notifies the tester group and gives them a link to install it.

Run it from the repository root:

```
bun run distribute:ziggy-test-app:android
bun run distribute:ziggy-test-app:android -- --groups testers,family
```

It needs the Firebase CLI on your PATH and signed in (`curl -sL https://firebase.tools | bash`, then `firebase login`), and the Android SDK and NDK that `bun run --filter=ziggy-test-app setup` sets up.

## Arguments

- `--groups <aliases>` names the tester group aliases to release to, comma separated, as they appear in the Firebase console. The default is `testers`. Groups belong to the whole Firebase project.
- `--project <id>` names the Firebase project. The default is the one `FIREBASE_PROJECT` in the script names.
- `--build-only` builds the APK and stops. It runs nothing against Firebase and needs no Firebase CLI.

## What it decides for you

- **The Firebase app** is found by the test app's package name, `dev.ziggy.testapp`. When the project has no app for that package the script creates one, called "Ziggy test app", so nothing has to be set up in the console first.
- **The build** is `package-android.sh` for arm64, the architecture of testers' mobile devices. It is the release build, debug signed so that it installs. Android's Play Protect may show "Unsafe app blocked" until the app targets a newer Android version and is signed with a release key.
- **The version** is the version in `apps/ziggy-test-app/package.json` followed by `-dev.` and the UTC time of the build, so a tester can say which build they have. The version code beside it is minutes since the epoch, which only goes up, so a mobile device treats each upload as an update.
- **The release notes** come from `scripts/release-notes.sh`, cut to the newest commits because Firebase rejects long notes after the whole APK has been uploaded.

## See also

- [Distributing your app](https://github.com/ashleydavis/ziggy/blob/main/docs/user-guide/distributing-your-app.md): the one-time Firebase setup, what testers do on their mobile devices and what goes wrong.
