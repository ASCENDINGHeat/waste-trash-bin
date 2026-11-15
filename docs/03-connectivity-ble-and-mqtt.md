# 03 — W.A.S.T.E. Connectivity: BLE Setup/Failover & MQTT Protocol

## 1. Network Lifecycle & Automatic BLE Failover

**W.A.S.T.E.** (**Waste Automation and Sensing Technology Engine**) uses a unified **Network Manager** that coordinates **Wi-Fi STA**, **NimBLE (Bluetooth Low Energy)**, and **MQTT (`esp-mqtt`)**:

```mermaid
stateDiagram-v2
    [*] --> CHECK_NVS
    CHECK_NVS --> BLE_PROVISIONING : No saved Wi-Fi SSID in NVS
    CHECK_NVS --> WIFI_CONNECTING : Saved credentials found
    WIFI_CONNECTING --> WIFI_ONLINE : IP_EVENT_STA_GOT_IP
    WIFI_CONNECTING --> BLE_FAILOVER : Failed after 5 retries
    WIFI_ONLINE --> MQTT_CONNECTED : MQTT Broker Connected (Flush PSRAM Buffer)
    WIFI_ONLINE --> BLE_FAILOVER : Wi-Fi lost for > 30s
    BLE_PROVISIONING --> WIFI_CONNECTING : New credentials written via BLE GATT
    BLE_FAILOVER --> WIFI_CONNECTING : New BLE credentials OR 60s background retry
    MQTT_CONNECTED --> WIFI_ONLINE : Broker disconnected (auto-reconnect)
```

---

## 2. Bluetooth Low Energy (`NimBLE`) Specification

### 2.1 Why `NimBLE` on ESP-IDF `^6.1`
- Uses $< 50\%$ of the RAM required by Bluedroid and integrates cleanly with ESP32-S3 Octal PSRAM (`CONFIG_BT_NIMBLE_ENABLED=y`).
- Active in two scenarios:
  1. **Initial Setup**: First boot when NVS (`net_cfg` namespace) has no Wi-Fi credentials.
  2. **Wi-Fi Failover**: Automatically starts advertising (`SmartBin-S3-XXXX`) whenever Wi-Fi fails to connect after 5 attempts or stays disconnected for $> 30\text{ seconds}$.

### 2.2 BLE GATT Custom Service (`UUID: 0xFF00` / 128-bit UUID)
Provides both **Configuration (Provisioning)** and **Live Offline Telemetry**:

| Characteristic | UUID Offset | Properties | Format / Purpose |
| :--- | :--- | :--- | :--- |
| **Wi-Fi SSID** | `0xFF01` | `Read`, `Write` | UTF-8 string (max 32 bytes) — stored in NVS |
| **Wi-Fi Password** | `0xFF02` | `Write` | UTF-8 string (max 64 bytes) — stored in NVS |
| **MQTT Broker URI** | `0xFF03` | `Read`, `Write` | UTF-8 string (e.g. `mqtt://192.168.1.10:1883`) — stored in NVS |
| **Apply & Connect** | `0xFF04` | `Write` | Write `0x01` to save to NVS and trigger immediate Wi-Fi connection attempt |
| **Live Bin Telemetry** | `0xFF05` | `Read`, `Notify` | JSON (`fill_percent`, `distance_cm`, `lid_state`, `open_cycles`) so the user's phone can monitor the trash bin over BLE even when Wi-Fi is down! |
| **Remote Command JSON** | `0xFF06` | `Write` | Accepts the same JSON command payloads as `smartbin/<id>/cmd` (`open_lid`, `measure_now`, `configure`) directly over BLE! |

---

## 3. MQTT Telemetry Protocol (`esp-mqtt`)

### 3.1 Topic Hierarchy
Using `<device_id>` derived from the ESP32-S3 factory MAC address (e.g., `smartbin_s3_a1b2c3`):

| Topic | Direction | QoS | Retain | Description |
| :--- | :--- | :--- | :--- | :--- |
| `smartbin/<device_id>/telemetry` | Publish | `1` | `false` | Published after every lid close measurement and every periodic ultrasonic check |
| `smartbin/<device_id>/alert` | Publish | `1` | `true` | Published when `fill_percent >= 95%` (cleared when emptied `< 20%`) |
| `smartbin/<device_id>/status` | Publish / LWT | `1` | `true` | `"online"` on connect; Last Will & Testament (LWT) `"offline"` on unexpected drop |
| `smartbin/<device_id>/cmd` | Subscribe | `1` | `false` | Remote JSON commands (open lid, measure now, calibrate, set periodic interval) |

### 3.2 Telemetry JSON Payload (`smartbin/<device_id>/telemetry`)
Built using the `espressif/cjson` managed component:
```json
{
  "device_id": "smartbin_s3_a1b2c3",
  "trigger": "lid_close",
  "fill_percent": 75,
  "distance_cm": 15.0,
  "full_alert": false,
  "lid_state": "closed",
  "open_cycles": 42,
  "wifi_rssi": -58,
  "uptime_s": 3600
}
```
- `"trigger"` values: `"lid_close"`, `"periodic"`, `"remote_cmd"`, or `"boot"`.

### 3.3 Remote Command JSON Payloads (`smartbin/<device_id>/cmd`)
- **Trigger immediate ultrasonic measurement**:
  ```json
  {"cmd": "measure_now"}
  ```
- **Remote lid open**:
  ```json
  {"cmd": "open_lid", "hold_s": 5}
  ```
- **Update calibration or periodic timer interval (persisted to NVS)**:
  ```json
  {
    "cmd": "configure",
    "full_cm": 10.0,
    "empty_cm": 30.0,
    "periodic_interval_s": 900,
    "oled_mode": "always_on"
  }
  ```

---

## 4. Offline Telemetry Ring Buffer (PSRAM)
- When Wi-Fi or the MQTT broker is unreachable during a lid-close event or periodic check:
  1. `open_cycles` is incremented and committed to `NVS` (`nvs_flash`).
  2. Up to **256 telemetry records** are queued in a ring buffer allocated in the **8 MB Octal PSRAM**.
  3. As soon as `MQTT_EVENT_CONNECTED` fires, queued records are published in chronological order before normal operation resumes.


---

## 5. Connecting to Flespi MQTT Broker (`mqtt.flespi.io`)

**Flespi** provides a fast, free cloud MQTT 3.1.1 / 5.0 broker (`mqtt.flespi.io`) with a built-in web MQTT Board for inspecting topics in real time.

### Step 1 — Get Your Flespi Token
1. Sign in at **[flespi.io](https://flespi.io/)** (GitHub / Google login supported).
2. In the left sidebar, go to **Access Control → Tokens**.
3. Copy your **Master Token** (or click **`+`** to create a Standard Token).
   - It is a 64-character string (e.g., `a1B2c3D4e5F6...`).
   - Do **not** include the `FlespiToken ` prefix when embedding it in an `mqtt://` URI (or if you paste it into the W.A.S.T.E. Companion App's **Flespi Token** box, the app automatically strips any `FlespiToken ` prefix for you).

### Step 2 — Format the Flespi Broker URI
Flespi authenticates using your token as the **MQTT Username** (with an empty password). Both the **ESP32-S3 (`esp-mqtt`)** and the **W.A.S.T.E. Flutter Companion App** natively support embedding the token directly in the URI:

```text
mqtt://<YOUR_FLESPI_TOKEN>@mqtt.flespi.io:1883
```

### Step 3 — Provision the ESP32-S3 & Connect the Companion App

#### Option A: Via the W.A.S.T.E. Flutter Companion App (No Re-flashing Needed)
1. Power on the `YD-ESP32-23` (`ESP32-S3`). If Wi-Fi is not yet configured, the onboard RGB LED (`GPIO 48`) glows **Blue** and advertises **`smartbin_s3_xxxxxx`** over BLE.
2. Open the **W.A.S.T.E. Companion App** and tap the **Antenna icon (`Connectivity & BLE Provisioning`)** in the top-right corner.
3. Under **1. MQTT Broker**:
   - Tap **`Flespi Preset`** (sets `mqtt://mqtt.flespi.io:1883`).
   - Paste your 64-character token into **`Flespi Token / MQTT Username`**.
   - Tap **`Connect MQTT`** — the phone app automatically builds `mqtt://<TOKEN>@mqtt.flespi.io:1883` and connects using MQTT 3.1.1.
4. Under **2. Direct BLE GATT (`0xFF00`)**:
   - Tap **`Scan BLE`** and tap **`Connect`** next to `smartbin_s3_xxxxxx`.
5. Under **3. Provision ESP32-S3 NVS over BLE**:
   - Enter your **2.4 GHz Wi-Fi SSID** and **Password**.
   - Tap **`Write to ESP32-S3 NVS & Connect Wi-Fi`** — this writes your Wi-Fi credentials (`0xFF01`/`0xFF02`) and the full Flespi token URI (`0xFF03`) into the ESP32-S3's NVS flash and triggers immediate connection (`0xFF04`).

#### Option B: Compile Default into Firmware (`idf.py menuconfig`)
If building locally, you can also set the default broker URI in **`Kconfig.projbuild`**:
```text
idf.py menuconfig
  -> W.A.S.T.E. Smart Trash Bin Configuration (ESP32-S3 N16R8)
  -> Default MQTT Broker URI: mqtt://<YOUR_FLESPI_TOKEN>@mqtt.flespi.io:1883
```

### Step 4 — Verify Live Telemetry in Flespi's Web Dashboard
1. In your browser, open **[MQTT Board (flespi.io)](https://flespi.io/mqtt-board)** (or click **MQTT → MQTT Board** inside the Flespi panel).
2. Add a **Subscriber** with topic filter:
   ```text
   smartbin/#
   ```
3. You will immediately see:
   - `smartbin/smartbin_s3_xxxxxx/status` $\rightarrow$ `"online"` (retained)
   - `smartbin/smartbin_s3_xxxxxx/telemetry` $\rightarrow$ Live JSON after every lid closure or 15-minute periodic ultrasonic ping.
4. To test remote commands directly from Flespi's **Publisher** tab, publish to `smartbin/smartbin_s3_xxxxxx/cmd`:
   - Open lid for 5 seconds: `{"cmd":"open_lid","hold_s":5}`
   - Trigger ultrasonic measurement: `{"cmd":"measure_now"}`


---

## 6. Future Roadmap: Tri-Mode Connectivity (`BLE + LAN + MQTT`)

To support high-bandwidth local transfers (such as user-uploadable OLED animations) alongside cloud telemetry and offline resilience, **W.A.S.T.E.** is designed to evolve into a **Tri-Mode Transport Architecture**:

```mermaid
flowchart TD
    APP["W.A.S.T.E. Flutter Companion App"]

    subgraph Transports["Tri-Mode Automatic Transport Router"]
        LAN["1. Local LAN (HTTP REST + WebSocket + mDNS) - Fast GIF Upload and Local Control"]
        MQTT["2. Cloud MQTT (Flespi Broker) - Remote Access Anywhere (4G / 5G / WAN)"]
        BLE["3. Direct BLE GATT (Service 0xFF00) - Setup, Offline Failover and Direct Transfer"]
    end

    MCU["ESP32-S3 N16R8 (W.A.S.T.E. Firmware)"]

    APP <-->|"Priority 1 (Same Wi-Fi)"| LAN
    APP <-->|"Priority 2 (Remote / WAN)"| MQTT
    APP <-->|"Priority 3 (No Wi-Fi / Direct)"| BLE

    LAN <--> MCU
    MQTT <--> MCU
    BLE <--> MCU
```

### Transport Role Comparison

| Transport | Bandwidth / Latency | Primary Use Cases |
| :--- | :--- | :--- |
| **LAN (`esp_http_server` + `mDNS`)** | $\sim 500\text{ KB/s}$ (`< 10 ms` latency) | Instant `85 KB` custom GIF/animation uploads (`POST /api/oled/upload` in `< 0.3s`), local dashboard streaming without internet |
| **MQTT (`esp-mqtt` / Flespi)** | $\sim 10\text{ KB/s}$ (`50–150 ms` latency) | Remote monitoring over cellular (`4G/5G`), retained full-bin alerts, cloud history, remote commands |
| **BLE GATT (`NimBLE` `0xFF00`)** | $\sim 15\text{–}25\text{ KB/s}$ (`247B` MTU) | Initial Wi-Fi/MQTT NVS provisioning, offline failover telemetry, and routerless chunked `.wbin` animation upload (`~5s`) |
