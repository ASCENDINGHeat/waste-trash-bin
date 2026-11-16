# Changelog

All notable changes to **W.A.S.T.E.** (**W**aste **A**utomation and **S**ensing **T**echnology **E**ngine) are documented in this file.

---

## [v2.0.0] — Gap B: Tri-Mode LAN Connectivity & Custom .wbin OLED Animation Subsystem

### Release Assets (`v2.0.0`)
- **`waste-firmware-v2.0.0-merged.bin`**: All-in-one merged ESP32-S3 (`N16R8`) image (Bootloader + Partition Table + Application) for flashing at offset **`0x0`**.
- **`waste-firmware-v2.0.0.bin`**: Standalone application partition image for offset **`0x10000`**.
- **`waste-companion-v2.0.0.apk`**: Android Release APK for the **W.A.S.T.E. Flutter Companion App** (`v2.0.0+4`).

### Changes & Additions

#### 1. Embedded Tri-Mode Local LAN Server & mDNS Discovery (`main/lan_server.c`, `main/lan_server.h`)
- **Embedded HTTP REST Server (`esp_http_server`)**: Runs on port 80, automatically started upon `IP_EVENT_STA_GOT_IP` and stopped gracefully on STA disconnect.
- **mDNS Service Advertisement (`espressif/mdns`)**: Broadcasts service `_waste._tcp` on port 80 under hostname `smartbin_s3_<mac>` with TXT records (`vendor=ASCENDINGHeat`, `model=WASTE_S3_N16R8`, `version=2.0.0`, `device_id=smartbin_s3_<mac>`).
- **Full REST API Suite**:
  - `GET /api/status`: Returns real-time JSON telemetry (`fill_percent`, `distance_cm`, `lid_state`, `open_cycles`, `wifi_rssi`, `uptime_s`, `has_custom_anim`, `active_anim_frames`, `active_fps`).
  - `POST /api/oled/upload`: High-speed binary upload endpoint streaming `.wbin` directly into flash and PSRAM with sub-second transfer times.
  - `POST /api/oled/reset`: Erases custom animation partition and restores the default mascot.
  - `POST /api/lid`: Remote actuation command (`{"action":"open"|"close"}`).
  - `POST /api/measure`: Triggers immediate 5-ping median ultrasonic distance measurement.
  - `POST /api/config`: Updates fill thresholds, periodic ping intervals, and OLED UI display mode.

#### 2. Custom `.wbin` (`WGF1`) Animation Subsystem (`main/anim_storage.c`, `main/anim_storage.h`)
- **1 MB Dedicated Flash Partition (`anim_data`)**: Reserved at offset `0x310000` (subtype `0x99`, 64 KB block aligned & 4 KB sector aligned) in `partitions.csv`.
- **`.wbin` (`WGF1`) Binary Container Format**: 16-byte packed header (`magic: "WGF1"`, `num_frames: 1..512`, `target_fps: 5..30`, `flags` for pixel inversion and HUD overlay masking, `payload_bytes`, and standard IEEE 802.3 `crc32` over payload bytes).
- **8 MB Octal PSRAM Dynamic Frame Caching**: Allocates frame memory in Octal PSRAM (`MALLOC_CAP_SPIRAM`) at boot, dynamically pacing frames at target FPS ($5\dots 30\text{ FPS}$).
- **Automatic Fallback to Compiled Mascot**: Pre-renders the compiled 85-frame Hololive Risu / Dancing Cat mascot (`dancing_cat_frames.h`) into PSRAM on startup; in the event of an unprogrammed partition (`0xFF`), header error, CRC mismatch, or user reset, seamlessly falls back without memory allocations.
- **Live Upload Progress HUD**: Core 1 Smart OLED HUD compositing hook (`oled_hud_set_upload_progress`) displays a live progress bar overlay (`"UPLOADING GIF: XX%"`) with transport badge (`LAN`, `BLE`, or `MQTT`) during streaming.
- **Thread-Safe Cross-Core Synchronization**: FreeRTOS mutex (`s_anim_mutex`) protects frame pointer swaps between network tasks on Core 0 and the render loop on Core 1.

#### 3. BLE GATT Characteristic `0xFF07` Streaming (`main/net_ble_mqtt.c`)
- **Characteristic `0xFF07` Added**: UUID `0000ff07-0000-1000-8000-00805f9b34fb` with `Write` and `Write Without Response` properties under Service `0xFF00`.
- **Chunked Transfer Protocol**: Supports routerless chunked streaming up to negotiated MTU (244 bytes) with progressive reassembly, OLED HUD feedback, and atomic flash commitment upon CRC32 verification.

#### 4. MQTT Remote Animation Commands (`main/net_ble_mqtt.c`)
- **`fetch_anim` Command**: JSON `{"cmd":"fetch_anim","url":"http://..."}` spawns a background HTTP client task to stream a remote `.wbin` file directly into PSRAM, verify CRC32, and commit to `anim_data` flash.
- **`reset_anim` Command**: JSON `{"cmd":"reset_anim"}` erases the custom animation flash partition and restores the dancing cat mascot.

#### 5. Cross-Platform Flutter Companion App v2.0.0 (`companion_app/`)
- **Tri-Mode Connection Router (`WasteConnectionService`)**: Automatically resolves and prioritizes connections: **Priority 1 (Local LAN)** $\rightarrow$ **Priority 2 (Cloud MQTT)** $\rightarrow$ **Priority 3 (Direct BLE GATT `0xFF00`)**.
- **Pure-Dart GIF-to-`.wbin` Converter (`WbinEncoder`)**: Decodes user-selected `.gif` files, performs box-area downsampling to $128 \times 64$, applies Atkinson 1-bit error diffusion dithering ($\Delta / 8$), formats into SSD1306 vertical page bytes, and packs 16-byte `WGF1` containers with IEEE 802.3 CRC32 (`0xEDB88320`).
- **Custom Animation Uploader Modal (`AnimationUploadSheet`)**: Provides local GIF picking, geometric demo generator, live virtual 128x64 OLED canvas preview (`OledCanvasPainter`), frame scrub slider, target FPS control, upload progress bar, and "Reset to Mascot" action.
- **Dashboard UI Enhancements (`DashboardScreen`)**: Added AppBar launcher button for OLED animations and Tri-Mode status badges (`LAN` green, `Cloud` teal, `BLE` light blue).
- **Expanded Automated Test Suite (`test/widget_test.dart`)**: 16 unit and widget tests across 7 test groups covering `.wbin` packing, IEEE 802.3 CRC32 verification vectors, Tri-Mode fallback precedence, and upload UI flows.

#### 6. Build Manifests & Deterministic Verification Tooling
- **ESP-IDF v6.1 Manifests**: Registered `esp_http_server`, `mdns`, `esp_http_client`, `esp_partition`, `esp_crc` in `main/CMakeLists.txt` and `espressif/mdns` in `main/idf_component.yml`.
- **Deterministic Node.js Verification Suite (`tools/`)**:
  - `tools/verify_gap_b.mjs`: 4-tier E2E verification suite testing WGF1 binary layout, CRC32 vectors, corner-case rejection, streaming simulation, and static code compliance.
  - `tools/verify_partitions.mjs`: Validates 4KB sector and 64KB block alignment of `partitions.csv` and ensures non-overlapping layout within 16 MB NOR Flash.

---

## [v1.1.0] — Release Asset Rebranding & Smart OLED HUD Specification

### Release Assets (`v1.1.0`)
- **`waste-firmware-v1.1.0-merged.bin`**: All-in-one merged ESP32-S3 (`N16R8`) image (Bootloader + Partition Table + Application) for flashing at offset **`0x0`**.
- **`waste-firmware-v1.1.0.bin`**: Standalone application partition image for offset **`0x10000`**.
- **`waste-companion-v1.1.0.apk`**: Android Release APK for the **W.A.S.T.E. Flutter Companion App** (`v1.1.0+2`).

### Changes & Additions
- **Unified W.A.S.T.E. Binary & Artifact Naming**:
  - Renamed root CMake target in [`CMakeLists.txt`](./CMakeLists.txt) to `waste_firmware` (`waste_firmware_merged.bin`, `waste_firmware.bin`, `waste_firmware.elf`).
  - Updated GitHub Actions artifact name to `waste-esp32s3-firmware` and release assets to `waste-firmware-<tag>-merged.bin`, `waste-firmware-<tag>.bin`, and `waste-companion-<tag>.apk`.
  - Updated repository URLs across all documentation to `ASCENDINGHeat/waste-trash-bin`.
- **Smart OLED HUD, Boot Animation & Warning Modal Specification ([`docs/07-smart-oled-hud-and-ui.md`](./docs/07-smart-oled-hud-and-ui.md))**:
  - Specified the 6-mode **Core 1** $128 \times 64$ OLED HUD compositor (`SCREEN_BOOT_SPLASH`, `SCREEN_IDLE_HUD`, `SCREEN_LID_ACTIVE`, `SCREEN_MEASURING`, `SCREEN_FULL_ALERT`, `SCREEN_BLE_SETUP`), floating **Warning Popup Modal** overlay, and user-uploadable **`.wbin` Custom Animation** format.
- **Tri-Mode Connectivity Roadmap ([`docs/03-connectivity-ble-and-mqtt.md`](./docs/03-connectivity-ble-and-mqtt.md))**:
  - Documented the `BLE + LAN + MQTT` automatic transport router for `< 0.3s` local LAN `.wbin` animation uploads and zero-latency control.

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
