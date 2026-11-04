// Editor add-ons that Monaco ships and CodeMirror does not: minimap, sticky
// scroll headers, and bracket pair colorization.

import { foldNodeProp, highlightingFor, syntaxTree } from "@codemirror/language";
import { type EditorState, type Extension, RangeSetBuilder } from "@codemirror/state";
import {
  Decoration,
  type DecorationSet,
  EditorView,
  ViewPlugin,
  type ViewUpdate,
} from "@codemirror/view";
import { NodeProp, type SyntaxNode } from "@lezer/common";
import { highlightTree } from "@lezer/highlight";
import { showMinimap } from "@replit/codemirror-minimap";

// MARK: - Minimap

export function minimap(): Extension {
  return showMinimap.of({
    create: () => {
      const dom = document.createElement("div");
      dom.className = "boo-minimap";
      return { dom };
    },
    displayText: "characters",
    showOverlay: "mouse-over",
  });
}

// MARK: - Sticky scroll

const MAX_STICKY_LINES = 5;

/** Start lines of the syntax nodes that enclose `line` but begin above it. */
function enclosingHeaders(state: EditorState, lineNumber: number): number[] {
  const line = state.doc.line(lineNumber);
  const headers = new Set<number>();
  let node: SyntaxNode | null = syntaxTree(state).resolveInner(line.from, 1);
  for (; node; node = node.parent) {
    if (!node.type.prop(foldNodeProp)) continue;
    const start = state.doc.lineAt(node.from).number;
    const end = state.doc.lineAt(node.to).number;
    if (start < lineNumber && end > lineNumber) headers.add(start);
  }
  return [...headers].sort((a, b) => a - b).slice(-MAX_STICKY_LINES);
}

type GutterLayout = { width: number; numbersEnd: number };

function renderLine(view: EditorView, lineNumber: number, gutter: GutterLayout): HTMLElement {
  const { state } = view;
  const line = state.doc.line(lineNumber);
  const row = document.createElement("div");
  row.className = "boo-sticky-row";
  row.dataset.line = String(lineNumber);
  const number = document.createElement("span");
  number.className = "boo-sticky-number";
  number.style.width = `${gutter.numbersEnd}px`;
  number.style.marginRight = `${gutter.width - gutter.numbersEnd}px`;
  if (gutter.numbersEnd > 0) number.textContent = String(lineNumber);
  const dom = document.createElement("div");
  dom.className = "cm-line boo-sticky-line";
  row.append(number, dom);
  let pos = line.from;
  const put = (from: number, to: number, cls: string) => {
    if (from > pos) dom.append(state.sliceDoc(pos, from));
    const span = document.createElement("span");
    span.className = cls;
    span.textContent = state.sliceDoc(from, to);
    dom.append(span);
    pos = to;
  };
  highlightTree(
    syntaxTree(state),
    { style: (tags) => highlightingFor(state, tags) },
    put,
    line.from,
    line.to,
  );
  if (pos < line.to) dom.append(state.sliceDoc(pos, line.to));
  if (!dom.textContent) dom.append(document.createElement("br"));
  return row;
}

const stickyPlugin = ViewPlugin.fromClass(
  class {
    dom: HTMLElement;
    shown = "";

    constructor(readonly view: EditorView) {
      this.dom = document.createElement("div");
      this.dom.className = "boo-sticky";
      this.dom.setAttribute("aria-hidden", "true");
      this.dom.addEventListener("mousedown", (event) => {
        const target = (event.target as HTMLElement).closest<HTMLElement>("[data-line]");
        if (!target) return;
        event.preventDefault();
        const line = view.state.doc.line(Number(target.dataset.line));
        view.dispatch({
          selection: { anchor: line.from },
          effects: EditorView.scrollIntoView(line.from, { y: "start" }),
        });
        view.focus();
      });
      view.dom.appendChild(this.dom);
      this.onScroll = this.onScroll.bind(this);
      view.scrollDOM.addEventListener("scroll", this.onScroll);
      this.schedule();
    }

    onScroll() {
      this.schedule();
    }

    update(update: ViewUpdate) {
      if (update.docChanged || update.geometryChanged || update.viewportChanged) this.schedule();
    }

    schedule() {
      this.view.requestMeasure({
        key: this,
        read: (view) => {
          const scrollTop = view.scrollDOM.scrollTop;
          if (scrollTop <= 0) return [] as number[];
          const lineHeight = view.defaultLineHeight;
          // Re-resolve once with the header block's height so the line under the
          // headers decides what they show, like Monaco.
          let top = view.lineBlockAtHeight(scrollTop).from;
          let headers = enclosingHeaders(view.state, view.state.doc.lineAt(top).number);
          top = view.lineBlockAtHeight(scrollTop + headers.length * lineHeight).from;
          headers = enclosingHeaders(view.state, view.state.doc.lineAt(top).number);
          return headers;
        },
        write: (headers, view) => this.render(view, headers),
      });
    }

    render(view: EditorView, headers: number[]) {
      const key = headers.join(",") + ":" + view.state.doc.length;
      if (key === this.shown) return;
      this.shown = key;
      // Line number gutters sit left of the content; the minimap gutter sits right.
      const gutters = view.dom.querySelector<HTMLElement>(".cm-gutters:not(.cm-minimap-gutter)");
      const minimap = view.dom.querySelector<HTMLElement>(".cm-minimap-gutter");
      const numbers = gutters?.querySelector<HTMLElement>(".cm-lineNumbers");
      const gutter = {
        width: gutters ? gutters.offsetWidth : 0,
        numbersEnd: numbers ? numbers.offsetLeft + numbers.offsetWidth : 0,
      };
      this.dom.replaceChildren(...headers.map((n) => renderLine(view, n, gutter)));
      this.dom.style.display = headers.length ? "block" : "none";
      this.dom.style.right = `${minimap ? minimap.offsetWidth : 0}px`;
      // The header sits outside the scroller, which carries the font settings.
      const font = getComputedStyle(view.scrollDOM);
      this.dom.style.fontFamily = font.fontFamily;
      this.dom.style.fontSize = font.fontSize;
      this.dom.style.lineHeight = font.lineHeight;
    }

    destroy() {
      this.view.scrollDOM.removeEventListener("scroll", this.onScroll);
      this.dom.remove();
    }
  },
);

export function stickyScroll(): Extension {
  return [
    stickyPlugin,
    EditorView.theme({
      ".boo-sticky": {
        position: "absolute",
        top: "0",
        left: "0",
        zIndex: "250",
        display: "none",
        backgroundColor: "var(--boo-bg)",
        borderBottom: "1px solid var(--boo-border)",
        boxShadow: "0 2px 4px color-mix(in srgb, black 25%, transparent)",
        cursor: "pointer",
      },
      ".boo-sticky-row": { display: "flex" },
      ".boo-sticky-row:hover": {
        backgroundColor: "color-mix(in srgb, var(--boo-fg) 8%, transparent)",
      },
      ".boo-sticky-number": {
        flex: "none",
        boxSizing: "border-box",
        padding: "0 3px 0 5px",
        textAlign: "right",
        color: "color-mix(in srgb, var(--boo-fg) 45%, transparent)",
      },
      ".boo-sticky-line": {
        flex: "1",
        minWidth: "0",
        whiteSpace: "pre",
        overflow: "hidden",
        textOverflow: "ellipsis",
      },
    }),
  ];
}

// MARK: - Bracket pair colorization

const DARK_COLORS = ["#ffd700", "#da70d6", "#179fff"];
const LIGHT_COLORS = ["#0431fa", "#319331", "#7b3814"];
const bracketMarks = DARK_COLORS.map((_, i) => Decoration.mark({ class: `cm-bracket-${i}` }));
const BRACKETS = new Set(["(", ")", "[", "]", "{", "}"]);

/**
 * Colors brackets by nesting depth. The depth is counted while walking down the
 * tree: a node is bracketed when its first child is an opening bracket.
 */
function bracketDecorations(view: EditorView): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  const tree = syntaxTree(view.state);
  for (const { from, to } of view.visibleRanges) {
    // One entry per open node: whether it is bracketed.
    const stack: boolean[] = [];
    let depth = 0;
    tree.iterate({
      from,
      to,
      enter: (ref) => {
        stack.push(false);
        if (!BRACKETS.has(ref.name) || ref.to - ref.from !== 1) return;
        if (ref.type.prop(NodeProp.closedBy) && !ref.node.prevSibling && stack.length > 1) {
          stack[stack.length - 2] = true;
          depth++;
        }
        if (depth === 0) return;
        builder.add(ref.from, ref.to, bracketMarks[(depth - 1) % bracketMarks.length]);
      },
      leave: () => {
        if (stack.pop()) depth--;
      },
    });
  }
  return builder.finish();
}

const bracketPlugin = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;
    constructor(view: EditorView) {
      this.decorations = bracketDecorations(view);
    }
    update(update: ViewUpdate) {
      if (
        update.docChanged ||
        update.viewportChanged ||
        syntaxTree(update.startState) !== syntaxTree(update.state)
      ) {
        this.decorations = bracketDecorations(update.view);
      }
    }
  },
  { decorations: (v) => v.decorations },
);

export function bracketPairColors(): Extension {
  const rules: Record<string, Record<string, string>> = {};
  DARK_COLORS.forEach((color, i) => {
    rules[`&dark .cm-bracket-${i}, &dark .cm-bracket-${i} *`] = { color };
    rules[`&light .cm-bracket-${i}, &light .cm-bracket-${i} *`] = { color: LIGHT_COLORS[i] };
  });
  return [bracketPlugin, EditorView.baseTheme(rules)];
}
