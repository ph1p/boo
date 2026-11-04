// Language detection and loading. Every grammar in @codemirror/language-data
// is a dynamic import, so it is its own chunk and loads only when used.

import { LanguageDescription, type LanguageSupport } from "@codemirror/language";
import { languages as builtIn } from "@codemirror/language-data";

export const PLAIN_TEXT = "Plain Text";

/** language-data's list, with Markdown highlighting fenced code blocks. */
export const languages: readonly LanguageDescription[] = builtIn.map((d) =>
  d.name === "Markdown"
    ? LanguageDescription.of({
        name: d.name,
        alias: d.alias,
        extensions: d.extensions,
        load: () =>
          import("@codemirror/lang-markdown").then((m) => m.markdown({ codeLanguages: languages })),
      })
    : d,
);

const byName = new Map(languages.map((d) => [d.name, d]));

/** Names language-data doesn't cover, or maps to a less common language. */
const extraNames: [RegExp, string][] = [
  [/^\.(bash|zsh)(rc|_profile|env|_login|_logout)$|^\.profile$|\.zsh$/i, "Shell"],
  [/\.(jsonc|json5)$|^\.(babelrc|eslintrc|prettierrc|swcrc)$/i, "JSON"],
  [/\.m$/i, "Objective-C"],
  [/^\.env(\..+)?$|^\.(gitconfig|editorconfig|npmrc)$|\.(conf|cfg)$/i, "Properties files"],
];

/** Markers on the first line, for files without a telling name. */
const firstLineRules: [RegExp, string][] = [
  [/^#!.*\b(ts-node|tsx|deno)\b/, "TypeScript"],
  [/^#!.*\b(node|bun)\b/, "JavaScript"],
  [/^#!.*\bpython/, "Python"],
  [/^#!.*\b(ba|z|k|da)?sh\b/, "Shell"],
  [/^#!.*\bruby/, "Ruby"],
  [/^#!.*\bperl/, "Perl"],
  [/^#!.*\bphp/, "PHP"],
  [/^#!.*\blua/, "Lua"],
  [/^<\?php/, "PHP"],
  [/^<\?xml/, "XML"],
  [/^\s*(<!doctype html|<html)/i, "HTML"],
];

/** Picks a language from the file name (exact names, then the longest
 *  matching extension), then from a shebang or other first-line marker. */
export function detectLanguage(
  fileName: string | undefined,
  firstLine: string,
): LanguageDescription | null {
  if (fileName) {
    for (const [pattern, name] of extraNames) {
      if (pattern.test(fileName)) return byName.get(name) ?? null;
    }
    for (const d of languages) {
      if (d.filename?.test(fileName)) return d;
    }
    const lower = fileName.toLowerCase();
    let best: LanguageDescription | null = null;
    let bestLength = 0;
    for (const d of languages) {
      for (const ext of d.extensions) {
        const e = `.${ext.toLowerCase()}`;
        if (e.length > bestLength && lower.endsWith(e)) {
          best = d;
          bestLength = e.length;
        }
      }
    }
    if (best) return best;
  }
  for (const [pattern, name] of firstLineRules) {
    if (pattern.test(firstLine)) return byName.get(name) ?? null;
  }
  return null;
}

export function languageByName(name: string): LanguageDescription | null {
  return byName.get(name) ?? null;
}

export function loadLanguage(desc: LanguageDescription): Promise<LanguageSupport> {
  return desc.support ? Promise.resolve(desc.support) : desc.load();
}

/** Names for the status strip's picker, sorted, Plain Text included. */
export function languageNames(): string[] {
  return [PLAIN_TEXT, ...languages.map((d) => d.name)].sort((a, b) =>
    a.localeCompare(b, undefined, { sensitivity: "base" }),
  );
}
