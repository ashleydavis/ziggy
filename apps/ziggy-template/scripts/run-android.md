# run-android.sh

Builds the debug APK for the chosen device's architecture, installs it and starts it.

Invoke: `bash apps/ziggy-template/scripts/run-android.sh [--target <adb serial>]`

- `--target <serial>`: the device to use (or set `ZIGGY_ANDROID_TARGET`). Without it the first attached emulator or device that no Ziggy smoke test is using is taken, under the device lock the smoke tests take, so a run never installs over an app a test is using, and the lock is held until the script ends. The script never starts an emulator.
