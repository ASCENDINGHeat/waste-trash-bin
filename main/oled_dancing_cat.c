#include "oled_dancing_cat.h"
#include "dancing_cat_frames.h"
#include "sdkconfig.h"
#include <inttypes.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/i2c_master.h"
#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "esp_log.h"

static const char *TAG = "oled_cat";

#define OLED_I2C_PORT         I2C_NUM_0
#define OLED_I2C_FREQ_HZ      400000
#define OLED_I2C_TIMEOUT_MS   50

static i2c_master_bus_handle_t s_i2c_bus = NULL;
static i2c_master_dev_handle_t s_oled_dev = NULL;
static uint8_t *s_psram_frames = NULL;
static volatile uint32_t s_sleep_timeout_s = 0;
static volatile int64_t s_last_activity_us = 0;
static bool s_display_sleeping = false;

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

    /* Standard SSD1306 / SH1106 128x64 initialization sequence */
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
        oled_send_cmd((uint8_t)(0xB0U | page)); /* Set page start address (0..7) */
        oled_send_cmd(0x00U);                   /* Lower column start address */
        oled_send_cmd(0x10U);                   /* Higher column start address */

        memcpy(&page_tx[1], &frame_buf[page * OLED_WIDTH], OLED_WIDTH);
        i2c_master_transmit(s_oled_dev, page_tx, sizeof(page_tx), OLED_I2C_TIMEOUT_MS);
    }
}

static void oled_anim_task(void *arg)
{
    (void)arg;
    const TickType_t frame_delay = pdMS_TO_TICKS(1000 / CONFIG_SMARTBIN_OLED_FPS);
    TickType_t last_wake = xTaskGetTickCount();
    int frame_idx = 0;

    ESP_LOGI(TAG, "Chinese Dancing Cat animation task running on Core %d (%d FPS)",
             xPortGetCoreID(), CONFIG_SMARTBIN_OLED_FPS);

    while (1) {
        uint32_t timeout_s = s_sleep_timeout_s;
        if (timeout_s > 0) {
            int64_t idle_us = esp_timer_get_time() - s_last_activity_us;
            if (idle_us > ((int64_t)timeout_s * 1000000LL)) {
                if (!s_display_sleeping) {
                    oled_send_cmd(0xAE); /* SSD1306_DISPLAY_OFF (<10 uA) */
                    s_display_sleeping = true;
                    ESP_LOGI(TAG, "OLED entered battery-saver sleep (0xAE)");
                }
                vTaskDelay(pdMS_TO_TICKS(200));
                last_wake = xTaskGetTickCount();
                continue;
            } else if (s_display_sleeping) {
                oled_send_cmd(0xAF); /* SSD1306_DISPLAY_ON */
                s_display_sleeping = false;
                ESP_LOGI(TAG, "OLED woke up from sleep (0xAF)");
            }
        } else if (s_display_sleeping) {
            oled_send_cmd(0xAF);
            s_display_sleeping = false;
        }

        const uint8_t *frame_ptr = &s_psram_frames[frame_idx * OLED_FRAME_BYTES];
        oled_flush_frame(frame_ptr);

        frame_idx = (frame_idx + 1) % DANCING_CAT_NUM_FRAMES;
        vTaskDelayUntil(&last_wake, frame_delay);
    }
}

esp_err_t oled_dancing_cat_start(uint32_t sleep_timeout_s)
{
    s_sleep_timeout_s = sleep_timeout_s;
    s_last_activity_us = esp_timer_get_time();

    /* Allocate animation frame buffer in 8 MB Octal PSRAM (fallback to internal RAM) */
    size_t total_bytes = (size_t)DANCING_CAT_NUM_FRAMES * OLED_FRAME_BYTES;
    s_psram_frames = (uint8_t *)heap_caps_malloc(total_bytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (s_psram_frames == NULL) {
        s_psram_frames = (uint8_t *)heap_caps_malloc(total_bytes, MALLOC_CAP_8BIT);
    }
    if (s_psram_frames == NULL) {
        ESP_LOGE(TAG, "Failed to allocate %u bytes for OLED frames", (unsigned)total_bytes);
        return ESP_ERR_NO_MEM;
    }

    /* Pre-render all 16 frames of the Chinese Dancing Cat GIF into PSRAM */
    for (int i = 0; i < DANCING_CAT_NUM_FRAMES; i++) {
        dancing_cat_render_frame(&s_psram_frames[i * OLED_FRAME_BYTES], i);
    }
    ESP_LOGI(TAG, "Pre-rendered %d Dancing Cat frames (%u bytes) into PSRAM",
             DANCING_CAT_NUM_FRAMES, (unsigned)total_bytes);

    oled_hw_init();

    /* Pin OLED task exclusively to Core 1 so Core 0 Wi-Fi/BLE/Sensors never jitter FPS */
    BaseType_t res = xTaskCreatePinnedToCore(
        oled_anim_task,
        "oled_cat_task",
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
    oled_send_cmd(0xAE);
    s_display_sleeping = true;
}
