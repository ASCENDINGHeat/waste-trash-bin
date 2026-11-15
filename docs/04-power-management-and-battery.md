# 04 — W.A.S.T.E. Battery Power Management, 1000 mAh Runtime & Flash Endurance

> [!NOTE]
> Power consumption analysis, sleep architecture, and 16 MB NOR Flash wear-leveling endurance reference for **W.A.S.T.E.** (**Waste Automation and Sensing Technology Engine**).

---

## 1. Per-Component Current Consumption Breakdown

| Component | Active Current | Optimized Idle / Sleep Current | Key Power Behavior |
| :--- | :--- | :--- | :--- |
| **`ESP32-S3-WROOM-1-N16R8`** | $95\text{–}130\text{ mA}$ (240 MHz + Wi-Fi TX/RX) | **$14\text{–}18\text{ mA}$** (Modem + Light Sleep)<br>**$0.25\text{ mA}$** (Deep Sleep) | Dominant continuous load if Wi-Fi power save (`WIFI_PS_MAX_MODEM`) is not enabled |
| **`YD-ESP32-23` Board Circuitry** | $5\text{–}8\text{ mA}$ | $3\text{–}6\text{ mA}$ | Quiescent draw of onboard LDO, `CH343P` USB-UART, and power indicator LED |
| **I2C OLED ($128\times 64$)** | $12\text{–}18\text{ mA}$ (Playing GIF) | **$< 0.01\text{ mA}$** (`0xAE` Display Off) | Current scales with number of lit pixels; `0xAE` disables internal charge pump |
| **`SG90` Micro Servo (5V)** | $220\text{–}650\text{ mA}$ (moving) | **$0.5\text{–}1.5\text{ mA}$** (PWM detached)<br>$15\text{–}40\text{ mA}$ (PWM active!) | `ledc_stop()` detaches PWM after lid closes so servo does not hum against mechanical stop |
| **`HC-SR04` Ultrasonic (5V)** | $15\text{ mA}$ (during 5x pings) | $2.0\text{ mA}$ (idle) / **$0\text{ mA}$** (5V gated) | 5 pings take $< 300\text{ ms}$ total per measurement cycle |
| **`HC-SR501` PIR Sensor** | $0.06\text{ mA}$ ($60\text{ }\mu\text{A}$) | **$0.05\text{ mA}$ ($50\text{ }\mu\text{A}$)** | Ultra-low power; stays powered continuously to detect hand motion |
| **Onboard `WS2812B` RGB LED** | $5\text{–}15\text{ mA}$ | **$\sim 0.8\text{ mA}$** (off quiescent) | Automatically turns off 5 seconds after lid closure |

---

## 2. How Long Can a **1000 mAh** Battery Last?

Calculations below assume a **1000 mAh 3.7V LiPo / 18650 cell** ($3.7\text{ Wh}$, yielding $\approx 800\text{ mAh}$ effective capacity after $85\%$ DC-DC conversion efficiency), **20 lid opens per day**, and **periodic ultrasonic level checks every 15 minutes**:

| Power Profile | Description | Avg Battery Current | **1000 mAh** Runtime |
| :--- | :--- | :--- | :--- |
| **Profile 1: Naive Always-On**<br>*(USB / Wall Power Mode)* | 240 MHz fixed clock, Wi-Fi `WIFI_PS_NONE`, OLED playing GIF 24/7, RGB LED continuously lit, Servo PWM left active. | $\sim 145\text{–}175\text{ mA}$ | **$\approx 5.5\text{ to }7\text{ hours}$** |
| **Profile 2: Smart Active Mode**<br>*(Firmware-Only, Always Online)* | ESP-IDF DFS ($240 \leftrightarrow 40\text{ MHz}$) + `WIFI_PS_MAX_MODEM`, Servo PWM detached when closed, OLED plays GIF for $60\text{ s}$ on motion then enters `0xAE` sleep. | $\sim 20\text{–}26\text{ mA}$ | **$\approx 38\text{ to }50\text{ hours}$**<br>*(~1.5 to 2 days)* |
| **Profile 3: Event-Driven Deep Sleep**<br>*(Firmware-Only, RTC Wakeup)* | ESP32-S3 enters Deep Sleep; wakes instantly on `GPIO 2` (`RTC_GPIO2`) motion or 15-min RTC timer to actuate lid, play OLED GIF, measure ultrasonic, publish MQTT, and sleep. | $\sim 5.5\text{–}7.5\text{ mA}$<br>*(limited by `HC-SR04` 2mA idle + board LDO)* | **$\approx 5.5\text{ to }7.5\text{ days}$** |
| **Profile 4: Deep Sleep + 5V Rail Gating**<br>*(Firmware + 5V Enable Switch)* | Profile 3 + a GPIO-controlled 5V boost `EN` pin (`GPIO 4`) that completely powers off `SG90` and `HC-SR04` during sleep, leaving only `HC-SR501` ($50\text{ }\mu\text{A}$) active. | $\sim 1.8\text{–}3.0\text{ mA}$ | **$\approx 14\text{ to }22\text{ days}$** |

---

## 3. Onboard 16 MB NOR Flash Endurance vs. External SD Card

Because the `YD-ESP32-23` (`N16R8`) includes **16 MB of onboard QSPI NOR Flash** (rated at **$100\,000$ Program/Erase cycles per $4\text{ KB}$ sector**) and **8 MB of Octal PSRAM** (unlimited write endurance), an external MicroSD card is unnecessary and saves $1\text{–}5\text{ mA}$ of idle battery drain.

For an **$8\text{ MB}$ wear-leveled log partition** ($2\,048\text{ sectors} \times 100\,000\text{ cycles} = \mathbf{204.8\text{ million sector erases}}$) storing $128\text{-byte}$ telemetry records:

| Telemetry Intensity | Rate | Logs / Day | Worst-Case Lifespan<br>*(1 sector erase per log)* | Realistic `LittleFS`/`SPIFFS` Lifespan<br>*(~12 logs per sector erase)* |
| :--- | :--- | :--- | :--- | :--- |
| **Normal Home Bin**<br>*(20 opens/day + 15-min timer)* | ~5 / hr | $116\text{ / day}$ | **$\approx 4\,837\text{ years}$** | **$> 50\,000\text{ years}$** |
| **Heavy Public / Mall Bin**<br>*(500 opens/day + 1-min timer)* | ~80 / hr | $1\,940\text{ / day}$ | **$\approx 289\text{ years}$** | **$\approx 3\,470\text{ years}$** |
| **Extreme High-Rate Polling**<br>*(1 log every **5 seconds** 24/7)* | $720\text{ / hr}$ | $17\,280\text{ / day}$ | **$\approx 32.5\text{ years}$** | **$\approx 390\text{ years}$** |
| **Continuous 1 Hz Flood**<br>*(1 log **every 1 second** 24/7)* | $3\,600\text{ / hr}$ | $86\,400\text{ / day}$ | **$\approx 6.5\text{ years}$** | **$\approx 78\text{ years}$** *(or **$>200\text{ yrs}$** with PSRAM batching)* |
