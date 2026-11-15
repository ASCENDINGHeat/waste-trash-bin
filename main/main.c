#include <stdio.h>
#include <inttypes.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "nvs_flash.h"
#include "esp_log.h"

#include "app_config.h"
#include "power_mgr.h"
#include "servo_sg90.h"
#include "ultrasonic_hcsr04.h"
#include "rgb_status.h"
#include "oled_dancing_cat.h"
#include "net_ble_mqtt.h"
#include "trash_bin_fsm.h"

static const char *TAG = "app_main";

static void on_remote_config_updated(const smartbin_config_t *new_cfg)
{
    if (new_cfg != NULL) {
        trash_bin_fsm_reload_timer(new_cfg->periodic_interval_s);
    }
}

void app_main(void)
{
    ESP_LOGI(TAG, "=== W.A.S.T.E. (Waste Automation and Sensing Technology Engine) | ESP-IDF v6.1 ===");

    /* 1. Initialize NVS Flash and load persisted configuration */
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);

    smartbin_config_t *cfg = app_config_get();
    app_config_load(cfg);

    /* 2. Initialize Power Manager (DFS 40<->240MHz, Light Sleep, 5V Rail Gate) */
    esp_sleep_wakeup_cause_t wakeup_cause = power_mgr_get_wakeup_cause();
    ESP_ERROR_CHECK(power_mgr_init());

    /* 3. Start independent Core 1 OLED "Chinese Dancing Cat" GIF engine (SCL=6, SDA=7) */
    ESP_ERROR_CHECK(oled_dancing_cat_start(cfg->oled_sleep_timeout_s));

    /* 4. Initialize Onboard WS2812B Status RGB LED (GPIO 48), SG90 Servo (GPIO 21), and HC-SR04 (GPIO 5, 18) */
    rgb_status_init();
    ESP_ERROR_CHECK(servo_sg90_init(cfg->servo_closed_angle));
    ESP_ERROR_CHECK(ultrasonic_hcsr04_init());

    /* 5. Initialize Wi-Fi STA, NimBLE Provisioning/Failover, MQTT Client & PSRAM Ring Buffer */
    const net_cmd_callbacks_t net_cbs = {
        .on_measure_now    = trash_bin_fsm_trigger_measure_now,
        .on_open_lid       = trash_bin_fsm_trigger_remote_open,
        .on_config_updated = on_remote_config_updated,
    };
    ESP_ERROR_CHECK(net_ble_mqtt_init(&net_cbs));

    /* 6. Start Core 0 Smart Trash Bin Finite State Machine (PIR GPIO 2 + Periodic Timer) */
    ESP_ERROR_CHECK(trash_bin_fsm_start(wakeup_cause));

    ESP_LOGI(TAG, "All subsystems started successfully.");
}
