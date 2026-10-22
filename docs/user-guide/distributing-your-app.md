# Distributing your app

How a Ziggy app is packaged, signed and put in front of testers and users on each platform. The Ziggy template's package scripts are the starting point: an app copied from the template has them, with its own name in place of the template's. Each script has a markdown file beside it with every argument.

Every package is built for release: optimized and without the test hooks. Scenario `8-release-has-no-hooks` of the smoke tests checks that a release build has no test control connection.

## Packaging

`bun run package:<platform>` from the app's root (`bun run package:ziggy-template:<platform>` for the template in this repository) writes the packages for one platform into `out/<platform>`. Each runs on its own platform: Linux on Linux, Windows under Git Bash on Windows, MacOS and iOS on a Mac.

| Platform | Packages | Signing |
|---|---|---|
| Linux | a zip of the executable, and a `.deb` that installs it under `/opt`, links it into `/usr/bin`, adds a menu entry and depends on the runtime libraries of GTK 3 and WebKitGTK 4.1 and on the plugins of GStreamer | unsigned |
| Windows | a zip of the executable, and an `.msi` installer for the current user, built with the WiX Toolset that `setup` fetches | unsigned |
| MacOS | a `.dmg` with a link to Applications, and a zip | ad hoc signed, not notarized |
| iOS | an `.xcarchive` and an `.ipa` built with code signing off | unsigned |
| Android | an `.apk` per architecture (`x86_64` and `arm64`) | signed with the debug key, so it installs |

The frontend is embedded in the app's own code on every platform (the Linux and Windows executables, and the backend library inside the MacOS, iOS and Android apps), so no package carries a directory of frontend files.

## Signing

None of the packages is signed for a store. What each platform needs before a build reaches users who do not want to see a warning:

- **Windows**: sign the executable and the `.msi` with a code signing certificate (`signtool sign`). An unsigned installer runs, but SmartScreen warns about it.
- **MacOS**: sign the app with a Developer ID Application certificate, with the hardened runtime, and notarize it (`xcrun notarytool submit`, then `xcrun stapler staple`). An ad hoc signed app is refused by Gatekeeper on another Mac unless the user overrides it.
- **iOS**: an app reaches a device only signed with an Apple development or distribution certificate and a provisioning profile. Archive with signing on (the app's team in the Xcode project), then export for TestFlight or the App Store, or for ad hoc distribution to registered devices.
- **Android**: make a release keystore with `keytool`, and add a `signingConfig` to `native/android/app/build.gradle` that reads the keystore's path and passwords from a file kept out of git. A debug signed build installs, but Play Protect may show "Unsafe app blocked", and the Play Store accepts only a release signed build (as an app bundle, `bundleRelease`).
- **Linux**: a `.deb` is usually distributed unsigned, or through a repository whose metadata is signed with GPG.

## Getting a build to testers

### Android, through Firebase App Distribution

Tester builds of an Android app go out through [Firebase App Distribution](https://firebase.google.com/docs/app-distribution). It takes an APK, emails the testers you have added and installs onto their mobile devices through the Firebase App Tester app. There is no store listing and no review, so a tester has the build a couple of minutes after the upload finishes. It is free on Firebase's Spark plan. The template's `distribute-android.sh` (`bun run distribute:ziggy-template:android`) does the whole upload.

One-time setup:

1. In the [Firebase console](https://console.firebase.google.com), signed in with the Google account that should own it, create a project. Google Analytics is not needed.
2. The distribute script finds the Firebase app by the Android package name (the `applicationId` in `native/android/app/build.gradle`) and creates it when the project has none for that package, so the app does not have to be added to the project first. Skip the `google-services.json` download and the SDK steps the console offers: App Distribution needs none of them.
3. Open App Distribution and click Get started, which turns the API on for the project.
4. On the Testers & Groups tab, create a group named Testers, check its alias is `testers` (the alias is what the upload names) and add the testers' email addresses, including your own.
5. Install the Firebase CLI (`curl -sL https://firebase.tools | bash`) and sign in (`firebase login`) with the account that owns the project.
6. Name the app's Firebase project: set the `FIREBASE_PROJECT` environment variable, or pass `--project <id>` each time. The script stops when neither names one.

Then each new build is one command, which builds the release APK for arm64 and uploads it for the `testers` group (`--groups a,b` for other groups). The release notes are the commits since the last version tag, from `scripts/release-notes.sh`, cut to the newest because Firebase rejects long notes. The version name is the app's version followed by `-dev.` and the time of the build, and the version code is minutes since the epoch, so each upload is an update on the mobile device.

What a tester does the first time: they open the invitation email and tap Get started, which downloads App Tester; Android refuses to install it until they allow installs from that source (Settings, "Allow from this source", then Install); in App Tester they sign in with the invited account, tap "Start testing on this device", then Download on the release and allow installs from App Tester the same way. After that each new build arrives as a notification in App Tester.

When something goes wrong:

| Symptom | Cause and fix |
| --- | --- |
| `the Firebase CLI is not on your PATH` | Install it, then run `firebase login`. |
| The upload is rejected as an app that does not exist | The project named by `--project` is not the one the testers are in, or the CLI is signed in to an account without access to it. |
| `Failed to authenticate` | The login has expired or is for the wrong account. Run `firebase login` again. |
| A tester sees no new build | The group released to is not the group they are in. Check Testers & Groups in the console. |
| "Unsafe app blocked" on the tester's mobile device | Play Protect, usually objecting to the app's `targetSdkVersion` or the debug signature. Tap **More details** then **Install anyway** when offered. If the only option is **OK**, turn off app scanning in the Play Store (profile icon > Play Protect > settings) and install again, or sign release builds. |
| `App not installed` | The mobile device has a build of the app signed with a different key. Uninstall it, then install again. `adb shell dumpsys package <application id>` shows which build is installed. |

### iOS, through TestFlight

Archive the app signed for distribution, upload it to App Store Connect from Xcode's Organizer and add testers to the build in TestFlight. Internal testers (members of the App Store Connect team) get it at once; external testers after a short review.

### Desktop

The desktop packages are files: put them where testers can download them. An app's release workflows (`.github/workflows/release-<platform>.yml`, which come with the template) do that once it is on GitHub, publishing each platform's packages as a GitHub release on every successful build of the default branch.

## Getting a build to users

- **Android**: the Play Store, with a release signed app bundle, through the Play Console.
- **iOS**: the App Store, through App Store Connect, after App Review.
- **MacOS**: a signed and notarized `.dmg` from your own site, or the Mac App Store (which needs the app sandbox and a Mac App Store certificate).
- **Windows**: a signed `.msi` from your own site, or the Microsoft Store.
- **Linux**: the `.deb` from your own site or an apt repository.

## See also

- [Building your app](building-your-app.md): copying the template and renaming it.
- [Releasing Ziggy](../development/releasing-ziggy.md): the release workflow that publishes the template's packages.
