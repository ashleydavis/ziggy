# 32-external-links

Checks that a link to an outside page reaches the system on every platform. The runner starts it with no arguments. A plain
link, a `target="_blank"` link followed 6 s after a click and a `window.open` 6 s after a click are each opened, so no user
gesture is behind the last two.

- Linux: a run with every URL handler hidden first checks that a failed open reaches the app's log. Then a URL handler of the
  scenario's own records each address the system is asked to open, so each link is seen reaching the system, and the frontend
  still holds the marker it was given.
- Android: the device log shows the activity start for each address. The app is restarted before the second and the third,
  because the browser the last link started covers the app and Android 10 and later refuse an activity start from an app in
  the background.
- Windows, macOS and iOS: nothing reports the open, so the scenario checks the app is still running 11 s after each click,
  which comes up to 6 s after it. On Windows the app's log also shows the new window request, and on Windows and macOS the
  frontend still holds its marker. On iOS the app is restarted before the second and the third, because the browser covers it.
