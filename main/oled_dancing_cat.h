#ifndef OLED_DANCING_CAT_H
#define OLED_DANCING_CAT_H

#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Initialize the I2C OLED display (SCL = GPIO 6, SDA = GPIO 7),
 *        pre-render the Chinese Dancing Cat GIF frames into 8 MB Octal PSRAM,
 *        and start the dedicated Core 1 animation task.
 *
 *        Completely decoupled from the Trash Bin FSM.
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

#ifdef __cplusplus
}
#endif

#endif /* OLED_DANCING_CAT_H */
