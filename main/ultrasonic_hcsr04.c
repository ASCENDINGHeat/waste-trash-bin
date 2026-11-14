#include "ultrasonic_hcsr04.h"
#include "power_mgr.h"
#include "sdkconfig.h"
#include <math.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/gpio.h"
#include "esp_timer.h"
#include "esp_rom_sys.h"
#include "esp_log.h"

static const char *TAG = "ultrasonic";

#define HCSR04_TRIG_PIN           ((gpio_num_t)CONFIG_SMARTBIN_ULTRA_TRIG_GPIO)
#define HCSR04_ECHO_PIN           ((gpio_num_t)CONFIG_SMARTBIN_ULTRA_ECHO_GPIO)
#define HCSR04_SAMPLE_COUNT       5
#define HCSR04_INTER_PING_MS      60
#define HCSR04_WAIT_HIGH_US       6000
#define HCSR04_ECHO_TIMEOUT_US    25000

static portMUX_TYPE s_pulse_mux = portMUX_INITIALIZER_UNLOCKED;

esp_err_t ultrasonic_hcsr04_init(void)
{
    gpio_config_t trig_conf = {
        .pin_bit_mask = (1ULL << HCSR04_TRIG_PIN),
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&trig_conf));
    gpio_set_level(HCSR04_TRIG_PIN, 0);

    gpio_config_t echo_conf = {
        .pin_bit_mask = (1ULL << HCSR04_ECHO_PIN),
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_ENABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&echo_conf));

    ESP_LOGI(TAG, "HC-SR04 initialized (TRIG=GPIO %d, ECHO=GPIO %d)",
             CONFIG_SMARTBIN_ULTRA_TRIG_GPIO, CONFIG_SMARTBIN_ULTRA_ECHO_GPIO);
    return ESP_OK;
}

static esp_err_t ultrasonic_ping_once_cm(float *out_cm)
{
    /* Send 10 us HIGH trigger pulse */
    portENTER_CRITICAL(&s_pulse_mux);
    gpio_set_level(HCSR04_TRIG_PIN, 0);
    esp_rom_delay_us(4);
    gpio_set_level(HCSR04_TRIG_PIN, 1);
    esp_rom_delay_us(10);
    gpio_set_level(HCSR04_TRIG_PIN, 0);
    portEXIT_CRITICAL(&s_pulse_mux);

    /* Wait for ECHO rising edge */
    int64_t t_wait_start = esp_timer_get_time();
    while (gpio_get_level(HCSR04_ECHO_PIN) == 0) {
        if ((esp_timer_get_time() - t_wait_start) > HCSR04_WAIT_HIGH_US) {
            return ESP_ERR_TIMEOUT;
        }
    }

    /* Measure ECHO HIGH duration */
    int64_t t_echo_start = esp_timer_get_time();
    while (gpio_get_level(HCSR04_ECHO_PIN) == 1) {
        if ((esp_timer_get_time() - t_echo_start) > HCSR04_ECHO_TIMEOUT_US) {
            return ESP_ERR_TIMEOUT;
        }
    }
    int64_t pulse_us = esp_timer_get_time() - t_echo_start;

    float cm = (float)pulse_us / 58.0f;
    if (cm < 1.5f || cm > 400.0f) {
        return ESP_ERR_INVALID_RESPONSE;
    }

    *out_cm = cm;
    return ESP_OK;
}

esp_err_t ultrasonic_measure_median_cm(float *out_distance_cm)
{
    if (out_distance_cm == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    power_mgr_set_5v_rail(true);

    float samples[HCSR04_SAMPLE_COUNT];
    int valid_count = 0;

    for (int i = 0; i < HCSR04_SAMPLE_COUNT; i++) {
        float cm = 0.0f;
        if (ultrasonic_ping_once_cm(&cm) == ESP_OK) {
            samples[valid_count++] = cm;
        }
        if (i < (HCSR04_SAMPLE_COUNT - 1)) {
            vTaskDelay(pdMS_TO_TICKS(HCSR04_INTER_PING_MS));
        }
    }

    if (valid_count == 0) {
        ESP_LOGW(TAG, "All %d ultrasonic pings timed out", HCSR04_SAMPLE_COUNT);
        return ESP_ERR_TIMEOUT;
    }

    /* Insertion sort valid samples to extract median */
    for (int i = 1; i < valid_count; i++) {
        float key = samples[i];
        int j = i - 1;
        while (j >= 0 && samples[j] > key) {
            samples[j + 1] = samples[j];
            j--;
        }
        samples[j + 1] = key;
    }

    *out_distance_cm = samples[valid_count / 2];
    ESP_LOGI(TAG, "Median ultrasonic distance: %.2f cm (%d/%d valid pings)",
             *out_distance_cm, valid_count, HCSR04_SAMPLE_COUNT);
    return ESP_OK;
}

uint8_t ultrasonic_calc_fill_percent(float distance_cm, float full_cm, float empty_cm)
{
    if (empty_cm <= full_cm) {
        empty_cm = full_cm + 1.0f;
    }
    if (distance_cm <= full_cm) {
        return 100;
    }
    if (distance_cm >= empty_cm) {
        return 0;
    }
    float ratio = ((empty_cm - distance_cm) / (empty_cm - full_cm)) * 100.0f;
    int32_t pct = (int32_t)lroundf(ratio);
    if (pct < 0) {
        pct = 0;
    } else if (pct > 100) {
        pct = 100;
    }
    return (uint8_t)pct;
}
