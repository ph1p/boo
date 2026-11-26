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
  /** Boo chrome tokens (CSS colors), shared with the native find bar. */
  chrome?: ChromeTokens;
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
      ...searchPanelTheme(c, chromeTokens(c)),
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

export type ChromeTokens = {
  text: string;
  textSecondary: string;
  textTertiary: string;
  separator: string;
  hoverFill: string;
  controlFill: string;
  focusRing: string;
  error: string;
};

/** Tokens from the app, or the same recipe (Theme.swift) from the editor colors. */
function chromeTokens(c: ThemeData): ChromeTokens {
  if (c.chrome) return c.chrome;
  return {
    text: c.foreground,
    textSecondary: mix(c.foreground, 70),
    textTertiary: mix(c.foreground, 50),
    separator: mix(c.foreground, 20),
    hoverFill: mix(c.foreground, 10),
    controlFill: mix(c.foreground, 15),
    focusRing: mix(c.cursor, 70),
    error: c.syntax.invalid,
  };
}

/**
 * Styles for the find/replace panel in searchPanel.ts. Sizes and colors follow
 * FindBarView.swift: 32px bar, 22px controls, 6px radius, hairline strokes.
 */
function searchPanelTheme(c: ThemeData, t: ChromeTokens): Record<string, Record<string, string>> {
  const hairline = `0.5px solid ${t.separator}`;
  return {
    ".cm-panels-top:has(> .boo-search)": { borderBottom: hairline },
    ".cm-panel.boo-search": {
      display: "grid",
      gridTemplateColumns: "minmax(0, 1fr) auto auto",
      alignItems: "center",
      columnGap: "8px",
      rowGap: "5px",
      padding: "5px 10px",
      backgroundColor: c.background,
      color: t.text,
      fontFamily: "system-ui, -apple-system, sans-serif",
      fontSize: "13px",
    },
    ".boo-search.collapsed .boo-search-replace": { display: "none" },
    ":where(.boo-search button)": {
      margin: "0",
      padding: "0",
      border: "none",
      background: "transparent",
      color: "inherit",
      font: "inherit",
      cursor: "default",
    },
    ".boo-search button[hidden]": { display: "none" },

    // Field: controlFill surface, hairline edge, accent stroke on focus.
    ".boo-search-field": {
      display: "flex",
      alignItems: "center",
      gap: "2px",
      minWidth: "0",
      height: "22px",
      padding: "0 3px 0 7px",
      boxSizing: "border-box",
      backgroundColor: t.controlFill,
      border: hairline,
      borderRadius: "6px",
    },
    ".boo-search-field:focus-within": { border: `1px solid ${t.focusRing}`, paddingLeft: "6.5px" },
    ".boo-search-field.error": { border: `1px solid ${t.error}`, paddingLeft: "6.5px" },
    ".boo-search-glyph": {
      display: "inline-flex",
      flexShrink: "0",
      width: "14px",
      justifyContent: "center",
      color: t.textSecondary,
    },
    ".boo-search-input": {
      flex: "1",
      minWidth: "0",
      height: "100%",
      padding: "0 0 0 4px",
      border: "none",
      outline: "none",
      background: "transparent",
      color: t.text,
      caretColor: c.cursor,
      font: "inherit",
    },
    ".boo-search-input::placeholder": { color: t.textTertiary },
    ".boo-search-input::selection": { backgroundColor: c.selection },
    ".boo-search-count": {
      flexShrink: "0",
      padding: "0 4px",
      color: t.textSecondary,
      fontSize: "11px",
      fontVariantNumeric: "tabular-nums",
      whiteSpace: "nowrap",
    },
    ".boo-search-field.error .boo-search-count": { color: t.error },
    ".boo-search-clear": {
      display: "inline-flex",
      alignItems: "center",
      justifyContent: "center",
      width: "16px",
      height: "16px",
      color: `${t.textTertiary}`,
      "--boo-search-clear-x": c.background,
    },
    ".boo-search-clear:hover": { color: `${t.textSecondary}` },
    ".boo-search-sep": {
      flexShrink: "0",
      width: "1px",
      height: "12px",
      margin: "0 3px",
      backgroundColor: t.separator,
    },
    ".boo-search-toggle": {
      display: "inline-flex",
      alignItems: "center",
      justifyContent: "center",
      flexShrink: "0",
      width: "20px",
      height: "16px",
      borderRadius: "4px",
      color: `${t.textTertiary}`,
      fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
      fontSize: "11px",
    },
    ".boo-search-word": { textDecoration: "underline", textUnderlineOffset: "2px" },
    ".boo-search-toggle:hover": { color: `${t.textSecondary}` },
    ".boo-search-toggle[aria-pressed=true]": {
      color: `${t.text}`,
      backgroundColor: `${t.separator}`,
    },

    // Joined stepper, like FindBarStepper: one rounded rect split by a hairline.
    ".boo-search-stepper": {
      display: "flex",
      alignItems: "stretch",
      height: "22px",
      overflow: "hidden",
      boxSizing: "border-box",
      backgroundColor: t.controlFill,
      border: hairline,
      borderRadius: "6px",
    },
    ".boo-search-segment": {
      display: "inline-flex",
      alignItems: "center",
      justifyContent: "center",
      flex: "1",
      minWidth: "28px",
      color: `${t.text}`,
    },
    ".boo-search-segment:hover": { backgroundColor: `${t.hoverFill}` },
    ".boo-search-label": { flex: "1 0 auto", padding: "0 10px" },
    ".boo-search-stepper.disabled .boo-search-segment": {
      color: `${t.textTertiary}`,
      backgroundColor: "transparent",
      pointerEvents: "none",
    },
    ".boo-search-divider": {
      flexShrink: "0",
      width: "1px",
      margin: "5px 0",
      backgroundColor: t.separator,
    },

    // Done: titled push button, like FindBarButton(.push).
    ".boo-search-push": {
      height: "22px",
      padding: "0 12px",
      boxSizing: "border-box",
      backgroundColor: `${t.controlFill}`,
      border: `${hairline}`,
      borderRadius: "6px",
      color: `${t.text}`,
    },
    ".boo-search-push:hover": { backgroundColor: `${t.separator}` },
  };
}
