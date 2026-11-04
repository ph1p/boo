// Maps Boo's editor settings onto CodeMirror extensions. The result goes into
// one compartment, so a settings change reconfigures the running editor.

import { codeFolding, foldGutter } from "@codemirror/language";
import { lintGutter } from "@codemirror/lint";
import type { Extension } from "@codemirror/state";
import {
  EditorView,
  drawSelection,
  highlightActiveLineGutter,
  lineNumbers,
  placeholder,
} from "@codemirror/view";
import { bracketPairColors, minimap, stickyScroll } from "./addons";
import type { EditorOptions } from "./bridge";
import { cursorStyle, ligatures, renderWhitespace, rulers } from "./display";

export type ResolvedOptions = Required<Omit<EditorOptions, "placeholder">> & {
  placeholder?: string;
};

export function resolveOptions(options?: EditorOptions): ResolvedOptions {
  return {
    fontFamily: options?.fontFamily ?? "SF Mono",
    fontSize: options?.fontSize ?? 13,
    lineHeight: options?.lineHeight ?? 20,
    tabSize: options?.tabSize ?? 4,
    insertSpaces: options?.insertSpaces ?? true,
    detectIndentation: options?.detectIndentation ?? true,
    wordWrap: options?.wordWrap ?? "off",
    lineNumbers: options?.lineNumbers ?? "on",
    minimap: options?.minimap ?? false,
    rulers: options?.rulers ?? [],
    renderWhitespace: options?.renderWhitespace ?? "selection",
    bracketPairColors: options?.bracketPairColors ?? true,
    stickyScroll: options?.stickyScroll ?? false,
    fontLigatures: options?.fontLigatures ?? false,
    cursorStyle: options?.cursorStyle ?? "line",
    cursorBlinking: options?.cursorBlinking ?? true,
    statusStrip: options?.statusStrip ?? false,
    placeholder: options?.placeholder,
    folding: options?.folding ?? true,
    glyphMargin: options?.glyphMargin ?? true,
  };
}

function quoteFont(name: string): string {
  return /^[\w-]+$/.test(name) ? name : `"${name.replace(/"/g, "")}"`;
}

export function optionsExtension(o: ResolvedOptions): Extension {
  const extensions: Extension[] = [
    EditorView.theme({
      ".cm-scroller": {
        fontFamily: `${quoteFont(o.fontFamily)}, "SF Mono", Menlo, monospace`,
        fontSize: `${o.fontSize}px`,
        lineHeight: `${o.lineHeight}px`,
      },
    }),
    drawSelection({ cursorBlinkRate: o.cursorBlinking ? 1200 : 0 }),
    cursorStyle(o.cursorStyle),
    ligatures(o.fontLigatures),
    renderWhitespace(o.renderWhitespace),
    rulers(o.rulers),
  ];
  if (o.wordWrap === "on") extensions.push(EditorView.lineWrapping);
  // Monaco's glyph margin holds diagnostics markers; the lint gutter is the closest match.
  if (o.glyphMargin) extensions.push(lintGutter());
  if (o.lineNumbers === "on") extensions.push(lineNumbers(), highlightActiveLineGutter());
  if (o.folding) {
    extensions.push(
      codeFolding(),
      foldGutter({ openText: "⌄", closedText: "›" }),
      EditorView.theme({
        ".cm-foldGutter .cm-gutterElement": { padding: "0 4px", cursor: "pointer", opacity: "0.7" },
      }),
    );
  }
  if (o.minimap) extensions.push(minimap());
  if (o.stickyScroll) extensions.push(stickyScroll());
  if (o.bracketPairColors) extensions.push(bracketPairColors());
  if (o.placeholder) extensions.push(placeholder(o.placeholder));
  return extensions;
}
