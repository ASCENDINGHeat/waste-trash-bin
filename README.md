<div align="center">

# W.A.S.T.E.
### **W**aste **A**utomation and **S**ensing **T**echnology **E**ngine

*Next-Generation Dual-Core IoT Smart Receptacle Firmware for ESP32-S3 (`N16R8`)*

[![ESP-IDF v6.1](https://img.shields.io/badge/ESP--IDF-v6.1%20Stable-red?logo=espressif)](https://github.com/espressif/esp-idf)
[![MCU](https://img.shields.io/badge/MCU-ESP32--S3%20N16R8-blue?logo=espressif)](./docs/01-hardware-and-pinout.md)
[![Memory](https://img.shields.io/badge/Memory-16MB%20Flash%20%7C%208MB%20Octal%20PSRAM-success)](./docs/01-hardware-and-pinout.md)
[![Connectivity](https://img.shields.io/badge/Connectivity-MQTT%20%2B%20NimBLE%20Failover-orange)](./docs/03-connectivity-ble-and-mqtt.md)
[![Build Firmware](https://github.com/ASCENDINGHeat/esp-trash-bin/actions/workflows/build.yml/badge.svg)](https://github.com/ASCENDINGHeat/esp-trash-bin/actions)

</div>

---

## Overview

**W.A.S.T.E.** (**Waste Automation and Sensing Technology Engine**) is an industrial-grade, dual-core embedded firmware platform built on **ESP-IDF `v6.1`** for the **`YD-ESP32-23` (`ESP32-S3-WROOM-1-N16R8`)**.

Designed from the ground up to eliminate the common failure modes of consumer "smart" bins—such as lid-slamming, power-rail false re-triggering, acoustic echo spikes, and offline data loss—**W.A.S.T.E.** combines touchless motion actuation, median-filtered ultrasonic fill analytics, self-healing Wi-Fi/BLE networking, and a dedicated **Core 1** high-speed I2C OLED animation engine.

---

## Key Capabilities

### 1. Touchless Kinematics & Anti-Slam Servo Control
- **Instant Motion Response (`150 ms`)**: `HC-SR501` PIR sensing on `GPIO 2` (`RTC_GPIO2`) triggers immediate lid opening via 14-bit `50 Hz` LEDC PWM (`GPIO 21`).
- **Soft-Close Ramping (`500 ms`)**: Smoothly interpolates `SG90` closing trajectory to prevent mechanical lid slam and sensor vibration.
- **Zero-Hum PWM Auto-Detach**: Automatically halts PWM pulses (`ledc_stop`) `400 ms` after closure—eliminating idle stall current ($15\text{–}40\text{ mA} \rightarrow 0\text{ mA}$), servo heating, and 5V rail noise.
- **PIR Anti-Retrigger Blanking (`1.5 s`)**: Hardware/software blanking window prevents 5V servo transients from causing endless open–close ghost loops.

### 2. Precision Ultrasonic Fill-Level Analytics
- **Post-Close + Periodic Sensing**: Automatically fires the `HC-SR04` (`TRIG = GPIO 5`, `ECHO = GPIO 18`) after every lid closure **and** on a configurable background schedule (default every `15 minutes` while closed) to detect trash settling.
- **5-Ping Median Filtering**: Rejects multipath acoustic bounces inside crinkled bin liners by sorting 5 rapid ultrasonic samples and extracting the true median distance.
- **Calibrated Fill Mapping**: Linearly maps bin depth from **$30\text{ cm}$ ($0\%$ Empty)** to **$10\text{ cm}$ ($100\%$ Full)** with runtime-configurable thresholds over MQTT.
- **Onboard `WS2812B` RGB Status (`GPIO 48`)**: Visual fill-level feedback (**Green** $< 50\%$, **Amber** $50\text{–}84\%$, **Red** $\ge 85\%$, **Blue** = BLE Setup/Failover) with a 5-second battery-saver auto-off timer.

### 3. Self-Healing Connectivity: MQTT + NimBLE Failover
- **Real-Time MQTT Telemetry (`esp-mqtt`)**: Publishes structured JSON telemetry (`smartbin/<id>/telemetry`), retained full-bin alerts (`smartbin/<id>/alert`), and Last Will & Testament online/offline state (`smartbin/<id>/status`).
- **256-Event Octal PSRAM Ring Buffer**: Never loses a telemetry event during Wi-Fi outages—records are buffered in the **8 MB Octal PSRAM** (and lifetime `open_cycles` persisted in Flash NVS) and flushed chronologically the instant MQTT reconnects.
- **Zero-Touch BLE Provisioning & Failover (`NimBLE`)**: Automatically advertises a custom BLE GATT service (`0xFF00`) on first boot or whenever Wi-Fi drops, allowing live smartphone telemetry readouts (`0xFF05`) and over-the-air Wi-Fi/MQTT reconfiguration without reflashing.

### 4. Dedicated `Core 1` OLED Animation Engine
- **100% Decoupled Visual Pipeline**: Pinned exclusively to **Xtensa LX7 `Core 1`**, streaming an 85-frame Atkinson-dithered $128 \times 64$ animation (`SCL = GPIO 6`, `SDA = GPIO 7` @ `400 kHz` I2C) directly from **8 MB Octal PSRAM** with zero frame drops during Wi-Fi, BLE, or sensor operations.
- **Custom GIF Toolchain Included**: Convert any `.gif` into a ready-to-compile 1-bit OLED header in seconds using [`tools/gif_to_oled.mjs`](./tools/gif_to_oled.mjs) or [`tools/gif_to_oled.py`](./tools/gif_to_oled.py).

### 5. Cross-Platform Flutter Companion App (`companion_app/`)
- **Dual-Transport Live Dashboard**: Connects via **MQTT** (LAN/Cloud) and automatically switches to **BLE GATT (`0xFF00`–`0xFF06`)** when offline.
- **Zero-Touch Provisioning & Remote Control**: Scan & provision Wi-Fi/MQTT credentials over BLE, remotely open the lid (`open_lid`), trigger instant ultrasonic pings (`measure_now`), calibrate bin depth ($10\text{–}30\text{ cm}$), and view historical fill-level trend charts stored locally on the phone.

---

## Dual-Core Architecture

```mermaid
flowchart TD
    subgraph Core0["Core 0 — W.A.S.T.E. Control & Telemetry Engine"]
        PIR["HC-SR501 Motion (GPIO 2)"] -->|Rising Edge ISR| FSM["W.A.S.T.E. Finite State Machine"]
        TIMER["Periodic Timer (15 min)"] -->|Background Check| FSM
        FSM -->|Fast Open / Soft Close + Auto-Detach| SERVO["SG90 Servo LEDC (GPIO 21)"]
        FSM -->|5-Ping Median Filter| ULTRA["HC-SR04 Ultrasonic (TRIG: 5, ECHO: 18)"]
        ULTRA -->|Distance & Fill %| FSM
        FSM -->|Status Indicator| RGB["WS2812B RGB LED (GPIO 48)"]
        FSM -->|JSON Telemetry| NET["Network Manager (Wi-Fi + NimBLE + MQTT)"]
        NET <-->|Offline Queue| PSRAM_RB["256-Slot Octal PSRAM Ring Buffer"]
    end

    subgraph Core1["Core 1 — Dedicated Visual Animation Engine"]
        FRAMES["85-Frame Animation Cache (8MB Octal PSRAM)"] --> OLED_TASK["OLED Render Task (15-25 FPS)"]
        OLED_TASK -->|400kHz I2C Master (SCL: 6, SDA: 7)| OLED["128x64 I2C OLED Display"]
    end

    subgraph Mobile["W.A.S.T.E. Flutter Companion App (companion_app/)"]
        APP["Android / iOS Dashboard\n+ History Chart + Remote Control"]
    end

    NET <==>|"MQTT (Wi-Fi) or BLE GATT (0xFF00)"| APP
```

---

## Hardware & Pinout Summary (`YD-ESP32-23` / `ESP32-S3 N16R8`)

| Subsystem | Component | Signal | ESP32-S3 Pin | Notes |
| :--- | :--- | :--- | :--- | :--- |
| **Motion Sensor** | `HC-SR501` PIR | `OUT` | **`GPIO 2`** (`RTC_GPIO2`) | 3.3V HIGH on motion; supports `ext0` Deep Sleep wakeup |
| **Distance Sensor** | `HC-SR04` Ultrasonic | `TRIG` | **`GPIO 5`** | $10\text{ }\mu\text{s}$ trigger pulse output |
| **Distance Sensor** | `HC-SR04` Ultrasonic | `ECHO` | **`GPIO 18`** | Pulse-width input ($10\text{ cm} = 100\%$, $30\text{ cm} = 0\%$) |
| **Lid Actuator** | `SG90` Micro Servo | `PWM` | **`GPIO 21`** | 50 Hz 14-bit LEDC PWM with auto-detach |
| **OLED Display** | $128 \times 64$ I2C OLED | `SCL` | **`GPIO 6`** | 400 kHz `esp_driver_i2c` Master Clock |
| **OLED Display** | $128 \times 64$ I2C OLED | `SDA` | **`GPIO 7`** | 400 kHz `esp_driver_i2c` Master Data |
| **Status LED** | Onboard `WS2812B` | `DIN` | **`GPIO 48`** | RMT `espressif/led_strip` (bridge `RGB` pad on board) |
| **5V Power Gate** | Boost `EN` / MOSFET | `EN` | **`GPIO 4`** *(optional)* | Cuts 5V idle draw during Deep Sleep |

---

## Quick Start & Flashing

### Option 1 — Download Pre-Built Firmware & Android APK from GitHub Actions
Every push to `main` automatically compiles both the **ESP-IDF `v6.1` firmware** and the **Flutter Android Companion APK**.
1. Download **`esp32s3-trash-bin-firmware.zip`** and **`waste-companion-apk.zip`** from the latest **[GitHub Actions run](https://github.com/ASCENDINGHeat/esp-trash-bin/actions)**.
2. Flash **`esp_trash_bin_merged.bin`** at address **`0x0`** using:
   - **Browser**: [Espressif ESPTool-JS Web Flasher](https://espressif.github.io/esptool-js/)
   - **Android (USB-C OTG)**: **ZFlasher AVR/ESP** or **ESPLoader** (`ESP32-S3`, offset `0x0`)
   - **CLI (`esptool.py`)**:
     ```bash
     esptool.py --chip esp32s3 --port /dev/ttyACM0 --baud 460800 write_flash 0x0 esp_trash_bin_merged.bin
     ```

### Option 2 — Build Firmware & Companion App Locally
```bash
# 1. Build & flash ESP32-S3 firmware (ESP-IDF v6.1):
idf.py set-target esp32s3
idf.py build
idf.py -p /dev/ttyACM0 flash monitor

# 2. Build W.A.S.T.E. Flutter Companion APK:
cd companion_app
flutter pub get
flutter build apk --release
```

### Converting Any Custom GIF for the OLED Screen
```bash
# Node.js converter (Atkinson 1-bit dithering, 128x64 SSD1306 page format):
node tools/gif_to_oled.mjs path/to/animation.gif main/dancing_cat_frames.h

# Or Python Pillow converter:
python3 tools/gif_to_oled.py path/to/animation.gif -o main/dancing_cat_frames.h --dither
```

---

## Complete Documentation (`docs/`)

All engineering specifications, state machines, protocols, and power analyses are organized in [`docs/`](./docs/README.md):

| Document | Topic |
| :--- | :--- |
| **[docs/README.md](./docs/README.md)** | Master Documentation Index & Quick Reference |
| **[docs/01-hardware-and-pinout.md](./docs/01-hardware-and-pinout.md)** | `YD-ESP32-23` (`N16R8`) Architecture, Solder Jumpers, Reserved Octal PSRAM Pins & Wiring |
| **[docs/02-functional-specification.md](./docs/02-functional-specification.md)** | Dual-Core Partitioning, W.A.S.T.E. State Machine, Ultrasonic Math & `Core 1` OLED Engine |
| **[docs/03-connectivity-ble-and-mqtt.md](./docs/03-connectivity-ble-and-mqtt.md)** | NimBLE GATT Provisioning/Failover, Live BLE Telemetry, MQTT Topics & Remote Commands |
| **[docs/04-power-management-and-battery.md](./docs/04-power-management-and-battery.md)** | 1000 mAh Battery Runtime Analysis ($5.5\text{ hrs} \rightarrow 22\text{ days}$), Sleep Modes & Flash Endurance |
| **[docs/05-esp-idf-v6.1-guide.md](./docs/05-esp-idf-v6.1-guide.md)** | ESP-IDF `v6.1` Modular Drivers, Managed Components, CI/CD & Flashing Guide |
| **[docs/06-flutter-companion-app.md](./docs/06-flutter-companion-app.md)** | W.A.S.T.E. Flutter Companion App Architecture, Dual MQTT/BLE Transport & APK Build Guide |
