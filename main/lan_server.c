#include "lan_server.h"
#include "anim_storage.h"
#include "oled_dancing_cat.h"
#include "trash_bin_fsm.h"
#include "servo_sg90.h"
#include "app_config.h"
#include "net_ble_mqtt.h"

#include <stdio.h>
#include <string.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>

#include "esp_http_server.h"
#include "mdns.h"
#include "esp_mac.h"
#include "esp_netif.h"
#include "esp_timer.h"
#include "esp_log.h"
#include "esp_heap_caps.h"
#include "esp_rom_crc.h"
#include "cJSON.h"

static const char *TAG = "lan_server";

static httpd_handle_t s_server = NULL;
static bool s_mdns_initialized = false;
static char s_device_id[32] = "smartbin_s3";

/* ---------------- Helper Utilities ---------------- */

static void get_sta_ip_str(char *out_ip, size_t max_len)
{
    if (out_ip == NULL || max_len == 0) {
        return;
    }
    snprintf(out_ip, max_len, "0.0.0.0");

    esp_netif_t *netif = esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");
    if (netif != NULL) {
        esp_netif_ip_info_t ip_info;
        if (esp_netif_get_ip_info(netif, &ip_info) == ESP_OK) {
            snprintf(out_ip, max_len, IPSTR, IP2STR(&ip_info.ip));
        }
    }
}

static esp_err_t send_json_response(httpd_req_t *req, const char *json_str, int status_code)
{
    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Methods", "GET, POST, OPTIONS");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Headers", "Content-Type");

    if (status_code == 400) {
        httpd_resp_set_status(req, "400 Bad Request");
    } else if (status_code == 500) {
        httpd_resp_set_status(req, "500 Internal Server Error");
    } else {
        httpd_resp_set_status(req, "200 OK");
    }

    return httpd_resp_send(req, json_str, HTTPD_RESP_USE_STRLEN);
}

/* ---------------- REST API Handlers ---------------- */

/**
 * @brief GET /api/status
 * Returns JSON status, IP, telemetry, Wi-Fi RSSI, uptime, custom anim status.
 */
static esp_err_t api_status_get_handler(httpd_req_t *req)
{
    char ip_str[32];
    get_sta_ip_str(ip_str, sizeof(ip_str));

    smartbin_config_t *cfg = app_config_get();
    int8_t rssi = net_ble_mqtt_get_rssi();
    uint32_t uptime_s = (uint32_t)(esp_timer_get_time() / 1000000LL);
    bool is_custom = oled_dancing_cat_is_custom_anim();
    uint16_t num_frames = oled_dancing_cat_get_num_frames();

    cJSON *root = cJSON_CreateObject();
    if (root == NULL) {
        return send_json_response(req, "{\"error\":\"out_of_memory\"}", 500);
    }

    cJSON_AddStringToObject(root, "status", "ok");
    cJSON_AddStringToObject(root, "device_id", s_device_id);
    cJSON_AddStringToObject(root, "ip", ip_str);
    cJSON_AddNumberToObject(root, "wifi_rssi", rssi);
    cJSON_AddNumberToObject(root, "uptime_s", uptime_s);
    cJSON_AddNumberToObject(root, "open_cycles", cfg->open_cycles);
    cJSON_AddBoolToObject(root, "anim_custom", is_custom);
    cJSON_AddStringToObject(root, "anim_source", is_custom ? "custom" : "default");
    cJSON_AddNumberToObject(root, "anim_frames", num_frames);
    cJSON_AddNumberToObject(root, "periodic_interval_s", cfg->periodic_interval_s);
    cJSON_AddNumberToObject(root, "oled_sleep_timeout_s", cfg->oled_sleep_timeout_s);
    cJSON_AddNumberToObject(root, "oled_ui_mode", cfg->oled_ui_mode);

    char *json_out = cJSON_PrintUnformatted(root);
    cJSON_Delete(root);

    if (json_out == NULL) {
        return send_json_response(req, "{\"error\":\"json_format_error\"}", 500);
    }

    esp_err_t res = send_json_response(req, json_out, 200);
    cJSON_free(json_out);
    return res;
}

/**
 * @brief POST /api/oled/upload
 * Streaming HTTP handler that reads binary .wbin body in chunks into PSRAM staging buffer,
 * verifies header ("WGF1", frames, fps, flags) and IEEE 802.3 CRC32,
 * updates live OLED progress (oled_hud_set_upload_progress), commits via
 * anim_storage_save_from_buffer(), and returns JSON {"status":"ok","frames":N,"crc32":"0x..."}.
 */
static esp_err_t api_oled_upload_post_handler(httpd_req_t *req)
{
    size_t total_len = req->content_len;
    if (total_len < sizeof(wbin_header_t)) {
        ESP_LOGE(TAG, "Upload payload too short: %zu bytes", total_len);
        return send_json_response(req, "{\"error\":\"truncated_header\"}", 400);
    }

    /* anim_data partition size is 1MB = 1048576 bytes; max allowed .wbin is 16 + 512*1024 = 524304 bytes */
    if (total_len > 1048576) {
        ESP_LOGE(TAG, "Upload payload exceeds partition capacity: %zu bytes", total_len);
        return send_json_response(req, "{\"error\":\"payload_overflow\"}", 400);
    }

    /* Allocate staging buffer in 8 MB Octal PSRAM */
    uint8_t *staging_buf = (uint8_t *)heap_caps_malloc(total_len, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (staging_buf == NULL) {
        staging_buf = (uint8_t *)heap_caps_malloc(total_len, MALLOC_CAP_8BIT);
    }
    if (staging_buf == NULL) {
        ESP_LOGE(TAG, "Failed to allocate %zu bytes staging buffer in PSRAM/heap", total_len);
        return send_json_response(req, "{\"error\":\"no_memory\"}", 500);
    }

    oled_hud_set_upload_progress(true, 0, "HTTP");

    size_t received = 0;
    while (received < total_len) {
        int to_read = (int)(total_len - received);
        if (to_read > 4096) {
            to_read = 4096;
        }

        int ret = httpd_req_recv(req, (char *)(staging_buf + received), (size_t)to_read);
        if (ret <= 0) {
            if (ret == HTTPD_SOCK_ERR_TIMEOUT) {
                continue;
            }
            ESP_LOGE(TAG, "HTTP upload stream aborted at %zu / %zu bytes (err=%d)", received, total_len, ret);
            oled_hud_set_upload_progress(false, 0, NULL);
            heap_caps_free(staging_buf);
            return send_json_response(req, "{\"error\":\"stream_aborted\"}", 500);
        }

        received += (size_t)ret;
        uint8_t pct = (uint8_t)((received * 100ULL) / total_len);
        oled_hud_set_upload_progress(true, pct, "HTTP");
    }

    /* Validate WGF1 header */
    wbin_header_t hdr;
    memcpy(&hdr, staging_buf, sizeof(hdr));

    if (memcmp(hdr.magic, WBIN_MAGIC, 4) != 0) {
        ESP_LOGE(TAG, "Invalid magic: %.4s", hdr.magic);
        oled_hud_set_upload_progress(false, 0, NULL);
        heap_caps_free(staging_buf);
        return send_json_response(req, "{\"error\":\"invalid_magic\"}", 400);
    }

    if (hdr.num_frames < WBIN_MIN_FRAMES || hdr.num_frames > WBIN_MAX_FRAMES) {
        ESP_LOGE(TAG, "Invalid frame count: %" PRIu16, hdr.num_frames);
        oled_hud_set_upload_progress(false, 0, NULL);
        heap_caps_free(staging_buf);
        return send_json_response(req, "{\"error\":\"invalid_frame_count\"}", 400);
    }

    if (hdr.target_fps < WBIN_MIN_FPS || hdr.target_fps > WBIN_MAX_FPS) {
        ESP_LOGE(TAG, "Invalid target_fps: %" PRIu8, hdr.target_fps);
        oled_hud_set_upload_progress(false, 0, NULL);
        heap_caps_free(staging_buf);
        return send_json_response(req, "{\"error\":\"invalid_fps\"}", 400);
    }

    uint32_t expected_payload = (uint32_t)hdr.num_frames * WBIN_FRAME_BYTES;
    if (hdr.payload_bytes != expected_payload || total_len != sizeof(wbin_header_t) + expected_payload) {
        ESP_LOGE(TAG, "Payload size mismatch: %" PRIu32 " expected vs %zu total",
                 hdr.payload_bytes, total_len);
        oled_hud_set_upload_progress(false, 0, NULL);
        heap_caps_free(staging_buf);
        return send_json_response(req, "{\"error\":\"size_mismatch\"}", 400);
    }

    /* Verify IEEE 802.3 CRC32 */
    const uint8_t *payload = staging_buf + sizeof(wbin_header_t);
    uint32_t computed_crc = esp_rom_crc32_le(0, payload, hdr.payload_bytes);
    if (computed_crc != hdr.crc32) {
        ESP_LOGE(TAG, "CRC32 mismatch: computed 0x%08" PRIx32 " != declared 0x%08" PRIx32,
                 computed_crc, hdr.crc32);
        oled_hud_set_upload_progress(false, 0, NULL);
        heap_caps_free(staging_buf);
        return send_json_response(req, "{\"error\":\"crc_mismatch\"}", 400);
    }

    /* Commit payload to flash partition */
    esp_err_t err = anim_storage_save_from_buffer(staging_buf, total_len);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to write animation to flash: %s", esp_err_to_name(err));
        oled_hud_set_upload_progress(false, 0, NULL);
        heap_caps_free(staging_buf);
        return send_json_response(req, "{\"error\":\"flash_write_error\"}", 500);
    }

    /* Reload new animation in Core 1 OLED task */
    oled_dancing_cat_reload_anim();
    oled_hud_set_upload_progress(false, 0, NULL);
    heap_caps_free(staging_buf);

    char resp_buf[128];
    snprintf(resp_buf, sizeof(resp_buf),
             "{\"status\":\"ok\",\"frames\":%" PRIu16 ",\"target_fps\":%" PRIu8 ",\"crc32\":\"0x%08" PRIx32 "\"}",
             hdr.num_frames, hdr.target_fps, hdr.crc32);

    ESP_LOGI(TAG, "Successfully committed LAN HTTP .wbin upload: %" PRIu16 " frames, CRC 0x%08" PRIx32,
             hdr.num_frames, hdr.crc32);
    return send_json_response(req, resp_buf, 200);
}

/**
 * @brief POST /api/oled/reset
 * Calls anim_storage_erase() to restore fallback mascot, returns JSON {"status":"ok"}.
 */
static esp_err_t api_oled_reset_post_handler(httpd_req_t *req)
{
    esp_err_t err = oled_anim_reset_to_default();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to reset animation: %s", esp_err_to_name(err));
        return send_json_response(req, "{\"error\":\"reset_failed\"}", 500);
    }

    ESP_LOGI(TAG, "Animation reset to compiled mascot fallback via LAN HTTP");
    return send_json_response(req, "{\"status\":\"ok\",\"animation\":\"default\"}", 200);
}

/**
 * @brief POST /api/lid
 * Handles JSON {"action":"open"|"close"}, actuates servo.
 */
static esp_err_t api_lid_post_handler(httpd_req_t *req)
{
    char body[256];
    size_t recv_len = req->content_len;
    if (recv_len >= sizeof(body)) {
        recv_len = sizeof(body) - 1;
    }

    int ret = httpd_req_recv(req, body, recv_len);
    if (ret <= 0) {
        return send_json_response(req, "{\"error\":\"empty_body\"}", 400);
    }
    body[ret] = '\0';

    cJSON *root = cJSON_Parse(body);
    if (root == NULL) {
        return send_json_response(req, "{\"error\":\"invalid_json\"}", 400);
    }

    const cJSON *action_item = cJSON_GetObjectItemCaseSensitive(root, "action");
    if (!cJSON_IsString(action_item) || action_item->valuestring == NULL) {
        action_item = cJSON_GetObjectItemCaseSensitive(root, "cmd");
    }

    if (!cJSON_IsString(action_item) || action_item->valuestring == NULL) {
        cJSON_Delete(root);
        return send_json_response(req, "{\"error\":\"missing_action\"}", 400);
    }

    const char *action = action_item->valuestring;
    smartbin_config_t *cfg = app_config_get();

    if (strcmp(action, "open") == 0 || strcmp(action, "open_lid") == 0) {
        const cJSON *hold_item = cJSON_GetObjectItemCaseSensitive(root, "hold_s");
        uint8_t hold_s = (hold_item != NULL && cJSON_IsNumber(hold_item))
                             ? (uint8_t)hold_item->valueint
                             : cfg->hold_open_s;
        cJSON_Delete(root);

        trash_bin_fsm_trigger_remote_open(hold_s);
        ESP_LOGI(TAG, "LAN HTTP triggered lid open (hold=%" PRIu8 "s)", hold_s);
        return send_json_response(req, "{\"status\":\"ok\",\"lid_state\":\"opening\"}", 200);
    } else if (strcmp(action, "close") == 0 || strcmp(action, "close_lid") == 0) {
        cJSON_Delete(root);
        servo_sg90_close_soft_and_detach(cfg->servo_open_angle, cfg->servo_closed_angle);
        ESP_LOGI(TAG, "LAN HTTP triggered soft lid close");
        return send_json_response(req, "{\"status\":\"ok\",\"lid_state\":\"closing\"}", 200);
    }

    cJSON_Delete(root);
    return send_json_response(req, "{\"error\":\"unknown_action\"}", 400);
}

/**
 * @brief POST /api/measure
 * Triggers immediate measurement.
 */
static esp_err_t api_measure_post_handler(httpd_req_t *req)
{
    trash_bin_fsm_trigger_measure_now();
    ESP_LOGI(TAG, "LAN HTTP triggered immediate measurement scan");
    return send_json_response(req, "{\"status\":\"ok\",\"message\":\"measurement_triggered\"}", 200);
}

/**
 * @brief POST /api/config
 * Updates configuration parameters.
 */
static esp_err_t api_config_post_handler(httpd_req_t *req)
{
    char body[512];
    size_t recv_len = req->content_len;
    if (recv_len >= sizeof(body)) {
        recv_len = sizeof(body) - 1;
    }

    int ret = httpd_req_recv(req, body, recv_len);
    if (ret <= 0) {
        return send_json_response(req, "{\"error\":\"empty_body\"}", 400);
    }
    body[ret] = '\0';

    cJSON *root = cJSON_Parse(body);
    if (root == NULL) {
        return send_json_response(req, "{\"error\":\"invalid_json\"}", 400);
    }

    smartbin_config_t *cfg = app_config_get();
    const cJSON *full_cm = cJSON_GetObjectItemCaseSensitive(root, "full_cm");
    const cJSON *empty_cm = cJSON_GetObjectItemCaseSensitive(root, "empty_cm");
    const cJSON *per_s = cJSON_GetObjectItemCaseSensitive(root, "periodic_interval_s");
    const cJSON *oled_s = cJSON_GetObjectItemCaseSensitive(root, "oled_sleep_timeout_s");
    const cJSON *ui_mode = cJSON_GetObjectItemCaseSensitive(root, "oled_ui_mode");
    const cJSON *hold_s = cJSON_GetObjectItemCaseSensitive(root, "hold_open_s");

    if (cJSON_IsNumber(full_cm) && full_cm->valuedouble > 1.0) {
        cfg->full_dist_cm = (float)full_cm->valuedouble;
    }
    if (cJSON_IsNumber(empty_cm) && empty_cm->valuedouble > cfg->full_dist_cm) {
        cfg->empty_dist_cm = (float)empty_cm->valuedouble;
    }
    if (cJSON_IsNumber(per_s) && per_s->valueint >= 30) {
        cfg->periodic_interval_s = (uint32_t)per_s->valueint;
        trash_bin_fsm_reload_timer(cfg->periodic_interval_s);
    }
    if (cJSON_IsNumber(oled_s) && oled_s->valueint >= 0) {
        cfg->oled_sleep_timeout_s = (uint32_t)oled_s->valueint;
        oled_dancing_cat_set_sleep_timeout(cfg->oled_sleep_timeout_s);
    }
    if (cJSON_IsNumber(hold_s) && hold_s->valueint >= 1 && hold_s->valueint <= 60) {
        cfg->hold_open_s = (uint8_t)hold_s->valueint;
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
    cJSON_Delete(root);

    ESP_LOGI(TAG, "LAN HTTP updated configuration in NVS");
    return send_json_response(req, "{\"status\":\"ok\"}", 200);
}

/**
 * @brief Handle OPTIONS for CORS pre-flight
 */
static esp_err_t options_cors_handler(httpd_req_t *req)
{
    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Methods", "GET, POST, OPTIONS");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Headers", "Content-Type");
    httpd_resp_set_status(req, "200 OK");
    return httpd_resp_send(req, "{}", 2);
}

/* ---------------- URI Handler Registrations ---------------- */

static const httpd_uri_t uri_api_status = {
    .uri       = "/api/status",
    .method    = HTTP_GET,
    .handler   = api_status_get_handler,
    .user_ctx  = NULL,
};

static const httpd_uri_t uri_api_oled_upload = {
    .uri       = "/api/oled/upload",
    .method    = HTTP_POST,
    .handler   = api_oled_upload_post_handler,
    .user_ctx  = NULL,
};

static const httpd_uri_t uri_api_oled_reset = {
    .uri       = "/api/oled/reset",
    .method    = HTTP_POST,
    .handler   = api_oled_reset_post_handler,
    .user_ctx  = NULL,
};

static const httpd_uri_t uri_api_lid = {
    .uri       = "/api/lid",
    .method    = HTTP_POST,
    .handler   = api_lid_post_handler,
    .user_ctx  = NULL,
};

static const httpd_uri_t uri_api_measure = {
    .uri       = "/api/measure",
    .method    = HTTP_POST,
    .handler   = api_measure_post_handler,
    .user_ctx  = NULL,
};

static const httpd_uri_t uri_api_config = {
    .uri       = "/api/config",
    .method    = HTTP_POST,
    .handler   = api_config_post_handler,
    .user_ctx  = NULL,
};

static const httpd_uri_t uri_options_all = {
    .uri       = "/*",
    .method    = HTTP_OPTIONS,
    .handler   = options_cors_handler,
    .user_ctx  = NULL,
};

/* ---------------- mDNS Lifecycle ---------------- */

static esp_err_t start_mdns_service(void)
{
    if (s_mdns_initialized) {
        return ESP_OK;
    }

    uint8_t mac[6] = {0};
    esp_read_mac(mac, ESP_MAC_WIFI_STA);
    snprintf(s_device_id, sizeof(s_device_id), "smartbin_s3_%02x%02x%02x", mac[3], mac[4], mac[5]);

    esp_err_t err = mdns_init();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "mdns_init failed: %s", esp_err_to_name(err));
        return err;
    }

    mdns_hostname_set(s_device_id);
    mdns_instance_name_set(s_device_id);

    mdns_txt_item_t service_txt_data[] = {
        {"version", "2.0.0"},
        {"proto", "v2"},
        {"device_id", s_device_id},
        {"type", "receptacle"},
    };

    err = mdns_service_add(s_device_id, "_waste", "_tcp", 80,
                           service_txt_data, sizeof(service_txt_data) / sizeof(service_txt_data[0]));
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "mdns_service_add failed: %s", esp_err_to_name(err));
        mdns_free();
        return err;
    }

    s_mdns_initialized = true;
    ESP_LOGI(TAG, "mDNS announced: hostname='%s.local', service='_waste._tcp':80", s_device_id);
    return ESP_OK;
}

static void stop_mdns_service(void)
{
    if (!s_mdns_initialized) {
        return;
    }
    mdns_service_remove("_waste", "_tcp");
    mdns_free();
    s_mdns_initialized = false;
    ESP_LOGI(TAG, "mDNS service stopped and freed");
}

/* ---------------- Server Lifecycle ---------------- */

esp_err_t lan_server_start(void)
{
    if (s_server != NULL) {
        ESP_LOGI(TAG, "LAN HTTP server is already running");
        return ESP_OK;
    }

    esp_err_t err = start_mdns_service();
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "Proceeding with HTTP server despite mDNS warning (%s)", esp_err_to_name(err));
    }

    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.server_port = 80;
    config.ctrl_port = 32768;
    config.stack_size = 10240;
    config.max_uri_handlers = 12;
    config.uri_match_fn = httpd_uri_match_wildcard;
    config.lru_purge_enable = true;

    err = httpd_start(&s_server, &config);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to start LAN HTTP server on port %d: %s", config.server_port, esp_err_to_name(err));
        return err;
    }

    httpd_register_uri_handler(s_server, &uri_api_status);
    httpd_register_uri_handler(s_server, &uri_api_oled_upload);
    httpd_register_uri_handler(s_server, &uri_api_oled_reset);
    httpd_register_uri_handler(s_server, &uri_api_lid);
    httpd_register_uri_handler(s_server, &uri_api_measure);
    httpd_register_uri_handler(s_server, &uri_api_config);
    httpd_register_uri_handler(s_server, &uri_options_all);

    ESP_LOGI(TAG, "LAN HTTP server started successfully on port %d", config.server_port);
    return ESP_OK;
}

esp_err_t lan_server_stop(void)
{
    if (s_server != NULL) {
        ESP_LOGI(TAG, "Stopping LAN HTTP server...");
        httpd_stop(s_server);
        s_server = NULL;
    }
    stop_mdns_service();
    return ESP_OK;
}

bool lan_server_is_running(void)
{
    return (s_server != NULL);
}
