import * as monaco from "monaco-editor";
import editorWorker from "monaco-editor/esm/vs/editor/editor.worker?worker";
import jsonWorker from "monaco-editor/esm/vs/language/json/json.worker?worker";
import cssWorker from "monaco-editor/esm/vs/language/css/css.worker?worker";
import htmlWorker from "monaco-editor/esm/vs/language/html/html.worker?worker";
import tsWorker from "monaco-editor/esm/vs/language/typescript/ts.worker?worker";
import "monaco-editor/min/vs/editor/editor.main.css";

declare global {
  interface BooMessageHandler {
    postMessage: (message: BooMessage) => void;
  }

  interface Window {
    initEditorFromJSON: (data: EditorInitData) => void;
    setContent: (content: string) => void;
    getContent: () => string;
    setTheme: (themeData: MonacoThemeData) => void;
    setEditorOptions: (options: EditorOptions) => void;
    focusEditor: () => void;
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

type EditorInitData = {
  content: string;
  language: string;
  themeData?: MonacoThemeData;
  options?: EditorOptions;
};

type EditorOptions = {
  fontFamily: string;
  fontSize: number;
  lineHeight: number;
};

type BooMessage =
  | { type: "log"; message: string }
  | { type: "error"; message: string }
  | { type: "ready" }
  | { type: "dirty" }
  | { type: "focused" };

let editor: monaco.editor.IStandaloneCodeEditor | undefined;
let isDirty = false;

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
        return new jsonWorker();
      case "css":
      case "scss":
      case "less":
        return new cssWorker();
      case "html":
      case "handlebars":
      case "razor":
        return new htmlWorker();
      case "typescript":
      case "javascript":
        return new tsWorker();
      default:
        return new editorWorker();
    }
  },
};

window.addEventListener("error", (event) => {
  reportError(`${event.message} at ${event.lineno}:${event.colno}`);
});

function ensureTheme(themeData?: MonacoThemeData): string {
  if (!themeData) {
    return "vs-dark";
  }

  monaco.editor.defineTheme("boo-theme", themeData);
  return "boo-theme";
}

function resolveEditorOptions(options?: EditorOptions): EditorOptions {
  return {
    fontFamily: options?.fontFamily || "SF Mono",
    fontSize: options?.fontSize || 13,
    lineHeight: options?.lineHeight || 20,
  };
}

window.initEditorFromJSON = (data: EditorInitData): void => {
  log(`initEditorFromJSON received for language: ${data.language}`);

  try {
    editor?.dispose();

    const theme = ensureTheme(data.themeData);
    const container = document.getElementById("container");

    if (!container) {
      throw new Error("Editor container not found");
    }

    editor = monaco.editor.create(container, {
      value: data.content ?? "",
      language: data.language || "plaintext",
      theme,
      automaticLayout: true,
      minimap: { enabled: false },
      ...resolveEditorOptions(data.options),
      scrollBeyondLastLine: false,
    });

    editor.onDidChangeModelContent(() => {
      if (isDirty) {
        return;
      }
      isDirty = true;
      postMessage({ type: "dirty" });
    });

    editor.onDidFocusEditorWidget(() => {
      postMessage({ type: "focused" });
    });

    isDirty = false;
    log(`Editor instance created successfully with ${data.content?.length ?? 0} chars`);
  } catch (error) {
    const message =
      error instanceof Error ? `${error.message}\nStack: ${error.stack ?? ""}` : String(error);
    reportError(`Error creating editor: ${message}`);
  }
};

window.setContent = (content: string): void => {
  editor?.setValue(content);
  isDirty = false;
};

window.getContent = (): string => editor?.getValue() ?? "";

window.setTheme = (themeData: MonacoThemeData): void => {
  monaco.editor.defineTheme("boo-theme", themeData);
  monaco.editor.setTheme("boo-theme");
};

window.setEditorOptions = (options: EditorOptions): void => {
  editor?.updateOptions(resolveEditorOptions(options));
};

window.focusEditor = (): void => {
  editor?.focus();
};

log("monaco bundle loaded");
postMessage({ type: "ready" });
