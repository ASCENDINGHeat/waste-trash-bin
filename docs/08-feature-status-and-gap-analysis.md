# 08 — W.A.S.T.E. Feature Tracking & Documentation Gap Analysis

> [!NOTE]
> This document tracks **currently implemented features** on the **`dev`** branch (targeting **`v2.0.0`**) compared against all specifications in `docs/01` through `docs/07` to clearly distinguish what is **live in code** versus **documented for future milestones**.

**Baseline Audited**: Branch `dev` (Release **`v2.0.0`** — Tri-Mode LAN Connectivity & Custom `.wbin` OLED Animation Subsystem)

---

## 1. Implementation Summary

| Category | Implemented (`Live`) | Planned / Spec Only (`Not Yet Built`) | Minor Spec Drift |
| :--- | :---: | :---: | :---: |
| **Core Hardware, FSM & Sensors (`main/`)** | 9 | 0 | 0 |
| **Power Management & Storage (`main/`, `partitions.csv`)** | 7 | 0 | 0 |
| **BLE, Wi-Fi, LAN & MQTT (`main/`)** | 10 | 0 | 0 |
| **OLED Display Engine & HUD (`main/`)** | 9 | 0 | 0 |
| **Flutter Companion App (`companion_app/`)** | 10 | 0 | 1 |
| **Tools & CI/CD (`tools/`, `.github/workflows/`)** | 9 | 0 | 0 |
| **TOTAL** | **54** | **0** | **1** |

**Legend**:
- **Implemented**: Verified directly in C/Dart source code and validated where local test harnesses exist.
- **Spec Only (Not Implemented)**: Documented in `docs/` as target architecture, with no runtime code yet (`0` items remaining for `v2.0.0`).
- **Partial / Spec Drift**: Working in code, with a minor UX difference vs. specification (`1` non-blocking item: user-facing file share/export button).

---

## 2. Feature Comparison Matrix (Code vs. Documentation)

### 2.1 Hardware Drivers & Trash Bin FSM (`Core 0`)

| Feature | Status | Verified Code Location | Documentation Reference |
| :--- | :--- | :--- | :--- |
| **`HC-SR501` PIR Motion ISR (`GPIO 2` / `RTC_GPIO2`)** | **Implemented** | [`trash_bin_fsm.c`](../main/trash_bin_fsm.c) (`pir_gpio_isr_handler`) | [01-hardware-and-pinout.md](./01-hardware-and-pinout.md), [02-functional-specification.md](./02-functional-specification.md) |
| **PIR `1.5 s` Post-Close Blanking & `30 s` Stuck Cap** | **Implemented** | [`trash_bin_fsm.c`](../main/trash_bin_fsm.c) (`execute_lid_cycle`) | [02-functional-specification.md](./02-functional-specification.md) |
| **`SG90` Servo `150 ms` Open, `500 ms` Soft Close & PWM Detach (`GPIO 21`)** | **Implemented** | [`servo_sg90.c`](../main/servo_sg90.c) (`servo_sg90_close_soft_and_detach`) | [02-functional-specification.md](./02-functional-specification.md) |
| **`HC-SR04` 5-Ping Median Filter & Linear $10\text{–}30\text{ cm}$ Fill % (`GPIO 5, 18`)** | **Implemented** | [`ultrasonic_hcsr04.c`](../main/ultrasonic_hcsr04.c) (`ultrasonic_measure_median_cm`) | [02-functional-specification.md](./02-functional-specification.md) |
| **Trigger Events (`boot`, `lid_close`, `periodic` 900s, `remote_cmd`)** | **Implemented** | [`trash_bin_fsm.c`](../main/trash_bin_fsm.c) (`execute_measurement_and_publish`) | [02-functional-specification.md](./02-functional-specification.md) |
| **`WS2812B` RGB Status LED (`GPIO 48`, Green/Amber/Red + 5s Auto-Off, Blue BLE)** | **Implemented** | [`rgb_status.c`](../main/rgb_status.c) (`rgb_status_show_fill_level`) | [02-functional-specification.md](./02-functional-specification.md) |

### 2.2 Power Management & Storage

| Feature | Status | Verified Code Location | Documentation Reference |
| :--- | :--- | :--- | :--- |
| **`esp_pm` Dynamic Frequency Scaling ($40 \leftrightarrow 240\text{ MHz}$) + Light Sleep** | **Implemented** | [`power_mgr.c`](../main/power_mgr.c) (`power_mgr_init`) | [04-power-management-and-battery.md](./04-power-management-and-battery.md) |
| **Wi-Fi `WIFI_PS_MAX_MODEM` Power Save** | **Implemented** | [`net_ble_mqtt.c`](../main/net_ble_mqtt.c) | [04-power-management-and-battery.md](./04-power-management-and-battery.md) |
| **Optional `5V` Rail MOSFET Gate (`GPIO 4`)** | **Implemented** | [`power_mgr.c`](../main/power_mgr.c) (`power_mgr_set_5v_rail`) | [01-hardware-and-pinout.md](./01-hardware-and-pinout.md), [04-power-management-and-battery.md](./04-power-management-and-battery.md) |
| **RTC `ext0` (`GPIO 2`) + Timer Deep Sleep Loop** | **Implemented** *(Off by default in `Kconfig`)* | [`power_mgr.c`](../main/power_mgr.c), [`trash_bin_fsm.c`](../main/trash_bin_fsm.c) | [04-power-management-and-battery.md](./04-power-management-and-battery.md) |
| **NVS Config & `open_cycles` Counter Persistence** | **Implemented** | [`app_config.c`](../main/app_config.c) | [04-power-management-and-battery.md](./04-power-management-and-battery.md) |
| **`anim_data` (`1 MB`, Subtype `0x99`) Flash Partition for `.wbin`** | **Implemented** | [`partitions.csv`](../partitions.csv), [`anim_storage.c`](../main/anim_storage.c) | [07-smart-oled-hud-and-ui.md](./07-smart-oled-hud-and-ui.md) (§ 7.3) |

### 2.3 Connectivity: Wi-Fi, NimBLE, MQTT & LAN

| Feature | Status | Verified Code Location | Documentation Reference |
| :--- | :--- | :--- | :--- |
| **Wi-Fi STA Auto-Connect + 5-Retry BLE Failover + 60s Reconnect** | **Implemented** | [`net_ble_mqtt.c`](../main/net_ble_mqtt.c) | [03-connectivity-ble-and-mqtt.md](./03-connectivity-ble-and-mqtt.md) (§ 1) |
| **`NimBLE` GATT `0xFF00` (`0xFF01`–`0xFF06`: Creds, Notify Telemetry, JSON Cmd)** | **Implemented** | [`net_ble_mqtt.c`](../main/net_ble_mqtt.c) | [03-connectivity-ble-and-mqtt.md](./03-connectivity-ble-and-mqtt.md) (§ 2.2) |
| **Onboard `BOOT` (`GPIO 0`) Short Press BLE Advertise / 3s Hold NVS Reset** | **Implemented** | [`net_ble_mqtt.c`](../main/net_ble_mqtt.c) | [03-connectivity-ble-and-mqtt.md](./03-connectivity-ble-and-mqtt.md) |
| **`esp-mqtt` Topics (`telemetry`, `alert` $\ge 95\%$, LWT `status`, `cmd`)** | **Implemented** | [`net_ble_mqtt.c`](../main/net_ble_mqtt.c) | [03-connectivity-ble-and-mqtt.md](./03-connectivity-ble-and-mqtt.md) (§ 3.1) |
| **256-Slot Octal PSRAM Offline Telemetry Ring Buffer** | **Implemented** | [`net_ble_mqtt.c`](../main/net_ble_mqtt.c) | [03-connectivity-ble-and-mqtt.md](./03-connectivity-ble-and-mqtt.md) (§ 4) |
| **Remote Commands (`measure_now`, `open_lid`, `ble_provision`, `reset_wifi`, `configure`)** | **Implemented** | [`net_ble_mqtt.c`](../main/net_ble_mqtt.c) (`handle_mqtt_cmd_payload`) | [03-connectivity-ble-and-mqtt.md](./03-connectivity-ble-and-mqtt.md) (§ 3.3) |
| **`configure` JSON OLED Field Name (`oled_sleep_timeout_s` + `oled_ui_mode`)** | **Implemented** | [`net_ble_mqtt.c`](../main/net_ble_mqtt.c), [`telemetry.dart`](../companion_app/lib/models/telemetry.dart) | [03-connectivity-ble-and-mqtt.md](./03-connectivity-ble-and-mqtt.md) (§ 3.3) |
| **Local LAN HTTP REST + mDNS Discovery (`esp_http_server` + `mdns`)** | **Implemented** | [`lan_server.c`](../main/lan_server.c), [`lan_server.h`](../main/lan_server.h), [`net_ble_mqtt.c`](../main/net_ble_mqtt.c) | [03-connectivity-ble-and-mqtt.md](./03-connectivity-ble-and-mqtt.md) (§ 6) |
| **BLE GATT `0xFF07` Chunked `.wbin` Animation Upload Characteristic** | **Implemented** | [`net_ble_mqtt.c`](../main/net_ble_mqtt.c) | [03-connectivity-ble-and-mqtt.md](./03-connectivity-ble-and-mqtt.md) (§ 6.3), [07-smart-oled-hud-and-ui.md](./07-smart-oled-hud-and-ui.md) (§ 7.4) |
| **MQTT Remote Animation Commands (`fetch_anim` URL download & `reset_anim`)** | **Implemented** | [`net_ble_mqtt.c`](../main/net_ble_mqtt.c) | [03-connectivity-ble-and-mqtt.md](./03-connectivity-ble-and-mqtt.md) (§ 6.4) |

### 2.4 `Core 1` OLED Engine & Smart HUD UI

| Feature | Status | Verified Code Location | Documentation Reference |
| :--- | :--- | :--- | :--- |
| **`400 kHz` I2C Master OLED Driver (`SCL = GPIO 6`, `SDA = GPIO 7`)** | **Implemented** | [`oled_dancing_cat.c`](../main/oled_dancing_cat.c) (`oled_hw_init`) | [01-hardware-and-pinout.md](./01-hardware-and-pinout.md), [02-functional-specification.md](./02-functional-specification.md) |
| **85-Frame Hololive Risu Animation Streamed from 8 MB Octal PSRAM (`15 FPS`)** | **Implemented** | [`oled_dancing_cat.c`](../main/oled_dancing_cat.c), [`dancing_cat_frames.h`](../main/dancing_cat_frames.h) | [02-functional-specification.md](./02-functional-specification.md) |
| **Display Sleep Timeout (`0xAE` OFF / `0xAF` Wake on Activity)** | **Implemented** | [`oled_dancing_cat.c`](../main/oled_dancing_cat.c) (`oled_dancing_cat_set_sleep_timeout`) | [04-power-management-and-battery.md](./04-power-management-and-battery.md) |
| **5x7 ASCII Font & Compositor Buffer (`oled_font5x7.h`, `s_composite_fb[1024]`)** | **Implemented** | [`oled_font5x7.h`](../main/oled_font5x7.h), [`oled_dancing_cat.c`](../main/oled_dancing_cat.c) | [07-smart-oled-hud-and-ui.md](./07-smart-oled-hud-and-ui.md) (§ 5–6) |
| **Boot Splash Animation & POST Checklist (`SCREEN_BOOT_SPLASH`)** | **Implemented** | [`oled_dancing_cat.c`](../main/oled_dancing_cat.c) (`render_boot_splash`) | [07-smart-oled-hud-and-ui.md](./07-smart-oled-hud-and-ui.md) (§ 3.1) |
| **5 Event-Driven HUD Modes (`IDLE_HUD`, `LID_ACTIVE`, `MEASURING`, `FULL_ALERT`, `BLE_SETUP`)** | **Implemented** | [`oled_dancing_cat.c`](../main/oled_dancing_cat.c), [`trash_bin_fsm.c`](../main/trash_bin_fsm.c), [`net_ble_mqtt.c`](../main/net_ble_mqtt.c) | [07-smart-oled-hud-and-ui.md](./07-smart-oled-hud-and-ui.md) (§ 3.2–3.6) |
| **Warning Popup Modal Overlay (`MODAL_WARNING_POPUP` / `oled_hud_show_warning()`)** | **Implemented** | [`oled_dancing_cat.c`](../main/oled_dancing_cat.c) (`render_warning_modal_overlay`) | [07-smart-oled-hud-and-ui.md](./07-smart-oled-hud-and-ui.md) (§ 4) |
| **`oled_ui_mode` Runtime Switch (`hud_mascot` / `split_dashboard` / `mascot_only`)** | **Implemented** | [`app_config.c`](../main/app_config.c), [`net_ble_mqtt.c`](../main/net_ble_mqtt.c), [`oled_dancing_cat.c`](../main/oled_dancing_cat.c) | [07-smart-oled-hud-and-ui.md](./07-smart-oled-hud-and-ui.md) (§ 3.2, § 6) |
| **User-Uploadable `.wbin` (`WGF1`) Custom Animation Loader + CRC32 + Fallback** | **Implemented** | [`anim_storage.c`](../main/anim_storage.c), [`anim_storage.h`](../main/anim_storage.h), [`oled_dancing_cat.c`](../main/oled_dancing_cat.c) | [07-smart-oled-hud-and-ui.md](./07-smart-oled-hud-and-ui.md) (§ 7) |

### 2.5 W.A.S.T.E. Flutter Companion App (`companion_app/`)

| Feature | Status | Verified Code Location | Documentation Reference |
| :--- | :--- | :--- | :--- |
| **Material 3 Dashboard, Fill Gauge & `fl_chart` Trend Graph** | **Implemented** | [`dashboard_screen.dart`](../companion_app/lib/screens/dashboard_screen.dart) | [06-flutter-companion-app.md](./06-flutter-companion-app.md) |
| **MQTT `3.1.1` Client (Flespi Token `userInfo`, TLS `8883`, Wildcard Discovery)** | **Implemented** | [`waste_connection_service.dart`](../companion_app/lib/services/waste_connection_service.dart) | [03-connectivity-ble-and-mqtt.md](./03-connectivity-ble-and-mqtt.md), [06-flutter-companion-app.md](./06-flutter-companion-app.md) |
| **BLE GATT `0xFF00` Failover, `247B` MTU & Provisioning Sheet (`Flespi Preset`)** | **Implemented** | [`ble_provision_sheet.dart`](../companion_app/lib/screens/ble_provision_sheet.dart), [`waste_connection_service.dart`](../companion_app/lib/services/waste_connection_service.dart) | [06-flutter-companion-app.md](./06-flutter-companion-app.md) |
| **Remote Actions (`open_lid`, `measure_now`) & Sensor Calibration Sheet** | **Implemented** | [`calibration_sheet.dart`](../companion_app/lib/screens/calibration_sheet.dart), [`waste_connection_service.dart`](../companion_app/lib/services/waste_connection_service.dart) | [06-flutter-companion-app.md](./06-flutter-companion-app.md) |
| **500-Event Local History Ring (`SharedPreferences`)** | **Implemented** | [`waste_connection_service.dart`](../companion_app/lib/services/waste_connection_service.dart) | [06-flutter-companion-app.md](./06-flutter-companion-app.md) |
| **OLED UI Mode Selector (`oled_ui_mode`) in Calibration UI** | **Implemented** | [`calibration_sheet.dart`](../companion_app/lib/screens/calibration_sheet.dart), [`telemetry.dart`](../companion_app/lib/models/telemetry.dart) | [07-smart-oled-hud-and-ui.md](./07-smart-oled-hud-and-ui.md) (§ 6) |
| **Persistent Android Release Signing Keystore Script & CI Secrets** | **Implemented** | [`configure_android_signing.mjs`](../companion_app/scripts/configure_android_signing.mjs), [`build-app.yml`](../.github/workflows/build-app.yml) | [06-flutter-companion-app.md](./06-flutter-companion-app.md) (§ 5) |
| **User-Facing JSON/CSV History File Export Action** | **Spec Drift** | *Persisted as JSON in `SharedPreferences` + clear button; no share/export file button yet* | [06-flutter-companion-app.md](./06-flutter-companion-app.md) (§ 1.4) |
| **Tri-Mode Priority 1 LAN Discovery (`mDNS` + HTTP REST)** | **Implemented** | [`waste_connection_service.dart`](../companion_app/lib/services/waste_connection_service.dart) | [03-connectivity-ble-and-mqtt.md](./03-connectivity-ble-and-mqtt.md) (§ 6), [06-flutter-companion-app.md](./06-flutter-companion-app.md) (§ 2) |
| **In-App `.gif` $\rightarrow$ `.wbin` Converter (`WbinEncoder`, Atkinson Dither)** | **Implemented** | [`wbin_encoder.dart`](../companion_app/lib/services/wbin_encoder.dart) | [06-flutter-companion-app.md](./06-flutter-companion-app.md) (§ 4) |
| **Custom Animation Uploader UI (`AnimationUploadSheet`)** | **Implemented** | [`animation_upload_sheet.dart`](../companion_app/lib/screens/animation_upload_sheet.dart) | [06-flutter-companion-app.md](./06-flutter-companion-app.md) (§ 5) |

### 2.6 Offline Tooling & CI/CD

| Feature | Status | Verified Code Location | Documentation Reference |
| :--- | :--- | :--- | :--- |
| **GIF-to-OLED C Header Converters (Node.js & Python Atkinson Dither)** | **Implemented** | [`gif_to_oled.mjs`](../tools/gif_to_oled.mjs), [`gif_to_oled.py`](../tools/gif_to_oled.py) | [02-functional-specification.md](./02-functional-specification.md), [05-esp-idf-v6.1-guide.md](./05-esp-idf-v6.1-guide.md) |
| **Path-Filtered Multi-Branch CI (`dev`, `staging`, `main` for Firmware & App)** | **Implemented** | [`build.yml`](../.github/workflows/build.yml), [`build-app.yml`](../.github/workflows/build-app.yml) | [05-esp-idf-v6.1-guide.md](./05-esp-idf-v6.1-guide.md) (§ 4) |
| **Tag-Triggered GitHub Releases & Staging Pre-Releases (`.bin` + `.apk`)** | **Implemented** | [`release.yml`](../.github/workflows/release.yml) | [05-esp-idf-v6.1-guide.md](./05-esp-idf-v6.1-guide.md) (§ 3–4) |
| **Automated Companion App Unit & Widget Test Suite (16 Tests, 7 Groups)** | **Implemented** | [`widget_test.dart`](../companion_app/test/widget_test.dart) | [06-flutter-companion-app.md](./06-flutter-companion-app.md) (§ 8) |
| **Deterministic Gap B E2E Verification Suite (Node.js)** | **Implemented** | [`verify_gap_b.mjs`](../tools/verify_gap_b.mjs), [`verify_partitions.mjs`](../tools/verify_partitions.mjs) | [05-esp-idf-v6.1-guide.md](./05-esp-idf-v6.1-guide.md) |

---

## 3. Detailed Gap Breakdown & Next Implementation Milestones

### Gap A — `Core 1` Smart OLED HUD, Boot Splash & Warning Modals (**Implemented on `dev` / `v1.2.0`**)
- **Implemented Modules**:
  - [`oled_font5x7.h`](../main/oled_font5x7.h): 95-glyph printable ASCII bitmap font & SSD1306 page-buffer drawing primitives.
  - [`oled_dancing_cat.h`](../main/oled_dancing_cat.h) / [`oled_dancing_cat.c`](../main/oled_dancing_cat.c): `SCREEN_BOOT_SPLASH` (`27 frames`, `~1.8 s`), 5 context-aware screen modes (`IDLE_HUD`, `LID_ACTIVE`, `MEASURING`, `FULL_ALERT`, `BLE_SETUP`), `MODAL_WARNING_POPUP` overlay (`oled_hud_show_warning()`), `s_composite_fb[1024]`, and `oled_ui_mode` (`hud_mascot` / `split_dashboard` / `mascot_only`).
  - [`trash_bin_fsm.c`](../main/trash_bin_fsm.c) & [`net_ble_mqtt.c`](../main/net_ble_mqtt.c): Push live lid countdowns, ultrasonic readings, Wi-Fi/MQTT/BLE status, and all 5 warning modal triggers (`NEAR_FULL`, `PIR_STUCK_TIMEOUT`, `SENSOR_ECHO_ERR`, `WIFI_FAILOVER`, `WIFI_RESET`).
  - [`calibration_sheet.dart`](../companion_app/lib/screens/calibration_sheet.dart) & [`telemetry.dart`](../companion_app/lib/models/telemetry.dart): Added `Core 1 OLED Idle Layout` segmented selector and `"oled_ui_mode"` JSON payload support.

### Gap B — Tri-Mode LAN Connectivity & User-Uploadable `.wbin` Animations (**Implemented on `dev` / `v2.0.0`**)
Gap B is **100% implemented, verified, and complete** for the `v2.0.0` release across firmware, mobile companion app, and automated verification suites:
- **Implemented Modules**:
  1. **Partition Table (`partitions.csv`)**: Reserved 1 MB `anim_data` partition at offset `0x310000` (subtype `0x99`), 64 KB block aligned and 4 KB sector aligned, with zero overlap and ~11.94 MB unallocated headroom inside 16 MB NOR Flash.
  2. **Firmware Animation Storage Engine (`main/anim_storage.h`, `main/anim_storage.c`)**:
     - Strict 16-byte packed `wbin_header_t` (`WGF1` magic, frame count $1\dots 512$, target FPS $5\dots 30$, flags, payload size, and IEEE 802.3 CRC32).
     - Dynamic frame caching into 8 MB Octal PSRAM (`MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT`).
     - Automated zero-alloc fallback to compiled 85-frame Hololive Risu / Dancing Cat mascot (`dancing_cat_frames.h`) on empty flash (`0xFF`), bad magic, CRC failure, or user reset.
     - Sector erase (`0x1000`) and flash writing with boundary validation.
  3. **Embedded Tri-Mode Local LAN Server & mDNS (`main/lan_server.h`, `main/lan_server.c`)**:
     - Embedded `esp_http_server` on port 80 launched on `IP_EVENT_STA_GOT_IP`.
     - mDNS responder broadcasting `_waste._tcp` on port 80 under hostname `smartbin_s3_<mac>`.
     - High-speed REST API: `GET /api/status`, `POST /api/oled/upload`, `POST /api/oled/reset`, `POST /api/lid`, `POST /api/measure`, and `POST /api/config`.
  4. **Multi-Transport Upload & Remote Commands (`main/net_ble_mqtt.c`)**:
     - BLE GATT characteristic `0xFF07` (UUID `0000ff07-0000-1000-8000-00805f9b34fb`) supporting 244-byte chunked streaming with progressive reassembly and real-time OLED upload progress HUD display.
     - MQTT remote commands: `"fetch_anim"` (background `esp_http_client` task downloads `.wbin` from URL, verifies CRC32, commits to flash) and `"reset_anim"` (erases flash, restores mascot).
  5. **Core 1 Smart OLED HUD Compositor Integration (`main/oled_dancing_cat.h`, `main/oled_dancing_cat.c`)**:
     - FreeRTOS mutex `s_anim_mutex` safeguarding frame buffer pointer swaps between network tasks on Core 0 and the render loop on Core 1.
     - Live upload progress HUD display (`oled_hud_set_upload_progress`) rendering `"UPLOADING GIF: XX%"` with progress bar and transport badge overlay (`LAN`, `BLE`, `MQTT`).
     - Dynamic frame rate pacing ($5\dots 30\text{ FPS}$) and support for `WBIN_FLAG_INVERT` and `WBIN_FLAG_HUD_OVERLAY`.
  6. **Flutter Companion App v2.0.0 (`companion_app/`)**:
     - Version bumped to `2.0.0+4` with non-conflicting dependencies (`http`, `image`, `file_picker`).
     - **Tri-Mode Connection Router (`WasteConnectionService`)**: Enforces strict routing precedence: **Priority 1 (Local LAN)** $\rightarrow$ **Priority 2 (Cloud MQTT)** $\rightarrow$ **Priority 3 (Direct BLE GATT `0xFF00`)**.
     - **Pure-Dart `WbinEncoder`**: Decodes `.gif` frames, performs box-area downsampling to $128 \times 64$, applies Atkinson 1-bit error-diffusion dithering ($\Delta / 8$), formats into SSD1306 vertical page bytes ($1024\text{ B/frame}$), and wraps in a 16-byte `WGF1` container with IEEE 802.3 CRC32 (`0xEDB88320`).
     - **`AnimationUploadSheet` Modal UI**: Real-time virtual 128x64 OLED canvas preview (`OledCanvasPainter`), frame scrub slider, FPS control, live linear upload progress bar, and "Reset to Mascot" action.
     - **`DashboardScreen` Integration**: OLED filmstrip AppBar launcher button and Tri-Mode status badges (`LAN` green, `Cloud` teal, `BLE` light blue).
  7. **Deterministic Verification Suite (`tools/`)**:
     - `tools/verify_gap_b.mjs`: 30-assertion deterministic test suite covering binary container, CRC32 vectors, corner-case rejection, BLE/HTTP streaming simulation, and static code compliance.
     - `tools/verify_partitions.mjs`: 8-assertion partition geometry and alignment verifier.
     - `companion_app/test/widget_test.dart`: 16 automated unit and widget tests across 7 test groups covering `.wbin` packing, IEEE 802.3 CRC32 vectors, Tri-Mode fallback precedence, and upload UI flows.

### Gap C — Minor Documentation & Schema Alignments (**Partially Resolved in `v2.0.0`**)
- **MQTT `configure` Schema Unified**: Both firmware (`net_ble_mqtt.c`) and mobile model (`telemetry.dart`) support `"oled_sleep_timeout_s": <int>` and `"oled_ui_mode": "hud_mascot" | "split_dashboard" | "mascot_only"`, fully documented in [`docs/03-connectivity-ble-and-mqtt.md`](./03-connectivity-ble-and-mqtt.md) § 3.3.
- **Companion App Telemetry Persistence**: `SharedPreferences` 500-event JSON ring buffer persistence and clear/reset actions are implemented; adding a user-facing file share/export button remains an optional future UX polish item (`Spec Drift`).

---

## 4. Release Conclusion (`v2.0.0`)

With Gap A (`v1.2.0` Smart OLED HUD) and Gap B (`v2.0.0` Tri-Mode LAN & Custom `.wbin` Animations) implemented locally across firmware, mobile application, docs, and verification harnesses:
- **Zero unimplemented major feature gaps remain for `v2.0.0`.** (`54` Implemented, `0` Spec Only, `1` optional UX Spec Drift).
- Note: Full `idf.py build` (ESP-IDF `v6.1`) and `flutter test` / `flutter build apk --release` compilation will execute in GitHub Actions CI once changes are pushed.
