import '../lib.dart';

class DeviceScreen extends StatefulWidget {
  const DeviceScreen(
      {super.key, required this.service, required this.scrollController});

  final WasteConnectionService service;
  final ScrollController scrollController;

  @override
  State<StatefulWidget> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  @override
  Widget build(BuildContext context) {
    final device = widget.service.activeDevice;
    final cs = Theme.of(context).colorScheme;

    return ListView(
      controller: widget.scrollController,
      padding: const EdgeInsets.all(16),
      children: [
        Center(
          child: Container(
            width: 32,
            height: 4,
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: cs.surfaceContainerLowest,
            // borderRadius: BorderRadius.circular(12),
            // border: Border.all(color: cs.outline),
          ),
          child: Row(
            children: [
              Icon(
                Icons.lan,
                size: 16,
              ),
              const SizedBox(width: 10),
              Text(
                "${widget.service.activeDeviceId} • ${widget.service.statusMessage}",
                style: TextStyle(fontSize: 14),
              )
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: cs.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cs.outline),
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Padding(
                    padding: EdgeInsetsGeometry.all(8),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        AspectRatio(
                          aspectRatio: 1,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              CircularProgressIndicator(
                                value: ((21 - 2.1) / 21),
                                strokeWidth: 9,
                                strokeCap: StrokeCap.round,
                                color: cs.error,
                                backgroundColor: cs.outlineVariant,
                              ),
                              Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      '${90} %',
                                      style: TextStyle(
                                        fontSize: 28,
                                        fontWeight: FontWeight.w800,
                                        color: cs.error,
                                      ),
                                    ),
                                    Text(
                                      '~ 2.1 cm',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: cs.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        )
                      ],
                    ),
                  ),
                ),
                SizedBox(width: 12),
                VerticalDivider(
                  width: 1,
                  indent: 24,
                  endIndent: 24,
                ),
                const Expanded(
                  child: Column(
                    children: [
                      Expanded(
                        child: _InfoCard(
                          icon: Icons.straighten,
                          title: 'Remaining Depth',
                          value: '2.1 cm',
                          caption: 'Maximum depth is 21cm',
                        ),
                      ),
                      // SizedBox(height: 4),
                      Expanded(
                        child: _InfoCard(
                          icon: Icons.battery_full,
                          title: 'Remaining Battery',
                          value: '85%',
                          caption: 'Lorem Ipsum',
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        ElevatedButton(
          onPressed: () {
            // Code to execute when the button is pressed
            debugPrint('Button pressed!');
          },
          child: const Text('Click Me'),
        ),

        // // Hero (1 col x 2 rows) + 2 stacked info cards
        // IntrinsicHeight(
        //   child: Row(
        //     crossAxisAlignment: CrossAxisAlignment.stretch,
        //     children: [
        //       Expanded(
        //         child: _HeroCard(
        //           percent: 30,
        //           headspaceCm: 2.1,
        //           lidClosed: true,
        //           onOpenLid: () {}, // TODO
        //           onMeasure: () {}, // TODO
        //         ),
        //       ),
        //       const SizedBox(width: 12),
        //       const Expanded(
        //         child: Column(
        //           children: [
        //             Expanded(
        //               child: _InfoCard(
        //                 icon: Icons.straighten,
        //                 title: 'Remaining Depth',
        //                 value: '2.1 cm',
        //                 caption: 'Maximum depth is 21cm',
        //               ),
        //             ),
        //             SizedBox(height: 12),
        //             Expanded(
        //               child: _InfoCard(
        //                 icon: Icons.sync,
        //                 title: 'Lid Cycles',
        //                 value: '13',
        //                 caption: 'Persisted in flash',
        //               ),
        //             ),
        //           ],
        //         ),
        //       ),
        //     ],
        //   ),
        // ),
        // const SizedBox(height: 12),

        // // Bottom row
        // const IntrinsicHeight(
        //   child: Row(
        //     crossAxisAlignment: CrossAxisAlignment.stretch,
        //     children: [
        //       Expanded(
        //         child: _InfoCard(
        //           icon: Icons.wifi,
        //           title: 'Wi-Fi Signal',
        //           value: '-47 dBm',
        //           caption: 'RSSI',
        //         ),
        //       ),
        //       SizedBox(width: 12),
        //       Expanded(
        //         child: _InfoCard(
        //           icon: Icons.timer_outlined,
        //           title: 'System Uptime',
        //           value: '3m 51s',
        //           caption: 'Trigger: remote_cmd',
        //         ),
        //       ),
        //     ],
        //   ),
        // ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers (put in the same file or move to their own)
// ---------------------------------------------------------------------------

class _CardShell extends StatelessWidget {
  const _CardShell({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      // decoration: BoxDecoration(
      //   color: cs.surfaceContainer,
      //   borderRadius: BorderRadius.circular(12),
      //   border: Border.all(color: cs.outline),
      // ),
      child: child,
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.percent,
    required this.headspaceCm,
    required this.lidClosed,
    required this.onOpenLid,
    required this.onMeasure,
  });

  final int percent;
  final double headspaceCm;
  final bool lidClosed;
  final VoidCallback onOpenLid;
  final VoidCallback onMeasure;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final statusColor = lidClosed ? cs.error : cs.primary;

    return _CardShell(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CircularProgressIndicator(
                  value: percent / 100,
                  strokeWidth: 9,
                  strokeCap: StrokeCap.round,
                  color: cs.error,
                  backgroundColor: cs.outlineVariant,
                ),
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '$percent%',
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          color: cs.error,
                        ),
                      ),
                      Text(
                        '$headspaceCm cm',
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // const SizedBox(height: 12),
          // Container(
          //   padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          //   decoration: BoxDecoration(
          //     color: statusColor.withValues(alpha: 0.15),
          //     borderRadius: BorderRadius.circular(8),
          //   ),
          //   child: Text(
          //     lidClosed ? 'LID: CLOSED' : 'LID: OPEN',
          //     style: TextStyle(
          //       fontSize: 10,
          //       fontWeight: FontWeight.w700,
          //       letterSpacing: 0.5,
          //       color: statusColor,
          //     ),
          //   ),
          // ),
          // const SizedBox(height: 12),
          // SizedBox(
          //   width: double.infinity,
          //   child: FilledButton.icon(
          //     onPressed: onOpenLid,
          //     icon: const Icon(Icons.meeting_room_outlined, size: 18),
          //     label: const Text('Open Lid'),
          //   ),
          // ),
          // const SizedBox(height: 8),
          // SizedBox(
          //   width: double.infinity,
          //   child: FilledButton.tonalIcon(
          //     onPressed: onMeasure,
          //     icon: const Icon(Icons.radar, size: 18),
          //     label: const Text('Measure Depth'),
          //   ),
          // ),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.icon,
    required this.title,
    required this.value,
    required this.caption,
    bool this.useDecoration = false,
  });

  final IconData icon;
  final String title;
  final String value;
  final String caption;
  final bool useDecoration;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 11, color: cs.onSurfaceVariant);

    return _CardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: cs.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: muted.copyWith(fontSize: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            value,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: muted.copyWith(fontSize: 10),
          ),
        ],
      ),
    );
  }
}

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
                tooltip: 'OLED Animation (.wbin)',
                icon: const Icon(Icons.movie_filter_outlined),
                onPressed: () {
                  showModalBottomSheet(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => AnimationUploadSheet(service: service),
                  );
                },
              ),
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
                tooltip: 'Connections (LAN, MQTT, BLE)',
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
                      service.transportMode == TransportMode.lan
                          ? Icons.lan_outlined
                          : (service.transportMode == TransportMode.mqtt
                              ? Icons.cloud_done
                              : (service.transportMode == TransportMode.ble
                                  ? Icons.bluetooth_connected
                                  : Icons.portable_wifi_off)),
                      size: 18,
                      color: service.transportMode == TransportMode.lan
                          ? const Color(0xFF00E676)
                          : (service.transportMode == TransportMode.mqtt
                              ? Colors.tealAccent
                              : (service.transportMode == TransportMode.ble
                                  ? Colors.lightBlueAccent
                                  : Colors.orangeAccent)),
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
                  padding:
                      const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
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
    final String label;
    final Color color;

    switch (mode) {
      case TransportMode.lan:
        label = 'LAN (Local)';
        color = const Color(0xFF00E676);
        break;
      case TransportMode.mqtt:
        label = 'Cloud (MQTT)';
        color = Colors.tealAccent;
        break;
      case TransportMode.ble:
        label = 'BLE (Direct)';
        color = Colors.lightBlueAccent;
        break;
      case TransportMode.disconnected:
        label = 'SETUP';
        color = Colors.orangeAccent;
        break;
    }

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
                    gridData:
                        const FlGridData(show: true, horizontalInterval: 25),
                    titlesData: const FlTitlesData(
                      topTitles:
                          AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      rightTitles:
                          AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      bottomTitles:
                          AxisTitles(sideTitles: SideTitles(showTitles: false)),
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
