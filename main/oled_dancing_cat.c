#include "oled_dancing_cat.h"
#include "oled_font5x7.h"
#include "dancing_cat_frames.h"
#include "sdkconfig.h"
#include <stdio.h>
#include <string.h>
#include <inttypes.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "driver/i2c_master.h"
#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "esp_log.h"
#include "anim_storage.h"

static const char *TAG = "oled_hud";

#define OLED_I2C_PORT           I2C_NUM_0
#define OLED_I2C_FREQ_HZ        400000
#define OLED_I2C_TIMEOUT_MS     50
#define OLED_BOOT_SPLASH_FRAMES 27
#define OLED_RESULT_HOLD_US     (3000000LL)

static i2c_master_bus_handle_t s_i2c_bus = NULL;
static i2c_master_dev_handle_t s_oled_dev = NULL;
static uint8_t *s_psram_frames = NULL;
static uint8_t *s_default_psram_buf = NULL;
static uint8_t *s_custom_psram_buf = NULL;
static uint16_t s_active_num_frames = DANCING_CAT_NUM_FRAMES;
static uint8_t s_active_fps = 15;
static uint8_t s_active_flags = 0;
static bool s_is_custom = false;
static SemaphoreHandle_t s_anim_mutex = NULL;

static bool s_upload_active = false;
static uint8_t s_upload_percent = 0;
static char s_upload_transport[16] = {0};
static uint8_t s_composite_fb[OLED_FB_BYTES];

static volatile uint32_t s_sleep_timeout_s = 0;
static volatile int64_t s_last_activity_us = 0;
static bool s_display_sleeping = false;
static bool s_hw_inverted = false;

static portMUX_TYPE s_hud_mux = portMUX_INITIALIZER_UNLOCKED;
static oled_ui_mode_t s_ui_mode = OLED_UI_MODE_HUD_MASCOT;
static int64_t s_result_card_until_us = 0;

static oled_hud_state_t s_hud_state = {
    .device_id = "smartbin_s3",
    .fill_percent = 0,
    .distance_cm = 30.0f,
    .full_alert = false,
    .lid_state = LID_STATE_CLOSED,
    .last_trigger = TRIGGER_BOOT,
    .open_cycles = 0,
    .wifi_rssi = -127,
    .wifi_connected = false,
    .mqtt_connected = false,
    .ble_active = false,
    .lid_hold_rem_ds = 0,
    .lid_hold_total_ds = 30,
    .pir_active = false,
};

static oled_warn_code_t s_modal_code = OLED_WARN_NONE;
static char s_modal_line1[32] = {0};
static char s_modal_line2[32] = {0};
static int64_t s_modal_start_us = 0;
static int64_t s_modal_expire_us = 0;

static esp_err_t oled_send_cmd(uint8_t cmd)
{
    if (s_oled_dev == NULL) {
        return ESP_ERR_INVALID_STATE;
    }
    uint8_t buf[2] = {0x00, cmd}; /* Control byte 0x00 = command stream */
    return i2c_master_transmit(s_oled_dev, buf, sizeof(buf), OLED_I2C_TIMEOUT_MS);
}

static esp_err_t oled_send_cmd_list(const uint8_t *cmds, size_t len)
{
    for (size_t i = 0; i < len; i++) {
        esp_err_t err = oled_send_cmd(cmds[i]);
        if (err != ESP_OK) {
            return err;
        }
    }
    return ESP_OK;
}

static void oled_set_hw_invert(bool invert)
{
    if (s_hw_inverted != invert) {
        oled_send_cmd(invert ? 0xA7 : 0xA6);
        s_hw_inverted = invert;
    }
}

static esp_err_t oled_hw_init(void)
{
    i2c_master_bus_config_t bus_cfg = {
        .i2c_port = OLED_I2C_PORT,
        .sda_io_num = (gpio_num_t)CONFIG_SMARTBIN_OLED_SDA_GPIO,
        .scl_io_num = (gpio_num_t)CONFIG_SMARTBIN_OLED_SCL_GPIO,
        .clk_source = I2C_CLK_SRC_DEFAULT,
        .glitch_ignore_cnt = 7,
        .flags = {
            .enable_internal_pullup = true,
        },
    };
    esp_err_t err = i2c_new_master_bus(&bus_cfg, &s_i2c_bus);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "i2c_new_master_bus failed: %s", esp_err_to_name(err));
        return err;
    }

    i2c_device_config_t dev_cfg = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = CONFIG_SMARTBIN_OLED_I2C_ADDR,
        .scl_speed_hz = OLED_I2C_FREQ_HZ,
    };
    err = i2c_master_bus_add_device(s_i2c_bus, &dev_cfg, &s_oled_dev);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "i2c_master_bus_add_device failed: %s", esp_err_to_name(err));
        return err;
    }

    static const uint8_t init_cmds[] = {
        0xAE,       /* Display OFF */
        0xD5, 0x80, /* Clock divide ratio / oscillator frequency */
        0xA8, 0x3F, /* Multiplex ratio = 64 - 1 */
        0xD3, 0x00, /* Display offset = 0 */
        0x40,       /* Start line = 0 */
        0x8D, 0x14, /* Enable internal charge pump */
        0x20, 0x02, /* Page addressing mode (compatible with both SSD1306 and SH1106) */
        0xA1,       /* Segment re-map (col 127 mapped to SEG0) */
        0xC8,       /* COM output scan direction remapped */
        0xDA, 0x12, /* COM pins hardware configuration for 128x64 */
        0x81, 0xCF, /* Contrast control */
        0xD9, 0xF1, /* Pre-charge period */
        0xDB, 0x40, /* VCOMH deselect level */
        0xA4,       /* Entire display ON follows RAM content */
        0xA6,       /* Normal (non-inverted) display */
        0xAF        /* Display ON */
    };

    err = oled_send_cmd_list(init_cmds, sizeof(init_cmds));
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "OLED I2C init at 0x%02X failed (%s) — check wiring on SDA=%d, SCL=%d",
                 CONFIG_SMARTBIN_OLED_I2C_ADDR, esp_err_to_name(err),
                 CONFIG_SMARTBIN_OLED_SDA_GPIO, CONFIG_SMARTBIN_OLED_SCL_GPIO);
        return err;
    }

    ESP_LOGI(TAG, "128x64 I2C OLED initialized at 0x%02X (SDA=GPIO %d, SCL=GPIO %d, 400 kHz)",
             CONFIG_SMARTBIN_OLED_I2C_ADDR,
             CONFIG_SMARTBIN_OLED_SDA_GPIO,
             CONFIG_SMARTBIN_OLED_SCL_GPIO);
    return ESP_OK;
}

static void oled_flush_frame(const uint8_t *frame_buf)
{
    if (s_oled_dev == NULL || frame_buf == NULL) {
        return;
    }

    uint8_t page_tx[1 + OLED_WIDTH];
    page_tx[0] = 0x40; /* Control byte 0x40 = GDDRAM data stream */

    for (uint8_t page = 0; page < OLED_PAGES; page++) {
        oled_send_cmd((uint8_t)(0xB0U | page));
        oled_send_cmd(0x00U);
        oled_send_cmd(0x10U);

        memcpy(&page_tx[1], &frame_buf[page * OLED_WIDTH], OLED_WIDTH);
        i2c_master_transmit(s_oled_dev, page_tx, sizeof(page_tx), OLED_I2C_TIMEOUT_MS);
    }
}

static const char *format_net_badge(const oled_hud_state_t *st, char *buf, size_t len)
{
    if (st->mqtt_connected) {
        snprintf(buf, len, "MQTT %d", (int)st->wifi_rssi);
    } else if (st->wifi_connected) {
        snprintf(buf, len, "WIFI %d", (int)st->wifi_rssi);
    } else if (st->ble_active) {
        snprintf(buf, len, "BLE 0xFF00");
    } else {
        snprintf(buf, len, "OFFLINE");
    }
    return buf;
}

static const char *trigger_short_name(smartbin_trigger_t t)
{
    switch (t) {
        case TRIGGER_LID_CLOSE:  return "LID_CLS";
        case TRIGGER_PERIODIC:   return "PERIODIC";
        case TRIGGER_REMOTE_CMD: return "REMOTE";
        case TRIGGER_BOOT:       return "BOOT";
        default:                 return "SENSOR";
    }
}

static void draw_hud_chrome(uint8_t *fb, const oled_hud_state_t *st, const char *mode_tag)
{
    char net_buf[24];
    char top_line[64];
    char bot_line[64];

    /* Clear Page 0 (y=0..7) and Page 7 (y=56..63) for clean text legibility */
    memset(&fb[0], 0x00, OLED_FB_WIDTH);
    memset(&fb[7 * OLED_FB_WIDTH], 0x00, OLED_FB_WIDTH);

    format_net_badge(st, net_buf, sizeof(net_buf));
    snprintf(top_line, sizeof(top_line), "%-9.9s %-6.6s %3u%%",
             net_buf, mode_tag, (unsigned)st->fill_percent);
    oled_fb_draw_text(fb, 1, 0, top_line, true, 1);

    snprintf(bot_line, sizeof(bot_line), "%4.1fcm", st->distance_cm);
    oled_fb_draw_text(fb, 1, 57, bot_line, true, 1);
    oled_fb_draw_progress_bar(fb, 42, 57, 32, 7, st->fill_percent, true);

    snprintf(bot_line, sizeof(bot_line), "Cyc:%04" PRIu32, st->open_cycles);
    oled_fb_draw_text(fb, 77, 57, bot_line, true, 1);
}

static void render_boot_splash(uint8_t *fb, const oled_hud_state_t *st, int boot_frame)
{
    char line[64];
    uint8_t pct = (uint8_t)((boot_frame * 100) / (OLED_BOOT_SPLASH_FRAMES - 1));

    oled_fb_clear(fb);

    /* Inverted Title Banner */
    oled_fb_fill_rect(fb, 0, 0, OLED_FB_WIDTH, 10, true);
    oled_fb_draw_text(fb, 13, 1, "=== W.A.S.T.E. ===", false, 1);

    if (boot_frame < 9) {
        /* Scanline wipe reveal of 2x W.A.S.T.E. logo */
        int half_w = ((boot_frame + 1) * 64) / 9;
        oled_fb_draw_text(fb, 16, 20, "W.A.S.T.E.", true, 2);
        oled_fb_draw_text(fb, 22, 40, "ESP32-S3 N16R8", true, 1);

        if (64 - half_w > 0) {
            oled_fb_fill_rect(fb, 0, 12, 64 - half_w, 40, false);
            oled_fb_fill_rect(fb, 64 + half_w, 12, 64 - half_w, 40, false);
        }
    } else {
        /* Sequential POST Checklist */
        oled_fb_draw_text(fb, 2, 13, "[OK] 8MB PSRAM 85Fr", true, 1);
        if (boot_frame >= 13) {
            oled_fb_draw_text(fb, 2, 23, "[OK] PIR+SG90+SR04", true, 1);
        }
        if (boot_frame >= 17) {
            oled_fb_draw_text(fb, 2, 33, "[OK] NimBLE + WiFi", true, 1);
        }
        if (boot_frame >= 21) {
            snprintf(line, sizeof(line), "ID: %.17s", st->device_id);
            oled_fb_draw_text(fb, 2, 43, line, true, 1);
        }
    }

    /* Page 7 Boot Progress Bar */
    oled_fb_draw_progress_bar(fb, 2, 55, 96, 8, pct, true);
    snprintf(line, sizeof(line), "%3u%%", (unsigned)pct);
    oled_fb_draw_text(fb, 102, 56, line, true, 1);
}

static void render_lid_active(uint8_t *fb, const oled_hud_state_t *st)
{
    char line[64];
    bool closing = (st->lid_state == LID_STATE_CLOSING || st->lid_state == LID_STATE_SETTLING);

    oled_fb_clear(fb);
    draw_hud_chrome(fb, st, closing ? "[CLSE]" : "[OPEN]");

    oled_fb_draw_rect(fb, 2, 10, 124, 44, true);

    if (closing) {
        oled_fb_draw_text(fb, 10, 17, "<<< SOFT CLOSE >>>", true, 1);
        oled_fb_draw_text(fb, 16, 31, "Settling & Detach", true, 1);
    } else {
        uint8_t rem_pct = 0;
        if (st->lid_hold_total_ds > 0) {
            uint32_t pct32 = ((uint32_t)st->lid_hold_rem_ds * 100U) / st->lid_hold_total_ds;
            rem_pct = (pct32 > 100U) ? 100U : (uint8_t)pct32;
        }
        oled_fb_draw_text(fb, 16, 14, ">>> LID OPEN <<<", true, 1);
        snprintf(line, sizeof(line), "Hold Time: %u.%us",
                 (unsigned)(st->lid_hold_rem_ds / 10U),
                 (unsigned)(st->lid_hold_rem_ds % 10U));
        oled_fb_draw_text(fb, 19, 27, line, true, 1);
        oled_fb_draw_progress_bar(fb, 12, 39, 104, 9, rem_pct, true);
    }

    /* Replace bottom bar left label with live PIR status */
    memset(&fb[7 * OLED_FB_WIDTH], 0x00, 76);
    oled_fb_draw_text(fb, 1, 57, st->pir_active ? "PIR: ACTIVE" : "PIR: IDLE", true, 1);
}

static void render_measuring_card(uint8_t *fb, const oled_hud_state_t *st)
{
    char line[64];

    oled_fb_clear(fb);
    draw_hud_chrome(fb, st, "[SCAN]");

    snprintf(line, sizeof(line), "%u%% FULL", (unsigned)st->fill_percent);
    int text_w = (int)strlen(line) * 12;
    int start_x = (text_w < OLED_FB_WIDTH) ? ((OLED_FB_WIDTH - text_w) / 2) : 2;
    oled_fb_draw_text(fb, start_x, 11, line, true, 2);

    snprintf(line, sizeof(line), "Depth: %.1f cm", st->distance_cm);
    oled_fb_draw_text(fb, 18, 30, line, true, 1);
    oled_fb_draw_progress_bar(fb, 10, 41, 108, 10, st->fill_percent, true);

    memset(&fb[7 * OLED_FB_WIDTH], 0x00, 76);
    snprintf(line, sizeof(line), "Trig:%.8s", trigger_short_name(st->last_trigger));
    oled_fb_draw_text(fb, 1, 57, line, true, 1);
}

static void render_full_alert(uint8_t *fb, const oled_hud_state_t *st)
{
    char line[64];

    oled_fb_clear(fb);

    /* Inverted Top Alert Bar */
    oled_fb_fill_rect(fb, 0, 0, OLED_FB_WIDTH, 9, true);
    snprintf(line, sizeof(line), "! ALERT ! [FULL] %u%%", (unsigned)st->fill_percent);
    oled_fb_draw_text(fb, 2, 1, line, false, 1);

    /* Double-bordered high-contrast alert box */
    oled_fb_draw_rect(fb, 4, 12, 120, 41, true);
    oled_fb_fill_rect(fb, 6, 14, 116, 13, true);
    oled_fb_draw_text(fb, 16, 17, "! BIN IS FULL !", false, 1);
    oled_fb_draw_text(fb, 10, 31, "PLEASE EMPTY RECEPT.", true, 1);
    snprintf(line, sizeof(line), "Depth: %.1fcm (%u%%)", st->distance_cm, (unsigned)st->fill_percent);
    oled_fb_draw_text(fb, 13, 41, line, true, 1);

    snprintf(line, sizeof(line), "ALERT ACTIVE  Cyc:%04" PRIu32, st->open_cycles);
    oled_fb_draw_text(fb, 1, 57, line, true, 1);
}

static void render_ble_setup(uint8_t *fb, const oled_hud_state_t *st)
{
    char line[64];

    oled_fb_clear(fb);
    oled_fb_fill_rect(fb, 0, 0, OLED_FB_WIDTH, 9, true);
    oled_fb_draw_text(fb, 2, 1, "[BLE SETUP]   0xFF00", false, 1);

    snprintf(line, sizeof(line), "ID: %.17s", st->device_id);
    oled_fb_draw_text(fb, 2, 13, line, true, 1);
    oled_fb_draw_text(fb, 2, 23, "Status: Advertising", true, 1);
    oled_fb_draw_text(fb, 2, 33, "App: W.A.S.T.E.", true, 1);
    oled_fb_draw_text(fb, 2, 43, "-> Antenna -> Scan", true, 1);

    snprintf(line, sizeof(line), "BOOT 3s=Reset   %3u%%", (unsigned)st->fill_percent);
    oled_fb_draw_text(fb, 1, 57, line, true, 1);
}

static void render_upload_progress(uint8_t *fb, const oled_hud_state_t *st, uint8_t percent, const char *transport)
{
    char line[64];
    oled_fb_clear(fb);

    /* Inverted Top Title Banner */
    oled_fb_fill_rect(fb, 0, 0, OLED_FB_WIDTH, 10, true);
    if (transport != NULL && transport[0] != '\0') {
        snprintf(line, sizeof(line), "[UPLOAD: %-5.5s] %3u%%", transport, (unsigned)percent);
    } else {
        snprintf(line, sizeof(line), "[UPLOAD ANIM] %3u%%", (unsigned)percent);
    }
    oled_fb_draw_text(fb, 2, 1, line, false, 1);

    /* Main Bordered Card */
    oled_fb_draw_rect(fb, 4, 13, 120, 41, true);

    /* Primary status line: "UPLOADING GIF: XX%" */
    snprintf(line, sizeof(line), "UPLOADING GIF: %u%%", (unsigned)percent);
    oled_fb_draw_text(fb, 10, 18, line, true, 1);

    /* Progress Bar */
    oled_fb_draw_progress_bar(fb, 12, 30, 104, 10, percent, true);

    /* Secondary detail line */
    snprintf(line, sizeof(line), "Streaming to PSRAM");
    oled_fb_draw_text(fb, 12, 43, line, true, 1);

    /* Bottom Status Bar */
    memset(&fb[7 * OLED_FB_WIDTH], 0x00, OLED_FB_WIDTH);
    snprintf(line, sizeof(line), "ID: %.14s", st->device_id);
    oled_fb_draw_text(fb, 2, 57, line, true, 1);
    snprintf(line, sizeof(line), "%4.1fcm", st->distance_cm);
    oled_fb_draw_text(fb, 86, 57, line, true, 1);
}

static void render_idle_hud(uint8_t *fb, const oled_hud_state_t *st, oled_ui_mode_t mode, int frame_idx)
{
    if (s_psram_frames == NULL) {
        oled_fb_clear(fb);
        return;
    }

    uint16_t num_frames = s_active_num_frames > 0 ? s_active_num_frames : DANCING_CAT_NUM_FRAMES;
    int safe_idx = frame_idx % num_frames;
    const uint8_t *src_frame = &s_psram_frames[safe_idx * OLED_FRAME_BYTES];

    if (s_is_custom) {
        bool invert = (s_active_flags & WBIN_FLAG_INVERT) != 0;
        bool hud_overlay = (s_active_flags & WBIN_FLAG_HUD_OVERLAY) != 0;

        if (mode == OLED_UI_MODE_MASCOT_ONLY || !hud_overlay) {
            memcpy(fb, src_frame, OLED_FB_BYTES);
            if (invert) {
                for (size_t i = 0; i < OLED_FB_BYTES; i++) {
                    fb[i] = (uint8_t)~fb[i];
                }
            }
            return;
        }

        if (mode == OLED_UI_MODE_SPLIT_DASHBOARD) {
            char line[64];
            oled_fb_clear(fb);

            /* Left half (64x48): Downsampled custom frame */
            for (int x = 0; x < 64; x++) {
                int src_x = x * 2;
                for (int y = 0; y < 48; y++) {
                    int src_y = (y * 64) / 48;
                    bool pix = oled_fb_get_pixel(src_frame, src_x, src_y);
                    if (invert) {
                        pix = !pix;
                    }
                    if (pix) {
                        oled_fb_set_pixel(fb, x, 8 + y, true);
                    }
                }
            }

            /* Vertical divider */
            oled_fb_fill_rect(fb, 64, 8, 1, 48, true);

            /* Right half: Large 2x Fill % + Vertical Tank Gauge */
            snprintf(line, sizeof(line), "%3u%%", (unsigned)st->fill_percent);
            oled_fb_draw_text(fb, 68, 11, line, true, 2);

            snprintf(line, sizeof(line), "%.1fcm", st->distance_cm);
            oled_fb_draw_text(fb, 70, 31, line, true, 1);
            oled_fb_draw_progress_bar(fb, 68, 42, 58, 9, st->fill_percent, true);

            draw_hud_chrome(fb, st, "[CUST]");
            return;
        }

        /* Default: OLED_UI_MODE_HUD_MASCOT with custom animation + HUD bars */
        memcpy(fb, src_frame, OLED_FB_BYTES);
        if (invert) {
            for (size_t i = 0; i < OLED_FB_BYTES; i++) {
                fb[i] = (uint8_t)~fb[i];
            }
        }
        draw_hud_chrome(fb, st, "[CUST]");
        return;
    }

    /* Fallback default Hololive Risu dancing cat mascot */
    if (mode == OLED_UI_MODE_MASCOT_ONLY) {
        memcpy(fb, src_frame, OLED_FB_BYTES);
        return;
    }

    if (mode == OLED_UI_MODE_SPLIT_DASHBOARD) {
        char line[64];
        oled_fb_clear(fb);

        /* Left half (64x48): Horizontally & vertically downsampled mascot */
        for (int x = 0; x < 64; x++) {
            int src_x = x * 2;
            for (int y = 0; y < 48; y++) {
                int src_y = (y * 64) / 48;
                if (oled_fb_get_pixel(src_frame, src_x, src_y)) {
                    oled_fb_set_pixel(fb, x, 8 + y, true);
                }
            }
        }

        /* Vertical divider */
        oled_fb_fill_rect(fb, 64, 8, 1, 48, true);

        /* Right half: Large 2x Fill % + Vertical Tank Gauge */
        snprintf(line, sizeof(line), "%3u%%", (unsigned)st->fill_percent);
        oled_fb_draw_text(fb, 68, 11, line, true, 2);

        snprintf(line, sizeof(line), "%.1fcm", st->distance_cm);
        oled_fb_draw_text(fb, 70, 31, line, true, 1);
        oled_fb_draw_progress_bar(fb, 68, 42, 58, 9, st->fill_percent, true);

        draw_hud_chrome(fb, st, "[IDLE]");
        return;
    }

    /* Default: OLED_UI_MODE_HUD_MASCOT (Full-frame Risu + Top/Bottom HUD bars) */
    memcpy(fb, src_frame, OLED_FB_BYTES);
    draw_hud_chrome(fb, st, "[IDLE]");
}

static void render_warning_modal_overlay(uint8_t *fb, oled_warn_code_t code,
                                         const char *line1, const char *line2,
                                         int64_t now_us, int64_t start_us, int64_t expire_us)
{
    const char *title = "[!] SYSTEM WARNING";
    switch (code) {
        case OLED_WARN_NEAR_FULL:         title = "[!] NEAR CAPACITY"; break;
        case OLED_WARN_PIR_STUCK_TIMEOUT: title = "[!] MOTION TIMEOUT"; break;
        case OLED_WARN_SENSOR_ECHO_ERR:   title = "[!] SENSOR ERROR"; break;
        case OLED_WARN_WIFI_FAILOVER:     title = "[!] WIFI OFFLINE"; break;
        case OLED_WARN_WIFI_RESET:        title = "[i] WIFI CLEARED"; break;
        default: break;
    }

    const int mx = 8;
    const int my = 10;
    const int mw = 112;
    const int mh = 44;

    /* 2px Drop Shadow */
    oled_fb_fill_rect(fb, mx + 2, my + mh, mw, 2, true);
    oled_fb_fill_rect(fb, mx + mw, my + 2, 2, mh, true);

    /* Modal background & border */
    oled_fb_fill_rect(fb, mx, my, mw, mh, false);
    oled_fb_draw_rect(fb, mx, my, mw, mh, true);

    /* Inverted header bar */
    oled_fb_fill_rect(fb, mx, my, mw, 10, true);
    oled_fb_draw_text(fb, mx + 3, my + 2, title, false, 1);

    /* Body lines (max ~17 chars inside 106px width) */
    oled_fb_draw_text(fb, mx + 4, my + 13, line1, true, 1);
    oled_fb_draw_text(fb, mx + 4, my + 23, line2, true, 1);

    /* Remaining modal lifetime countdown bar */
    uint8_t rem_pct = 0;
    int64_t total_us = expire_us - start_us;
    if (total_us > 0 && expire_us > now_us) {
        rem_pct = (uint8_t)(((expire_us - now_us) * 100LL) / total_us);
    }
    oled_fb_draw_progress_bar(fb, mx + 4, my + 34, mw - 8, 6, rem_pct, true);
}

static void oled_anim_task(void *arg)
{
    (void)arg;
    TickType_t last_wake = xTaskGetTickCount();
    int frame_idx = 0;
    int boot_frame = 0;

    ESP_LOGI(TAG, "Core 1 Smart OLED HUD & animation compositor running on Core %d",
             xPortGetCoreID());

    while (1) {
        int64_t now_us = esp_timer_get_time();
        uint32_t timeout_s = s_sleep_timeout_s;

        /* Battery-saver 0xAE display sleep handling (disabled during boot splash, modal, or upload) */
        bool upload_active_check = false;
        taskENTER_CRITICAL(&s_hud_mux);
        upload_active_check = s_upload_active;
        taskEXIT_CRITICAL(&s_hud_mux);

        if (upload_active_check) {
            s_last_activity_us = now_us;
        }

        if (timeout_s > 0 && boot_frame >= OLED_BOOT_SPLASH_FRAMES && !upload_active_check) {
            int64_t idle_us = now_us - s_last_activity_us;
            if (idle_us > ((int64_t)timeout_s * 1000000LL)) {
                if (!s_display_sleeping) {
                    oled_set_hw_invert(false);
                    oled_send_cmd(0xAE);
                    s_display_sleeping = true;
                    ESP_LOGI(TAG, "OLED entered battery-saver sleep (0xAE)");
                }
                vTaskDelay(pdMS_TO_TICKS(200));
                last_wake = xTaskGetTickCount();
                continue;
            } else if (s_display_sleeping) {
                oled_send_cmd(0xAF);
                s_display_sleeping = false;
                ESP_LOGI(TAG, "OLED woke up from sleep (0xAF)");
            }
        } else if (s_display_sleeping) {
            oled_send_cmd(0xAF);
            s_display_sleeping = false;
        }

        /* Lock-free atomic snapshot copy from Core 0 shared state */
        oled_hud_state_t st;
        oled_ui_mode_t ui_mode;
        int64_t result_until_us;
        oled_warn_code_t modal_code;
        char modal_l1[sizeof(s_modal_line1)];
        char modal_l2[sizeof(s_modal_line2)];
        int64_t modal_start;
        int64_t modal_expire;
        bool upload_active;
        uint8_t upload_pct;
        char upload_transport[16];

        taskENTER_CRITICAL(&s_hud_mux);
        st = s_hud_state;
        ui_mode = s_ui_mode;
        result_until_us = s_result_card_until_us;
        modal_code = s_modal_code;
        memcpy(modal_l1, s_modal_line1, sizeof(modal_l1));
        memcpy(modal_l2, s_modal_line2, sizeof(modal_l2));
        modal_start = s_modal_start_us;
        modal_expire = s_modal_expire_us;
        upload_active = s_upload_active;
        upload_pct = s_upload_percent;
        memcpy(upload_transport, s_upload_transport, sizeof(upload_transport));
        taskEXIT_CRITICAL(&s_hud_mux);

        bool use_full_alert = false;

        /* Layer 0 & Layer 1: Select screen mode by priority */
        if (upload_active) {
            render_upload_progress(s_composite_fb, &st, upload_pct, upload_transport);
        } else if (boot_frame < OLED_BOOT_SPLASH_FRAMES) {
            render_boot_splash(s_composite_fb, &st, boot_frame);
            boot_frame++;
        } else if (st.lid_state == LID_STATE_OPENING ||
                   st.lid_state == LID_STATE_OPEN_HOLD ||
                   st.lid_state == LID_STATE_CLOSING ||
                   st.lid_state == LID_STATE_SETTLING) {
            render_lid_active(s_composite_fb, &st);
        } else if (st.lid_state == LID_STATE_MEASURING || now_us < result_until_us) {
            render_measuring_card(s_composite_fb, &st);
        } else if (st.full_alert) {
            use_full_alert = true;
            render_full_alert(s_composite_fb, &st);
        } else if (st.ble_active && !st.mqtt_connected) {
            render_ble_setup(s_composite_fb, &st);
        } else {
            if (s_anim_mutex != NULL) {
                xSemaphoreTake(s_anim_mutex, portMAX_DELAY);
            }
            render_idle_hud(s_composite_fb, &st, ui_mode, frame_idx);
            if (s_anim_mutex != NULL) {
                xSemaphoreGive(s_anim_mutex);
            }
        }

        /* Toggle 1 Hz hardware display inversion while on Full-Bin Alert screen */
        if (use_full_alert) {
            bool invert_phase = (((now_us / 1000000LL) % 2LL) == 1LL);
            oled_set_hw_invert(invert_phase);
        } else {
            oled_set_hw_invert(false);
        }

        /* Layer 2: Non-blocking centered warning popup modal overlay */
        if (modal_code != OLED_WARN_NONE && now_us < modal_expire) {
            render_warning_modal_overlay(s_composite_fb, modal_code, modal_l1, modal_l2,
                                         now_us, modal_start, modal_expire);
        }

        oled_flush_frame(s_composite_fb);

        uint16_t num_frames = s_active_num_frames > 0 ? s_active_num_frames : DANCING_CAT_NUM_FRAMES;
        frame_idx = (frame_idx + 1) % num_frames;

        uint8_t fps = s_active_fps;
        if (fps < 5 || fps > 30) {
            fps = 15;
        }
        TickType_t frame_delay = pdMS_TO_TICKS(1000 / fps);
        if (frame_delay == 0) {
            frame_delay = 1;
        }
        vTaskDelayUntil(&last_wake, frame_delay);
    }
}

esp_err_t oled_dancing_cat_start(uint32_t sleep_timeout_s)
{
    s_sleep_timeout_s = sleep_timeout_s;
    s_last_activity_us = esp_timer_get_time();

    smartbin_config_t *cfg = app_config_get();
    if (cfg != NULL && cfg->oled_ui_mode <= (uint8_t)OLED_UI_MODE_MASCOT_ONLY) {
        s_ui_mode = (oled_ui_mode_t)cfg->oled_ui_mode;
    }

    if (s_anim_mutex == NULL) {
        s_anim_mutex = xSemaphoreCreateMutex();
        if (s_anim_mutex == NULL) {
            ESP_LOGE(TAG, "Failed to create s_anim_mutex");
            return ESP_ERR_NO_MEM;
        }
    }

    /* Pre-render compiled dancing cat frames into PSRAM fallback buffer */
    size_t default_bytes = (size_t)DANCING_CAT_NUM_FRAMES * OLED_FRAME_BYTES;
    s_default_psram_buf = (uint8_t *)heap_caps_malloc(default_bytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (s_default_psram_buf == NULL) {
        s_default_psram_buf = (uint8_t *)heap_caps_malloc(default_bytes, MALLOC_CAP_8BIT);
    }
    if (s_default_psram_buf == NULL) {
        ESP_LOGE(TAG, "Failed to allocate %zu bytes for default OLED frames", default_bytes);
        return ESP_ERR_NO_MEM;
    }

    for (int i = 0; i < DANCING_CAT_NUM_FRAMES; i++) {
        dancing_cat_render_frame(&s_default_psram_buf[i * OLED_FRAME_BYTES], i);
    }
    ESP_LOGI(TAG, "Pre-rendered %d default animation frames (%zu bytes) into PSRAM",
             DANCING_CAT_NUM_FRAMES, default_bytes);

    s_psram_frames = s_default_psram_buf;
    s_active_num_frames = DANCING_CAT_NUM_FRAMES;
    s_active_fps = 15;
    s_active_flags = 0;
    s_is_custom = false;
    s_custom_psram_buf = NULL;

    /* Initialize hardware display */
    oled_hw_init();

    /* Attempt to load custom animation from anim_data partition into PSRAM */
    oled_dancing_cat_reload_anim();

    BaseType_t res = xTaskCreatePinnedToCore(
        oled_anim_task,
        "oled_hud_task",
        4096,
        NULL,
        4,
        NULL,
        1 /* Core 1 */
    );
    return (res == pdPASS) ? ESP_OK : ESP_FAIL;
}

void oled_dancing_cat_notify_activity(void)
{
    s_last_activity_us = esp_timer_get_time();
}

void oled_dancing_cat_set_sleep_timeout(uint32_t sleep_timeout_s)
{
    s_sleep_timeout_s = sleep_timeout_s;
    s_last_activity_us = esp_timer_get_time();
}

void oled_dancing_cat_power_off(void)
{
    oled_set_hw_invert(false);
    oled_send_cmd(0xAE);
    s_display_sleeping = true;
}

void oled_hud_set_ui_mode(oled_ui_mode_t mode)
{
    taskENTER_CRITICAL(&s_hud_mux);
    s_ui_mode = mode;
    taskEXIT_CRITICAL(&s_hud_mux);
    oled_dancing_cat_notify_activity();
}

void oled_hud_update(const oled_hud_state_t *state)
{
    if (state == NULL) {
        return;
    }
    taskENTER_CRITICAL(&s_hud_mux);
    s_hud_state = *state;
    taskEXIT_CRITICAL(&s_hud_mux);
}

void oled_hud_set_network_state(const char *device_id, bool wifi_connected,
                                bool mqtt_connected, bool ble_active, int8_t wifi_rssi)
{
    taskENTER_CRITICAL(&s_hud_mux);
    if (device_id != NULL && device_id[0] != '\0') {
        snprintf(s_hud_state.device_id, sizeof(s_hud_state.device_id), "%s", device_id);
    }
    s_hud_state.wifi_connected = wifi_connected;
    s_hud_state.mqtt_connected = mqtt_connected;
    s_hud_state.ble_active = ble_active;
    s_hud_state.wifi_rssi = wifi_rssi;
    taskEXIT_CRITICAL(&s_hud_mux);
}

void oled_hud_set_sensor_state(uint8_t fill_percent, float distance_cm, bool full_alert,
                               smartbin_trigger_t trigger, uint32_t open_cycles)
{
    int64_t now_us = esp_timer_get_time();
    taskENTER_CRITICAL(&s_hud_mux);
    s_hud_state.fill_percent = fill_percent;
    s_hud_state.distance_cm = distance_cm;
    s_hud_state.full_alert = full_alert;
    s_hud_state.last_trigger = trigger;
    s_hud_state.open_cycles = open_cycles;
    s_result_card_until_us = now_us + OLED_RESULT_HOLD_US;
    taskEXIT_CRITICAL(&s_hud_mux);
}

void oled_hud_set_lid_state(smartbin_lid_state_t lid_state, uint16_t hold_rem_ds,
                            uint16_t hold_total_ds, bool pir_active, uint32_t open_cycles)
{
    taskENTER_CRITICAL(&s_hud_mux);
    s_hud_state.lid_state = lid_state;
    s_hud_state.lid_hold_rem_ds = hold_rem_ds;
    s_hud_state.lid_hold_total_ds = hold_total_ds;
    s_hud_state.pir_active = pir_active;
    s_hud_state.open_cycles = open_cycles;
    taskEXIT_CRITICAL(&s_hud_mux);
}

void oled_hud_show_warning(oled_warn_code_t code, const char *line1,
                           const char *line2, uint32_t duration_ms)
{
    int64_t now_us = esp_timer_get_time();
    s_last_activity_us = now_us;

    taskENTER_CRITICAL(&s_hud_mux);
    s_modal_code = code;
    snprintf(s_modal_line1, sizeof(s_modal_line1), "%s", (line1 != NULL) ? line1 : "");
    snprintf(s_modal_line2, sizeof(s_modal_line2), "%s", (line2 != NULL) ? line2 : "");
    s_modal_start_us = now_us;
    s_modal_expire_us = now_us + ((int64_t)duration_ms * 1000LL);
    taskEXIT_CRITICAL(&s_hud_mux);
}

void oled_hud_set_upload_progress(bool active, uint8_t percent, const char *transport_name)
{
    taskENTER_CRITICAL(&s_hud_mux);
    s_upload_active = active;
    s_upload_percent = (percent > 100U) ? 100U : percent;
    if (transport_name != NULL) {
        snprintf(s_upload_transport, sizeof(s_upload_transport), "%s", transport_name);
    } else {
        s_upload_transport[0] = '\0';
    }
    taskEXIT_CRITICAL(&s_hud_mux);
    oled_dancing_cat_notify_activity();
}

esp_err_t oled_dancing_cat_reload_anim(void)
{
    uint8_t *new_frames = NULL;
    uint16_t new_num = 0;
    uint8_t new_fps = 0;

    esp_err_t err = anim_storage_load_to_psram(&new_frames, &new_num, &new_fps);
    if (err == ESP_OK && new_frames != NULL) {
        uint8_t flags = anim_storage_get_flags();
        uint8_t *old_custom = NULL;

        if (s_anim_mutex != NULL) {
            xSemaphoreTake(s_anim_mutex, portMAX_DELAY);
        }
        old_custom = s_custom_psram_buf;
        s_custom_psram_buf = new_frames;
        s_psram_frames = s_custom_psram_buf;
        s_active_num_frames = new_num;
        s_active_fps = new_fps;
        s_active_flags = flags;
        s_is_custom = true;
        if (s_anim_mutex != NULL) {
            xSemaphoreGive(s_anim_mutex);
        }

        if (old_custom != NULL) {
            heap_caps_free(old_custom);
        }

        ESP_LOGI(TAG, "Swapped to custom animation: %" PRIu16 " frames @ %" PRIu8 " FPS (flags: 0x%02X)",
                 new_num, new_fps, flags);
        return ESP_OK;
    }

    ESP_LOGI(TAG, "Custom animation not loaded (%s), using default dancing cat fallback",
             esp_err_to_name(err));
    return oled_dancing_cat_reset_anim();
}

esp_err_t oled_dancing_cat_reset_anim(void)
{
    uint8_t *old_custom = NULL;

    if (s_anim_mutex != NULL) {
        xSemaphoreTake(s_anim_mutex, portMAX_DELAY);
    }
    old_custom = s_custom_psram_buf;
    s_custom_psram_buf = NULL;
    s_psram_frames = s_default_psram_buf;
    s_active_num_frames = DANCING_CAT_NUM_FRAMES;
    s_active_fps = 15;
    s_active_flags = 0;
    s_is_custom = false;
    if (s_anim_mutex != NULL) {
        xSemaphoreGive(s_anim_mutex);
    }

    if (old_custom != NULL) {
        heap_caps_free(old_custom);
    }

    ESP_LOGI(TAG, "Active animation reset to compiled dancing cat fallback (%d frames @ 15 FPS)",
             DANCING_CAT_NUM_FRAMES);
    return ESP_OK;
}

bool oled_dancing_cat_is_custom_anim(void)
{
    bool is_cust;
    if (s_anim_mutex != NULL) {
        xSemaphoreTake(s_anim_mutex, portMAX_DELAY);
    }
    is_cust = s_is_custom;
    if (s_anim_mutex != NULL) {
        xSemaphoreGive(s_anim_mutex);
    }
    return is_cust;
}

uint16_t oled_dancing_cat_get_num_frames(void)
{
    uint16_t num;
    if (s_anim_mutex != NULL) {
        xSemaphoreTake(s_anim_mutex, portMAX_DELAY);
    }
    num = s_active_num_frames;
    if (s_anim_mutex != NULL) {
        xSemaphoreGive(s_anim_mutex);
    }
    return num;
}

esp_err_t oled_anim_load_from_partition(void)
{
    return oled_dancing_cat_reload_anim();
}

esp_err_t oled_anim_reset_to_default(void)
{
    anim_storage_erase();
    return oled_dancing_cat_reset_anim();
}

esp_err_t oled_anim_commit_and_reload(const uint8_t *wbin_data, size_t total_len)
{
    esp_err_t err = anim_storage_save_from_buffer(wbin_data, total_len);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to commit animation to partition: %s", esp_err_to_name(err));
        return err;
    }
    return oled_dancing_cat_reload_anim();
}
