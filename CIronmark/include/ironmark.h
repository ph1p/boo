#ifndef IRONMARK_H
#define IRONMARK_H

#ifdef __cplusplus
extern "C" {
#endif

/// Render markdown input and return a heap-allocated HTML string.
/// Returns NULL if input is NULL or contains invalid UTF-8.
/// Caller must free the result with ironmark_free().
char* ironmark_render_html(const char* input);

/// Free a string returned by ironmark_render_html().
void ironmark_free(char* ptr);

#ifdef __cplusplus
}
#endif

#endif
