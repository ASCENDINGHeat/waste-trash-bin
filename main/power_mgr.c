#include "power_mgr.h"
#include <inttypes.h>
#include "sdkconfig.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/gpio.h"
#include "driver/rtc_io.h"
#include "esp_pm.h"
#include "esp_log.h"

static const char *TAG = "power_mgr";

esp_err_t power_mgr_init(void)
{
#if CONFIG_SMARTBIN_POWER_5V_EN_GPIO >= 0
    gpio_config_t io_conf = {
        .pin_bit_mask = (1ULL << CONFIG_SMARTBIN_POWER_5V_EN_GPIO),
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&io_conf));
    gpio_set_level((gpio_num_t)CONFIG_SMARTBIN_POWER_5V_EN_GPIO, 1);
    ESP_LOGI(TAG, "5V peripheral rail gate initialized on GPIO %d", CONFIG_SMARTBIN_POWER_5V_EN_GPIO);
#endif

#if CONFIG_PM_ENABLE
    esp_pm_config_t pm_config = {
        .max_freq_mhz = 240,
        .min_freq_mhz = 40,
#if CONFIG_FREERTOS_USE_TICKLESS_IDLE
        .light_sleep_enable = true,
#else
        .light_sleep_enable = false,
#endif
    };
    esp_err_t err = esp_pm_configure(&pm_config);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "esp_pm_configure returned %s (continuing at default clock)", esp_err_to_name(err));
    } else {
        ESP_LOGI(TAG, "DFS enabled (40 MHz <-> 240 MHz, auto light-sleep=%d)", pm_config.light_sleep_enable);
    }
#endif
    return ESP_OK;
}

void power_mgr_set_5v_rail(bool enable)
{
#if CONFIG_SMARTBIN_POWER_5V_EN_GPIO >= 0
    gpio_set_level((gpio_num_t)CONFIG_SMARTBIN_POWER_5V_EN_GPIO, enable ? 1 : 0);
    if (enable) {
        /* Allow 5V boost rail and HC-SR04 internal reference to stabilize */
        vTaskDelay(pdMS_TO_TICKS(30));
    }
#else
    (void)enable;
#endif
}

esp_sleep_wakeup_cause_t power_mgr_get_wakeup_cause(void)
{
    return esp_sleep_get_wakeup_cause();
}

void power_mgr_enter_deep_sleep(uint32_t periodic_interval_s)
{
    ESP_LOGI(TAG, "Preparing Deep Sleep: PIR ext0 wakeup on GPIO %d + Timer %" PRIu32 "s",
             CONFIG_SMARTBIN_PIR_GPIO, periodic_interval_s);

    /* Gate off the 5V rail (SG90 + HC-SR04) during Deep Sleep to save battery */
    power_mgr_set_5v_rail(false);

    /* Configure RTC_GPIO2 (GPIO 2) for ext0 wakeup on HIGH level from HC-SR501 */
    gpio_num_t pir_pin = (gpio_num_t)CONFIG_SMARTBIN_PIR_GPIO;
    if (esp_sleep_is_valid_wakeup_gpio(pir_pin)) {
        rtc_gpio_init(pir_pin);
        rtc_gpio_set_direction(pir_pin, RTC_GPIO_MODE_INPUT_ONLY);
        rtc_gpio_pulldown_en(pir_pin);
        rtc_gpio_pullup_dis(pir_pin);
        esp_sleep_enable_ext0_wakeup(pir_pin, 1);
    }

    /* Configure periodic timer wakeup for background ultrasonic level checks */
    if (periodic_interval_s > 0) {
        uint64_t sleep_us = (uint64_t)periodic_interval_s * 1000000ULL;
        esp_sleep_enable_timer_wakeup(sleep_us);
    }

    esp_deep_sleep_start();
}
