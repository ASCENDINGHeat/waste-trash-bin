# W.A.S.T.E. Documentation Suite
### **W**aste **A**utomation and **S**ensing **T**echnology **E**ngine (`ESP-IDF ^6.1`)

Complete engineering and architectural reference for **W.A.S.T.E.** (**Waste Automation and Sensing Technology Engine**), built on **ESP-IDF `^6.1`** targeting the **`YD-ESP32-23` (`ESP32-S3-WROOM-1-N16R8`)** development board.

---

## Documentation Index (`docs/`)

| Document | Contents |
| :--- | :--- |
| **[01-hardware-and-pinout.md](./01-hardware-and-pinout.md)** | `YD-ESP32-23` (`N16R8`) hardware specs, dual USB-C ports, solder jumpers (`RGB`, `IN-OUT`, `USB-OTG`), reserved Octal PSRAM pins (`GPIO 33–37`), W.A.S.T.E. peripheral pinout table (`HC-SR501`, `HC-SR04`, `SG90`, `I2C OLED`), and electrical protection notes. |
| **[02-functional-specification.md](./02-functional-specification.md)** | Dual-core FreeRTOS task split (`Core 0` W.A.S.T.E. FSM vs `Core 1` OLED Engine), Finite State Machine, `SG90` fast-open / soft-close ramp & PWM auto-detach, PIR anti-retrigger blanking, post-close + periodic `HC-SR04` 5-sample median filtering, $10\text{–}30\text{ cm}$ fill-level formula, `GPIO 48` RGB status codes, and the independent `Core 1` OLED GIF engine. |
| **[03-connectivity-ble-and-mqtt.md](./03-connectivity-ble-and-mqtt.md)** | NimBLE initial provisioning (Wi-Fi + MQTT broker config), automatic BLE failover on Wi-Fi loss, 256-slot offline Octal PSRAM telemetry ring buffer, live BLE GATT telemetry service, MQTT topic hierarchy, JSON payload schemas, and remote commands. |
| **[04-power-management-and-battery.md](./04-power-management-and-battery.md)** | Component current draw breakdown, **1000 mAh battery runtime calculations** across 4 power profiles ($5.5\text{ hours}$ to $22\text{ days}$), ESP-IDF `esp_pm` DFS + `WIFI_PS_MAX_MODEM` + `RTC_GPIO2` Deep Sleep wakeup, OLED `0xAE` sleep timeout, 5V rail MOSFET gating, and **16 MB NOR Flash wear-leveling endurance analysis**. |
| **[05-esp-idf-v6.1-guide.md](./05-esp-idf-v6.1-guide.md)** | **ESP-IDF `^6.1`** build system: CMake $\ge 3.22.1$, modular `esp_driver_*` dependencies, external managed components (`espressif/cjson`, `espressif/led_strip`, `espressif/mqtt`), Picolibc & `-Werror` rules, path-filtered GitHub Actions CI, and flashing guide. |
| **[06-flutter-companion-app.md](./06-flutter-companion-app.md)** | **W.A.S.T.E. Flutter Companion App** (`companion_app/`): Dual-transport architecture (MQTT + BLE GATT `0xFF00`–`0xFF06` failover), zero-touch BLE Wi-Fi/MQTT provisioning, remote lid & sensor control, unit tests, and phone-side historical telemetry analytics. |
| **[07-smart-oled-hud-and-ui.md](./07-smart-oled-hud-and-ui.md)** | **Core 1 Smart OLED HUD & Context-Aware UI Specification**: $128 \times 64$ page memory map, 6 event-driven screen modes (`BOOT_SPLASH`, `IDLE_HUD`, `LID_ACTIVE`, `MEASURING`, `FULL_ALERT`, `BLE_SETUP`), `MODAL_WARNING_POPUP` centered modal overlay, `.wbin` custom animation uploads, ASCII wireframes, and lock-free compositor pipeline. |
| **[08-feature-status-and-gap-analysis.md](./08-feature-status-and-gap-analysis.md)** | **Feature Tracking & Documentation Gap Analysis**: Audited matrix comparing currently implemented `v1.1.0` firmware/app features against planned specifications (`HUD`, `.wbin` uploads, LAN mode) and minor schema drift. |
| **[../CHANGELOG.md](../CHANGELOG.md)** | Release history (`v1.1.0` & `v1.0.0` release notes). |

---

## Quick Hardware & Pin Summary

- **System Name**: **W.A.S.T.E.** (*Waste Automation and Sensing Technology Engine*) — **`v1.1.0`**
- **MCU**: `ESP32-S3-WROOM-1-N16R8` (`YD-ESP32-23` DevKitC-1 clone, 16 MB QIO Flash, 8 MB Octal PSRAM)
- **ESP-IDF Version**: `^6.1` (`v6.1` Stable, CMake $\ge 3.22.1$)
- **PIR Motion Sensor (`HC-SR501`)**: `OUT -> GPIO 2` (`RTC_GPIO2`)
- **Ultrasonic Sensor (`HC-SR04`)**: `TRIG -> GPIO 5`, `ECHO -> GPIO 18` ($10\text{ cm} = 100\%$, $30\text{ cm} = 0\%$)
- **Micro Servo (`SG90`)**: `PWM -> GPIO 21` (50 Hz 14-bit LEDC)
- **I2C OLED (`SSD1306` / `SH1106`)**: `SCL -> GPIO 6`, `SDA -> GPIO 7` (400 kHz `esp_driver_i2c`, Core 1 GIF Engine)
- **Onboard Status RGB LED (`WS2812B`)**: `GPIO 48` (RMT `led_strip`)
- **Onboard Provision Button (`BOOT`)**: `GPIO 0` (Short press = Enable BLE advertising; 3s hold = Reset Wi-Fi NVS)
