// The editor theme, derived from Boo's app theme (see buildEditorTheme in
// EditorContentView.swift): editor chrome colors plus a syntax palette.

import { HighlightStyle, syntaxHighlighting } from "@codemirror/language";
import type { Extension } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { tags as t } from "@lezer/highlight";

export type ThemeData = {
  dark: boolean;
  background: string;
  foreground: string;
  cursor: string;
  selection: string;
  lineHighlight: string;
  border: string;
  syntax: {
    comment: string;
    keyword: string;
    string: string;
    number: string;
    type: string;
    function: string;
    tag: string;
    invalid: string;
  };
};

const fallback: ThemeData = {
  dark: true,
  background: "#1e1e1e",
  foreground: "#d4d4d4",
  cursor: "#aeafad",
  selection: "#264f78",
  lineHighlight: "#2a2a2a",
  border: "#3c3c3c",
  syntax: {
    comment: "#6a9955",
    keyword: "#c586c0",
    string: "#ce9178",
    number: "#b5cea8",
    type: "#4ec9b0",
    function: "#dcdcaa",
    tag: "#569cd6",
    invalid: "#f44747",
  },
};

/** Mirrors the editor colors onto the banner and status strip. */
function applyChromeColors(theme: ThemeData): void {
  const style = document.documentElement.style;
  style.setProperty("--boo-bg", theme.background);
  style.setProperty("--boo-fg", theme.foreground);
  style.setProperty("--boo-border", theme.border);
  style.setProperty("--boo-accent", theme.cursor);
  style.setProperty("--boo-selection", theme.selection);
  style.colorScheme = theme.dark ? "dark" : "light";
}

const mix = (color: string, percent: number, over = "transparent") =>
  `color-mix(in srgb, ${color} ${percent}%, ${over})`;

export function themeExtension(data?: ThemeData): Extension {
  const c = data ?? fallback;
  applyChromeColors(c);
  const s = c.syntax;
  const muted = mix(c.foreground, 45);
  const panel = mix(c.foreground, 6, c.background);

  const editorTheme = EditorView.theme(
    {
      "&": { color: c.foreground, backgroundColor: c.background },
      ".cm-content": { caretColor: c.cursor },
      ".cm-cursor, .cm-dropCursor": { borderLeftColor: c.cursor },
      "&.cm-focused > .cm-scroller > .cm-selectionLayer .cm-selectionBackground, .cm-selectionBackground":
        { backgroundColor: c.selection },
      ".cm-content ::selection": { backgroundColor: c.selection },
      ".cm-activeLine": { backgroundColor: c.lineHighlight },
      ".cm-gutters": { backgroundColor: c.background, color: muted, border: "none" },
      ".cm-activeLineGutter": { backgroundColor: "transparent", color: c.foreground },
      ".cm-foldPlaceholder": {
        backgroundColor: panel,
        border: `1px solid ${c.border}`,
        color: muted,
      },
      ".cm-searchMatch": {
        backgroundColor: mix(s.number, 30),
        outline: `1px solid ${mix(s.number, 60)}`,
      },
      ".cm-searchMatch.cm-searchMatch-selected": { backgroundColor: mix(s.number, 55) },
      ".cm-selectionMatch": { backgroundColor: mix(c.selection, 55) },
      "&.cm-focused .cm-matchingBracket": {
        backgroundColor: mix(c.foreground, 12),
        outline: `1px solid ${mix(c.foreground, 35)}`,
      },
      "&.cm-focused .cm-nonmatchingBracket": { color: s.invalid },
      ".cm-panels": { backgroundColor: panel, color: c.foreground },
      ".cm-panels.cm-panels-top": { borderBottom: `1px solid ${c.border}` },
      ".cm-panels.cm-panels-bottom": { borderTop: `1px solid ${c.border}` },
      ".cm-tooltip": {
        backgroundColor: panel,
        color: c.foreground,
        border: `1px solid ${c.border}`,
        borderRadius: "4px",
      },
      ".cm-tooltip-autocomplete > ul > li[aria-selected]": {
        backgroundColor: c.selection,
        color: c.foreground,
      },
      ".cm-placeholder": { color: muted },
    },
    { dark: c.dark },
  );

  const highlight = HighlightStyle.define(
    [
      {
        tag: [t.comment, t.lineComment, t.blockComment, t.docComment],
        color: s.comment,
        fontStyle: "italic",
      },
      {
        tag: [
          t.keyword,
          t.controlKeyword,
          t.definitionKeyword,
          t.moduleKeyword,
          t.operatorKeyword,
          t.modifier,
          t.self,
        ],
        color: s.keyword,
        fontWeight: "bold",
      },
      {
        tag: [t.string, t.special(t.string), t.character, t.attributeValue, t.docString],
        color: s.string,
      },
      { tag: [t.regexp, t.escape], color: s.invalid },
      {
        tag: [t.number, t.integer, t.float, t.bool, t.null, t.atom, t.unit, t.color],
        color: s.number,
      },
      {
        tag: [t.typeName, t.className, t.namespace, t.standard(t.typeName), t.attributeName],
        color: s.type,
      },
      {
        tag: [t.function(t.variableName), t.function(t.propertyName), t.macroName, t.labelName],
        color: s.function,
      },
      { tag: [t.tagName, t.angleBracket], color: s.tag },
      { tag: [t.meta, t.processingInstruction, t.annotation], color: muted },
      { tag: t.heading, color: s.keyword, fontWeight: "bold" },
      { tag: t.strong, fontWeight: "bold" },
      { tag: t.emphasis, fontStyle: "italic" },
      { tag: t.strikethrough, textDecoration: "line-through" },
      { tag: [t.link, t.url], color: s.function, textDecoration: "underline" },
      { tag: t.monospace, color: s.string },
      { tag: [t.inserted], color: s.string },
      { tag: [t.deleted], color: s.invalid },
      { tag: [t.changed], color: s.number },
      { tag: t.invalid, color: s.invalid },
    ],
    { themeType: c.dark ? "dark" : "light" },
  );

  return [editorTheme, syntaxHighlighting(highlight)];
}
