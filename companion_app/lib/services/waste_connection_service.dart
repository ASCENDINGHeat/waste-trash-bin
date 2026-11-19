import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/device_session.dart';
import '../models/telemetry.dart';

export '../models/device_session.dart';

class WasteConnectionService extends ChangeNotifier {
  static const int maxHistoryEntries = WasteDeviceSession.maxHistoryEntries;
  static const String defaultPlaceholderDeviceId = 'smartbin_s3';

  // V1 legacy preference keys (read once for migration if v2 absent)
  static const String _legacyHistoryKey = 'waste_telemetry_history_v1';
  static const String _legacyDeviceIdKey = 'waste_device_id';
  static const String _legacyLanHostKey = 'waste_lan_host';
  static const String _legacyLanPortKey = 'waste_lan_port';
  static const String _legacyTransportPrefKey = 'waste_transport_preference';

  // V2 multi-device preference keys
  static const String _prefsBrokerKey = 'waste_mqtt_broker_uri';
  static const String _prefsMqttFilterKey = 'waste_mqtt_device_filter';
  static const String _prefsDevicesKey = 'waste_devices_v2';
  static const String _prefsActiveDeviceKey = 'waste_active_device_v2';

  static String _historyKeyFor(String deviceId) =>
      'waste_telemetry_history_v2_$deviceId';

  final Map<String, WasteDeviceSession> _devices = {
    defaultPlaceholderDeviceId:
        WasteDeviceSession(deviceId: defaultPlaceholderDeviceId),
  };
  String _activeDeviceId = defaultPlaceholderDeviceId;

  String _mqttBrokerUri = 'mqtt://broker.emqx.io:1883';
  String _mqttDeviceFilter = '';
  bool _mqttConnected = false;
  MqttServerClient? _mqttClient;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage?>>>? _mqttUpdatesSub;

  String _statusMessage = 'Idle — Connect via LAN, MQTT or BLE';

  WasteConnectionService();

  // -------------------- Device Registry Helpers --------------------

  WasteDeviceSession _ensureDevice(String deviceId) {
    final normalized = deviceId.trim().isNotEmpty
        ? deviceId.trim()
        : defaultPlaceholderDeviceId;
    return _devices.putIfAbsent(
      normalized,
      () => WasteDeviceSession(deviceId: normalized),
    );
  }

  WasteDeviceSession _targetSession(String? deviceId) =>
      _ensureDevice(deviceId ?? _activeDeviceId);

  bool _isUntouchedPlaceholder(WasteDeviceSession? session) =>
      session != null &&
      session.deviceId == defaultPlaceholderDeviceId &&
      !session.lanConnected &&
      !session.bleConnected &&
      session.lanHost.isEmpty &&
      session.latestTelemetry == null &&
      session.history.isEmpty;

  WasteDeviceSession _bindOrMigrateSession(
    WasteDeviceSession current,
    String reportedId, {
    bool selectIfActiveChanged = false,
  }) {
    final id = reportedId.trim();
    if (id.isEmpty || id == current.deviceId) {
      return current;
    }

    if (current.deviceId == defaultPlaceholderDeviceId) {
      final existing = _devices[id];
      if (existing == null) {
        _devices.remove(defaultPlaceholderDeviceId);
        current.deviceId = id;
        _devices[id] = current;
        if (_activeDeviceId == defaultPlaceholderDeviceId) {
          _activeDeviceId = id;
        }
        return current;
      } else {
        if (current.lanHost.isNotEmpty) {
          existing.lanHost = current.lanHost;
          existing.lanPort = current.lanPort;
        }
        if (current.lanConnected) {
          existing.lanConnected = true;
          existing.lanDeviceIp = current.lanDeviceIp;
        }
        current.cancelLanTimer();
        current.lanConnected = false;
        _devices.remove(defaultPlaceholderDeviceId);
        if (_activeDeviceId == defaultPlaceholderDeviceId) {
          _activeDeviceId = id;
        }
        return existing;
      }
    }

    final target = _ensureDevice(id);
    if (selectIfActiveChanged && current.deviceId == _activeDeviceId) {
      _activeDeviceId = id;
    }
    return target;
  }

  // -------------------- Public Getters (Active-Device Facade + Multi-Device) --------------------

  List<WasteDeviceSession> get devices => List.unmodifiable(_devices.values);

  WasteDeviceSession get activeDevice => _ensureDevice(_activeDeviceId);

  WasteDeviceSession? getDevice(String deviceId) => _devices[deviceId.trim()];

  String get activeDeviceId {
    final active = activeDevice;
    return active.latestTelemetry?.deviceId.isNotEmpty == true
        ? active.latestTelemetry!.deviceId
        : active.deviceId;
  }

  String get mqttBrokerUri => _mqttBrokerUri;
  String get mqttDeviceFilter => _mqttDeviceFilter;
  String get lanHost => activeDevice.lanHost;
  int get lanPort => activeDevice.lanPort;
  String get lanDeviceIp => activeDevice.lanDeviceIp;
  TransportPreference get preferredTransport => activeDevice.preferredTransport;

  bool get isLanConnected => activeDevice.lanConnected;
  bool get isLanConnecting => activeDevice.lanConnecting;
  bool get isMqttConnected => _mqttConnected;
  bool get isBleConnected => activeDevice.bleConnected;
  bool get isNodeOnline => activeDevice.isOnline();
  String get statusMessage => _statusMessage;
  WasteTelemetry? get latestTelemetry => activeDevice.latestTelemetry;
  List<WasteTelemetry> get history => List.unmodifiable(activeDevice.history);

  /// Tri-Mode Transport Priority Resolver for the active device:
  /// Auto: Priority 1 (Local LAN) -> Priority 2 (Cloud MQTT) -> Priority 3 (Direct BLE)
  /// Manual: Uses only the selected transport without silent fallback.
  TransportMode get transportMode =>
      activeDevice.resolveTransportMode(mqttBrokerConnected: _mqttConnected);

  /// UI Purpose
  int get totalEmptyBin => _devices.values
      .where((d) => d.isOnline() && !(d.latestTelemetry?.fullAlert ?? false))
      .length;
  int get totalFullBin => _devices.values
      .where((d) => d.isOnline() && (d.latestTelemetry?.fullAlert ?? false))
      .length;
  int get totalOffBin => _devices.values.where((d) => !d.isOnline()).length;
  // -------------------- Multi-Device Lifecycle & Persistence --------------------

  Future<void> _persistRegistry() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list =
          _devices.values.map((d) => jsonEncode(d.toMetadataJson())).toList();
      await prefs.setStringList(_prefsDevicesKey, list);
      await prefs.setString(_prefsActiveDeviceKey, _activeDeviceId);
    } catch (_) {}
  }

  Future<void> _persistDeviceHistory(WasteDeviceSession session) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded =
          session.history.map((e) => jsonEncode(e.toJson())).toList();
      await prefs.setStringList(_historyKeyFor(session.deviceId), encoded);
    } catch (_) {}
  }

  Future<void> selectActiveDevice(String deviceId) async {
    final session = _ensureDevice(deviceId);
    _activeDeviceId = session.deviceId;
    _statusMessage = 'Active node: ${session.displayName}';
    notifyListeners();
    await _persistRegistry();
  }

  Future<WasteDeviceSession> registerDevice({
    required String deviceId,
    String? alias,
    String? lanHost,
    int? lanPort,
    bool makeActive = false,
  }) async {
    final normalizedId = deviceId.trim();
    if (_devices.length == 1 &&
        _isUntouchedPlaceholder(_devices[defaultPlaceholderDeviceId]) &&
        normalizedId != defaultPlaceholderDeviceId &&
        normalizedId.isNotEmpty) {
      _devices.remove(defaultPlaceholderDeviceId);
      if (_activeDeviceId == defaultPlaceholderDeviceId) {
        _activeDeviceId = normalizedId;
      }
    }

    final session = _ensureDevice(normalizedId);
    if (alias != null) session.alias = alias.trim();
    if (lanHost != null && lanHost.trim().isNotEmpty) {
      session.lanHost = _sanitizeHost(lanHost).host;
    }
    if (lanPort != null && lanPort > 0 && lanPort <= 65535) {
      session.lanPort = lanPort;
    }
    if (makeActive) {
      _activeDeviceId = session.deviceId;
    }
    notifyListeners();
    await _persistRegistry();
    return session;
  }

  Future<void> setDeviceAlias(String deviceId, String alias) async {
    final session = _ensureDevice(deviceId);
    session.alias = alias.trim();
    notifyListeners();
    await _persistRegistry();
  }

  Future<void> removeDevice(String deviceId) async {
    final id = deviceId.trim();
    final session = _devices[id];
    if (session == null) return;

    session.cancelLanTimer();
    session.lanConnected = false;
    await session.closeBleResources();
    _devices.remove(id);

    if (_devices.isEmpty) {
      _devices[defaultPlaceholderDeviceId] =
          WasteDeviceSession(deviceId: defaultPlaceholderDeviceId);
      _activeDeviceId = defaultPlaceholderDeviceId;
    } else if (_activeDeviceId == id) {
      _activeDeviceId = _devices.keys.first;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_historyKeyFor(id));
    } catch (_) {}

    notifyListeners();
    await _persistRegistry();
  }

  Future<void> setTransportPreference(
    TransportPreference pref, {
    String? deviceId,
  }) async {
    final session = _targetSession(deviceId);
    session.preferredTransport = pref;
    switch (pref) {
      case TransportPreference.auto:
        _statusMessage =
            '${session.displayName}: Transport Auto (LAN -> MQTT -> BLE)';
        break;
      case TransportPreference.lan:
        _statusMessage = session.lanConnected
            ? '${session.displayName}: Pinned to LAN (http://${session.lanHost}:${session.lanPort})'
            : '${session.displayName}: Pinned to LAN (Disconnected)';
        break;
      case TransportPreference.mqtt:
        _statusMessage = _mqttConnected
            ? '${session.displayName}: Pinned to Cloud MQTT'
            : '${session.displayName}: Pinned to Cloud MQTT (Disconnected)';
        break;
      case TransportPreference.ble:
        _statusMessage = session.bleConnected
            ? '${session.displayName}: Pinned to Direct BLE'
            : '${session.displayName}: Pinned to Direct BLE (Disconnected)';
        break;
    }
    notifyListeners();
    await _persistRegistry();
  }

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _mqttBrokerUri = prefs.getString(_prefsBrokerKey) ?? _mqttBrokerUri;
    _mqttDeviceFilter = prefs.getString(_prefsMqttFilterKey) ??
        prefs.getString(_legacyDeviceIdKey) ??
        '';

    final savedDevices = prefs.getStringList(_prefsDevicesKey);
    if (savedDevices != null && savedDevices.isNotEmpty) {
      _devices.clear();
      for (final raw in savedDevices) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, dynamic>) {
            final session = WasteDeviceSession.fromMetadataJson(decoded);
            _devices[session.deviceId] = session;
          }
        } catch (_) {}
      }
      if (_devices.isEmpty) {
        _devices[defaultPlaceholderDeviceId] =
            WasteDeviceSession(deviceId: defaultPlaceholderDeviceId);
      }
      final savedActive = prefs.getString(_prefsActiveDeviceKey);
      _activeDeviceId =
          (savedActive != null && _devices.containsKey(savedActive))
              ? savedActive
              : _devices.keys.first;

      for (final session in _devices.values) {
        final histRaw =
            prefs.getStringList(_historyKeyFor(session.deviceId)) ?? [];
        session.history.clear();
        for (final item in histRaw) {
          final parsed = WasteTelemetry.tryParse(item);
          if (parsed != null) {
            session.history.add(parsed);
          }
        }
        if (session.history.isNotEmpty) {
          session.latestTelemetry = session.history.last;
        }
      }
    } else {
      // One-time migration from V1 single-device preferences
      final legacyId = prefs.getString(_legacyDeviceIdKey)?.trim() ?? '';
      final initialId =
          legacyId.isNotEmpty ? legacyId : defaultPlaceholderDeviceId;
      final session = WasteDeviceSession(
        deviceId: initialId,
        lanHost: prefs.getString(_legacyLanHostKey) ?? '',
        lanPort: prefs.getInt(_legacyLanPortKey) ?? 80,
      );

      final prefName = prefs.getString(_legacyTransportPrefKey);
      if (prefName != null) {
        for (final v in TransportPreference.values) {
          if (v.name == prefName) {
            session.preferredTransport = v;
            break;
          }
        }
      }

      final rawList = prefs.getStringList(_legacyHistoryKey) ?? [];
      for (final item in rawList) {
        final parsed = WasteTelemetry.tryParse(item);
        if (parsed != null) {
          session.addTelemetry(parsed);
        }
      }

      _devices
        ..clear()
        ..[initialId] = session;
      _activeDeviceId = initialId;
      await _persistRegistry();
      if (session.history.isNotEmpty) {
        await _persistDeviceHistory(session);
      }
    }

    notifyListeners();

    // Auto-reconnect any saved LAN endpoints on startup
    for (final session in List<WasteDeviceSession>.from(_devices.values)) {
      if (session.lanHost.isNotEmpty && session.allowLan) {
        unawaited(connectLan(deviceId: session.deviceId));
      }
    }
  }

  Future<void> _recordTelemetry(
    WasteTelemetry t, {
    String? deviceId,
  }) async {
    final targetId =
        (t.deviceId.isNotEmpty ? t.deviceId : (deviceId ?? _activeDeviceId));
    WasteDeviceSession session;

    if (_devices.length == 1 &&
        _isUntouchedPlaceholder(_devices[defaultPlaceholderDeviceId]) &&
        targetId != defaultPlaceholderDeviceId) {
      session = _bindOrMigrateSession(
        _devices[defaultPlaceholderDeviceId]!,
        targetId,
      );
      await _persistRegistry();
    } else {
      session = _ensureDevice(targetId);
    }

    session.addTelemetry(t);
    notifyListeners();
    await _persistDeviceHistory(session);
  }

  Future<void> clearHistory({String? deviceId}) async {
    final session = _targetSession(deviceId);
    session.history.clear();
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_historyKeyFor(session.deviceId));
    } catch (_) {}
  }

  // -------------------- Priority 1: Local LAN HTTP Transport --------------------

  ({String host, int? port}) _sanitizeHost(String raw) {
    var cleaned = raw.trim();
    cleaned =
        cleaned.replaceFirst(RegExp(r'^https?://', caseSensitive: false), '');
    final slashIdx = cleaned.indexOf('/');
    if (slashIdx != -1) {
      cleaned = cleaned.substring(0, slashIdx);
    }
    int? parsedPort;
    final colonIdx = cleaned.lastIndexOf(':');
    if (colonIdx > 0 && colonIdx < cleaned.length - 1) {
      final maybePort = int.tryParse(cleaned.substring(colonIdx + 1));
      if (maybePort != null && maybePort > 0 && maybePort <= 65535) {
        cleaned = cleaned.substring(0, colonIdx);
        parsedPort = maybePort;
      }
    }
    return (host: cleaned, port: parsedPort);
  }

  Future<bool> connectLan({
    String? host,
    int? port,
    String? deviceId,
  }) async {
    var session = _targetSession(deviceId);
    final explicitDeviceTarget = deviceId != null;

    if (host != null) {
      final sanitized = _sanitizeHost(host);
      port ??= sanitized.port;
      if (sanitized.host.isNotEmpty) {
        session.lanHost = sanitized.host;
      }
    }
    if (port != null && port > 0 && port <= 65535) {
      session.lanPort = port;
    }

    if (session.lanHost.isEmpty) {
      _statusMessage = 'LAN Error: Host IP/hostname cannot be empty';
      notifyListeners();
      return false;
    }

    session.lanConnecting = true;
    _statusMessage =
        'Connecting LAN (http://${session.lanHost}:${session.lanPort})...';
    notifyListeners();
    await _persistRegistry();

    final hostSnapshot = session.lanHost;
    final portSnapshot = session.lanPort;

    try {
      final uri = Uri.parse('http://$hostSnapshot:$portSnapshot/api/status');
      final resp = await http.get(uri).timeout(const Duration(seconds: 4));
      if (resp.statusCode == 200) {
        String reportedIp = '';
        String reportedId = '';
        try {
          final decoded = jsonDecode(resp.body);
          if (decoded is Map<String, dynamic>) {
            reportedId = (decoded['device_id'] as String?)?.trim() ?? '';
            reportedIp = (decoded['ip'] as String?)?.trim() ?? '';
          }
        } catch (_) {}

        if (reportedId.isNotEmpty && reportedId != session.deviceId) {
          final resolvedSession = _bindOrMigrateSession(
            session,
            reportedId,
            selectIfActiveChanged: !explicitDeviceTarget,
          );
          if (resolvedSession != session) {
            session.lanConnecting = false;
            resolvedSession.lanHost = hostSnapshot;
            resolvedSession.lanPort = portSnapshot;
            session = resolvedSession;
          }
        }

        if (reportedIp.isNotEmpty) {
          session.lanDeviceIp = reportedIp;
        }
        session.lanConnected = true;

        final parsed = WasteTelemetry.tryParse(resp.body);
        if (parsed != null) {
          await _recordTelemetry(parsed, deviceId: session.deviceId);
        }
        await _persistRegistry();

        _statusMessage =
            '${session.displayName}: LAN Connected (http://$hostSnapshot:$portSnapshot)';
        _startLanPolling(session);
        return true;
      } else {
        session.lanConnected = false;
        _statusMessage = 'LAN Error: HTTP ${resp.statusCode}';
        return false;
      }
    } catch (e) {
      session.lanConnected = false;
      _statusMessage = 'LAN Connection Failed: $e';
      return false;
    } finally {
      session.lanConnecting = false;
      notifyListeners();
    }
  }

  /// Probes mDNS .local hostnames (e.g. smartbin_s3_XXXXXX.local) for port 80.
  Future<bool> probeMdnsLan({int port = 80, String? deviceId}) async {
    final session = _targetSession(deviceId);
    final candidates = <String>[
      if (session.deviceId.isNotEmpty) '${session.deviceId}.local',
      if (session.lanHost.isNotEmpty &&
          session.lanHost != '${session.deviceId}.local')
        session.lanHost,
      if (session.deviceId != defaultPlaceholderDeviceId)
        '$defaultPlaceholderDeviceId.local',
    ];
    for (final candidate in candidates.toSet()) {
      final ok = await connectLan(
        host: candidate,
        port: port,
        deviceId: deviceId,
      );
      if (ok) return true;
    }
    return false;
  }

  void _startLanPolling(WasteDeviceSession session) {
    session.cancelLanTimer();
    session.lanPollTimer =
        Timer.periodic(const Duration(seconds: 4), (_) async {
      if (!session.lanConnected || session.lanHost.isEmpty) {
        session.cancelLanTimer();
        return;
      }
      try {
        final uri = Uri.parse(
            'http://${session.lanHost}:${session.lanPort}/api/status');
        final resp = await http.get(uri).timeout(const Duration(seconds: 3));
        if (resp.statusCode == 200) {
          final parsed = WasteTelemetry.tryParse(resp.body);
          if (parsed != null) {
            await _recordTelemetry(parsed, deviceId: session.deviceId);
          }
        } else {
          session.lanConnected = false;
          notifyListeners();
        }
      } catch (_) {
        session.lanConnected = false;
        notifyListeners();
      }
    });
  }

  void disconnectLan({String? deviceId}) {
    final session = _targetSession(deviceId);
    session.cancelLanTimer();
    session.lanConnected = false;
    _statusMessage = _mqttConnected
        ? '${session.displayName}: MQTT Active'
        : (session.bleConnected
            ? '${session.displayName}: BLE Active'
            : '${session.displayName}: LAN Disconnected');
    notifyListeners();
  }

  // -------------------- Priority 2: Shared Cloud MQTT Transport --------------------

  Future<void> connectMqtt({String? brokerUri, String? deviceId}) async {
    if (brokerUri != null && brokerUri.trim().isNotEmpty) {
      _mqttBrokerUri = brokerUri.trim();
    }
    if (deviceId != null) {
      _mqttDeviceFilter = deviceId.trim();
      if (_mqttDeviceFilter.isNotEmpty &&
          _mqttDeviceFilter != defaultPlaceholderDeviceId) {
        await registerDevice(
          deviceId: _mqttDeviceFilter,
          makeActive:
              _isUntouchedPlaceholder(_devices[defaultPlaceholderDeviceId]),
        );
      }
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsBrokerKey, _mqttBrokerUri);
      await prefs.setString(_prefsMqttFilterKey, _mqttDeviceFilter);
    } catch (_) {}

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
      final active = activeDevice;
      _statusMessage = active.lanConnected
          ? 'LAN Active'
          : (active.bleConnected ? 'BLE Failover Active' : 'MQTT Disconnected');
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
      await _mqttUpdatesSub?.cancel();
      _mqttUpdatesSub = client.updates?.listen(_onMqttMessage);
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
    final filter = _mqttDeviceFilter.isNotEmpty ? _mqttDeviceFilter : '+';
    c.subscribe('smartbin/$filter/telemetry', MqttQos.atLeastOnce);
    c.subscribe('smartbin/$filter/alert', MqttQos.atLeastOnce);
    c.subscribe('smartbin/$filter/status', MqttQos.atLeastOnce);
  }

  String _extractDeviceIdFromTopic(String topic) {
    final parts = topic.split('/');
    if (parts.length >= 3 && parts[0] == 'smartbin') {
      return parts[1].trim();
    }
    return '';
  }

  void _onMqttMessage(List<MqttReceivedMessage<MqttMessage?>>? events) {
    if (events == null) return;
    for (final rec in events) {
      final pubMsg = rec.payload as MqttPublishMessage?;
      if (pubMsg == null) continue;
      final payload =
          MqttPublishPayload.bytesToStringAsString(pubMsg.payload.message);
      final topic = rec.topic;
      final topicDeviceId = _extractDeviceIdFromTopic(topic);

      if (topic.endsWith('/telemetry')) {
        final t = WasteTelemetry.tryParse(payload);
        if (t != null) {
          final id = t.deviceId.isNotEmpty ? t.deviceId : topicDeviceId;
          final session = _devices.length == 1 &&
                  _isUntouchedPlaceholder(
                      _devices[defaultPlaceholderDeviceId]) &&
                  id.isNotEmpty
              ? _bindOrMigrateSession(_devices[defaultPlaceholderDeviceId]!, id)
              : _ensureDevice(id);
          session.nodeOnlineLwt = true;
          unawaited(_recordTelemetry(t, deviceId: session.deviceId));
        }
      } else if (topic.endsWith('/status') && topicDeviceId.isNotEmpty) {
        final session = _devices.length == 1 &&
                _isUntouchedPlaceholder(_devices[defaultPlaceholderDeviceId])
            ? _bindOrMigrateSession(
                _devices[defaultPlaceholderDeviceId]!, topicDeviceId)
            : _ensureDevice(topicDeviceId);
        session.nodeOnlineLwt = payload.trim() == 'online';
        notifyListeners();
      }
    }
  }

  void disconnectMqtt() {
    unawaited(_mqttUpdatesSub?.cancel());
    _mqttUpdatesSub = null;
    _mqttClient?.disconnect();
    _mqttClient = null;
    _mqttConnected = false;
    notifyListeners();
  }

  // -------------------- Priority 3: Per-Device BLE GATT Transport (0xFF00 - 0xFF07) --------------------

  bool _matchesUuid16(Guid guid, String hex4) {
    final s = guid.toString().toLowerCase();
    return s == hex4.toLowerCase() ||
        s.startsWith('0000${hex4.toLowerCase()}-0000-1000-8000');
  }

  Future<bool> connectBleDevice(
    BluetoothDevice device, {
    String? deviceId,
  }) async {
    final platformName = device.platformName.trim();
    final inferredId = (deviceId != null && deviceId.trim().isNotEmpty)
        ? deviceId.trim()
        : (platformName.toLowerCase().contains('smartbin')
            ? platformName
            : _activeDeviceId);

    final session = _devices.length == 1 &&
            _isUntouchedPlaceholder(_devices[defaultPlaceholderDeviceId]) &&
            inferredId != defaultPlaceholderDeviceId
        ? _bindOrMigrateSession(
            _devices[defaultPlaceholderDeviceId]!, inferredId)
        : _ensureDevice(inferredId);

    await disconnectBle(deviceId: session.deviceId);
    _statusMessage = 'Connecting BLE to ${device.platformName}...';
    notifyListeners();

    try {
      await device.connect(timeout: const Duration(seconds: 10));
      session.bleDevice = device;

      try {
        await device.requestMtu(247);
      } catch (_) {}

      session.bleConnSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          session.bleConnected = false;
          _statusMessage = session.lanConnected
              ? '${session.displayName}: LAN Active'
              : (_mqttConnected
                  ? '${session.displayName}: MQTT Connected'
                  : 'BLE Disconnected from ${device.platformName}');
          notifyListeners();
        }
      });

      final services = await device.discoverServices();
      for (final svc in services) {
        if (_matchesUuid16(svc.uuid, 'ff00')) {
          for (final chr in svc.characteristics) {
            if (_matchesUuid16(chr.uuid, 'ff01')) session.chrSsid = chr;
            if (_matchesUuid16(chr.uuid, 'ff02')) session.chrPass = chr;
            if (_matchesUuid16(chr.uuid, 'ff03')) session.chrMqtt = chr;
            if (_matchesUuid16(chr.uuid, 'ff04')) session.chrApply = chr;
            if (_matchesUuid16(chr.uuid, 'ff05')) session.chrTelem = chr;
            if (_matchesUuid16(chr.uuid, 'ff06')) session.chrCmd = chr;
            if (_matchesUuid16(chr.uuid, 'ff07')) session.chrUpload = chr;
          }
        }
      }

      if (session.chrTelem != null) {
        final initialBytes = await session.chrTelem!.read();
        final initialStr = utf8.decode(initialBytes, allowMalformed: true);
        final t = WasteTelemetry.tryParse(initialStr);
        if (t != null) {
          await _recordTelemetry(t, deviceId: session.deviceId);
        }

        await session.chrTelem!.setNotifyValue(true);
        session.bleTelemSub = session.chrTelem!.onValueReceived.listen((bytes) {
          final jsonStr = utf8.decode(bytes, allowMalformed: true);
          final parsed = WasteTelemetry.tryParse(jsonStr);
          if (parsed != null) {
            unawaited(_recordTelemetry(parsed, deviceId: session.deviceId));
          }
        });
      }

      session.bleConnected = true;
      _activeDeviceId = session.deviceId;
      await _persistRegistry();
      _statusMessage = 'BLE Connected (${device.platformName})';
      notifyListeners();
      return true;
    } catch (e) {
      session.bleConnected = false;
      _statusMessage = 'BLE Connection Failed: $e';
      notifyListeners();
      return false;
    }
  }

  Future<Map<String, String>> readBleProvisioningConfig({
    String? deviceId,
  }) async {
    final session = _targetSession(deviceId);
    String ssid = '';
    String mqtt = _mqttBrokerUri;
    try {
      if (session.chrSsid != null) {
        ssid = utf8.decode(
          await session.chrSsid!.read(),
          allowMalformed: true,
        );
      }
      if (session.chrMqtt != null) {
        final m = utf8.decode(
          await session.chrMqtt!.read(),
          allowMalformed: true,
        );
        if (m.isNotEmpty) mqtt = m;
      }
    } catch (_) {}
    return {'ssid': ssid, 'mqtt_uri': mqtt};
  }

  Future<bool> provisionOverBle({
    required String wifiSsid,
    required String wifiPass,
    required String mqttUri,
    String? deviceId,
  }) async {
    final session = _targetSession(deviceId);
    if (!session.bleConnected) return false;
    try {
      if (session.chrSsid != null) {
        await session.chrSsid!
            .write(utf8.encode(wifiSsid), withoutResponse: false);
      }
      if (session.chrPass != null && wifiPass.isNotEmpty) {
        await session.chrPass!
            .write(utf8.encode(wifiPass), withoutResponse: false);
      }
      if (session.chrMqtt != null && mqttUri.isNotEmpty) {
        await session.chrMqtt!
            .write(utf8.encode(mqttUri), withoutResponse: false);
      }
      if (session.chrApply != null) {
        await session.chrApply!.write([0x01], withoutResponse: false);
      }
      _statusMessage =
          'Provisioned ${session.displayName} Wi-Fi & MQTT via BLE!';
      notifyListeners();
      return true;
    } catch (e) {
      _statusMessage = 'BLE Provisioning Error: $e';
      notifyListeners();
      return false;
    }
  }

  Future<void> disconnectBle({String? deviceId}) async {
    final session = _targetSession(deviceId);
    await session.closeBleResources();
    notifyListeners();
  }

  // -------------------- Tri-Mode Unified Command Routing --------------------

  /// Sends a command dictionary honoring Tri-Mode priority and user selection:
  /// Priority 1 (LAN HTTP) -> Priority 2 (Cloud MQTT) -> Priority 3 (Direct BLE)
  Future<bool> sendCommandMap(
    Map<String, dynamic> cmdPayload, {
    String? deviceId,
  }) async {
    final session = _targetSession(deviceId);
    final rawJson = jsonEncode(cmdPayload);
    final cmdName = cmdPayload['cmd'] ?? cmdPayload['action'] ?? 'cmd';

    // 1. Priority 1: Local LAN HTTP REST
    if (session.allowLan &&
        session.lanConnected &&
        session.lanHost.isNotEmpty) {
      try {
        Uri uri;
        String? body;
        final base = 'http://${session.lanHost}:${session.lanPort}';
        if (cmdName == 'open_lid' || cmdPayload['action'] == 'open') {
          uri = Uri.parse('$base/api/lid');
          body = jsonEncode({
            'action': 'open',
            'hold_s': cmdPayload['hold_s'] ?? 5,
          });
        } else if (cmdName == 'measure_now') {
          uri = Uri.parse('$base/api/measure');
          body = jsonEncode({});
        } else if (cmdName == 'configure') {
          uri = Uri.parse('$base/api/config');
          body = rawJson;
        } else if (cmdName == 'reset_anim') {
          uri = Uri.parse('$base/api/oled/reset');
          body = jsonEncode({});
        } else {
          uri = Uri.parse('$base/api/cmd');
          body = rawJson;
        }

        final resp = await http
            .post(
              uri,
              headers: {'Content-Type': 'application/json'},
              body: body,
            )
            .timeout(const Duration(seconds: 4));

        if (resp.statusCode == 200) {
          _statusMessage = 'Sent "$cmdName" to ${session.displayName} via LAN';
          final parsed = WasteTelemetry.tryParse(resp.body);
          if (parsed != null) {
            await _recordTelemetry(parsed, deviceId: session.deviceId);
          }
          notifyListeners();
          return true;
        }
      } catch (_) {
        // LAN failed; fall through to Priority 2 (MQTT) if Auto
        session.lanConnected = false;
      }
    }

    // 2. Priority 2: Cloud MQTT
    if (session.allowMqtt && _mqttConnected && _mqttClient != null) {
      try {
        final builder = MqttClientPayloadBuilder();
        builder.addUTF8String(rawJson);
        final topic = 'smartbin/${session.deviceId}/cmd';
        _mqttClient!
            .publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
        _statusMessage = 'Sent "$cmdName" via MQTT ($topic)';
        notifyListeners();
        return true;
      } catch (_) {
        // Fall through to Priority 3 (BLE) if Auto
      }
    }

    // 3. Priority 3: Direct BLE GATT 0xFF06
    if (session.allowBle && session.bleConnected && session.chrCmd != null) {
      try {
        await session.chrCmd!
            .write(utf8.encode(rawJson), withoutResponse: false);
        _statusMessage =
            'Sent "$cmdName" to ${session.displayName} via BLE (0xFF06)';
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

  Future<bool> triggerMeasureNow({String? deviceId}) =>
      sendCommandMap({'cmd': 'measure_now'}, deviceId: deviceId);

  Future<bool> triggerOpenLid({int holdSeconds = 5, String? deviceId}) =>
      sendCommandMap(
        {'cmd': 'open_lid', 'hold_s': holdSeconds},
        deviceId: deviceId,
      );

  Future<bool> updateBinConfig(WasteBinConfig cfg, {String? deviceId}) =>
      sendCommandMap(cfg.toCommandJson(), deviceId: deviceId);

  // -------------------- Custom OLED Animation Upload & Reset --------------------

  /// Uploads a binary .wbin container using LAN HTTP (POST /api/oled/upload)
  /// or BLE GATT characteristic 0xFF07 chunked transfer.
  Future<bool> uploadCustomAnimation(
    Uint8List wbinBytes, {
    void Function(double progress)? onProgress,
    String? deviceId,
  }) async {
    if (wbinBytes.isEmpty) {
      _statusMessage = 'Animation payload is empty';
      notifyListeners();
      return false;
    }

    final session = _targetSession(deviceId);

    // Priority 1: Local LAN HTTP Upload
    if (session.allowLan &&
        session.lanConnected &&
        session.lanHost.isNotEmpty) {
      try {
        _statusMessage =
            'Uploading ${wbinBytes.length} bytes to ${session.displayName} via LAN...';
        notifyListeners();

        final uri = Uri.parse(
            'http://${session.lanHost}:${session.lanPort}/api/oled/upload');
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
            _statusMessage =
                'Uploaded custom animation to ${session.displayName} via LAN!';
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
        session.lanConnected = false;
        notifyListeners();
      }
    }

    // Priority 3: BLE GATT Characteristic 0xFF07 Chunked Upload
    if (session.allowBle && session.bleConnected && session.chrUpload != null) {
      try {
        _statusMessage =
            'Uploading ${wbinBytes.length} bytes to ${session.displayName} via BLE 0xFF07...';
        notifyListeners();

        const int chunkSize = 244;
        int sent = 0;
        for (int i = 0; i < wbinBytes.length; i += chunkSize) {
          final end = math.min(i + chunkSize, wbinBytes.length);
          final chunk = wbinBytes.sublist(i, end);
          await session.chrUpload!.write(chunk, withoutResponse: true);
          sent += (end - i);
          onProgress?.call(sent / wbinBytes.length);
          await Future.delayed(const Duration(milliseconds: 15));
        }

        onProgress?.call(1.0);
        _statusMessage =
            'Uploaded custom animation to ${session.displayName} via BLE!';
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
  Future<bool> resetCustomAnimation({String? deviceId}) async {
    final session = _targetSession(deviceId);

    // Priority 1: LAN HTTP POST /api/oled/reset
    if (session.allowLan &&
        session.lanConnected &&
        session.lanHost.isNotEmpty) {
      try {
        final uri = Uri.parse(
            'http://${session.lanHost}:${session.lanPort}/api/oled/reset');
        final resp = await http
            .post(
              uri,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({}),
            )
            .timeout(const Duration(seconds: 4));
        if (resp.statusCode == 200) {
          _statusMessage = 'Reset animation to Mascot via LAN';
          notifyListeners();
          return true;
        }
      } catch (_) {
        session.lanConnected = false;
      }
    }

    // Priority 2: MQTT reset_anim
    if (session.allowMqtt && _mqttConnected && _mqttClient != null) {
      return sendCommandMap({'cmd': 'reset_anim'}, deviceId: session.deviceId);
    }

    // Priority 3: BLE GATT reset_anim
    if (session.allowBle && session.bleConnected && session.chrCmd != null) {
      return sendCommandMap({'cmd': 'reset_anim'}, deviceId: session.deviceId);
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
    bool? nodeOnlineLwt,
    String? lanHost,
    int? lanPort,
    TransportPreference? preferredTransport,
    String? deviceId,
    WasteTelemetry? latestTelemetry,
  }) {
    final session = _targetSession(deviceId);
    if (lan != null) session.lanConnected = lan;
    if (mqtt != null) _mqttConnected = mqtt;
    if (ble != null) session.bleConnected = ble;
    if (nodeOnlineLwt != null) session.nodeOnlineLwt = nodeOnlineLwt;
    if (lanHost != null) session.lanHost = lanHost;
    if (lanPort != null) session.lanPort = lanPort;
    if (preferredTransport != null) {
      session.preferredTransport = preferredTransport;
    }
    if (latestTelemetry != null) {
      session.addTelemetry(latestTelemetry);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    for (final session in _devices.values) {
      session.cancelLanTimer();
      unawaited(session.closeBleResources());
    }
    unawaited(_mqttUpdatesSub?.cancel());
    _mqttUpdatesSub = null;
    _mqttClient?.disconnect();
    _mqttClient = null;
    super.dispose();
  }
}
