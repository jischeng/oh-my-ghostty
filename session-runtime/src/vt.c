#include <ghostty/vt.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef __APPLE__
#include <libproc.h>
#include <sys/sysctl.h>
#include <unistd.h>
int omg_process_cwd(int pid, unsigned char *buffer, size_t capacity) {
    struct proc_vnodepathinfo info;
    int result = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, sizeof(info));
    if (result != sizeof(info)) return -1;
    size_t len = strnlen(info.pvi_cdir.vip_path, sizeof(info.pvi_cdir.vip_path));
    if (len >= capacity) return -1;
    memcpy(buffer, info.pvi_cdir.vip_path, len);
    return (int)len;
}
int omg_group_pids(int pgid, int *pids, size_t capacity) {
    if (pgid <= 1 || !pids || capacity == 0) return -1;
    int bytes = proc_listpids(PROC_PGRP_ONLY, (uint32_t)pgid, pids, (int)(capacity * sizeof(int)));
    if (bytes < 0) return -1;
    return bytes / (int)sizeof(int);
}
int omg_tty_foreground_pgid(int pid) {
    if (pid <= 1) return -1;
    struct proc_bsdinfo info;
    int result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    if (result != sizeof(info)) return -1;
    if (info.e_tdev == 0 || info.e_tdev == (uint32_t)-1) return -1;
    int pgid = (int)info.e_tpgid;
    return pgid > 1 ? pgid : -1;
}
int omg_session_pids(int leader, int *pids, size_t capacity) {
    if (leader <= 1 || !pids || capacity == 0) return -1;
    int total_bytes = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (total_bytes <= 0) return -1;
    size_t max_count = (size_t)(total_bytes / (int)sizeof(int)) + 64;
    if (max_count > 16384) max_count = 16384;
    int *all = calloc(max_count, sizeof(int));
    if (!all) return -1;
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, all, (int)(max_count * sizeof(int)));
    if (bytes <= 0) {
        free(all);
        return -1;
    }
    int count = bytes / (int)sizeof(int);
    size_t out = 0;
    for (int i = 0; i < count && out < capacity; i++) {
        int pid = all[i];
        if (pid > 1 && getsid(pid) == leader) {
            pids[out++] = pid;
        }
    }
    free(all);
    return (int)out;
}
int omg_process_args(int pid, unsigned char *buffer, size_t capacity) {
    if (pid <= 1 || !buffer || capacity < sizeof(int)) return -1;
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
    size_t size = capacity;
    if (sysctl(mib, 3, buffer, &size, NULL, 0) != 0 || size < sizeof(int)) {
        return -1;
    }
    return (int)size;
}
int omg_process_path(int pid, unsigned char *buffer, size_t capacity) {
    if (pid <= 1 || !buffer || capacity < PROC_PIDPATHINFO_MAXSIZE) return -1;
    int len = proc_pidpath(pid, buffer, (uint32_t)capacity);
    return len > 0 ? len : -1;
}
int omg_process_bsdinfo(int pid, int *ppid_out, unsigned int *uid_out, int *pgid_out, int *zombie_out) {
    if (pid <= 1) return -1;
    struct proc_bsdinfo info;
    int result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    if (result != sizeof(info)) return -1;
    if (ppid_out) *ppid_out = (int)info.pbi_ppid;
    if (uid_out) *uid_out = (unsigned int)info.pbi_uid;
    if (pgid_out) *pgid_out = (int)info.pbi_pgid;
    if (zombie_out) *zombie_out = (info.pbi_status == SZOMB) ? 1 : 0;
    return 0;
}
#endif

typedef void (*Reply)(void *, const unsigned char *, size_t);
typedef void (*Context)(void *, bool, const uint8_t *, size_t, const uint8_t *, size_t);
typedef struct {
    GhosttyTerminal terminal;
    Reply reply;
    void *context;
    Context signal;
    void *signal_context;
    size_t continuation_max_bytes;
    size_t scrollback_max_bytes;
    bool has_scrollback_max_lines;
    size_t scrollback_max_lines;
    unsigned short cols;
    unsigned short rows;
    unsigned short cell_width;
    unsigned short cell_height;
    char xtversion[128];
    size_t xtversion_len;
    char terminfo_name[128];
    size_t terminfo_name_len;
    bool has_color_scheme;
    GhosttyColorScheme color_scheme;
    bool has_fg;
    GhosttyColorRgb fg;
    bool has_bg;
    GhosttyColorRgb bg;
    bool has_cursor;
    GhosttyColorRgb cursor;
} Vt;
static const size_t OMG_VT_UNKNOWN_MAX_BYTES = 4096;

static void context_signal(GhosttyTerminal terminal, void *context, bool ended,
                           GhosttyString id, GhosttyString metadata) {
    (void)terminal;
    Vt *vt = context;
    if (vt->signal) vt->signal(vt->signal_context, ended,
        (const uint8_t *)id.ptr, id.len, (const uint8_t *)metadata.ptr, metadata.len);
}
static void unknown_sequence(GhosttyTerminal terminal, void *context,
                             const GhosttyTerminalUnknownSequence *sequence) {
    (void)terminal;
    Vt *vt = context;
    if (!vt || !vt->signal || !sequence) return;
    if (sequence->tag != GHOSTTY_TERMINAL_UNKNOWN_SEQUENCE_OSC) return;
    const GhosttyTerminalUnknownOscSequence *osc = &sequence->value.osc;
    if (osc->truncated || !osc->content.ptr || osc->content.len <= 3) return;
    if (osc->content.len > OMG_VT_UNKNOWN_MAX_BYTES) return;
    if (memcmp(osc->content.ptr, "26;", 3) != 0) return;
    static const uint8_t id[] = "omg-osc26";
    vt->signal(vt->signal_context, false, id, sizeof(id) - 1,
               (const uint8_t *)osc->content.ptr + 3, osc->content.len - 3);
}
int omg_vt_context(Vt *vt, Context callback, void *context) {
    vt->signal = callback;
    vt->signal_context = context;
    int result = ghostty_terminal_set(
        vt->terminal, GHOSTTY_TERMINAL_OPT_CONTEXT_SIGNAL, (const void *)context_signal);
    if (!result) {
        size_t unknown_max_bytes = callback ? OMG_VT_UNKNOWN_MAX_BYTES : 0;
        result = ghostty_terminal_set(
            vt->terminal, GHOSTTY_TERMINAL_OPT_UNKNOWN_MAX_BYTES, &unknown_max_bytes);
    }
    if (!result) {
        result = ghostty_terminal_set(
            vt->terminal,
            GHOSTTY_TERMINAL_OPT_UNKNOWN_SEQUENCE,
            callback ? (const void *)unknown_sequence : NULL);
    }
    return result;
}
static void reply(GhosttyTerminal terminal, void *context, const uint8_t *bytes, size_t len) {
    (void)terminal;
    Vt *vt = context;
    if (vt->reply) vt->reply(vt->context, bytes, len);
}
static GhosttyString xtversion_callback(GhosttyTerminal terminal, void *context) {
    (void)terminal;
    Vt *vt = context;
    GhosttyString empty = { NULL, 0 };
    if (!vt || vt->xtversion_len == 0) return empty;
    GhosttyString s = { (const uint8_t *)vt->xtversion, vt->xtversion_len };
    return s;
}
static bool device_attributes_callback(GhosttyTerminal terminal, void *context,
                                       GhosttyDeviceAttributes *out_attrs) {
    (void)terminal;
    (void)context;
    if (!out_attrs) return false;
    memset(out_attrs, 0, sizeof(*out_attrs));
    out_attrs->primary.conformance_level = 62;
    out_attrs->primary.features[0] = 22;
    out_attrs->primary.features[1] = 52;
    out_attrs->primary.num_features = 2;
    out_attrs->secondary.device_type = 1;
    out_attrs->secondary.firmware_version = 10;
    out_attrs->secondary.rom_cartridge = 0;
    out_attrs->tertiary.unit_id = 0;
    return true;
}
static bool size_callback(GhosttyTerminal terminal, void *context,
                          GhosttySizeReportSize *out_size) {
    (void)terminal;
    Vt *vt = context;
    if (!vt || !out_size || !vt->cols || !vt->rows) return false;
    out_size->rows = vt->rows;
    out_size->columns = vt->cols;
    out_size->cell_width = vt->cell_width ? vt->cell_width : 8;
    out_size->cell_height = vt->cell_height ? vt->cell_height : 16;
    return true;
}
static bool color_scheme_callback(GhosttyTerminal terminal, void *context,
                                  GhosttyColorScheme *out_scheme) {
    (void)terminal;
    Vt *vt = context;
    if (!vt || !out_scheme || !vt->has_color_scheme) return false;
    *out_scheme = vt->color_scheme;
    return true;
}
static void init_default_identity(Vt *vt) {
    GhosttyString ver = { NULL, 0 };
    if (ghostty_build_info(GHOSTTY_BUILD_INFO_VERSION_STRING, &ver) == GHOSTTY_SUCCESS && ver.ptr && ver.len > 0) {
        int n = snprintf(vt->xtversion, sizeof(vt->xtversion), "ghostty %.*s", (int)ver.len, (const char *)ver.ptr);
        if (n > 0) {
            vt->xtversion_len = (size_t)n >= sizeof(vt->xtversion) ? sizeof(vt->xtversion) - 1 : (size_t)n;
        }
    }
    if (vt->xtversion_len == 0) {
        memcpy(vt->xtversion, "ghostty", 7);
        vt->xtversion_len = 7;
    }
    memcpy(vt->terminfo_name, "xterm-ghostty", 13);
    vt->terminfo_name_len = 13;
}
static int apply_vt_options(Vt *vt) {
    int result = ghostty_terminal_set(
        vt->terminal, GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, &vt->continuation_max_bytes);
    if (!result) {
        result = ghostty_terminal_set(
            vt->terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &vt->scrollback_max_bytes);
    }
    if (!result) {
        result = ghostty_terminal_set(
            vt->terminal,
            GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES,
            vt->has_scrollback_max_lines ? &vt->scrollback_max_lines : NULL);
    }
    if (!result) result = ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_USERDATA, vt);
    if (!result) {
        result = ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, (const void *)reply);
    }
    if (!result) {
        result = ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_XTVERSION, (const void *)xtversion_callback);
    }
    if (!result) {
        result = ghostty_terminal_set(
            vt->terminal, GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES, (const void *)device_attributes_callback);
    }
    if (!result) {
        result = ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_SIZE, (const void *)size_callback);
    }
    if (!result) {
        result = ghostty_terminal_set(
            vt->terminal, GHOSTTY_TERMINAL_OPT_COLOR_SCHEME, (const void *)color_scheme_callback);
    }
    if (!result && vt->terminfo_name_len > 0) {
        GhosttyString tn = { (const uint8_t *)vt->terminfo_name, vt->terminfo_name_len };
        result = ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_TERMINFO_NAME, &tn);
    }
    if (!result && vt->has_fg) {
        result = ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &vt->fg);
    }
    if (!result && vt->has_bg) {
        result = ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &vt->bg);
    }
    if (!result && vt->has_cursor) {
        result = ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &vt->cursor);
    }
    if (!result && vt->signal) {
        result = ghostty_terminal_set(
            vt->terminal, GHOSTTY_TERMINAL_OPT_CONTEXT_SIGNAL, (const void *)context_signal);
        if (!result) {
            size_t unknown_max_bytes = OMG_VT_UNKNOWN_MAX_BYTES;
            result = ghostty_terminal_set(
                vt->terminal, GHOSTTY_TERMINAL_OPT_UNKNOWN_MAX_BYTES, &unknown_max_bytes);
        }
        if (!result) {
            result = ghostty_terminal_set(
                vt->terminal,
                GHOSTTY_TERMINAL_OPT_UNKNOWN_SEQUENCE,
                (const void *)unknown_sequence);
        }
    }
    return result;
}
static int resize_pixels(Vt *vt, unsigned short cols, unsigned short rows,
                         unsigned short pixel_width, unsigned short pixel_height) {
    if (!cols || !rows) return -1;
    unsigned short cell_width = pixel_width / cols;
    unsigned short cell_height = pixel_height / rows;
    if (!cell_width) cell_width = 1;
    if (!cell_height) cell_height = 1;
    if (vt->cols == cols && vt->rows == rows &&
        vt->cell_width == cell_width && vt->cell_height == cell_height) {
        return GHOSTTY_SUCCESS;
    }
    bool preserve_sync = false;
    if (vt->cols == cols && vt->rows == rows) {
        GhosttyTerminalModeConfig mode = {
            .mode = GHOSTTY_MODE_SYNCHRONIZED_OUTPUT,
            .value = false,
        };
        if (ghostty_terminal_get(vt->terminal, GHOSTTY_TERMINAL_DATA_MODE, &mode) == GHOSTTY_SUCCESS) {
            preserve_sync = mode.value;
        }
    }
    vt->cols = cols;
    vt->rows = rows;
    vt->cell_width = cell_width;
    vt->cell_height = cell_height;
    int res = ghostty_terminal_resize(vt->terminal, cols, rows, cell_width, cell_height);
    if (res == GHOSTTY_SUCCESS && preserve_sync) {
        GhosttyTerminalModeConfig mode = {
            .mode = GHOSTTY_MODE_SYNCHRONIZED_OUTPUT,
            .value = true,
        };
        ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_MODE, &mode);
    }
    return res;
}

void *omg_vt_new_with_pixels_scrollback(unsigned short cols, unsigned short rows,
                                        unsigned short pixel_width, unsigned short pixel_height,
                                        size_t scrollback_max_bytes,
                                        const size_t *scrollback_max_lines,
                                        Reply callback, void *context) {
    Vt *vt = calloc(1, sizeof(*vt));
    if (!vt) return NULL;
    if (ghostty_terminal_new(NULL, &vt->terminal, cols, rows) != GHOSTTY_SUCCESS) { free(vt); return NULL; }
    if (resize_pixels(vt, cols, rows, pixel_width, pixel_height) != GHOSTTY_SUCCESS) {
        ghostty_terminal_free(vt->terminal); free(vt); return NULL;
    }
    vt->reply = callback;
    vt->context = context;
    vt->continuation_max_bytes = 1024 * 1024;
    vt->scrollback_max_bytes = scrollback_max_bytes;
    vt->has_scrollback_max_lines = scrollback_max_lines != NULL;
    vt->scrollback_max_lines = scrollback_max_lines ? *scrollback_max_lines : 0;
    init_default_identity(vt);
    if (apply_vt_options(vt) != GHOSTTY_SUCCESS) {
        ghostty_terminal_free(vt->terminal); free(vt); return NULL;
    }
    return vt;
}
int omg_vt_scrollback_limits(Vt *vt, size_t *scrollback_max_bytes,
                             bool *has_scrollback_max_lines,
                             size_t *scrollback_max_lines) {
    int result = ghostty_terminal_get(
        vt->terminal,
        GHOSTTY_TERMINAL_DATA_SCROLLBACK_MAX_BYTES,
        scrollback_max_bytes);
    if (result != GHOSTTY_SUCCESS) return result;
    result = ghostty_terminal_get(
        vt->terminal,
        GHOSTTY_TERMINAL_DATA_SCROLLBACK_MAX_LINES,
        scrollback_max_lines);
    if (result == GHOSTTY_NO_VALUE) {
        *has_scrollback_max_lines = false;
        return GHOSTTY_SUCCESS;
    }
    if (result != GHOSTTY_SUCCESS) return result;
    *has_scrollback_max_lines = true;
    return GHOSTTY_SUCCESS;
}
void omg_vt_free(Vt *vt) { ghostty_terminal_free(vt->terminal); free(vt); }
void omg_vt_write(Vt *vt, const unsigned char *data, size_t len) { ghostty_terminal_vt_write(vt->terminal, data, len); }
int omg_vt_resize(Vt *vt, unsigned short cols, unsigned short rows) {
    if (!cols || !rows) return -1;
    if (vt->cols == cols && vt->rows == rows) return GHOSTTY_SUCCESS;
    unsigned short cell_width = vt->cell_width ? vt->cell_width : 8;
    unsigned short cell_height = vt->cell_height ? vt->cell_height : 16;
    vt->cols = cols;
    vt->rows = rows;
    vt->cell_width = cell_width;
    vt->cell_height = cell_height;
    return ghostty_terminal_resize(vt->terminal, cols, rows, cell_width, cell_height);
}
int omg_vt_resize_pixels(Vt *vt, unsigned short cols, unsigned short rows,
                         unsigned short pixel_width, unsigned short pixel_height) {
    return resize_pixels(vt, cols, rows, pixel_width, pixel_height);
}
int omg_vt_snapshot(Vt *vt, unsigned char **data, size_t *len) { return ghostty_snapshot_encode_alloc(vt->terminal, NULL, data, len); }
void omg_vt_buffer_free(unsigned char *data, size_t len) { ghostty_free(NULL, data, len); }
int omg_vt_restore(Vt *vt, const unsigned char *data, size_t len) {
    GhosttySnapshotDecoder decoder = NULL;
    GhosttyTerminal terminal = NULL;
    int result = ghostty_snapshot_decoder_new_buf(NULL, &decoder, data, len);
    if (result) return result;
    bool retain = true;
    size_t limit = vt->continuation_max_bytes;
    result = ghostty_snapshot_decoder_set(decoder, GHOSTTY_SNAPSHOT_DECODER_OPT_MAX_CONTINUATION_BYTES, &limit);
    if (!result) result = ghostty_snapshot_decoder_set(decoder, GHOSTTY_SNAPSHOT_DECODER_OPT_RETAIN_CONTINUATION, &retain);
    if (!result) result = ghostty_snapshot_decoder_decode(decoder, &terminal);
    size_t consumed = 0;
    if (!result) result = ghostty_snapshot_decoder_get(decoder, GHOSTTY_SNAPSHOT_DECODER_DATA_SOURCE_OFFSET, &consumed);
    ghostty_snapshot_decoder_free(decoder);
    if (result || consumed != len) { if (terminal) ghostty_terminal_free(terminal); return result ? result : -1; }
    ghostty_terminal_free(vt->terminal); vt->terminal = terminal;
    uint16_t cols = 0;
    uint16_t rows = 0;
    if (ghostty_terminal_get(vt->terminal, GHOSTTY_TERMINAL_DATA_COLS, &cols) == GHOSTTY_SUCCESS && cols > 0) {
        vt->cols = cols;
    }
    if (ghostty_terminal_get(vt->terminal, GHOSTTY_TERMINAL_DATA_ROWS, &rows) == GHOSTTY_SUCCESS && rows > 0) {
        vt->rows = rows;
    }
    return apply_vt_options(vt);
}
int omg_vt_continuation(Vt *vt, unsigned char **data, size_t *len) {
    return ghostty_terminal_continuation_alloc(vt->terminal, NULL, data, len);
}
int omg_vt_screen_only(Vt *vt) {
    vt->scrollback_max_bytes = 0;
    vt->has_scrollback_max_lines = true;
    vt->scrollback_max_lines = 0;
    int result = ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &vt->scrollback_max_bytes);
    if (!result) result = ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &vt->scrollback_max_lines);
    return result;
}
int omg_vt_set_scrollback_limits(Vt *vt, size_t scrollback_max_bytes,
                                 const size_t *scrollback_max_lines) {
    if (!vt) return GHOSTTY_INVALID_VALUE;
    vt->scrollback_max_bytes = scrollback_max_bytes;
    vt->has_scrollback_max_lines = scrollback_max_lines != NULL;
    vt->scrollback_max_lines = scrollback_max_lines ? *scrollback_max_lines : 0;
    int result = ghostty_terminal_set(
        vt->terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &vt->scrollback_max_bytes);
    if (!result) {
        result = ghostty_terminal_set(
            vt->terminal,
            GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES,
            vt->has_scrollback_max_lines ? &vt->scrollback_max_lines : NULL);
    }
    return result;
}
void omg_vt_c_free(unsigned char *data) { free(data); }
int omg_vt_grid_metrics(Vt *vt, unsigned short *cols, unsigned short *rows,
                        size_t *scrollback_rows, bool *alternate) {
    if (!vt) return GHOSTTY_INVALID_VALUE;
    uint16_t c = 0, r = 0;
    size_t sb = 0;
    GhosttyTerminalScreen screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY;
    int result = ghostty_terminal_get(vt->terminal, GHOSTTY_TERMINAL_DATA_COLS, &c);
    if (!result) result = ghostty_terminal_get(vt->terminal, GHOSTTY_TERMINAL_DATA_ROWS, &r);
    if (!result) result = ghostty_terminal_get(vt->terminal, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &sb);
    if (!result) result = ghostty_terminal_get(vt->terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen);
    if (result != GHOSTTY_SUCCESS) return result;
    if (cols) *cols = c;
    if (rows) *rows = r;
    if (scrollback_rows) *scrollback_rows = sb;
    if (alternate) *alternate = (screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE);
    return GHOSTTY_SUCCESS;
}
int omg_vt_region_plain(Vt *vt, bool history, unsigned char **data, size_t *len, size_t *row_count) {
    if (!vt || !data || !len || !row_count) return GHOSTTY_INVALID_VALUE;
    *data = NULL;
    *len = 0;
    *row_count = 0;
    uint16_t cols = 0, rows = 0;
    size_t sb = 0;
    int result = ghostty_terminal_get(vt->terminal, GHOSTTY_TERMINAL_DATA_COLS, &cols);
    if (!result) result = ghostty_terminal_get(vt->terminal, GHOSTTY_TERMINAL_DATA_ROWS, &rows);
    if (!result) result = ghostty_terminal_get(vt->terminal, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &sb);
    if (result || !cols || !rows) return result ? result : -1;
    if (history) {
        if (sb == 0) return GHOSTTY_SUCCESS;
        *row_count = sb > (size_t)UINT32_MAX ? (size_t)UINT32_MAX : sb;
    } else {
        *row_count = (size_t)rows;
    }
    GhosttySelection sel = {0};
    GhosttyPoint start = {0};
    GhosttyPoint end = {0};
    if (history) {
        start.tag = GHOSTTY_POINT_TAG_HISTORY;
        start.value.coordinate.x = 0;
        start.value.coordinate.y = 0;
        end.tag = GHOSTTY_POINT_TAG_HISTORY;
        end.value.coordinate.x = cols - 1;
        end.value.coordinate.y = (uint32_t)(*row_count - 1);
    } else {
        start.tag = GHOSTTY_POINT_TAG_ACTIVE;
        start.value.coordinate.x = 0;
        start.value.coordinate.y = 0;
        end.tag = GHOSTTY_POINT_TAG_ACTIVE;
        end.value.coordinate.x = cols - 1;
        end.value.coordinate.y = rows - 1;
    }
    result = ghostty_terminal_grid_ref(vt->terminal, start, &sel.start);
    if (!result) result = ghostty_terminal_grid_ref(vt->terminal, end, &sel.end);
    if (result) return result;
    GhosttyFormatter formatter = NULL;
    result = ghostty_formatter_terminal_new(NULL, &formatter, vt->terminal);
    if (result) return result;
    GhosttyFormatterFormat emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
    bool unwrap = false;
    bool trim = true;
    GhosttyFormatterExtras extras = GHOSTTY_FORMATTER_EXTRAS_NONE;
    result = ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EMIT, &emit);
    if (!result) result = ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_UNWRAP, &unwrap);
    if (!result) result = ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_TRIM, &trim);
    if (!result) result = ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EXTRAS, &extras);
    if (!result) result = ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_SELECTION, &sel);
    if (!result) result = ghostty_formatter_format_alloc(formatter, NULL, data, len);
    ghostty_formatter_free(formatter);
    return result;
}
int omg_vt_track_row(Vt *vt, bool history, size_t row, void **out_ref) {
    if (!vt || !out_ref) return GHOSTTY_INVALID_VALUE;
    *out_ref = NULL;
    GhosttyPoint pt = {0};
    pt.tag = history ? GHOSTTY_POINT_TAG_HISTORY : GHOSTTY_POINT_TAG_ACTIVE;
    pt.value.coordinate.x = 0;
    pt.value.coordinate.y = row > (size_t)UINT32_MAX ? UINT32_MAX : (uint32_t)row;
    GhosttyTrackedGridRef ref = NULL;
    int res = ghostty_terminal_grid_ref_track(vt->terminal, pt, &ref);
    if (res != GHOSTTY_SUCCESS) return res;
    *out_ref = ref;
    return GHOSTTY_SUCCESS;
}
int omg_vt_resolve_tracked_history_row(Vt *vt, void *raw_ref, size_t *out_history_start_row) {
    if (!vt || !raw_ref || !out_history_start_row) return GHOSTTY_INVALID_VALUE;
    GhosttyTrackedGridRef ref = (GhosttyTrackedGridRef)raw_ref;
    if (!ghostty_tracked_grid_ref_has_value(ref)) {
        *out_history_start_row = 0;
        return GHOSTTY_SUCCESS;
    }
    GhosttyPointCoordinate coord = {0};
    GhosttyResult res = ghostty_tracked_grid_ref_point(ref, GHOSTTY_POINT_TAG_HISTORY, &coord);
    if (res == GHOSTTY_SUCCESS) {
        *out_history_start_row = (size_t)coord.y;
        return GHOSTTY_SUCCESS;
    }
    if (res == GHOSTTY_NO_VALUE) {
        size_t sb = 0;
        int sb_res = ghostty_terminal_get(vt->terminal, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &sb);
        if (sb_res != GHOSTTY_SUCCESS) return sb_res;
        *out_history_start_row = sb;
        return GHOSTTY_SUCCESS;
    }
    return res;
}
void omg_vt_tracked_ref_free(void *raw_ref) {
    if (raw_ref) ghostty_tracked_grid_ref_free((GhosttyTrackedGridRef)raw_ref);
}
int omg_vt_in_alt_screen(Vt *vt) {
    GhosttyTerminalScreen screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY;
    if (ghostty_terminal_get(vt->terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen) != GHOSTTY_SUCCESS) {
        return 0;
    }
    return screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE ? 1 : 0;
}
int omg_vt_in_sync_and_screen(Vt *vt, bool *in_sync, bool *alt_screen) {
    if (!vt) return GHOSTTY_INVALID_VALUE;
    if (in_sync) {
        GhosttyTerminalModeConfig mode = {
            .mode = GHOSTTY_MODE_SYNCHRONIZED_OUTPUT,
            .value = false,
        };
        int res = ghostty_terminal_get(vt->terminal, GHOSTTY_TERMINAL_DATA_MODE, &mode);
        if (res != GHOSTTY_SUCCESS) return res;
        *in_sync = mode.value;
    }
    if (alt_screen) {
        GhosttyTerminalScreen screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY;
        int res = ghostty_terminal_get(vt->terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen);
        if (res != GHOSTTY_SUCCESS) return res;
        *alt_screen = (screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE);
    }
    return GHOSTTY_SUCCESS;
}
int omg_vt_ui_modes(Vt *vt, bool *in_sync, bool *alt_screen, bool *cursor_visible, bool *mouse_active) {
    int res = omg_vt_in_sync_and_screen(vt, in_sync, alt_screen);
    if (res != GHOSTTY_SUCCESS) return res;
    if (cursor_visible) {
        GhosttyTerminalModeConfig mode = {
            .mode = GHOSTTY_MODE_CURSOR_VISIBLE,
            .value = true,
        };
        if (ghostty_terminal_get(vt->terminal, GHOSTTY_TERMINAL_DATA_MODE, &mode) == GHOSTTY_SUCCESS) {
            *cursor_visible = mode.value;
        } else {
            *cursor_visible = true;
        }
    }
    if (mouse_active) {
        const GhosttyMode mouse_modes[] = {
            GHOSTTY_MODE_MOUSE_EVENT_X10,
            GHOSTTY_MODE_MOUSE_EVENT_NORMAL,
            GHOSTTY_MODE_MOUSE_EVENT_BUTTON,
            GHOSTTY_MODE_MOUSE_EVENT_ANY,
        };
        bool active = false;
        for (size_t i = 0; i < sizeof(mouse_modes) / sizeof(mouse_modes[0]); i++) {
            GhosttyTerminalModeConfig mode = {
                .mode = mouse_modes[i],
                .value = false,
            };
            if (ghostty_terminal_get(vt->terminal, GHOSTTY_TERMINAL_DATA_MODE, &mode) == GHOSTTY_SUCCESS && mode.value) {
                active = true;
                break;
            }
        }
        *mouse_active = active;
    }
    return GHOSTTY_SUCCESS;
}
int omg_vt_build_version(const unsigned char **data, size_t *len) {
    GhosttyString ver = { NULL, 0 };
    int res = ghostty_build_info(GHOSTTY_BUILD_INFO_VERSION_STRING, &ver);
    if (res != GHOSTTY_SUCCESS) return res;
    if (data) *data = ver.ptr;
    if (len) *len = ver.len;
    return GHOSTTY_SUCCESS;
}
int omg_vt_set_identity(Vt *vt,
                        const unsigned char *term_program, size_t term_program_len,
                        const unsigned char *version, size_t version_len,
                        const unsigned char *terminfo, size_t terminfo_len) {
    if (!vt) return GHOSTTY_INVALID_VALUE;
    if (term_program && term_program_len > 0 && version && version_len > 0) {
        int n = snprintf(vt->xtversion, sizeof(vt->xtversion), "%.*s %.*s",
                         (int)term_program_len, (const char *)term_program,
                         (int)version_len, (const char *)version);
        if (n > 0) {
            vt->xtversion_len = (size_t)n >= sizeof(vt->xtversion) ? sizeof(vt->xtversion) - 1 : (size_t)n;
        }
    } else if (version && version_len > 0) {
        int n = snprintf(vt->xtversion, sizeof(vt->xtversion), "ghostty %.*s",
                         (int)version_len, (const char *)version);
        if (n > 0) {
            vt->xtversion_len = (size_t)n >= sizeof(vt->xtversion) ? sizeof(vt->xtversion) - 1 : (size_t)n;
        }
    }
    if (terminfo && terminfo_len > 0) {
        if (terminfo_len > sizeof(vt->terminfo_name)) return GHOSTTY_INVALID_VALUE;
        memcpy(vt->terminfo_name, terminfo, terminfo_len);
        vt->terminfo_name_len = terminfo_len;
        GhosttyString tn = { (const uint8_t *)vt->terminfo_name, vt->terminfo_name_len };
        return ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_TERMINFO_NAME, &tn);
    }
    return GHOSTTY_SUCCESS;
}
int omg_vt_set_theme(Vt *vt,
                     bool has_scheme, int dark_scheme,
                     bool has_fg, const unsigned char *fg_rgb,
                     bool has_bg, const unsigned char *bg_rgb,
                     bool has_cursor, const unsigned char *cursor_rgb) {
    if (!vt) return GHOSTTY_INVALID_VALUE;
    vt->has_color_scheme = has_scheme;
    if (has_scheme) {
        vt->color_scheme = dark_scheme ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT;
    }
    vt->has_fg = has_fg && fg_rgb != NULL;
    if (vt->has_fg) {
        vt->fg.r = fg_rgb[0];
        vt->fg.g = fg_rgb[1];
        vt->fg.b = fg_rgb[2];
    }
    vt->has_bg = has_bg && bg_rgb != NULL;
    if (vt->has_bg) {
        vt->bg.r = bg_rgb[0];
        vt->bg.g = bg_rgb[1];
        vt->bg.b = bg_rgb[2];
    }
    vt->has_cursor = has_cursor && cursor_rgb != NULL;
    if (vt->has_cursor) {
        vt->cursor.r = cursor_rgb[0];
        vt->cursor.g = cursor_rgb[1];
        vt->cursor.b = cursor_rgb[2];
    }
    int result = ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND,
                                      vt->has_fg ? &vt->fg : NULL);
    if (!result) {
        result = ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND,
                                      vt->has_bg ? &vt->bg : NULL);
    }
    if (!result) {
        result = ghostty_terminal_set(vt->terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR,
                                      vt->has_cursor ? &vt->cursor : NULL);
    }
    return result;
}
int omg_vt_dynamic_color(Vt *vt, unsigned int index, unsigned char *rgb) {
    const GhosttyTerminalData keys[] = {
        GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND,
        GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND,
        GHOSTTY_TERMINAL_DATA_COLOR_CURSOR
    };
    if (index >= 3) return -1;
    GhosttyColorRgb color;
    int result = ghostty_terminal_get(vt->terminal, keys[index], &color);
    if (!result) { rgb[0] = color.r; rgb[1] = color.g; rgb[2] = color.b; }
    return result;
}
static const size_t OMG_VT_MAX_REPLAY_HISTORY_ROWS = 10000;
static const size_t OMG_VT_MAX_REPLAY_HISTORY_BYTES = 2 * 1024 * 1024;

static size_t advance_past_wrap_continuation(GhosttyTerminal terminal,
                                             size_t row_idx,
                                             size_t scrollback_rows) {
    size_t steps = 0;
    while (row_idx < scrollback_rows && steps < 256) {
        GhosttyPoint pt = {0};
        pt.tag = GHOSTTY_POINT_TAG_HISTORY;
        pt.value.coordinate.x = 0;
        pt.value.coordinate.y = (uint32_t)row_idx;
        GhosttyGridRef ref = {0};
        GhosttyRow row = 0;
        bool cont = false;
        if (ghostty_terminal_grid_ref(terminal, pt, &ref) != GHOSTTY_SUCCESS ||
            ghostty_grid_ref_row(&ref, &row) != GHOSTTY_SUCCESS ||
            ghostty_row_get(row, GHOSTTY_ROW_DATA_WRAP_CONTINUATION, &cont) != GHOSTTY_SUCCESS ||
            !cont) {
            break;
        }
        row_idx++;
        steps++;
    }
    return row_idx;
}

static int format_content_selection(GhosttyTerminal terminal,
                                    GhosttyFormatter formatter,
                                    uint16_t cols,
                                    uint16_t rows,
                                    bool include_history,
                                    size_t history_start_row,
                                    uint8_t **out_ptr,
                                    size_t *out_len) {
    GhosttySelection sel = {0};
    GhosttyPoint start = {0};
    if (include_history) {
        start.tag = GHOSTTY_POINT_TAG_HISTORY;
        start.value.coordinate.x = 0;
        start.value.coordinate.y = (uint32_t)history_start_row;
    } else {
        start.tag = GHOSTTY_POINT_TAG_ACTIVE;
        start.value.coordinate.x = 0;
        start.value.coordinate.y = 0;
    }
    GhosttyPoint end = {0};
    end.tag = GHOSTTY_POINT_TAG_ACTIVE;
    end.value.coordinate.x = cols - 1;
    end.value.coordinate.y = rows - 1;
    int result = ghostty_terminal_grid_ref(terminal, start, &sel.start);
    if (!result) result = ghostty_terminal_grid_ref(terminal, end, &sel.end);
    if (!result) result = ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_SELECTION, &sel);
    if (!result) result = ghostty_formatter_format_alloc(formatter, NULL, out_ptr, out_len);
    return result;
}

int omg_vt_paint_with_history(Vt *vt, size_t history_start_row,
                              unsigned char **data, size_t *len,
                              bool *alternate) {
    if (!vt || !data || !len || !alternate) return GHOSTTY_INVALID_VALUE;
    *data = NULL;
    *len = 0;
    uint16_t cols = 0, rows = 0;
    size_t scrollback_rows = 0;
    GhosttyTerminalScreen screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY;
    int result = ghostty_terminal_get(vt->terminal, GHOSTTY_TERMINAL_DATA_COLS, &cols);
    if (!result) result = ghostty_terminal_get(vt->terminal, GHOSTTY_TERMINAL_DATA_ROWS, &rows);
    if (!result) result = ghostty_terminal_get(vt->terminal, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &scrollback_rows);
    if (!result) result = ghostty_terminal_get(vt->terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen);
    if (result || !cols || !rows) return result ? result : -1;
    if (scrollback_rows > (size_t)UINT32_MAX) scrollback_rows = (size_t)UINT32_MAX;
    *alternate = (screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE);

    GhosttyFormatter formatter = NULL;
    result = ghostty_formatter_terminal_new(NULL, &formatter, vt->terminal);
    if (result) return result;

    uint8_t *cell_ptr = NULL, *tabs_ptr = NULL, *modes_ptr = NULL, *post_ptr = NULL, *content_ptr = NULL;
    size_t cell_len = 0, tabs_len = 0, modes_len = 0, post_len = 0, content_len = 0;

    GhosttySelection dummy_sel = {0};
    GhosttyPoint origin = {.tag = GHOSTTY_POINT_TAG_ACTIVE, .value.coordinate = {.x = 0, .y = 0}};
    result = ghostty_terminal_grid_ref(vt->terminal, origin, &dummy_sel.start);
    if (!result) result = ghostty_terminal_grid_ref(vt->terminal, origin, &dummy_sel.end);

    GhosttyFormatterFormat emit = GHOSTTY_FORMATTER_FORMAT_VT;
    bool unwrap_false = false;
    bool trim_true = true;
    GhosttyFormatterExtras extras_none = GHOSTTY_FORMATTER_EXTRAS_NONE;
    GhosttyFormatterExtras extras_tabs = GHOSTTY_FORMATTER_EXTRA_TABSTOPS;
    GhosttyFormatterExtras extras_modes = GHOSTTY_FORMATTER_EXTRA_MODES;
    // Theme defaults belong to the outer viewer, not the headless runtime;
    // tabstops emit CSI H and MUST run before text, while modes/cursor/region run after text.
    GhosttyFormatterExtras extras_post = GHOSTTY_FORMATTER_EXTRAS_ALL &
        ~(GHOSTTY_FORMATTER_EXTRA_PALETTE | GHOSTTY_FORMATTER_EXTRA_TABSTOPS);

    if (!result) result = ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EMIT, &emit);
    if (!result) result = ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_UNWRAP, &unwrap_false);
    if (!result) result = ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_TRIM, &trim_true);
    if (!result) result = ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_SELECTION, &dummy_sel);

    if (!result) result = ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EXTRAS, &extras_none);
    if (!result) result = ghostty_formatter_format_alloc(formatter, NULL, &cell_ptr, &cell_len);

    if (!result) result = ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EXTRAS, &extras_tabs);
    if (!result) result = ghostty_formatter_format_alloc(formatter, NULL, &tabs_ptr, &tabs_len);

    if (!result) result = ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EXTRAS, &extras_modes);
    if (!result) result = ghostty_formatter_format_alloc(formatter, NULL, &modes_ptr, &modes_len);

    if (!result) result = ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EXTRAS, &extras_post);
    if (!result) result = ghostty_formatter_format_alloc(formatter, NULL, &post_ptr, &post_len);

    size_t pure_tabs_len = 0;
    size_t pure_modes_len = 0;
    const uint8_t *pure_state_ptr = NULL;
    size_t pure_state_len = 0;

    if (!result) {
        if (tabs_len < cell_len || modes_len < cell_len ||
            (cell_len > 0 && memcmp(tabs_ptr + (tabs_len - cell_len), cell_ptr, cell_len) != 0) ||
            (cell_len > 0 && memcmp(modes_ptr + (modes_len - cell_len), cell_ptr, cell_len) != 0)) {
            result = -1;
        } else {
            pure_tabs_len = tabs_len - cell_len;
            pure_modes_len = modes_len - cell_len;
            if (post_len < pure_modes_len + cell_len ||
                (pure_modes_len > 0 && memcmp(post_ptr, modes_ptr, pure_modes_len) != 0) ||
                (cell_len > 0 && memcmp(post_ptr + pure_modes_len, cell_ptr, cell_len) != 0)) {
                result = -1;
            } else {
                pure_state_ptr = post_ptr + pure_modes_len + cell_len;
                pure_state_len = post_len - pure_modes_len - cell_len;
            }
        }
    }

    bool unwrap_true = true;
    bool trim_false = false;
    if (!result) result = ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_UNWRAP, &unwrap_true);
    if (!result) result = ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_TRIM, &trim_false);
    if (!result) result = ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EXTRAS, &extras_none);

    size_t start_row = history_start_row;
    if (!*alternate && start_row < scrollback_rows) {
        if (scrollback_rows - start_row > OMG_VT_MAX_REPLAY_HISTORY_ROWS) {
            start_row = advance_past_wrap_continuation(
                vt->terminal, scrollback_rows - OMG_VT_MAX_REPLAY_HISTORY_ROWS, scrollback_rows);
        }
    } else {
        start_row = scrollback_rows;
    }

    if (!result) {
        for (int attempt = 0; attempt < 5; attempt++) {
            bool include_hist = !*alternate && start_row < scrollback_rows;
            result = format_content_selection(
                vt->terminal, formatter, cols, rows, include_hist, start_row, &content_ptr, &content_len);
            if (result || !include_hist || content_len <= OMG_VT_MAX_REPLAY_HISTORY_BYTES || attempt == 4) {
                break;
            }
            size_t hist_count = scrollback_rows - start_row;
            ghostty_free(NULL, content_ptr, content_len);
            content_ptr = NULL;
            content_len = 0;
            if (hist_count <= 32) {
                start_row = scrollback_rows;
            } else {
                size_t target_rows = (size_t)(((uint64_t)hist_count * OMG_VT_MAX_REPLAY_HISTORY_BYTES) / content_len);
                size_t max_keep = (hist_count * 3) / 4;
                if (target_rows > max_keep) target_rows = max_keep;
                if (target_rows == 0) {
                    start_row = scrollback_rows;
                } else {
                    start_row = advance_past_wrap_continuation(
                        vt->terminal, scrollback_rows - target_rows, scrollback_rows);
                }
            }
        }
    }

    if (!result) {
        size_t total_len = pure_tabs_len + content_len + pure_modes_len + pure_state_len;
        if (total_len > 0) {
            unsigned char *combined = malloc(total_len);
            if (!combined) {
                result = GHOSTTY_OUT_OF_MEMORY;
            } else {
                size_t off = 0;
                if (pure_tabs_len > 0) {
                    memcpy(combined + off, tabs_ptr, pure_tabs_len);
                    off += pure_tabs_len;
                }
                if (content_len > 0) {
                    memcpy(combined + off, content_ptr, content_len);
                    off += content_len;
                }
                if (pure_modes_len > 0) {
                    memcpy(combined + off, post_ptr, pure_modes_len);
                    off += pure_modes_len;
                }
                if (pure_state_len > 0) {
                    memcpy(combined + off, pure_state_ptr, pure_state_len);
                    off += pure_state_len;
                }
                *data = combined;
                *len = total_len;
            }
        }
    }

    ghostty_free(NULL, cell_ptr, cell_len);
    ghostty_free(NULL, tabs_ptr, tabs_len);
    ghostty_free(NULL, modes_ptr, modes_len);
    ghostty_free(NULL, post_ptr, post_len);
    ghostty_free(NULL, content_ptr, content_len);
    ghostty_formatter_free(formatter);
    return result;
}

int omg_vt_paint(Vt *vt, unsigned char **data, size_t *len, bool *alternate) {
    return omg_vt_paint_with_history(vt, SIZE_MAX, data, len, alternate);
}
int omg_vt_text(Vt *vt, unsigned char **data, size_t *len) {
    GhosttyFormatter formatter = NULL;
    int result = ghostty_formatter_terminal_new(NULL, &formatter, vt->terminal);
    if (result) return result;
    bool trim = true;
    result = ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_TRIM, &trim);
    if (!result) result = ghostty_formatter_format_alloc(formatter, NULL, data, len);
    ghostty_formatter_free(formatter);
    return result;
}
