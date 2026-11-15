# New windows

A new window is another window of the app, run as a process of its own: one window, its own backend and its own task queue. It starts from the app's own executable, with the arguments the app gives it. The new process stays in the process group of the window that started it, so a smoke test that ends the group ends every window of the run.

## Opening a window

The frontend opens one with `window.ziggy.newWindow(arguments)`, usually in the handler of one of the app's actions. The template's File > New Window item runs the template's New Window action, whose handler calls `window.ziggy.newWindow([])`. The backend opens one with `services.new_window(io, allocator, arguments)`, from a message handler, a menu item's Zig function or a callback. Both resolve once the new process has started.

The new process gets everything the window that started it was given. Its command line, after the program's name, is that window's own command line followed by the arguments given to `newWindow`, so the user's options for the run (`--theme`, `-geometry=` or one of the app's own) reach every window. An option that both give reaches the window twice: `-geometry=` takes the later one, and a theme option given twice fails the window's start with `ThemeGivenTwice`. It also inherits that window's whole environment. A window opened under remote control connects to the same remote control server, where it is the next window number.

On Android, iOS and in dev mode the call fails with `NewWindowUnavailable`: a phone runs one window of an app, and dev mode's frontend is one browser tab served by one dev host.

## What Quit ends

Closing a window ends that window's process and leaves every other window running.

On Linux and macOS Quit ends every window of the app, whichever route asked for it: the Quit menu item (Cmd+Q on macOS, Ctrl+Q on Linux), `services.quit` from the app's own code, and the remote control `quit` command. Each window records itself as a file named by its process id in the `windows` folder of the app's data directory, and a Quit sends every other recorded process of the same executable SIGTERM. A window that receives SIGTERM ends as if its own Quit had been asked for: its backend stops and its log file ends with its footer. The next Quit removes a record left by a process that died.

On Windows Quit closes the window it was asked in, so each window ends only its own process.

## Shared files

Every window of an app shares its data directory: the config file, the state file and the web view's stored data belong to the app, so two windows can change the same file. The config file's update lock, described in [The config file](config-file.md), keeps one window's write from losing another's.
