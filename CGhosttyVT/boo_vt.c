#include "boo_vt.h"

#include <ghostty/vt.h>
#include <stdlib.h>
#include <string.h>

struct BooVT {
    GhosttyTerminal terminal;
    GhosttyRenderState state;
    GhosttyRenderStateRowIterator rows;
    GhosttyRenderStateRowCells cells;
    bool held;
    bool changed;
    // Cursor moves alone may not mark rows dirty.
    GhosttyRenderStateCursor last_cursor;

    BooVTCell *grid;
    size_t grid_cap;
    char *text;
    size_t text_cap;
    size_t text_len;
};

static uint32_t pack(GhosttyColorRgb c) {
    return ((uint32_t)c.r << 16) | ((uint32_t)c.g << 8) | c.b;
}

static GhosttyColorRgb unpack(uint32_t v) {
    GhosttyColorRgb c = {(uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v};
    return c;
}

static void on_render_hold(GhosttyTerminal terminal, void *userdata, bool held) {
    BooVT *vt = userdata;
    if (held) {
        // The frame the program wants left on screen.
        ghostty_render_state_update(vt->state, terminal);
        vt->changed = true;
    }
    vt->held = held;
}

BooVT *boo_vt_new(uint16_t cols, uint16_t rows) {
    BooVT *vt = calloc(1, sizeof(BooVT));
    if (!vt) return NULL;
    if (ghostty_terminal_new(NULL, &vt->terminal, cols, rows) != GHOSTTY_SUCCESS
        || ghostty_render_state_new(NULL, &vt->state) != GHOSTTY_SUCCESS
        || ghostty_render_state_row_iterator_new(NULL, &vt->rows) != GHOSTTY_SUCCESS
        || ghostty_render_state_row_cells_new(NULL, &vt->cells) != GHOSTTY_SUCCESS) {
        boo_vt_free(vt);
        return NULL;
    }
    ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_USERDATA, vt);
    ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_RENDER_HOLD, (const void *)on_render_hold);
    vt->changed = true;
    return vt;
}

void boo_vt_free(BooVT *vt) {
    if (!vt) return;
    if (vt->cells) ghostty_render_state_row_cells_free(vt->cells);
    if (vt->rows) ghostty_render_state_row_iterator_free(vt->rows);
    if (vt->state) ghostty_render_state_free(vt->state);
    if (vt->terminal) ghostty_terminal_free(vt->terminal);
    free(vt->grid);
    free(vt->text);
    free(vt);
}

void boo_vt_write(BooVT *vt, const uint8_t *bytes, size_t len) {
    ghostty_terminal_vt_write(vt->terminal, bytes, len);
}

void boo_vt_resize(BooVT *vt, uint16_t cols, uint16_t rows) {
    // Pixel size only matters for size reports; nobody reads them here.
    ghostty_terminal_resize(vt->terminal, cols, rows, 8, 16);
}

void boo_vt_set_colors(BooVT *vt, uint32_t fg, uint32_t bg, uint32_t cursor, const uint32_t *ansi16) {
    GhosttyColorRgb f = unpack(fg), b = unpack(bg), c = unpack(cursor);
    ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &f);
    ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &b);
    ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &c);

    GhosttyColorRgb palette[256];
    for (int i = 0; i < 16; i++) palette[i] = unpack(ansi16[i]);
    static const uint8_t steps[6] = {0, 95, 135, 175, 215, 255};
    for (int i = 0; i < 216; i++) {
        GhosttyColorRgb v = {steps[i / 36], steps[(i / 6) % 6], steps[i % 6]};
        palette[16 + i] = v;
    }
    for (int i = 0; i < 24; i++) {
        uint8_t g = (uint8_t)(8 + i * 10);
        GhosttyColorRgb v = {g, g, g};
        palette[232 + i] = v;
    }
    ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, palette);
    vt->changed = true;
}

void boo_vt_set_cursor_style(BooVT *vt, uint8_t style) {
    GhosttyTerminalCursorStyle s = (GhosttyTerminalCursorStyle)style;
    ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE, &s);
    // The default only applies on a DECSCUSR reset; apply it now.
    static const uint8_t reset[] = "\x1b[0 q";
    ghostty_terminal_vt_write(vt->terminal, reset, sizeof(reset) - 1);
}

bool boo_vt_held(const BooVT *vt) { return vt->held; }

void boo_vt_end_hold(BooVT *vt) {
    if (!vt->held) return;
    GhosttyTerminalModeConfig mode = {.mode = GHOSTTY_MODE_SYNC_OUTPUT, .value = false};
    ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_MODE, &mode);
    vt->held = false;
}

bool boo_vt_update(BooVT *vt) {
    if (!vt->held) ghostty_render_state_update(vt->state, vt->terminal);
    GhosttyRenderStateDirty dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE;
    ghostty_render_state_get(vt->state, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty);
    GhosttyRenderStateCursor cursor = {.size = sizeof(GhosttyRenderStateCursor)};
    ghostty_render_state_get(vt->state, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor);
    bool moved = cursor.visible != vt->last_cursor.visible
        || cursor.viewport_has_value != vt->last_cursor.viewport_has_value
        || cursor.viewport_x != vt->last_cursor.viewport_x
        || cursor.viewport_y != vt->last_cursor.viewport_y
        || cursor.visual_style != vt->last_cursor.visual_style;
    bool changed = vt->changed || moved || dirty != GHOSTTY_RENDER_STATE_DIRTY_FALSE;
    vt->changed = false;
    return changed;
}

static bool reserve_text(BooVT *vt, size_t extra) {
    if (vt->text_len + extra <= vt->text_cap) return true;
    size_t cap = vt->text_cap ? vt->text_cap : 4096;
    while (cap < vt->text_len + extra) cap *= 2;
    char *next = realloc(vt->text, cap);
    if (!next) return false;
    vt->text = next;
    vt->text_cap = cap;
    return true;
}

static void read_text(BooVT *vt, BooVTCell *out) {
    out->text_offset = (uint32_t)vt->text_len;
    out->text_len = 0;
    if (!reserve_text(vt, 16)) return;
    GhosttyBuffer buf = {.ptr = (uint8_t *)vt->text + vt->text_len, .cap = vt->text_cap - vt->text_len, .len = 0};
    GhosttyResult r = ghostty_render_state_row_cells_get(vt->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &buf);
    if (r == GHOSTTY_OUT_OF_SPACE) {
        if (!reserve_text(vt, buf.len)) return;
        buf.ptr = (uint8_t *)vt->text + vt->text_len;
        buf.cap = vt->text_cap - vt->text_len;
        r = ghostty_render_state_row_cells_get(vt->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &buf);
    }
    if (r != GHOSTTY_SUCCESS || buf.len > UINT16_MAX) return;
    out->text_len = (uint16_t)buf.len;
    vt->text_len += buf.len;
}

const BooVTCell *boo_vt_capture(BooVT *vt, BooVTFrame *frame, const char **text) {
    memset(frame, 0, sizeof(*frame));
    *text = NULL;

    uint16_t cols = 0, rows = 0;
    ghostty_render_state_get(vt->state, GHOSTTY_RENDER_STATE_DATA_COLS, &cols);
    ghostty_render_state_get(vt->state, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows);
    frame->cols = cols;
    frame->rows = rows;

    GhosttyRenderStateColors colors = {.size = sizeof(GhosttyRenderStateColors)};
    ghostty_render_state_get(vt->state, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors);
    uint32_t def_fg = pack(colors.foreground), def_bg = pack(colors.background);
    frame->fg = def_fg;
    frame->bg = def_bg;
    frame->cursor_has_color = colors.cursor_has_value;
    frame->cursor_color = colors.cursor_has_value ? pack(colors.cursor) : def_fg;

    GhosttyRenderStateCursor cursor = {.size = sizeof(GhosttyRenderStateCursor)};
    ghostty_render_state_get(vt->state, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor);
    frame->cursor_visible = cursor.visible && cursor.viewport_has_value;
    frame->cursor_x = cursor.viewport_x;
    frame->cursor_y = cursor.viewport_y;
    frame->cursor_style = (uint8_t)cursor.visual_style;
    frame->cursor_wide = cursor.wide_tail;

    size_t count = (size_t)cols * rows;
    if (count > vt->grid_cap) {
        BooVTCell *next = realloc(vt->grid, count * sizeof(BooVTCell));
        if (!next) return NULL;
        vt->grid = next;
        vt->grid_cap = count;
    }
    memset(vt->grid, 0, count * sizeof(BooVTCell));
    vt->text_len = 0;

    if (ghostty_render_state_get(vt->state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &vt->rows) != GHOSTTY_SUCCESS)
        return NULL;
    uint16_t y = 0;
    while (y < rows && ghostty_render_state_row_iterator_next(vt->rows)) {
        if (ghostty_render_state_row_get(vt->rows, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &vt->cells) != GHOSTTY_SUCCESS) {
            y++;
            continue;
        }
        uint16_t x = 0;
        while (x < cols && ghostty_render_state_row_cells_next(vt->cells)) {
            BooVTCell *out = &vt->grid[(size_t)y * cols + x];
            x++;

            GhosttyCell raw = 0;
            GhosttyCellWide wide = GHOSTTY_CELL_WIDE_NARROW;
            if (ghostty_render_state_row_cells_get(vt->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw) == GHOSTTY_SUCCESS)
                ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide);
            out->wide = (uint8_t)wide;

            GhosttyStyle style = {.size = sizeof(GhosttyStyle)};
            ghostty_render_state_row_cells_get(vt->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style);

            GhosttyColorRgb c;
            bool has_fg = ghostty_render_state_row_cells_get(vt->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &c) == GHOSTTY_SUCCESS;
            uint32_t fg = has_fg ? pack(c) : def_fg;
            bool has_bg = ghostty_render_state_row_cells_get(vt->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &c) == GHOSTTY_SUCCESS;
            uint32_t bg = has_bg ? pack(c) : def_bg;
            if (style.inverse) {
                uint32_t t = fg;
                fg = bg;
                bg = t;
                has_bg = true;
            }
            out->fg = fg;
            out->bg = bg;
            out->has_bg = has_bg && bg != def_bg;

            uint8_t flags = 0;
            if (style.bold) flags |= BOO_VT_BOLD;
            if (style.italic) flags |= BOO_VT_ITALIC;
            if (style.faint) flags |= BOO_VT_FAINT;
            if (style.strikethrough) flags |= BOO_VT_STRIKE;
            if (style.overline) flags |= BOO_VT_OVERLINE;
            out->flags = flags;
            out->underline = (uint8_t)style.underline;

            if (!style.invisible && wide != GHOSTTY_CELL_WIDE_SPACER_TAIL && wide != GHOSTTY_CELL_WIDE_SPACER_HEAD)
                read_text(vt, out);
        }
        y++;
    }

    // Next update reports only what changed after this capture.
    ghostty_render_state_clean(vt->state);
    vt->last_cursor = cursor;
    *text = vt->text;
    return vt->grid;
}
