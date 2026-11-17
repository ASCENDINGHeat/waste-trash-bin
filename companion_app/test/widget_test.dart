import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:waste_companion/main.dart';
import 'package:waste_companion/models/telemetry.dart';
import 'package:waste_companion/screens/animation_upload_sheet.dart';
import 'package:waste_companion/services/waste_connection_service.dart';
import 'package:waste_companion/services/wbin_encoder.dart';

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
        oledUiMode: 'split_dashboard',
      );
      final cmd = cfg.toCommandJson();
      expect(cmd['cmd'], 'configure');
      expect(cmd['full_cm'], 10.0);
      expect(cmd['empty_cm'], 30.0);
      expect(cmd['periodic_interval_s'], 900);
      expect(cmd['oled_sleep_timeout_s'], 30);
      expect(cmd['oled_ui_mode'], 'split_dashboard');
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
      expect(find.text('HUD+Cat'), findsOneWidget);
      expect(find.text('Apply Configuration to W.A.S.T.E. Node'), findsOneWidget);
    });
  });

  group('.wbin (WGF1) Container & IEEE 802.3 CRC32 Tests', () {
    test('Computes exact IEEE 802.3 CRC32 for standard test vectors (ASCII "123456789")', () {
      final asciiBytes = utf8.encode('123456789');
      final crc = Crc32Ieee.compute(asciiBytes);
      expect(crc, 0xCBF43926);
    });

    test('Packages valid 16-byte WGF1 container header with correct field encodings', () {
      final frame1 = Uint8List(1024);
      final frame2 = Uint8List(1024);
      frame1[0] = 0xAA;
      frame2[1023] = 0x55;

      final packed = WbinEncoder.packageRawFrames(
        rawFrames: [frame1, frame2],
        targetFps: 20,
        invert: true,
        hudOverlay: false,
      );

      expect(packed.length, 16 + 2048);

      // Verify Header Layout
      // Offset 0..3: "WGF1"
      expect(packed[0], 0x57); // 'W'
      expect(packed[1], 0x47); // 'G'
      expect(packed[2], 0x46); // 'F'
      expect(packed[3], 0x31); // '1'

      final bd = ByteData.sublistView(packed);
      // Offset 4..5: num_frames = 2 (little-endian)
      expect(bd.getUint16(4, Endian.little), 2);
      // Offset 6: target_fps = 20
      expect(packed[6], 20);
      // Offset 7: flags = bit 0 (invert=1), bit 1 (hud_overlay=0) -> 0x01
      expect(packed[7], 0x01);
      // Offset 8..11: payload_bytes = 2048
      expect(bd.getUint32(8, Endian.little), 2048);

      // Offset 12..15: IEEE 802.3 CRC32 over the 2048 payload bytes
      final expectedCrc = Crc32Ieee.compute(packed.sublist(16));
      expect(bd.getUint32(12, Endian.little), expectedCrc);

      // Verify parsing and validation
      final header = WbinEncoder.parseHeader(packed);
      expect(header.magic, 'WGF1');
      expect(header.numFrames, 2);
      expect(header.targetFps, 20);
      expect(header.isInverted, isTrue);
      expect(header.hasHudOverlay, isFalse);
      expect(header.payloadBytes, 2048);
      expect(header.crc32, expectedCrc);
      expect(WbinEncoder.verifyCrc32(packed), isTrue);
    });

    test('Maps SSD1306 vertical page addressing bit positions accurately', () {
      // Test pixel (x = 10, y = 17):
      // Page = 17 ~/ 8 = 2
      // Bit = 17 % 8 = 1
      // Byte offset = Page * 128 + x = 2 * 128 + 10 = 266
      final frameBuf = Uint8List(1024);
      frameBuf[2 * 128 + 10] = (1 << 1); // Row 17, Col 10

      final frame = WbinEncoder.frameFromSsd1306Bytes(frameBuf);
      expect(frame.ssd1306Bytes.length, 1024);
      expect(frame.previewRgba.length, 128 * 64 * 4);

      // Pixel (10, 17) in RGBA preview should be white (255, 255, 255, 255)
      const pIdx = (17 * 128 + 10) * 4;
      expect(frame.previewRgba[pIdx], 0xFF);     // R
      expect(frame.previewRgba[pIdx + 1], 0xFF); // G
      expect(frame.previewRgba[pIdx + 2], 0xFF); // B
      expect(frame.previewRgba[pIdx + 3], 0xFF); // A

      // Pixel (10, 16) should be off (0, 0, 0, 255)
      const offIdx = (16 * 128 + 10) * 4;
      expect(frame.previewRgba[offIdx], 0x00);
      expect(frame.previewRgba[offIdx + 1], 0x00);
    });

    test('Enforces bounds and rejects zero frames, oversized frame counts, and bad magic', () {
      // 0 frames
      expect(
        () => WbinEncoder.packageRawFrames(rawFrames: []),
        throwsArgumentError,
      );

      // > 512 frames
      final tooManyFrames = List.generate(513, (_) => Uint8List(1024));
      expect(
        () => WbinEncoder.packageRawFrames(rawFrames: tooManyFrames),
        throwsArgumentError,
      );

      // Corrupt magic
      final badMagic = Uint8List(16 + 1024);
      badMagic.setRange(0, 4, utf8.encode('BAD!'));
      expect(() => WbinEncoder.parseHeader(badMagic), throwsFormatException);
    });

    test('Detects corrupt CRC32 and payload length mismatches', () {
      final valid = WbinEncoder.packageRawFrames(
        rawFrames: [Uint8List(1024)],
        targetFps: 15,
      );
      expect(WbinEncoder.verifyCrc32(valid), isTrue);

      // Flip single payload bit
      final corrupted = Uint8List.fromList(valid);
      corrupted[20] ^= 0x01;
      expect(WbinEncoder.verifyCrc32(corrupted), isFalse);

      // Truncated payload
      final truncated = valid.sublist(0, valid.length - 100);
      expect(() => WbinEncoder.parseHeader(truncated), throwsFormatException);
    });

    test('Unpacks valid .wbin payload back into WbinFrame objects', () {
      final frame1 = Uint8List(1024);
      frame1[0] = 0x01;
      final packed = WbinEncoder.packageRawFrames(
        rawFrames: [frame1],
        targetFps: 15,
      );

      final unpacked = WbinEncoder.unpackFrames(packed);
      expect(unpacked.length, 1);
      expect(unpacked.first.ssd1306Bytes[0], 0x01);
      expect(unpacked.first.durationMs, 66);
    });
  });

  group('Tri-Mode Transport Router & Priority Fallback Tests', () {
    test('Resolves Priority 1 (LAN) when LAN, MQTT, and BLE are all active', () {
      final service = WasteConnectionService();
      service.setMockTransports(
        lan: true,
        mqtt: true,
        ble: true,
        lanHost: '192.168.1.100',
      );

      expect(service.transportMode, TransportMode.lan);
      expect(service.isLanConnected, isTrue);
      expect(service.isNodeOnline, isTrue);
    });

    test('Falls back to Priority 2 (MQTT) when LAN is disconnected', () {
      final service = WasteConnectionService();
      service.setMockTransports(
        lan: false,
        mqtt: true,
        ble: true,
      );

      expect(service.transportMode, TransportMode.mqtt);
      expect(service.isMqttConnected, isTrue);
      expect(service.isNodeOnline, isTrue);
    });

    test('Falls back to Priority 3 (BLE) when LAN and MQTT are disconnected', () {
      final service = WasteConnectionService();
      service.setMockTransports(
        lan: false,
        mqtt: false,
        ble: true,
      );

      expect(service.transportMode, TransportMode.ble);
      expect(service.isBleConnected, isTrue);
      expect(service.isNodeOnline, isTrue);
    });

    test('Reports TransportMode.disconnected when all transports are inactive', () {
      final service = WasteConnectionService();
      service.setMockTransports(
        lan: false,
        mqtt: false,
        ble: false,
      );

      expect(service.transportMode, TransportMode.disconnected);
      expect(service.isNodeOnline, isFalse);
    });

    test('Rejects custom animation upload and reset when all transports are disconnected', () async {
      final service = WasteConnectionService();
      service.setMockTransports(lan: false, mqtt: false, ble: false);

      final uploadResult = await service.uploadCustomAnimation(Uint8List(1040));
      expect(uploadResult, isFalse);
      expect(service.statusMessage, contains('Upload unavailable'));

      final resetResult = await service.resetCustomAnimation();
      expect(resetResult, isFalse);
      expect(service.statusMessage, contains('Cannot reset'));
    });

    test('Honors explicit TransportPreference pinning over Auto priority', () async {
      SharedPreferences.setMockInitialValues({});
      final service = WasteConnectionService();
      service.setMockTransports(
        lan: true,
        mqtt: true,
        ble: true,
        lanHost: '192.168.1.100',
      );

      expect(service.transportMode, TransportMode.lan);

      await service.setTransportPreference(TransportPreference.mqtt);
      expect(service.transportMode, TransportMode.mqtt);

      await service.setTransportPreference(TransportPreference.ble);
      expect(service.transportMode, TransportMode.ble);

      service.setMockTransports(ble: false);
      expect(service.transportMode, TransportMode.disconnected);

      await service.setTransportPreference(TransportPreference.auto);
      expect(service.transportMode, TransportMode.lan);
    });
  });

  group('AnimationUploadSheet & Dashboard UI Integration Tests', () {
    testWidgets('Renders OLED Animation launcher button and opens AnimationUploadSheet',
        (WidgetTester tester) async {
      final service = WasteConnectionService();
      service.setMockTransports(
        lan: true,
        mqtt: false,
        ble: false,
        lanHost: '192.168.1.50',
      );

      await tester.pumpWidget(WasteCompanionApp(service: service));
      await tester.pumpAndSettle();

      // Check badge shows LAN (Local)
      expect(find.text('LAN (Local)'), findsOneWidget);

      // Verify OLED animation button is present in AppBar
      final animButtonFinder = find.byTooltip('OLED Animation (.wbin)');
      expect(animButtonFinder, findsOneWidget);

      // Tap to open bottom sheet
      await tester.tap(animButtonFinder);
      await tester.pumpAndSettle();

      // Verify AnimationUploadSheet modal title and controls appear
      expect(find.text('Custom OLED Animation (.wbin)'), findsOneWidget);
      expect(find.text('Pick GIF File'), findsOneWidget);
      expect(find.text('Demo Pattern'), findsOneWidget);
      expect(find.byKey(const Key('reset_anim_button')), findsOneWidget);
    });

    testWidgets('Renders Connection Selector and LAN HTTP controls inside Connectivity sheet',
        (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final service = WasteConnectionService();
      service.setMockTransports(
        lan: true,
        mqtt: true,
        ble: false,
        lanHost: '192.168.1.50',
      );

      await tester.pumpWidget(WasteCompanionApp(service: service));
      await tester.pumpAndSettle();

      expect(find.text('LAN (Local)'), findsOneWidget);

      final connButtonFinder = find.byTooltip('Connections (LAN, MQTT, BLE)');
      expect(connButtonFinder, findsOneWidget);
      await tester.tap(connButtonFinder);
      await tester.pumpAndSettle();

      expect(find.text('Tri-Mode Connectivity & Setup'), findsOneWidget);
      expect(find.byKey(const Key('transport_selector')), findsOneWidget);
      expect(find.byKey(const Key('lan_host_field')), findsOneWidget);
      expect(find.byKey(const Key('lan_port_field')), findsOneWidget);
      expect(find.byKey(const Key('connect_lan_button')), findsOneWidget);
      expect(find.byKey(const Key('probe_mdns_button')), findsOneWidget);
      expect(find.byKey(const Key('disconnect_lan_button')), findsOneWidget);

      // Tap "Use .local" quick-fill chip
      await tester.tap(find.byKey(const Key('use_mdns_local_button')));
      await tester.pumpAndSettle();
      expect(find.text('smartbin_s3.local'), findsOneWidget);

      // Switch active selector from Auto to MQTT and verify mode updates
      await tester.tap(find.text('MQTT'));
      await tester.pumpAndSettle();
      expect(service.preferredTransport, TransportPreference.mqtt);
      expect(service.transportMode, TransportMode.mqtt);

      // Disconnect LAN and confirm LAN status pill updates
      await tester.tap(find.byKey(const Key('disconnect_lan_button')));
      await tester.pumpAndSettle();
      expect(service.isLanConnected, isFalse);
      expect(find.byKey(const Key('disconnect_lan_button')), findsNothing);
    });

    testWidgets('Renders preview canvas, scrubbing slider, and handles demo pattern',
        (WidgetTester tester) async {
      final service = WasteConnectionService();
      service.setMockTransports(lan: true, lanHost: '192.168.1.50');

      // Create a test 3-frame animation
      final f1 = Uint8List(1024);
      final f2 = Uint8List(1024);
      final f3 = Uint8List(1024);
      f1[0] = 0xFF;
      f2[128] = 0xFF;
      f3[256] = 0xFF;

      final testAnim = WbinAnimation(
        frames: [
          WbinEncoder.frameFromSsd1306Bytes(f1),
          WbinEncoder.frameFromSsd1306Bytes(f2),
          WbinEncoder.frameFromSsd1306Bytes(f3),
        ],
        targetFps: 15,
        invert: false,
        hudOverlay: true,
        wbinBytes: WbinEncoder.packageRawFrames(rawFrames: [f1, f2, f3]),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: AnimationUploadSheet(
              service: service,
              initialAnimation: testAnim,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify frame counter and slider
      expect(find.text('1 / 3'), findsOneWidget);
      final sliderFinder = find.byKey(const Key('frame_scrub_slider'));
      expect(sliderFinder, findsOneWidget);

      // Verify upload button reflects LAN mode
      expect(find.text('Upload Animation (3 frames)'), findsOneWidget);
      expect(find.textContaining('Route: Local LAN'), findsOneWidget);

      // Tap Reset button
      final resetFinder = find.byKey(const Key('reset_anim_button'));
      expect(resetFinder, findsOneWidget);
      await tester.ensureVisible(resetFinder);
      await tester.pumpAndSettle();
      await tester.tap(resetFinder);
      await tester.pumpAndSettle();
    });
  });
}
