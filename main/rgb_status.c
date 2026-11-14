#include "rgb_status.h"
#include "sdkconfig.h"
#include "led_strip.h"
#include "esp_timer.h"
#include "esp_log.h"

static const char *TAG = "rgb_status";

static led_strip_handle_t s_led_strip = NULL;
static esp_timer_handle_t s_off_timer = NULL;
static bool s_ble_active = false;

static void rgb_set_rgb(uint8_t r, uint8_t g, uint8_t b)
{
    if (s_led_strip == NULL) {
        return;
    }
    if (r == 0 && g == 0 && b == 0) {
        led_strip_clear(s_led_strip);
    } else {
        led_strip_set_pixel(s_led_strip, 0, r, g, b);
        led_strip_refresh(s_led_strip);
    }
}

static void rgb_auto_off_cb(void *arg)
{
    (void)arg;
    if (s_ble_active) {
        /* Return to dim blue if BLE setup/failover is still active */
        rgb_set_rgb(0, 8, 32);
    } else {
        rgb_set_rgb(0, 0, 0);
    }
}

esp_err_t rgb_status_init(void)
{
    led_strip_config_t strip_config = {
        .strip_gpio_num = CONFIG_SMARTBIN_RGB_LED_GPIO,
        .max_leds = 1,
        .led_model = LED_MODEL_WS2812,
        .color_component_format = LED_STRIP_COLOR_COMPONENT_FMT_GRB,
        .flags = {
            .invert_out = false,
        },
    };

    led_strip_rmt_config_t rmt_config = {
        .clk_src = RMT_CLK_SRC_DEFAULT,
        .resolution_hz = 10 * 1000 * 1000, /* 10 MHz */
        .mem_block_symbols = 64,
        .flags = {
            .with_dma = false,
        },
    };

    esp_err_t err = led_strip_new_rmt_device(&strip_config, &rmt_config, &s_led_strip);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "WS2812 init on GPIO %d returned %s",
                 CONFIG_SMARTBIN_RGB_LED_GPIO, esp_err_to_name(err));
        return err;
    }

    led_strip_clear(s_led_strip);

    const esp_timer_create_args_t timer_args = {
        .callback = &rgb_auto_off_cb,
        .name = "rgb_auto_off",
    };
    esp_timer_create(&timer_args, &s_off_timer);

    ESP_LOGI(TAG, "WS2812B RGB status LED initialized on GPIO %d", CONFIG_SMARTBIN_RGB_LED_GPIO);
    return ESP_OK;
}

void rgb_status_show_fill_level(uint8_t fill_percent)
{
    if (s_led_strip == NULL) {
        return;
    }

    if (fill_percent < 50) {
        rgb_set_rgb(0, 32, 0);    /* Green */
    } else if (fill_percent < 85) {
        rgb_set_rgb(36, 20, 0);   /* Yellow / Amber */
    } else {
        rgb_set_rgb(48, 0, 0);    /* Red (Full alert) */
    }

    if (s_off_timer != NULL) {
        esp_timer_stop(s_off_timer);
        esp_timer_start_once(s_off_timer, 5ULL * 1000000ULL); /* Auto-off after 5s */
    }
}

void rgb_status_set_ble_active(bool ble_active)
{
    s_ble_active = ble_active;
    if (ble_active) {
        rgb_set_rgb(0, 8, 32); /* Blue indicator for BLE provisioning / failover */
    } else {
        rgb_set_rgb(0, 0, 0);
    }
}

void rgb_status_off(void)
{
    if (s_off_timer != NULL) {
        esp_timer_stop(s_off_timer);
    }
    rgb_set_rgb(0, 0, 0);
}
