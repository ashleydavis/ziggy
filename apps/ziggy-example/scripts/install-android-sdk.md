# install-android-sdk.sh

Installs the Android command-line toolchain a Ziggy app needs, without Android Studio: Google's command-line tools, then, through sdkmanager, platform-tools (adb), the compile platform, the build tools, the NDK the app pins in `shells/android/variables.gradle`, the emulator and a system image. Everything goes under one SDK directory (`$HOME/Android/Sdk` on Linux), which is where [lib/android-env.sh](lib/android-env.md) looks. A JDK 17 is installed too when none is found (with apt on Debian and Ubuntu, which asks for sudo).

Invoked as `bash scripts/install-android-sdk.sh <option>` from the app's directory. The app's `setup` script (`setup-android.sh`) runs it with `--install`.

- no option: prints the help and changes nothing.
- `--status`: reports what is installed and what is missing, and changes nothing.
- `--install`: downloads and installs whatever is missing.

`ZIGGY_CMDLINE_TOOLS_VERSION` picks another build of Google's command-line tools than the pinned one. `ZIGGY_JDK17_HOME` names a JDK 17 to use.
