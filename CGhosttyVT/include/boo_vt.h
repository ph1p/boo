// Flat wrapper over libghostty-vt for the offline recording exporter.
// Kept free of ghostty types so the Swift side never sees vt.h (whose
// names would clash with nothing today, but GhosttyKit's ghostty.h lives
// in the same Swift module graph).
#ifndef BOO_VT_H
#define BOO_VT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct BooVT BooVT;

enum {
    BOO_VT_BOLD = 1 << 0,
    BOO_VT_ITALIC = 1 << 1,
    BOO_VT_FAINT = 1 << 2,
    BOO_VT_STRIKE = 1 << 3,
    BOO_VT_OVERLINE = 1 << 4,
};

enum {
    BOO_VT_NARROW = 0,
    BOO_VT_WIDE = 1,
    BOO_VT_SPACER_TAIL = 2,
    BOO_VT_SPACER_HEAD = 3,
};

/// One grid cell. Colors are 0xRRGGBB with inverse already applied.
typedef struct {
    uint32_t text_offset;  ///< Byte offset into the frame's UTF-8 buffer.
    uint16_t text_len;     ///< 0 = nothing to draw.
    uint8_t wide;          ///< BOO_VT_NARROW...
    uint8_t flags;         ///< BOO_VT_BOLD...
    uint8_t underline;     ///< 0 none, 1 single, 2 double, 3 curly, 4 dotted, 5 dashed.
    uint8_t has_bg;        ///< bg differs from the default background.
    uint32_t fg;
    uint32_t bg;
} BooVTCell;

typedef struct {
    uint16_t cols;
    uint16_t rows;
    uint32_t fg;
    uint32_t bg;
    bool cursor_visible;
    uint16_t cursor_x;
    uint16_t cursor_y;
    uint8_t cursor_style;  ///< 0 bar, 1 block, 2 underline, 3 hollow block.
    bool cursor_wide;
    bool cursor_has_color;
    uint32_t cursor_color;
} BooVTFrame;

BooVT *boo_vt_new(uint16_t cols, uint16_t rows);
void boo_vt_free(BooVT *vt);
void boo_vt_write(BooVT *vt, const uint8_t *bytes, size_t len);
void boo_vt_resize(BooVT *vt, uint16_t cols, uint16_t rows);

/// Default colors plus the 16 ANSI entries; the rest of the 256 palette is
/// the standard xterm cube and gray ramp.
void boo_vt_set_colors(BooVT *vt, uint32_t fg, uint32_t bg, uint32_t cursor, const uint32_t *ansi16);

/// Cursor shape until the program picks one (0 bar, 1 block, 2 underline,
/// 3 hollow block).
void boo_vt_set_cursor_style(BooVT *vt, uint8_t style);

/// Whether a synchronized-output hold (mode 2026) is freezing the frame.
bool boo_vt_held(const BooVT *vt);
/// Gives up on a hold the program never released.
void boo_vt_end_hold(BooVT *vt);

/// Refreshes the render state (unless held). Returns true when anything
/// changed since the last capture.
bool boo_vt_update(BooVT *vt);

/// Grid of the last update, rows * cols cells, valid until the next call.
const BooVTCell *boo_vt_capture(BooVT *vt, BooVTFrame *frame, const char **text);

#endif
