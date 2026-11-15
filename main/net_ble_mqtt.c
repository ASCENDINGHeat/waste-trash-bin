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
#include "mqtt_client.h"
#include "cJSON.h"

/* NimBLE includes */
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

static const char *TAG = "net_ble_mqtt";

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
 */
static const ble_uuid16_t s_svc_uuid        = BLE_UUID16_INIT(0xFF00);
static const ble_uuid16_t s_chr_ssid_uuid   = BLE_UUID16_INIT(0xFF01);
static const ble_uuid16_t s_chr_pass_uuid   = BLE_UUID16_INIT(0xFF02);
static const ble_uuid16_t s_chr_mqtt_uuid   = BLE_UUID16_INIT(0xFF03);
static const ble_uuid16_t s_chr_apply_uuid  = BLE_UUID16_INIT(0xFF04);
static const ble_uuid16_t s_chr_telem_uuid  = BLE_UUID16_INIT(0xFF05);
static const ble_uuid16_t s_chr_cmd_uuid    = BLE_UUID16_INIT(0xFF06);

static char s_device_id[32] = "smartbin_s3";
static char s_topic_telemetry[64];
static char s_topic_alert[64];
static char s_topic_status[64];
static char s_topic_cmd[64];

static net_cmd_callbacks_t s_cmd_cbs = {0};
static esp_mqtt_client_handle_t s_mqtt_client = NULL;
static esp_timer_handle_t s_wifi_retry_timer = NULL;

static bool s_wifi_connected = false;
static bool s_mqtt_connected = false;
static bool s_ble_advertising = false;
static bool s_nimble_started = false;
static int s_wifi_retry_count = 0;
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

static void ble_start_advertising(void);
static void ble_stop_advertising(void);
static void wifi_attempt_connect(void);

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
        } else if (strcmp(cmd, "configure") == 0) {
            smartbin_config_t *cfg = app_config_get();
            const cJSON *full_cm = cJSON_GetObjectItemCaseSensitive(root, "full_cm");
            const cJSON *empty_cm = cJSON_GetObjectItemCaseSensitive(root, "empty_cm");
            const cJSON *per_s = cJSON_GetObjectItemCaseSensitive(root, "periodic_interval_s");
            const cJSON *oled_s = cJSON_GetObjectItemCaseSensitive(root, "oled_sleep_timeout_s");

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
            app_config_save(cfg);
            if (s_cmd_cbs.on_config_updated != NULL) {
                s_cmd_cbs.on_config_updated(cfg);
            }
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
            break;

        case MQTT_EVENT_DISCONNECTED:
            s_mqtt_connected = false;
            ESP_LOGW(TAG, "MQTT disconnected from broker");
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
            break;

        case BLE_GAP_EVENT_DISCONNECT:
            ESP_LOGI(TAG, "BLE client disconnected");
            s_ble_conn_handle = BLE_HS_CONN_HANDLE_NONE;
            if (!s_wifi_connected) {
                ble_start_advertising();
            } else {
                rgb_status_set_ble_active(false);
            }
            break;

        case BLE_GAP_EVENT_ADV_COMPLETE:
            s_ble_advertising = false;
            if (!s_wifi_connected) {
                ble_start_advertising();
            }
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

static void wifi_ip_event_handler(void *arg, esp_event_base_t event_base,
                                  int32_t event_id, void *event_data)
{
    (void)arg;
    if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_START) {
        wifi_attempt_connect();
    } else if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_DISCONNECTED) {
        s_wifi_connected = false;
        s_mqtt_connected = false;

        if (strlen(app_config_get()->wifi_ssid) > 0 && s_wifi_retry_count < WIFI_MAX_RETRY) {
            s_wifi_retry_count++;
            ESP_LOGW(TAG, "Wi-Fi disconnected; retry %d/%d", s_wifi_retry_count, WIFI_MAX_RETRY);
            esp_wifi_connect();
        } else {
            ESP_LOGW(TAG, "Wi-Fi unavailable; switching to BLE failover mode");
            ble_start_advertising();
            if (s_wifi_retry_timer != NULL) {
                esp_timer_stop(s_wifi_retry_timer);
                esp_timer_start_once(s_wifi_retry_timer, WIFI_BG_RETRY_INTERVAL_US);
            }
        }
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *event = (ip_event_got_ip_t *)event_data;
        ESP_LOGI(TAG, "Wi-Fi connected! IP: " IPSTR, IP2STR(&event->ip_info.ip));
        s_wifi_connected = true;
        s_wifi_retry_count = 0;

        /* Enable Wi-Fi Modem Sleep to drop idle draw from ~105mA to ~15mA */
        esp_wifi_set_ps(WIFI_PS_MAX_MODEM);

        if (s_wifi_retry_timer != NULL) {
            esp_timer_stop(s_wifi_retry_timer);
        }
        ble_stop_advertising();
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
