import 'package:google_fonts/google_fonts.dart';

import '../lib.dart';

/// TEMPORARY Main tab UI. Replace when the real design is ready.
class MainPage extends StatefulWidget {
  const MainPage({super.key, required this.service});

  final WasteConnectionService service;

  @override
  State<StatefulWidget> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  bool _isGrid = false;

  @override
  Widget build(BuildContext context) {
    WasteConnectionService service = widget.service;

    final cs = Theme.of(context).colorScheme;

    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              color: cs.surfaceContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(children: [
                  Text(
                    "Good Morning, lad",
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: cs.onPrimaryContainer),
                  ),
                  SizedBox(height: 8),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      StatusChip(
                        label: 'Empty',
                        count: service.totalEmptyBin,
                        background: cs.secondary,
                        foreground: cs.onSecondary,
                      ),
                      StatusChip(
                        label: 'Full',
                        count: service.totalFullBin,
                        background: cs.tertiary,
                        foreground: cs.onTertiary,
                      ),
                      StatusChip(
                        label: 'Off',
                        count: service.totalOffBin,
                        background: cs.error,
                        foreground: cs.onError,
                      ),
                    ],
                  ),
                  SizedBox(height: 6),
                ]),
              ),
            ),
            // SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Expanded(
                    child: Text(
                      "Library",
                      style:
                          TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                  ),
                  SegmentedButton<bool>(
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                      visualDensity:
                          VisualDensity(horizontal: -4, vertical: -2),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: WidgetStatePropertyAll(
                        EdgeInsets.symmetric(horizontal: 10),
                      ),
                    ),
                    segments: const [
                      ButtonSegment(
                        value: false,
                        icon: Icon(Icons.view_list, size: 17),
                        tooltip: 'Show as list',
                      ),
                      ButtonSegment(
                        value: true,
                        icon: Icon(Icons.grid_view, size: 17),
                        tooltip: 'Show as grid',
                      ),
                    ],
                    selected: {_isGrid},
                    onSelectionChanged: (selection) {
                      setState(() => _isGrid = selection.first);
                    },
                  ),
                ],
              ),
            ),
            Divider(
              height: 1,
            ),
            SizedBox(
              height: 12,
            ),
            _builtList(service)
          ],
        );
      },
    );
  }

  Widget _builtList(WasteConnectionService service) {
    return Column(
      spacing: 8,
      children: [
        for (final d in service.devices)
          _builtListItem(
              Icons.rocket,
              d.displayName,
              d.isOnline() ? "Connected" : "Offline",
              d.latestTelemetry?.fillPercent ?? 0,
              d.latestTelemetry?.fillPercent ?? 0,
              () => _selectAndOpen(service, d)),
      ],
    );
  }

  Widget _builtListItem(
    IconData icon,
    String title,
    String status,
    int batteryPercentage,
    int trashFullPercentage,
    VoidCallback? onTap,
  ) {
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsetsGeometry.symmetric(horizontal: 4),
      child: ListTile(
        onTap: onTap,
        tileColor: cs.surface,
        iconColor: cs.primary,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadiusGeometry.all(Radius.circular(10))),
        leading: Icon(
          icon,
          size: 25,
        ),
        title: Text(title),
        subtitle: Row(children: [
          Text('$status • '),
          RotatedBox(
            quarterTurns: 1,
            child: Icon(
              _convertBatteryPercentageToIcon(batteryPercentage),
              color: cs.secondary,
              size: 20,
            ),
          )
        ]),
        trailing: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              "$trashFullPercentage%",
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: cs.primary,
              ),
            ),
            Text(
              "Full",
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _selectAndOpen(
      WasteConnectionService service, WasteDeviceSession device) async {
    await service.selectActiveDevice(device.deviceId);
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      // showDragHandle: true,
      enableDrag: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.935,
        expand: false,
        snap: true,
        snapSizes: const [0.5, 0.935],
        builder: (ctx, scrollController) => Material(
          clipBehavior: Clip.antiAlias,
          color: Theme.of(context).colorScheme.surface,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: DeviceScreen(
            service: service,
            scrollController: scrollController,
          ),
        ),
      ),
    );
  }

  IconData _convertBatteryPercentageToIcon(int percentage) =>
      switch (percentage) {
        >= 90 => Icons.battery_full,
        >= 80 => Icons.battery_6_bar,
        >= 65 => Icons.battery_5_bar,
        >= 50 => Icons.battery_4_bar,
        >= 35 => Icons.battery_3_bar,
        >= 25 => Icons.battery_2_bar,
        >= 10 => Icons.battery_1_bar,
        >= 0 => Icons.battery_0_bar,
        _ => Icons.battery_unknown
      };
}

class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.label,
    required this.count,
    required this.background,
    required this.foreground,
  });

  final String label;
  final int count;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration:
                BoxDecoration(color: foreground, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            '$label • $count',
            style: TextStyle(fontSize: 11, color: foreground),
          ),
        ],
      ),
    );
  }
}
