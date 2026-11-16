#ifndef LAN_SERVER_H
#define LAN_SERVER_H

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Start the local LAN HTTP REST server (port 80) and initialize mDNS responder
 *        announcing service _waste._tcp as smartbin_s3_<mac>.
 *
 * @return ESP_OK on success, or error code.
 */
esp_err_t lan_server_start(void);

/**
 * @brief Stop the local LAN HTTP REST server and tear down mDNS service.
 *
 * @return ESP_OK on success, or error code.
 */
esp_err_t lan_server_stop(void);

/**
 * @brief Query if local LAN HTTP server is currently active and listening.
 *
 * @return true if running, false otherwise.
 */
bool lan_server_is_running(void);

#ifdef __cplusplus
}
#endif

#endif /* LAN_SERVER_H */
