#!/usr/bin/env python3
"""Derive ios/runtime/display_ios.c from framework/runtime/display.c: one UIScreen-backed display, no CoreGraphics."""
import sys
root = sys.argv[1] if len(sys.argv) > 1 else '.'
src = open(f'{root}/framework/runtime/display.c').read()
def rep(old, new):
    global src
    assert old in src, old[:40]
    src = src.replace(old, new, 1)
rep('// user32/gdi32 displays: monitors, display modes and gamma, backed by CoreGraphics.',
    '// GENERATED from framework/runtime/display.c by ios/scripts/gen_display_ios.py: do not edit.\n'
    '// user32/gdi32 displays on iOS: one display (the screen), backed by UIScreen through cocoa_ios.m.')
rep('#include <CoreGraphics/CoreGraphics.h>\n',
    '#include <CoreFoundation/CoreFoundation.h>\nvoid cocoa_ios_screen(int *w, int *h, int *hz);\ntypedef uint32_t CGDirectDisplayID;\n')
rep('static uint32_t mode_hz(CGDisplayModeRef m) { double r = CGDisplayModeGetRefreshRate(m); return r > 0 ? (uint32_t)(r + 0.5) : 60; }\n', '')
a = src.index('static void disp_init(void) {'); b = src.index('static int disp_count(void)')
new = r'''static void disp_init(void) {
    int sw, sh, shz;
    cocoa_ios_screen(&sw, &sh, &shz);
    Disp *d = &disps[0];
    d->id = 1; d->w = (uint32_t)sw; d->h = (uint32_t)sh; d->hz = (uint32_t)shz; d->x = d->y = 0;
    snap_ratio(&d->w, &d->h);
    d->capw = d->w; d->caph = d->h;
    // a ladder of common widths at the screen's own aspect ratio (Windows drivers list these as scaled modes)
    {
        uint32_t g = d->w, b = d->h; while (b) { uint32_t t = g % b; g = b; b = t; }
        uint32_t p = d->w / g, q = d->h / g;
        static const uint32_t widths[] = { 1280, 1440, 1600, 1680, 1920, 2240, 2560, 2880, 3200, 3840, 5120 };
        for (size_t i = 0; p <= 64 && i < sizeof widths / sizeof *widths; i++) {
            uint32_t k = widths[i] / p;
            if (k && k * p <= d->capw) add_mode(d, k * p, k * q, d->hz);
        }
    }
    d->nw = d->w; d->nh = d->h;
    add_mode(d, d->w, d->h, d->hz);
    qsort(d->modes, d->nmodes, sizeof(Mode), mode_cmp);
    rt_log("[display] DISPLAY1: %ux%u @ %u Hz primary, %d modes\n", d->w, d->h, d->hz, d->nmodes);
    if (getenv("RT_LIST_MODES")) for (int i = 0; i < d->nmodes; i++) rt_log("[display]   %ux%u @ %u\n", d->modes[i].w, d->modes[i].h, d->modes[i].hz);
    ndisp = 1;
}
'''
src = src[:a] + new + src[b:]
a = src.index('    const char *apply = getenv("RT_GAMMA");')
b = src.index('    pthread_mutex_unlock(&gamma_mu);\n    RET(1);\n}\n', a)
src = src[:a] + src[b:]
open(f'{root}/ios/runtime/display_ios.c', 'w').write(src)
