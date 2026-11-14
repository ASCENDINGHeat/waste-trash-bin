# 05 — ESP-IDF `^6.1` Build System, Drivers & Environment Guide

> [!IMPORTANT]
> This project targets **ESP-IDF `^6.1`** (`v6.1.x`). ESP-IDF v6.x introduces major architectural changes compared to v5.x, including CMake $\ge 3.22.1$, modularized `esp_driver_*` components, Picolibc as the default C library, and extracted managed components.

---

## 1. Key ESP-IDF `^6.1` Requirements & Breaking Changes

### 1.1 Minimum CMake Version (`3.22.1`)
Root `CMakeLists.txt` must specify at least CMake `3.22.1`:
```cmake
cmake_minimum_required(VERSION 3.22.1)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(esp_idf_project)
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

### 1.3 Managed Components (`main/idf_component.yml`)
In ESP-IDF `^6.1`, `cJSON`, `led_strip`, and `mqtt` (`esp-mqtt`) are distributed via the IDF Component Registry (`idf_component.yml`):
```yaml
dependencies:
  idf:
    version: ">=5.3.0"
  espressif/cjson: "*"
  espressif/led_strip: "^3.0.0"
  espressif/mqtt: "*"
```

### 1.4 Picolibc & Strict `-Werror` Enforcement
- **Picolibc**: Default standard C library in ESP-IDF v6.x (replaces Newlib for smaller flash/RAM footprint). Avoid Newlib-specific `_reent` internals.
- **`-Werror` by Default**: Unused variables, implicit conversions, or format-string mismatches (`PRIu32` vs `%d`) will fail compilation. Always use `<inttypes.h>` macros (`PRIu32`, `PRId64`) in `ESP_LOG*` calls.

---

## 2. Project Directory Structure

```text
esp-idf-project/
├── CMakeLists.txt                       # Root CMake (requires >= 3.22.1)
├── sdkconfig.defaults                   # ESP32-S3 N16R8 + NimBLE + Power Management defaults
├── README.md                            # Quick-start overview and links to docs/
├── docs/                                # Complete project documentation folder
│   ├── README.md                        # Documentation index
│   ├── 01-hardware-and-pinout.md        # YD-ESP32-23 N16R8 specs, jumpers, pin mapping
│   ├── 02-functional-specification.md   # Dual-core architecture, Trash Bin FSM, OLED GIF engine
│   ├── 03-connectivity-ble-and-mqtt.md  # NimBLE provisioning/failover, GATT, MQTT telemetry
│   ├── 04-power-management-and-battery.md # 1000 mAh battery analysis & sleep modes
│   └── 05-esp-idf-v6.1-guide.md         # ESP-IDF ^6.1 migration, drivers, and Git workflow
└── main/
    ├── CMakeLists.txt                   # Explicit esp_driver_* component registration
    ├── idf_component.yml                # IDF Component Manager manifest (^6.1.0)
    ├── Kconfig.projbuild                # Custom menuconfig parameters (pins, angles, intervals)
    ├── app_config.h / app_config.c      # NVS configuration persistence & shared types
    ├── power_mgr.h / power_mgr.c        # DFS, Light Sleep, 5V rail gate & RTC Deep Sleep
    ├── servo_sg90.h / servo_sg90.c      # GPIO 21 50Hz LEDC driver (fast open, soft close, auto-detach)
    ├── ultrasonic_hcsr04.h / .c         # GPIO 5/18 HC-SR04 5-sample median filter & 10-30cm mapping
    ├── rgb_status.h / rgb_status.c      # GPIO 48 WS2812B RMT status indicator
    ├── dancing_cat_frames.h             # 16-frame 128x64 Chinese Dancing Cat bitmap generator
    ├── oled_dancing_cat.h / .c          # Core 1 400kHz I2C OLED animation engine (GPIO 6/7)
    ├── net_ble_mqtt.h / net_ble_mqtt.c  # Wi-Fi STA, NimBLE GATT setup/failover, MQTT & PSRAM buffer
    ├── trash_bin_fsm.h / .c             # Core 0 Smart Trash Bin FSM, PIR blanking & periodic timer
    └── main.c                           # Application entry point (app_main)
```

---

## 3. Flashing the Compiled Firmware (`YD-ESP32-23` / `ESP32-S3 N16R8`)

### 3.1 Download Artifact from GitHub Actions
1. Open **[GitHub Actions](https://github.com/ASCENDINGHeat/esp-trash-bin/actions)** $\rightarrow$ select the latest successful workflow run.
2. Scroll to **Artifacts** and download **`esp32s3-trash-bin-firmware.zip`**.
3. Extract the zip. It contains:
   - **`esp_trash_bin_merged.bin`** — All-in-one merged image (Bootloader + Partition Table + Application). Flash at offset **`0x0`**.
   - Individual binaries (if flashing separately):
     - `bootloader.bin` $\rightarrow$ **`0x0`**
     - `partition-table.bin` $\rightarrow$ **`0x8000`**
     - `esp_trash_bin.bin` $\rightarrow$ **`0x10000`**

### 3.2 Entering Download Mode on `YD-ESP32-23`
- **Via `COM` (`UART`) USB-C Port (`CH343P`)**: Supports automatic bootloader entry via `DTR`/`RTS`.
- **Via `USB` (Native `ESP32-S3`) USB-C Port** (or if auto-reset does not trigger):
  1. Hold down the **`BOOT`** button.
  2. Press and release the **`RST`** button.
  3. Release the **`BOOT`** button.

### 3.3 Option A — Flash via Browser (No Software Install, Chrome / Edge)
1. Open **[Espressif ESPTool-JS Web Flasher](https://espressif.github.io/esptool-js/)**.
2. Connect the `YD-ESP32-23` via USB-C and click **Connect** (baudrate `460800` or `115200`).
3. Set **Flash Address** to **`0x0`** and select **`esp_trash_bin_merged.bin`**.
4. Click **Program**, then press **`RST`** on the board when finished.

### 3.4 Option B — Flash from Android Phone via USB-C OTG Cable
1. Connect your phone to the `YD-ESP32-23` (`USB` or `COM` port) using a USB-C to USB-C OTG cable and put the board into Download Mode (`Hold BOOT -> Tap RST -> Release BOOT`).
2. Use an Android ESP flasher app such as **ESPLoader** or **ZFlasher AVR/ESP**:
   - Chip: **`ESP32-S3`**
   - File: **`esp_trash_bin_merged.bin`**
   - Address / Offset: **`0x0`** (`0x00000000`)
3. Tap **Flash**, then press the **`RST`** button on the board.

### 3.5 Option C — Command Line (`esptool.py` on PC / Mac / Linux)
```bash
# Flash the single merged image at 0x0:
esptool.py --chip esp32s3 --port /dev/ttyACM0 --baud 460800 write_flash 0x0 esp_trash_bin_merged.bin
```

---

## 4. Git & SSH Remote Reference (Device Environment)

- **Repository Location**: `/storage/emulated/0/projects/esp-idf-project`
- **Remote (`origin`)**: `git@github.com:ASCENDINGHeat/esp-trash-bin.git`
- **Git Identity**: `ASCENDINGHeat <alfina.jauhar@gmail.com>` (no AI contributor or `Co-authored-by` metadata)
- **SSH Wrapper**: `/data/user/0/com.agy/files/usr/bin/agy-ssh` (uses `/data/user/0/com.agy/files/.ssh/config` and `/data/user/0/com.agy/files/.ssh/id_ed25519`)
- **Push Command**:
  ```bash
  export PATH="/data/user/0/com.agy/files/usr/bin:$PATH"
  export HOME="/data/user/0/com.agy/files"
  export GIT_CONFIG_NOSYSTEM=1
  git -C "/storage/emulated/0/projects/esp-idf-project" push origin main
  ```
