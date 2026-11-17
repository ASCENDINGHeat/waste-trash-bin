import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/telemetry.dart';

/// Active network connection transport mode.
///
/// Priority 1: LAN (Local HTTP / mDNS)
/// Priority 2: MQTT (Cloud broker / Flespi)
/// Priority 3: BLE (Direct GATT 0xFF00)
enum TransportMode { disconnected, lan, mqtt, ble }

/// User-selectable transport routing preference.
enum TransportPreference { auto, lan, mqtt, ble }

class WasteConnectionService extends ChangeNotifier {
  static const int maxHistoryEntries = 500;
  static const String _prefsHistoryKey = 'waste_telemetry_history_v1';
  static const String _prefsBrokerKey = 'waste_mqtt_broker_uri';
  static const String _prefsDeviceIdKey = 'waste_device_id';
  static const String _prefsLanHostKey = 'waste_lan_host';
  static const String _prefsLanPortKey = 'waste_lan_port';
  static const String _prefsTransportPrefKey = 'waste_transport_preference';

  String _mqttBrokerUri = 'mqtt://broker.emqx.io:1883';
  String _targetDeviceId = '';
  String _lanHost = '';
  int _lanPort = 80;
  String _lanDeviceIp = '';
  TransportPreference _preferredTransport = TransportPreference.auto;

  bool _lanConnected = false;
  bool _lanConnecting = false;
  bool _mqttConnected = false;
  bool _bleConnected = false;
  bool _nodeOnlineLwt = false;
  String _statusMessage = 'Idle — Connect via LAN, MQTT or BLE';

  WasteTelemetry? _latestTelemetry;
  final List<WasteTelemetry> _history = [];

  Timer? _lanPollTimer;
  MqttServerClient? _mqttClient;
  BluetoothDevice? _bleDevice;
  BluetoothCharacteristic? _chrSsid;
  BluetoothCharacteristic? _chrPass;
  BluetoothCharacteristic? _chrMqtt;
  BluetoothCharacteristic? _chrApply;
  BluetoothCharacteristic? _chrTelem;
  BluetoothCharacteristic? _chrCmd;
  BluetoothCharacteristic? _chrUpload;
  StreamSubscription<List<int>>? _bleTelemSub;
  StreamSubscription<BluetoothConnectionState>? _bleConnSub;

  String get mqttBrokerUri => _mqttBrokerUri;
  String get lanHost => _lanHost;
  int get lanPort => _lanPort;
  String get lanDeviceIp => _lanDeviceIp;
  TransportPreference get preferredTransport => _preferredTransport;
  String get activeDeviceId => _latestTelemetry?.deviceId.isNotEmpty == true
      ? _latestTelemetry!.deviceId
      : (_targetDeviceId.isNotEmpty ? _targetDeviceId : 'smartbin_s3');

  bool get isLanConnected => _lanConnected;
  bool get isLanConnecting => _lanConnecting;
  bool get isMqttConnected => _mqttConnected;
  bool get isBleConnected => _bleConnected;
  bool get isNodeOnline {
    switch (_preferredTransport) {
      case TransportPreference.lan:
        return _lanConnected;
      case TransportPreference.mqtt:
        return _nodeOnlineLwt;
      case TransportPreference.ble:
        return _bleConnected;
      case TransportPreference.auto:
        return _lanConnected || _nodeOnlineLwt || _bleConnected;
    }
  }
  String get statusMessage => _statusMessage;
  WasteTelemetry? get latestTelemetry => _latestTelemetry;
  List<WasteTelemetry> get history => List.unmodifiable(_history);

  /// Tri-Mode Transport Priority Resolver:
  /// Auto: Priority 1 (Local LAN) -> Priority 2 (Cloud MQTT) -> Priority 3 (Direct BLE)
  /// Manual: Uses only the selected transport without silent fallback.
  TransportMode get transportMode {
    switch (_preferredTransport) {
      case TransportPreference.lan:
        return _lanConnected ? TransportMode.lan : TransportMode.disconnected;
      case TransportPreference.mqtt:
        return _mqttConnected ? TransportMode.mqtt : TransportMode.disconnected;
      case TransportPreference.ble:
        return _bleConnected ? TransportMode.ble : TransportMode.disconnected;
      case TransportPreference.auto:
        if (_lanConnected) return TransportMode.lan;
        if (_mqttConnected) return TransportMode.mqtt;
        if (_bleConnected) return TransportMode.ble;
        return TransportMode.disconnected;
    }
  }

  Future<void> setTransportPreference(TransportPreference pref) async {
    _preferredTransport = pref;
    switch (pref) {
      case TransportPreference.auto:
        _statusMessage = 'Transport: Auto (LAN -> MQTT -> BLE)';
        break;
      case TransportPreference.lan:
        _statusMessage = _lanConnected
            ? 'Transport pinned to Local LAN (http://$_lanHost:$_lanPort)'
            : 'Transport pinned to Local LAN (Disconnected)';
        break;
      case TransportPreference.mqtt:
        _statusMessage = _mqttConnected
            ? 'Transport pinned to Cloud MQTT'
            : 'Transport pinned to Cloud MQTT (Disconnected)';
        break;
      case TransportPreference.ble:
        _statusMessage = _bleConnected
            ? 'Transport pinned to Direct BLE'
            : 'Transport pinned to Direct BLE (Disconnected)';
        break;
    }
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsTransportPrefKey, pref.name);
    } catch (_) {}
  }

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _mqttBrokerUri = prefs.getString(_prefsBrokerKey) ?? _mqttBrokerUri;
    _targetDeviceId = prefs.getString(_prefsDeviceIdKey) ?? '';
    _lanHost = prefs.getString(_prefsLanHostKey) ?? '';
    _lanPort = prefs.getInt(_prefsLanPortKey) ?? 80;

    final prefName = prefs.getString(_prefsTransportPrefKey);
    if (prefName != null) {
      for (final v in TransportPreference.values) {
        if (v.name == prefName) {
          _preferredTransport = v;
          break;
        }
      }
    }

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

    if (_lanHost.isNotEmpty &&
        (_preferredTransport == TransportPreference.auto ||
            _preferredTransport == TransportPreference.lan)) {
      unawaited(connectLan());
    }
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

  // -------------------- Priority 1: Local LAN HTTP Transport --------------------

  Future<bool> connectLan({String? host, int? port}) async {
    if (host != null) {
      var cleaned = host.trim();
      cleaned = cleaned.replaceFirst(
          RegExp(r'^https?://', caseSensitive: false), '');
      final slashIdx = cleaned.indexOf('/');
      if (slashIdx != -1) {
        cleaned = cleaned.substring(0, slashIdx);
      }
      final colonIdx = cleaned.lastIndexOf(':');
      if (colonIdx > 0 && colonIdx < cleaned.length - 1) {
        final maybePort = int.tryParse(cleaned.substring(colonIdx + 1));
        if (maybePort != null && maybePort > 0 && maybePort <= 65535) {
          cleaned = cleaned.substring(0, colonIdx);
          port ??= maybePort;
        }
      }
      if (cleaned.isNotEmpty) {
        _lanHost = cleaned;
      }
    }
    if (port != null && port > 0 && port <= 65535) {
      _lanPort = port;
    }

    if (_lanHost.isEmpty) {
      _statusMessage = 'LAN Error: Host IP/hostname cannot be empty';
      notifyListeners();
      return false;
    }

    _lanConnecting = true;
    _statusMessage = 'Connecting LAN (http://$_lanHost:$_lanPort)...';
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsLanHostKey, _lanHost);
      await prefs.setInt(_prefsLanPortKey, _lanPort);
    } catch (_) {}

    try {
      final uri = Uri.parse('http://$_lanHost:$_lanPort/api/status');
      final resp = await http.get(uri).timeout(const Duration(seconds: 4));
      if (resp.statusCode == 200) {
        _lanConnected = true;
        try {
          final decoded = jsonDecode(resp.body);
          if (decoded is Map<String, dynamic>) {
            final devId = decoded['device_id'] as String?;
            if (devId != null && devId.isNotEmpty && _targetDeviceId.isEmpty) {
              _targetDeviceId = devId;
            }
            final ip = decoded['ip'] as String?;
            if (ip != null && ip.isNotEmpty) {
              _lanDeviceIp = ip;
            }
          }
        } catch (_) {}

        final parsed = WasteTelemetry.tryParse(resp.body);
        if (parsed != null) {
          await _recordTelemetry(parsed);
        }
        _statusMessage = 'LAN Connected (http://$_lanHost:$_lanPort)';
        _startLanPolling();
        return true;
      } else {
        _lanConnected = false;
        _statusMessage = 'LAN Error: HTTP ${resp.statusCode}';
        return false;
      }
    } catch (e) {
      _lanConnected = false;
      _statusMessage = 'LAN Connection Failed: $e';
      return false;
    } finally {
      _lanConnecting = false;
      notifyListeners();
    }
  }

  /// Probes mDNS .local hostnames (e.g. smartbin_s3_XXXXXX.local) for port 80.
  Future<bool> probeMdnsLan({int port = 80}) async {
    final candidates = <String>[
      if (activeDeviceId.isNotEmpty) '$activeDeviceId.local',
      if (_lanHost.isNotEmpty && _lanHost != '$activeDeviceId.local') _lanHost,
      if (activeDeviceId != 'smartbin_s3') 'smartbin_s3.local',
    ];
    for (final candidate in candidates.toSet()) {
      final ok = await connectLan(host: candidate, port: port);
      if (ok) return true;
    }
    return false;
  }

  void _startLanPolling() {
    _lanPollTimer?.cancel();
    _lanPollTimer = Timer.periodic(const Duration(seconds: 4), (_) async {
      if (!_lanConnected || _lanHost.isEmpty) {
        _lanPollTimer?.cancel();
        return;
      }
      try {
        final uri = Uri.parse('http://$_lanHost:$_lanPort/api/status');
        final resp = await http.get(uri).timeout(const Duration(seconds: 3));
        if (resp.statusCode == 200) {
          final parsed = WasteTelemetry.tryParse(resp.body);
          if (parsed != null) {
            _recordTelemetry(parsed);
          }
        } else {
          _lanConnected = false;
          notifyListeners();
        }
      } catch (_) {
        _lanConnected = false;
        notifyListeners();
      }
    });
  }

  void disconnectLan() {
    _lanPollTimer?.cancel();
    _lanPollTimer = null;
    _lanConnected = false;
    _statusMessage = _mqttConnected
        ? 'MQTT Connected'
        : (_bleConnected ? 'BLE Connected' : 'LAN Disconnected');
    notifyListeners();
  }

  // -------------------- Priority 2: Cloud MQTT Transport --------------------

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

    final isSecure = parsed.scheme == 'mqtts' || parsed.scheme == 'ssl';
    final host = parsed.host;
    final port = parsed.hasPort ? parsed.port : (isSecure ? 8883 : 1883);
    final clientId =
        'waste_app_${DateTime.now().millisecondsSinceEpoch.remainder(100000)}';

    String? username;
    String? password;
    if (parsed.userInfo.isNotEmpty) {
      final parts = parsed.userInfo.split(':');
      username = Uri.decodeComponent(parts[0]);
      if (parts.length > 1) {
        password = Uri.decodeComponent(parts.sublist(1).join(':'));
      }
    }

    _statusMessage = 'Connecting MQTT ($host:$port)...';
    notifyListeners();

    final client = MqttServerClient.withPort(host, clientId, port);
    client.setProtocolV311();
    client.keepAlivePeriod = 30;
    client.autoReconnect = true;
    client.secure = isSecure;
    client.logging(on: false);

    client.onConnected = () {
      _mqttConnected = true;
      _statusMessage = 'MQTT Connected ($host:$port)';
      _subscribeMqttTopics();
      notifyListeners();
    };

    client.onDisconnected = () {
      _mqttConnected = false;
      _statusMessage = _lanConnected
          ? 'LAN Active'
          : (_bleConnected ? 'BLE Failover Active' : 'MQTT Disconnected');
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
      await client.connect(username, password);
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

  // -------------------- Priority 3: BLE GATT Transport (0xFF00 - 0xFF07) --------------------

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

      try {
        await device.requestMtu(247);
      } catch (_) {}

      _bleConnSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _bleConnected = false;
          _statusMessage = _lanConnected
              ? 'LAN Active'
              : (_mqttConnected
                  ? 'MQTT Connected'
                  : 'BLE Disconnected from ${device.platformName}');
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
            if (_matchesUuid16(chr.uuid, 'ff07')) _chrUpload = chr;
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
    _chrUpload = null;
    _bleConnected = false;
    notifyListeners();
  }

  // -------------------- Tri-Mode Unified Command Routing --------------------

  bool get _allowLan =>
      _preferredTransport == TransportPreference.auto ||
      _preferredTransport == TransportPreference.lan;

  bool get _allowMqtt =>
      _preferredTransport == TransportPreference.auto ||
      _preferredTransport == TransportPreference.mqtt;

  bool get _allowBle =>
      _preferredTransport == TransportPreference.auto ||
      _preferredTransport == TransportPreference.ble;

  /// Sends a command dictionary honoring Tri-Mode priority and user selection:
  /// Priority 1 (LAN HTTP) -> Priority 2 (Cloud MQTT) -> Priority 3 (Direct BLE)
  Future<bool> sendCommandMap(Map<String, dynamic> cmdPayload) async {
    final rawJson = jsonEncode(cmdPayload);
    final cmdName = cmdPayload['cmd'] ?? cmdPayload['action'] ?? 'cmd';

    // 1. Priority 1: Local LAN HTTP REST
    if (_allowLan && _lanConnected && _lanHost.isNotEmpty) {
      try {
        Uri uri;
        String? body;
        if (cmdName == 'open_lid' || cmdPayload['action'] == 'open') {
          uri = Uri.parse('http://$_lanHost:$_lanPort/api/lid');
          body = jsonEncode({
            'action': 'open',
            'hold_s': cmdPayload['hold_s'] ?? 5,
          });
        } else if (cmdName == 'measure_now') {
          uri = Uri.parse('http://$_lanHost:$_lanPort/api/measure');
          body = jsonEncode({});
        } else if (cmdName == 'configure') {
          uri = Uri.parse('http://$_lanHost:$_lanPort/api/config');
          body = rawJson;
        } else if (cmdName == 'reset_anim') {
          uri = Uri.parse('http://$_lanHost:$_lanPort/api/oled/reset');
          body = jsonEncode({});
        } else {
          uri = Uri.parse('http://$_lanHost:$_lanPort/api/cmd');
          body = rawJson;
        }

        final resp = await http.post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: body,
        ).timeout(const Duration(seconds: 4));

        if (resp.statusCode == 200) {
          _statusMessage = 'Sent "$cmdName" via Local LAN';
          final parsed = WasteTelemetry.tryParse(resp.body);
          if (parsed != null) {
            await _recordTelemetry(parsed);
          }
          notifyListeners();
          return true;
        }
      } catch (_) {
        // LAN failed; fall through to Priority 2 (MQTT) if Auto
        _lanConnected = false;
      }
    }

    // 2. Priority 2: Cloud MQTT
    if (_allowMqtt && _mqttConnected && _mqttClient != null) {
      try {
        final builder = MqttClientPayloadBuilder();
        builder.addUTF8String(rawJson);
        final topic = 'smartbin/$activeDeviceId/cmd';
        _mqttClient!.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
        _statusMessage = 'Sent "$cmdName" via MQTT ($topic)';
        notifyListeners();
        return true;
      } catch (_) {
        // Fall through to Priority 3 (BLE) if Auto
      }
    }

    // 3. Priority 3: Direct BLE GATT 0xFF06
    if (_allowBle && _bleConnected && _chrCmd != null) {
      try {
        await _chrCmd!.write(utf8.encode(rawJson), withoutResponse: false);
        _statusMessage = 'Sent "$cmdName" via BLE (0xFF06)';
        notifyListeners();
        return true;
      } catch (e) {
        _statusMessage = 'BLE Cmd Error: $e';
        notifyListeners();
      }
    }

    _statusMessage = 'Cannot send command: Disconnected';
    notifyListeners();
    return false;
  }

  Future<bool> triggerMeasureNow() =>
      sendCommandMap({'cmd': 'measure_now'});

  Future<bool> triggerOpenLid({int holdSeconds = 5}) =>
      sendCommandMap({'cmd': 'open_lid', 'hold_s': holdSeconds});

  Future<bool> updateBinConfig(WasteBinConfig cfg) =>
      sendCommandMap(cfg.toCommandJson());

  // -------------------- Custom OLED Animation Upload & Reset --------------------

  /// Uploads a binary .wbin container using LAN HTTP (POST /api/oled/upload)
  /// or BLE GATT characteristic 0xFF07 chunked transfer.
  Future<bool> uploadCustomAnimation(
    Uint8List wbinBytes, {
    void Function(double progress)? onProgress,
  }) async {
    if (wbinBytes.isEmpty) {
      _statusMessage = 'Animation payload is empty';
      notifyListeners();
      return false;
    }

    // Priority 1: Local LAN HTTP Upload
    if (_allowLan && _lanConnected && _lanHost.isNotEmpty) {
      try {
        _statusMessage = 'Uploading ${wbinBytes.length} bytes via LAN HTTP...';
        notifyListeners();

        final uri = Uri.parse('http://$_lanHost:$_lanPort/api/oled/upload');
        final request = http.StreamedRequest('POST', uri);
        request.headers['Content-Type'] = 'application/octet-stream';
        request.contentLength = wbinBytes.length;

        final client = http.Client();
        try {
          final responseFuture = client.send(request);
          const chunkSize = 4096;
          int sent = 0;
          for (int i = 0; i < wbinBytes.length; i += chunkSize) {
            final end = math.min(i + chunkSize, wbinBytes.length);
            request.sink.add(wbinBytes.sublist(i, end));
            sent += (end - i);
            onProgress?.call(sent / wbinBytes.length);
          }
          await request.sink.close();
          final res = await responseFuture.timeout(const Duration(seconds: 15));
          if (res.statusCode == 200) {
            onProgress?.call(1.0);
            _statusMessage = 'Successfully uploaded custom animation via LAN!';
            notifyListeners();
            return true;
          } else {
            _statusMessage = 'LAN Upload Failed: HTTP ${res.statusCode}';
            notifyListeners();
            return false;
          }
        } finally {
          client.close();
        }
      } catch (e) {
        _statusMessage = 'LAN Upload Error: $e';
        _lanConnected = false;
        notifyListeners();
      }
    }

    // Priority 3: BLE GATT Characteristic 0xFF07 Chunked Upload
    if (_allowBle && _bleConnected && _chrUpload != null) {
      try {
        _statusMessage = 'Uploading ${wbinBytes.length} bytes via BLE 0xFF07...';
        notifyListeners();

        const int chunkSize = 244;
        int sent = 0;
        for (int i = 0; i < wbinBytes.length; i += chunkSize) {
          final end = math.min(i + chunkSize, wbinBytes.length);
          final chunk = wbinBytes.sublist(i, end);
          await _chrUpload!.write(chunk, withoutResponse: true);
          sent += (end - i);
          onProgress?.call(sent / wbinBytes.length);
          await Future.delayed(const Duration(milliseconds: 15));
        }

        onProgress?.call(1.0);
        _statusMessage = 'Successfully uploaded custom animation via BLE!';
        notifyListeners();
        return true;
      } catch (e) {
        _statusMessage = 'BLE Upload Error: $e';
        notifyListeners();
        return false;
      }
    }

    _statusMessage = 'Upload unavailable: Neither LAN nor BLE transport active';
    notifyListeners();
    return false;
  }

  /// Resets the active OLED animation back to the compiled Dancing Cat mascot.
  Future<bool> resetCustomAnimation() async {
    // Priority 1: LAN HTTP POST /api/oled/reset
    if (_allowLan && _lanConnected && _lanHost.isNotEmpty) {
      try {
        final uri = Uri.parse('http://$_lanHost:$_lanPort/api/oled/reset');
        final resp = await http.post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({}),
        ).timeout(const Duration(seconds: 4));
        if (resp.statusCode == 200) {
          _statusMessage = 'Reset animation to Mascot via LAN';
          notifyListeners();
          return true;
        }
      } catch (_) {
        _lanConnected = false;
      }
    }

    // Priority 2: MQTT reset_anim
    if (_allowMqtt && _mqttConnected && _mqttClient != null) {
      return sendCommandMap({'cmd': 'reset_anim'});
    }

    // Priority 3: BLE GATT reset_anim
    if (_allowBle && _bleConnected && _chrCmd != null) {
      return sendCommandMap({'cmd': 'reset_anim'});
    }

    _statusMessage = 'Cannot reset animation: Disconnected';
    notifyListeners();
    return false;
  }

  // -------------------- Test Support Hooks --------------------

  @visibleForTesting
  void setMockTransports({
    bool? lan,
    bool? mqtt,
    bool? ble,
    String? lanHost,
    int? lanPort,
    TransportPreference? preferredTransport,
  }) {
    if (lan != null) _lanConnected = lan;
    if (mqtt != null) _mqttConnected = mqtt;
    if (ble != null) _bleConnected = ble;
    if (lanHost != null) _lanHost = lanHost;
    if (lanPort != null) _lanPort = lanPort;
    if (preferredTransport != null) _preferredTransport = preferredTransport;
    notifyListeners();
  }
}
