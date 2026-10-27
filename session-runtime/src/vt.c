#include <ghostty/vt.h>
#include <stdlib.h>
#include <string.h>

typedef void (*Reply)(void *, const unsigned char *, size_t);
typedef struct { GhosttyTerminal terminal; Reply reply; void *context; } Vt;
static void reply(GhosttyTerminal terminal, void *context, const uint8_t *bytes, size_t len) {
    (void)terminal;
    Vt *vt = context;
    if (vt->reply) vt->reply(vt->context, bytes, len);
}
void *omg_vt_new(unsigned short cols, unsigned short rows, Reply callback, void *context) {
    Vt *vt = calloc(1, sizeof(*vt));
    if (!vt) return NULL;
    if (ghostty_terminal_new(NULL, &vt->terminal, cols, rows) != GHOSTTY_SUCCESS) { free(vt); return NULL; }
    size_t continuation = 1024 * 1024, history = 4 * 1024 * 1024;
    vt->reply = callback; vt->context = context;
    if (ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, &continuation) != GHOSTTY_SUCCESS ||
        ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &history) != GHOSTTY_SUCCESS ||
        ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_USERDATA, vt) != GHOSTTY_SUCCESS ||
        ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, (const void *)reply) != GHOSTTY_SUCCESS) {
        ghostty_terminal_free(vt->terminal); free(vt); return NULL;
    }
    return vt;
}
void omg_vt_free(Vt *vt) { ghostty_terminal_free(vt->terminal); free(vt); }
void omg_vt_write(Vt *vt, const unsigned char *data, size_t len) { ghostty_terminal_vt_write(vt->terminal, data, len); }
int omg_vt_resize(Vt *vt, unsigned short cols, unsigned short rows) { return ghostty_terminal_resize(vt->terminal, cols, rows, 8, 16); }
int omg_vt_snapshot(Vt *vt, unsigned char **data, size_t *len) { return ghostty_snapshot_encode_alloc(vt->terminal, NULL, data, len); }
void omg_vt_buffer_free(unsigned char *data, size_t len) { ghostty_free(NULL, data, len); }
int omg_vt_restore(Vt *vt, const unsigned char *data, size_t len) {
    GhosttySnapshotDecoder decoder = NULL;
    GhosttyTerminal terminal = NULL;
    int result = ghostty_snapshot_decoder_new_buf(NULL, &decoder, data, len);
    if (result) return result;
    bool retain = true;
    size_t limit = 1024 * 1024;
    result = ghostty_snapshot_decoder_set(decoder, GHOSTTY_SNAPSHOT_DECODER_OPT_MAX_CONTINUATION_BYTES, &limit);
    if (!result) result = ghostty_snapshot_decoder_set(decoder, GHOSTTY_SNAPSHOT_DECODER_OPT_RETAIN_CONTINUATION, &retain);
    if (!result) result = ghostty_snapshot_decoder_decode(decoder, &terminal);
    size_t consumed = 0;
    if (!result) result = ghostty_snapshot_decoder_get(decoder, GHOSTTY_SNAPSHOT_DECODER_DATA_SOURCE_OFFSET, &consumed);
    ghostty_snapshot_decoder_free(decoder);
    if (result || consumed != len) { if (terminal) ghostty_terminal_free(terminal); return result ? result : -1; }
    ghostty_terminal_free(vt->terminal); vt->terminal = terminal;
    return 0;
}
int omg_vt_text(Vt *vt, unsigned char **data, size_t *len) {
    GhosttyFormatter formatter = NULL;
    GhosttyFormatterTerminalOptions opts = {0};
    opts.size = sizeof(opts); opts.trim = true;
    int result = ghostty_formatter_terminal_new(NULL, &formatter, vt->terminal, opts);
    if (result) return result;
    result = ghostty_formatter_format_alloc(formatter, NULL, data, len);
    ghostty_formatter_free(formatter);
    return result;
}
