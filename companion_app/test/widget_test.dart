import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:waste_companion/main.dart';
import 'package:waste_companion/models/telemetry.dart';
import 'package:waste_companion/services/waste_connection_service.dart';

void main() {
  group('WasteTelemetry Model & Protocol Tests', () {
    test('Parses valid ESP32-S3 cJSON telemetry payload and round-trips toJson', () {
      const raw =
          '{"device_id":"smartbin_s3_a1b2c3","trigger":"lid_close","fill_percent":75,"distance_cm":15.0,"full_alert":false,"lid_state":"closed","open_cycles":42,"wifi_rssi":-58,"uptime_s":3600}';
      final parsed = WasteTelemetry.tryParse(raw);
      expect(parsed, isNotNull);
      expect(parsed!.deviceId, 'smartbin_s3_a1b2c3');
      expect(parsed.trigger, 'lid_close');
      expect(parsed.fillPercent, 75);
      expect(parsed.distanceCm, 15.0);
      expect(parsed.fullAlert, isFalse);
      expect(parsed.lidState, 'closed');
      expect(parsed.openCycles, 42);
      expect(parsed.wifiRssi, -58);
      expect(parsed.uptimeS, 3600);

      final roundTrip = WasteTelemetry.tryParse(jsonEncode(parsed.toJson()));
      expect(roundTrip, isNotNull);
      expect(roundTrip!.deviceId, 'smartbin_s3_a1b2c3');
      expect(roundTrip.fillPercent, 75);
      expect(roundTrip.openCycles, 42);
    });

    test('Ignores initial BLE booting placeholder and malformed JSON gracefully', () {
      expect(WasteTelemetry.tryParse('{"status":"booting"}'), isNull);
      expect(WasteTelemetry.tryParse('{"alert":"bin_full"}'), isNull);
      expect(WasteTelemetry.tryParse('not_valid_json'), isNull);
      expect(WasteTelemetry.tryParse(''), isNull);
    });

    test('Clamps out-of-range fill_percent values to [0, 100]', () {
      final low = WasteTelemetry.tryParse('{"fill_percent":-20,"distance_cm":35.0}');
      final high = WasteTelemetry.tryParse('{"fill_percent":135,"distance_cm":5.0}');
      expect(low, isNotNull);
      expect(high, isNotNull);
      expect(low!.fillPercent, 0);
      expect(high!.fillPercent, 100);
    });
  });

  group('WasteBinConfig Command Serialization Tests', () {
    test('toCommandJson matches firmware handle_mqtt_cmd_payload schema', () {
      const cfg = WasteBinConfig(
        fullCm: 10.0,
        emptyCm: 30.0,
        periodicIntervalS: 900,
        oledSleepTimeoutS: 30,
      );
      final cmd = cfg.toCommandJson();
      expect(cmd['cmd'], 'configure');
      expect(cmd['full_cm'], 10.0);
      expect(cmd['empty_cm'], 30.0);
      expect(cmd['periodic_interval_s'], 900);
      expect(cmd['oled_sleep_timeout_s'], 30);
    });
  });

  group('WasteConnectionService Local History & State Tests', () {
    test('Loads persisted telemetry history from SharedPreferences and clears cleanly', () async {
      final sampleEvents = [
        jsonEncode({
          'device_id': 'smartbin_s3_ff0011',
          'trigger': 'periodic',
          'fill_percent': 40,
          'distance_cm': 22.0,
          'full_alert': false,
          'lid_state': 'closed',
          'open_cycles': 10,
          'wifi_rssi': -62,
          'uptime_s': 900,
          'timestamp_ms': 1700000000000,
        }),
        jsonEncode({
          'device_id': 'smartbin_s3_ff0011',
          'trigger': 'lid_close',
          'fill_percent': 96,
          'distance_cm': 10.8,
          'full_alert': true,
          'lid_state': 'closed',
          'open_cycles': 11,
          'wifi_rssi': -60,
          'uptime_s': 1200,
          'timestamp_ms': 1700000300000,
        }),
      ];

      SharedPreferences.setMockInitialValues({
        'waste_telemetry_history_v1': sampleEvents,
        'waste_mqtt_broker_uri': 'mqtt://mqtt.flespi.io:1883',
      });

      final service = WasteConnectionService();
      await service.init();

      expect(service.history.length, 2);
      expect(service.latestTelemetry, isNotNull);
      expect(service.latestTelemetry!.fillPercent, 96);
      expect(service.latestTelemetry!.fullAlert, isTrue);
      expect(service.activeDeviceId, 'smartbin_s3_ff0011');
      expect(service.mqttBrokerUri, 'mqtt://mqtt.flespi.io:1883');

      await service.clearHistory();
      expect(service.history, isEmpty);
    });
  });

  group('Dashboard UI & Modal Widget Tests', () {
    testWidgets('Renders W.A.S.T.E. dashboard, full-bin alert banner, and calibration sheet',
        (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({
        'waste_telemetry_history_v1': [
          jsonEncode({
            'device_id': 'smartbin_s3_test01',
            'trigger': 'lid_close',
            'fill_percent': 98,
            'distance_cm': 10.4,
            'full_alert': true,
            'lid_state': 'closed',
            'open_cycles': 77,
            'wifi_rssi': -55,
            'uptime_s': 7200,
            'timestamp_ms': 1700000000000,
          }),
        ],
      });

      final service = WasteConnectionService();
      await service.init();

      await tester.pumpWidget(WasteCompanionApp(service: service));
      await tester.pumpAndSettle();

      // Verify branding, fill percentage, and Full-Bin Alert banner
      expect(find.text('W.A.S.T.E.'), findsOneWidget);
      expect(find.text('98%'), findsOneWidget);
      expect(find.textContaining('BIN FULL ALERT'), findsOneWidget);
      expect(find.text('Open Lid (5s)'), findsOneWidget);
      expect(find.text('Measure Now'), findsOneWidget);

      // Open Calibration modal bottom sheet
      await tester.tap(find.byIcon(Icons.tune));
      await tester.pumpAndSettle();
      expect(find.text('Sensor & Power Calibration'), findsOneWidget);
      expect(find.text('Apply Configuration to W.A.S.T.E. Node'), findsOneWidget);
    });
  });
}
