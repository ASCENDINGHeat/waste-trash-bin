#ifndef DANCING_CAT_FRAMES_H
#define DANCING_CAT_FRAMES_H

#include <stdint.h>
#include <stdbool.h>
#include <string.h>

#define OLED_WIDTH              128
#define OLED_HEIGHT             64
#define OLED_PAGES              (OLED_HEIGHT / 8)
#define OLED_FRAME_BYTES        (OLED_WIDTH * OLED_PAGES) /* 1024 bytes per frame */
#define DANCING_CAT_NUM_FRAMES  16

/**
 * @brief Helper to set a single pixel (x, y) in an SSD1306 page-addressed 1024-byte buffer
 */
static inline void oled_buf_set_px(uint8_t *buf, int x, int y, bool on)
{
    if (x < 0 || x >= OLED_WIDTH || y < 0 || y >= OLED_HEIGHT) {
        return;
    }
    uint16_t idx = (uint16_t)((y / 8) * OLED_WIDTH + x);
    uint8_t mask = (uint8_t)(1U << (y & 7));
    if (on) {
        buf[idx] |= mask;
    } else {
        buf[idx] &= (uint8_t)~mask;
    }
}

static inline void oled_buf_line(uint8_t *buf, int x0, int y0, int x1, int y1)
{
    int dx = (x1 > x0) ? (x1 - x0) : (x0 - x1);
    int sx = (x0 < x1) ? 1 : -1;
    int dy = (y1 > y0) ? -(y1 - y0) : -(y0 - y1);
    int sy = (y0 < y1) ? 1 : -1;
    int err = dx + dy;
    while (1) {
        oled_buf_set_px(buf, x0, y0, true);
        if (x0 == x1 && y0 == y1) {
            break;
        }
        int e2 = 2 * err;
        if (e2 >= dy) {
            err += dy;
            x0 += sx;
        }
        if (e2 <= dx) {
            err += dx;
            y0 += sy;
        }
    }
}

static inline void oled_buf_fill_circle(uint8_t *buf, int cx, int cy, int r, bool on)
{
    for (int dy = -r; dy <= r; dy++) {
        for (int dx = -r; dx <= r; dx++) {
            if (dx * dx + dy * dy <= r * r) {
                oled_buf_set_px(buf, cx + dx, cy + dy, on);
            }
        }
    }
}

static inline void oled_buf_music_note(uint8_t *buf, int x, int y, bool double_beam)
{
    oled_buf_fill_circle(buf, x, y + 6, 2, true);
    oled_buf_line(buf, x + 2, y + 6, x + 2, y);
    if (double_beam) {
        oled_buf_fill_circle(buf, x + 7, y + 5, 2, true);
        oled_buf_line(buf, x + 9, y + 5, x + 9, y - 1);
        oled_buf_line(buf, x + 2, y, x + 9, y - 1);
        oled_buf_line(buf, x + 2, y + 1, x + 9, y);
    } else {
        oled_buf_line(buf, x + 2, y, x + 5, y + 2);
    }
}

/**
 * @brief Render a single frame (0..15) of the iconic "Chinese Dancing Cat" GIF
 *        into an SSD1306 128x64 page-addressed 1024-byte buffer in Octal PSRAM.
 *
 *        Features:
 *        - Rhythmic horizontal hip/body sway & head bobbing
 *        - Alternating raised/Grooving cat paws & stepping feet
 *        - Pointy cat ears, animated happy eyes/whiskers, wagging tail
 *        - Floating musical notes & rhythmic stage floor lines
 */
static inline void dancing_cat_render_frame(uint8_t *buf, int frame_idx)
{
    memset(buf, 0, OLED_FRAME_BYTES);

    /* Sinusoidal sway lookup across 16 frames */
    static const int8_t sway_x[16] = { 0,  3,  6,  8,  9,  8,  6,  3,  0, -3, -6, -8, -9, -8, -6, -3};
    static const int8_t bob_y[16]  = { 0,  1,  3,  2,  0,  1,  3,  2,  0,  1,  3,  2,  0,  1,  3,  2};
    static const int8_t arm_l[16]  = {-8,-12,-15,-12, -6,  2,  8, 10,  6,  0, -6,-10,-14,-12, -8, -4};
    static const int8_t arm_r[16]  = { 8, 10,  6,  0, -6,-12,-15,-12, -8, -4,  2,  8, 10,  8,  4,  6};

    int f = frame_idx & 0x0F;
    int cx = 64 + sway_x[f];
    int hy = 21 + bob_y[f];
    int by = 43 + (bob_y[f] / 2);

    /* 1. Stage floor & disco beat bars */
    oled_buf_line(buf, 14, 61, 114, 61);
    int beat_w = (f % 4 == 0) ? 14 : ((f % 2 == 0) ? 9 : 5);
    for (int b = 0; b < 4; b++) {
        int bx0 = 8 + b * 32;
        oled_buf_line(buf, bx0, 63, bx0 + beat_w, 63);
    }

    /* 2. Floating music notes on left & right */
    int note_y1 = 42 - ((f * 3) % 32);
    int note_y2 = 46 - (((f + 8) * 3) % 32);
    oled_buf_music_note(buf, 12 + (f & 3), note_y1, true);
    oled_buf_music_note(buf, 102 - (f & 3), note_y2, false);

    /* 3. Cat Tail (wagging behind torso) */
    int tail_dir = (f < 8) ? 1 : -1;
    int tx0 = cx + (tail_dir * 12);
    int ty0 = by + 7;
    int tx1 = tx0 + (tail_dir * (10 + (f % 4)));
    int ty1 = ty0 - 8 - (f % 5);
    oled_buf_line(buf, tx0, ty0, tx1, ty1);
    oled_buf_line(buf, tx0, ty0 + 1, tx1, ty1 + 1);
    oled_buf_fill_circle(buf, tx1, ty1, 2, true);

    /* 4. Cat Torso (filled silhouette with groovy belly) */
    for (int y = hy + 9; y <= by + 9; y++) {
        int half_w = 11 + ((y - (hy + 9)) / 3);
        int row_shift = ((y - hy) * sway_x[f]) / 24;
        for (int x = cx - half_w + row_shift; x <= cx + half_w + row_shift; x++) {
            oled_buf_set_px(buf, x, y, true);
        }
    }
    /* White belly patch inside torso */
    oled_buf_fill_circle(buf, cx + (sway_x[f] / 3), by + 1, 6, false);

    /* 5. Cat Head (filled rounded head + pointy ears) */
    oled_buf_fill_circle(buf, cx, hy, 12, true);

    /* Left Ear triangle */
    for (int ey = 0; ey < 9; ey++) {
        for (int ex = 0; ex <= ey; ex++) {
            oled_buf_set_px(buf, cx - 11 + ex, hy - 16 + ey, true);
            oled_buf_set_px(buf, cx + 11 - ex, hy - 16 + ey, true);
        }
    }

    /* Inner Face Cutout */
    oled_buf_fill_circle(buf, cx, hy + 1, 9, false);

    /* 6. Expressive Vibing Eyes (blinking / happy arcs on beat) */
    if ((f % 8) < 2) {
        /* Happy squinted ^_^ eyes on strong beat */
        oled_buf_line(buf, cx - 6, hy - 1, cx - 4, hy - 3);
        oled_buf_line(buf, cx - 4, hy - 3, cx - 2, hy - 1);
        oled_buf_line(buf, cx + 2, hy - 1, cx + 4, hy - 3);
        oled_buf_line(buf, cx + 4, hy - 3, cx + 6, hy - 1);
    } else {
        oled_buf_fill_circle(buf, cx - 4, hy - 1, 2, true);
        oled_buf_fill_circle(buf, cx + 4, hy - 1, 2, true);
    }

    /* Nose & ":3" Cat Mouth */
    oled_buf_set_px(buf, cx, hy + 2, true);
    oled_buf_line(buf, cx - 3, hy + 4, cx, hy + 3);
    oled_buf_line(buf, cx, hy + 3, cx + 3, hy + 4);
    if ((f & 2) != 0) {
        /* Singing / vibing open mouth */
        oled_buf_fill_circle(buf, cx, hy + 5, 2, true);
    }

    /* Whiskers */
    oled_buf_line(buf, cx - 9, hy + 1, cx - 16, hy - 1);
    oled_buf_line(buf, cx - 9, hy + 3, cx - 16, hy + 4);
    oled_buf_line(buf, cx + 9, hy + 1, cx + 16, hy - 1);
    oled_buf_line(buf, cx + 9, hy + 3, cx + 16, hy + 4);

    /* 7. Dancing Arms & Paws (swinging with arm_l / arm_r) */
    int lx_end = cx - 20 - (sway_x[f] / 2);
    int ly_end = (hy + 14) + arm_l[f];
    oled_buf_line(buf, cx - 10, hy + 12, lx_end, ly_end);
    oled_buf_line(buf, cx - 10, hy + 13, lx_end, ly_end + 1);
    oled_buf_fill_circle(buf, lx_end, ly_end, 3, true);

    int rx_end = cx + 20 - (sway_x[f] / 2);
    int ry_end = (hy + 14) + arm_r[f];
    oled_buf_line(buf, cx + 10, hy + 12, rx_end, ry_end);
    oled_buf_line(buf, cx + 10, hy + 13, rx_end, ry_end + 1);
    oled_buf_fill_circle(buf, rx_end, ry_end, 3, true);

    /* 8. Stepping Feet */
    int lift_l = (f < 8) ? (bob_y[f] * 2) : 0;
    int lift_r = (f >= 8) ? (bob_y[f] * 2) : 0;
    oled_buf_line(buf, cx - 6, by + 9, cx - 9, 59 - lift_l);
    oled_buf_line(buf, cx - 5, by + 9, cx - 8, 59 - lift_l);
    oled_buf_fill_circle(buf, cx - 9, 59 - lift_l, 2, true);

    oled_buf_line(buf, cx + 6, by + 9, cx + 9, 59 - lift_r);
    oled_buf_line(buf, cx + 5, by + 9, cx + 8, 59 - lift_r);
    oled_buf_fill_circle(buf, cx + 9, 59 - lift_r, 2, true);
}

#endif /* DANCING_CAT_FRAMES_H */
