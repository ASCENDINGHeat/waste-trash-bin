#ifndef APP_CONFIG_H
#define APP_CONFIG_H

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"
#include "sdkconfig.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Lid mechanical states for the Smart Trash Bin FSM
 */
typedef enum {
    LID_STATE_CLOSED = 0,
    LID_STATE_OPENING,
    LID_STATE_OPEN_HOLD,
    LID_STATE_CLOSING,
    LID_STATE_SETTLING,
    LID_STATE_MEASURING,
    LID_STATE_COOLDOWN
} smartbin_lid_state_t;

/**
 * @brief Trigger source for an ultrasonic fill-level telemetry event
 */
typedef enum {
    TRIGGER_LID_CLOSE = 0,
    TRIGGER_PERIODIC,
    TRIGGER_REMOTE_CMD,
    TRIGGER_BOOT
} smartbin_trigger_t;

/**
 * @brief Runtime configuration persisted in NVS ("smartbin" namespace)
 */
typedef struct {
    char wifi_ssid[33];
    char wifi_pass[65];
    char mqtt_uri[128];
    float full_dist_cm;            /* Default: 10.0 cm -> 100% */
    float empty_dist_cm;           /* Default: 30.0 cm -> 0%   */
    uint32_t periodic_interval_s;  /* Default: 900 s (15 min)  */
    uint32_t oled_sleep_timeout_s; /* 0 = Always On, >0 = sleep timeout */
    uint8_t oled_ui_mode;          /* 0 = hud_mascot, 1 = split_dashboard, 2 = mascot_only */
    uint8_t servo_open_angle;      /* Default: 90 deg */
    uint8_t servo_closed_angle;    /* Default: 0 deg  */
    uint8_t hold_open_s;           /* Default: 3 s    */
    uint32_t open_cycles;          /* Persisted total lid open counter */
    bool deep_sleep_enabled;       /* Deep sleep between events */
} smartbin_config_t;

/**
 * @brief Single telemetry snapshot for MQTT publishing, PSRAM buffering, and BLE GATT
 */
typedef struct {
    smartbin_trigger_t trigger;
    uint8_t fill_percent;
    float distance_cm;
    bool full_alert;
    smartbin_lid_state_t lid_state;
    uint32_t open_cycles;
    int8_t wifi_rssi;
    uint32_t uptime_s;
} smartbin_telemetry_t;

/**
 * @brief Load configuration from NVS (falling back to Kconfig defaults)
 */
esp_err_t app_config_load(smartbin_config_t *cfg);

/**
 * @brief Save configuration to NVS
 */
esp_err_t app_config_save(const smartbin_config_t *cfg);

/**
 * @brief Increment and persist the lid open cycle counter in NVS
 */
uint32_t app_config_increment_cycles(smartbin_config_t *cfg);

/**
 * @brief Get global mutable configuration pointer (thread-safe accessor)
 */
smartbin_config_t *app_config_get(void);

#ifdef __cplusplus
}
#endif

#endif /* APP_CONFIG_H */
