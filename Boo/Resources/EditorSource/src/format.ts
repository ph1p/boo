// Built-in formatters and the JSON linter. js-beautify only changes
// whitespace, so it is safe for JavaScript, CSS and HTML, and for JSON it
// keeps comments and number spellings that a parse/stringify round trip
// would lose. It mangles TypeScript type syntax, so TypeScript is left to a
// language server.

import type { Extension } from "@codemirror/state";
import { linter } from "@codemirror/lint";
import type { Indent } from "./indent";

type Kind = "js" | "css" | "html";

const kinds: Record<string, Kind> = {
  JavaScript: "js",
  JSX: "js",
  JSON: "js",
  CSS: "css",
  SCSS: "css",
  LESS: "css",
  HTML: "html",
};

/** Formats `text`, or returns null when the language has no built-in formatter. */
export async function formatText(
  languageName: string | undefined,
  text: string,
  indent: Indent,
): Promise<string | null> {
  const kind = languageName ? kinds[languageName] : undefined;
  if (!kind) return null;
  const beautify = (await import("js-beautify")).default;
  const opts = {
    indent_size: indent.insertSpaces ? indent.tabSize : 1,
    indent_char: indent.insertSpaces ? " " : "\t",
    indent_with_tabs: !indent.insertSpaces,
    end_with_newline: text.endsWith("\n"),
    preserve_newlines: true,
    max_preserve_newlines: 2,
  };
  switch (kind) {
    case "js":
      return beautify.js(text, { ...opts, e4x: languageName === "JSX" });
    case "css":
      return beautify.css(text, opts);
    case "html":
      return beautify.html(text, opts);
  }
}

/** JSON files that allow comments, where a strict parse reports false errors. */
const commentedJson =
  /(^|\/)(tsconfig.*|jsconfig.*|settings|launch|tasks|devcontainer|extensions|keybindings)\.json$|\.(jsonc|json5)$|^\.[a-z]+rc$/i;

/** Lints strict JSON files; others get nothing. */
export async function jsonLint(fileName: string | undefined): Promise<Extension> {
  if (!fileName || !/\.json$/i.test(fileName) || commentedJson.test(fileName)) return [];
  const { jsonParseLinter } = await import("@codemirror/lang-json");
  return linter(jsonParseLinter(), { delay: 300 });
}
