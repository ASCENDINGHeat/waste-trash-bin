import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/telemetry.dart';

enum TransportMode { disconnected, mqtt, ble }

class WasteConnectionService extends ChangeNotifier {
  static const int maxHistoryEntries = 500;
  static const String _prefsHistoryKey = 'waste_telemetry_history_v1';
  static const String _prefsBrokerKey = 'waste_mqtt_broker_uri';
  static const String _prefsDeviceIdKey = 'waste_device_id';

  String _mqttBrokerUri = 'mqtt://broker.emqx.io:1883';
  String _targetDeviceId = '';
  bool _mqttConnected = false;
  bool _bleConnected = false;
  bool _nodeOnlineLwt = false;
  String _statusMessage = 'Idle — Connect via MQTT or BLE';

  WasteTelemetry? _latestTelemetry;
  final List<WasteTelemetry> _history = [];

  MqttServerClient? _mqttClient;
  BluetoothDevice? _bleDevice;
  BluetoothCharacteristic? _chrSsid;
  BluetoothCharacteristic? _chrPass;
  BluetoothCharacteristic? _chrMqtt;
  BluetoothCharacteristic? _chrApply;
  BluetoothCharacteristic? _chrTelem;
  BluetoothCharacteristic? _chrCmd;
  StreamSubscription<List<int>>? _bleTelemSub;
  StreamSubscription<BluetoothConnectionState>? _bleConnSub;

  String get mqttBrokerUri => _mqttBrokerUri;
  String get activeDeviceId => _latestTelemetry?.deviceId.isNotEmpty == true
      ? _latestTelemetry!.deviceId
      : (_targetDeviceId.isNotEmpty ? _targetDeviceId : 'smartbin_s3');
  bool get isMqttConnected => _mqttConnected;
  bool get isBleConnected => _bleConnected;
  bool get isNodeOnline => _nodeOnlineLwt || _bleConnected;
  String get statusMessage => _statusMessage;
  WasteTelemetry? get latestTelemetry => _latestTelemetry;
  List<WasteTelemetry> get history => List.unmodifiable(_history);

  TransportMode get transportMode {
    if (_bleConnected) return TransportMode.ble;
    if (_mqttConnected) return TransportMode.mqtt;
    return TransportMode.disconnected;
  }

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _mqttBrokerUri = prefs.getString(_prefsBrokerKey) ?? _mqttBrokerUri;
    _targetDeviceId = prefs.getString(_prefsDeviceIdKey) ?? '';

    final rawList = prefs.getStringList(_prefsHistoryKey) ?? [];
    _history.clear();
    for (final item in rawList) {
      final parsed = WasteTelemetry.tryParse(item);
      if (parsed != null) {
        _history.add(parsed);
      }
    }
    if (_history.isNotEmpty) {
      _latestTelemetry = _history.last;
    }
    notifyListeners();
  }

  Future<void> _recordTelemetry(WasteTelemetry t) async {
    _latestTelemetry = t;
    if (_targetDeviceId.isEmpty && t.deviceId.isNotEmpty) {
      _targetDeviceId = t.deviceId;
    }
    _history.add(t);
    if (_history.length > maxHistoryEntries) {
      _history.removeRange(0, _history.length - maxHistoryEntries);
    }
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    final encoded = _history.map((e) => jsonEncode(e.toJson())).toList();
    await prefs.setStringList(_prefsHistoryKey, encoded);
  }

  Future<void> clearHistory() async {
    _history.clear();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsHistoryKey);
  }

  // -------------------- MQTT Transport --------------------

  Future<void> connectMqtt({String? brokerUri, String? deviceId}) async {
    if (brokerUri != null && brokerUri.trim().isNotEmpty) {
      _mqttBrokerUri = brokerUri.trim();
    }
    if (deviceId != null) {
      _targetDeviceId = deviceId.trim();
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsBrokerKey, _mqttBrokerUri);
    await prefs.setString(_prefsDeviceIdKey, _targetDeviceId);

    disconnectMqtt();

    Uri parsed;
    try {
      final normalized = _mqttBrokerUri.contains('://')
          ? _mqttBrokerUri
          : 'mqtt://$_mqttBrokerUri';
      parsed = Uri.parse(normalized);
    } catch (e) {
      _statusMessage = 'Invalid MQTT URI: $_mqttBrokerUri';
      notifyListeners();
      return;
    }

    final host = parsed.host;
    final port = parsed.hasPort ? parsed.port : 1883;
    final clientId =
        'waste_app_${DateTime.now().millisecondsSinceEpoch.remainder(100000)}';

    _statusMessage = 'Connecting MQTT ($host:$port)...';
    notifyListeners();

    final client = MqttServerClient.withPort(host, clientId, port);
    client.keepAlivePeriod = 30;
    client.autoReconnect = true;
    client.logging(on: false);

    client.onConnected = () {
      _mqttConnected = true;
      _statusMessage = 'MQTT Connected ($host:$port)';
      _subscribeMqttTopics();
      notifyListeners();
    };

    client.onDisconnected = () {
      _mqttConnected = false;
      _statusMessage = _bleConnected
          ? 'BLE Failover Active (MQTT Disconnected)'
          : 'MQTT Disconnected';
      notifyListeners();
    };

    client.onAutoReconnected = () {
      _mqttConnected = true;
      _statusMessage = 'MQTT Reconnected ($host:$port)';
      _subscribeMqttTopics();
      notifyListeners();
    };

    _mqttClient = client;

    try {
      await client.connect();
      client.updates?.listen(_onMqttMessage);
    } catch (e) {
      _mqttConnected = false;
      _statusMessage = 'MQTT Error: $e';
      client.disconnect();
      notifyListeners();
    }
  }

  void _subscribeMqttTopics() {
    final c = _mqttClient;
    if (c == null || !_mqttConnected) return;
    final filter = _targetDeviceId.isNotEmpty ? _targetDeviceId : '+';
    c.subscribe('smartbin/$filter/telemetry', MqttQos.atLeastOnce);
    c.subscribe('smartbin/$filter/alert', MqttQos.atLeastOnce);
    c.subscribe('smartbin/$filter/status', MqttQos.atLeastOnce);
  }

  void _onMqttMessage(List<MqttReceivedMessage<MqttMessage?>>? events) {
    if (events == null) return;
    for (final rec in events) {
      final pubMsg = rec.payload as MqttPublishMessage?;
      if (pubMsg == null) continue;
      final payload =
          MqttPublishPayload.bytesToStringAsString(pubMsg.payload.message);
      final topic = rec.topic;

      if (topic.endsWith('/telemetry')) {
        final t = WasteTelemetry.tryParse(payload);
        if (t != null) {
          _nodeOnlineLwt = true;
          _recordTelemetry(t);
        }
      } else if (topic.endsWith('/status')) {
        _nodeOnlineLwt = payload.trim() == 'online';
        notifyListeners();
      }
    }
  }

  void disconnectMqtt() {
    _mqttClient?.disconnect();
    _mqttClient = null;
    _mqttConnected = false;
    notifyListeners();
  }

  // -------------------- BLE GATT Transport (0xFF00 - 0xFF06) --------------------

  bool _matchesUuid16(Guid guid, String hex4) {
    final s = guid.toString().toLowerCase();
    return s == hex4.toLowerCase() ||
        s.startsWith('0000${hex4.toLowerCase()}-0000-1000-8000');
  }

  Future<bool> connectBleDevice(BluetoothDevice device) async {
    await disconnectBle();
    _statusMessage = 'Connecting BLE to ${device.platformName}...';
    notifyListeners();

    try {
      await device.connect(timeout: const Duration(seconds: 10));
      _bleDevice = device;

      _bleConnSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _bleConnected = false;
          _statusMessage = _mqttConnected
              ? 'MQTT Connected'
              : 'BLE Disconnected from ${device.platformName}';
          notifyListeners();
        }
      });

      final services = await device.discoverServices();
      for (final svc in services) {
        if (_matchesUuid16(svc.uuid, 'ff00')) {
          for (final chr in svc.characteristics) {
            if (_matchesUuid16(chr.uuid, 'ff01')) _chrSsid = chr;
            if (_matchesUuid16(chr.uuid, 'ff02')) _chrPass = chr;
            if (_matchesUuid16(chr.uuid, 'ff03')) _chrMqtt = chr;
            if (_matchesUuid16(chr.uuid, 'ff04')) _chrApply = chr;
            if (_matchesUuid16(chr.uuid, 'ff05')) _chrTelem = chr;
            if (_matchesUuid16(chr.uuid, 'ff06')) _chrCmd = chr;
          }
        }
      }

      if (_chrTelem != null) {
        final initialBytes = await _chrTelem!.read();
        final initialStr = utf8.decode(initialBytes, allowMalformed: true);
        final t = WasteTelemetry.tryParse(initialStr);
        if (t != null) {
          await _recordTelemetry(t);
        }

        await _chrTelem!.setNotifyValue(true);
        _bleTelemSub = _chrTelem!.onValueReceived.listen((bytes) {
          final jsonStr = utf8.decode(bytes, allowMalformed: true);
          final parsed = WasteTelemetry.tryParse(jsonStr);
          if (parsed != null) {
            _recordTelemetry(parsed);
          }
        });
      }

      _bleConnected = true;
      _statusMessage = 'BLE Connected (${device.platformName})';
      notifyListeners();
      return true;
    } catch (e) {
      _bleConnected = false;
      _statusMessage = 'BLE Connection Failed: $e';
      notifyListeners();
      return false;
    }
  }

  Future<Map<String, String>> readBleProvisioningConfig() async {
    String ssid = '';
    String mqtt = _mqttBrokerUri;
    try {
      if (_chrSsid != null) {
        ssid = utf8.decode(await _chrSsid!.read(), allowMalformed: true);
      }
      if (_chrMqtt != null) {
        final m = utf8.decode(await _chrMqtt!.read(), allowMalformed: true);
        if (m.isNotEmpty) mqtt = m;
      }
    } catch (_) {}
    return {'ssid': ssid, 'mqtt_uri': mqtt};
  }

  Future<bool> provisionOverBle({
    required String wifiSsid,
    required String wifiPass,
    required String mqttUri,
  }) async {
    if (!_bleConnected) return false;
    try {
      if (_chrSsid != null) {
        await _chrSsid!.write(utf8.encode(wifiSsid), withoutResponse: false);
      }
      if (_chrPass != null && wifiPass.isNotEmpty) {
        await _chrPass!.write(utf8.encode(wifiPass), withoutResponse: false);
      }
      if (_chrMqtt != null && mqttUri.isNotEmpty) {
        await _chrMqtt!.write(utf8.encode(mqttUri), withoutResponse: false);
      }
      if (_chrApply != null) {
        await _chrApply!.write([0x01], withoutResponse: false);
      }
      _statusMessage = 'Provisioned Wi-Fi & MQTT to NVS via BLE!';
      notifyListeners();
      return true;
    } catch (e) {
      _statusMessage = 'BLE Provisioning Error: $e';
      notifyListeners();
      return false;
    }
  }

  Future<void> disconnectBle() async {
    await _bleTelemSub?.cancel();
    _bleTelemSub = null;
    await _bleConnSub?.cancel();
    _bleConnSub = null;
    try {
      await _bleDevice?.disconnect();
    } catch (_) {}
    _bleDevice = null;
    _chrSsid = null;
    _chrPass = null;
    _chrMqtt = null;
    _chrApply = null;
    _chrTelem = null;
    _chrCmd = null;
    _bleConnected = false;
    notifyListeners();
  }

  // -------------------- Unified Remote Commands --------------------

  Future<bool> sendCommandMap(Map<String, dynamic> cmdPayload) async {
    final rawJson = jsonEncode(cmdPayload);

    // 1. Prefer direct BLE GATT 0xFF06 if connected over BLE
    if (_bleConnected && _chrCmd != null) {
      try {
        await _chrCmd!.write(utf8.encode(rawJson), withoutResponse: false);
        _statusMessage = 'Sent "${cmdPayload['cmd']}" via BLE';
        notifyListeners();
        return true;
      } catch (e) {
        _statusMessage = 'BLE Cmd Error: $e';
        notifyListeners();
      }
    }

    // 2. Otherwise publish over MQTT to smartbin/<device_id>/cmd
    if (_mqttConnected && _mqttClient != null) {
      final builder = MqttClientPayloadBuilder();
      builder.addUTF8String(rawJson);
      final topic = 'smartbin/$activeDeviceId/cmd';
      _mqttClient!.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
      _statusMessage = 'Sent "${cmdPayload['cmd']}" via MQTT ($topic)';
      notifyListeners();
      return true;
    }

    _statusMessage = 'Cannot send command: Connect via MQTT or BLE first';
    notifyListeners();
    return false;
  }

  Future<bool> triggerMeasureNow() =>
      sendCommandMap({'cmd': 'measure_now'});

  Future<bool> triggerOpenLid({int holdSeconds = 5}) =>
      sendCommandMap({'cmd': 'open_lid', 'hold_s': holdSeconds});

  Future<bool> updateBinConfig(WasteBinConfig cfg) =>
      sendCommandMap(cfg.toCommandJson());
}
