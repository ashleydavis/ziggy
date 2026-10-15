# render-diagrams.sh

Draws every Mermaid diagram under `docs/diagrams` (each `.mmd` file) into the SVG beside it, with a white background, then runs `add-diagram-labels.ts` on it to add the `label-under` lines Mermaid cannot place itself.

Run it from the root of the repository as `bun run diagrams`. No arguments.

It draws with the Mermaid command line tool (`@mermaid-js/mermaid-cli`, at the version the script pins, fetched by `bunx`), which runs a headless Chrome or Chromium: the one `PUPPETEER_EXECUTABLE_PATH` names, else the first of `google-chrome`, `chromium` and `chromium-browser` on the PATH. It stops when there is none.

## add-diagram-labels.ts

`bun scripts/add-diagram-labels.ts <diagram.mmd> <diagram.svg>`

- `<diagram.mmd>`: the diagram's source. Each line `%% label-under: <box id> = <text>` names a box by its id in the source and the text to put under it.
- `<diagram.svg>`: the SVG Mermaid drew from that source, which it rewrites in place.

It puts each label in the box's own group, just under the box, and makes the drawing taller, and wider on each side by about as much as the widest label sticks out past its box, so no label is cut off. It fails, naming the box, when a `label-under` line names a box the diagram does not have.

## See also

- [communication.md](../docs/diagrams/communication.md): the diagram this draws, and how to change it.
