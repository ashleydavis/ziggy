# bundle-ui.sh

Builds the template's UI with Vite and puts the result in `apps/ziggy-template/dist`, which every platform embeds. Run through the app's `bundle:ui` script. No arguments.

The UI is built into a directory of its own first. Builds of the app read `dist` while they run, and several runs can be at it at once, so `dist` is not emptied and rewritten in place: when the built UI is the same as `dist` nothing in `dist` is touched, and otherwise each changed file is moved into place whole and a file the new build no longer has is deleted.
