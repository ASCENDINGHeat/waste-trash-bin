#ifndef POWER_MGR_H
#define POWER_MGR_H

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"
#include "esp_sleep.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Initialize ESP-IDF Dynamic Frequency Scaling (DFS), Light Sleep,
 *        and optional 5V peripheral rail power gate GPIO.
 */
esp_err_t power_mgr_init(void);

/**
 * @brief Enable or disable the external 5V boost rail (for SG90 & HC-SR04)
 *        when CONFIG_SMARTBIN_POWER_5V_EN_GPIO >= 0.
 */
void power_mgr_set_5v_rail(bool enable);

/**
 * @brief Return the wakeup cause if waking from Deep Sleep.
 */
esp_sleep_wakeup_cause_t power_mgr_get_wakeup_cause(void);

/**
 * @brief Configure RTC ext0 wakeup on GPIO 2 (PIR) + RTC timer wakeup
 *        and enter Deep Sleep immediately.
 *
 * @param periodic_interval_s Seconds until next periodic ultrasonic check
 */
void power_mgr_enter_deep_sleep(uint32_t periodic_interval_s);

#ifdef __cplusplus
}
#endif

#endif /* POWER_MGR_H */
