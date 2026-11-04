import {
  autocompletion,
  closeBrackets,
  closeBracketsKeymap,
  completeAnyWord,
  completionKeymap,
} from "@codemirror/autocomplete";
import { defaultKeymap, history, historyKeymap, isolateHistory } from "@codemirror/commands";
import {
  bracketMatching,
  foldKeymap,
  indentOnInput,
  type LanguageDescription,
} from "@codemirror/language";
import { lintKeymap } from "@codemirror/lint";
import { highlightSelectionMatches, search, searchKeymap } from "@codemirror/search";
import {
  Annotation,
  Compartment,
  EditorState,
  type Extension,
  Text,
  Transaction,
} from "@codemirror/state";
import {
  EditorView,
  crosshairCursor,
  dropCursor,
  highlightActiveLine,
  highlightSpecialChars,
  keymap,
  rectangularSelection,
} from "@codemirror/view";
import {
  type Banner,
  type EditorInitData,
  type EditorOptions,
  type FileInfo,
  type SaveOptions,
  type SavePayload,
  element,
  log,
  postMessage,
  reportError,
} from "./bridge";
import { formatText, jsonLint } from "./format";
import * as lsp from "./lsp";
import { type Indent, currentIndent, detectIndent, indentExtension, tabBinding } from "./indent";
import {
  PLAIN_TEXT,
  detectLanguage,
  languageByName,
  languageNames,
  loadLanguage,
} from "./languages";
import type { LspTarget } from "./lsp";
import { type ResolvedOptions, optionsExtension, resolveOptions } from "./options";
import { type ThemeData, themeExtension } from "./theme";

type Eol = "\n" | "\r\n";

let view: EditorView | undefined;
let options: ResolvedOptions = resolveOptions();
let fileName: string | undefined;
let encodingName = "UTF-8";
let eol: Eol = "\n";
let language: LanguageDescription | null = null;
/** Indentation found in the file at load, used while detectIndentation is on. */
let detectedIndent: Indent | null = null;
/** Picked in the status strip; wins over settings and detection. */
let pickedIndent: Indent | null = null;

// Dirty tracking compares against the text at the last load or save, so
// undoing back to it makes the file clean again.
let savedDoc: Text = Text.empty;
let savedEol: Eol = "\n";
let isDirty = false;
/** Bumped on every edit; prepareSave hands it out, markClean takes it back. */
let version = 0;
const saveSnapshots = new Map<number, { doc: Text; eol: Eol }>();
let changedTimer: ReturnType<typeof setTimeout> | undefined;
let statusFrame = 0;
let dropDragoverHandler: ((e: DragEvent) => void) | null = null;
let dropDropHandler: ((e: DragEvent) => void) | null = null;

/** Marks Swift's content replacements, which aren't user edits. */
const external = Annotation.define<boolean>();

const compartments = {
  language: new Compartment(),
  theme: new Compartment(),
  options: new Compartment(),
  indent: new Compartment(),
  readOnly: new Compartment(),
  lsp: new Compartment(),
};

window.addEventListener("error", (event) => {
  reportError(`${event.message} at ${event.lineno}:${event.colno}`);
});

function detectEol(text: string): Eol {
  const crlf = text.split("\r\n").length - 1;
  if (crlf === 0) return "\n";
  const lf = text.split("\n").length - 1;
  return crlf * 2 >= lf ? "\r\n" : "\n";
}

function docText(): string {
  return view ? view.state.doc.sliceString(0, undefined, eol) : "";
}

// MARK: - Options

function resolvedIndent(): Indent {
  if (pickedIndent) return pickedIndent;
  const fromSettings = { insertSpaces: options.insertSpaces, tabSize: options.tabSize };
  if (!options.detectIndentation || !detectedIndent) return fromSettings;
  // Tabs keep the configured width; spaces bring their own.
  return {
    insertSpaces: detectedIndent.insertSpaces,
    tabSize: detectedIndent.tabSize || options.tabSize,
  };
}

function applyOptions(next?: EditorOptions): void {
  options = resolveOptions(next);
  view?.dispatch({
    effects: [
      compartments.options.reconfigure(optionsExtension(options)),
      compartments.indent.reconfigure(indentExtension(resolvedIndent())),
    ],
  });
  setStatusVisible();
}

/** Only hosts that ask for it (the editor tab) get the strip. */
function setStatusVisible(): void {
  element("status").hidden = !options.statusStrip;
  scheduleStatusUpdate();
}

// MARK: - Language

function setLanguage(desc: LanguageDescription | null): void {
  language = desc;
  scheduleStatusUpdate();
  postMessage({ type: "lspLanguage", language: desc?.name ?? null });
  if (!desc) {
    view?.dispatch({ effects: compartments.language.reconfigure([]) });
    return;
  }
  // A JSON language server reports its own diagnostics.
  const lint =
    desc.name === "JSON" && !lsp.isConnected() ? jsonLint(fileName) : Promise.resolve([]);
  Promise.all([loadLanguage(desc), lint]).then(
    ([support, lintExtension]) => {
      if (language !== desc) return;
      view?.dispatch({ effects: compartments.language.reconfigure([support, lintExtension]) });
    },
    (error) => reportError(`Loading ${desc.name} failed: ${String(error)}`),
  );
}

function detectFor(name: string | undefined): LanguageDescription | null {
  const first = view && view.state.doc.lines > 0 ? view.state.doc.line(1).text : "";
  return detectLanguage(name, first);
}

function fillLanguagePicker(): void {
  const select = element<HTMLSelectElement>("language-select");
  if (select.options.length > 0) return;
  for (const name of languageNames()) select.add(new Option(name, name));
}

// MARK: - Status strip

/** Coalesces the several updates of one keystroke into one. */
function scheduleStatusUpdate(): void {
  if (statusFrame) return;
  statusFrame = requestAnimationFrame(() => {
    statusFrame = 0;
    updateStatus();
  });
}

function updateStatus(): void {
  if (!view || element("status").hidden) return;
  const { state } = view;
  const head = state.selection.main.head;
  const line = state.doc.lineAt(head);
  element("status-position").textContent = `Ln ${line.number}, Col ${head - line.from + 1}`;

  const ranges = state.selection.ranges;
  const selected = ranges.reduce((sum, r) => sum + (r.to - r.from), 0);
  let selectionText = "";
  if (ranges.length > 1) {
    selectionText = `${ranges.length} cursors`;
  } else if (selected > 0) {
    selectionText = `${selected} selected`;
  }
  element("status-selection").textContent = selectionText;

  const indent = currentIndent(state);
  element("status-indent").textContent = indent.insertSpaces
    ? `Spaces: ${indent.tabSize}`
    : `Tab Size: ${indent.tabSize}`;
  element<HTMLSelectElement>("indent-select").value =
    `${indent.insertSpaces ? "spaces" : "tabs"}:${indent.tabSize}`;

  element("status-encoding").textContent = encodingName;
  element("status-eol").textContent = eol === "\r\n" ? "CRLF" : "LF";

  const name = language?.name ?? PLAIN_TEXT;
  element("status-language").textContent = name;
  element<HTMLSelectElement>("language-select").value = name;
}

function setupStatusStrip(): void {
  const indentSelect = element<HTMLSelectElement>("indent-select");
  for (const kind of ["spaces", "tabs"]) {
    for (const size of [2, 4, 8]) {
      const label =
        kind === "spaces" ? `Indent with ${size} spaces` : `Indent with tabs (${size} wide)`;
      indentSelect.add(new Option(label, `${kind}:${size}`));
    }
  }
  indentSelect.addEventListener("change", () => {
    const [kind, size] = indentSelect.value.split(":");
    pickedIndent = { insertSpaces: kind === "spaces", tabSize: Number(size) };
    view?.dispatch({ effects: compartments.indent.reconfigure(indentExtension(pickedIndent)) });
    view?.focus();
  });

  const languageSelect = element<HTMLSelectElement>("language-select");
  languageSelect.addEventListener("change", () => {
    setLanguage(languageByName(languageSelect.value));
    view?.focus();
  });

  element("status-eol").addEventListener("click", () => {
    if (!view) return;
    eol = eol === "\r\n" ? "\n" : "\r\n";
    // Switching line endings is an edit: it changes what gets written.
    version++;
    syncDirty();
    scheduleStatusUpdate();
    view.focus();
  });
}

// MARK: - Banner

window.showBanner = (banner: Banner | null): void => {
  const root = element("banner");
  const actions = element("banner-actions");
  actions.replaceChildren();
  if (!banner) {
    root.hidden = true;
    return;
  }
  element("banner-message").textContent = banner.message;
  for (const action of banner.actions) {
    const button = document.createElement("button");
    button.textContent = action.label;
    button.addEventListener("click", () => {
      root.hidden = true;
      postMessage({ type: "bannerAction", id: banner.id, action: action.id });
    });
    actions.append(button);
  }
  root.hidden = false;
};

// MARK: - Dirty tracking

function syncDirty(): void {
  const dirty = !!view && (eol !== savedEol || !view.state.doc.eq(savedDoc));
  if (dirty === isDirty) return;
  isDirty = dirty;
  postMessage({ type: "dirty", dirty });
}

function markSaved(): void {
  if (view) savedDoc = view.state.doc;
  savedEol = eol;
  saveSnapshots.clear();
  syncDirty();
}

// MARK: - Save preparation

/** One change covering only the differing middle, so the cursor, folds and
 *  scroll position map through it. */
function minimalChange(from: string, to: string): { from: number; to: number; insert: string } {
  let start = 0;
  const max = Math.min(from.length, to.length);
  while (start < max && from.charCodeAt(start) === to.charCodeAt(start)) start++;
  let end = 0;
  while (
    end < max - start &&
    from.charCodeAt(from.length - 1 - end) === to.charCodeAt(to.length - 1 - end)
  ) {
    end++;
  }
  return { from: start, to: from.length - end, insert: to.slice(start, to.length - end) };
}

/** Replaces the whole text as one undoable edit that keeps the cursor. */
function replaceText(text: string, userEvent: string): void {
  if (!view) return;
  const current = view.state.doc.toString();
  if (current === text) return;
  view.dispatch({
    changes: minimalChange(current, text),
    userEvent,
    scrollIntoView: false,
  });
}

function trimTrailingWhitespace(): void {
  if (!view) return;
  // Two trailing spaces are a line break in Markdown.
  if (language?.name === "Markdown") return;
  const { doc } = view.state;
  const changes: { from: number; to: number }[] = [];
  for (let n = 1; n <= doc.lines; n++) {
    const line = doc.line(n);
    const match = /[ \t]+$/.exec(line.text);
    if (match) changes.push({ from: line.from + match.index, to: line.to });
  }
  if (changes.length > 0) view.dispatch({ changes, userEvent: "boo.save" });
}

function insertFinalNewline(): void {
  if (!view) return;
  const { doc } = view.state;
  if (doc.length === 0 || doc.line(doc.lines).length === 0) return;
  view.dispatch({ changes: { from: doc.length, insert: "\n" }, userEvent: "boo.save" });
}

/** Applies the on-save edits (as undoable edits) and returns the text to write. */
window.prepareSave = async (save: SaveOptions): Promise<SavePayload> => {
  if (!view) return { content: "", version: -1 };
  if (!view.state.readOnly) {
    if (save.format) await formatDocument();
    if (save.trimTrailingWhitespace) trimTrailingWhitespace();
    if (save.insertFinalNewline) insertFinalNewline();
  }
  saveSnapshots.set(version, { doc: view.state.doc, eol });
  return { content: docText(), version };
};

const FORMAT_TIMEOUT_MS = 2000;

/** Formats the document as one undoable edit. Gives up after two seconds so
 *  a slow formatter never blocks a save. */
async function formatDocument(): Promise<void> {
  if (!view || view.state.readOnly) return;
  const before = view.state.doc;
  const indent = currentIndent(view.state);
  const editor = view;
  const run = formatText(language?.name, before.toString(), indent).then(
    (text) => text ?? lsp.formatWithServer(editor, indent),
  );
  const timeout = new Promise<null>((resolve) =>
    setTimeout(() => resolve(null), FORMAT_TIMEOUT_MS),
  );
  try {
    const result = await Promise.race([run, timeout]);
    // Drop the result if the user typed while it ran.
    if (result === null || !view || view.state.doc !== before) return;
    replaceText(result, "boo.format");
  } catch (error) {
    log(`Format on save failed: ${String(error)}`);
  }
}

// MARK: - Drop

function setupDropHandler(): void {
  // Remove previous listeners before re-registering (initEditorFromJSON can be called multiple times).
  if (dropDragoverHandler) document.removeEventListener("dragover", dropDragoverHandler);
  if (dropDropHandler) document.removeEventListener("drop", dropDropHandler);

  // Listen on document so drops anywhere in the webview are caught,
  // preventing WKWebView from navigating to dropped URLs.
  dropDragoverHandler = (e) => {
    if (!e.dataTransfer?.types.includes("text/uri-list")) return;
    e.preventDefault();
    e.stopPropagation();
    e.dataTransfer.dropEffect = "copy";
  };

  dropDropHandler = (e) => {
    const url = e.dataTransfer && extractDroppedUrl(e.dataTransfer);
    if (!url || !view) return;
    e.preventDefault();
    e.stopPropagation();
    if (view.state.readOnly) return;
    const head = view.state.selection.main.head;
    view.dispatch({
      changes: { from: head, insert: url },
      selection: { anchor: head + url.length },
      userEvent: "input.drop",
    });
    view.focus();
  };

  document.addEventListener("dragover", dropDragoverHandler);
  document.addEventListener("drop", dropDropHandler);
}

function extractDroppedUrl(dt: DataTransfer): string | null {
  const uriList = dt.getData("text/uri-list");
  if (!uriList) return null;
  const first = uriList
    .split(/\r?\n/)
    .find((l) => !l.startsWith("#"))
    ?.trim();
  return first || null;
}

// MARK: - Editor

const onUpdate = EditorView.updateListener.of((update) => {
  if (update.docChanged) {
    version++;
    const isExternal = update.transactions.some((tr) => tr.annotation(external));
    if (!isExternal) {
      syncDirty();
      // Debounced per-edit signal for autosaving hosts.
      clearTimeout(changedTimer);
      changedTimer = setTimeout(() => postMessage({ type: "changed" }), 500);
    }
  }
  if (update.focusChanged) {
    postMessage({ type: update.view.hasFocus ? "focused" : "blurred" });
  }
  if (
    update.docChanged ||
    update.selectionSet ||
    update.transactions.some((tr) => tr.reconfigured)
  ) {
    scheduleStatusUpdate();
  }
});

function baseExtensions(): Extension[] {
  return [
    highlightSpecialChars(),
    history(),
    dropCursor(),
    EditorState.allowMultipleSelections.of(true),
    indentOnInput(),
    bracketMatching(),
    closeBrackets(),
    autocompletion(),
    EditorState.languageData.of(() => [{ autocomplete: completeAnyWord }]),
    rectangularSelection(),
    crosshairCursor(),
    highlightActiveLine(),
    highlightSelectionMatches(),
    search({ top: true }),
    keymap.of([
      ...closeBracketsKeymap,
      ...defaultKeymap,
      ...searchKeymap,
      ...historyKeymap,
      ...foldKeymap,
      ...completionKeymap,
      ...lintKeymap,
      tabBinding,
      {
        key: "Shift-Alt-f",
        run: () => {
          void formatDocument();
          return true;
        },
      },
    ]),
    EditorView.theme({
      "&": { height: "100%" },
      "&.cm-focused": { outline: "none" },
      ".cm-scroller": { overflow: "auto" },
    }),
    onUpdate,
  ];
}

window.initEditorFromJSON = (data: EditorInitData): void => {
  log(`initEditorFromJSON received for ${data.fileName ?? "untitled"}`);

  try {
    view?.destroy();
    view = undefined;
    clearTimeout(changedTimer);

    const content = data.content ?? "";
    fileName = data.fileName;
    encodingName = data.encoding ?? "UTF-8";
    eol = detectEol(content);
    options = resolveOptions(data.options);
    pickedIndent = null;

    const doc = Text.of(content.split(/\r\n?|\n/));
    detectedIndent = detectIndent(doc);
    language = detectLanguage(fileName, doc.line(1).text);

    const state = EditorState.create({
      doc,
      extensions: [
        baseExtensions(),
        compartments.language.of([]),
        compartments.theme.of(themeExtension(data.themeData)),
        compartments.options.of(optionsExtension(options)),
        compartments.indent.of(indentExtension(resolvedIndent())),
        compartments.readOnly.of(EditorState.readOnly.of(data.readOnly ?? false)),
        compartments.lsp.of(lsp.lspExtension()),
      ],
    });
    view = new EditorView({ state, parent: element("container") });

    setLanguage(language);
    setupDropHandler();
    fillLanguagePicker();
    setStatusVisible();
    window.showBanner(data.notice ? { id: "notice", message: data.notice, actions: [] } : null);

    isDirty = false;
    markSaved();
    log(`Editor instance created successfully with ${content.length} chars`);
  } catch (error) {
    const message =
      error instanceof Error ? `${error.message}\nStack: ${error.stack ?? ""}` : String(error);
    reportError(`Error creating editor: ${message}`);
  }
};

/** Replaces the text with what's on disk, keeping cursor and scroll, as one
 *  undoable edit. */
window.setContent = (content: string): void => {
  if (!view) return;
  clearTimeout(changedTimer);
  const next = content.replace(/\r\n?/g, "\n");
  const current = view.state.doc.toString();
  if (current !== next) {
    view.dispatch({
      changes: minimalChange(current, next),
      effects: view.scrollSnapshot(),
      annotations: [
        external.of(true),
        isolateHistory.of("full"),
        Transaction.addToHistory.of(true),
      ],
    });
  }
  eol = detectEol(content);
  markSaved();
  scheduleStatusUpdate();
};

/** Called after a save with prepareSave's version; stays dirty when edits
 *  landed during the write. */
window.markClean = (saved: number): boolean => {
  const snapshot = saveSnapshots.get(saved);
  if (!view || !snapshot || eol !== snapshot.eol || !view.state.doc.eq(snapshot.doc)) return false;
  markSaved();
  return true;
};

window.setFileInfo = (info: FileInfo): void => {
  if (info.encoding) encodingName = info.encoding;
  if (info.fileName) {
    fileName = info.fileName;
    setLanguage(detectFor(fileName));
  }
  scheduleStatusUpdate();
};

window.setTheme = (themeData: ThemeData): void => {
  view?.dispatch({ effects: compartments.theme.reconfigure(themeExtension(themeData)) });
};

window.setEditorOptions = (next: EditorOptions): void => {
  applyOptions(next);
};

window.setAppearance = (themeData: ThemeData, next: EditorOptions): void => {
  window.setTheme(themeData);
  applyOptions(next);
};

window.focusEditor = (): void => {
  view?.focus();
};

window.revealPosition = (line: number, column: number): void => {
  if (!view) return;
  const { doc } = view.state;
  const target = doc.line(Math.max(1, Math.min(line, doc.lines)));
  const pos = target.from + Math.min(Math.max(1, column) - 1, target.length);
  view.dispatch({
    selection: { anchor: pos },
    effects: EditorView.scrollIntoView(pos, { y: "center" }),
  });
  view.focus();
};

// MARK: - Language server

window.lspConnect = (target: LspTarget): void => {
  lsp.connect(target);
  view?.dispatch({ effects: compartments.lsp.reconfigure(lsp.lspExtension()) });
  // Drops the built-in JSON linter in favor of the server's diagnostics.
  if (language?.name === "JSON") setLanguage(language);
};

window.lspDisconnect = (): void => {
  if (!lsp.isConnected()) return;
  view?.dispatch({ effects: compartments.lsp.reconfigure([]) });
  lsp.disconnect();
  if (language?.name === "JSON") setLanguage(language);
};

window.lspReceive = (message: string): void => {
  lsp.receive(message);
};

setupStatusStrip();
log("editor bundle loaded");
postMessage({ type: "ready" });
