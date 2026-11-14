#include "app_config.h"
#include <string.h>
#include <inttypes.h>
#include "nvs_flash.h"
#include "nvs.h"
#include "esp_log.h"

static const char *TAG = "app_config";
static const char *NVS_NAMESPACE = "smartbin";

static smartbin_config_t s_config;

smartbin_config_t *app_config_get(void)
{
    return &s_config;
}

esp_err_t app_config_load(smartbin_config_t *cfg)
{
    if (cfg == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    /* Populate defaults from Kconfig */
    memset(cfg, 0, sizeof(*cfg));
    strncpy(cfg->wifi_ssid, CONFIG_SMARTBIN_DEFAULT_WIFI_SSID, sizeof(cfg->wifi_ssid) - 1);
    strncpy(cfg->wifi_pass, CONFIG_SMARTBIN_DEFAULT_WIFI_PASS, sizeof(cfg->wifi_pass) - 1);
    strncpy(cfg->mqtt_uri, CONFIG_SMARTBIN_DEFAULT_MQTT_URI, sizeof(cfg->mqtt_uri) - 1);
    cfg->full_dist_cm         = (float)CONFIG_SMARTBIN_FULL_DIST_CM;
    cfg->empty_dist_cm        = (float)CONFIG_SMARTBIN_EMPTY_DIST_CM;
    cfg->periodic_interval_s  = (uint32_t)CONFIG_SMARTBIN_PERIODIC_INTERVAL_SEC;
    cfg->oled_sleep_timeout_s = (uint32_t)CONFIG_SMARTBIN_OLED_SLEEP_TIMEOUT_SEC;
    cfg->servo_open_angle     = (uint8_t)CONFIG_SMARTBIN_SERVO_OPEN_ANGLE;
    cfg->servo_closed_angle   = (uint8_t)CONFIG_SMARTBIN_SERVO_CLOSED_ANGLE;
    cfg->hold_open_s          = (uint8_t)CONFIG_SMARTBIN_HOLD_OPEN_SEC;
    cfg->open_cycles          = 0;
#ifdef CONFIG_SMARTBIN_ENABLE_DEEP_SLEEP
    cfg->deep_sleep_enabled   = true;
#else
    cfg->deep_sleep_enabled   = false;
#endif

    nvs_handle_t handle;
    esp_err_t err = nvs_open(NVS_NAMESPACE, NVS_READONLY, &handle);
    if (err == ESP_ERR_NVS_NOT_FOUND) {
        ESP_LOGI(TAG, "No saved NVS config found; using Kconfig defaults");
        return ESP_OK;
    } else if (err != ESP_OK) {
        ESP_LOGW(TAG, "Failed to open NVS (%s); using defaults", esp_err_to_name(err));
        return err;
    }

    size_t len = sizeof(cfg->wifi_ssid);
    nvs_get_str(handle, "wifi_ssid", cfg->wifi_ssid, &len);

    len = sizeof(cfg->wifi_pass);
    nvs_get_str(handle, "wifi_pass", cfg->wifi_pass, &len);

    len = sizeof(cfg->mqtt_uri);
    nvs_get_str(handle, "mqtt_uri", cfg->mqtt_uri, &len);

    int32_t full_mm = 0;
    if (nvs_get_i32(handle, "full_mm", &full_mm) == ESP_OK && full_mm > 0) {
        cfg->full_dist_cm = (float)full_mm / 10.0f;
    }

    int32_t empty_mm = 0;
    if (nvs_get_i32(handle, "empty_mm", &empty_mm) == ESP_OK && empty_mm > 0) {
        cfg->empty_dist_cm = (float)empty_mm / 10.0f;
    }

    uint32_t u32_val = 0;
    if (nvs_get_u32(handle, "periodic_s", &u32_val) == ESP_OK && u32_val >= 30) {
        cfg->periodic_interval_s = u32_val;
    }
    if (nvs_get_u32(handle, "oled_sleep_s", &u32_val) == ESP_OK) {
        cfg->oled_sleep_timeout_s = u32_val;
    }
    if (nvs_get_u32(handle, "open_cycles", &u32_val) == ESP_OK) {
        cfg->open_cycles = u32_val;
    }

    uint8_t u8_val = 0;
    if (nvs_get_u8(handle, "deep_sleep", &u8_val) == ESP_OK) {
        cfg->deep_sleep_enabled = (u8_val != 0);
    }

    nvs_close(handle);
    ESP_LOGI(TAG, "Loaded NVS config: SSID='%s', MQTT='%s', Full=%.1fcm, Empty=%.1fcm, Cycles=%" PRIu32,
             cfg->wifi_ssid, cfg->mqtt_uri, cfg->full_dist_cm, cfg->empty_dist_cm, cfg->open_cycles);
    return ESP_OK;
}

esp_err_t app_config_save(const smartbin_config_t *cfg)
{
    if (cfg == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    nvs_handle_t handle;
    esp_err_t err = nvs_open(NVS_NAMESPACE, NVS_READWRITE, &handle);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "nvs_open failed: %s", esp_err_to_name(err));
        return err;
    }

    nvs_set_str(handle, "wifi_ssid", cfg->wifi_ssid);
    nvs_set_str(handle, "wifi_pass", cfg->wifi_pass);
    nvs_set_str(handle, "mqtt_uri", cfg->mqtt_uri);
    nvs_set_i32(handle, "full_mm", (int32_t)(cfg->full_dist_cm * 10.0f));
    nvs_set_i32(handle, "empty_mm", (int32_t)(cfg->empty_dist_cm * 10.0f));
    nvs_set_u32(handle, "periodic_s", cfg->periodic_interval_s);
    nvs_set_u32(handle, "oled_sleep_s", cfg->oled_sleep_timeout_s);
    nvs_set_u32(handle, "open_cycles", cfg->open_cycles);
    nvs_set_u8(handle, "deep_sleep", cfg->deep_sleep_enabled ? 1 : 0);

    err = nvs_commit(handle);
    nvs_close(handle);
    return err;
}

uint32_t app_config_increment_cycles(smartbin_config_t *cfg)
{
    if (cfg == NULL) {
        return 0;
    }
    cfg->open_cycles++;

    nvs_handle_t handle;
    if (nvs_open(NVS_NAMESPACE, NVS_READWRITE, &handle) == ESP_OK) {
        nvs_set_u32(handle, "open_cycles", cfg->open_cycles);
        nvs_commit(handle);
        nvs_close(handle);
    }
    return cfg->open_cycles;
}
