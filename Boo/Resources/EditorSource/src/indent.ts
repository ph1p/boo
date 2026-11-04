// Indentation: detection from the file, the Tab key, and the state facets.

import { indentLess, indentMore } from "@codemirror/commands";
import { getIndentUnit, indentUnit } from "@codemirror/language";
import { EditorSelection, EditorState, type Extension, type Text } from "@codemirror/state";
import type { EditorView } from "@codemirror/view";

export type Indent = { insertSpaces: boolean; tabSize: number };

/** Guesses tabs or spaces and the width from the first lines, the way
 *  Monaco's detectIndentation did. Null when nothing is indented. */
export function detectIndent(doc: Text): Indent | null {
  let tabLines = 0;
  let spaceLines = 0;
  const deltas = new Map<number, number>();
  let previous = 0;
  const lines = Math.min(doc.lines, 10000);
  for (let n = 1; n <= lines; n++) {
    const text = doc.line(n).text;
    if (text.trim() === "") continue;
    if (text.startsWith("\t")) {
      tabLines++;
      previous = 0;
      continue;
    }
    const width = /^ */.exec(text)![0].length;
    if (width > 0) spaceLines++;
    const delta = Math.abs(width - previous);
    if (delta > 1 && delta <= 8) deltas.set(delta, (deltas.get(delta) ?? 0) + 1);
    previous = width;
  }
  if (tabLines === 0 && spaceLines === 0) return null;
  if (tabLines > spaceLines) return { insertSpaces: false, tabSize: 0 };
  let best = 0;
  let bestCount = 0;
  for (const [delta, count] of deltas) {
    if (count > bestCount || (count === bestCount && delta < best)) {
      best = delta;
      bestCount = count;
    }
  }
  return best ? { insertSpaces: true, tabSize: best } : null;
}

export function indentExtension(indent: Indent): Extension {
  return [
    EditorState.tabSize.of(indent.tabSize),
    indentUnit.of(indent.insertSpaces ? " ".repeat(indent.tabSize) : "\t"),
  ];
}

export function currentIndent(state: EditorState): Indent {
  return { insertSpaces: state.facet(indentUnit) !== "\t", tabSize: state.tabSize };
}

/** Tab with a selection indents the lines; at a cursor it inserts up to the
 *  next tab stop, as in Monaco. */
function insertIndent(view: EditorView): boolean {
  const { state } = view;
  if (state.readOnly) return false;
  if (state.selection.ranges.some((r) => !r.empty)) return indentMore(view);
  const unit = state.facet(indentUnit);
  const width = getIndentUnit(state);
  view.dispatch(
    state.changeByRange((range) => {
      let insert = "\t";
      if (unit !== "\t") {
        const line = state.doc.lineAt(range.head);
        let column = 0;
        for (const ch of line.text.slice(0, range.head - line.from)) {
          column = ch === "\t" ? column + state.tabSize - (column % state.tabSize) : column + 1;
        }
        insert = " ".repeat(width - (column % width));
      }
      return {
        changes: { from: range.head, insert },
        range: EditorSelection.cursor(range.head + insert.length),
      };
    }),
    { userEvent: "input.indent", scrollIntoView: true },
  );
  return true;
}

export const tabBinding = { key: "Tab", run: insertIndent, shift: indentLess };
