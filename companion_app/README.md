# W.A.S.T.E. Flutter Companion App (`companion_app/`) — v2.0.0

Cross-platform **Flutter** companion application for **W.A.S.T.E.** (**W**aste **A**utomation and **S**ensing **T**echnology **E**ngine).

See **[../docs/06-flutter-companion-app.md](../docs/06-flutter-companion-app.md)** for full architectural and protocol documentation.

## Features in v2.0.0
- **Tri-Mode Transport Router (`WasteConnectionService`)**:
  - **Priority 1 — Local LAN (`esp_http_server` + mDNS `_waste._tcp`)**: High-bandwidth, sub-10ms local communication over Wi-Fi (`/api/status`, `/api/oled/upload`, `/api/oled/reset`, `/api/lid`, `/api/measure`, `/api/config`).
  - **Priority 2 — Cloud MQTT (`mqtt_client` / Flespi)**: Remote monitoring and control anywhere over WAN/cellular (`smartbin/+/telemetry`, `smartbin/<id>/cmd`).
  - **Priority 3 — Direct BLE GATT (`flutter_blue_plus` / Service `0xFF00`)**: Routerless offline monitoring, initial provisioning (`0xFF01`–`0xFF04`), telemetry stream (`0xFF05`), remote commands (`0xFF06`), and chunked animation streaming (`0xFF07`).
- **In-App GIF to `.wbin` Converter (`WbinEncoder`)**:
  - Pure-Dart GIF decoding (`package:image/image.dart`) with zero external C dependencies.
  - Box-area downsampling to $128 \times 64$ with gamma correction ($0.85$) and luminance thresholding ($118$).
  - **Atkinson 1-Bit Error Diffusion Dithering**: Preserves crisp textures on monochrome displays.
  - SSD1306 vertical page bit-packing ($8\text{ pages} \times 128\text{ cols} = 1024\text{ bytes/frame}$).
  - 16-byte `WGF1` container packing with standard IEEE 802.3 CRC32 calculation (`0xEDB88320`).
- **Custom Animation Uploader UI (`AnimationUploadSheet`)**:
  - In-app file picker for user-selected `.gif` animations plus built-in geometric demo generator.
  - Virtual 1-bit $128 \times 64$ monochrome OLED preview canvas (`OledCanvasPainter`) with live frame scrubbing slider and playback controls.
  - Target FPS selector ($5\dots 30\text{ FPS}$), B/W invert toggle, and HUD overlay toggle.
  - Multi-transport upload: sub-second LAN HTTP streaming or 244-byte BLE `0xFF07` chunks with live linear progress bar.
  - One-tap "Reset to Mascot" action to restore the default Hololive Risu animation.
- **Zero-Touch BLE Provisioning (`0xFF01`–`0xFF04`)**: Scan for `smartbin_s3_*` nodes and write Wi-Fi SSID, Password, and MQTT Broker URI directly to ESP32-S3 NVS flash.
- **Remote Actuation & Calibration**: Remotely open the lid (`open_lid`), trigger an immediate 5-ping ultrasonic check (`measure_now`), adjust `10–30 cm` depth thresholds, and select OLED HUD idle layout (`oled_ui_mode`).
- **Phone-Side Telemetry History**: Stores up to 500 telemetry events locally (`SharedPreferences`) and plots an interactive fill-level trend chart (`fl_chart`).
- **Comprehensive Automated Test Suite**: 16 unit and widget tests across 7 test groups in `test/widget_test.dart` covering `.wbin` packing, IEEE 802.3 CRC32 vectors, Tri-Mode fallback precedence, and UI controls.

## Quick Build & Persistent Signing
```bash
cd companion_app
# Generate platform runners if building from a fresh clone:
flutter create --platforms=android,ios --org com.ascendingheat.waste --project-name waste_companion .
# Configure persistent release signing (reads android/key.properties or CI secrets):
node scripts/configure_android_signing.mjs
flutter pub get
flutter test
flutter build apk --release
```

See **[../docs/06-flutter-companion-app.md](../docs/06-flutter-companion-app.md)** for generating `waste-release.jks` and setting the GitHub Actions secrets (`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`) so future APKs install as in-place updates without uninstalling.

