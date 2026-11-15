import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../services/waste_connection_service.dart';
import 'ble_provision_sheet.dart';
import 'calibration_sheet.dart';

class DashboardScreen extends StatelessWidget {
  final WasteConnectionService service;

  const DashboardScreen({super.key, required this.service});

  Color _fillColor(int pct) {
    if (pct >= 85) return Colors.redAccent;
    if (pct >= 50) return Colors.amberAccent;
    return Colors.tealAccent;
  }

  String _formatUptime(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final t = service.latestTelemetry;
        final fillPct = t?.fillPercent ?? 0;
        final distCm = t?.distanceCm ?? 30.0;
        final lidState = (t?.lidState ?? 'closed').toUpperCase();
        final cycles = t?.openCycles ?? 0;
        final rssi = t?.wifiRssi ?? -127;
        final uptime = t?.uptimeS ?? 0;
        final fullAlert = (t?.fullAlert ?? false) || fillPct >= 95;
        final ringColor = _fillColor(fillPct);

        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'W.A.S.T.E.',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2.0,
                    fontSize: 20,
                  ),
                ),
                Text(
                  'Waste Automation & Sensing Technology Engine',
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.white.withOpacity(0.65),
                  ),
                ),
              ],
            ),
            actions: [
              _buildTransportBadge(context),
              IconButton(
                tooltip: 'Sensor & Power Calibration',
                icon: const Icon(Icons.tune),
                onPressed: () {
                  showModalBottomSheet(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => CalibrationSheet(service: service),
                  );
                },
              ),
              IconButton(
                tooltip: 'BLE Provisioning & MQTT Broker',
                icon: const Icon(Icons.settings_input_antenna),
                onPressed: () {
                  showModalBottomSheet(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => BleProvisionSheet(service: service),
                  );
                },
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // Status Bar
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white12),
                ),
                child: Row(
                  children: [
                    Icon(
                      service.transportMode == TransportMode.ble
                          ? Icons.bluetooth_connected
                          : (service.transportMode == TransportMode.mqtt
                              ? Icons.cloud_done
                              : Icons.portable_wifi_off),
                      size: 18,
                      color: service.transportMode == TransportMode.disconnected
                          ? Colors.orangeAccent
                          : Colors.tealAccent,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '${service.activeDeviceId} • ${service.statusMessage}',
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // Full-Bin Alert Banner
              if (fullAlert)
                Container(
                  margin: const EdgeInsets.only(bottom: 14),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.redAccent, width: 1.5),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.warning_amber_rounded,
                          color: Colors.redAccent, size: 28),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'BIN FULL ALERT — Capacity ≥ 95% (≤ 10 cm from sensor). Empty receptacle to clear alert.',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

              // Main Fill Level Gauge Card
              Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: const BorderSide(color: Colors.white12),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      vertical: 24, horizontal: 20),
                  child: Column(
                    children: [
                      SizedBox(
                        width: 190,
                        height: 190,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            SizedBox(
                              width: 190,
                              height: 190,
                              child: CircularProgressIndicator(
                                value: fillPct / 100.0,
                                strokeWidth: 14,
                                backgroundColor: Colors.white10,
                                valueColor:
                                    AlwaysStoppedAnimation<Color>(ringColor),
                                strokeCap: StrokeCap.round,
                              ),
                            ),
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '$fillPct%',
                                  style: TextStyle(
                                    fontSize: 44,
                                    fontWeight: FontWeight.w900,
                                    color: ringColor,
                                  ),
                                ),
                                Text(
                                  '${distCm.toStringAsFixed(1)} cm headspace',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: Colors.white70,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: ringColor.withOpacity(0.18),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Text(
                                    'LID: $lidState',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: ringColor,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 22),

                      // Remote Actuation Controls
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              icon: const Icon(Icons.sensor_door_outlined),
                              label: const Text('Open Lid (5s)'),
                              onPressed: () =>
                                  service.triggerOpenLid(holdSeconds: 5),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton.tonalIcon(
                              icon: const Icon(Icons.radar),
                              label: const Text('Measure Now'),
                              onPressed: service.triggerMeasureNow,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // 4 Telemetry Metric Cards
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.75,
                children: [
                  _metricCard(
                    icon: Icons.straighten,
                    label: 'Ultrasonic Depth',
                    value: '${distCm.toStringAsFixed(1)} cm',
                    sub: '10 cm = Full • 30 cm = Empty',
                  ),
                  _metricCard(
                    icon: Icons.autorenew,
                    label: 'Lifetime Lid Cycles',
                    value: '$cycles',
                    sub: 'Persisted in NVS Flash',
                  ),
                  _metricCard(
                    icon: Icons.wifi,
                    label: 'Wi-Fi Signal (RSSI)',
                    value: rssi <= -120 ? 'BLE Mode' : '$rssi dBm',
                    sub: 'WIFI_PS_MAX_MODEM',
                  ),
                  _metricCard(
                    icon: Icons.timer_outlined,
                    label: 'System Uptime',
                    value: _formatUptime(uptime),
                    sub: 'Trigger: ${t?.trigger ?? "idle"}',
                  ),
                ],
              ),
              const SizedBox(height: 18),

              // Historical Fill-Level Trend Chart (Phone Storage)
              _buildHistoryCard(context),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTransportBadge(BuildContext context) {
    final mode = service.transportMode;
    final label = mode == TransportMode.ble
        ? 'BLE GATT'
        : (mode == TransportMode.mqtt ? 'MQTT LIVE' : 'SETUP');
    final color = mode == TransportMode.ble
        ? Colors.lightBlueAccent
        : (mode == TransportMode.mqtt
            ? Colors.tealAccent
            : Colors.orangeAccent);

    return GestureDetector(
      onTap: () {
        showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          builder: (_) => BleProvisionSheet(service: service),
        );
      },
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withOpacity(0.16),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withOpacity(0.6)),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ),
      ),
    );
  }

  Widget _metricCard({
    required IconData icon,
    required String label,
    required String value,
    required String sub,
  }) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Colors.white12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(icon, size: 16, color: Colors.tealAccent),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            Text(
              value,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            Text(
              sub,
              style: const TextStyle(fontSize: 10.5, color: Colors.white54),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHistoryCard(BuildContext context) {
    final items = service.history;
    final recent = items.length > 30 ? items.sublist(items.length - 30) : items;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: Colors.white12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Fill-Level History (${items.length} events stored on phone)',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (items.isNotEmpty)
                  TextButton(
                    onPressed: service.clearHistory,
                    child: const Text('Clear'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (recent.length < 2)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    'Connect via MQTT or BLE to begin recording fill-level trend telemetry.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                ),
              )
            else
              SizedBox(
                height: 170,
                child: LineChart(
                  LineChartData(
                    minY: 0,
                    maxY: 100,
                    gridData: const FlGridData(show: true, horizontalInterval: 25),
                    titlesData: const FlTitlesData(
                      topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    ),
                    borderData: FlBorderData(show: false),
                    lineBarsData: [
                      LineChartBarData(
                        isCurved: true,
                        color: Colors.tealAccent,
                        barWidth: 3,
                        dotData: const FlDotData(show: true),
                        belowBarData: BarAreaData(
                          show: true,
                          color: Colors.tealAccent.withOpacity(0.15),
                        ),
                        spots: [
                          for (int i = 0; i < recent.length; i++)
                            FlSpot(
                              i.toDouble(),
                              recent[i].fillPercent.toDouble(),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
