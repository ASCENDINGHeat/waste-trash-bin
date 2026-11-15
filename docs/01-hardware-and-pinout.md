# 01 — W.A.S.T.E. Hardware & Pinout Reference (`YD-ESP32-23` / `ESP32-S3 N16R8`)

> [!NOTE]
> Hardware architecture and pin assignment reference for **W.A.S.T.E.** (**Waste Automation and Sensing Technology Engine**).

## 1. MCU & Development Board Overview
- **Board Model / Silkscreen**: `YD-ESP32-23` (VCC-GND Studio `YD-ESP32-S3` clone, 44-pin `ESP32-S3-DevKitC-1` form factor)
- **Reference Repositories**:
  - [`rtek1000/YD-ESP32-23`](https://github.com/rtek1000/YD-ESP32-23) — Pinout diagrams, `YD-ESP32-S3-SCH-V1.4.pdf` schematic, solder jumper notes, and hardware errata.
  - [`vcc-gnd/YD-ESP32-S3`](https://github.com/vcc-gnd/YD-ESP32-S3) — Manufacturer documentation and hardware specifications.
- **SoC & Module**: `ESP32-S3-WROOM-1-N16R8`
  - **CPU**: Dual-core 32-bit Xtensa LX7 @ up to 240 MHz + ULP Coprocessor (RISC-V / FSM)
  - **Internal Memory**: 384 KB ROM, 512 KB SRAM, 16 KB RTC SRAM
  - **External Flash (`N16`)**: **16 MB Quad SPI Flash** (3.3 V, 80 MHz QIO)
  - **External PSRAM (`R8`)**: **8 MB Octal SPI PSRAM** (3.3 V `AP_3v3`, 80 MHz DDR)
  - **Radio**: 2.4 GHz Wi-Fi (802.11b/g/n) + Bluetooth 5 (LE / NimBLE)

---

## 2. Board Connectors, Buttons & Solder Jumpers

### 2.1 Dual USB Type-C Ports
1. **`COM` / `UART` Port**: Connected to onboard **WCH CH343P** USB-to-UART bridge (`U0TXD = GPIO 43`, `U0RXD = GPIO 44`) with auto-download (`DTR`/`RTS`) circuitry.
2. **`USB` Port**: Connected directly to ESP32-S3 native USB Serial/JTAG & USB-OTG PHY (`D- = GPIO 19`, `D+ = GPIO 20`).

### 2.2 Onboard Solder Jumpers (Open by Default on Most Boards)
- **`RGB` Jumper**: Connects `GPIO 48` to the onboard **WS2812B Addressable RGB LED**. Must be bridged with a solder blob if the onboard RGB LED does not light up out of the box.
- **`IN-OUT` Jumper**: Bypasses the blocking diode between USB `VBUS` (5V) and the `5V` (`5VIN`) header pin.
  - When open, USB 5V does not feed the `5V` header pin (or may read low/3.3V on some clone revisions). Bridge `IN-OUT` to power 5V sensors from USB, or use a dedicated 5V rail with common `GND`.
- **`USB-OTG` Jumper**: Connects the 5V `VBUS` rails of both Type-C ports together when using the native `USB` port in OTG Host mode.

### 2.3 Reserved & Restricted Pins on `ESP32-S3 N16R8`
| GPIO Range | Status | Function / Restriction |
| :--- | :--- | :--- |
| `GPIO 26 – 32` | **DO NOT USE** | Internal SPI Flash & PSRAM signals (not broken out) |
| `GPIO 33 – 37` | **DO NOT USE** | **Reserved for 8 MB Octal SPI PSRAM (`R8`)**. Even though `GPIO 35`, `36`, and `37` are exposed on the pin headers, touching them will crash Octal PSRAM! |
| `GPIO 19, 20` | **Reserved** | Native USB `D-` (`19`) and `D+` (`20`) |
| `GPIO 43, 44` | **Reserved** | UART0 Console / CH343P (`TX = 43`, `RX = 44`) |
| `GPIO 0, 3, 45, 46` | **Strapping** | `GPIO 0` (BOOT button), `GPIO 3` (JTAG), `GPIO 45` (`VDD_SPI` voltage—must stay LOW at boot for 3.3V Octal PSRAM), `GPIO 46` (ROM log/boot) |
| `GPIO 48` | **Onboard RGB** | WS2812B NeoPixel RGB LED (via `RGB` solder jumper) |

---

## 3. Peripheral Pinout Assignment

> [!IMPORTANT]
> **Sensor Part Name Clarification (`HC-SR501` vs `HC-SR04`)**:
> In the initial prompt, the part numbers were written as `HC-SR04(out -> gpio 2), HC-SR501(trig -> gpio 5, echo -> gpio 18)`.
> Physically:
> - **`HC-SR501`** is the 3-pin **PIR Motion Sensor** (`VCC`, `OUT`, `GND` $\rightarrow$ `OUT` on **`GPIO 2`**).
> - **`HC-SR04`** is the 4-pin **Ultrasonic Distance Sensor** (`VCC`, `TRIG`, `ECHO`, `GND` $\rightarrow$ `TRIG` on **`GPIO 5`**, `ECHO` on **`GPIO 18`**).

| Peripheral | Role | Pin Label | ESP32-S3 Pin | Signal Type | ESP-IDF `^6.1` Driver Component |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **PIR Sensor (`HC-SR501`)** | Motion Trigger | `OUT` | **`GPIO 2`** (`RTC_GPIO2`) | Digital Input (3.3V HIGH on motion) | `esp_driver_gpio` (+ `esp_sleep` `ext0`) |
| **Ultrasonic (`HC-SR04`)** | Trash Level Trigger | `TRIG` | **`GPIO 5`** | Digital Output ($10\text{ }\mu\text{s}$ pulse) | `esp_driver_gpio` / `esp_driver_rmt` |
| **Ultrasonic (`HC-SR04`)** | Trash Level Echo | `ECHO` | **`GPIO 18`** | Digital Input (Pulse width) | `esp_driver_gpio` + `esp_timer` / `esp_driver_rmt` |
| **Micro Servo (`SG90`)** | Lid Actuator | `PWM` | **`GPIO 21`** | 50 Hz PWM Output ($500\text{–}2500\text{ }\mu\text{s}$) | `esp_driver_ledc` |
| **I2C OLED (`SSD1306`)** | Dancing Cat GIF | `SCL` | **`GPIO 6`** | I2C Master Clock (400 kHz) | `esp_driver_i2c` (`driver/i2c_master.h`) |
| **I2C OLED (`SSD1306`)** | Dancing Cat GIF | `SDA` | **`GPIO 7`** | I2C Master Data (400 kHz) | `esp_driver_i2c` (`driver/i2c_master.h`) |
| **Onboard RGB (`WS2812B`)** | Bin & BLE Status | `DIN` | **`GPIO 48`** | RMT Addressable LED | `esp_driver_rmt` + `espressif/led_strip` |
| **5V Rail Gate (Optional)** | Battery Saver | `EN` | **`GPIO 4`** *(optional)* | Digital Output (HIGH = 5V ON) | `esp_driver_gpio` |

---

## 4. Electrical & Wiring Best Practices
1. **`HC-SR04` `ECHO` (`GPIO 18`) 5V Level Shifting**:
   - Standard 5V `HC-SR04` modules output $5\text{ V}$ on `ECHO`. Because ESP32-S3 GPIOs are $3.3\text{ V}$ only, place a simple resistor voltage divider ($1\text{ k}\Omega$ series from `ECHO` to `GPIO 18`, and $2\text{ k}\Omega$ from `GPIO 18` to `GND`) or use a $3.3\text{ V}$-compatible `HC-SR04P` / `RCWL-1601`.
2. **Servo 5V Decoupling (`SG90` on `GPIO 21`)**:
   - Place a **$470\text{ }\mu\text{F}\text{–}1000\text{ }\mu\text{F}$ electrolytic capacitor** across `5V` and `GND` near the `SG90` connector to prevent servo startup current spikes ($400\text{–}650\text{ mA}$) from dipping the 5V rail and false-triggering the `HC-SR501` PIR sensor or resetting the MCU.
3. **I2C Pull-Ups (`GPIO 6` & `GPIO 7`)**:
   - Enable internal pull-ups (`flags.enable_internal_pullup = true` in `i2c_master_bus_config_t`); most breakout OLED modules also include onboard $4.7\text{ k}\Omega$ pull-up resistors to `3V3`.
