#ifndef RGB_STATUS_H
#define RGB_STATUS_H

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Initialize YD-ESP32-23 onboard WS2812B RGB LED on GPIO 48 via RMT led_strip
 */
esp_err_t rgb_status_init(void);

/**
 * @brief Display trash bin fill-level status color for 5 seconds (then turn off to save battery):
 *        < 50%  -> Green
 *        50-84% -> Yellow/Amber
 *        >= 85% -> Red
 */
void rgb_status_show_fill_level(uint8_t fill_percent);

/**
 * @brief Enable or disable BLE provisioning / Wi-Fi failover blue indicator
 */
void rgb_status_set_ble_active(bool ble_active);

/**
 * @brief Turn off the onboard RGB LED immediately
 */
void rgb_status_off(void);

#ifdef __cplusplus
}
#endif

#endif /* RGB_STATUS_H */
