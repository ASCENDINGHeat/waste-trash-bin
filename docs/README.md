# Documentation Index — ESP32-S3 Smart Trash Bin (`ESP-IDF ^6.1`)

Complete technical reference for the **ESP32-S3 Smart Trash Bin + Independent OLED Dancing Cat Display** built on **ESP-IDF `^6.1`** targeting the **`YD-ESP32-23` (`ESP32-S3 N16R8`)** development board.

---

## Documents in `docs/`

| Document | Contents |
| :--- | :--- |
| **[01-hardware-and-pinout.md](./01-hardware-and-pinout.md)** | `YD-ESP32-23` (`N16R8`) specs, dual USB-C ports, solder jumpers (`RGB`, `IN-OUT`, `USB-OTG`), reserved Octal PSRAM pins (`GPIO 33–37`), peripheral pinout table (`HC-SR501`, `HC-SR04`, `SG90`, `I2C OLED`), and electrical protection notes. |
| **[02-functional-specification.md](./02-functional-specification.md)** | Dual-core FreeRTOS task split (`Core 0` vs `Core 1`), Trash Bin Finite State Machine, `SG90` fast-open / soft-close ramp & PWM auto-detach, PIR anti-retrigger blanking, post-close + periodic `HC-SR04` 5-sample median filtering, $10\text{–}30\text{ cm}$ fill-level formula, `GPIO 48` RGB status codes, and the independent `Core 1` Chinese Dancing Cat GIF OLED engine. |
| **[03-connectivity-ble-and-mqtt.md](./03-connectivity-ble-and-mqtt.md)** | NimBLE initial provisioning (Wi-Fi + MQTT broker config), automatic BLE failover on Wi-Fi loss, offline PSRAM telemetry ring buffer, live BLE GATT telemetry service, MQTT topic hierarchy, JSON payload schemas, and remote commands. |
| **[04-power-management-and-battery.md](./04-power-management-and-battery.md)** | Component current draw breakdown, **1000 mAh battery runtime calculations** across 4 power profiles ($5.5\text{ hours}$ to $22\text{ days}$), ESP-IDF `esp_pm` DFS + `WIFI_PS_MAX_MODEM` + `RTC_GPIO2` Deep Sleep wakeup, OLED `0xAE` sleep timeout, and 5V rail MOSFET gating. |
| **[05-esp-idf-v6.1-guide.md](./05-esp-idf-v6.1-guide.md)** | **ESP-IDF `^6.1`** specific architecture: CMake $\ge 3.22.1$, modular `esp_driver_*` dependencies (`esp_driver_gpio`, `esp_driver_ledc`, `esp_driver_i2c`, `esp_driver_rmt`), external managed components (`espressif/cjson`, `espressif/led_strip`), Picolibc & `-Werror` rules, and Git SSH setup on Android. |

---

## Quick Pin & Spec Summary

- **MCU**: `ESP32-S3-WROOM-1-N16R8` (`YD-ESP32-23` DevKitC-1 clone, 16 MB QIO Flash, 8 MB Octal PSRAM)
- **ESP-IDF Version**: `^6.1` (CMake $\ge 3.22.1$)
- **PIR Motion Sensor (`HC-SR501`)**: `OUT -> GPIO 2` (`RTC_GPIO2`)
- **Ultrasonic Sensor (`HC-SR04`)**: `TRIG -> GPIO 5`, `ECHO -> GPIO 18` ($10\text{ cm} = 100\%$, $30\text{ cm} = 0\%$)
- **Micro Servo (`SG90`)**: `PWM -> GPIO 21` (50 Hz LEDC)
- **I2C OLED (`SSD1306` / `SH1106`)**: `SCL -> GPIO 6`, `SDA -> GPIO 7` (400 kHz `esp_driver_i2c`, Core 1 Chinese Dancing Cat GIF)
- **Onboard Status RGB LED (`WS2812B`)**: `GPIO 48` (RMT `led_strip`)
