#ifndef TRASH_BIN_FSM_H
#define TRASH_BIN_FSM_H

#include <stdint.h>
#include "esp_err.h"
#include "esp_sleep.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Start the Core 0 Smart Trash Bin Finite State Machine task,
 *        PIR GPIO 2 interrupt, and periodic ultrasonic check timer.
 *
 * @param wakeup_cause Deep sleep wakeup cause (if waking from RTC Deep Sleep)
 */
esp_err_t trash_bin_fsm_start(esp_sleep_wakeup_cause_t wakeup_cause);

/**
 * @brief Trigger an immediate ultrasonic fill-level measurement (e.g. from MQTT cmd)
 */
void trash_bin_fsm_trigger_measure_now(void);

/**
 * @brief Trigger a remote lid open cycle (e.g. from MQTT cmd)
 */
void trash_bin_fsm_trigger_remote_open(uint8_t hold_s);

/**
 * @brief Notify FSM that periodic interval or calibration was updated at runtime
 */
void trash_bin_fsm_reload_timer(uint32_t periodic_interval_s);

#ifdef __cplusplus
}
#endif

#endif /* TRASH_BIN_FSM_H */
