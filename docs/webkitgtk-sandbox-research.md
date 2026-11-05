# WebKitGTK sandbox and blocked user namespaces

**Conclusion:** Ziggy's Linux native app has no code for WebKitGTK's sandbox because it needs none. With the webkit2gtk-4.1 API it uses, the sandbox is off unless the app turns it on (or `WEBKIT_FORCE_SANDBOX=1` is set), so bubblewrap is never run for its web view and a system that blocks user namespaces does not affect it.

## Why this note exists

Ubuntu 24.04 stops ordinary programs creating user namespaces, so `bwrap --ro-bind / / --unshare-user true` fails there with "setting up uid map: Permission denied". WebKitGTK's sandbox is built on bubblewrap, and apps with the sandbox on crash on such systems. Ziggy's Linux native app used to guard against this: before creating the web view it ran that bwrap command and, when it failed, turned the sandbox off, first by setting `WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS` in the process environment and then through `webkit_web_context_set_sandbox_enabled(context, FALSE)`. The smoke-test launchers also set the variable. This research found the sandbox was never on for Ziggy, so all of that was removed. Read this before adding sandbox handling back.

All source quotes below were read from the WebKit repository at the tag `webkitgtk-2.52.6` (the version installed when this was written, on Ubuntu 24.04) unless another tag or URL is given. A probe built against that library showed `webkit_web_context_get_sandbox_enabled(webkit_web_context_get_default())` returns FALSE.

## 1. Default and the setter in the 4.0/4.1 API

### What the sources state

- The sandbox field starts off. `Source/WebKit/UIProcess/WebProcessPool.h` (2.52.6 and 2.44.0):
  `bool m_sandboxEnabled { false };`
  https://github.com/WebKit/WebKit/blob/webkitgtk-2.52.6/Source/WebKit/UIProcess/WebProcessPool.h
- The context constructor turns it on only for the 2022 (GTK 4, `webkitgtk-6.0`) API. `Source/WebKit/UIProcess/API/glib/WebKitWebContext.cpp`, same in 2.44.0 and 2.52.6:
  ```
  #if ENABLE(2022_GLIB_API)
      priv->processPool->setSandboxEnabled(true);
  #endif
  ```
  https://github.com/WebKit/WebKit/blob/webkitgtk-2.52.6/Source/WebKit/UIProcess/API/glib/WebKitWebContext.cpp
- The setter and getter exist only in the old API (`#if !ENABLE(2022_GLIB_API)`), carry "Since: 2.26" and no "Deprecated:" tag. The setter forwards to the pool and the getter returns the same field:
  `context->priv->processPool->setSandboxEnabled(enabled);`
  `return context->priv->processPool->sandboxEnabled();`
  Calling the setter after a web process exists hits `g_error("Sandboxing cannot be changed after subprocesses were spawned.");`
- API docs, 4.1, library 2.42.5: "Set whether WebKit subprocesses will be sandboxed, limiting access to the system. This method must be called before any web process has been created ... Calling it later is a fatal error." Available since 2.26, no deprecation note.
  https://webkitgtk.org/reference/webkit2gtk/stable/method.WebContext.set_sandbox_enabled.html
- The only other way to turn it on in the 4.x API is an environment variable. `WebProcessPoolGLib.cpp`, `platformInitialize`, inside `#if !ENABLE(2022_GLIB_API)`:
  `if (forceSandbox == "1"_s) setSandboxEnabled(true);` (2.52.6 spells it with `strcmp`).
- Michael Catanzaro (WebKitGTK maintainer), 2020: "why isn't the sandbox enabled by default? ... It can break applications that use WebKitWebExtension" and "To sandbox any WebKitGTK app, just call `webkit_web_context_set_sandbox_enabled()`" and "The WebKitGTK sandbox will become mandatory in the future when porting applications to GTK 4."
  https://blogs.gnome.org/mcatanzaro/2020/03/31/sandboxing-webkitgtk-apps/
- WebKit bug 220117, "[WPE][GTK] Remove webkit_web_context_set_sandbox_enabled() from modern API": "The sandbox should always be enabled, with no API function to disable it." Landed as 259028@main on 2023-01-18. This is the GTK 4 API only.
  https://bugs.webkit.org/show_bug.cgi?id=220117

### Answers

- In the 4.0/4.1 API the sandbox has never become on by default, up to and including 2.52.6. It became always on (no setter) only in the `webkitgtk-6.0` API, from the change above (January 2023). I did not find which release first shipped `webkitgtk-6.0`; I looked at the bug and the source, not the release notes.
- The setter is still honoured on 2.44 to 2.52: it writes `m_sandboxEnabled`, which decides the launch (section 2). It is neither deprecated nor a no-op on Linux.
- `get_sandbox_enabled` returning FALSE means `m_sandboxEnabled` is false. That same field is what the launcher reads (next section). So the local probe's 0 is what WebKit uses to decide, not a separate flag. Inference from reading the code, not a run: the getter reflects real behaviour.

## 2. What happens when bwrap cannot make a user namespace

### What the sources state

- The web process launch option comes straight from the field. `Source/WebKit/UIProcess/glib/WebProcessProxyGLib.cpp`:
  `launchOptions.extraInitializationData.set("enable-sandbox"_s, m_processPool->sandboxEnabled() ? "true"_s : "false"_s);`
  A code search of the WebKit repository for `"enable-sandbox"` finds only this file, the launcher and MiniBrowser, so the network process is not given this option.
- The launcher. `Source/WebKit/UIProcess/Launcher/glib/ProcessLauncherGLib.cpp`:
  ```
  bool sandboxEnabled = m_launchOptions.extraInitializationData.get<HashTranslatorASCIILiteral>("enable-sandbox"_s) == "true"_s;
  if (sandboxEnabled && isInsideFlatpak() && isFlatpakSpawnUsable())
      process = flatpakSpawn(...);
  else if (sandboxEnabled && shouldUseBubblewrap())
      process = bubblewrapSpawn(...);
  else
      process = adoptGRef(g_subprocess_launcher_spawnv(launcher.get(), argv, &error.outPtr()));
  if (!process.get())
      g_error("Unable to spawn a new child process: %s", error->message);
  ```
- `Source/WTF/wtf/glib/Sandbox.cpp`: `return !isInsideFlatpak() && !isInsideSnap() && !isInsideUnsupportedContainer();`. The only bwrap test WebKit runs is inside `isInsideUnsupportedContainer` and runs only when `/run/.containerenv` exists; then it logs "Bubblewrap does not work inside of this container, sandboxing will be disabled."
- Reports from Ubuntu 24.04 show the failure when the sandbox is on: Launchpad bug 2060810 (Wike): "bwrap: setting up uid map: Permission denied", "Failed to fully launch dbus-proxy: Child process exited with code 1", "Trace/breakpoint trap". The report's output names `gtk-4.0/settings.ini`.
  https://bugs.launchpad.net/bugs/2060810
  The same pattern for Foliate: https://bugs.launchpad.net/bugs/2060767
- Turning the sandbox off by environment. 2.52.6 `WebProcessPoolGLib.cpp`, in `setSandboxEnabled` when asked to enable:
  `if (const char* disableSandbox = getenv("WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS")) { if (strcmp(disableSandbox, "0")) return; }`
  In 2.44.0 the same check sits in `isSandboxEnabled` in `ProcessLauncherGLib.cpp`: `if (!strcmp(sandboxEnv, "1")) return false;`
  The variable came from WebKit bug 250232 (landed 258930@main, 2023-01-15): "Disabling the sandbox is very useful for debugging purposes. But the name of the environment variable should be much scarier than the current WEBKIT_FORCE_SANDBOX=0."
  https://bugs.webkit.org/show_bug.cgi?id=250232
  Since then `WEBKIT_FORCE_SANDBOX` set to anything but 1 only prints "WEBKIT_FORCE_SANDBOX no longer allows disabling the sandbox. Use WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 instead."

### Answers

- When the sandbox is on and bwrap cannot make a user namespace on a normal host (not Flatpak, Snap or a `/run/.containerenv` container), WebKit does not fall back: it still takes the bubblewrap path. Inference from the code plus the Launchpad output: the dbus proxy or web process launched through bwrap exits and the app aborts with a trap, as in bug 2060810. I did not find a source naming the exact abort site for 2.52.
- When the sandbox is off (the 4.x default), bwrap is not run at all, so the namespace restriction does not matter. Inference from the launcher code above.
- Ways to turn it off: in the 4.x API, `webkit_web_context_set_sandbox_enabled(ctx, FALSE)` or simply never turning it on; in the 6.0 API, `WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS` (any value but "0" on 2.52.6, exactly "1" on 2.44.0) is the only way. The Ubuntu reports found (Wike, Foliate) are GTK 4 apps; inference: that is why they fail and 4.1 apps that never enable the sandbox do not.

## 3. What this means for Ziggy

- Ziggy's web view is created with `webkit_web_view_new()` (native-app.zig), which uses the default context. Nothing in `packages/ziggy/native/linux` calls `webkit_web_context_set_sandbox_enabled(..., TRUE)` or sets `WEBKIT_FORCE_SANDBOX` (checked with grep). So `m_sandboxEnabled` stays false and the web process is spawned by `g_subprocess_launcher_spawnv` without bwrap. Inference from the code: the removed `set_sandbox_enabled(FALSE)` call did nothing, because setting FALSE when the value is already false returns at once (`if (m_sandboxEnabled == enabled) return;`), and the bwrap check before it decided nothing.
- The removed `setenv("WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS", "1", 1)` did nothing either for the same reason: it only blocks a request to turn the sandbox on, and nothing makes one. Being in the process environment, it was also inherited by every program the app started. Inference from the 2.52.6 source.
- One case where the sandbox would be on: a user who sets `WEBKIT_FORCE_SANDBOX=1` turns it on in `platformInitialize`. On a system that blocks user namespaces the web view would then fail to start. That is the user's own setting, and they can undo it by unsetting the variable or by setting `WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1`.
- When to look at this again: if Ziggy moves to GTK 4 and the `webkitgtk-6.0` API, where the sandbox is always on and `WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS` is the only way to turn it off, or if Ziggy ever calls `set_sandbox_enabled(TRUE)`.

## Not checked

- Everything above about WebKit's runtime behaviour is read from source, not traced in a running app. What was observed: with the sandbox handling removed, all 25 Linux smoke tests passed on Ubuntu 24.04 with WebKitGTK 2.52.6, on a machine where the bwrap command above fails.
- WebKitGTK release notes (webkitgtk.org/news) were not searched for a sandbox default change; the source at 2.44.0 and 2.52.6 shows none for the 4.x API.
- Debian and Arch bug trackers were not searched; only Launchpad turned up in searches.
