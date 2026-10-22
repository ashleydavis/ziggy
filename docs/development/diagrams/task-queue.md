# task-queue.svg

The diagram under "Tasks" in the architecture guide: how the frontend queues a task with `window.ziggy.addTask`, how a worker thread runs it and reports with `task-event` and `task-completed` events, and how `window.ziggy.cancelTasks` stops it. The native app carries every message and event, as `message-bridge.svg` shows, and is left out.

## How it is made

It is made the same way as `communication.svg` (see `communication.md`): `task-queue.mmd` is the Mermaid source, with a `label-under` line for the text under each box, and `bun run diagrams` draws `task-queue.svg` from it. Never edit `task-queue.svg` itself: the next `bun run diagrams` replaces it.

## Changing it

1. Edit `task-queue.mmd`, keeping the names of boxes and the words on arrows short.
2. Run `bun run diagrams` from the root of the repository.
3. Look at the drawing: open `task-queue.svg` in a browser, or the architecture guide in an editor's preview.
4. Update "Tasks" in `docs/development/architecture.md` when an arrow or a box changed.
