import 'dart:convert';

class WasteTelemetry {
  final String deviceId;
  final String trigger;
  final int fillPercent;
  final double distanceCm;
  final bool fullAlert;
  final String lidState;
  final int openCycles;
  final int wifiRssi;
  final int uptimeS;
  final DateTime timestamp;

  const WasteTelemetry({
    required this.deviceId,
    required this.trigger,
    required this.fillPercent,
    required this.distanceCm,
    required this.fullAlert,
    required this.lidState,
    required this.openCycles,
    required this.wifiRssi,
    required this.uptimeS,
    required this.timestamp,
  });

  factory WasteTelemetry.fromJson(Map<String, dynamic> json) {
    return WasteTelemetry(
      deviceId: (json['device_id'] as String?) ?? 'smartbin_s3',
      trigger: (json['trigger'] as String?) ?? 'periodic',
      fillPercent: ((json['fill_percent'] as num?) ?? 0).toInt().clamp(0, 100),
      distanceCm: ((json['distance_cm'] as num?) ?? 30.0).toDouble(),
      fullAlert: (json['full_alert'] as bool?) ?? false,
      lidState: (json['lid_state'] as String?) ?? 'closed',
      openCycles: ((json['open_cycles'] as num?) ?? 0).toInt(),
      wifiRssi: ((json['wifi_rssi'] as num?) ?? -127).toInt(),
      uptimeS: ((json['uptime_s'] as num?) ?? 0).toInt(),
      timestamp: json['timestamp_ms'] != null
          ? DateTime.fromMillisecondsSinceEpoch((json['timestamp_ms'] as num).toInt())
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'device_id': deviceId,
        'trigger': trigger,
        'fill_percent': fillPercent,
        'distance_cm': distanceCm,
        'full_alert': fullAlert,
        'lid_state': lidState,
        'open_cycles': openCycles,
        'wifi_rssi': wifiRssi,
        'uptime_s': uptimeS,
        'timestamp_ms': timestamp.millisecondsSinceEpoch,
      };

  static WasteTelemetry? tryParse(String rawJson) {
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is Map<String, dynamic> && decoded.containsKey('fill_percent')) {
        return WasteTelemetry.fromJson(decoded);
      }
    } catch (_) {}
    return null;
  }
}

class WasteBinConfig {
  final double fullCm;
  final double emptyCm;
  final int periodicIntervalS;
  final int oledSleepTimeoutS;

  const WasteBinConfig({
    this.fullCm = 10.0,
    this.emptyCm = 30.0,
    this.periodicIntervalS = 900,
    this.oledSleepTimeoutS = 0,
  });

  Map<String, dynamic> toCommandJson() => {
        'cmd': 'configure',
        'full_cm': fullCm,
        'empty_cm': emptyCm,
        'periodic_interval_s': periodicIntervalS,
        'oled_sleep_timeout_s': oledSleepTimeoutS,
      };
}
