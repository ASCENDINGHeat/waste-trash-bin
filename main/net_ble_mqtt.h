#ifndef NET_BLE_MQTT_H
#define NET_BLE_MQTT_H

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"
#include "app_config.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Callback invoked when an MQTT remote command arrives on smartbin/<id>/cmd
 */
typedef struct {
    void (*on_measure_now)(void);
    void (*on_open_lid)(uint8_t hold_s);
    void (*on_config_updated)(const smartbin_config_t *new_cfg);
} net_cmd_callbacks_t;

/**
 * @brief Initialize Wi-Fi STA, NimBLE Provisioning/Failover GATT service,
 *        MQTT client, and the 256-entry Octal PSRAM offline ring buffer.
 */
esp_err_t net_ble_mqtt_init(const net_cmd_callbacks_t *cbs);

/**
 * @brief Publish a telemetry record via MQTT (or queue in Octal PSRAM if offline)
 *        and update the live BLE GATT telemetry characteristic.
 */
esp_err_t net_ble_mqtt_publish_telemetry(const smartbin_telemetry_t *telemetry);

/**
 * @brief Check whether MQTT is currently connected
 */
bool net_ble_mqtt_is_connected(void);

/**
 * @brief Get current Wi-Fi RSSI in dBm (or -127 if disconnected)
 */
int8_t net_ble_mqtt_get_rssi(void);

#ifdef __cplusplus
}
#endif

#endif /* NET_BLE_MQTT_H */
