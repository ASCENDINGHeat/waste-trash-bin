#include "net_ble_mqtt.h"
#include "rgb_status.h"
#include "oled_dancing_cat.h"
#include <stdio.h>
#include <string.h>
#include <inttypes.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_mac.h"
#include "esp_timer.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "driver/gpio.h"
#include "mqtt_client.h"
#include "cJSON.h"
#include "lan_server.h"
#include "anim_storage.h"
#include "esp_http_client.h"
#include "esp_rom_crc.h"

/* NimBLE includes */
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

static const char *TAG = "net_ble_mqtt";

#define BOOT_BUTTON_GPIO            GPIO_NUM_0
#define WIFI_MAX_RETRY              5
#define WIFI_BG_RETRY_INTERVAL_US   (60ULL * 1000000ULL) /* 60s background retry while in BLE failover */
#define PSRAM_RINGBUF_CAPACITY      256

/* Custom BLE GATT UUIDs:
 * Service:  0xFF00
 * SSID:     0xFF01 (Read/Write)
 * PASS:     0xFF02 (Write)
 * MQTT URI: 0xFF03 (Read/Write)
 * APPLY:    0xFF04 (Write 0x01 to save & connect)
 * TELEM:    0xFF05 (Read/Notify JSON telemetry)
 * CMD:      0xFF06 (Write JSON remote command: open_lid, measure_now, configure)
 * UPLOAD:   0xFF07 (Write/Write Without Response for chunked .wbin animation stream)
 */
static const ble_uuid16_t s_svc_uuid             = BLE_UUID16_INIT(0xFF00);
static const ble_uuid16_t s_chr_ssid_uuid        = BLE_UUID16_INIT(0xFF01);
static const ble_uuid16_t s_chr_pass_uuid        = BLE_UUID16_INIT(0xFF02);
static const ble_uuid16_t s_chr_mqtt_uuid        = BLE_UUID16_INIT(0xFF03);
static const ble_uuid16_t s_chr_apply_uuid       = BLE_UUID16_INIT(0xFF04);
static const ble_uuid16_t s_chr_telem_uuid       = BLE_UUID16_INIT(0xFF05);
static const ble_uuid16_t s_chr_cmd_uuid         = BLE_UUID16_INIT(0xFF06);
static const ble_uuid16_t s_chr_anim_upload_uuid = BLE_UUID16_INIT(0xFF07);

static char s_device_id[32] = "smartbin_s3";
static char s_topic_telemetry[64];
static char s_topic_alert[64];
static char s_topic_status[64];
static char s_topic_cmd[64];

static net_cmd_callbacks_t s_cmd_cbs = {0};
static esp_mqtt_client_handle_t s_mqtt_client = NULL;
static esp_timer_handle_t s_wifi_retry_timer = NULL;
static esp_timer_handle_t s_boot_btn_timer = NULL;

static bool s_wifi_connected = false;
static bool s_mqtt_connected = false;
static bool s_ble_advertising = false;
static bool s_nimble_started = false;
static bool s_failover_warned = false;
static int s_wifi_retry_count = 0;
static int s_boot_btn_hold_ticks = 0;
static uint16_t s_ble_conn_handle = BLE_HS_CONN_HANDLE_NONE;
static uint16_t s_telem_val_handle = 0;
static uint8_t s_ble_addr_type = BLE_OWN_ADDR_PUBLIC;

/* Live telemetry JSON string for BLE GATT read/notify */
static char s_latest_telem_json[256] = "{\"status\":\"booting\"}";
static SemaphoreHandle_t s_ringbuf_mux = NULL;
static smartbin_telemetry_t *s_psram_ringbuf = NULL;
static size_t s_ring_head = 0;
static size_t s_ring_tail = 0;
static size_t s_ring_count = 0;

/* BLE 0xFF07 Chunked Animation Upload Staging State */
static uint8_t *s_ble_upload_buf = NULL;
static size_t s_ble_upload_received = 0;
static size_t s_ble_upload_total = 0;
static int64_t s_ble_upload_last_chunk_us = 0;

static void ble_start_advertising(void);
static void ble_stop_advertising(void);
static void wifi_attempt_connect(void);

static void hud_sync_net(void)
{
    oled_hud_set_network_state(
        s_device_id,
        s_wifi_connected,
        s_mqtt_connected,
        s_ble_advertising || (s_ble_conn_handle != BLE_HS_CONN_HANDLE_NONE),
        net_ble_mqtt_get_rssi()
    );
}

static const char *trigger_to_str(smartbin_trigger_t t)
{
    switch (t) {
        case TRIGGER_LID_CLOSE:  return "lid_close";
        case TRIGGER_PERIODIC:   return "periodic";
        case TRIGGER_REMOTE_CMD: return "remote_cmd";
        case TRIGGER_BOOT:       return "boot";
        default:                 return "unknown";
    }
}

static const char *lid_state_to_str(smartbin_lid_state_t st)
{
    switch (st) {
        case LID_STATE_CLOSED:    return "closed";
        case LID_STATE_OPENING:   return "opening";
        case LID_STATE_OPEN_HOLD: return "open";
        case LID_STATE_CLOSING:   return "closing";
        case LID_STATE_SETTLING:  return "settling";
        case LID_STATE_MEASURING: return "measuring";
        case LID_STATE_COOLDOWN:  return "cooldown";
        default:                  return "unknown";
    }
}

static void format_telemetry_json(const smartbin_telemetry_t *t, char *out_buf, size_t out_len)
{
    cJSON *root = cJSON_CreateObject();
    if (root == NULL) {
        return;
    }
    cJSON_AddStringToObject(root, "device_id", s_device_id);
    cJSON_AddStringToObject(root, "trigger", trigger_to_str(t->trigger));
    cJSON_AddNumberToObject(root, "fill_percent", t->fill_percent);
    cJSON_AddNumberToObject(root, "distance_cm", ((int)(t->distance_cm * 10.0f + 0.5f)) / 10.0);
    cJSON_AddBoolToObject(root, "full_alert", t->full_alert);
    cJSON_AddStringToObject(root, "lid_state", lid_state_to_str(t->lid_state));
    cJSON_AddNumberToObject(root, "open_cycles", t->open_cycles);
    cJSON_AddNumberToObject(root, "wifi_rssi", t->wifi_rssi);
    cJSON_AddNumberToObject(root, "uptime_s", t->uptime_s);

    char *printed = cJSON_PrintUnformatted(root);
    if (printed != NULL) {
        strncpy(out_buf, printed, out_len - 1);
        out_buf[out_len - 1] = '\0';
        cJSON_free(printed);
    }
    cJSON_Delete(root);
}

/* ---------------- PSRAM Offline Ring Buffer ---------------- */

static void ringbuf_push(const smartbin_telemetry_t *item)
{
    if (s_psram_ringbuf == NULL || s_ringbuf_mux == NULL) {
        return;
    }
    xSemaphoreTake(s_ringbuf_mux, portMAX_DELAY);
    s_psram_ringbuf[s_ring_head] = *item;
    s_ring_head = (s_ring_head + 1) % PSRAM_RINGBUF_CAPACITY;
    if (s_ring_count == PSRAM_RINGBUF_CAPACITY) {
        s_ring_tail = (s_ring_tail + 1) % PSRAM_RINGBUF_CAPACITY; /* Overwrite oldest */
    } else {
        s_ring_count++;
    }
    xSemaphoreGive(s_ringbuf_mux);
}

static bool ringbuf_pop(smartbin_telemetry_t *out_item)
{
    if (s_psram_ringbuf == NULL || s_ringbuf_mux == NULL) {
        return false;
    }
    bool popped = false;
    xSemaphoreTake(s_ringbuf_mux, portMAX_DELAY);
    if (s_ring_count > 0) {
        *out_item = s_psram_ringbuf[s_ring_tail];
        s_ring_tail = (s_ring_tail + 1) % PSRAM_RINGBUF_CAPACITY;
        s_ring_count--;
        popped = true;
    }
    xSemaphoreGive(s_ringbuf_mux);
    return popped;
}

static void mqtt_flush_psram_ringbuf(void)
{
    if (!s_mqtt_connected || s_mqtt_client == NULL) {
        return;
    }
    smartbin_telemetry_t item;
    char json_buf[256];
    int flushed = 0;
    while (ringbuf_pop(&item)) {
        format_telemetry_json(&item, json_buf, sizeof(json_buf));
        esp_mqtt_client_publish(s_mqtt_client, s_topic_telemetry, json_buf, 0, 1, 0);
        flushed++;
    }
    if (flushed > 0) {
        ESP_LOGI(TAG, "Flushed %d buffered telemetry records from PSRAM to MQTT", flushed);
    }
}

/* ---------------- MQTT Client & Command Handler ---------------- */

typedef struct {
    char url[256];
} anim_fetch_param_t;

static void anim_fetch_http_task(void *pvParameters)
{
    anim_fetch_param_t *param = (anim_fetch_param_t *)pvParameters;
    if (param == NULL) {
        vTaskDelete(NULL);
        return;
    }

    ESP_LOGI(TAG, "Starting background MQTT fetch_anim from URL: %s", param->url);
    oled_hud_set_upload_progress(true, 0, "MQTT");

    esp_http_client_config_t config = {
        .url = param->url,
        .timeout_ms = 15000,
    };

    esp_http_client_handle_t client = esp_http_client_init(&config);
    if (client == NULL) {
        ESP_LOGE(TAG, "Failed to initialize HTTP client for fetch_anim");
        oled_hud_set_upload_progress(false, 0, NULL);
        free(param);
        vTaskDelete(NULL);
        return;
    }

    esp_err_t err = esp_http_client_open(client, 0);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to open HTTP connection: %s", esp_err_to_name(err));
        esp_http_client_cleanup(client);
        oled_hud_set_upload_progress(false, 0, NULL);
        free(param);
        vTaskDelete(NULL);
        return;
    }

    int content_len = esp_http_client_fetch_headers(client);
    if (content_len < (int)sizeof(wbin_header_t) || content_len > 1048576) {
        ESP_LOGE(TAG, "Invalid content length for fetch_anim: %d bytes", content_len);
        esp_http_client_close(client);
        esp_http_client_cleanup(client);
        oled_hud_set_upload_progress(false, 0, NULL);
        free(param);
        vTaskDelete(NULL);
        return;
    }

    size_t total_len = (size_t)content_len;
    uint8_t *staging_buf = (uint8_t *)heap_caps_malloc(total_len, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (staging_buf == NULL) {
        staging_buf = (uint8_t *)heap_caps_malloc(total_len, MALLOC_CAP_8BIT);
    }
    if (staging_buf == NULL) {
        ESP_LOGE(TAG, "Failed to allocate %zu bytes in PSRAM for fetch_anim", total_len);
        esp_http_client_close(client);
        esp_http_client_cleanup(client);
        oled_hud_set_upload_progress(false, 0, NULL);
        free(param);
        vTaskDelete(NULL);
        return;
    }

    size_t received = 0;
    while (received < total_len) {
        int read_len = esp_http_client_read(client, (char *)(staging_buf + received), (int)(total_len - received));
        if (read_len <= 0) {
            ESP_LOGE(TAG, "HTTP read error at %zu / %zu bytes", received, total_len);
            break;
        }
        received += (size_t)read_len;
        uint8_t pct = (uint8_t)((received * 100ULL) / total_len);
        oled_hud_set_upload_progress(true, pct, "MQTT");
    }

    esp_http_client_close(client);
    esp_http_client_cleanup(client);

    if (received == total_len) {
        wbin_header_t hdr;
        memcpy(&hdr, staging_buf, sizeof(hdr));
        if (memcmp(hdr.magic, WBIN_MAGIC, 4) == 0 &&
            hdr.num_frames >= WBIN_MIN_FRAMES && hdr.num_frames <= WBIN_MAX_FRAMES) {
            uint32_t computed_crc = esp_rom_crc32_le(0, staging_buf + sizeof(wbin_header_t), hdr.payload_bytes);
            if (computed_crc == hdr.crc32) {
                ESP_LOGI(TAG, "MQTT fetch_anim verified successfully (CRC 0x%08" PRIx32 "), committing", computed_crc);
                oled_anim_commit_and_reload(staging_buf, total_len);
            } else {
                ESP_LOGE(TAG, "MQTT fetch_anim CRC mismatch: computed 0x%08" PRIx32 " != header 0x%08" PRIx32,
                         computed_crc, hdr.crc32);
            }
        } else {
            ESP_LOGE(TAG, "MQTT fetch_anim invalid header magic or frame count");
        }
    }

    oled_hud_set_upload_progress(false, 0, NULL);
    heap_caps_free(staging_buf);
    free(param);
    vTaskDelete(NULL);
}

static void handle_mqtt_cmd_payload(const char *data, int len)
{
    cJSON *root = cJSON_ParseWithLength(data, (size_t)len);
    if (root == NULL) {
        ESP_LOGW(TAG, "Received invalid JSON on %s", s_topic_cmd);
        return;
    }

    const cJSON *cmd_item = cJSON_GetObjectItemCaseSensitive(root, "cmd");
    if (cJSON_IsString(cmd_item) && cmd_item->valuestring != NULL) {
        const char *cmd = cmd_item->valuestring;
        ESP_LOGI(TAG, "Executing remote MQTT command: %s", cmd);

        if (strcmp(cmd, "measure_now") == 0) {
            if (s_cmd_cbs.on_measure_now != NULL) {
                s_cmd_cbs.on_measure_now();
            }
        } else if (strcmp(cmd, "open_lid") == 0) {
            const cJSON *hold_item = cJSON_GetObjectItemCaseSensitive(root, "hold_s");
            uint8_t hold_s = cJSON_IsNumber(hold_item) ? (uint8_t)hold_item->valueint
                                                       : app_config_get()->hold_open_s;
            if (s_cmd_cbs.on_open_lid != NULL) {
                s_cmd_cbs.on_open_lid(hold_s);
            }
        } else if (strcmp(cmd, "ble_provision") == 0) {
            ESP_LOGI(TAG, "Remote command activated BLE provisioning advertising");
            ble_start_advertising();
        } else if (strcmp(cmd, "reset_wifi") == 0) {
            smartbin_config_t *cfg = app_config_get();
            memset(cfg->wifi_ssid, 0, sizeof(cfg->wifi_ssid));
            memset(cfg->wifi_pass, 0, sizeof(cfg->wifi_pass));
            app_config_save(cfg);
            esp_wifi_disconnect();
            ble_start_advertising();
            oled_hud_show_warning(OLED_WARN_WIFI_RESET, "NVS WiFi cleared", "BLE Setup Active", 4000);
            ESP_LOGW(TAG, "Wi-Fi credentials cleared via remote command; BLE provisioning active");
        } else if (strcmp(cmd, "configure") == 0) {
            smartbin_config_t *cfg = app_config_get();
            const cJSON *full_cm = cJSON_GetObjectItemCaseSensitive(root, "full_cm");
            const cJSON *empty_cm = cJSON_GetObjectItemCaseSensitive(root, "empty_cm");
            const cJSON *per_s = cJSON_GetObjectItemCaseSensitive(root, "periodic_interval_s");
            const cJSON *oled_s = cJSON_GetObjectItemCaseSensitive(root, "oled_sleep_timeout_s");
            const cJSON *ui_mode = cJSON_GetObjectItemCaseSensitive(root, "oled_ui_mode");

            if (cJSON_IsNumber(full_cm) && full_cm->valuedouble > 1.0) {
                cfg->full_dist_cm = (float)full_cm->valuedouble;
            }
            if (cJSON_IsNumber(empty_cm) && empty_cm->valuedouble > cfg->full_dist_cm) {
                cfg->empty_dist_cm = (float)empty_cm->valuedouble;
            }
            if (cJSON_IsNumber(per_s) && per_s->valueint >= 30) {
                cfg->periodic_interval_s = (uint32_t)per_s->valueint;
            }
            if (cJSON_IsNumber(oled_s) && oled_s->valueint >= 0) {
                cfg->oled_sleep_timeout_s = (uint32_t)oled_s->valueint;
                oled_dancing_cat_set_sleep_timeout(cfg->oled_sleep_timeout_s);
            }
            if (cJSON_IsString(ui_mode) && ui_mode->valuestring != NULL) {
                if (strcmp(ui_mode->valuestring, "split_dashboard") == 0) {
                    cfg->oled_ui_mode = (uint8_t)OLED_UI_MODE_SPLIT_DASHBOARD;
                } else if (strcmp(ui_mode->valuestring, "mascot_only") == 0) {
                    cfg->oled_ui_mode = (uint8_t)OLED_UI_MODE_MASCOT_ONLY;
                } else {
                    cfg->oled_ui_mode = (uint8_t)OLED_UI_MODE_HUD_MASCOT;
                }
                oled_hud_set_ui_mode((oled_ui_mode_t)cfg->oled_ui_mode);
            }
            app_config_save(cfg);
            if (s_cmd_cbs.on_config_updated != NULL) {
                s_cmd_cbs.on_config_updated(cfg);
            }
        } else if (strcmp(cmd, "fetch_anim") == 0) {
            const cJSON *url_item = cJSON_GetObjectItemCaseSensitive(root, "url");
            if (cJSON_IsString(url_item) && url_item->valuestring != NULL && strlen(url_item->valuestring) > 0) {
                anim_fetch_param_t *param = (anim_fetch_param_t *)malloc(sizeof(anim_fetch_param_t));
                if (param != NULL) {
                    snprintf(param->url, sizeof(param->url), "%s", url_item->valuestring);
                    BaseType_t res = xTaskCreate(anim_fetch_http_task, "anim_fetch", 8192, param, 3, NULL);
                    if (res != pdPASS) {
                        ESP_LOGE(TAG, "Failed to spawn anim_fetch_http_task");
                        free(param);
                    }
                }
            } else {
                ESP_LOGW(TAG, "fetch_anim command missing valid 'url' property");
            }
        } else if (strcmp(cmd, "reset_anim") == 0) {
            ESP_LOGI(TAG, "MQTT command reset_anim: restoring compiled dancing cat mascot");
            oled_anim_reset_to_default();
        }
    }
    cJSON_Delete(root);
}

static void mqtt_event_handler(void *handler_args, esp_event_base_t base,
                               int32_t event_id, void *event_data)
{
    (void)handler_args;
    (void)base;
    esp_mqtt_event_handle_t event = (esp_mqtt_event_handle_t)event_data;

    switch ((esp_mqtt_event_id_t)event_id) {
        case MQTT_EVENT_CONNECTED:
            s_mqtt_connected = true;
            ESP_LOGI(TAG, "MQTT connected to broker; publishing online status & subscribing to %s", s_topic_cmd);
            esp_mqtt_client_publish(s_mqtt_client, s_topic_status, "online", 0, 1, 1);
            esp_mqtt_client_subscribe(s_mqtt_client, s_topic_cmd, 1);
            mqtt_flush_psram_ringbuf();
            ble_stop_advertising();
            hud_sync_net();
            break;

        case MQTT_EVENT_DISCONNECTED:
            s_mqtt_connected = false;
            ESP_LOGW(TAG, "MQTT disconnected from broker; enabling BLE GATT provisioning/failover");
            ble_start_advertising();
            hud_sync_net();
            break;

        case MQTT_EVENT_DATA:
            if (event->topic_len > 0 &&
                strncmp(event->topic, s_topic_cmd, (size_t)event->topic_len) == 0) {
                handle_mqtt_cmd_payload(event->data, event->data_len);
            }
            break;

        default:
            break;
    }
}

static void mqtt_start_or_reconfigure(void)
{
    smartbin_config_t *cfg = app_config_get();
    if (strlen(cfg->mqtt_uri) == 0) {
        return;
    }

    if (s_mqtt_client != NULL) {
        esp_mqtt_client_stop(s_mqtt_client);
        esp_mqtt_client_destroy(s_mqtt_client);
        s_mqtt_client = NULL;
    }

    esp_mqtt_client_config_t mqtt_cfg = {
        .broker.address.uri = cfg->mqtt_uri,
        .session.last_will = {
            .topic = s_topic_status,
            .msg = "offline",
            .msg_len = 7,
            .qos = 1,
            .retain = 1,
        },
    };

    s_mqtt_client = esp_mqtt_client_init(&mqtt_cfg);
    if (s_mqtt_client != NULL) {
        esp_mqtt_client_register_event(s_mqtt_client, ESP_EVENT_ANY_ID, mqtt_event_handler, NULL);
        esp_mqtt_client_start(s_mqtt_client);
    }
}

/* ---------------- NimBLE GATT Provisioning & Live Telemetry ---------------- */

static int gatt_chr_access_cb(uint16_t conn_handle, uint16_t attr_handle,
                              struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn_handle;
    (void)attr_handle;
    (void)arg;
    smartbin_config_t *cfg = app_config_get();
    uint16_t uuid16 = ble_uuid_u16(ctxt->chr->uuid);

    if (ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) {
        if (uuid16 == 0xFF01) {
            return os_mbuf_append(ctxt->om, cfg->wifi_ssid, strlen(cfg->wifi_ssid));
        } else if (uuid16 == 0xFF03) {
            return os_mbuf_append(ctxt->om, cfg->mqtt_uri, strlen(cfg->mqtt_uri));
        } else if (uuid16 == 0xFF05) {
            return os_mbuf_append(ctxt->om, s_latest_telem_json, strlen(s_latest_telem_json));
        }
    } else if (ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR) {
        uint16_t om_len = OS_MBUF_PKTLEN(ctxt->om);
        if (uuid16 == 0xFF01 && om_len < sizeof(cfg->wifi_ssid)) {
            memset(cfg->wifi_ssid, 0, sizeof(cfg->wifi_ssid));
            ble_hs_mbuf_to_flat(ctxt->om, cfg->wifi_ssid, sizeof(cfg->wifi_ssid) - 1, NULL);
            ESP_LOGI(TAG, "BLE GATT set Wi-Fi SSID: '%s'", cfg->wifi_ssid);
            return 0;
        } else if (uuid16 == 0xFF02 && om_len < sizeof(cfg->wifi_pass)) {
            memset(cfg->wifi_pass, 0, sizeof(cfg->wifi_pass));
            ble_hs_mbuf_to_flat(ctxt->om, cfg->wifi_pass, sizeof(cfg->wifi_pass) - 1, NULL);
            ESP_LOGI(TAG, "BLE GATT updated Wi-Fi password");
            return 0;
        } else if (uuid16 == 0xFF03 && om_len < sizeof(cfg->mqtt_uri)) {
            memset(cfg->mqtt_uri, 0, sizeof(cfg->mqtt_uri));
            ble_hs_mbuf_to_flat(ctxt->om, cfg->mqtt_uri, sizeof(cfg->mqtt_uri) - 1, NULL);
            ESP_LOGI(TAG, "BLE GATT set MQTT URI: '%s'", cfg->mqtt_uri);
            return 0;
        } else if (uuid16 == 0xFF04) {
            ESP_LOGI(TAG, "BLE GATT Apply triggered: saving NVS and connecting Wi-Fi");
            app_config_save(cfg);
            s_wifi_retry_count = 0;
            wifi_attempt_connect();
            return 0;
        } else if (uuid16 == 0xFF06 && om_len > 0 && om_len < 256) {
            char cmd_buf[256] = {0};
            uint16_t copied = 0;
            ble_hs_mbuf_to_flat(ctxt->om, cmd_buf, sizeof(cmd_buf) - 1, &copied);
            ESP_LOGI(TAG, "BLE GATT received remote command JSON: %s", cmd_buf);
            handle_mqtt_cmd_payload(cmd_buf, (int)copied);
            return 0;
        } else if (uuid16 == 0xFF07 && om_len > 0) {
            uint8_t chunk[512];
            uint16_t copied = 0;
            ble_hs_mbuf_to_flat(ctxt->om, chunk, sizeof(chunk), &copied);

            int64_t now_us = esp_timer_get_time();
            if (s_ble_upload_buf != NULL && (now_us - s_ble_upload_last_chunk_us > 10000000LL)) {
                /* Discard stale or abandoned upload after 10s of silence */
                ESP_LOGW(TAG, "BLE 0xFF07 upload timeout: discarding %zu bytes", s_ble_upload_received);
                heap_caps_free(s_ble_upload_buf);
                s_ble_upload_buf = NULL;
                s_ble_upload_received = 0;
                s_ble_upload_total = 0;
                oled_hud_set_upload_progress(false, 0, NULL);
            }

            if (s_ble_upload_buf == NULL) {
                if (copied < sizeof(wbin_header_t)) {
                    ESP_LOGE(TAG, "BLE 0xFF07 initial packet smaller than header (%u B)", copied);
                    return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
                }
                wbin_header_t hdr;
                memcpy(&hdr, chunk, sizeof(hdr));
                if (memcmp(hdr.magic, WBIN_MAGIC, 4) != 0) {
                    ESP_LOGE(TAG, "BLE 0xFF07 invalid magic: %.4s", hdr.magic);
                    return BLE_ATT_ERR_UNLIKELY;
                }
                if (hdr.num_frames < WBIN_MIN_FRAMES || hdr.num_frames > WBIN_MAX_FRAMES) {
                    ESP_LOGE(TAG, "BLE 0xFF07 invalid frame count: %" PRIu16, hdr.num_frames);
                    return BLE_ATT_ERR_UNLIKELY;
                }
                s_ble_upload_total = sizeof(wbin_header_t) + (size_t)hdr.payload_bytes;
                if (s_ble_upload_total > 1048576) {
                    ESP_LOGE(TAG, "BLE 0xFF07 upload exceeds partition limit: %zu", s_ble_upload_total);
                    return BLE_ATT_ERR_UNLIKELY;
                }
                s_ble_upload_buf = (uint8_t *)heap_caps_malloc(s_ble_upload_total, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
                if (s_ble_upload_buf == NULL) {
                    s_ble_upload_buf = (uint8_t *)heap_caps_malloc(s_ble_upload_total, MALLOC_CAP_8BIT);
                }
                if (s_ble_upload_buf == NULL) {
                    ESP_LOGE(TAG, "BLE 0xFF07 failed to allocate %zu bytes in PSRAM", s_ble_upload_total);
                    return BLE_ATT_ERR_INSUFFICIENT_RES;
                }
                s_ble_upload_received = 0;
                oled_hud_set_upload_progress(true, 0, "BLE");
            }

            size_t to_copy = copied;
            if (s_ble_upload_received + to_copy > s_ble_upload_total) {
                to_copy = s_ble_upload_total - s_ble_upload_received;
            }
            memcpy(s_ble_upload_buf + s_ble_upload_received, chunk, to_copy);
            s_ble_upload_received += to_copy;
            s_ble_upload_last_chunk_us = now_us;

            uint8_t pct = (uint8_t)((s_ble_upload_received * 100ULL) / s_ble_upload_total);
            oled_hud_set_upload_progress(true, pct, "BLE");

            if (s_ble_upload_received >= s_ble_upload_total) {
                wbin_header_t hdr;
                memcpy(&hdr, s_ble_upload_buf, sizeof(hdr));
                uint32_t computed_crc = esp_rom_crc32_le(0, s_ble_upload_buf + sizeof(wbin_header_t), hdr.payload_bytes);
                if (computed_crc == hdr.crc32) {
                    ESP_LOGI(TAG, "BLE 0xFF07 stream complete (%zu bytes), CRC valid (0x%08" PRIx32 "), committing",
                             s_ble_upload_total, computed_crc);
                    oled_anim_commit_and_reload(s_ble_upload_buf, s_ble_upload_total);
                } else {
                    ESP_LOGE(TAG, "BLE 0xFF07 CRC mismatch: computed 0x%08" PRIx32 " != declared 0x%08" PRIx32,
                             computed_crc, hdr.crc32);
                }
                oled_hud_set_upload_progress(false, 0, NULL);
                heap_caps_free(s_ble_upload_buf);
                s_ble_upload_buf = NULL;
                s_ble_upload_received = 0;
                s_ble_upload_total = 0;
            }
            return 0;
        }
    }
    return BLE_ATT_ERR_UNLIKELY;
}

static const struct ble_gatt_svc_def s_gatt_svcs[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &s_svc_uuid.u,
        .characteristics = (struct ble_gatt_chr_def[]) {
            {
                .uuid = &s_chr_ssid_uuid.u,
                .access_cb = gatt_chr_access_cb,
                .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_WRITE,
            },
            {
                .uuid = &s_chr_pass_uuid.u,
                .access_cb = gatt_chr_access_cb,
                .flags = BLE_GATT_CHR_F_WRITE,
            },
            {
                .uuid = &s_chr_mqtt_uuid.u,
                .access_cb = gatt_chr_access_cb,
                .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_WRITE,
            },
            {
                .uuid = &s_chr_apply_uuid.u,
                .access_cb = gatt_chr_access_cb,
                .flags = BLE_GATT_CHR_F_WRITE,
            },
            {
                .uuid = &s_chr_telem_uuid.u,
                .access_cb = gatt_chr_access_cb,
                .val_handle = &s_telem_val_handle,
                .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY,
            },
            {
                .uuid = &s_chr_cmd_uuid.u,
                .access_cb = gatt_chr_access_cb,
                .flags = BLE_GATT_CHR_F_WRITE,
            },
            {
                .uuid = &s_chr_anim_upload_uuid.u,
                .access_cb = gatt_chr_access_cb,
                .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP,
            },
            {0}
        },
    },
    {0}
};

static int ble_gap_event_cb(struct ble_gap_event *event, void *arg)
{
    (void)arg;
    switch (event->type) {
        case BLE_GAP_EVENT_CONNECT:
            if (event->connect.status == 0) {
                s_ble_conn_handle = event->connect.conn_handle;
                ESP_LOGI(TAG, "BLE client connected (handle=%u)", s_ble_conn_handle);
            } else {
                s_ble_conn_handle = BLE_HS_CONN_HANDLE_NONE;
                if (!s_wifi_connected) {
                    ble_start_advertising();
                }
            }
            hud_sync_net();
            break;

        case BLE_GAP_EVENT_DISCONNECT:
            ESP_LOGI(TAG, "BLE client disconnected");
            s_ble_conn_handle = BLE_HS_CONN_HANDLE_NONE;
            if (s_ble_upload_buf != NULL) {
                ESP_LOGW(TAG, "Cleaning up partial BLE upload on client disconnect");
                heap_caps_free(s_ble_upload_buf);
                s_ble_upload_buf = NULL;
                s_ble_upload_received = 0;
                s_ble_upload_total = 0;
                oled_hud_set_upload_progress(false, 0, NULL);
            }
            if (!s_wifi_connected) {
                ble_start_advertising();
            } else {
                rgb_status_set_ble_active(false);
            }
            hud_sync_net();
            break;

        case BLE_GAP_EVENT_ADV_COMPLETE:
            s_ble_advertising = false;
            if (!s_wifi_connected) {
                ble_start_advertising();
            }
            hud_sync_net();
            break;

        default:
            break;
    }
    return 0;
}

static void ble_start_advertising(void)
{
    if (!s_nimble_started || s_ble_advertising) {
        return;
    }

    struct ble_hs_adv_fields fields = {0};
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    const char *name = ble_svc_gap_device_name();
    fields.name = (uint8_t *)name;
    fields.name_len = (uint8_t)strlen(name);
    fields.name_is_complete = 1;
    fields.uuids16 = (ble_uuid16_t[]){s_svc_uuid};
    fields.num_uuids16 = 1;
    fields.uuids16_is_complete = 1;

    ble_gap_adv_set_fields(&fields);

    struct ble_gap_adv_params adv_params = {0};
    adv_params.conn_mode = BLE_GAP_CONN_MODE_UND;
    adv_params.disc_mode = BLE_GAP_DISC_MODE_GEN;

    if (ble_gap_adv_start(s_ble_addr_type, NULL, BLE_HS_FOREVER,
                          &adv_params, ble_gap_event_cb, NULL) == 0) {
        s_ble_advertising = true;
        rgb_status_set_ble_active(true);
        hud_sync_net();
        ESP_LOGI(TAG, "BLE advertising active as '%s' (setup / Wi-Fi failover mode)", name);
    }
}

static void ble_stop_advertising(void)
{
    if (s_ble_advertising) {
        ble_gap_adv_stop();
        s_ble_advertising = false;
    }
    if (s_ble_conn_handle == BLE_HS_CONN_HANDLE_NONE) {
        rgb_status_set_ble_active(false);
    }
    hud_sync_net();
}

static void ble_on_sync(void)
{
    ble_hs_id_infer_auto(0, &s_ble_addr_type);
    s_nimble_started = true;

    /* Start BLE advertising immediately if Wi-Fi is not yet connected */
    if (!s_wifi_connected) {
        ble_start_advertising();
    }
}

static void nimble_host_task(void *param)
{
    (void)param;
    nimble_port_run();
    nimble_port_freertos_deinit();
}

/* ---------------- Wi-Fi STA & Failover Handler ---------------- */

static void wifi_attempt_connect(void)
{
    smartbin_config_t *cfg = app_config_get();
    if (strlen(cfg->wifi_ssid) == 0) {
        ESP_LOGW(TAG, "No Wi-Fi SSID configured; activating BLE initial provisioning");
        ble_start_advertising();
        return;
    }

    wifi_config_t wifi_cfg = {0};
    strncpy((char *)wifi_cfg.sta.ssid, cfg->wifi_ssid, sizeof(wifi_cfg.sta.ssid) - 1);
    strncpy((char *)wifi_cfg.sta.password, cfg->wifi_pass, sizeof(wifi_cfg.sta.password) - 1);
    wifi_cfg.sta.threshold.authmode = (strlen(cfg->wifi_pass) > 0) ? WIFI_AUTH_WPA2_PSK : WIFI_AUTH_OPEN;

    esp_wifi_disconnect();
    esp_wifi_set_config(WIFI_IF_STA, &wifi_cfg);
    esp_wifi_connect();
}

static void wifi_bg_retry_timer_cb(void *arg)
{
    (void)arg;
    if (!s_wifi_connected && strlen(app_config_get()->wifi_ssid) > 0) {
        ESP_LOGI(TAG, "Background Wi-Fi recovery check while in BLE failover mode...");
        s_wifi_retry_count = 0;
        esp_wifi_connect();
    }
}

static void boot_btn_timer_cb(void *arg)
{
    (void)arg;
    if (gpio_get_level(BOOT_BUTTON_GPIO) == 0) {
        s_boot_btn_hold_ticks++;
        if (s_boot_btn_hold_ticks == 30) { /* Held for 3.0 seconds (30 x 100ms) */
            smartbin_config_t *cfg = app_config_get();
            memset(cfg->wifi_ssid, 0, sizeof(cfg->wifi_ssid));
            memset(cfg->wifi_pass, 0, sizeof(cfg->wifi_pass));
            app_config_save(cfg);
            esp_wifi_disconnect();
            ble_start_advertising();
            oled_hud_show_warning(OLED_WARN_WIFI_RESET, "NVS WiFi cleared", "BLE Setup Active", 4000);
            ESP_LOGW(TAG, "BOOT button held 3s: cleared Wi-Fi NVS credentials & restarted BLE provisioning!");
        }
    } else {
        if (s_boot_btn_hold_ticks >= 1 && s_boot_btn_hold_ticks < 30) {
            /* Short press: immediately re-enable BLE advertising without wiping Wi-Fi */
            oled_dancing_cat_notify_activity();
            ble_start_advertising();
            ESP_LOGI(TAG, "BOOT button pressed: BLE provisioning advertising enabled");
        }
        s_boot_btn_hold_ticks = 0;
    }
}

static void wifi_ip_event_handler(void *arg, esp_event_base_t event_base,
                                  int32_t event_id, void *event_data)
{
    (void)arg;
    if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_START) {
        wifi_attempt_connect();
    } else if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_DISCONNECTED) {
        s_wifi_connected = false;
        s_mqtt_connected = false;

        /* Stop local LAN HTTP server and mDNS service while disconnected */
        lan_server_stop();

        if (strlen(app_config_get()->wifi_ssid) > 0 && s_wifi_retry_count < WIFI_MAX_RETRY) {
            s_wifi_retry_count++;
            ESP_LOGW(TAG, "Wi-Fi disconnected; retry %d/%d", s_wifi_retry_count, WIFI_MAX_RETRY);
            esp_wifi_connect();
        } else {
            ESP_LOGW(TAG, "Wi-Fi unavailable; switching to BLE failover mode");
            ble_start_advertising();
            if (!s_failover_warned && strlen(app_config_get()->wifi_ssid) > 0) {
                s_failover_warned = true;
                oled_hud_show_warning(OLED_WARN_WIFI_FAILOVER,
                                      "BLE Mode Active",
                                      "Buffering in PSRAM",
                                      3500);
            }
            if (s_wifi_retry_timer != NULL) {
                esp_timer_stop(s_wifi_retry_timer);
                esp_timer_start_once(s_wifi_retry_timer, WIFI_BG_RETRY_INTERVAL_US);
            }
        }
        hud_sync_net();
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *event = (ip_event_got_ip_t *)event_data;
        ESP_LOGI(TAG, "Wi-Fi connected! IP: " IPSTR, IP2STR(&event->ip_info.ip));
        s_wifi_connected = true;
        s_wifi_retry_count = 0;
        s_failover_warned = false;

        /* Start local LAN HTTP REST server & mDNS service */
        lan_server_start();

        /* Enable Wi-Fi Modem Sleep to drop idle draw from ~105mA to ~15mA */
        esp_wifi_set_ps(WIFI_PS_MAX_MODEM);

        if (s_wifi_retry_timer != NULL) {
            esp_timer_stop(s_wifi_retry_timer);
        }
        hud_sync_net();
        /* Keep BLE advertising active until MQTT_EVENT_CONNECTED succeeds */
        mqtt_start_or_reconfigure();
    }
}

esp_err_t net_ble_mqtt_init(const net_cmd_callbacks_t *cbs)
{
    if (cbs != NULL) {
        s_cmd_cbs = *cbs;
    }

    /* Derive unique device ID and MQTT topics from factory MAC */
    uint8_t mac[6] = {0};
    esp_read_mac(mac, ESP_MAC_WIFI_STA);
    snprintf(s_device_id, sizeof(s_device_id), "smartbin_s3_%02x%02x%02x", mac[3], mac[4], mac[5]);
    snprintf(s_topic_telemetry, sizeof(s_topic_telemetry), "smartbin/%s/telemetry", s_device_id);
    snprintf(s_topic_alert, sizeof(s_topic_alert), "smartbin/%s/alert", s_device_id);
    snprintf(s_topic_status, sizeof(s_topic_status), "smartbin/%s/status", s_device_id);
    snprintf(s_topic_cmd, sizeof(s_topic_cmd), "smartbin/%s/cmd", s_device_id);
    hud_sync_net();

    /* Allocate 256-entry offline telemetry ring buffer in 8 MB Octal PSRAM */
    s_ringbuf_mux = xSemaphoreCreateMutex();
    size_t rb_bytes = sizeof(smartbin_telemetry_t) * PSRAM_RINGBUF_CAPACITY;
    s_psram_ringbuf = (smartbin_telemetry_t *)heap_caps_malloc(rb_bytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (s_psram_ringbuf == NULL) {
        s_psram_ringbuf = (smartbin_telemetry_t *)heap_caps_malloc(rb_bytes, MALLOC_CAP_8BIT);
    }

    const esp_timer_create_args_t retry_timer_args = {
        .callback = &wifi_bg_retry_timer_cb,
        .name = "wifi_bg_retry",
    };
    esp_timer_create(&retry_timer_args, &s_wifi_retry_timer);

    /* Configure onboard BOOT button (GPIO 0) to re-trigger BLE provisioning anytime */
    gpio_config_t boot_btn_cfg = {
        .pin_bit_mask = (1ULL << BOOT_BUTTON_GPIO),
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    gpio_config(&boot_btn_cfg);

    const esp_timer_create_args_t boot_btn_timer_args = {
        .callback = &boot_btn_timer_cb,
        .name = "boot_btn_poll",
    };
    if (esp_timer_create(&boot_btn_timer_args, &s_boot_btn_timer) == ESP_OK) {
        esp_timer_start_periodic(s_boot_btn_timer, 100 * 1000); /* 100 ms */
    }

    /* Initialize TCP/IP stack and Wi-Fi STA */
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();

    wifi_init_config_t wifi_init_cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&wifi_init_cfg));

    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, &wifi_ip_event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, &wifi_ip_event_handler, NULL));

    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_start());

    /* Initialize NimBLE stack for initial setup & Wi-Fi failover */
    ESP_ERROR_CHECK(nimble_port_init());
    ble_hs_cfg.sync_cb = ble_on_sync;
    ble_svc_gap_init();
    ble_svc_gatt_init();
    ble_svc_gap_device_name_set(s_device_id);
    ble_gatts_count_cfg(s_gatt_svcs);
    ble_gatts_add_svcs(s_gatt_svcs);
    nimble_port_freertos_init(nimble_host_task);

    ESP_LOGI(TAG, "Network Manager initialized (Device ID: %s)", s_device_id);
    return ESP_OK;
}

esp_err_t net_ble_mqtt_publish_telemetry(const smartbin_telemetry_t *telemetry)
{
    if (telemetry == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    hud_sync_net();
    format_telemetry_json(telemetry, s_latest_telem_json, sizeof(s_latest_telem_json));

    /* Notify connected BLE GATT client if any (works offline!) */
    if (s_ble_conn_handle != BLE_HS_CONN_HANDLE_NONE && s_telem_val_handle != 0) {
        struct os_mbuf *om = ble_hs_mbuf_from_flat(s_latest_telem_json, strlen(s_latest_telem_json));
        if (om != NULL) {
            ble_gatts_notify_custom(s_ble_conn_handle, s_telem_val_handle, om);
        }
    }

    /* Publish via MQTT if connected, or store in PSRAM ring buffer if offline */
    if (s_mqtt_connected && s_mqtt_client != NULL) {
        esp_mqtt_client_publish(s_mqtt_client, s_topic_telemetry, s_latest_telem_json, 0, 1, 0);
        if (telemetry->full_alert) {
            esp_mqtt_client_publish(s_mqtt_client, s_topic_alert,
                                    "{\"alert\":\"bin_full\",\"fill_percent\":100}", 0, 1, 1);
        } else if (telemetry->fill_percent < 20) {
            esp_mqtt_client_publish(s_mqtt_client, s_topic_alert,
                                    "{\"alert\":\"cleared\"}", 0, 1, 1);
        }
        ESP_LOGI(TAG, "Published MQTT telemetry: %s", s_latest_telem_json);
    } else {
        ringbuf_push(telemetry);
        ESP_LOGW(TAG, "MQTT offline; buffered telemetry in PSRAM: %s", s_latest_telem_json);
    }
    return ESP_OK;
}

bool net_ble_mqtt_is_connected(void)
{
    return s_mqtt_connected;
}

int8_t net_ble_mqtt_get_rssi(void)
{
    if (!s_wifi_connected) {
        return -127;
    }
    int rssi = -127;
    if (esp_wifi_sta_get_rssi(&rssi) == ESP_OK) {
        return (int8_t)rssi;
    }
    return -127;
}
