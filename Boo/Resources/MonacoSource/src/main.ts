import * as monaco from "monaco-editor";
// monaco-editor 0.56 added an `exports` map that rewrites `monaco-editor/*` to
// `esm/vs/*.js`, so the old `esm/vs/...` prefixes no longer resolve. The ESM
// entry also imports its own component CSS, replacing the `min/vs` stylesheet.
import editorWorker from "monaco-editor/editor/editor.worker?worker";
import jsonWorker from "monaco-editor/language/json/json.worker?worker";
import cssWorker from "monaco-editor/language/css/css.worker?worker";
import htmlWorker from "monaco-editor/language/html/html.worker?worker";
import tsWorker from "monaco-editor/language/typescript/ts.worker?worker";

declare global {
  interface BooMessageHandler {
    postMessage: (message: BooMessage) => void;
  }

  interface Window {
    initEditorFromJSON: (data: EditorInitData) => void;
    setContent: (content: string) => void;
    prepareSave: (options: SaveOptions) => Promise<SavePayload>;
    markClean: (version: number) => boolean;
    setFileInfo: (info: FileInfo) => void;
    showBanner: (banner: Banner | null) => void;
    setTheme: (themeData: MonacoThemeData) => void;
    setEditorOptions: (options: EditorOptions) => void;
    setAppearance: (themeData: MonacoThemeData, options: EditorOptions) => void;
    focusEditor: () => void;
    revealPosition: (line: number, column: number) => void;
    webkit?: {
      messageHandlers?: {
        boo?: BooMessageHandler;
      };
    };
    MonacoEnvironment?: {
      getWorker: (_moduleId: string, label: string) => Worker;
    };
  }

  interface WindowEventMap {
    error: ErrorEvent;
  }
}

type MonacoRule = {
  token: string;
  foreground: string;
  fontStyle?: string;
};

type MonacoThemeData = {
  base: "vs" | "vs-dark" | "hc-black";
  inherit: boolean;
  rules: MonacoRule[];
  colors: Record<string, string>;
};

type FileInfo = {
  /** Base name, used to pick the language. */
  fileName?: string;
  /** Shown in the status strip. */
  encoding?: string;
};

type EditorInitData = FileInfo & {
  content: string;
  readOnly?: boolean;
  /** Shown above the editor, e.g. why the file can't be edited. */
  notice?: string;
  themeData?: MonacoThemeData;
  options?: EditorOptions;
};

type EditorOptions = {
  fontFamily: string;
  fontSize: number;
  lineHeight: number;
  tabSize?: number;
  insertSpaces?: boolean;
  detectIndentation?: boolean;
  wordWrap?: "off" | "on";
  lineNumbers?: "on" | "off";
  minimap?: boolean;
  rulers?: number[];
  renderWhitespace?: "none" | "boundary" | "selection" | "trailing" | "all";
  bracketPairColors?: boolean;
  stickyScroll?: boolean;
  fontLigatures?: boolean;
  cursorStyle?: "line" | "block" | "underline";
  cursorBlinking?: boolean;
  statusStrip?: boolean;
  placeholder?: string;
  folding?: boolean;
  glyphMargin?: boolean;
};

type SaveOptions = {
  format?: boolean;
  trimTrailingWhitespace?: boolean;
  insertFinalNewline?: boolean;
};

type SavePayload = {
  content: string;
  /** Pass back to markClean once written. */
  version: number;
};

type Banner = {
  id: string;
  message: string;
  actions: { id: string; label: string }[];
};

type BooMessage =
  | { type: "log"; message: string }
  | { type: "error"; message: string }
  | { type: "ready" }
  | { type: "dirty"; dirty: boolean }
  | { type: "changed" }
  | { type: "focused" }
  | { type: "blurred" }
  | { type: "bannerAction"; id: string; action: string };

let editor: monaco.editor.IStandaloneCodeEditor | undefined;
let isDirty = false;
// The model's alternative version at the last load or save. Undoing back to
// it makes the file clean again.
let savedVersionId = 0;
let changedTimer: ReturnType<typeof setTimeout> | undefined;
// True while Swift replaces the content, so it doesn't count as an edit.
let applyingContent = false;
let encodingName = "UTF-8";
let dropDragoverHandler: ((e: DragEvent) => void) | null = null;
let dropDropHandler: ((e: DragEvent) => void) | null = null;
let editorDisposables: monaco.IDisposable[] = [];
let statusFrame = 0;
let languageNames: Map<string, string> | undefined;

const workerCache = new Map<string, Worker>();

function getOrCreateWorker(key: string, factory: () => Worker): Worker {
  let worker = workerCache.get(key);
  if (!worker) {
    worker = factory();
    workerCache.set(key, worker);
  }
  return worker;
}

function postMessage(message: BooMessage): void {
  window.webkit?.messageHandlers?.boo?.postMessage(message);
}

function log(message: string): void {
  postMessage({ type: "log", message });
}

function reportError(message: string): void {
  postMessage({ type: "error", message });
}

window.MonacoEnvironment = {
  getWorker(_: string, label: string): Worker {
    switch (label) {
      case "json":
        return getOrCreateWorker("json", () => new jsonWorker());
      case "css":
      case "scss":
      case "less":
        return getOrCreateWorker("css", () => new cssWorker());
      case "html":
      case "handlebars":
      case "razor":
        return getOrCreateWorker("html", () => new htmlWorker());
      case "typescript":
      case "javascript":
        return getOrCreateWorker("typescript", () => new tsWorker());
      default:
        return getOrCreateWorker("editor", () => new editorWorker());
    }
  },
};

window.addEventListener("error", (event) => {
  reportError(`${event.message} at ${event.lineno}:${event.colno}`);
});

function element<T extends HTMLElement>(id: string): T {
  const el = document.getElementById(id);
  if (!el) throw new Error(`#${id} not found`);
  return el as T;
}

/** Mirrors the editor colors onto the banner and status strip. */
function applyChromeColors(themeData: MonacoThemeData): void {
  const style = document.documentElement.style;
  const colors = themeData.colors;
  const set = (name: string, value: string | undefined) => {
    if (value) style.setProperty(name, value);
  };
  set("--boo-bg", colors["editor.background"]);
  set("--boo-fg", colors["editor.foreground"]);
  set("--boo-border", colors["editorIndentGuide.background"]);
  set("--boo-accent", colors["editorCursor.foreground"]);
}

function ensureTheme(themeData?: MonacoThemeData): string {
  if (!themeData) {
    return "vs-dark";
  }
  monaco.editor.defineTheme("boo-theme", themeData);
  applyChromeColors(themeData);
  return "boo-theme";
}

function resolveEditorOptions(
  options?: EditorOptions,
): monaco.editor.IEditorOptions & monaco.editor.IGlobalEditorOptions {
  return {
    fontFamily: options?.fontFamily ?? "SF Mono",
    fontSize: options?.fontSize ?? 13,
    lineHeight: options?.lineHeight ?? 20,
    tabSize: options?.tabSize ?? 4,
    insertSpaces: options?.insertSpaces ?? true,
    detectIndentation: options?.detectIndentation ?? true,
    wordWrap: options?.wordWrap ?? "off",
    lineNumbers: options?.lineNumbers ?? "on",
    minimap: { enabled: options?.minimap ?? false },
    rulers: options?.rulers ?? [],
    renderWhitespace: options?.renderWhitespace ?? "selection",
    bracketPairColorization: { enabled: options?.bracketPairColors ?? true },
    stickyScroll: { enabled: options?.stickyScroll ?? false },
    fontLigatures: options?.fontLigatures ?? false,
    cursorStyle: options?.cursorStyle ?? "line",
    cursorBlinking: options?.cursorBlinking === false ? "solid" : "blink",
    placeholder: options?.placeholder,
    folding: options?.folding ?? true,
    glyphMargin: options?.glyphMargin ?? true,
  };
}

function applyOptions(options?: EditorOptions): void {
  editor?.updateOptions(resolveEditorOptions(options));
  setStatusVisible(options);
}

/** Only hosts that ask for it (the editor tab) get the strip. */
function setStatusVisible(options?: EditorOptions): void {
  element("status").hidden = options?.statusStrip !== true;
  scheduleStatusUpdate();
}

// MARK: - Language

/** Picks a language from the file name (exact names, then the longest
 *  matching extension), then from a shebang or other first-line marker. */
function detectLanguage(fileName: string | undefined, firstLine: string): string {
  const languages = monaco.languages.getLanguages();
  if (fileName) {
    const name = fileName.toLowerCase();
    let best = "";
    let bestLength = 0;
    for (const lang of languages) {
      if (lang.filenames?.some((f) => f.toLowerCase() === name)) return lang.id;
      for (const ext of lang.extensions ?? []) {
        const e = ext.toLowerCase();
        if (e.length > bestLength && name.endsWith(e)) {
          best = lang.id;
          bestLength = e.length;
        }
      }
    }
    if (best) return best;
  }
  for (const lang of languages) {
    if (!lang.firstLine) continue;
    try {
      if (new RegExp(lang.firstLine).test(firstLine)) return lang.id;
    } catch {
      // A language's pattern that JS can't parse just doesn't match.
    }
  }
  return "plaintext";
}

function languageName(id: string): string {
  languageNames ??= new Map(
    monaco.languages.getLanguages().map((l) => [l.id, l.aliases?.[0] ?? l.id]),
  );
  return languageNames.get(id) ?? id;
}

function fillLanguagePicker(): void {
  const select = element<HTMLSelectElement>("language-select");
  if (select.options.length > 0) return;
  const entries = monaco.languages
    .getLanguages()
    .map((l) => ({ id: l.id, name: languageName(l.id) }))
    .sort((a, b) => a.name.localeCompare(b.name));
  for (const entry of entries) {
    select.add(new Option(entry.name, entry.id));
  }
}

// MARK: - Status strip

/** Coalesces the several change events of one keystroke into one update. */
function scheduleStatusUpdate(): void {
  if (statusFrame) return;
  statusFrame = requestAnimationFrame(() => {
    statusFrame = 0;
    updateStatus();
  });
}

function updateStatus(): void {
  const model = editor?.getModel();
  if (!editor || !model || element("status").hidden) return;

  const position = editor.getPosition();
  element("status-position").textContent = position
    ? `Ln ${position.lineNumber}, Col ${position.column}`
    : "";

  const selections = editor.getSelections() ?? [];
  const selected = selections.reduce((sum, s) => sum + model.getValueLengthInRange(s), 0);
  let selectionText = "";
  if (selections.length > 1) {
    selectionText = `${selections.length} cursors`;
  } else if (selected > 0) {
    selectionText = `${selected} selected`;
  }
  element("status-selection").textContent = selectionText;

  const indent = model.getOptions();
  element("status-indent").textContent = indent.insertSpaces
    ? `Spaces: ${indent.tabSize}`
    : `Tab Size: ${indent.tabSize}`;
  element<HTMLSelectElement>("indent-select").value =
    `${indent.insertSpaces ? "spaces" : "tabs"}:${indent.tabSize}`;

  element("status-encoding").textContent = encodingName;
  element("status-eol").textContent = model.getEOL() === "\r\n" ? "CRLF" : "LF";

  const language = model.getLanguageId();
  element("status-language").textContent = languageName(language);
  element<HTMLSelectElement>("language-select").value = language;
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
    editor?.getModel()?.updateOptions({ insertSpaces: kind === "spaces", tabSize: Number(size) });
    scheduleStatusUpdate();
    editor?.focus();
  });

  const languageSelect = element<HTMLSelectElement>("language-select");
  languageSelect.addEventListener("change", () => {
    const model = editor?.getModel();
    if (model) monaco.editor.setModelLanguage(model, languageSelect.value);
    scheduleStatusUpdate();
    editor?.focus();
  });

  element("status-eol").addEventListener("click", () => {
    const model = editor?.getModel();
    if (!model) return;
    const crlf = model.getEOL() === "\r\n";
    model.pushEOL(crlf ? monaco.editor.EndOfLineSequence.LF : monaco.editor.EndOfLineSequence.CRLF);
    scheduleStatusUpdate();
    editor?.focus();
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
  const model = editor?.getModel();
  const dirty = !!model && model.getAlternativeVersionId() !== savedVersionId;
  if (dirty === isDirty) return;
  isDirty = dirty;
  postMessage({ type: "dirty", dirty });
}

function markSaved(): void {
  savedVersionId = editor?.getModel()?.getAlternativeVersionId() ?? 0;
  syncDirty();
}

// MARK: - Save preparation

async function formatDocument(): Promise<void> {
  const action = editor?.getAction("editor.action.formatDocument");
  if (!action || !action.isSupported()) return;
  try {
    // A formatter that never answers must not block the save.
    await Promise.race([action.run(), new Promise((resolve) => setTimeout(resolve, 2000))]);
  } catch (error) {
    log(`Format on save failed: ${String(error)}`);
  }
}

function trimTrailingWhitespace(model: monaco.editor.ITextModel): void {
  // Two trailing spaces are a line break in Markdown.
  if (model.getLanguageId() === "markdown") return;
  const edits: monaco.editor.IIdentifiedSingleEditOperation[] = [];
  for (let line = 1; line <= model.getLineCount(); line++) {
    const text = model.getLineContent(line);
    const match = /[ \t]+$/.exec(text);
    if (match) {
      edits.push({
        range: new monaco.Range(line, match.index + 1, line, text.length + 1),
        text: "",
      });
    }
  }
  if (edits.length > 0) editor?.executeEdits("boo-save", edits);
}

function insertFinalNewline(model: monaco.editor.ITextModel): void {
  const last = model.getLineCount();
  if (model.getValueLength() === 0 || model.getLineContent(last) === "") return;
  const column = model.getLineMaxColumn(last);
  editor?.executeEdits("boo-save", [
    { range: new monaco.Range(last, column, last, column), text: model.getEOL() },
  ]);
}

/** Applies the on-save edits (as undoable edits) and returns the text to write. */
window.prepareSave = async (options: SaveOptions): Promise<SavePayload> => {
  const model = editor?.getModel();
  if (!editor || !model) return { content: "", version: -1 };
  if (!editor.getOption(monaco.editor.EditorOption.readOnly)) {
    if (options.format) await formatDocument();
    if (options.trimTrailingWhitespace) trimTrailingWhitespace(model);
    if (options.insertFinalNewline) insertFinalNewline(model);
  }
  return { content: model.getValue(), version: model.getAlternativeVersionId() };
};

// MARK: - Drop

function setupDropHandler(ed: monaco.editor.IStandaloneCodeEditor): void {
  // Remove previous listeners before re-registering (initEditorFromJSON can be called multiple times).
  if (dropDragoverHandler) document.removeEventListener("dragover", dropDragoverHandler);
  if (dropDropHandler) document.removeEventListener("drop", dropDropHandler);

  // Listen on document so drops anywhere in the webview are caught,
  // preventing WKWebView from navigating to dropped URLs.
  dropDragoverHandler = (e) => {
    if (!hasDraggableUrl(e.dataTransfer)) return;
    e.preventDefault();
    e.stopPropagation();
    e.dataTransfer!.dropEffect = "copy";
  };

  dropDropHandler = (e) => {
    const dt = e.dataTransfer;
    if (!dt) return;
    const url = extractDroppedUrl(dt);
    if (!url) return;
    e.preventDefault();
    e.stopPropagation();

    const position = ed.getPosition();
    if (!position) return;

    ed.executeEdits("url-drop", [
      {
        range: new monaco.Range(
          position.lineNumber,
          position.column,
          position.lineNumber,
          position.column,
        ),
        text: url,
        forceMoveMarkers: true,
      },
    ]);
    ed.focus();
  };

  document.addEventListener("dragover", dropDragoverHandler);
  document.addEventListener("drop", dropDropHandler);
}

function hasDraggableUrl(dt: DataTransfer | null): boolean {
  if (!dt) return false;
  return dt.types.includes("text/uri-list");
}

function extractDroppedUrl(dt: DataTransfer): string | null {
  const uriList = dt.getData("text/uri-list");
  if (uriList) {
    const first = uriList
      .split(/\r?\n/)
      .find((l) => !l.startsWith("#"))
      ?.trim();
    if (first) return first;
  }
  return null;
}

// MARK: - Bridge

window.initEditorFromJSON = (data: EditorInitData): void => {
  log(`initEditorFromJSON received for ${data.fileName ?? "untitled"}`);

  try {
    editorDisposables.forEach((d) => d.dispose());
    editorDisposables = [];
    editor?.getModel()?.dispose();
    editor?.dispose();
    workerCache.forEach((w) => w.terminate());
    workerCache.clear();

    const theme = ensureTheme(data.themeData);
    const container = element("container");
    const content = data.content ?? "";
    encodingName = data.encoding ?? "UTF-8";

    editor = monaco.editor.create(container, {
      value: content,
      language: detectLanguage(data.fileName, content.split("\n", 1)[0]),
      theme,
      automaticLayout: true,
      scrollBeyondLastLine: false,
      readOnly: data.readOnly ?? false,
      ...resolveEditorOptions(data.options),
    });
    const ed = editor;

    editorDisposables.push(
      ed.onDidChangeModelContent(() => {
        scheduleStatusUpdate();
        if (applyingContent) return;
        syncDirty();
        // Debounced per-edit signal for autosaving hosts.
        clearTimeout(changedTimer);
        changedTimer = setTimeout(() => postMessage({ type: "changed" }), 500);
      }),
      ed.onDidChangeCursorSelection(scheduleStatusUpdate),
      ed.onDidChangeModelLanguage(scheduleStatusUpdate),
      ed.onDidChangeModelOptions(scheduleStatusUpdate),
      ed.onDidFocusEditorWidget(() => postMessage({ type: "focused" })),
      ed.onDidBlurEditorWidget(() => postMessage({ type: "blurred" })),
    );

    setupDropHandler(ed);
    fillLanguagePicker();
    setStatusVisible(data.options);
    window.showBanner(data.notice ? { id: "notice", message: data.notice, actions: [] } : null);

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
  const model = editor?.getModel();
  if (!editor || !model) return;
  clearTimeout(changedTimer);
  if (model.getValue() !== content) {
    const view = editor.saveViewState();
    applyingContent = true;
    model.pushStackElement();
    model.pushEditOperations([], [{ range: model.getFullModelRange(), text: content }], () => null);
    model.pushStackElement();
    applyingContent = false;
    if (view) editor.restoreViewState(view);
  }
  markSaved();
};

/** Called after a save with prepareSave's version; stays dirty when edits
 *  landed during the write. */
window.markClean = (version: number): boolean => {
  if (editor?.getModel()?.getAlternativeVersionId() !== version) return false;
  markSaved();
  return true;
};

window.setFileInfo = (info: FileInfo): void => {
  if (info.encoding) encodingName = info.encoding;
  const model = editor?.getModel();
  if (model && info.fileName) {
    monaco.editor.setModelLanguage(model, detectLanguage(info.fileName, model.getLineContent(1)));
  }
  scheduleStatusUpdate();
};

window.setTheme = (themeData: MonacoThemeData): void => {
  monaco.editor.setTheme(ensureTheme(themeData));
};

window.setEditorOptions = (options: EditorOptions): void => {
  applyOptions(options);
};

window.setAppearance = (themeData: MonacoThemeData, options: EditorOptions): void => {
  monaco.editor.setTheme(ensureTheme(themeData));
  applyOptions(options);
};

window.focusEditor = (): void => {
  editor?.focus();
};

window.revealPosition = (line: number, column: number): void => {
  if (!editor) return;
  const lineNumber = Math.max(1, Math.min(line, editor.getModel()?.getLineCount() ?? line));
  const position = { lineNumber, column: Math.max(1, column) };
  editor.setPosition(position);
  editor.revealPositionInCenter(position);
  editor.focus();
};

setupStatusStrip();
log("monaco bundle loaded");
postMessage({ type: "ready" });
