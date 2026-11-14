#include "servo_sg90.h"
#include "power_mgr.h"
#include "sdkconfig.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/ledc.h"
#include "esp_log.h"

static const char *TAG = "servo_sg90";

#define SERVO_LEDC_MODE       LEDC_LOW_SPEED_MODE
#define SERVO_LEDC_TIMER      LEDC_TIMER_0
#define SERVO_LEDC_CHANNEL    LEDC_CHANNEL_0
#define SERVO_PWM_FREQ_HZ     50
#define SERVO_DUTY_RES        LEDC_TIMER_14_BIT
#define SERVO_PERIOD_US       20000U
#define SERVO_MIN_PULSE_US    500U
#define SERVO_MAX_PULSE_US    2500U
#define SERVO_MAX_DEGREE      180U

static uint32_t angle_to_duty(uint8_t angle)
{
    if (angle > SERVO_MAX_DEGREE) {
        angle = SERVO_MAX_DEGREE;
    }
    uint32_t pulse_us = SERVO_MIN_PULSE_US +
                        ((uint32_t)angle * (SERVO_MAX_PULSE_US - SERVO_MIN_PULSE_US)) / SERVO_MAX_DEGREE;
    uint32_t max_duty = (1U << SERVO_DUTY_RES);
    return (pulse_us * max_duty) / SERVO_PERIOD_US;
}

static esp_err_t servo_set_angle_raw(uint8_t angle)
{
    uint32_t duty = angle_to_duty(angle);
    esp_err_t err = ledc_set_duty(SERVO_LEDC_MODE, SERVO_LEDC_CHANNEL, duty);
    if (err == ESP_OK) {
        err = ledc_update_duty(SERVO_LEDC_MODE, SERVO_LEDC_CHANNEL);
    }
    return err;
}

esp_err_t servo_sg90_init(uint8_t initial_closed_angle)
{
    power_mgr_set_5v_rail(true);

    ledc_timer_config_t timer_conf = {
        .speed_mode       = SERVO_LEDC_MODE,
        .duty_resolution  = SERVO_DUTY_RES,
        .timer_num        = SERVO_LEDC_TIMER,
        .freq_hz          = SERVO_PWM_FREQ_HZ,
        .clk_cfg          = LEDC_AUTO_CLK,
    };
    ESP_ERROR_CHECK(ledc_timer_config(&timer_conf));

    ledc_channel_config_t ch_conf = {
        .gpio_num   = CONFIG_SMARTBIN_SERVO_GPIO,
        .speed_mode = SERVO_LEDC_MODE,
        .channel    = SERVO_LEDC_CHANNEL,
        .intr_type  = LEDC_INTR_DISABLE,
        .timer_sel  = SERVO_LEDC_TIMER,
        .duty       = angle_to_duty(initial_closed_angle),
        .hpoint     = 0,
    };
    ESP_ERROR_CHECK(ledc_channel_config(&ch_conf));

    /* Hold closed position briefly to align horn on boot, then detach PWM */
    vTaskDelay(pdMS_TO_TICKS(300));
    ledc_stop(SERVO_LEDC_MODE, SERVO_LEDC_CHANNEL, 0);

    ESP_LOGI(TAG, "SG90 initialized on GPIO %d (closed=%u deg, PWM auto-detached)",
             CONFIG_SMARTBIN_SERVO_GPIO, initial_closed_angle);
    return ESP_OK;
}

esp_err_t servo_sg90_open_fast(uint8_t open_angle)
{
    power_mgr_set_5v_rail(true);
    ESP_LOGI(TAG, "Opening lid fast -> %u deg", open_angle);
    esp_err_t err = servo_set_angle_raw(open_angle);
    vTaskDelay(pdMS_TO_TICKS(150));
    return err;
}

esp_err_t servo_sg90_close_soft_and_detach(uint8_t from_angle, uint8_t closed_angle)
{
    ESP_LOGI(TAG, "Soft-closing lid %u deg -> %u deg", from_angle, closed_angle);

    const int steps = 25; /* 25 * 20 ms = 500 ms smooth ramp */
    for (int i = 1; i <= steps; i++) {
        int32_t interp = (int32_t)from_angle +
                         (((int32_t)closed_angle - (int32_t)from_angle) * i) / steps;
        servo_set_angle_raw((uint8_t)interp);
        vTaskDelay(pdMS_TO_TICKS(20));
    }

    /* Mechanical settling delay (400 ms) before ultrasonic sensor fires */
    vTaskDelay(pdMS_TO_TICKS(400));

    /* Auto-detach PWM pulses to eliminate stall current and 5V rail noise */
    esp_err_t err = ledc_stop(SERVO_LEDC_MODE, SERVO_LEDC_CHANNEL, 0);
    ESP_LOGI(TAG, "Lid returned to normal state; servo PWM detached");
    return err;
}
