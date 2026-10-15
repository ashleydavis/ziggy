# run-windows.sh

Builds the Windows app with `sync-windows.sh` (x64, ReleaseSafe, into `native/windows/zig-out`) and then runs `ziggy-test-app.exe`.

Run it as `bash apps/ziggy-test-app/scripts/run-windows.sh [app arguments]`. Every argument is passed to the app, for example `-geometry=1000x700+50+50` for a window of that size at that position.
