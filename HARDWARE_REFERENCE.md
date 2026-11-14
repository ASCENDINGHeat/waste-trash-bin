# Hardware & Board Reference Documentation (`YD-ESP32-23` / `ESP32-S3 N16R8`)

> [!NOTE]
> Internal technical reference for the ESP-IDF project targeting the **VCC-GND Studio `YD-ESP32-S3` (`YD-ESP32-23` silkscreen clone) N16R8** development board and attached peripherals.

---

## 1. MCU & Development Board: `YD-ESP32-23` (`ESP32-S3 N16R8`)

### 1.1 Overview & GitHub Reference Repositories
- **Board Silkscreen / Model**: `YD-ESP32-23` (clone of VCC-GND Studio `YD-ESP32-S3`, layout compatible with Espressif `ESP32-S3-DevKitC-1`)
- **Reference Repositories**:
  - [`rtek1000/YD-ESP32-23`](https://github.com/rtek1000/YD-ESP32-23) — Pinout diagrams, schematic (`YD-ESP32-S3-SCH-V1.4.pdf`), jumper documentation, and board quirks.
  - [`vcc-gnd/YD-ESP32-S3`](https://github.com/vcc-gnd/YD-ESP32-S3) — Original manufacturer hardware specifications and schematics.
- **Module**: `ESP32-S3-WROOM-1-N16R8`
  - **CPU**: Dual-core 32-bit Xtensa LX7 @ up to 240 MHz + ULP Coprocessor (RISC-V / FSM)
  - **SRAM**: 512 KB internal SRAM + 16 KB RTC SRAM
  - **Flash (`N16`)**: **16 MB Quad SPI Flash** (3.3 V)
  - **PSRAM (`R8`)**: **8 MB Octal SPI PSRAM** (3.3 V, `AP_3v3`)
  - **Wireless**: 2.4 GHz Wi-Fi (802.11 b/g/n) + Bluetooth 5 (LE / Mesh)
  - **Peripherals**: 45 programmable GPIOs, 2x 12-bit SAR ADCs (20 channels), 2x I2C, 4x SPI, 3x UART, 8x LEDC PWM channels, 2x MCPWM units, 4x TX / 4x RX RMT channels, USB OTG 1.1, TWAI, I2S, LCD/Camera interface, 14x capacitive touch IOs.

### 1.2 Board-Specific Hardware Features & Solder Jumpers
1. **Dual USB Type-C Connectors**:
   - **`COM` / `UART` USB-C Port**: Connected to onboard **WCH CH343P** hardware USB-to-UART bridge (`U0TXD = GPIO 43`, `U0RXD = GPIO 44`) with auto-reset/bootloader circuit (`DTR`/`RTS`).
   - **`USB` Native USB-C Port**: Connected directly to ESP32-S3 internal USB Serial/JTAG & USB-OTG PHY (`D- = GPIO 19`, `D+ = GPIO 20`).
2. **Solder Jumper Pads**:
   - **`RGB` Jumper**: Connects `GPIO 48` to the onboard **WS2812B Addressable RGB LED** (requires RMT / `led_strip` protocol, *not* standard digital HIGH/LOW). Open by default on most `YD-ESP32-23` boards—must be bridged with solder to use the onboard RGB LED.
   - **`IN-OUT` Jumper**: Open by default. Isolates USB `VBUS` from the `5V` (`5VIN`) header pin via a protection diode.
     - **Important for 5V Peripherals**: When open, the `5V` header pin may not output USB 5V power (or on some clone batches may read ~3.3V or float). Either bridge the `IN-OUT` pad to route USB 5V to the `5V` pin, or power 5V devices (`HC-SR04`, `HC-SR501`, `SG90`) from a dedicated 5V rail with common `GND`.
   - **`USB-OTG` Jumper**: Open by default. Bridging ties the `VBUS` rails of both USB-C ports together for USB Host OTG power delivery.
3. **Onboard Buttons**:
   - `RST`: Hardware reset (`EN` / `CHIP_PU`).
   - `BOOT`: Tied to `GPIO 0` (active LOW). Can be used as a user button after boot.

### 1.3 Reserved & Restricted GPIOs on `ESP32-S3 N16R8`
| GPIO Range | Status | Reason |
| :--- | :--- | :--- |
| `GPIO 26 – 32` | **DO NOT USE** | Internal SPI Flash / PSRAM bus (not exposed) |
| `GPIO 33 – 37` | **DO NOT USE** | **Used by 8 MB Octal SPI PSRAM (`R8`)**. Although `GPIO 35`, `36`, `37` are broken out to header pins on the PCB, using them will crash or corrupt Octal PSRAM. |
| `GPIO 19, 20` | **Reserved (USB)** | Native USB `D-` (`GPIO 19`) and `D+` (`GPIO 20`) |
| `GPIO 43, 44` | **Reserved (UART0)** | Default console/programming UART via CH343P (`TX = 43`, `RX = 44`) |
| `GPIO 0, 3, 45, 46` | **Strapping Pins** | `GPIO 0` (Boot mode), `GPIO 3` (JTAG source), `GPIO 45` (`VDD_SPI` voltage—must remain LOW at boot for 3.3V Octal PSRAM), `GPIO 46` (Boot mode / ROM log) |
| `GPIO 48` | **Onboard RGB LED** | WS2812B RGB LED (when `RGB` jumper is bridged) |

---

## 2. Project Pinout & Peripheral Mapping

> [!IMPORTANT]
> **Note on Sensor Part Numbers (`HC-SR04` vs `HC-SR501`)**:
> In the user specification:
> - `HC-SR04(out -> gpio 2)`
> - `HC-SR501(trig -> gpio 5, echo -> gpio 18)`
>
> Physically, **HC-SR501** is a **PIR Motion Sensor** (single `OUT` digital pin), whereas **HC-SR04** is an **Ultrasonic Distance Sensor** (`TRIG` and `ECHO` pins). The pin numbers themselves are unambiguous and mapped below according to their signal function (`OUT` on `GPIO 2`, `TRIG` on `GPIO 5`, `ECHO` on `GPIO 18`).

| Peripheral | Function / Role | Signal Pin | ESP32-S3 GPIO | Direction | Electrical / Driver Notes |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **PIR Motion Sensor** (`HC-SR501`)* | Motion Detection | `OUT` | **`GPIO 2`** | Input | 3.3V logic output (HIGH = motion detected, LOW = idle). Safe for direct connection to `GPIO 2`. |
| **Ultrasonic Sensor** (`HC-SR04`)* | Distance Measurement | `TRIG` | **`GPIO 5`** | Output | Send $\ge 10\text{ }\mu\text{s}$ HIGH pulse to trigger measurement. |
| **Ultrasonic Sensor** (`HC-SR04`)* | Distance Measurement | `ECHO` | **`GPIO 18`** | Input | Pulse width output ($\text{cm} \approx \Delta t_{\mu\text{s}} / 58$). Use voltage divider ($5\text{V} \to 3.3\text{V}$) if powered by 5V. |
| **Micro Servo** (`SG90`) | Angular Actuator | `PWM` | **`GPIO 21`** | Output (PWM) | 50 Hz ($20\text{ ms}$ period), pulse width $500\text{ }\mu\text{s}$ ($0^\circ$) to $2500\text{ }\mu\text{s}$ ($180^\circ$). |
| **I2C OLED Display** (`SSD1306` / `SH1106`) | Visual Display | `SCL` | **`GPIO 7`** | I2C Clock | 3.3V logic, internal pull-up enabled (or external $4.7\text{ k}\Omega$), up to 400 kHz Fast Mode. |
| **I2C OLED Display** (`SSD1306` / `SH1106`) | Visual Display | `SDA` | **`GPIO 6`** | I2C Data | 3.3V logic, typical I2C address `0x3C` (or `0x3D`). |

*\*Part names corrected to match physical signal pins (`OUT` = PIR `HC-SR501`, `TRIG`/`ECHO` = Ultrasonic `HC-SR04`).*

### Pin Conflict Verification
All assigned GPIOs (`GPIO 2`, `GPIO 5`, `GPIO 6`, `GPIO 7`, `GPIO 18`, `GPIO 21`) have been verified against the `ESP32-S3-WROOM-1-N16R8` datasheet:
- None conflict with **Octal PSRAM / Flash** (`GPIO 26–37`).
- None conflict with **Strapping Pins** (`GPIO 0, 3, 45, 46`).
- None conflict with **Native USB** (`GPIO 19, 20`) or **UART0** (`GPIO 43, 44`).
- All reside on standard `VDD3P3_RTC` / `VDD3P3_CPU` 3.3V IO domains and support full GPIO Matrix routing.

---

## 3. Peripheral Implementation Reference (ESP-IDF)

### 3.1 PIR Sensor (`OUT -> GPIO 2`)
- **Pin Configuration**:
  - `GPIO_MODE_INPUT`, pull-down enabled (`GPIO_PULLDOWN_ONLY`) to prevent floating states if disconnected.
  - Can be read via `gpio_get_level(GPIO_NUM_2)` or edge-triggered interrupt (`GPIO_INTR_ANYEDGE`).

### 3.2 Ultrasonic Distance Sensor (`TRIG -> GPIO 5`, `ECHO -> GPIO 18`)
- **Trigger (`GPIO 5`)**: `GPIO_MODE_OUTPUT`, initial level `0`. Pulse HIGH for $10\text{ }\mu\text{s}$ via `esp_rom_delay_us(10)`.
- **Echo (`GPIO 18`)**: `GPIO_MODE_INPUT`.
  - Measure HIGH pulse duration $\Delta t$ (in $\mu\text{s}$) using `esp_timer_get_time()` (with timeout $\approx 25\text{–}30\text{ ms}$) or ESP-IDF **RMT RX** / **MCPWM Capture** peripheral for non-blocking hardware timestamping.
  - Formula:
    $$\text{Distance (cm)} = \frac{\Delta t_{\mu\text{s}} \times 0.0343}{2} \approx \frac{\Delta t_{\mu\text{s}}}{58.0}$$

### 3.3 SG90 Micro Servo (`PWM -> GPIO 21`)
- **Recommended Peripheral**: **LEDC PWM** (`driver/ledc.h`) or **MCPWM** (`driver/mcpwm_prelude.h`).
- **LEDC Parameters**:
  - Frequency: `50 Hz` ($20\,000\text{ }\mu\text{s}$ period)
  - Resolution: `LEDC_TIMER_14_BIT` ($16\,384$ ticks per $20\text{ ms} \implies \approx 1.22\text{ }\mu\text{s}$ resolution)
  - Pulse Mapping:
    - $0^\circ \to 500\text{ }\mu\text{s}$ ($\text{duty} \approx 410$)
    - $90^\circ \to 1500\text{ }\mu\text{s}$ ($\text{duty} \approx 1229$)
    - $180^\circ \to 2500\text{ }\mu\text{s}$ ($\text{duty} \approx 2048$)

### 3.4 I2C OLED Screen (`SCL -> GPIO 7`, `SDA -> GPIO 6`)
- **Recommended Peripheral**: Hardware I2C Controller `I2C_NUM_0` (`driver/i2c_master.h` in ESP-IDF v5.x or `esp_lcd_panel_ssd1306`).
- **Bus Parameters**:
  - `SCL = GPIO_NUM_7`, `SDA = GPIO_NUM_6`
  - Clock speed: `400000` Hz (400 kHz)
  - Default I2C 7-bit address: `0x3C`
  - Typical resolution: $128 \times 64$ monochrome (`SSD1306` or `SH1106`).

---

## 4. Recommended `sdkconfig.defaults` for `YD-ESP32-23` (`N16R8`)

```ini
CONFIG_IDF_TARGET="esp32s3"

# 16 MB Quad SPI Flash
CONFIG_ESPTOOLPY_FLASHSIZE_16MB=y
CONFIG_ESPTOOLPY_FLASHMODE_QIO=y
CONFIG_ESPTOOLPY_FLASHFREQ_80M=y

# 8 MB Octal SPI PSRAM
CONFIG_SPIRAM=y
CONFIG_SPIRAM_MODE_OCT=y
CONFIG_SPIRAM_SPEED_80M=y

# CPU & FreeRTOS
CONFIG_ESP_DEFAULT_CPU_FREQ_MHZ_240=y
CONFIG_FREERTOS_HZ=1000
```
