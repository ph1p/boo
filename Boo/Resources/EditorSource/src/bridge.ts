// Types and messages shared with Swift (Boo/Content/EditorContentView.swift).

import type { ThemeData } from "./theme";

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
    setTheme: (themeData: ThemeData) => void;
    setEditorOptions: (options: EditorOptions) => void;
    setAppearance: (themeData: ThemeData, options: EditorOptions) => void;
    focusEditor: () => void;
    revealPosition: (line: number, column: number) => void;
    webkit?: {
      messageHandlers?: {
        boo?: BooMessageHandler;
      };
    };
  }

  interface WindowEventMap {
    error: ErrorEvent;
  }
}

export type FileInfo = {
  /** Base name, used to pick the language. */
  fileName?: string;
  /** Shown in the status strip. */
  encoding?: string;
};

export type EditorInitData = FileInfo & {
  content: string;
  readOnly?: boolean;
  /** Shown above the editor, e.g. why the file can't be edited. */
  notice?: string;
  themeData?: ThemeData;
  options?: EditorOptions;
};

export type EditorOptions = {
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

export type SaveOptions = {
  format?: boolean;
  trimTrailingWhitespace?: boolean;
  insertFinalNewline?: boolean;
};

export type SavePayload = {
  content: string;
  /** Pass back to markClean once written. */
  version: number;
};

export type Banner = {
  id: string;
  message: string;
  actions: { id: string; label: string }[];
};

export type BooMessage =
  | { type: "log"; message: string }
  | { type: "error"; message: string }
  | { type: "ready" }
  | { type: "dirty"; dirty: boolean }
  | { type: "changed" }
  | { type: "focused" }
  | { type: "blurred" }
  | { type: "bannerAction"; id: string; action: string };

export function postMessage(message: BooMessage): void {
  window.webkit?.messageHandlers?.boo?.postMessage(message);
}

export function log(message: string): void {
  postMessage({ type: "log", message });
}

export function reportError(message: string): void {
  postMessage({ type: "error", message });
}

export function element<T extends HTMLElement>(id: string): T {
  const el = document.getElementById(id);
  if (!el) throw new Error(`#${id} not found`);
  return el as T;
}
