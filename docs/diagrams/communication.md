# communication.svg

The diagram at the start of the architecture guide, "How the parts communicate": the UI, the native app, the backend and the OS, the messages, responses, native calls and OS calls between them, and the languages each part is written in.

## How it is made

- `communication.mmd` is the diagram's source, in Mermaid. It names the boxes, the arrows and the words on each arrow, and sets the colours: a white background with black boxes, lines and text, so the diagram reads the same in a light or a dark editor.
- `communication.svg` is drawn from it by `bun run diagrams` (`scripts/render-diagrams.sh`), from the root of the repository. The architecture guide shows the SVG, not the Mermaid, so it looks the same in GitHub and in every editor's preview.
- The languages under each box are not something Mermaid can place. Each is a `label-under` comment in `communication.mmd` (`%% label-under: <box id> = <text>`), and after Mermaid has drawn the SVG, `scripts/add-diagram-labels.ts` adds each one as a line of small grey text under its box.
- Never edit `communication.svg` itself: the next `bun run diagrams` replaces it.

## Changing it

1. Edit `communication.mmd`:
   - A box is a line `Id["Name"]`. Keep the names short: the box shows the name only.
   - An arrow is a line `From -->|"words"| To`. Keep its words short, a word or two, and merge arrows that run between the same two boxes the same way. The table under the diagram in the architecture guide holds the detail.
   - The languages of a box are its `label-under` line. A new box that needs one gets a new line, naming the box by its id.
   - Mermaid lays the boxes out by itself, left to right. It has no way to place a box by hand.
2. Run `bun run diagrams` from the root of the repository. It needs Chrome or Chromium (`docs/dependencies.md`).
3. Look at the drawing: open `communication.svg` in a browser, or the architecture guide in an editor's preview.
4. Update the table under the diagram in `docs/architecture.md` when an arrow or a box changed.
