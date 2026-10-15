# message-bridge.svg

The diagram under "The message bridge" in the architecture guide: how a message from the UI reaches the backend through the native app and how its message response comes back.

## How it is made

It is made the same way as `communication.svg` (see `communication.md`): `message-bridge.mmd` is the Mermaid source, with a `label-under` line for the text under each box, and `bun run diagrams` draws `message-bridge.svg` from it. Never edit `message-bridge.svg` itself: the next `bun run diagrams` replaces it.

## Changing it

1. Edit `message-bridge.mmd`, keeping the names of boxes and the words on arrows short.
2. Run `bun run diagrams` from the root of the repository.
3. Look at the drawing: open `message-bridge.svg` in a browser, or the architecture guide in an editor's preview.
4. Update "The message bridge" in `docs/development/architecture.md` when an arrow or a box changed.
