# 07 — W.A.S.T.E. Smart OLED HUD, Boot Animation & Warning Modal Specification (`Core 1`)

> [!NOTE]
> This document specifies the upgrade of the **Core 1** $128 \times 64$ I2C OLED engine (`SCL = GPIO 6`, `SDA = GPIO 7`) from a standalone GIF loop into a **Context-Aware Smart HUD (Heads-Up Display), Boot Splash Animator & Popup Warning Modal Compositor**.

---

## 1. Design Goals

While streaming the 85-frame **Hololive Risu / Dancing Cat** animation from the **8 MB Octal PSRAM** showcases the ESP32-S3's dual-core capability, a production smart receptacle screen should provide **immediate, actionable physical feedback** to anyone standing in front of the bin—without requiring them to open the mobile app or serial monitor:

1. **Animated Boot & Hardware Self-Test (`SCREEN_BOOT_SPLASH`)**: Greet the user at power-on with a smooth **W.A.S.T.E.** logo reveal, live subsystem checklist (`PSRAM`, `Sensors`, `BLE/Wi-Fi`), and node ID readout.
2. **At-a-Glance Fill & Connectivity HUD**: Always show current fill percentage (`0–100%`), ultrasonic headspace (`cm`), lid cycle counter, and network mode (`Wi-Fi/MQTT` vs `BLE Setup`).
3. **Event-Driven Screen Transitions**: Automatically switch from the idle mascot/HUD view to dedicated **Lid Open Countdown**, **Ultrasonic Scanning Progress**, **BLE Onboarding**, or **Full-Bin Alert** screens based on real-time FSM events.
4. **Centered Warning Popup Modals (`MODAL_WARNING_POPUP`)**: Render a floating, drop-shadowed modal window **over** the active screen for transient warnings (e.g., `85% Near Full`, `30s PIR Stuck Timeout`, `HC-SR04 Echo Error`, `Wi-Fi Failover`, or `NVS Reset`).
5. **Zero Core 0 Blocking**: Keep all font rasterization, modal compositing, and PSRAM frame blitting exclusively on **Xtensa LX7 `Core 1`** via a lock-free shared state snapshot (`oled_hud_state_t`).

---

## 2. Display Geometry & Page Memory Map ($128 \times 64$)

The `SSD1306` / `SH1106` GDDRAM ($1024\text{ bytes}$ per frame) is organized into **8 horizontal pages (`Page 0`–`Page 7`)**, each $128\text{ columns wide} \times 8\text{ pixels high}$:

| Page(s) | Pixel Rows ($y$) | Region Name | Content |
| :--- | :--- | :--- | :--- |
| **`Page 0`** | $y = 0..7$ | **Top Status Bar** | Network badge (`MQTT` / `BLE` / `OFFLINE`), Lid state (`IDLE` / `OPEN`), Fill `[ 75% ]` |
| **`Pages 1–6`** | $y = 8..55$ | **Main Viewport ($128 \times 48$)** | Context-switched view: Boot Splash, Mascot + HUD, Split Gauge, Lid Countdown, Radar Scan, or Alert |
| **`Page 7`** | $y = 56..63$ | **Bottom Telemetry Bar** | Ultrasonic depth (`15.0cm`), Open cycles (`#0042`), Wi-Fi RSSI (`-58dBm`) |
| **Overlay Layer** | $x = 8..119$, $y = 10..53$ | **Warning Popup Modal** | Floating $112 \times 44\text{ px}$ modal dialog box with inverted title bar & drop shadow |

---

## 3. Context-Aware Screen Modes & Wireframes

The **Core 1** compositor automatically selects the active base screen mode and composites any active **Warning Popup Modal** on top:

```mermaid
stateDiagram-v2
    [*] --> SCREEN_BOOT_SPLASH
    SCREEN_BOOT_SPLASH --> SCREEN_BLE_SETUP : Boot Done (No Wi-Fi / BLE Active)
    SCREEN_BOOT_SPLASH --> SCREEN_IDLE_HUD : Boot Done (Normal Operation)
    SCREEN_IDLE_HUD --> SCREEN_BLE_SETUP : BLE Provisioning / Failover Active
    SCREEN_IDLE_HUD --> SCREEN_FULL_ALERT : Fill >= 95% (Bin Full)
    SCREEN_IDLE_HUD --> SCREEN_LID_ACTIVE : PIR Motion (GPIO 2) or Remote Open
    SCREEN_LID_ACTIVE --> SCREEN_MEASURING : Soft-Close Complete -> 5x HC-SR04 Scan
    SCREEN_MEASURING --> SCREEN_RESULT_CARD : Show Updated Fill % for 3s
    SCREEN_RESULT_CARD --> SCREEN_FULL_ALERT : Fill >= 95%
    SCREEN_RESULT_CARD --> SCREEN_IDLE_HUD : Fill < 95%
    SCREEN_BLE_SETUP --> SCREEN_IDLE_HUD : MQTT Connected
```

### 3.1 Mode 0 — Boot Splash Animation & POST Checklist (`SCREEN_BOOT_SPLASH`)
Runs automatically for $\sim 1.8\text{ seconds}$ (`27 frames` @ 15 FPS) when the ESP32-S3 powers on:
- **Frames 0–8 (`0.0–0.5s`)**: Horizontal center-outward scanline wipe reveals the $2\times$ bold **`W.A.S.T.E.`** logo and version badge (`v1.0.0`).
- **Frames 9–20 (`0.5–1.3s`)**: Sequential Power-On Self-Test (POST) lines appear with an animated progress bar (`0% -> 100%`):
  - `[OK] 8MB Octal PSRAM (85 Frames)`
  - `[OK] HC-SR04 + SG90 + PIR Ready`
  - `[OK] NimBLE 0xFF00 + Wi-Fi STA`
- **Frames 21–27 (`1.3–1.8s`)**: Displays the unique MAC-derived device ID (`ID: smartbin_s3_a1b2c3`) before transitioning into `SCREEN_IDLE_HUD`.

```text
+------------------------------------------+
|         === W.A.S.T.E. v1.0 ===          |  <- Page 0 (Inverted Title Banner)
+------------------------------------------+
|  [OK] 8MB Octal PSRAM (85 Frames)        |
|  [OK] HC-SR04 + SG90 + PIR Ready         |  <- Animated POST Checklist
|  [OK] NimBLE 0xFF00 + Wi-Fi STA          |
|  ID:  smartbin_s3_a1b2c3                 |
+------------------------------------------+
| BOOTING [##################..]       92% |  <- Page 7: Smooth Progress Bar
+------------------------------------------+
```

### 3.2 Mode 1 — Idle HUD + Mascot Overlay (`SCREEN_IDLE_HUD`)
When the bin is closed and normal (`fill_percent < 95%`), **Core 1** composites the top and bottom telemetry bars over the 85-frame PSRAM animation (or displays a side-by-side Split Gauge):

```text
+------------------------------------------+
| MQTT -58dB      [IDLE]        Fill:  42% |  <- Page 0 (y=0..7): Status Bar
+------------------------------------------+
|                                          |
|        ( 85-Frame Risu Animation         |
|          or Split Fill Bar Gauge )       |  <- Pages 1..6 (y=8..55): Viewport
|                                          |
+------------------------------------------+
| Dist: 21.6cm    ||||||||..    Cycles: 42 |  <- Page 7 (y=56..63): Telemetry Footer
+------------------------------------------+
```
* **Selectable Idle Sub-Styles** (configurable via MQTT/BLE `oled_ui_mode`):
  - `"hud_mascot"` *(Default)*: Full-frame Risu animation with masked top (`Page 0`) and bottom (`Page 7`) HUD bars.
  - `"split_dashboard"`: Left $64 \times 48$ animated mascot + Right $64 \times 48$ large $2\times$ font `42%` and vertical bin fill bar.
  - `"mascot_only"`: Pure 100% full-screen GIF animation during idle, waking the HUD overlay only when motion or state changes occur.

### 3.3 Mode 2 — Active Lid & Hold Countdown (`SCREEN_LID_ACTIVE`)
Triggered immediately when `LID_STATE_OPENING`, `LID_STATE_OPEN_HOLD`, or `LID_STATE_CLOSING` is active:

```text
+------------------------------------------+
| MQTT            [OPEN]        Fill:  42% |  <- Page 0
+------------------------------------------+
|                                          |
|            >>> LID OPEN <<<              |  <- 2x Bold Header
|          Hold Time:  2.4 sec             |  <- Live countdown timer
|       [################........]         |  <- Animated countdown bar
|                                          |
+------------------------------------------+
| PIR: MOTION ACTIVE            Cycles: 43 |  <- Page 7
+------------------------------------------+
```
* During `LID_STATE_CLOSING` (`500 ms` soft-close ramp), the center banner transitions to **`<<< SOFT CLOSING >>>`** so the user knows the lid is descending.

### 3.4 Mode 3 — Ultrasonic Scanning & Result Card (`SCREEN_MEASURING`)
Triggered during `LID_STATE_MEASURING` (5-ping median `HC-SR04` burst) and held for `3.0 seconds` afterward:

```text
+------------------------------------------+
| MQTT            [SCAN]        Fill:  75% |  <- Page 0
+------------------------------------------+
|                                          |
|          CAPACITY:   75% FULL            |  <- Large 2x Font Readout
|          Headspace:  15.0 cm             |  <- 5-Ping Median Result
|          [###############.....]          |  <- 0-100% Fill Gauge Bar
|                                          |
+------------------------------------------+
| Trigger: LID_CLOSE            Cycles: 43 |  <- Page 7
+------------------------------------------+
```

### 3.5 Mode 4 — High-Contrast Full-Bin Alert (`SCREEN_FULL_ALERT`)
Triggered automatically whenever `full_alert == true` (`fill_percent >= 95%`, $\le 10\text{ cm}$):

```text
+------------------------------------------+
| ! ALERT !       [FULL]        Fill: 100% |  <- Page 0 (Inverted / Blinking)
+------------------------------------------+
|  ######################################  |
|  ##         ! BIN IS FULL !          ##  |
|  ##      PLEASE EMPTY RECEPTACLE     ##  |  <- High-contrast inverted alert box
|  ##       Depth: 9.8 cm (100%)       ##  |
|  ######################################  |
+------------------------------------------+
| ALERT SENT TO MQTT            Cycles: 50 |  <- Page 7
+------------------------------------------+
```
* Periodically toggles SSD1306 hardware display inversion (`0xA6` $\leftrightarrow$ `0xA7`) at `1 Hz` to catch attention from across the room.

### 3.6 Mode 5 — BLE Provisioning & Onboarding (`SCREEN_BLE_SETUP`)
Triggered when NVS has no Wi-Fi SSID, when Wi-Fi/MQTT enters BLE failover, or when the user presses the onboard **`BOOT` (`GPIO 0`)** button:

```text
+------------------------------------------+
| [BLE SETUP]     0xFF00        No Wi-Fi   |  <- Page 0
+------------------------------------------+
|  BLE Name: smartbin_s3_a1b2c3            |
|  Status:   Advertising (Ready to Pair)   |
|  App:      Open W.A.S.T.E. Companion     |
|            -> Tap Antenna -> Scan BLE    |
+------------------------------------------+
| Hold BOOT 3s = Reset Wi-Fi    Fill:  42% |  <- Page 7
+------------------------------------------+
```

---

## 4. Non-Blocking Warning Popup Modal System (`MODAL_WARNING_POPUP`)

In addition to the 6 base screens above, the **Core 1** compositor supports a **floating Popup Modal Overlay** ($112 \times 44\text{ px}$, centered at $x = 8..119, y = 10..53$) that renders **on top of** the current screen with a cleared background border, inverted header bar, drop shadow, and an auto-dismiss timer bar:

```text
+------------------------------------------+
| MQTT -58dB      [IDLE]        Fill:  88% |  <- Background screen remains visible
+------------------------------------------+
|   +----------------------------------+   |
|   | [!] WARNING: NEAR CAPACITY       |#  |  <- Inverted Modal Title Bar
|   |----------------------------------|#  |
|   | Bin fill level reached 88%       |#  |  <- Modal Message Line 1
|   | Headspace remaining: 12.4 cm     |#  |  <- Modal Message Line 2
|   | [####################........]   |#  |  <- Auto-Dismiss Countdown Bar
|   +----------------------------------+#  |
|    ####################################  |  <- 2px Drop Shadow
+------------------------------------------+
| Dist: 12.4cm    |||||||||.    Cycles: 49 |
+------------------------------------------+
```

### 4.1 Built-In Warning Modal Triggers (`oled_warn_code_t`)

| Warning Code | Trigger Condition | Modal Title | Modal Body Text | Duration |
| :--- | :--- | :--- | :--- | :--- |
| **`OLED_WARN_NEAR_FULL`** | $85\% \le \text{fill\_percent} < 95\%$ after measurement | `[!] NEAR CAPACITY` | `Bin reached XX% full` / `Headspace: XX.X cm` | `4.0 s` |
| **`OLED_WARN_PIR_STUCK_TIMEOUT`** | `HC-SR501` (`GPIO 2`) held HIGH for $> 30\text{ s}$ safety cap | `[!] MOTION TIMEOUT` | `PIR active > 30 sec` / `Force closing lid...` | `3.5 s` |
| **`OLED_WARN_SENSOR_ECHO_ERR`** | All 5 `HC-SR04` pings timed out (`ECHO` `GPIO 18` lost) | `[!] SENSOR ERROR` | `HC-SR04 echo timeout` / `Check TRIG:5 ECHO:18` | `4.5 s` |
| **`OLED_WARN_WIFI_FAILOVER`** | Wi-Fi lost after 5 retries $\rightarrow$ switched to BLE `0xFF00` | `[!] WIFI OFFLINE` | `Switched to BLE Mode` / `Buffering in PSRAM` | `3.5 s` |
| **`OLED_WARN_WIFI_RESET`** | `BOOT` (`GPIO 0`) held $3\text{ s}$ or remote `reset_wifi` cmd | `[i] WIFI CLEARED` | `NVS Wi-Fi erased` / `BLE Setup Active` | `4.0 s` |

---

## 5. Dual-Core Compositor Architecture (`Core 0` $\rightarrow$ `Core 1`)

```mermaid
flowchart LR
    subgraph Core0["Core 0 - FSM and Network"]
        FSM["trash_bin_fsm.c"]
        NET["net_ble_mqtt.c"]
    end

    subgraph Shared["Lock-Free Shared Snapshot"]
        STATE["oled_hud_state_t + Warning Modal Queue"]
    end

    subgraph Core1["Core 1 - OLED HUD Compositor (15-25 FPS)"]
        BOOT["Boot Splash Animator"]
        PSRAM["85 GIF Frames (8MB Octal PSRAM)"]
        FONT["5x7 ASCII Font + Primitives"]
        MODAL["Popup Modal Overlay Renderer"]
        COMP["1024-Byte SRAM Composite Buffer"]
        I2C["400 kHz I2C Master (SCL 6, SDA 7)"]

        BOOT --> COMP
        PSRAM --> COMP
        FONT --> COMP
        MODAL --> COMP
        COMP --> I2C
    end

    FSM -->|"oled_hud_update() / oled_hud_show_warning()"| STATE
    NET -->|"oled_hud_update() / oled_hud_show_warning()"| STATE
    STATE --> COMP
```

### 5.1 Shared HUD & Modal API (`oled_dancing_cat.h`)
```c
typedef enum {
    OLED_UI_MODE_HUD_MASCOT = 0,   /* Mascot animation + Top/Bottom HUD bars */
    OLED_UI_MODE_SPLIT_DASHBOARD,  /* 64px Mascot + 64px Large Fill Gauge    */
    OLED_UI_MODE_MASCOT_ONLY       /* Fullscreen GIF when idle, HUD on event */
} oled_ui_mode_t;

typedef enum {
    OLED_WARN_NONE = 0,
    OLED_WARN_NEAR_FULL,           /* 85% - 94% fill warning modal           */
    OLED_WARN_PIR_STUCK_TIMEOUT,   /* 30s PIR stuck-sensor safety close      */
    OLED_WARN_SENSOR_ECHO_ERR,     /* HC-SR04 ultrasonic timeout             */
    OLED_WARN_WIFI_FAILOVER,       /* Wi-Fi disconnected -> BLE failover     */
    OLED_WARN_WIFI_RESET           /* NVS Wi-Fi credentials cleared          */
} oled_warn_code_t;

/**
 * @brief Trigger a non-blocking centered warning popup modal over the current screen.
 */
void oled_hud_show_warning(oled_warn_code_t code, const char *line1, const char *line2, uint32_t duration_ms);
```

### 5.2 Multi-Layer Rendering Pipeline on `Core 1`
1. **Layer 0 (Boot Override)**: During the first `1.8 seconds` after boot, renders `SCREEN_BOOT_SPLASH` into `s_composite_fb[1024]`.
2. **Layer 1 (Base Viewport + HUD Bars)**: Copies `oled_hud_state_t` and renders the active screen (`IDLE_HUD`, `LID_ACTIVE`, `MEASURING`, `FULL_ALERT`, or `BLE_SETUP`) into `s_composite_fb[1024]`.
3. **Layer 2 (Popup Warning Modal Overlay)**: If `esp_timer_get_time() < s_modal_expire_us`, clears the $112 \times 44\text{ px}$ center box in `s_composite_fb`, draws the 1-bit border + 2px drop shadow, renders the inverted warning header, draws `line1` / `line2`, and draws the remaining modal duration bar.
4. **I2C Burst Flush**: Transmits the 8 pages (`1024 bytes`) over `400 kHz` I2C (`~22 ms` bus time), sleeping for the remainder of the frame tick via `vTaskDelayUntil()`.

---

## 6. Planned Firmware & Companion App Integration

| Component | Planned Additions |
| :--- | :--- |
| **`main/oled_font5x7.h`** *(New)* | Compact `95-glyph` printable ASCII $5 \times 7$ bitmap font (`475 bytes` in Flash) + $1\times / 2\times$ text, progress bar, and drop-shadow modal box drawing helpers. |
| **`main/oled_dancing_cat.h / .c`** | Add `SCREEN_BOOT_SPLASH` animator, 5-mode HUD compositor, `oled_hud_show_warning()` popup modal overlay renderer, and `s_composite_fb[1024]` on **Core 1**. |
| **`main/trash_bin_fsm.c` & `net_ble_mqtt.c`** | Push live state into `oled_hud_update()` and trigger warning modals (`NEAR_FULL`, `PIR_STUCK_TIMEOUT`, `SENSOR_ECHO_ERR`, `WIFI_FAILOVER`, `WIFI_RESET`). |
| **Remote Command (`configure`)** | Support `"oled_ui_mode": "hud_mascot" | "split_dashboard" | "mascot_only"` in MQTT/BLE JSON configuration and the **W.A.S.T.E. Flutter Companion App**. |


---

## 7. Future Roadmap: User-Uploadable Custom Animations (`.wbin` Format)

Because the `YD-ESP32-23` (`ESP32-S3 N16R8`) provides **16 MB of NOR Flash** (of which only `2 MB` is currently allocated) and **8 MB of Octal PSRAM**, the OLED animation **does not have to stay hardcoded in C**. Users can upload any `.gif` directly from the **W.A.S.T.E. Flutter Companion App** without recompiling or reflashing firmware.

### 7.1 Why Pre-Convert on the Phone Instead of Decoding `.gif` on the MCU?
Decoding arbitrary LZW-compressed `.gif` files with variable color tables, disposal methods, and aspect ratios on an MCU wastes CPU cycles and struggles with non-$128 \times 64$ dimensions.
Instead:
1. **Phone-Side Conversion & Live Preview**: The **Flutter Companion App** decodes the user's `.gif`, crops/scales it to $128 \times 64$, applies **Atkinson 1-bit dithering** (showing a live monochrome preview on the phone screen), and packs the frames into a compact **`.wbin` (`W.A.S.T.E. Binary Animation`)** stream.
2. **Zero-Overhead MCU Playback**: The ESP32-S3 receives ready-to-DMA SSD1306 vertical page bytes (`1,024 bytes` per frame), stores them in a dedicated Flash partition (`anim_data`), and loads them into **8 MB Octal PSRAM** at boot.

### 7.2 `.wbin` Binary Container Specification

| Offset | Size | Type | Field | Description |
| :--- | :--- | :--- | :--- | :--- |
| `0x00` | `4 B` | `char[4]` | `magic` | Magic header: `"WGF1"` (`0x57, 0x47, 0x46, 0x31`) |
| `0x04` | `2 B` | `uint16_t` | `num_frames` | Number of $128 \times 64$ frames ($1 \dots 512$, max `512 KB`) |
| `0x06` | `1 B` | `uint8_t` | `target_fps` | Playback frame rate ($5 \dots 30\text{ FPS}$, default `15`) |
| `0x07` | `1 B` | `uint8_t` | `flags` | Bit 0: `invert_pixels`, Bit 1: `hud_overlay_enabled` |
| `0x08` | `4 B` | `uint32_t` | `payload_bytes`| Must equal `num_frames * 1024` |
| `0x0C` | `4 B` | `uint32_t` | `crc32` | IEEE 802.3 CRC32 checksum of the frame payload |
| `0x10` | $N \times 1024\text{ B}$ | `uint8_t[]` | `frames` | Raw SSD1306 page-addressed frame buffers ($8\text{ pages} \times 128\text{ B}$) |

### 7.3 Storage & Fallback Architecture (`16 MB Flash` + `8 MB Octal PSRAM`)

1. **Dedicated Flash Partition (`partitions.csv`)**:
   ```csv
   # Name,     Type, SubType, Offset,   Size,     Flags
   nvs,        data, nvs,     0x9000,   0x6000,
   phy_init,   data, phy,     0xf000,   0x1000,
   factory,    app,  factory, 0x10000,  0x200000,
   anim_data,  data, 0x99,    0x210000, 0x100000,
   ```
   - Reserves a **`1 MB` (`1,024 KB`)** partition (`anim_data`) in the unused upper `14 MB` of Flash—enough to store a **1,000-frame** custom animation!
2. **PSRAM Staging & Dual-Source Fallback**:
   - On boot, `oled_dancing_cat_start()` checks the `anim_data` partition header for `"WGF1"` and verifies `crc32`.
   - **If valid**: Copies the custom `.wbin` frames from `anim_data` into **8 MB Octal PSRAM** and plays the user's custom animation.
   - **If empty/corrupted (or after a `"reset_anim"` command)**: Automatically falls back to the built-in **85-frame Hololive Risu** animation compiled into `dancing_cat_frames.h`!

### 7.4 Upload Transports (`LAN` vs `BLE` vs `MQTT`)

| Transport | Endpoint / Characteristic | Transfer Time (`85 frames` / `85 KB`) | How It Works |
| :--- | :--- | :--- | :--- |
| **1. Local LAN HTTP** *(Fastest)* | `POST http://<ip>/api/oled/upload` | **`~0.25 seconds`** | Streams `.wbin` directly into PSRAM staging buffer over Wi-Fi LAN, verifies CRC32, and commits to `anim_data` partition. |
| **2. BLE GATT (`0xFF00`)** *(Routerless)* | Characteristic **`0xFF07`** (`Write Without Response`, `244B` chunks) | **`~4.5 seconds`** | Sends `BEGIN_UPLOAD` $\rightarrow$ streams `244-byte` chunks with a live **`UPLOADING GIF: 68%`** progress bar on the OLED $\rightarrow$ `COMMIT_UPLOAD`. |
| **3. MQTT URL Fetch** *(Remote)* | `{"cmd":"fetch_anim","url":"https://.../anim.wbin"}` | **`~1.0 second`** | ESP32-S3 downloads `.wbin` over HTTPS directly into PSRAM. |
