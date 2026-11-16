#include "anim_storage.h"
#include <stdio.h>
#include <string.h>
#include <inttypes.h>
#include "esp_partition.h"
#include "esp_heap_caps.h"
#include "esp_rom_crc.h"
#include "esp_log.h"

static const char *TAG = "anim_storage";

static const esp_partition_t *s_anim_partition = NULL;
static uint8_t s_cached_flags = 0;

esp_err_t anim_storage_init(void)
{
    if (s_anim_partition != NULL) {
        return ESP_OK;
    }

    s_anim_partition = esp_partition_find_first(ESP_PARTITION_TYPE_DATA, (esp_partition_subtype_t)0x99, "anim_data");
    if (s_anim_partition == NULL) {
        s_anim_partition = esp_partition_find_first(ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_ANY, "anim_data");
    }

    if (s_anim_partition == NULL) {
        ESP_LOGW(TAG, "anim_data partition not found in partition table");
        return ESP_ERR_NOT_FOUND;
    }

    ESP_LOGI(TAG, "Located anim_data partition @ 0x%08" PRIx32 ", size: %" PRIu32 " bytes",
             (uint32_t)s_anim_partition->address, (uint32_t)s_anim_partition->size);
    return ESP_OK;
}

esp_err_t anim_storage_get_header(wbin_header_t *out_hdr)
{
    if (out_hdr == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    if (s_anim_partition == NULL) {
        esp_err_t err = anim_storage_init();
        if (err != ESP_OK || s_anim_partition == NULL) {
            return ESP_ERR_NOT_FOUND;
        }
    }

    return esp_partition_read(s_anim_partition, 0, out_hdr, sizeof(wbin_header_t));
}

bool anim_storage_has_custom(void)
{
    wbin_header_t hdr;
    if (anim_storage_get_header(&hdr) != ESP_OK) {
        return false;
    }

    if ((uint8_t)hdr.magic[0] == 0xFF) {
        return false;
    }

    if (memcmp(hdr.magic, WBIN_MAGIC, 4) != 0) {
        return false;
    }

    if (hdr.num_frames < WBIN_MIN_FRAMES || hdr.num_frames > WBIN_MAX_FRAMES) {
        return false;
    }

    if (hdr.target_fps < WBIN_MIN_FPS || hdr.target_fps > WBIN_MAX_FPS) {
        return false;
    }

    if (hdr.payload_bytes != (uint32_t)hdr.num_frames * WBIN_FRAME_BYTES) {
        return false;
    }

    return true;
}

esp_err_t anim_storage_load_to_psram(uint8_t **out_frames, uint16_t *out_num_frames, uint8_t *out_fps)
{
    if (out_frames == NULL || out_num_frames == NULL || out_fps == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    *out_frames = NULL;
    *out_num_frames = 0;
    *out_fps = 0;

    if (s_anim_partition == NULL) {
        esp_err_t err = anim_storage_init();
        if (err != ESP_OK || s_anim_partition == NULL) {
            return ESP_ERR_NOT_FOUND;
        }
    }

    wbin_header_t hdr;
    esp_err_t err = esp_partition_read(s_anim_partition, 0, &hdr, sizeof(hdr));
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "Failed to read header from anim_data: %s", esp_err_to_name(err));
        return ESP_ERR_NOT_FOUND;
    }

    /* Check for blank flash (0xFF) or invalid magic */
    if ((uint8_t)hdr.magic[0] == 0xFF || memcmp(hdr.magic, WBIN_MAGIC, 4) != 0) {
        ESP_LOGI(TAG, "No custom animation found in flash (magic mismatch or blank flash)");
        return ESP_ERR_NOT_FOUND;
    }

    if (hdr.num_frames < WBIN_MIN_FRAMES || hdr.num_frames > WBIN_MAX_FRAMES) {
        ESP_LOGW(TAG, "Invalid frame count in flash: %" PRIu16 " (allowed: %d..%d)",
                 hdr.num_frames, WBIN_MIN_FRAMES, WBIN_MAX_FRAMES);
        return ESP_ERR_NOT_FOUND;
    }

    if (hdr.target_fps < WBIN_MIN_FPS || hdr.target_fps > WBIN_MAX_FPS) {
        ESP_LOGW(TAG, "Invalid target_fps in flash: %" PRIu8 " (allowed: %d..%d)",
                 hdr.target_fps, WBIN_MIN_FPS, WBIN_MAX_FPS);
        return ESP_ERR_NOT_FOUND;
    }

    uint32_t expected_payload = (uint32_t)hdr.num_frames * WBIN_FRAME_BYTES;
    if (hdr.payload_bytes != expected_payload) {
        ESP_LOGW(TAG, "Payload size mismatch in flash: %" PRIu32 " != %" PRIu32,
                 hdr.payload_bytes, expected_payload);
        return ESP_ERR_NOT_FOUND;
    }

    if (sizeof(wbin_header_t) + hdr.payload_bytes > s_anim_partition->size) {
        ESP_LOGW(TAG, "Animation payload exceeds partition size: %" PRIu32 " > %" PRIu32,
                 (uint32_t)(sizeof(wbin_header_t) + hdr.payload_bytes), (uint32_t)s_anim_partition->size);
        return ESP_ERR_NOT_FOUND;
    }

    /* Allocate frame buffer in 8 MB Octal PSRAM */
    uint8_t *psram_buf = (uint8_t *)heap_caps_malloc(hdr.payload_bytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (psram_buf == NULL) {
        psram_buf = (uint8_t *)heap_caps_malloc(hdr.payload_bytes, MALLOC_CAP_8BIT);
    }
    if (psram_buf == NULL) {
        ESP_LOGE(TAG, "Failed to allocate %" PRIu32 " bytes in PSRAM for custom animation",
                 hdr.payload_bytes);
        return ESP_ERR_NO_MEM;
    }

    err = esp_partition_read(s_anim_partition, sizeof(wbin_header_t), psram_buf, hdr.payload_bytes);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to read payload from partition: %s", esp_err_to_name(err));
        heap_caps_free(psram_buf);
        return err;
    }

    /* Verify IEEE 802.3 CRC32 over payload bytes */
    uint32_t computed_crc = esp_rom_crc32_le(0, psram_buf, hdr.payload_bytes);
    if (computed_crc != hdr.crc32) {
        ESP_LOGE(TAG, "CRC32 verification failed: computed 0x%08" PRIx32 " != header 0x%08" PRIx32,
                 computed_crc, hdr.crc32);
        heap_caps_free(psram_buf);
        return ESP_ERR_INVALID_CRC;
    }

    s_cached_flags = hdr.flags;
    *out_frames = psram_buf;
    *out_num_frames = hdr.num_frames;
    *out_fps = hdr.target_fps;

    ESP_LOGI(TAG, "Loaded custom animation from flash: %" PRIu16 " frames (%" PRIu32 " bytes) @ %" PRIu8 " FPS, CRC: 0x%08" PRIx32,
             hdr.num_frames, hdr.payload_bytes, hdr.target_fps, hdr.crc32);
    return ESP_OK;
}

esp_err_t anim_storage_save_from_buffer(const uint8_t *buffer, size_t len)
{
    if (buffer == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    if (len < sizeof(wbin_header_t)) {
        ESP_LOGE(TAG, "Buffer too short for header: %zu < %zu", len, sizeof(wbin_header_t));
        return ESP_ERR_INVALID_SIZE;
    }

    wbin_header_t hdr;
    memcpy(&hdr, buffer, sizeof(hdr));

    if (memcmp(hdr.magic, WBIN_MAGIC, 4) != 0) {
        ESP_LOGE(TAG, "Invalid magic: %.4s", hdr.magic);
        return ESP_ERR_INVALID_ARG;
    }

    if (hdr.num_frames < WBIN_MIN_FRAMES || hdr.num_frames > WBIN_MAX_FRAMES) {
        ESP_LOGE(TAG, "Invalid frame count: %" PRIu16 " (allowed: %d..%d)",
                 hdr.num_frames, WBIN_MIN_FRAMES, WBIN_MAX_FRAMES);
        return ESP_ERR_INVALID_ARG;
    }

    if (hdr.target_fps < WBIN_MIN_FPS || hdr.target_fps > WBIN_MAX_FPS) {
        ESP_LOGE(TAG, "Invalid target_fps: %" PRIu8 " (allowed: %d..%d)",
                 hdr.target_fps, WBIN_MIN_FPS, WBIN_MAX_FPS);
        return ESP_ERR_INVALID_ARG;
    }

    uint32_t expected_payload = (uint32_t)hdr.num_frames * WBIN_FRAME_BYTES;
    if (hdr.payload_bytes != expected_payload) {
        ESP_LOGE(TAG, "Payload size mismatch: %" PRIu32 " != %" PRIu32,
                 hdr.payload_bytes, expected_payload);
        return ESP_ERR_INVALID_ARG;
    }

    if (len != sizeof(wbin_header_t) + (size_t)hdr.payload_bytes) {
        ESP_LOGE(TAG, "Total length mismatch: %zu != %zu",
                 len, sizeof(wbin_header_t) + (size_t)hdr.payload_bytes);
        return ESP_ERR_INVALID_SIZE;
    }

    /* Verify IEEE 802.3 CRC32 before touching flash */
    const uint8_t *payload = buffer + sizeof(wbin_header_t);
    uint32_t computed_crc = esp_rom_crc32_le(0, payload, hdr.payload_bytes);
    if (computed_crc != hdr.crc32) {
        ESP_LOGE(TAG, "Payload CRC32 mismatch: computed 0x%08" PRIx32 " != header 0x%08" PRIx32,
                 computed_crc, hdr.crc32);
        return ESP_ERR_INVALID_CRC;
    }

    if (s_anim_partition == NULL) {
        esp_err_t err = anim_storage_init();
        if (err != ESP_OK || s_anim_partition == NULL) {
            return ESP_ERR_NOT_FOUND;
        }
    }

    if (len > s_anim_partition->size) {
        ESP_LOGE(TAG, "Animation size (%zu) exceeds partition size (%" PRIu32 ")",
                 len, (uint32_t)s_anim_partition->size);
        return ESP_ERR_NO_MEM;
    }

    /* Calculate required 4KB sector erase size */
    size_t erase_bytes = ((len + 4095U) / 4096U) * 4096U;
    if (erase_bytes > s_anim_partition->size) {
        erase_bytes = s_anim_partition->size;
    }

    ESP_LOGI(TAG, "Erasing %zu bytes (%" PRIu32 " sectors) on anim_data partition...",
             erase_bytes, (uint32_t)(erase_bytes / 4096U));
    esp_err_t err = esp_partition_erase_range(s_anim_partition, 0, erase_bytes);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "esp_partition_erase_range failed: %s", esp_err_to_name(err));
        return err;
    }

    ESP_LOGI(TAG, "Writing %zu bytes to anim_data partition...", len);
    err = esp_partition_write(s_anim_partition, 0, buffer, len);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "esp_partition_write failed: %s", esp_err_to_name(err));
        return err;
    }

    s_cached_flags = hdr.flags;
    ESP_LOGI(TAG, "Successfully committed animation to flash: %" PRIu16 " frames (%" PRIu32 " bytes) @ %" PRIu8 " FPS",
             hdr.num_frames, hdr.payload_bytes, hdr.target_fps);
    return ESP_OK;
}

esp_err_t anim_storage_erase(void)
{
    if (s_anim_partition == NULL) {
        esp_err_t err = anim_storage_init();
        if (err != ESP_OK || s_anim_partition == NULL) {
            return ESP_ERR_NOT_FOUND;
        }
    }

    ESP_LOGI(TAG, "Erasing sector 0 of anim_data partition to invalidate custom animation");
    s_cached_flags = 0;
    return esp_partition_erase_range(s_anim_partition, 0, 4096);
}

uint8_t anim_storage_get_flags(void)
{
    return s_cached_flags;
}
