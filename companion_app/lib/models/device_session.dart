import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'telemetry.dart';

/// Active network connection transport mode.
///
/// Priority 1: LAN (Local HTTP / mDNS)
/// Priority 2: MQTT (Cloud broker / Flespi)
/// Priority 3: BLE (Direct GATT 0xFF00)
enum TransportMode { disconnected, lan, mqtt, ble }

/// User-selectable transport routing preference.
enum TransportPreference { auto, lan, mqtt, ble }

/// Per-node runtime and persisted state for a W.A.S.T.E. ESP32-S3 smart bin.
class WasteDeviceSession {
  static const int maxHistoryEntries = 500;

  String deviceId;
  String alias;

  // Priority 1: Local LAN HTTP REST
  String lanHost;
  int lanPort;
  String lanDeviceIp;
  bool lanConnected;
  bool lanConnecting;
  Timer? lanPollTimer;

  // Priority 2: MQTT node presence (over shared broker)
  bool nodeOnlineLwt;

  // Priority 3: Direct BLE GATT (0xFF00 - 0xFF07)
  BluetoothDevice? bleDevice;
  bool bleConnected;
  BluetoothCharacteristic? chrSsid;
  BluetoothCharacteristic? chrPass;
  BluetoothCharacteristic? chrMqtt;
  BluetoothCharacteristic? chrApply;
  BluetoothCharacteristic? chrTelem;
  BluetoothCharacteristic? chrCmd;
  BluetoothCharacteristic? chrUpload;
  StreamSubscription<List<int>>? bleTelemSub;
  StreamSubscription<BluetoothConnectionState>? bleConnSub;

  // Routing & Telemetry
  TransportPreference preferredTransport;
  WasteTelemetry? latestTelemetry;
  final List<WasteTelemetry> history;

  WasteDeviceSession({
    required this.deviceId,
    this.alias = '',
    this.lanHost = '',
    this.lanPort = 80,
    this.lanDeviceIp = '',
    this.lanConnected = false,
    this.lanConnecting = false,
    this.nodeOnlineLwt = false,
    this.bleConnected = false,
    this.preferredTransport = TransportPreference.auto,
    this.latestTelemetry,
    List<WasteTelemetry>? history,
  }) : history = history ?? [];

  String get displayName => alias.trim().isNotEmpty ? alias.trim() : deviceId;

  bool get allowLan =>
      preferredTransport == TransportPreference.auto ||
      preferredTransport == TransportPreference.lan;

  bool get allowMqtt =>
      preferredTransport == TransportPreference.auto ||
      preferredTransport == TransportPreference.mqtt;

  bool get allowBle =>
      preferredTransport == TransportPreference.auto ||
      preferredTransport == TransportPreference.ble;

  TransportMode resolveTransportMode({required bool mqttBrokerConnected}) {
    switch (preferredTransport) {
      case TransportPreference.lan:
        return lanConnected ? TransportMode.lan : TransportMode.disconnected;
      case TransportPreference.mqtt:
        return mqttBrokerConnected
            ? TransportMode.mqtt
            : TransportMode.disconnected;
      case TransportPreference.ble:
        return bleConnected ? TransportMode.ble : TransportMode.disconnected;
      case TransportPreference.auto:
        if (lanConnected) return TransportMode.lan;
        if (mqttBrokerConnected) return TransportMode.mqtt;
        if (bleConnected) return TransportMode.ble;
        return TransportMode.disconnected;
    }
  }

  bool isOnline() {
    switch (preferredTransport) {
      case TransportPreference.lan:
        return lanConnected;
      case TransportPreference.mqtt:
        return nodeOnlineLwt;
      case TransportPreference.ble:
        return bleConnected;
      case TransportPreference.auto:
        return lanConnected || nodeOnlineLwt || bleConnected;
    }
  }

  void addTelemetry(WasteTelemetry t) {
    latestTelemetry = t;
    history.add(t);
    if (history.length > maxHistoryEntries) {
      history.removeRange(0, history.length - maxHistoryEntries);
    }
  }

  void cancelLanTimer() {
    lanPollTimer?.cancel();
    lanPollTimer = null;
  }

  Future<void> closeBleResources() async {
    await bleTelemSub?.cancel();
    bleTelemSub = null;
    await bleConnSub?.cancel();
    bleConnSub = null;
    try {
      await bleDevice?.disconnect();
    } catch (_) {}
    bleDevice = null;
    chrSsid = null;
    chrPass = null;
    chrMqtt = null;
    chrApply = null;
    chrTelem = null;
    chrCmd = null;
    chrUpload = null;
    bleConnected = false;
  }

  Map<String, dynamic> toMetadataJson() => {
        'device_id': deviceId,
        'alias': alias,
        'lan_host': lanHost,
        'lan_port': lanPort,
        'lan_device_ip': lanDeviceIp,
        'preferred_transport': preferredTransport.name,
      };

  factory WasteDeviceSession.fromMetadataJson(Map<String, dynamic> json) {
    final prefName = json['preferred_transport'] as String?;
    var pref = TransportPreference.auto;
    if (prefName != null) {
      for (final v in TransportPreference.values) {
        if (v.name == prefName) {
          pref = v;
          break;
        }
      }
    }

    return WasteDeviceSession(
      deviceId: (json['device_id'] as String?) ?? 'smartbin_s3',
      alias: (json['alias'] as String?) ?? '',
      lanHost: (json['lan_host'] as String?) ?? '',
      lanPort: ((json['lan_port'] as num?) ?? 80).toInt().clamp(1, 65535),
      lanDeviceIp: (json['lan_device_ip'] as String?) ?? '',
      preferredTransport: pref,
    );
  }
}
