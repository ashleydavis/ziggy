# build-android.sh

Runs `sync-android.sh`, then `gradlew assembleDebug`. The APK is `native/android/app/build/outputs/apk/debug/app-debug.apk`.

Invoke: `bash apps/ziggy-template/scripts/build-android.sh [--arch "<list>"] [--optimize <mode>] [--test-hooks]`

The options are passed to `sync-android.sh`, which describes them.
