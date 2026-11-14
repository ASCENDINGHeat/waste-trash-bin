# 04 — Battery Power Management & 1000 mAh Runtime Reference

## 1. Per-Component Current Consumption Breakdown

| Component | Active Current | Optimized Idle / Sleep Current | Key Power Behavior |
| :--- | :--- | :--- | :--- |
| **`ESP32-S3-WROOM-1-N16R8`** | $95\text{–}130\text{ mA}$ (240 MHz + Wi-Fi TX/RX) | **$14\text{–}18\text{ mA}$** (Modem + Light Sleep)<br>**$0.25\text{ mA}$** (Deep Sleep) | Dominant continuous load if Wi-Fi power save (`WIFI_PS_MAX_MODEM`) is not enabled |
| **`YD-ESP32-23` Board Circuitry** | $5\text{–}8\text{ mA}$ | $3\text{–}6\text{ mA}$ | Quiescent draw of onboard LDO, `CH343P` USB-UART, and power indicator LED |
| **I2C OLED ($128\times 64$)** | $12\text{–}18\text{ mA}$ (Dancing Cat GIF) | **$< 0.01\text{ mA}$** (`0xAE` Display Off) | Current scales with number of lit white/blue pixels; `0xAE` turns off charge pump |
| **`SG90` Micro Servo (5V)** | $220\text{–}650\text{ mA}$ (moving) | **$0.5\text{–}1.5\text{ mA}$** (PWM detached)<br>$15\text{–}40\text{ mA}$ (PWM active!) | Must call `ledc_stop()` after lid closes so servo does not hum against mechanical stop |
| **`HC-SR04` Ultrasonic (5V)** | $15\text{ mA}$ (during 5x pings) | $2.0\text{ mA}$ (idle) / **$0\text{ mA}$** (5V gated) | 5 pings take $< 300\text{ ms}$ total per cycle |
| **`HC-SR501` PIR Sensor** | $0.06\text{ mA}$ ($60\text{ }\mu\text{A}$) | **$0.05\text{ mA}$ ($50\text{ }\mu\text{A}$)** | Ultra-low power; stays powered continuously to detect hand motion |
| **Onboard `WS2812B` RGB LED** | $5\text{–}15\text{ mA}$ | **$\sim 0.8\text{ mA}$** (off quiescent) | Only light for $5\text{ s}$ after lid closes in battery mode |

---

## 2. How Long Can a **1000 mAh** Battery Last?

Calculations below assume a **1000 mAh 3.7V LiPo / 18650 cell** ($3.7\text{ Wh}$, yielding $\approx 800\text{ mAh}$ effective capacity after $85\%$ DC-DC conversion efficiency), **20 trash bin opens per day**, and **periodic ultrasonic level checks every 15 minutes**:

| Power Profile | Description | Avg Battery Current | **1000 mAh** Runtime |
| :--- | :--- | :--- | :--- |
| **Profile 1: Naive Always-On**<br>*(USB / Wall Power Mode)* | 240 MHz fixed clock, Wi-Fi `WIFI_PS_NONE`, OLED playing Dancing Cat GIF 24/7, RGB LED continuously lit, Servo PWM left active. | $\sim 145\text{–}175\text{ mA}$ | **$\approx 5.5\text{ to }7\text{ hours}$** |
| **Profile 2: Smart Active Mode**<br>*(Firmware-Only, Always Online)* | ESP-IDF DFS ($240 \leftrightarrow 40\text{ MHz}$) + `WIFI_PS_MAX_MODEM` + Auto Light Sleep, Servo PWM detached when closed, OLED plays Dancing Cat for $60\text{ s}$ on motion then enters `0xAE` sleep. | $\sim 20\text{–}26\text{ mA}$ | **$\approx 38\text{ to }50\text{ hours}$**<br>*(~1.5 to 2 days)* |
| **Profile 3: Event-Driven Deep Sleep**<br>*(Firmware-Only, RTC Wakeup)* | ESP32-S3 enters Deep Sleep; wakes instantly on `GPIO 2` (`RTC_GPIO2`) motion or 15-min RTC timer to actuate lid, play OLED GIF, measure ultrasonic, publish MQTT, and sleep. | $\sim 5.5\text{–}7.5\text{ mA}$<br>*(limited by `HC-SR04` 2mA idle + board LDO)* | **$\approx 5.5\text{ to }7.5\text{ days}$** |
| **Profile 4: Deep Sleep + 5V Rail Gating**<br>*(Firmware + 5V Enable Switch)* | Profile 3 + a GPIO-controlled 5V boost `EN` pin (or high-side MOSFET) that completely powers off `SG90` and `HC-SR04` during sleep, leaving only `HC-SR501` ($50\text{ }\mu\text{A}$) active. | $\sim 1.8\text{–}3.0\text{ mA}$ | **$\approx 14\text{ to }22\text{ days}$** |

---

## 3. Firmware Power Management Architecture

### 3.1 Dynamic Frequency Scaling (DFS) & Automatic Light Sleep
Configured via `esp_pm_configure()` in `esp_pm.h`:
- `max_freq_mhz = 240` (boosts immediately during OLED rendering, Wi-Fi TX/RX, and ultrasonic calculation)
- `min_freq_mhz = 40` (drops to 40 MHz XTAL clock when idle)
- `light_sleep_enable = true` (paired with `CONFIG_FREERTOS_USE_TICKLESS_IDLE=y`)
- Wi-Fi power saving set to `esp_wifi_set_ps(WIFI_PS_MAX_MODEM)`.

### 3.2 Deep Sleep Dual-Wakeup (`RTC_GPIO2` + Timer)
Because the `HC-SR501` PIR sensor is connected to **`GPIO 2`**, which is a valid RTC wakeup pin (`RTC_GPIO2`) on the ESP32-S3, the firmware supports a selectable Deep Sleep Battery mode:
1. **Motion Wakeup (`ext0`)**:
   ```c
   esp_sleep_enable_ext0_wakeup(GPIO_NUM_2, 1); // Wake on PIR HIGH
   rtc_gpio_pulldown_en(GPIO_NUM_2);
   rtc_gpio_pullup_dis(GPIO_NUM_2);
   ```
2. **Periodic Ultrasonic Timer Wakeup**:
   ```c
   esp_sleep_enable_timer_wakeup(15ULL * 60ULL * 1000000ULL); // 15 minutes in microseconds
   ```
3. **Wakeup Cause Dispatch (`esp_sleep_get_wakeup_cause()`)**:
   - `ESP_SLEEP_WAKEUP_EXT0`: Immediately start `Core 1` OLED Dancing Cat GIF + open `SG90` lid on `Core 0` $\rightarrow$ wait for motion end $\rightarrow$ soft-close $\rightarrow$ measure `HC-SR04` $\rightarrow$ publish MQTT $\rightarrow$ sleep after OLED timeout.
   - `ESP_SLEEP_WAKEUP_TIMER`: Keep lid closed $\rightarrow$ fire 5x `HC-SR04` pings $\rightarrow$ publish MQTT level update $\rightarrow$ immediately return to Deep Sleep ($< 3\text{ seconds}$ awake).

---

## 4. Hardware Recommendations for Battery Operation
1. **Use a 5V Boost Converter with an `EN` Pin (Gated by `GPIO 4`)**:
   - Connect `SG90` (`VCC`) and `HC-SR04` (`VCC`) to a switched 5V boost converter (`MT3608` / `FP6291` / load switch) controlled by `GPIO 4`.
   - Drive `GPIO 4` `HIGH` only when opening/closing the lid or firing the ultrasonic sensor, and `LOW` while idle/sleeping.
2. **Add a $470\text{–}1000\text{ }\mu\text{F}$ Bulk Capacitor Across 5V & GND**:
   - Prevents the `SG90` servo's $500\text{ mA}$ inrush current from sagging a 1000 mAh LiPo battery below the ESP32-S3 brownout threshold.
3. **Power `HC-SR501` via 3.3V Bypass (Optional)**:
   - The `HC-SR501` board internally drops `VCC` to $3.3\text{ V}$ through a diode and `HT7133` LDO. Feeding $3.3\text{ V}$ directly to the middle `H` jumper pad bypasses the diode drop and allows the PIR sensor to run directly off the $3.3\text{ V}$ rail with zero 5V boost overhead during sleep.
