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

  @override
  void dispose() {
    _scanSub?.cancel();
    FlutterBluePlus.stopScan();
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
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return ListenableBuilder(
          listenable: widget.service,
          builder: (context, _) {
            return ListView(
              controller: scrollController,
              padding: const EdgeInsets.all(20),
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Connectivity & BLE Provisioning',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  widget.service.statusMessage,
                  style: TextStyle(color: Colors.tealAccent.shade200, fontSize: 13),
                ),
                const Divider(height: 28),

                // 1. Phone MQTT Broker Connection
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      '1. MQTT Broker (Flespi / LAN / Cloud)',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
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
                    hintText: 'mqtt://mqtt.flespi.io:1883 or mqtt://<TOKEN>@mqtt.flespi.io:1883',
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
                    labelText: 'Target Device ID (blank = auto-discover smartbin/+)',
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
                        icon: Icon(widget.service.isMqttConnected
                            ? Icons.sync
                            : Icons.power),
                        label: Text(widget.service.isMqttConnected
                            ? 'Reconnect MQTT'
                            : 'Connect MQTT'),
                        onPressed: () {
                          final resolved = _resolvedMqttUri();
                          _mqttCtrl.text = resolved;
                          widget.service.connectMqtt(
                            brokerUri: resolved,
                            deviceId: _deviceIdCtrl.text,
                          );
                        },
                      ),
                    ),
                    if (widget.service.isMqttConnected) ...[
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: widget.service.disconnectMqtt,
                        child: const Text('Disconnect'),
                      ),
                    ],
                  ],
                ),
                const Divider(height: 32),

                // 2. BLE Scanner & Failover Connection
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      '2. Direct BLE GATT (0xFF00)',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
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
                        subtitle: Text('RSSI: ${r.rssi} dBm • ${r.device.remoteId}'),
                        trailing: FilledButton(
                          onPressed: () async {
                            final ok =
                                await widget.service.connectBleDevice(r.device);
                            if (ok) {
                              await _loadCurrentBleConfig();
                            }
                          },
                          child: const Text('Connect'),
                        ),
                      ),
                    );
                  }),

                // 3. Provision NVS Credentials over BLE
                if (widget.service.isBleConnected) ...[
                  const Divider(height: 32),
                  const Text(
                    '3. Provision ESP32-S3 NVS over BLE (0xFF01–0xFF04)',
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
                      await widget.service.provisionOverBle(
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
