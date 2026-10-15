//
// Adds the "label-under" lines of a Mermaid diagram's source to the SVG Mermaid drew from it: each puts a line of small grey
// text under one box, which Mermaid itself cannot place. The SVG is rewritten in place, and the drawing is made taller so the
// labels under the lowest box are not cut off. See render-diagrams.md.
//
// Usage: bun scripts/add-diagram-labels.ts <diagram.mmd> <diagram.svg>
//
//   <diagram.mmd>  The diagram's Mermaid source. Each line "%% label-under: <box id> = <text>" names a box by the id it has in
//                  the source and the text to put under it.
//   <diagram.svg>  The SVG Mermaid drew from that source, which this rewrites.
//

import { readFileSync, writeFileSync } from "fs";

//
// One line of text to put under a box.
//
interface ILabelUnder {
    // The id the box has in the Mermaid source, such as "UI".
    boxId: string;

    // The text to put under it.
    text: string;
}

//
// How far below a box's bottom edge the label's baseline goes, in the SVG's units.
//
const labelGap = 16;

//
// Reads every "label-under" line of a diagram's Mermaid source.
//
function readLabels(source: string): ILabelUnder[] {
    const labels: ILabelUnder[] = [];
    for (const line of source.split("\n")) {
        const match = /^%% label-under: (\S+) = (.+)$/.exec(line.trim());
        if (match) {
            labels.push({
                boxId: match[1],
                text: match[2].trim(),
            });
        }
    }
    return labels;
}

//
// Makes text safe to put inside an SVG element.
//
function escapeXml(text: string): string {
    return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

//
// What adding one label did: the SVG with the label in it, and how far the label sticks out past each side of its box.
//
interface IAddedLabel {
    // The SVG with the label added.
    svg: string;

    // How far the label reaches past each side of its box, in the SVG's units, or 0 when it is narrower than the box.
    overhang: number;
}

//
// About how wide one character of a label is, in the SVG's units, at the labels' font size. Used to work out how far a label
// sticks out past its box, because an SVG file cannot be measured without drawing it.
//
const characterWidth = 7;

//
// Puts one label under its box: a text element inside the box's own group, so it moves with the box, just below its edge.
// Fails, naming the box, when the SVG has no such box.
//
function addLabel(svg: string, label: ILabelUnder): IAddedLabel {
    const boxPattern = new RegExp(`<g class="node[^"]*" id="[^"]*-flowchart-${label.boxId}-\\d+"[^>]*>`);
    const boxMatch = boxPattern.exec(svg);
    if (!boxMatch) {
        throw new Error(`The diagram has no box with the id ${label.boxId}, which a label-under line names.`);
    }
    const afterBox = svg.slice(boxMatch.index + boxMatch[0].length);
    const rectangleMatch = /<rect class="basic label-container"[^>]*width="([0-9.]+)" height="([0-9.]+)"/.exec(afterBox);
    if (!rectangleMatch) {
        throw new Error(`The box ${label.boxId} has no rectangle to measure.`);
    }
    const boxWidth = Number(rectangleMatch[1]);
    const labelY = Number(rectangleMatch[2]) / 2 + labelGap;
    const labelElement = `<text x="0" y="${labelY}" text-anchor="middle" style="font-family: 'trebuchet ms', verdana, arial, sans-serif; font-size: 12px; fill: #444444;">${escapeXml(label.text)}</text>`;
    const insertAt = boxMatch.index + boxMatch[0].length;
    return {
        svg: svg.slice(0, insertAt) + labelElement + svg.slice(insertAt),
        overhang: Math.max(0, (label.text.length * characterWidth - boxWidth) / 2),
    };
}

//
// Makes the drawing taller by the room a label takes, so a label under the lowest box is not cut off, and wider on each side by
// the most any label sticks out past its box, so a label under the first or last box is not cut off either.
//
function makeRoomForLabels(svg: string, overhang: number): string {
    const resized = svg.replace(/(<svg[^>]*viewBox=")([0-9.\-]+) ([0-9.\-]+) ([0-9.]+) ([0-9.]+)(")/, (whole: string, start: string, minX: string, minY: string, width: string, height: string, end: string) => {
        return `${start}${Number(minX) - overhang} ${minY} ${Number(width) + 2 * overhang} ${Number(height) + labelGap + 8}${end}`;
    });
    return resized.replace(/(<svg[^>]*style="[^"]*max-width: )([0-9.]+)px/, (whole: string, start: string, maxWidth: string) => {
        return `${start}${Number(maxWidth) + 2 * overhang}px`;
    });
}

//
// Adds every label of the diagram's source to its SVG.
//
function main(): void {
    const [sourcePath, svgPath] = process.argv.slice(2);
    if (!sourcePath || !svgPath) {
        throw new Error("Usage: bun scripts/add-diagram-labels.ts <diagram.mmd> <diagram.svg>");
    }
    const labels = readLabels(readFileSync(sourcePath, "utf8"));
    let svg = readFileSync(svgPath, "utf8");
    let overhang = 0;
    for (const label of labels) {
        const added = addLabel(svg, label);
        svg = added.svg;
        overhang = Math.max(overhang, added.overhang);
    }
    if (labels.length > 0) {
        svg = makeRoomForLabels(svg, overhang);
    }
    writeFileSync(svgPath, svg);
}

main();
