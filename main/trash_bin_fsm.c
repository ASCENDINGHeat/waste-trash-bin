#include "trash_bin_fsm.h"
#include "app_config.h"
#include "servo_sg90.h"
#include "ultrasonic_hcsr04.h"
#include "rgb_status.h"
#include "oled_dancing_cat.h"
#include "net_ble_mqtt.h"
#include "power_mgr.h"
#include <stdio.h>
#include <inttypes.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "driver/gpio.h"
#include "esp_timer.h"
#include "esp_log.h"

static const char *TAG = "trash_bin_fsm";

#define PIR_GPIO_PIN                 ((gpio_num_t)CONFIG_SMARTBIN_PIR_GPIO)
#define PIR_BLANKING_COOLDOWN_MS     1500
#define POLL_SLICE_MS                100

typedef enum {
    FSM_EVT_PIR_MOTION = 0,
    FSM_EVT_PERIODIC_TIMER,
    FSM_EVT_REMOTE_MEASURE,
    FSM_EVT_REMOTE_OPEN
} fsm_evt_type_t;

typedef struct {
    fsm_evt_type_t type;
    uint8_t hold_s;
} fsm_event_t;

static QueueHandle_t s_fsm_queue = NULL;
static esp_timer_handle_t s_periodic_timer = NULL;
static volatile bool s_pir_blanked = false;

static void IRAM_ATTR pir_gpio_isr_handler(void *arg)
{
    (void)arg;
    if (s_pir_blanked || s_fsm_queue == NULL) {
        return;
    }
    fsm_event_t evt = {
        .type = FSM_EVT_PIR_MOTION,
        .hold_s = 0,
    };
    BaseType_t hp_woken = pdFALSE;
    xQueueSendFromISR(s_fsm_queue, &evt, &hp_woken);
    if (hp_woken == pdTRUE) {
        portYIELD_FROM_ISR();
    }
}

static void periodic_timer_cb(void *arg)
{
    (void)arg;
    if (s_fsm_queue == NULL) {
        return;
    }
    fsm_event_t evt = {
        .type = FSM_EVT_PERIODIC_TIMER,
        .hold_s = 0,
    };
    xQueueSend(s_fsm_queue, &evt, 0);
}

static void execute_measurement_and_publish(smartbin_trigger_t trigger, smartbin_lid_state_t lid_state)
{
    smartbin_config_t *cfg = app_config_get();
    float dist_cm = cfg->empty_dist_cm;

    oled_dancing_cat_notify_activity();
    oled_hud_set_lid_state(LID_STATE_MEASURING, 0, 0, false, cfg->open_cycles);

    esp_err_t err = ultrasonic_measure_median_cm(&dist_cm);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "Ultrasonic measurement failed (%s); reporting clamped empty", esp_err_to_name(err));
        oled_hud_show_warning(OLED_WARN_SENSOR_ECHO_ERR,
                              "HC-SR04 timeout!",
                              "Check TRIG5 ECHO18",
                              4500);
    }

    uint8_t fill_pct = ultrasonic_calc_fill_percent(dist_cm, cfg->full_dist_cm, cfg->empty_dist_cm);
    bool full_alert = (fill_pct >= 95);

    if (err == ESP_OK && fill_pct >= 85 && !full_alert) {
        char warn_l1[24];
        char warn_l2[24];
        snprintf(warn_l1, sizeof(warn_l1), "Bin fill: %u%%", (unsigned)fill_pct);
        snprintf(warn_l2, sizeof(warn_l2), "Space: %.1f cm", dist_cm);
        oled_hud_show_warning(OLED_WARN_NEAR_FULL, warn_l1, warn_l2, 4000);
    }

    ESP_LOGI(TAG, "[%s] Distance=%.1f cm -> Fill=%u%% (alert=%d, cycles=%" PRIu32 ")",
             (trigger == TRIGGER_LID_CLOSE) ? "LID_CLOSE" :
             (trigger == TRIGGER_PERIODIC)  ? "PERIODIC"  : "CMD/BOOT",
             dist_cm, fill_pct, full_alert, cfg->open_cycles);

    /* Update onboard WS2812B RGB status LED (auto-offs after 5s) */
    rgb_status_show_fill_level(fill_pct);

    /* Push measurement snapshot to Core 1 Smart OLED HUD (shows 3s result card) */
    oled_hud_set_sensor_state(fill_pct, dist_cm, full_alert, trigger, cfg->open_cycles);
    oled_hud_set_lid_state(lid_state, 0, 0, false, cfg->open_cycles);

    /* Publish telemetry over MQTT (or PSRAM ring buffer) and BLE GATT */
    smartbin_telemetry_t telem = {
        .trigger      = trigger,
        .fill_percent = fill_pct,
        .distance_cm  = dist_cm,
        .full_alert   = full_alert,
        .lid_state    = lid_state,
        .open_cycles  = cfg->open_cycles,
        .wifi_rssi    = net_ble_mqtt_get_rssi(),
        .uptime_s     = (uint32_t)(esp_timer_get_time() / 1000000ULL),
    };
    net_ble_mqtt_publish_telemetry(&telem);
}

static void execute_lid_cycle(uint8_t requested_hold_s)
{
    smartbin_config_t *cfg = app_config_get();
    uint8_t hold_s = (requested_hold_s > 0) ? requested_hold_s : cfg->hold_open_s;
    uint16_t hold_total_ds = (uint16_t)hold_s * 10U;
    uint32_t max_stuck_s = CONFIG_SMARTBIN_MAX_STUCK_OPEN_SEC;

    /* 1. Notify Core 1 OLED task (in case battery-saver display timeout is enabled) */
    oled_dancing_cat_notify_activity();

    /* 2. Increment persisted open cycle counter and open SG90 fast (150ms) */
    app_config_increment_cycles(cfg);
    oled_hud_set_lid_state(LID_STATE_OPENING, hold_total_ds, hold_total_ds, true, cfg->open_cycles);
    servo_sg90_open_fast(cfg->servo_open_angle);

    /* 3. Hold lid open while PIR stays HIGH + hold_s dwell, capped at max_stuck_s */
    int64_t t_open_start_us = esp_timer_get_time();
    int64_t t_last_motion_us = t_open_start_us;

    while (1) {
        vTaskDelay(pdMS_TO_TICKS(POLL_SLICE_MS));
        int64_t now_us = esp_timer_get_time();
        bool pir_high = (gpio_get_level(PIR_GPIO_PIN) == 1);

        if (pir_high) {
            t_last_motion_us = now_us;
            oled_dancing_cat_notify_activity();
        }

        int64_t since_motion_ms = (now_us - t_last_motion_us) / 1000LL;
        int64_t total_open_ms   = (now_us - t_open_start_us) / 1000LL;
        int64_t rem_ms = ((int64_t)hold_s * 1000LL) - since_motion_ms;
        if (rem_ms < 0) {
            rem_ms = 0;
        }
        uint16_t rem_ds = (uint16_t)(rem_ms / 100LL);
        oled_hud_set_lid_state(LID_STATE_OPEN_HOLD, rem_ds, hold_total_ds, pir_high, cfg->open_cycles);

        if (since_motion_ms >= ((int64_t)hold_s * 1000LL)) {
            break;
        }
        if (total_open_ms >= ((int64_t)max_stuck_s * 1000LL)) {
            ESP_LOGW(TAG, "Max stuck-sensor open timeout (%" PRIu32 "s) reached; forcing lid close", max_stuck_s);
            oled_hud_show_warning(OLED_WARN_PIR_STUCK_TIMEOUT,
                                  "PIR active > 30s!",
                                  "Force closing lid",
                                  3500);
            break;
        }
    }

    /* 4. Blank PIR interrupts before closing to reject 5V servo power-dip false triggers */
    s_pir_blanked = true;
    oled_hud_set_lid_state(LID_STATE_CLOSING, 0, hold_total_ds, false, cfg->open_cycles);

    /* 5. Soft-close ramp (500ms) + mechanical settle (400ms) + PWM auto-detach (ledc_stop) */
    servo_sg90_close_soft_and_detach(cfg->servo_open_angle, cfg->servo_closed_angle);

    /* 6. SG90 returned to normal state -> trigger HC-SR04 5-sample median measurement */
    execute_measurement_and_publish(TRIGGER_LID_CLOSE, LID_STATE_CLOSED);

    /* 7. Enforce 1.5s anti-retrigger blanking cooldown and flush any spurious PIR events */
    vTaskDelay(pdMS_TO_TICKS(PIR_BLANKING_COOLDOWN_MS));
    xQueueReset(s_fsm_queue);
    s_pir_blanked = false;
}

static void trash_bin_fsm_task(void *arg)
{
    esp_sleep_wakeup_cause_t wakeup_cause = (esp_sleep_wakeup_cause_t)(uintptr_t)arg;

    ESP_LOGI(TAG, "Smart Trash Bin FSM task running on Core %d (wakeup_cause=%d)",
             xPortGetCoreID(), (int)wakeup_cause);

    /* Handle immediate action if waking from RTC Deep Sleep */
    if (wakeup_cause == ESP_SLEEP_WAKEUP_EXT0 || gpio_get_level(PIR_GPIO_PIN) == 1) {
        execute_lid_cycle(0);
    } else if (wakeup_cause == ESP_SLEEP_WAKEUP_TIMER) {
        execute_measurement_and_publish(TRIGGER_PERIODIC, LID_STATE_CLOSED);
    } else {
        /* Initial boot measurement while lid is closed */
        execute_measurement_and_publish(TRIGGER_BOOT, LID_STATE_CLOSED);
    }

    fsm_event_t evt;
    while (1) {
        /* If Deep Sleep Battery Mode is enabled and no motion is active, enter Deep Sleep */
        smartbin_config_t *cfg = app_config_get();
        if (cfg->deep_sleep_enabled && uxQueueMessagesWaiting(s_fsm_queue) == 0 &&
            gpio_get_level(PIR_GPIO_PIN) == 0) {
            /* Allow 2 seconds for MQTT telemetry transmission before sleeping */
            vTaskDelay(pdMS_TO_TICKS(2000));
            if (uxQueueMessagesWaiting(s_fsm_queue) == 0 && gpio_get_level(PIR_GPIO_PIN) == 0) {
                oled_dancing_cat_power_off();
                rgb_status_off();
                power_mgr_enter_deep_sleep(cfg->periodic_interval_s);
            }
        }

        if (xQueueReceive(s_fsm_queue, &evt, pdMS_TO_TICKS(500)) == pdTRUE) {
            switch (evt.type) {
                case FSM_EVT_PIR_MOTION:
                case FSM_EVT_REMOTE_OPEN:
                    execute_lid_cycle(evt.hold_s);
                    break;

                case FSM_EVT_PERIODIC_TIMER:
                    ESP_LOGI(TAG, "Periodic ultrasonic timer fired while lid closed");
                    execute_measurement_and_publish(TRIGGER_PERIODIC, LID_STATE_CLOSED);
                    break;

                case FSM_EVT_REMOTE_MEASURE:
                    ESP_LOGI(TAG, "Remote ultrasonic measurement requested");
                    execute_measurement_and_publish(TRIGGER_REMOTE_CMD, LID_STATE_CLOSED);
                    break;
            }
        } else if (!s_pir_blanked && gpio_get_level(PIR_GPIO_PIN) == 1) {
            /* Catch level-high PIR if rising edge occurred right as blanking ended */
            execute_lid_cycle(0);
        }
    }
}

esp_err_t trash_bin_fsm_start(esp_sleep_wakeup_cause_t wakeup_cause)
{
    s_fsm_queue = xQueueCreate(8, sizeof(fsm_event_t));
    if (s_fsm_queue == NULL) {
        return ESP_ERR_NO_MEM;
    }

    /* Configure GPIO 2 (HC-SR501 PIR OUT) with rising-edge interrupt & pull-down */
    gpio_config_t pir_conf = {
        .pin_bit_mask = (1ULL << PIR_GPIO_PIN),
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_ENABLE,
        .intr_type = GPIO_INTR_POSEDGE,
    };
    ESP_ERROR_CHECK(gpio_config(&pir_conf));
    ESP_ERROR_CHECK(gpio_install_isr_service(0));
    ESP_ERROR_CHECK(gpio_isr_handler_add(PIR_GPIO_PIN, pir_gpio_isr_handler, NULL));

    /* Create periodic ultrasonic firing timer (default 15 minutes) */
    const esp_timer_create_args_t timer_args = {
        .callback = &periodic_timer_cb,
        .name = "periodic_ultra",
    };
    ESP_ERROR_CHECK(esp_timer_create(&timer_args, &s_periodic_timer));
    uint32_t interval_s = app_config_get()->periodic_interval_s;
    if (interval_s > 0) {
        ESP_ERROR_CHECK(esp_timer_start_periodic(s_periodic_timer, (uint64_t)interval_s * 1000000ULL));
    }

    /* Pin Trash Bin FSM task to Core 0 alongside wireless stack */
    BaseType_t res = xTaskCreatePinnedToCore(
        trash_bin_fsm_task,
        "trash_bin_fsm",
        6144,
        (void *)(uintptr_t)wakeup_cause,
        5,
        NULL,
        0 /* Core 0 */
    );
    return (res == pdPASS) ? ESP_OK : ESP_FAIL;
}

void trash_bin_fsm_trigger_measure_now(void)
{
    if (s_fsm_queue != NULL) {
        fsm_event_t evt = {.type = FSM_EVT_REMOTE_MEASURE, .hold_s = 0};
        xQueueSend(s_fsm_queue, &evt, 0);
    }
}

void trash_bin_fsm_trigger_remote_open(uint8_t hold_s)
{
    if (s_fsm_queue != NULL) {
        fsm_event_t evt = {.type = FSM_EVT_REMOTE_OPEN, .hold_s = hold_s};
        xQueueSend(s_fsm_queue, &evt, 0);
    }
}

void trash_bin_fsm_reload_timer(uint32_t periodic_interval_s)
{
    if (s_periodic_timer != NULL) {
        esp_timer_stop(s_periodic_timer);
        if (periodic_interval_s > 0) {
            esp_timer_start_periodic(s_periodic_timer, (uint64_t)periodic_interval_s * 1000000ULL);
        }
    }
}
