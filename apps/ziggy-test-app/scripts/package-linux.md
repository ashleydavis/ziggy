# package-linux.sh

Builds the test app for release and packages it as `out/linux/ziggy-test-app-<version>-linux-<arch>.zip` and `.deb`. The version comes from `apps/ziggy-test-app/package.json`. The packages are unsigned. Runs on Linux and needs `zip`, `dpkg-deb` and `jq`.

The frontend is embedded in the executable, so the app is one file. The zip holds one directory with that executable. The deb installs it as `/opt/ziggy-test-app/ziggy-test-app`, links it into `/usr/bin` and adds a menu entry (`/usr/share/applications/dev.ziggy.testapp.desktop`) so the app shows in the applications menu and search. It depends on the GTK 3 and WebKitGTK 4.1 runtime libraries (`libgtk-3-0` and `libwebkit2gtk-4.1-0`) and on the plugins of GStreamer (`gstreamer1.0-plugins-good` and `gstreamer1.0-libav`).

- `--output-dir <dir>`: where the zip and the deb go, in place of `out/linux`. The smoke tests give each run a directory of its own, so two runs in one checkout never write the same file.
