# package-linux.sh

Builds the template for release, without the test hooks, and packages it as `out/linux/ziggy-template-<version>-linux-<arch>.zip` and `.deb`. The version comes from `apps/ziggy-template/package.json`. The packages are unsigned. Runs on Linux and needs `zip`, `dpkg-deb` and `jq`.

The frontend is embedded in the executable, so the app is one file. The zip holds one directory with that executable. The deb installs it as `/opt/ziggy-template/ziggy-template`, links it into `/usr/bin` and adds a menu entry (`/usr/share/applications/dev.ziggy.template.desktop`) so the app shows in the applications menu and search. It depends on the GTK 3 and WebKitGTK 4.1 runtime libraries (`libgtk-3-0` and `libwebkit2gtk-4.1-0`) and on the plugins of GStreamer (`gstreamer1.0-plugins-good` and `gstreamer1.0-libav`).

No arguments.
