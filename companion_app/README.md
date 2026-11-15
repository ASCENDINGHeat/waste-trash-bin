# W.A.S.T.E. Flutter Companion App (`companion_app/`)

Cross-platform **Flutter** companion application for **W.A.S.T.E.** (**W**aste **A**utomation and **S**ensing **T**echnology **E**ngine).

See **[../docs/06-flutter-companion-app.md](../docs/06-flutter-companion-app.md)** for full architectural and protocol documentation.

## Features
- **Dual-Transport Live Dashboard**: Connects via **MQTT** (`smartbin/+/telemetry`) and automatically falls back to **BLE GATT (`0xFF00` / `0xFF05`)** when Wi-Fi is offline.
- **Zero-Touch BLE Provisioning (`0xFF01`–`0xFF04`)**: Scan for `smartbin_s3_*` nodes and write Wi-Fi SSID, Password, and MQTT Broker URI directly to ESP32-S3 NVS flash.
- **Remote Actuation & Calibration (`0xFF06` / `smartbin/<id>/cmd`)**: Remotely open the lid (`open_lid`), trigger an immediate 5-ping ultrasonic check (`measure_now`), and adjust `10–30 cm` depth thresholds (`configure`).
- **Phone-Side Telemetry History**: Stores up to 500 telemetry events locally (`SharedPreferences`) and plots an interactive fill-level trend chart (`fl_chart`).

## Quick Build
```bash
cd companion_app
# Generate platform runners if building from a fresh clone:
flutter create --platforms=android,ios --org com.ascendingheat.waste .
flutter pub get
flutter test
flutter build apk --release
```
