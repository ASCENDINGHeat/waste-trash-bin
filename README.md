# ESP32-S3 Smart Trash Bin (`ESP-IDF ^6.1`)

Smart trash bin firmware and independent OLED animation engine targeting the **`YD-ESP32-23` (`ESP32-S3-WROOM-1-N16R8`)** development board using **ESP-IDF `^6.1`**.

## Key Features
- **Motion-Triggered Lid (`HC-SR501` $\rightarrow$ `SG90`)**: Fast lid open on motion (`GPIO 2`), soft-close ramp (`GPIO 21`), PWM auto-detach, and PIR anti-retrigger blanking.
- **Event + Periodic Ultrasonic Fill Level (`HC-SR04`)**: 5-sample median-filtered distance measurement (`TRIG = GPIO 5`, `ECHO = GPIO 18`) triggered after every lid close and periodically while closed ($10\text{ cm} = 100\%$, $30\text{ cm} = 0\%$).
- **BLE Setup & Wi-Fi Failover (`NimBLE`)**: Initial provisioning and automatic failover when Wi-Fi drops, plus live BLE GATT telemetry readout.
- **MQTT Telemetry (`esp-mqtt`)**: Real-time fill level, alerts, offline Octal PSRAM ring buffering, and remote commands.
- **Independent OLED Display (`Core 1`)**: Dedicated $128 \times 64$ I2C OLED (`SCL = GPIO 7`, `SDA = GPIO 6`) rendering the Chinese Dancing Cat GIF from 8 MB Octal PSRAM.

## Documentation (`docs/`)
All hardware, functional, connectivity, battery power, and ESP-IDF `^6.1` references are organized in [`docs/`](./docs/README.md):
- [docs/README.md](./docs/README.md) — Documentation Index
- [docs/01-hardware-and-pinout.md](./docs/01-hardware-and-pinout.md) — `YD-ESP32-23` (`N16R8`) Hardware, Jumpers & Pinout
- [docs/02-functional-specification.md](./docs/02-functional-specification.md) — Dual-Core Architecture, Trash Bin FSM & OLED GIF Engine
- [docs/03-connectivity-ble-and-mqtt.md](./docs/03-connectivity-ble-and-mqtt.md) — BLE Provisioning/Failover & MQTT Telemetry Schema
- [docs/04-power-management-and-battery.md](./docs/04-power-management-and-battery.md) — Battery Power Management & 1000 mAh Runtime Analysis
- [docs/05-esp-idf-v6.1-guide.md](./docs/05-esp-idf-v6.1-guide.md) — ESP-IDF `^6.1` Build System, Modular Drivers & Git Guide

## Build & Flash (`ESP-IDF ^6.1`)
```bash
idf.py set-target esp32s3
idf.py build
idf.py -p /dev/ttyACM0 flash monitor
```
