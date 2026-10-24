# task-queue.svg

The diagram under "Tasks" in the architecture guide: how the frontend queues a task with `window.ziggy.addTask`, how a worker thread runs it and reports with `task-event` and `task-completed` events, and how `window.ziggy.cancelTasks` stops it. The native app carries every message and event, as `message-bridge.svg` shows, and is left out.

## A parent waiting on its children

The task queue lives on the main thread, which starts each task on a free worker. A task that waits on its child tasks keeps its worker while it waits, as in TypeScript. If every worker holds a waiting parent, no worker is free for the children they wait on, and the queue stops.

- TypeScript frees a worker when its task runs past the pool's task timeout: the pool fails the task and ends the worker.
- Ziggy cannot end a thread from outside it, so it has no task timeout. The queue stays stopped until those parents are cancelled or the app stops.
- This is not a problem in practice, and it may have to be addressed later.

## How it is made

It is made the same way as `communication.svg` (see `communication.md`): `task-queue.mmd` is the Mermaid source, with a `label-under` line for the text under each box, and `bun run diagrams` draws `task-queue.svg` from it. Never edit `task-queue.svg` itself: the next `bun run diagrams` replaces it.

## Changing it

1. Edit `task-queue.mmd`, keeping the names of boxes and the words on arrows short.
2. Run `bun run diagrams` from the root of the repository.
3. Look at the drawing: open `task-queue.svg` in a browser, or the architecture guide in an editor's preview.
4. Update "Tasks" in `docs/development/architecture.md` when an arrow or a box changed.
