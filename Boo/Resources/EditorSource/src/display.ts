// Display options CodeMirror has no built-in for: rulers, Monaco-style
// whitespace rendering modes, and block/underline cursors.

import { type Extension, RangeSetBuilder } from "@codemirror/state";
import {
  Decoration,
  type DecorationSet,
  EditorView,
  type LayerMarker,
  RectangleMarker,
  ViewPlugin,
  type ViewUpdate,
  layer,
} from "@codemirror/view";

// MARK: - Rulers

function rulerMarkers(view: EditorView, columns: number[]): readonly LayerMarker[] {
  const line = view.contentDOM.querySelector(".cm-line");
  const padding = line ? parseFloat(getComputedStyle(line).paddingLeft) || 0 : 0;
  const scroller = view.scrollDOM.getBoundingClientRect();
  const content = view.contentDOM.getBoundingClientRect();
  const left = content.left - scroller.left + view.scrollDOM.scrollLeft + padding;
  const top = content.top - scroller.top + view.scrollDOM.scrollTop;
  const height = Math.max(view.contentHeight, view.scrollDOM.clientHeight);
  return columns.map(
    (column) =>
      new RectangleMarker(
        "cm-ruler",
        left + column * view.defaultCharacterWidth,
        top,
        null,
        height,
      ),
  );
}

export function rulers(columns: number[]): Extension {
  const valid = columns.filter((c) => Number.isFinite(c) && c > 0);
  if (valid.length === 0) return [];
  return [
    layer({
      above: false,
      class: "cm-rulerLayer",
      markers: (view) => rulerMarkers(view, valid),
      update: (update) => update.geometryChanged || update.viewportChanged,
    }),
    EditorView.theme({
      ".cm-ruler": {
        width: "0",
        borderLeft: "1px solid color-mix(in srgb, var(--boo-fg) 15%, transparent)",
      },
    }),
  ];
}

// MARK: - Whitespace

export type WhitespaceMode = "none" | "boundary" | "selection" | "trailing" | "all";

const spaceMark = Decoration.mark({ class: "cm-ws-space" });
const tabMark = Decoration.mark({ class: "cm-ws-tab" });

function whitespaceDecorations(view: EditorView, mode: WhitespaceMode): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  const selection = view.state.selection.ranges.filter((r) => !r.empty);
  if (mode === "selection" && selection.length === 0) return Decoration.none;

  const add = (from: number, to: number, text: string) => {
    for (let i = 0; i < text.length; i++) {
      const pos = from + i;
      if (pos >= to) break;
      builder.add(pos, pos + 1, text[i] === "\t" ? tabMark : spaceMark);
    }
  };

  for (const { from, to } of view.visibleRanges) {
    let pos = from;
    while (pos <= to) {
      const line = view.state.doc.lineAt(pos);
      const text = line.text;
      const pattern = /[ \t]+/g;
      let match: RegExpExecArray | null;
      while ((match = pattern.exec(text))) {
        const start = line.from + match.index;
        const end = start + match[0].length;
        const trailing = match.index + match[0].length === text.length;
        if (mode === "trailing" && !trailing) continue;
        if (mode === "boundary") {
          const leading = match.index === 0;
          const single = match[0] === " ";
          if (single && !leading && !trailing) continue;
        }
        if (mode === "selection") {
          for (const range of selection) {
            const a = Math.max(start, range.from);
            const b = Math.min(end, range.to);
            if (a < b) add(a, b, text.slice(a - line.from, b - line.from));
          }
          continue;
        }
        add(start, end, match[0]);
      }
      pos = line.to + 1;
    }
  }
  return builder.finish();
}

export function renderWhitespace(mode: WhitespaceMode): Extension {
  if (mode === "none") return [];
  const plugin = ViewPlugin.fromClass(
    class {
      decorations: DecorationSet;
      constructor(view: EditorView) {
        this.decorations = whitespaceDecorations(view, mode);
      }
      update(update: ViewUpdate) {
        if (
          update.docChanged ||
          update.viewportChanged ||
          (mode === "selection" && update.selectionSet)
        ) {
          this.decorations = whitespaceDecorations(update.view, mode);
        }
      }
    },
    { decorations: (v) => v.decorations },
  );
  return [
    plugin,
    EditorView.theme({
      ".cm-ws-space": {
        backgroundImage:
          "radial-gradient(circle at 50% 55%, color-mix(in srgb, var(--boo-fg) 35%, transparent) 15%, transparent 20%)",
        backgroundPosition: "center",
        backgroundRepeat: "no-repeat",
      },
      ".cm-ws-tab": { position: "relative" },
      ".cm-ws-tab::before": {
        content: '"→"',
        position: "absolute",
        left: "0",
        color: "color-mix(in srgb, var(--boo-fg) 35%, transparent)",
        pointerEvents: "none",
      },
    }),
  ];
}

// MARK: - Cursor and ligatures

export function cursorStyle(style: "line" | "block" | "underline"): Extension {
  if (style === "block") {
    return EditorView.theme({
      ".cm-cursor": {
        borderLeft: "none",
        width: "1ch",
        backgroundColor: "var(--boo-accent)",
        opacity: "0.6",
      },
    });
  }
  if (style === "underline") {
    return EditorView.theme({
      ".cm-cursor": {
        borderLeft: "none",
        width: "1ch",
        borderBottom: "2px solid var(--boo-accent)",
        boxSizing: "border-box",
      },
    });
  }
  return [];
}

export function ligatures(enabled: boolean): Extension {
  return EditorView.theme({
    ".cm-content": enabled
      ? { fontVariantLigatures: "normal", fontFeatureSettings: '"liga" 1, "calt" 1' }
      : { fontVariantLigatures: "none", fontFeatureSettings: '"liga" 0, "calt" 0' },
  });
}
