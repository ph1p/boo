// The editor's find/replace panel, laid out like Boo's native find bar
// (FindBarView.swift): a rounded field with a magnifier, the match count and
// a clear button inside, a joined previous/next stepper and a Done button.
// Colors are Boo's chrome tokens (see searchPanelTheme in theme.ts).

import {
  SearchQuery,
  closeSearchPanel,
  findNext,
  findPrevious,
  getSearchQuery,
  replaceAll,
  replaceNext,
  selectMatches,
  setSearchQuery,
} from "@codemirror/search";
import type { EditorState } from "@codemirror/state";
import { type EditorView, type Panel, type ViewUpdate, runScopeHandlers } from "@codemirror/view";

/** Counting stops here so huge files stay responsive while typing. */
const MAX_COUNT = 9999;

const svg = (body: string, size = 12) =>
  `<svg viewBox="0 0 16 16" width="${size}" height="${size}" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">${body}</svg>`;

const ICONS = {
  search: svg('<circle cx="7" cy="7" r="4.5"/><path d="M10.5 10.5L14 14"/>', 13),
  replace: svg('<path d="M3 4.5h7a3 3 0 0 1 0 6H5"/><path d="M7 8l-2.5 2.5L7 13"/>', 13),
  prev: svg('<path d="M10 3.5L5.5 8l4.5 4.5"/>', 11),
  next: svg('<path d="M6 3.5L10.5 8 6 12.5"/>', 11),
  clear:
    '<svg viewBox="0 0 16 16" width="13" height="13"><circle cx="8" cy="8" r="7" fill="currentColor"/><path d="M5.5 5.5l5 5M10.5 5.5l-5 5" stroke="var(--boo-search-clear-x)" stroke-width="1.5" stroke-linecap="round"/></svg>',
};

function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  className: string,
  ...children: (Node | string)[]
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  node.className = className;
  node.append(...children);
  return node;
}

function button(className: string, title: string, onClick: () => void): HTMLButtonElement {
  const b = el("button", className);
  b.type = "button";
  b.title = title;
  b.setAttribute("aria-label", title);
  // Keep focus in the field, like the native bar's buttons.
  b.addEventListener("mousedown", (e) => e.preventDefault());
  b.addEventListener("click", onClick);
  return b;
}

function glyph(className: string, icon: keyof typeof ICONS, title: string, onClick: () => void) {
  const b = button(className, title, onClick);
  b.innerHTML = ICONS[icon];
  return b;
}

function push(label: string, title: string, onClick: () => void): HTMLButtonElement {
  const b = button("boo-search-push", title, onClick);
  b.textContent = label;
  return b;
}

function toggle(label: string, title: string, onChange: () => void): HTMLButtonElement {
  const b = button("boo-search-toggle", title, () => {
    setOn(b, !isOn(b));
    onChange();
  });
  b.textContent = label;
  setOn(b, false);
  return b;
}

const isOn = (b: HTMLElement) => b.getAttribute("aria-pressed") === "true";
const setOn = (b: HTMLElement, on: boolean) => b.setAttribute("aria-pressed", String(on));

function input(placeholder: string, name: string): HTMLInputElement {
  const field = el("input", "boo-search-input");
  field.placeholder = placeholder;
  field.name = name;
  field.spellcheck = false;
  field.autocomplete = "off";
  field.setAttribute("aria-label", placeholder);
  field.setAttribute("form", "");
  return field;
}

/** Match count and the index of the match the selection sits on. */
function countMatches(state: EditorState, query: SearchQuery): { total: number; current: number } {
  const sel = state.selection.main;
  const cursor = query.getCursor(state);
  let total = 0;
  let current = 0;
  for (let next = cursor.next(); !next.done; next = cursor.next()) {
    total++;
    if (next.value.from === sel.from && next.value.to === sel.to) current = total;
    if (total > MAX_COUNT) break;
  }
  return { total, current };
}

class BooSearchPanel implements Panel {
  dom: HTMLElement;
  top = true;
  private query: SearchQuery;
  private searchField = input("Find", "search");
  private replaceField = input("Replace", "replace");
  private caseToggle: HTMLButtonElement;
  private wordToggle: HTMLButtonElement;
  private reToggle: HTMLButtonElement;
  private replaceToggle: HTMLButtonElement;
  private count = el("span", "boo-search-count");
  private clear: HTMLButtonElement;
  private findBox: HTMLElement;
  private stepper: HTMLElement;
  private countTimer = 0;

  constructor(private view: EditorView) {
    this.query = getSearchQuery(view.state);
    const commit = () => this.commit();
    const readOnly = view.state.readOnly;

    this.searchField.setAttribute("main-field", "true");
    this.searchField.addEventListener("input", commit);
    this.replaceField.addEventListener("input", commit);

    this.caseToggle = toggle("Aa", "Match Case", commit);
    this.wordToggle = toggle("ab", "Whole Word", commit);
    this.wordToggle.classList.add("boo-search-word");
    this.reToggle = toggle(".*", "Regular Expression", commit);
    this.replaceToggle = glyph("boo-search-toggle", "replace", "Replace", () =>
      this.showReplace(!isOn(this.replaceToggle)),
    );
    setOn(this.replaceToggle, false);
    this.replaceToggle.hidden = readOnly;

    this.clear = glyph("boo-search-clear", "clear", "Clear Search", () => {
      this.searchField.value = "";
      this.commit();
      this.searchField.focus();
    });

    this.findBox = el(
      "div",
      "boo-search-field",
      el("span", "boo-search-glyph", ""),
      this.searchField,
      this.count,
      this.clear,
      el("span", "boo-search-sep"),
      this.caseToggle,
      this.wordToggle,
      this.reToggle,
      this.replaceToggle,
    );
    (this.findBox.firstChild as HTMLElement).innerHTML = ICONS.search;

    this.stepper = el(
      "div",
      "boo-search-stepper",
      glyph("boo-search-segment", "prev", "Previous Match (⇧↩)", () => findPrevious(view)),
      el("span", "boo-search-divider"),
      glyph("boo-search-segment", "next", "Next Match (↩)", () => findNext(view)),
    );

    const replaceBox = el(
      "div",
      "boo-search-field boo-search-replace",
      el("span", "boo-search-glyph", ""),
      this.replaceField,
    );
    (replaceBox.firstChild as HTMLElement).innerHTML = ICONS.replace;

    // Grid: fields stretch, buttons sit right. The replace row's buttons share
    // the stepper's and Done's columns, so both rows line up.
    this.dom = el(
      "div",
      "boo-search collapsed",
      this.findBox,
      this.stepper,
      push("Done", "Close Find Bar (Esc)", () => closeSearchPanel(view)),
      replaceBox,
      el(
        "div",
        "boo-search-stepper boo-search-replace",
        button("boo-search-segment boo-search-label", "Replace (↩)", () => replaceNext(view)),
        el("span", "boo-search-divider"),
        button("boo-search-segment boo-search-label", "Replace All (⌘↩)", () => replaceAll(view)),
      ),
    );
    const [one, all] = this.dom.querySelectorAll(".boo-search-label");
    one.textContent = "Replace";
    all.textContent = "All";
    this.dom.addEventListener("keydown", (e) => this.keydown(e));

    this.setQuery(this.query);
    this.showReplace(!readOnly && this.query.replace.length > 0, false);
  }

  mount(): void {
    this.searchField.select();
    this.scheduleCount();
  }

  destroy(): void {
    clearTimeout(this.countTimer);
  }

  update(update: ViewUpdate): void {
    for (const tr of update.transactions) {
      for (const effect of tr.effects) {
        if (effect.is(setSearchQuery) && !effect.value.eq(this.query)) this.setQuery(effect.value);
      }
    }
    if (update.docChanged || update.selectionSet || update.transactions.length) {
      this.scheduleCount();
    }
  }

  private showReplace(show: boolean, focus = true): void {
    if (this.view.state.readOnly) show = false;
    this.dom.classList.toggle("collapsed", !show);
    setOn(this.replaceToggle, show);
    if (focus) (show ? this.replaceField : this.searchField).focus({ preventScroll: true });
  }

  private commit(): void {
    const query = new SearchQuery({
      search: this.searchField.value,
      caseSensitive: isOn(this.caseToggle),
      regexp: isOn(this.reToggle),
      wholeWord: isOn(this.wordToggle),
      replace: this.replaceField.value,
    });
    if (!query.eq(this.query)) {
      this.query = query;
      this.view.dispatch({ effects: setSearchQuery.of(query) });
    }
  }

  private setQuery(query: SearchQuery): void {
    this.query = query;
    this.searchField.value = query.search;
    this.replaceField.value = query.replace;
    setOn(this.caseToggle, query.caseSensitive);
    setOn(this.reToggle, query.regexp);
    setOn(this.wordToggle, query.wholeWord);
  }

  private scheduleCount(): void {
    clearTimeout(this.countTimer);
    this.countTimer = window.setTimeout(() => this.renderCount(), 30);
  }

  private renderCount(): void {
    const query = this.query;
    const empty = query.search === "";
    const invalid = !empty && !query.valid;
    const { total, current } =
      empty || invalid ? { total: -1, current: 0 } : countMatches(this.view.state, query);
    const shown = total > MAX_COUNT ? `${MAX_COUNT}+` : String(total);
    this.count.textContent = invalid
      ? "Invalid"
      : total < 0
        ? ""
        : total === 0
          ? "No results"
          : current
            ? `${current} of ${shown}`
            : shown;
    this.findBox.classList.toggle("error", invalid || total === 0);
    this.clear.hidden = empty;
    this.stepper.classList.toggle("disabled", total <= 0);
  }

  private keydown(e: KeyboardEvent): void {
    if (runScopeHandlers(this.view, e, "search-panel")) {
      e.preventDefault();
      return;
    }
    if (e.key !== "Enter") return;
    if (e.target === this.searchField) {
      e.preventDefault();
      if (e.altKey) selectMatches(this.view);
      else (e.shiftKey ? findPrevious : findNext)(this.view);
    } else if (e.target === this.replaceField) {
      e.preventDefault();
      (e.metaKey ? replaceAll : replaceNext)(this.view);
    }
  }
}

export const createSearchPanel = (view: EditorView): Panel => new BooSearchPanel(view);
