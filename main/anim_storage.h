#ifndef ANIM_STORAGE_H
#define ANIM_STORAGE_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include "esp_err.h"
#include "esp_partition.h"

#ifdef __cplusplus
extern "C" {
#endif

#define WBIN_MAGIC              "WGF1"
#define WBIN_HEADER_SIZE        16
#define WBIN_FRAME_BYTES        1024
#define WBIN_MIN_FRAMES         1
#define WBIN_MAX_FRAMES         512
#define WBIN_MIN_FPS            5
#define WBIN_MAX_FPS            30
#define WBIN_DEFAULT_FPS        15

#define WBIN_FLAG_INVERT        (1U << 0)
#define WBIN_FLAG_HUD_OVERLAY   (1U << 1)

#pragma pack(push, 1)
typedef struct {
    char     magic[4];       /* "WGF1" (0x57, 0x47, 0x46, 0x31) */
    uint16_t num_frames;     /* 1 to 512 frames */
    uint8_t  target_fps;     /* 5 to 30 FPS */
    uint8_t  flags;          /* bit 0: invert, bit 1: hud_overlay */
    uint32_t payload_bytes;  /* num_frames * 1024 */
    uint32_t crc32;          /* IEEE 802.3 CRC32 over payload bytes */
} wbin_header_t;
#pragma pack(pop)

/**
 * @brief Initialize the animation storage subsystem and locate the anim_data partition.
 *
 * @return ESP_OK if anim_data partition is found, ESP_ERR_NOT_FOUND otherwise.
 */
esp_err_t anim_storage_init(void);

/**
 * @brief Load active animation from anim_data partition into Octal PSRAM.
 *        Validates WGF1 magic, bounds, and IEEE 802.3 CRC32 checksum.
 *        If partition is unprogrammed (0xFF), invalid, or empty, returns ESP_ERR_NOT_FOUND.
 *        If CRC fails, frees allocated buffer and returns ESP_ERR_INVALID_CRC.
 *
 * @param[out] out_frames     Pointer to allocated PSRAM buffer containing frame data
 * @param[out] out_num_frames Number of frames loaded
 * @param[out] out_fps        Target playback FPS
 * @return ESP_OK on success, ESP_ERR_NOT_FOUND on missing/invalid header,
 *         ESP_ERR_INVALID_CRC on checksum error, ESP_ERR_NO_MEM on allocation failure.
 */
esp_err_t anim_storage_load_to_psram(uint8_t **out_frames, uint16_t *out_num_frames, uint8_t *out_fps);

/**
 * @brief Validate and commit raw .wbin buffer to anim_data partition.
 *        Validates header, frame bounds, and IEEE 802.3 CRC32 before touching flash.
 *        Erases required 4KB sectors and writes the payload to flash.
 *
 * @param buffer Raw .wbin stream buffer (header + payload)
 * @param len    Total length of buffer in bytes
 * @return ESP_OK on success, ESP_ERR_INVALID_ARG on invalid header/length,
 *         ESP_ERR_INVALID_CRC on checksum mismatch, or flash write error.
 */
esp_err_t anim_storage_save_from_buffer(const uint8_t *buffer, size_t len);

/**
 * @brief Invalidate custom animation by erasing sector 0 (4KB) of anim_data partition.
 *        Triggers fallback to compiled dancing cat mascot.
 *
 * @return ESP_OK on success, or flash erase error.
 */
esp_err_t anim_storage_erase(void);

/**
 * @brief Check if anim_data partition contains a valid custom animation header.
 *
 * @return true if valid WGF1 header exists, false otherwise.
 */
bool anim_storage_has_custom(void);

/**
 * @brief Get cached flags from last loaded/saved header.
 *
 * @return flags byte (bit 0: invert, bit 1: hud_overlay).
 */
uint8_t anim_storage_get_flags(void);

/**
 * @brief Read full header from anim_data partition.
 *
 * @param[out] out_hdr Pointer to header destination struct
 * @return ESP_OK if read successfully, error otherwise.
 */
esp_err_t anim_storage_get_header(wbin_header_t *out_hdr);

#ifdef __cplusplus
}
#endif

#endif /* ANIM_STORAGE_H */
