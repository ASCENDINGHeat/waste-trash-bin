#ifndef ULTRASONIC_HCSR04_H
#define ULTRASONIC_HCSR04_H

#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Initialize HC-SR04 Ultrasonic Sensor pins (TRIG = GPIO 5, ECHO = GPIO 18)
 */
esp_err_t ultrasonic_hcsr04_init(void);

/**
 * @brief Perform a 5-sample median-filtered ultrasonic distance measurement (in cm).
 *
 * @param[out] out_distance_cm Measured median distance in centimeters
 * @return ESP_OK if at least one valid echo was captured, ESP_ERR_TIMEOUT otherwise
 */
esp_err_t ultrasonic_measure_median_cm(float *out_distance_cm);

/**
 * @brief Map measured distance (cm) to trash bin fill percentage (0-100%).
 *        <= full_cm (10 cm) -> 100%
 *        >= empty_cm (30 cm) -> 0%
 *        Linear interpolation between full_cm and empty_cm.
 */
uint8_t ultrasonic_calc_fill_percent(float distance_cm, float full_cm, float empty_cm);

#ifdef __cplusplus
}
#endif

#endif /* ULTRASONIC_HCSR04_H */
