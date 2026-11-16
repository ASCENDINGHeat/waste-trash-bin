# 08 — W.A.S.T.E. Feature Tracking & Documentation Gap Analysis

> [!NOTE]
> This document tracks **currently implemented features** in the **`v1.1.0`** codebase (`dev` / `staging` / `main`) and compares them side-by-side against all specifications in `docs/01` through `docs/07` to clearly identify what is **live in code** versus **documented for future milestones**.

**Baseline Audited**: Commit `8f3bbf5` (`v1.1.0` + multi-branch CI/CD)

---

## 1. Implementation Summary

| Category | Implemented (`Live`) | Planned / Spec Only (`Not Yet Built`) | Minor Spec Drift |
| :--- | :---: | :---: | :---: |
| **Core Hardware, FSM & Sensors (`main/`)** | 9 | 0 | 0 |
| **Power Management & NVS (`main/`)** | 6 | 0 | 0 |
| **BLE, Wi-Fi & MQTT (`main/net_ble_mqtt.c`)** | 7 | 2 | 1 |
| **OLED Display Engine (`main/oled_dancing_cat.c`)** | 3 | 8 | 0 |
| **Flutter Companion App (`companion_app/`)** | 7 | 3 | 1 |
| **Tools & CI/CD (`tools/`, `.github/workflows/`)** | 6 | 0 | 0 |

**Legend**:
- **Implemented**: Verified directly in C/Dart source code and active in compiled builds.
- **Spec Only (Not Implemented)**: Documented in `docs/` (`03`, `06`, `07`) as target architecture, with no runtime code yet.
- **Partial / Spec Drift**: Working in code, but schema/UX differs slightly from a documentation example.

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
| **`anim_data` (`1 MB`, Subtype `0x99`) Flash Partition for `.wbin`** | **Not Implemented** | [`partitions.csv`](../partitions.csv) *(only `nvs`, `phy_init`, `factory`)* | [07-smart-oled-hud-and-ui.md](./07-smart-oled-hud-and-ui.md) (§ 7.3) |

### 2.3 Connectivity: Wi-Fi, NimBLE, MQTT & LAN

| Feature | Status | Verified Code Location | Documentation Reference |
| :--- | :--- | :--- | :--- |
| **Wi-Fi STA Auto-Connect + 5-Retry BLE Failover + 60s Reconnect** | **Implemented** | [`net_ble_mqtt.c`](../main/net_ble_mqtt.c) | [03-connectivity-ble-and-mqtt.md](./03-connectivity-ble-and-mqtt.md) (§ 1) |
| **`NimBLE` GATT `0xFF00` (`0xFF01`–`0xFF06`: Creds, Notify Telemetry, JSON Cmd)** | **Implemented** | [`net_ble_mqtt.c`](../main/net_ble_mqtt.c) | [03-connectivity-ble-and-mqtt.md](./03-connectivity-ble-and-mqtt.md) (§ 2.2) |
| **Onboard `BOOT` (`GPIO 0`) Short Press BLE Advertise / 3s Hold NVS Reset** | **Implemented** | [`net_ble_mqtt.c`](../main/net_ble_mqtt.c) | [03-connectivity-ble-and-mqtt.md](./03-connectivity-ble-and-mqtt.md) |
| **`esp-mqtt` Topics (`telemetry`, `alert` $\ge 95\%$, LWT `status`, `cmd`)** | **Implemented** | [`net_ble_mqtt.c`](../main/net_ble_mqtt.c) | [03-connectivity-ble-and-mqtt.md](./03-connectivity-ble-and-mqtt.md) (§ 3.1) |
| **256-Slot Octal PSRAM Offline Telemetry Ring Buffer** | **Implemented** | [`net_ble_mqtt.c`](../main/net_ble_mqtt.c) | [03-connectivity-ble-and-mqtt.md](./03-connectivity-ble-and-mqtt.md) (§ 4) |
| **Remote Commands (`measure_now`, `open_lid`, `ble_provision`, `reset_wifi`, `configure`)** | **Implemented** | [`net_ble_mqtt.c`](../main/net_ble_mqtt.c) (`handle_mqtt_cmd_payload`) | [03-connectivity-ble-and-mqtt.md](./03-connectivity-ble-and-mqtt.md) (§ 3.3) |
| **`configure` JSON OLED Field Name (`oled_sleep_timeout_s` vs `oled_mode`)** | **Spec Drift** | [`net_ble_mqtt.c`](../main/net_ble_mqtt.c) parses `"oled_sleep_timeout_s"` | [03-connectivity-ble-and-mqtt.md](./03-connectivity-ble-and-mqtt.md) (§ 3.3 shows `"oled_mode"`) |
| **Local LAN HTTP REST + WebSocket + `mDNS` (`esp_http_server`)** | **Not Implemented** | *No HTTP server or mDNS component in `main/`* | [03-connectivity-ble-and-mqtt.md](./03-connectivity-ble-and-mqtt.md) (§ 6) |
| **BLE GATT `0xFF07` Chunked `.wbin` Animation Upload Characteristic** | **Not Implemented** | [`net_ble_mqtt.c`](../main/net_ble_mqtt.c) *(UUIDs stop at `0xFF06`)* | [07-smart-oled-hud-and-ui.md](./07-smart-oled-hud-and-ui.md) (§ 7.4) |

### 2.4 `Core 1` OLED Engine & Smart HUD UI

| Feature | Status | Verified Code Location | Documentation Reference |
| :--- | :--- | :--- | :--- |
| **`400 kHz` I2C Master OLED Driver (`SCL = GPIO 6`, `SDA = GPIO 7`)** | **Implemented** | [`oled_dancing_cat.c`](../main/oled_dancing_cat.c) (`oled_hw_init`) | [01-hardware-and-pinout.md](./01-hardware-and-pinout.md), [02-functional-specification.md](./02-functional-specification.md) |
| **85-Frame Hololive Risu Animation Streamed from 8 MB Octal PSRAM (`15 FPS`)** | **Implemented** | [`oled_dancing_cat.c`](../main/oled_dancing_cat.c), [`dancing_cat_frames.h`](../main/dancing_cat_frames.h) | [02-functional-specification.md](./02-functional-specification.md) |
| **Display Sleep Timeout (`0xAE` OFF / `0xAF` Wake on Activity)** | **Implemented** | [`oled_dancing_cat.c`](../main/oled_dancing_cat.c) (`oled_dancing_cat_set_sleep_timeout`) | [04-power-management-and-battery.md](./04-power-management-and-battery.md) |
| **5x7 ASCII Font & Compositor Buffer (`oled_font5x7.h`, `s_composite_fb[1024]`)** | **Not Implemented** | *Raw frame blitting only* | [07-smart-oled-hud-and-ui.md](./07-smart-oled-hud-and-ui.md) (§ 5–6) |
| **Boot Splash Animation & POST Checklist (`SCREEN_BOOT_SPLASH`)** | **Not Implemented** | *Immediately starts GIF loop* | [07-smart-oled-hud-and-ui.md](./07-smart-oled-hud-and-ui.md) (§ 3.1) |
| **5 Event-Driven HUD Modes (`IDLE_HUD`, `LID_ACTIVE`, `MEASURING`, `FULL_ALERT`, `BLE_SETUP`)** | **Not Implemented** | *No `Core 0 -> Core 1` HUD state struct* | [07-smart-oled-hud-and-ui.md](./07-smart-oled-hud-and-ui.md) (§ 3.2–3.6) |
| **Warning Popup Modal Overlay (`MODAL_WARNING_POPUP` / `oled_hud_show_warning()`)** | **Not Implemented** | *No modal compositor or warning queue* | [07-smart-oled-hud-and-ui.md](./07-smart-oled-hud-and-ui.md) (§ 4) |
| **`oled_ui_mode` Runtime Switch (`hud_mascot` / `split_dashboard` / `mascot_only`)** | **Not Implemented** | *Not in `smartbin_config_t` or `configure`* | [07-smart-oled-hud-and-ui.md](./07-smart-oled-hud-and-ui.md) (§ 3.2, § 6) |
| **User-Uploadable `.wbin` (`WGF1`) Custom Animation Loader + CRC32 + Fallback** | **Not Implemented** | *Hardcoded to `s_dancing_cat_gif_bitmap`* | [07-smart-oled-hud-and-ui.md](./07-smart-oled-hud-and-ui.md) (§ 7) |

### 2.5 W.A.S.T.E. Flutter Companion App (`companion_app/`)

| Feature | Status | Verified Code Location | Documentation Reference |
| :--- | :--- | :--- | :--- |
| **Material 3 Dashboard, Fill Gauge & `fl_chart` Trend Graph** | **Implemented** | [`dashboard_screen.dart`](../companion_app/lib/screens/dashboard_screen.dart) | [06-flutter-companion-app.md](./06-flutter-companion-app.md) |
| **MQTT `3.1.1` Client (Flespi Token `userInfo`, TLS `8883`, Wildcard Discovery)** | **Implemented** | [`waste_connection_service.dart`](../companion_app/lib/services/waste_connection_service.dart) | [03-connectivity-ble-and-mqtt.md](./03-connectivity-ble-and-mqtt.md), [06-flutter-companion-app.md](./06-flutter-companion-app.md) |
| **BLE GATT `0xFF00` Failover, `247B` MTU & Provisioning Sheet (`Flespi Preset`)** | **Implemented** | [`ble_provision_sheet.dart`](../companion_app/lib/screens/ble_provision_sheet.dart), [`waste_connection_service.dart`](../companion_app/lib/services/waste_connection_service.dart) | [06-flutter-companion-app.md](./06-flutter-companion-app.md) |
| **Remote Actions (`open_lid`, `measure_now`) & Sensor Calibration Sheet** | **Implemented** | [`calibration_sheet.dart`](../companion_app/lib/screens/calibration_sheet.dart), [`waste_connection_service.dart`](../companion_app/lib/services/waste_connection_service.dart) | [06-flutter-companion-app.md](./06-flutter-companion-app.md) |
| **500-Event Local History Ring (`SharedPreferences`)** | **Implemented** | [`waste_connection_service.dart`](../companion_app/lib/services/waste_connection_service.dart) | [06-flutter-companion-app.md](./06-flutter-companion-app.md) |
| **User-Facing JSON/CSV History File Export Action** | **Spec Drift** | *Persisted as JSON in `SharedPreferences` + clear button; no share/export button yet* | [06-flutter-companion-app.md](./06-flutter-companion-app.md) (§ 1.4) |
| **OLED UI Mode Selector (`oled_ui_mode`) in Calibration UI** | **Not Implemented** | [`calibration_sheet.dart`](../companion_app/lib/screens/calibration_sheet.dart) | [07-smart-oled-hud-and-ui.md](./07-smart-oled-hud-and-ui.md) (§ 6) |
| **Tri-Mode Priority 1 LAN Discovery (`mDNS` + HTTP REST/WS)** | **Not Implemented** | *Dual MQTT + BLE only* | [03-connectivity-ble-and-mqtt.md](./03-connectivity-ble-and-mqtt.md) (§ 6) |
| **In-App `.gif` $\rightarrow$ `.wbin` Converter, Preview & Uploader** | **Not Implemented** | *CLI converters only (`tools/`)* | [07-smart-oled-hud-and-ui.md](./07-smart-oled-hud-and-ui.md) (§ 7.1, § 7.4) |

### 2.6 Offline Tooling & CI/CD

| Feature | Status | Verified Code Location | Documentation Reference |
| :--- | :--- | :--- | :--- |
| **GIF-to-OLED C Header Converters (Node.js & Python Atkinson Dither)** | **Implemented** | [`gif_to_oled.mjs`](../tools/gif_to_oled.mjs), [`gif_to_oled.py`](../tools/gif_to_oled.py) | [02-functional-specification.md](./02-functional-specification.md), [05-esp-idf-v6.1-guide.md](./05-esp-idf-v6.1-guide.md) |
| **Path-Filtered Multi-Branch CI (`dev`, `staging`, `main` for Firmware & App)** | **Implemented** | [`build.yml`](../.github/workflows/build.yml), [`build-app.yml`](../.github/workflows/build-app.yml) | [05-esp-idf-v6.1-guide.md](./05-esp-idf-v6.1-guide.md) (§ 4) |
| **Tag-Triggered GitHub Releases & Staging Pre-Releases (`.bin` + `.apk`)** | **Implemented** | [`release.yml`](../.github/workflows/release.yml) | [05-esp-idf-v6.1-guide.md](./05-esp-idf-v6.1-guide.md) (§ 3–4) |
| **Automated Companion App Unit & Widget Test Suite** | **Implemented** | [`widget_test.dart`](../companion_app/test/widget_test.dart) | [06-flutter-companion-app.md](./06-flutter-companion-app.md) |

---

## 3. Detailed Gap Breakdown & Next Implementation Milestones

### Gap A — `Core 1` Smart OLED HUD, Boot Splash & Warning Modals (`v1.2.0` Target)
- **What exists today**: [`oled_dancing_cat.c`](../main/oled_dancing_cat.c) initializes the SSD1306/SH1106 display over 400 kHz I2C, unpacks the 85 frames of [`dancing_cat_frames.h`](../main/dancing_cat_frames.h) into Octal PSRAM, loops them on `Core 1`, and toggles `0xAE`/`0xAF` on sleep timeout.
- **What needs to be built**:
  1. Add `main/oled_font5x7.h` with 95-glyph ASCII rasterizer and drawing primitives (box, inverted header, drop shadow, progress bar).
  2. Implement `s_composite_fb[1024]` and lock-free `oled_hud_state_t` snapshot (`oled_hud_update()`, `oled_hud_show_warning()`).
  3. Implement `SCREEN_BOOT_SPLASH` (27 frames / `1.8 s`), the 5 context-aware screens (`IDLE_HUD`, `LID_ACTIVE`, `MEASURING`, `FULL_ALERT`, `BLE_SETUP`), and `MODAL_WARNING_POPUP`.
  4. Wire triggers from `trash_bin_fsm.c` and `net_ble_mqtt.c` (`NEAR_FULL` $\ge 85\%$, `PIR_STUCK_TIMEOUT`, `SENSOR_ECHO_ERR`, `WIFI_FAILOVER`, `WIFI_RESET`).

### Gap B — Tri-Mode LAN Connectivity & User-Uploadable `.wbin` Animations (`v1.3.0` Target)
- **What exists today**: Dual-transport (Cloud MQTT + BLE GATT `0xFF00`–`0xFF06`), `3 MB` factory app partition in [`partitions.csv`](../partitions.csv), and desktop CLI converters in [`tools/`](../tools/).
- **What needs to be built**:
  1. Add `anim_data` (`1 MB`, offset `0x310000` or after `factory`) to `partitions.csv` and `.wbin` (`WGF1`) CRC32 loader with fallback to `dancing_cat_frames.h`.
  2. Add `esp_http_server` + `mdns` on the ESP32-S3 (`POST /api/oled/upload`, local status/control endpoints) and BLE characteristic `0xFF07` for routerless chunked uploads.
  3. Extend `WasteConnectionService` in Flutter with Priority-1 LAN discovery and add an in-app GIF $\rightarrow$ `.wbin` converter + upload sheet.

### Gap C — Minor Documentation & Schema Alignments
- **MQTT `configure` OLED field**: [`docs/03-connectivity-ble-and-mqtt.md`](./03-connectivity-ble-and-mqtt.md) § 3.3 lists `"oled_mode": "always_on"`, whereas firmware ([`net_ble_mqtt.c`](../main/net_ble_mqtt.c)) and [`WasteBinConfig`](../companion_app/lib/models/telemetry.dart) currently implement `"oled_sleep_timeout_s": <int>` (keeping `oled_ui_mode` reserved for the upcoming HUD UI switch).
- **Companion App History Export**: `SharedPreferences` persistence works for 500 events, and adding a Share/Export JSON button in `dashboard_screen.dart` will close the remaining item mentioned in [`docs/06-flutter-companion-app.md`](./06-flutter-companion-app.md).
