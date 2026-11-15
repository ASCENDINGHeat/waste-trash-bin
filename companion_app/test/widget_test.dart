import 'package:flutter_test/flutter_test.dart';
import 'package:waste_companion/main.dart';
import 'package:waste_companion/models/telemetry.dart';
import 'package:waste_companion/services/waste_connection_service.dart';

void main() {
  test('WasteTelemetry JSON parsing matches ESP32-S3 firmware payload', () {
    const raw =
        '{"device_id":"smartbin_s3_a1b2c3","trigger":"lid_close","fill_percent":75,"distance_cm":15.0,"full_alert":false,"lid_state":"closed","open_cycles":42,"wifi_rssi":-58,"uptime_s":3600}';
    final parsed = WasteTelemetry.tryParse(raw);
    expect(parsed, isNotNull);
    expect(parsed!.deviceId, 'smartbin_s3_a1b2c3');
    expect(parsed.fillPercent, 75);
    expect(parsed.distanceCm, 15.0);
    expect(parsed.openCycles, 42);
  });

  testWidgets('Dashboard renders W.A.S.T.E. header and controls',
      (WidgetTester tester) async {
    final service = WasteConnectionService();
    await tester.pumpWidget(WasteCompanionApp(service: service));
    expect(find.text('W.A.S.T.E.'), findsOneWidget);
    expect(find.text('Open Lid (5s)'), findsOneWidget);
    expect(find.text('Measure Now'), findsOneWidget);
  });
}
