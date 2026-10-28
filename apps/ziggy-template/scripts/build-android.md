# build-android.sh

Runs `sync-android.sh`, then `gradlew assembleDebug`. The APK is `native/android/app/build/outputs/apk/debug/app-debug.apk`.

Invoke: `bash apps/ziggy-template/scripts/build-android.sh [--arch "<list>"] [--optimize <mode>] [--output-dir <dir>]`

`--arch` and `--optimize` are passed to `sync-android.sh`, which describes them. `--output-dir <dir>` also copies the APK to `<dir>/ziggy-template.apk`, which is where CI's `app-build` job and the smoke tests take it from.
