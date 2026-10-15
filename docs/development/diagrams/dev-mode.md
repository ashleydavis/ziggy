# dev-mode.svg

The diagram under "Dev mode" at the start of the architecture guide: the UI in an ordinary browser, the dev backend (the app's backend built as a program of its own), the app's dev server it gets the page from and the OS, and what passes between them.

## How it is made

It is made the same way as `communication.svg` (see `communication.md`): `dev-mode.mmd` is the Mermaid source, with a `label-under` line for the text under each box, and `bun run diagrams` draws `dev-mode.svg` from it. Never edit `dev-mode.svg` itself: the next `bun run diagrams` replaces it.

## Changing it

1. Edit `dev-mode.mmd`, keeping the names of boxes and the words on arrows short.
2. Run `bun run diagrams` from the root of the repository.
3. Look at the drawing: open `dev-mode.svg` in a browser, or the architecture guide in an editor's preview.
4. Update the "Dev mode" sections of `docs/development/architecture.md` when an arrow or a box changed.
