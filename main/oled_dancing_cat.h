#ifndef OLED_DANCING_CAT_H
#define OLED_DANCING_CAT_H

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"
#include "app_config.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Idle OLED HUD layout modes selectable via NVS / MQTT / BLE configure
 */
typedef enum {
    OLED_UI_MODE_HUD_MASCOT = 0,   /* Mascot animation + Top/Bottom HUD bars */
    OLED_UI_MODE_SPLIT_DASHBOARD,  /* 64px Mascot + 64px Large Fill Gauge    */
    OLED_UI_MODE_MASCOT_ONLY       /* Fullscreen GIF when idle, HUD on event */
} oled_ui_mode_t;

/**
 * @brief Warning popup modal severity/cause codes
 */
typedef enum {
    OLED_WARN_NONE = 0,
    OLED_WARN_NEAR_FULL,           /* 85% - 94% fill warning modal           */
    OLED_WARN_PIR_STUCK_TIMEOUT,   /* 30s PIR stuck-sensor safety close      */
    OLED_WARN_SENSOR_ECHO_ERR,     /* HC-SR04 ultrasonic echo timeout        */
    OLED_WARN_WIFI_FAILOVER,       /* Wi-Fi disconnected -> BLE failover     */
    OLED_WARN_WIFI_RESET,          /* NVS Wi-Fi credentials cleared          */
    OLED_WARN_BLE_ACTIVE           /* BOOT button BLE/IP info modal          */
} oled_warn_code_t;

/**
 * @brief Lock-free shared snapshot rendered by Core 1 Smart OLED HUD compositor
 */
typedef struct {
    char device_id[32];
    uint8_t fill_percent;
    float distance_cm;
    bool full_alert;
    smartbin_lid_state_t lid_state;
    smartbin_trigger_t last_trigger;
    uint32_t open_cycles;
    int8_t wifi_rssi;
    bool wifi_connected;
    bool mqtt_connected;
    bool ble_active;
    uint16_t lid_hold_rem_ds;      /* Remaining hold time in 0.1s units */
    uint16_t lid_hold_total_ds;    /* Configured total hold time in 0.1s units */
    bool pir_active;
} oled_hud_state_t;

/**
 * @brief Initialize the I2C OLED display (SCL = GPIO 6, SDA = GPIO 7),
 *        cache the 85-frame animation in 8 MB Octal PSRAM, and start the
 *        dedicated Core 1 Smart OLED HUD & animation compositor task.
 */
esp_err_t oled_dancing_cat_start(uint32_t sleep_timeout_s);

/**
 * @brief Notify the OLED task of activity (used only when battery-saver
 *        sleep_timeout_s > 0 to wake the display from 0xAE sleep).
 */
void oled_dancing_cat_notify_activity(void);

/**
 * @brief Dynamically update the OLED battery-saver sleep timeout (0 = Always On).
 */
void oled_dancing_cat_set_sleep_timeout(uint32_t sleep_timeout_s);

/**
 * @brief Put the OLED panel into ultra-low-power sleep (0xAE, <10 uA) before Deep Sleep.
 */
void oled_dancing_cat_power_off(void);

/**
 * @brief Update the idle OLED UI layout mode.
 */
void oled_hud_set_ui_mode(oled_ui_mode_t mode);

/**
 * @brief Replace the full shared Core 1 HUD state snapshot.
 */
void oled_hud_update(const oled_hud_state_t *state);

/**
 * @brief Update network/connectivity fields inside the shared HUD snapshot.
 */
void oled_hud_set_network_state(const char *device_id, bool wifi_connected,
                                bool mqtt_connected, bool ble_active, int8_t wifi_rssi);

/**
 * @brief Update ultrasonic measurement fields and show the 3s result card.
 */
void oled_hud_set_sensor_state(uint8_t fill_percent, float distance_cm, bool full_alert,
                               smartbin_trigger_t trigger, uint32_t open_cycles);

/**
 * @brief Update active lid state and live hold countdown inside the HUD snapshot.
 */
void oled_hud_set_lid_state(smartbin_lid_state_t lid_state, uint16_t hold_rem_ds,
                            uint16_t hold_total_ds, bool pir_active, uint32_t open_cycles);

/**
 * @brief Trigger a non-blocking centered warning popup modal over the active screen.
 */
void oled_hud_show_warning(oled_warn_code_t code, const char *line1,
                           const char *line2, uint32_t duration_ms);

/**
 * @brief Show or hide live upload progress overlay on the OLED display.
 *        Renders "UPLOADING GIF: XX%" with an animated progress bar and
 *        transport indicator while an upload is streaming over LAN HTTP,
 *        BLE 0xFF07, or MQTT.
 *
 * @param active         true to activate the upload progress screen, false to restore normal HUD
 * @param percent        0 to 100 percent
 * @param transport_name optional transport label (e.g. "BLE", "HTTP", "MQTT")
 */
void oled_hud_set_upload_progress(bool active, uint8_t percent, const char *transport_name);

/**
 * @brief Reload custom animation from anim_data partition into PSRAM.
 *        If partition is blank/corrupt/absent, restores compiled dancing cat mascot.
 *        Thread-safe under s_anim_mutex.
 *
 * @return ESP_OK on success, or error code.
 */
esp_err_t oled_dancing_cat_reload_anim(void);

/**
 * @brief Reset custom animation, invalidate partition header, and restore
 *        compiled dancing cat fallback mascot. Thread-safe under s_anim_mutex.
 *
 * @return ESP_OK on success, or error code.
 */
esp_err_t oled_dancing_cat_reset_anim(void);

/**
 * @brief Check if custom animation is currently active.
 *
 * @return true if playing custom wbin animation, false if playing compiled dancing cat.
 */
bool oled_dancing_cat_is_custom_anim(void);

/**
 * @brief Get the number of frames in the currently active animation.
 *
 * @return Frame count (85 for default dancing cat, 1..512 for custom).
 */
uint16_t oled_dancing_cat_get_num_frames(void);

/**
 * @brief Load animation from partition (convenience wrapper for oled_dancing_cat_reload_anim).
 */
esp_err_t oled_anim_load_from_partition(void);

/**
 * @brief Reset to default compiled mascot and erase partition sector 0
 *        (convenience wrapper for oled_dancing_cat_reset_anim).
 */
esp_err_t oled_anim_reset_to_default(void);

/**
 * @brief Commit verified .wbin payload to flash and swap into active PSRAM playback.
 */
esp_err_t oled_anim_commit_and_reload(const uint8_t *wbin_data, size_t total_len);

#ifdef __cplusplus
}
#endif

#endif /* OLED_DANCING_CAT_H */
