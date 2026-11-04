// Language server support. Swift (EditorLanguageServer.swift) starts the
// server and relays JSON-RPC messages; this side runs @codemirror/lsp-client
// over that relay. Without a server on the user's PATH none of this loads.

import {
  LSPClient,
  LSPPlugin,
  type Transport,
  Workspace,
  type WorkspaceFile,
  findReferencesKeymap,
  hoverTooltips,
  serverCompletion,
  serverDiagnostics,
  signatureHelp,
} from "@codemirror/lsp-client";
import { ChangeSet, type Extension, Prec, type Text } from "@codemirror/state";
import { type EditorView, keymap } from "@codemirror/view";
import { postMessage } from "./bridge";
import type { Indent } from "./indent";

export type LspTarget = {
  /** file:// URI of the edited file. */
  uri: string;
  /** file:// URI of the project root the server runs in. */
  rootUri: string;
  /** LSP language identifier, e.g. "typescriptreact". */
  languageId: string;
};

type Handler = (message: string) => void;
const handlers = new Set<Handler>();

const transport: Transport = {
  send: (message) => postMessage({ type: "lsp", message }),
  subscribe: (handler) => handlers.add(handler),
  unsubscribe: (handler) => handlers.delete(handler),
};

/** Messages from the server, relayed by Swift. */
export function receive(message: string): void {
  for (const handler of handlers) handler(message);
}

// MARK: - Workspace

class BooFile implements WorkspaceFile {
  constructor(
    readonly uri: string,
    readonly languageId: string,
    public version: number,
    public doc: Text,
    readonly view: EditorView,
  ) {}
  getView(): EditorView {
    return this.view;
  }
}

/** Holds the one file this page edits. Files elsewhere open as Boo tabs. */
class BooWorkspace extends Workspace {
  files: BooFile[] = [];
  private versions: Record<string, number> = Object.create(null);

  private nextVersion(uri: string): number {
    this.versions[uri] = (this.versions[uri] ?? -1) + 1;
    return this.versions[uri];
  }

  syncFiles() {
    const result = [];
    for (const file of this.files) {
      const plugin = LSPPlugin.get(file.view);
      if (!plugin || plugin.unsyncedChanges.empty) continue;
      result.push({ changes: plugin.unsyncedChanges, file, prevDoc: file.doc });
      file.doc = file.view.state.doc;
      file.version = this.nextVersion(file.uri);
      plugin.clear();
    }
    return result;
  }

  openFile(uri: string, languageId: string, view: EditorView): void {
    if (this.getFile(uri)) return;
    const file = new BooFile(uri, languageId, this.nextVersion(uri), view.state.doc, view);
    this.files.push(file);
    this.client.didOpen(file);
  }

  closeFile(uri: string): void {
    const file = this.getFile(uri);
    if (!file) return;
    this.files = this.files.filter((f) => f !== file);
    this.client.didClose(uri);
  }
}

// MARK: - Commands

type Position = { line: number; character: number };
type Range = { start: Position; end: Position };
type Location = { uri: string; range: Range };
type LocationLink = { targetUri: string; targetSelectionRange: Range };

/** Jumps to the definition, opening it in a Boo tab when it is in another file. */
function goToDefinition(view: EditorView): boolean {
  const plugin = LSPPlugin.get(view);
  const capabilities = plugin?.client.serverCapabilities;
  if (!plugin || (capabilities && !capabilities.definitionProvider)) return false;
  plugin.client.sync();
  plugin.client
    .request<unknown, Location | Location[] | LocationLink[] | null>("textDocument/definition", {
      textDocument: { uri: plugin.uri },
      position: plugin.toPosition(view.state.selection.main.head),
    })
    .then(
      (response) => {
        const found = Array.isArray(response) ? response[0] : response;
        if (!found) return;
        const uri = "targetUri" in found ? found.targetUri : found.uri;
        const { start } = "targetUri" in found ? found.targetSelectionRange : found.range;
        if (uri === plugin.uri) {
          const pos = plugin.fromPosition(start, view.state.doc);
          view.dispatch({
            selection: { anchor: pos },
            scrollIntoView: true,
            userEvent: "select.definition",
          });
        } else {
          postMessage({
            type: "openFile",
            uri,
            line: start.line + 1,
            column: start.character + 1,
          });
        }
      },
      (error) => plugin.reportError("Go to definition failed", error),
    );
  return true;
}

type TextEdit = { range: Range; newText: string };

/** The server's formatting of the document, or null when it has none. */
export async function formatWithServer(view: EditorView, indent: Indent): Promise<string | null> {
  const plugin = LSPPlugin.get(view);
  if (!plugin || !plugin.client.connected) return null;
  await plugin.client.initializing;
  if (!plugin.client.serverCapabilities?.documentFormattingProvider) return null;
  plugin.client.sync();
  const doc = plugin.syncedDoc;
  const edits = await plugin.client.request<unknown, TextEdit[] | null>("textDocument/formatting", {
    textDocument: { uri: plugin.uri },
    options: { tabSize: indent.tabSize, insertSpaces: indent.insertSpaces },
  });
  if (!edits) return null;
  const changes = edits
    .map((edit) => ({
      from: plugin.fromPosition(edit.range.start, doc),
      to: plugin.fromPosition(edit.range.end, doc),
      insert: edit.newText,
    }))
    .sort((a, b) => a.from - b.from);
  return ChangeSet.of(changes, doc.length).apply(doc).toString();
}

// MARK: - Client

let client: LSPClient | null = null;
let target: LspTarget | null = null;

export function connect(next: LspTarget): void {
  disconnect();
  target = next;
  client = new LSPClient({
    rootUri: next.rootUri,
    workspace: (c) => new BooWorkspace(c),
    timeout: 5000,
    extensions: [
      serverCompletion({ override: true }),
      hoverTooltips(),
      signatureHelp(),
      serverDiagnostics(),
    ],
    // Server logs go to Boo's log via Swift, not into the editor.
    notificationHandlers: {
      "window/logMessage": () => true,
      "window/showMessage": () => true,
    },
  }).connect(transport);
}

export function disconnect(): void {
  client?.disconnect();
  client = null;
  target = null;
}

export function isConnected(): boolean {
  return client !== null;
}

/** The editor extension for the connected server; empty without one. */
export function lspExtension(): Extension {
  if (!client || !target) return [];
  return [
    client.plugin(target.uri, target.languageId),
    Prec.high(keymap.of([{ key: "F12", run: goToDefinition }, ...findReferencesKeymap])),
  ];
}
