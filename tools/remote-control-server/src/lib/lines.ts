//
// Cuts the text a test script writes on its TCP connection into whole lines. TCP delivers bytes in chunks that need not end at
// a line's end, so the unfinished end of one chunk is kept and joined to the start of the next.
//

import assert from "node:assert";

//
// The whole lines a chunk completed, and the unfinished text after the last of them.
//
export interface ISplitLines {
    //
    // Each complete line, without its newline, in the order they were written.
    //
    lines: string[];

    //
    // The text after the last newline, which the next chunk continues.
    //
    rest: string;
}

//
// Joins the chunk to the text left over from the chunks before it and cuts the whole into lines.
//
export function splitLines(rest: string, chunk: string): ISplitLines {
    const pieces = (rest + chunk).split("\n");
    const unfinished = pieces.pop();
    assert(unfinished !== undefined, "split always gives at least one piece");
    assert(!unfinished.includes("\n"), "the unfinished text holds no newline");
    return {
        lines: pieces,
        rest: unfinished,
    };
}
