import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/waste_connection_service.dart';

class BleProvisionSheet extends StatefulWidget {
  final WasteConnectionService service;

  const BleProvisionSheet({super.key, required this.service});

  @override
  State<BleProvisionSheet> createState() => _BleProvisionSheetState();
}

class _BleProvisionSheetState extends State<BleProvisionSheet> {
  final _lanHostCtrl = TextEditingController();
  final _lanPortCtrl = TextEditingController();
  final _ssidCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _mqttCtrl = TextEditingController();
  final _tokenCtrl = TextEditingController();
  final _deviceIdCtrl = TextEditingController();

  List<ScanResult> _scanResults = [];
  bool _scanning = false;
  StreamSubscription<List<ScanResult>>? _scanSub;

  @override
  void initState() {
    super.initState();
    _lanHostCtrl.text = widget.service.lanHost;
    _lanPortCtrl.text = widget.service.lanPort.toString();
    _mqttCtrl.text = widget.service.mqttBrokerUri;
    _deviceIdCtrl.text = widget.service.activeDeviceId;
    if (widget.service.isBleConnected) {
      _loadCurrentBleConfig();
    }
  }

  String _resolvedMqttUri() {
    final rawUri = _mqttCtrl.text.trim();
    final rawToken = _tokenCtrl.text.trim();
    if (rawToken.isEmpty) return rawUri;

    final cleanToken = rawToken.replaceFirst(RegExp(r'^FlespiToken\s+', caseSensitive: false), '');
    final encodedToken = Uri.encodeComponent(cleanToken);
    final normalized = rawUri.contains('://') ? rawUri : 'mqtt://$rawUri';
    try {
      final u = Uri.parse(normalized);
      final host = u.host.isNotEmpty ? u.host : 'mqtt.flespi.io';
      final port = u.hasPort ? u.port : 1883;
      return '${u.scheme}://$encodedToken@$host:$port';
    } catch (_) {
      return 'mqtt://$encodedToken@mqtt.flespi.io:1883';
    }
  }

  Future<void> _loadCurrentBleConfig() async {
    final cfg = await widget.service.readBleProvisioningConfig();
    if (!mounted) return;
    setState(() {
      if (cfg['ssid']?.isNotEmpty == true) _ssidCtrl.text = cfg['ssid']!;
      if (cfg['mqtt_uri']?.isNotEmpty == true) _mqttCtrl.text = cfg['mqtt_uri']!;
    });
  }

  Future<void> _startBleScan() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    setState(() {
      _scanResults = [];
      _scanning = true;
    });

    await _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      if (!mounted) return;
      setState(() {
        _scanResults = results
            .where((r) =>
                r.device.platformName.isNotEmpty ||
                r.advertisementData.serviceUuids
                    .any((u) => u.toString().toLowerCase().contains('ff00')))
            .toList();
      });
    });

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 6));
    } catch (_) {}

    if (mounted) {
      setState(() => _scanning = false);
    }
  }

  Widget _buildLinkPill(String label, bool connected, Color activeColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: connected
            ? activeColor.withOpacity(0.15)
            : Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: connected ? activeColor.withOpacity(0.6) : Colors.white12,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            connected ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 13,
            color: connected ? activeColor : Colors.white38,
          ),
          const SizedBox(width: 5),
          Text(
            '$label: ${connected ? 'Up' : 'Down'}',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: connected ? activeColor : Colors.white54,
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    if (_scanning) {
      unawaited(FlutterBluePlus.stopScan().catchError((_) {}));
    }
    _lanHostCtrl.dispose();
    _lanPortCtrl.dispose();
    _ssidCtrl.dispose();
    _passCtrl.dispose();
    _mqttCtrl.dispose();
    _tokenCtrl.dispose();
    _deviceIdCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.88,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return ListenableBuilder(
          listenable: widget.service,
          builder: (context, _) {
            final svc = widget.service;
            return ListView(
              controller: scrollController,
              padding: const EdgeInsets.all(20),
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Tri-Mode Connectivity & Setup',
                      style:
                          TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  svc.statusMessage,
                  style: TextStyle(color: Colors.tealAccent.shade200, fontSize: 13),
                ),
                const SizedBox(height: 12),

                // Transport Selector (Auto Priority vs Manual Pin)
                const Text(
                  'Active Connection Selector',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.white70,
                  ),
                ),
                const SizedBox(height: 8),
                SegmentedButton<TransportPreference>(
                  key: const Key('transport_selector'),
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment<TransportPreference>(
                      value: TransportPreference.auto,
                      label: Text('Auto'),
                      icon: Icon(Icons.auto_awesome, size: 16),
                    ),
                    ButtonSegment<TransportPreference>(
                      value: TransportPreference.lan,
                      label: Text('LAN'),
                      icon: Icon(Icons.lan_outlined, size: 16),
                    ),
                    ButtonSegment<TransportPreference>(
                      value: TransportPreference.mqtt,
                      label: Text('MQTT'),
                      icon: Icon(Icons.cloud_outlined, size: 16),
                    ),
                    ButtonSegment<TransportPreference>(
                      value: TransportPreference.ble,
                      label: Text('BLE'),
                      icon: Icon(Icons.bluetooth, size: 16),
                    ),
                  ],
                  selected: {svc.preferredTransport},
                  onSelectionChanged: (selection) {
                    if (selection.isNotEmpty) {
                      svc.setTransportPreference(selection.first);
                    }
                  },
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    _buildLinkPill(
                        'LAN', svc.isLanConnected, const Color(0xFF00E676)),
                    _buildLinkPill('MQTT', svc.isMqttConnected, Colors.tealAccent),
                    _buildLinkPill(
                        'BLE', svc.isBleConnected, Colors.lightBlueAccent),
                  ],
                ),
                const Divider(height: 28),

                // 1. Local LAN HTTP REST (:80 / mDNS .local)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      '1. Local LAN HTTP (:80 / mDNS)',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    TextButton.icon(
                      key: const Key('use_mdns_local_button'),
                      icon: const Icon(Icons.dns_outlined, size: 16),
                      label: const Text('Use .local'),
                      onPressed: () {
                        setState(() {
                          _lanHostCtrl.text = '${svc.activeDeviceId}.local';
                          if (_lanPortCtrl.text.trim().isEmpty) {
                            _lanPortCtrl.text = '80';
                          }
                        });
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        key: const Key('lan_host_field'),
                        controller: _lanHostCtrl,
                        decoration: InputDecoration(
                          labelText: 'Node IP or .local Hostname',
                          hintText: '192.168.1.50 or ${svc.activeDeviceId}.local',
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.lan_outlined),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 1,
                      child: TextField(
                        key: const Key('lan_port_field'),
                        controller: _lanPortCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Port',
                          hintText: '80',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                if (svc.lanDeviceIp.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Last resolved LAN IP: ${svc.lanDeviceIp}',
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ],
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      key: const Key('connect_lan_button'),
                      icon: svc.isLanConnecting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.black,
                              ),
                            )
                          : Icon(svc.isLanConnected ? Icons.sync : Icons.lan),
                      label: Text(
                          svc.isLanConnected ? 'Reconnect LAN' : 'Connect LAN'),
                      onPressed: svc.isLanConnecting
                          ? null
                          : () {
                              final port =
                                  int.tryParse(_lanPortCtrl.text.trim()) ?? 80;
                              svc.connectLan(
                                host: _lanHostCtrl.text.trim(),
                                port: port,
                              );
                            },
                    ),
                    FilledButton.tonalIcon(
                      key: const Key('probe_mdns_button'),
                      icon: const Icon(Icons.radar),
                      label: const Text('Find .local'),
                      onPressed: svc.isLanConnecting
                          ? null
                          : () async {
                              final port =
                                  int.tryParse(_lanPortCtrl.text.trim()) ?? 80;
                              final ok = await svc.probeMdnsLan(port: port);
                              if (ok && mounted) {
                                _lanHostCtrl.text = svc.lanHost;
                                _lanPortCtrl.text = svc.lanPort.toString();
                              }
                            },
                    ),
                    if (svc.isLanConnected)
                      OutlinedButton(
                        key: const Key('disconnect_lan_button'),
                        onPressed: svc.disconnectLan,
                        child: const Text('Disconnect'),
                      ),
                  ],
                ),
                const Divider(height: 32),

                // 2. Phone MQTT Broker Connection
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      '2. MQTT Broker (Flespi / LAN / Cloud)',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    TextButton.icon(
                      icon: const Icon(Icons.bolt, size: 16),
                      label: const Text('Flespi Preset'),
                      onPressed: () {
                        setState(() {
                          _mqttCtrl.text = 'mqtt://mqtt.flespi.io:1883';
                        });
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _mqttCtrl,
                  decoration: const InputDecoration(
                    labelText: 'MQTT Broker URI',
                    hintText:
                        'mqtt://mqtt.flespi.io:1883 or mqtt://<TOKEN>@mqtt.flespi.io:1883',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.cloud_outlined),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _tokenCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Flespi Token / MQTT Username (Optional)',
                    hintText: 'Paste FlespiToken here (auto-embeds into URI)',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.vpn_key_outlined),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _deviceIdCtrl,
                  decoration: const InputDecoration(
                    labelText:
                        'Target Device ID (blank = auto-discover smartbin/+)',
                    hintText: 'smartbin_s3_a1b2c3',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.memory),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        icon: Icon(
                            svc.isMqttConnected ? Icons.sync : Icons.power),
                        label: Text(svc.isMqttConnected
                            ? 'Reconnect MQTT'
                            : 'Connect MQTT'),
                        onPressed: () {
                          final resolved = _resolvedMqttUri();
                          _mqttCtrl.text = resolved;
                          svc.connectMqtt(
                            brokerUri: resolved,
                            deviceId: _deviceIdCtrl.text,
                          );
                        },
                      ),
                    ),
                    if (svc.isMqttConnected) ...[
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: svc.disconnectMqtt,
                        child: const Text('Disconnect'),
                      ),
                    ],
                  ],
                ),
                const Divider(height: 32),

                // 3. BLE Scanner & Failover Connection
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      '3. Direct BLE GATT (0xFF00)',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    FilledButton.tonalIcon(
                      icon: _scanning
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.bluetooth_searching),
                      label: Text(_scanning ? 'Scanning...' : 'Scan BLE'),
                      onPressed: _scanning ? null : _startBleScan,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_scanResults.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'Tap "Scan BLE" to discover nearby smartbin_s3_* nodes in Setup or Wi-Fi Failover mode.',
                      style: TextStyle(color: Colors.white60, fontSize: 13),
                    ),
                  )
                else
                  ..._scanResults.map((r) {
                    final name = r.device.platformName.isNotEmpty
                        ? r.device.platformName
                        : r.device.remoteId.str;
                    final isSmartBin = name.toLowerCase().contains('smartbin');
                    return Card(
                      color: isSmartBin
                          ? Colors.teal.withOpacity(0.18)
                          : Colors.white10,
                      child: ListTile(
                        leading: Icon(
                          Icons.bluetooth,
                          color: isSmartBin ? Colors.tealAccent : Colors.white70,
                        ),
                        title: Text(name),
                        subtitle:
                            Text('RSSI: ${r.rssi} dBm • ${r.device.remoteId}'),
                        trailing: FilledButton(
                          onPressed: () async {
                            final ok = await svc.connectBleDevice(r.device);
                            if (ok) {
                              await _loadCurrentBleConfig();
                            }
                          },
                          child: const Text('Connect'),
                        ),
                      ),
                    );
                  }),

                // 4. Provision NVS Credentials over BLE
                if (svc.isBleConnected) ...[
                  const Divider(height: 32),
                  const Text(
                    '4. Provision ESP32-S3 NVS over BLE (0xFF01–0xFF04)',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _ssidCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Wi-Fi 2.4 GHz SSID (0xFF01)',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.wifi),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _passCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Wi-Fi Password (0xFF02)',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.lock_outline),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    icon: const Icon(Icons.save_alt),
                    label: const Text('Write to ESP32-S3 NVS & Connect Wi-Fi'),
                    onPressed: () async {
                      final resolved = _resolvedMqttUri();
                      _mqttCtrl.text = resolved;
                      await svc.provisionOverBle(
                        wifiSsid: _ssidCtrl.text.trim(),
                        wifiPass: _passCtrl.text,
                        mqttUri: resolved,
                      );
                    },
                  ),
                ],
              ],
            );
          },
        );
      },
    );
  }
}
