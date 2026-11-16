# 05 — W.A.S.T.E. ESP-IDF `^6.1` Build System, Drivers & Flashing Guide

> [!IMPORTANT]
> **W.A.S.T.E.** (**Waste Automation and Sensing Technology Engine**) targets **ESP-IDF `^6.1`** (`v6.1` Stable). ESP-IDF v6.x introduces CMake $\ge 3.22.1$, modularized `esp_driver_*` components, Picolibc as the default C library, and extracted managed components (`espressif/mqtt`, `espressif/cjson`, `espressif/led_strip`).

---

## 1. Key ESP-IDF `^6.1` Requirements & Breaking Changes

### 1.1 Minimum CMake Version (`3.22.1`)
Root `CMakeLists.txt` must specify at least CMake `3.22.1`:
```cmake
cmake_minimum_required(VERSION 3.22.1)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(waste_firmware)
```

### 1.2 Granular Peripheral Driver Components (`esp_driver_*`)
In ESP-IDF `^6.1`, the legacy umbrella `driver` component no longer implicitly exports all peripheral headers. Components must explicitly declare each required driver in `main/CMakeLists.txt`:

| Peripheral / Subsystem | Required ESP-IDF `^6.1` Component | Header File |
| :--- | :--- | :--- |
| **PIR (`GPIO 2`) & Ultrasonic (`GPIO 5, 18`)** | `esp_driver_gpio` | `driver/gpio.h` |
| **SG90 Servo PWM (`GPIO 21`)** | `esp_driver_ledc` | `driver/ledc.h` |
| **OLED Display I2C (`GPIO 6, 7`)** | `esp_driver_i2c` *(new master API)* | `driver/i2c_master.h` |
| **WS2812 RGB (`GPIO 48`) / RMT** | `esp_driver_rmt` | `driver/rmt_tx.h`, `driver/rmt_rx.h` |
| **High-Resolution Microsecond Timer** | `esp_timer` | `esp_timer.h` |
| **Power Management & Sleep** | `esp_pm`, `esp_hw_support` | `esp_pm.h`, `esp_sleep.h`, `driver/rtc_io.h` |
| **Wi-Fi, Event Loop & Netif** | `esp_wifi`, `esp_event`, `esp_netif` | `esp_wifi.h`, `esp_event.h`, `esp_netif.h` |
| **BLE (`NimBLE`)** | `bt` | `nimble/nimble_port.h`, `host/ble_hs.h` |
| **MQTT Client** | `mqtt` | `mqtt_client.h` |
| **Non-Volatile Storage** | `nvs_flash` | `nvs_flash.h`, `nvs.h` |
| **PSRAM Allocation** | `esp_psram` | `esp_psram.h`, `esp_heap_caps.h` |
| **Local HTTP REST Server** | `esp_http_server` | `esp_http_server.h` |
| **mDNS Service Responder** | `mdns` | `mdns.h` |
| **HTTP Client (Remote Fetch)** | `esp_http_client` | `esp_http_client.h` |
| **Flash Partition Manager** | `esp_partition` | `esp_partition.h` |
| **ROM / Hardware CRC32** | `esp_rom` / `esp_crc` | `esp_rom_crc.h` |

### 1.3 Managed Components (`main/idf_component.yml`)
In ESP-IDF `^6.1`, `cJSON`, `led_strip`, `mqtt` (`esp-mqtt`), and `mdns` are distributed via the IDF Component Registry (`idf_component.yml`):
```yaml
dependencies:
  idf:
    version: ">=5.3.0"
  espressif/cjson: "*"
  espressif/led_strip: "^3.0.0"
  espressif/mqtt: "*"
  espressif/mdns: "*"
```

### 1.4 Picolibc & Strict `-Werror` Enforcement
- **Picolibc**: Default standard C library in ESP-IDF v6.x (replaces Newlib for smaller flash/RAM footprint). Avoid Newlib-specific `_reent` internals.
- **`-Werror` by Default**: Unused variables, implicit conversions, or format-string mismatches (`PRIu32` vs `%d`) will fail compilation. Always use `<inttypes.h>` macros (`PRIu32`, `PRId64`) in `ESP_LOG*` calls.

---

## 2. Project Directory Structure

```text
waste-trash-bin/
├── CMakeLists.txt                       # Root CMake (requires >= 3.22.1, project(waste_firmware))
├── sdkconfig.defaults                   # ESP32-S3 N16R8 + NimBLE + Power Management defaults
├── partitions.csv                       # 16 MB Flash partition table (3 MB factory app + 1 MB anim_data @ 0x310000)
├── README.md                            # W.A.S.T.E. product overview, architecture & quick start
├── CHANGELOG.md                         # Release history (v2.0.0, v1.1.0 & v1.0.0)
├── .github/workflows/
│   ├── build.yml                        # Path-filtered ESP-IDF v6.1 firmware CI workflow
│   ├── build-app.yml                    # Path-filtered Flutter Companion APK & test CI workflow
│   └── release.yml                      # Tag-triggered (v*) GitHub Release publisher (.bin + .apk)
├── companion_app/                       # Cross-platform Flutter Companion App (Android / iOS)
│   ├── pubspec.yaml                     # Dependencies (http, image, file_picker, mqtt_client, flutter_blue_plus)
│   ├── lib/
│   │   ├── services/
│   │   │   ├── wbin_encoder.dart        # GIF decoding, Atkinson 1-bit dithering, WGF1 packing & CRC32
│   │   │   └── waste_connection_service.dart # Tri-Mode Transport Router (LAN -> MQTT -> BLE)
│   │   └── screens/
│   │       ├── animation_upload_sheet.dart   # Animation Uploader UI, virtual OLED canvas & scrub slider
│   │       ├── dashboard_screen.dart         # Material 3 dashboard, Tri-Mode badges & telemetry cards
│   │       └── ...
│   └── test/widget_test.dart            # 16 automated unit & widget tests across 7 test groups
├── tools/                               # Tooling & deterministic verification scripts
│   ├── verify_gap_b.mjs                 # 4-tier E2E verification suite for WGF1, CRC32, and static compliance
│   ├── verify_partitions.mjs            # Partition geometry and 4KB/64KB alignment verifier
│   ├── gif_to_oled.mjs                  # Node.js GIF decoder + Atkinson ditherer
│   └── gif_to_oled.py                   # Python Pillow GIF converter
├── docs/                                # Complete project documentation suite (01 through 08)
└── main/
    ├── CMakeLists.txt                   # Explicit esp_driver_* and network component registrations
    ├── idf_component.yml                # IDF Component Manager manifest (cjson, led_strip, mqtt, mdns)
    ├── Kconfig.projbuild                # Custom menuconfig parameters (pins, angles, intervals)
    ├── app_config.h / app_config.c      # NVS configuration persistence & shared types
    ├── power_mgr.h / power_mgr.c        # DFS, Light Sleep, 5V rail gate & RTC Deep Sleep
    ├── servo_sg90.h / servo_sg90.c      # GPIO 21 50Hz LEDC driver (fast open, soft close, auto-detach)
    ├── ultrasonic_hcsr04.h / .c         # GPIO 5/18 HC-SR04 5-sample median filter & 10-30cm mapping
    ├── rgb_status.h / rgb_status.c      # GPIO 48 WS2812B RMT status indicator
    ├── anim_storage.h / anim_storage.c  # anim_data flash partition I/O, .wbin header/CRC verification, PSRAM load
    ├── lan_server.h / lan_server.c      # Local HTTP REST server (port 80) & mDNS responder (_waste._tcp)
    ├── oled_font5x7.h                   # 95-glyph ASCII font & UI drawing primitives
    ├── dancing_cat_frames.h             # 85-frame 128x64 Atkinson-dithered mascot fallback bitmap array
    ├── oled_dancing_cat.h / .c          # Core 1 Smart OLED HUD compositor & live upload progress bar
    ├── net_ble_mqtt.h / net_ble_mqtt.c  # Wi-Fi STA, NimBLE GATT (0xFF00-0xFF07), BOOT button, MQTT fetch/reset
    ├── trash_bin_fsm.h / .c             # Core 0 W.A.S.T.E. FSM, PIR blanking & periodic timer
    └── main.c                           # Application entry point (app_main)
```

---

## 3. Flashing the Compiled Firmware (`YD-ESP32-23` / `ESP32-S3 N16R8`)

### 3.1 Download Binary from GitHub Releases (`v2.0.0`) or Actions
1. **From GitHub Releases (Recommended)**:
   - Open **[Releases (`v2.0.0`)](https://github.com/ASCENDINGHeat/waste-trash-bin/releases/tag/v2.0.0)** and download **`waste-firmware-v2.0.0-merged.bin`** (and **`waste-companion-v2.0.0.apk`** for Android).
2. **From GitHub Actions (Latest Commit)**:
   - Open **[GitHub Actions](https://github.com/ASCENDINGHeat/waste-trash-bin/actions)** $\rightarrow$ select the latest workflow run and download **`waste-esp32s3-firmware-<branch>.zip`** (for example `waste-esp32s3-firmware-main.zip`, `-staging.zip`, or `-dev.zip`).
   - Extract the zip to get **`waste_firmware_merged.bin`** (all-in-one Bootloader + Partition Table + Application image for offset **`0x0`**), or individual binaries (`bootloader.bin` at `0x0`, `partition-table.bin` at `0x8000`, `waste_firmware.bin` at `0x10000`).

### 3.2 Entering Download Mode on `YD-ESP32-23`
- **Via `COM` (`UART`) USB-C Port (`CH343P`)**: Supports automatic bootloader entry via `DTR`/`RTS`.
- **Via `USB` (Native `ESP32-S3`) USB-C Port** (or if auto-reset does not trigger):
  1. Hold down the **`BOOT`** button.
  2. Press and release the **`RST`** button.
  3. Release the **`BOOT`** button.

### 3.3 Option A — Flash via Browser (No Software Install, Chrome / Edge)
1. Open **[Espressif ESPTool-JS Web Flasher](https://espressif.github.io/esptool-js/)**.
2. Connect the `YD-ESP32-23` via USB-C and click **Connect** (baudrate `460800` or `115200`).
3. Set **Flash Address** to **`0x0`** and select **`waste-firmware-v2.0.0-merged.bin`**.
4. Click **Program**, then press **`RST`** on the board when finished.

### 3.4 Option B — Flash from Android Phone via USB-C OTG Cable
1. Connect your phone to the `YD-ESP32-23` (`USB` or `COM` port) using a USB-C to USB-C OTG cable and put the board into Download Mode (`Hold BOOT -> Tap RST -> Release BOOT`).
2. Use an Android ESP flasher app such as **ESPLoader** or **ZFlasher AVR/ESP**:
   - Chip: **`ESP32-S3`**
   - File: **`waste-firmware-v2.0.0-merged.bin`**
   - Address / Offset: **`0x0`** (`0x00000000`)
3. Tap **Flash**, then press the **`RST`** button on the board.

### 3.5 Option C — Command Line (`esptool.py` on PC / Mac / Linux)
```bash
# Flash the single merged image at 0x0:
esptool.py --chip esp32s3 --port /dev/ttyACM0 --baud 460800 write_flash 0x0 waste-firmware-v2.0.0-merged.bin
```

---

## 4. Branching & CI/CD Promotion Strategy (`dev` $\rightarrow$ `staging` $\rightarrow$ `main`)

The repository uses a three-tier branching model backed by path-filtered GitHub Actions workflows:

```mermaid
flowchart LR
    FEAT["Feature Branches"] -->|"PR / Merge"| DEV["dev (Active Development)"]
    DEV -->|"PR / Merge"| STG["staging (Hardware QA & Soak Test)"]
    STG -->|"PR / Merge"| MAIN["main (Production Stable)"]
    STG -.->|"Tag vX.Y.Z-rc.N"| PRE["GitHub Pre-Release"]
    MAIN -.->|"Tag vX.Y.Z"| REL["GitHub Production Release"]
```

| Branch | Purpose | CI Workflows Triggered | Artifact Suffix | Release Behavior |
| :--- | :--- | :--- | :--- | :--- |
| **`dev`** | Active feature integration (firmware & Flutter UI) | `build.yml`, `build-app.yml` | `-dev` | CI artifacts only |
| **`staging`** | Pre-release candidate soak testing on `YD-ESP32-23` | `build.yml`, `build-app.yml` | `-staging` | Tags with `-` (e.g. `v2.0.0-rc.1`) publish a **Pre-Release** |
| **`main`** | Stable production branch | `build.yml`, `build-app.yml` | `-main` | Clean tags (e.g. `v2.0.0`) publish a **Production Release** |

---

## 5. Git & SSH Remote Reference (Device Environment)

- **Repository Location**: `/storage/emulated/0/projects/esp-idf-project`
- **Remote (`origin`)**: `git@github.com:ASCENDINGHeat/waste-trash-bin.git`
- **Git Identity**: `ASCENDINGHeat <alfina.jauhar@gmail.com>` (no AI contributor or `Co-authored-by` metadata)
- **SSH Wrapper**: `/data/user/0/com.agy/files/usr/bin/agy-ssh` (uses `/data/user/0/com.agy/files/.ssh/config` and `/data/user/0/com.agy/files/.ssh/id_ed25519`)
- **Push Command**:
  ```bash
  export PATH="/data/user/0/com.agy/files/usr/bin:$PATH"
  export HOME="/data/user/0/com.agy/files"
  export GIT_CONFIG_NOSYSTEM=1
  git -C "/storage/emulated/0/projects/esp-idf-project" push origin dev staging main
  ```
