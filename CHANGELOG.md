# Changelog

All notable changes to **W.A.S.T.E.** (**W**aste **A**utomation and **S**ensing **T**echnology **E**ngine) are documented in this file.

---

## [v1.0.0] — Initial Release

### ESP32-S3 Firmware (`ESP-IDF v6.1` — `YD-ESP32-23` `N16R8`)
- **Dual-Core Architecture**:
  - **Core 0 (`trash_bin_fsm.c`, `net_ble_mqtt.c`)**: Dedicated to PIR motion interrupts (`GPIO 2`), `SG90` servo control (`GPIO 21`), `HC-SR04` ultrasonic sensing (`TRIG = GPIO 5`, `ECHO = GPIO 18`), `WS2812B` RGB status indicator (`GPIO 48`), Wi-Fi STA, `NimBLE` GATT, and `esp-mqtt`.
  - **Core 1 (`oled_dancing_cat.c`, `dancing_cat_frames.h`)**: Dedicated 400 kHz I2C OLED animation engine (`SCL = GPIO 6`, `SDA = GPIO 7`) streaming an 85-frame Atkinson-dithered $128 \times 64$ animation directly from **8 MB Octal PSRAM** at 15 FPS.
- **Anti-Slam & Zero-Hum Servo Kinematics (`servo_sg90.c`)**:
  - Fast `150 ms` open to $90^\circ$, smooth `500 ms` soft-close ramp to $0^\circ$, `400 ms` mechanical settling window, and automatic PWM detachment (`ledc_stop`) to eliminate idle stall current and 5V rail noise.
  - `1.5 s` PIR anti-retrigger blanking window and `30 s` stuck-sensor safety cap.
- **5-Ping Median Ultrasonic Analytics (`ultrasonic_hcsr04.c`)**:
  - Automatic post-close measurement + configurable `15-minute` periodic background checks while closed.
  - Linearly maps $30\text{ cm} \rightarrow 0\%$ (Empty) and $10\text{ cm} \rightarrow 100\%$ (Full).
- **Self-Healing Connectivity (`net_ble_mqtt.c`)**:
  - **MQTT (`espressif/mqtt`)**: Publishes live telemetry (`smartbin/<id>/telemetry`), retained full-bin alerts (`smartbin/<id>/alert`), and LWT status (`smartbin/<id>/status`), and subscribes to remote commands (`smartbin/<id>/cmd`). Compatible with **Flespi (`mqtt.flespi.io`)**, EMQX, and Mosquitto.
  - **256-Slot Octal PSRAM Offline Ring Buffer**: Buffers up to 256 telemetry snapshots in 8 MB Octal PSRAM during Wi-Fi outages and flushes chronologically on reconnect.
  - **NimBLE GATT Service (`0xFF00`–`0xFF06`) & `BOOT` (`GPIO 0`) Button Trigger**: Supports zero-touch Wi-Fi/MQTT NVS provisioning (`0xFF01`–`0xFF04`), live BLE telemetry notifications (`0xFF05`), direct BLE remote commands (`0xFF06`), short-press `BOOT` (`GPIO 0`) BLE activation, and 3-second hold `BOOT` (`GPIO 0`) Wi-Fi NVS reset.
- **Power Management (`power_mgr.c`)**:
  - Dynamic Frequency Scaling ($40\text{ MHz} \leftrightarrow 240\text{ MHz}$), `WIFI_PS_MAX_MODEM`, optional `GPIO 4` 5V rail gating, and `RTC_GPIO2` `ext0` Deep Sleep wakeup.

### W.A.S.T.E. Flutter Companion App (`companion_app/`)
- **Material 3 Dark Dashboard (`dashboard_screen.dart`)**: Live circular fill-level gauge, full-bin alert banner, 1-tap **Open Lid (5s)** & **Measure Now** remote controls, 4 telemetry metric cards, and an interactive `fl_chart` historical fill-level trend graph.
- **Dual-Transport Connection Service (`waste_connection_service.dart`)**: Seamless switching between **MQTT `v3.1.1`** (with native **Flespi Token** authentication & TLS support) and **BLE GATT (`0xFF00`–`0xFF06`)** with `247`-byte MTU negotiation, plus a 500-event phone-side persistent telemetry history log.
- **BLE Provisioning & Calibration Modals (`ble_provision_sheet.dart`, `calibration_sheet.dart`)**: 1-tap **Flespi Preset**, BLE scanner, NVS credential writer, and live ultrasonic depth/timer calibration.
- **Automated Unit & Widget Test Suite (`test/widget_test.dart`)**: Tests JSON telemetry parsing, boundary clamping, command serialization, `SharedPreferences` history persistence, and dashboard/modal rendering.

### Tooling & CI/CD
- **GIF-to-OLED Converters (`tools/gif_to_oled.mjs`, `tools/gif_to_oled.py`)**: Convert any `.gif` into a 1-bit $128 \times 64$ SSD1306 vertical page C header with Atkinson error-diffusion dithering.
- **Path-Filtered GitHub Actions & Automated Releases (`.github/workflows/`)**:
  - `build.yml`: Compiles ESP-IDF `v6.1` firmware on firmware changes.
  - `build-app.yml`: Runs `flutter analyze`, `flutter test`, and builds the Android APK on `companion_app/` changes.
  - `release.yml`: Publishes `esp_trash_bin_merged.bin`, `esp_trash_bin.bin`, and `waste-companion-<tag>.apk` directly to GitHub Releases on `v*` tags.
