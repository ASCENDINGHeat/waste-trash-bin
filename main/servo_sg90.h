#ifndef SERVO_SG90_H
#define SERVO_SG90_H

#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Initialize LEDC 50 Hz PWM timer and channel on GPIO 21 for SG90 servo
 */
esp_err_t servo_sg90_init(uint8_t initial_closed_angle);

/**
 * @brief Open lid rapidly (~150 ms) to the specified open angle
 */
esp_err_t servo_sg90_open_fast(uint8_t open_angle);

/**
 * @brief Smoothly ramp servo from current open angle back to normal closed angle
 *        over ~500 ms, wait 400 ms mechanical settle delay, and detach PWM pulses
 *        (ledc_stop) so the servo draws 0 mA idle current and causes no 5V noise.
 */
esp_err_t servo_sg90_close_soft_and_detach(uint8_t from_angle, uint8_t closed_angle);

#ifdef __cplusplus
}
#endif

#endif /* SERVO_SG90_H */
