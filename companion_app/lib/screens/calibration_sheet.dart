import 'package:flutter/material.dart';
import '../models/telemetry.dart';
import '../services/waste_connection_service.dart';

class CalibrationSheet extends StatefulWidget {
  final WasteConnectionService service;

  const CalibrationSheet({super.key, required this.service});

  @override
  State<CalibrationSheet> createState() => _CalibrationSheetState();
}

class _CalibrationSheetState extends State<CalibrationSheet> {
  double _fullCm = 10.0;
  double _emptyCm = 30.0;
  double _periodicMinutes = 15.0;
  double _oledSleepSeconds = 0.0;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Sensor & Power Calibration',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Updates are persisted to ESP32-S3 NVS over MQTT or BLE GATT (0xFF06).',
            style: TextStyle(color: Colors.white60, fontSize: 13),
          ),
          const SizedBox(height: 16),

          Text('100% Full Distance: ${_fullCm.toStringAsFixed(1)} cm'),
          Slider(
            value: _fullCm,
            min: 5.0,
            max: 25.0,
            divisions: 40,
            label: '${_fullCm.toStringAsFixed(1)} cm',
            onChanged: (v) {
              setState(() {
                _fullCm = v;
                if (_emptyCm <= _fullCm + 2.0) {
                  _emptyCm = (_fullCm + 5.0).clamp(10.0, 80.0);
                }
              });
            },
          ),

          Text('0% Empty Depth: ${_emptyCm.toStringAsFixed(1)} cm'),
          Slider(
            value: _emptyCm,
            min: 15.0,
            max: 80.0,
            divisions: 65,
            label: '${_emptyCm.toStringAsFixed(1)} cm',
            onChanged: (v) {
              setState(() {
                if (v > _fullCm + 2.0) {
                  _emptyCm = v;
                }
              });
            },
          ),

          Text('Periodic Background Check: ${_periodicMinutes.toInt()} min'),
          Slider(
            value: _periodicMinutes,
            min: 1.0,
            max: 60.0,
            divisions: 59,
            label: '${_periodicMinutes.toInt()} min',
            onChanged: (v) => setState(() => _periodicMinutes = v),
          ),

          Text(
            _oledSleepSeconds == 0
                ? 'Core 1 OLED Mode: Always On (0s)'
                : 'Core 1 OLED Auto-Sleep: ${_oledSleepSeconds.toInt()}s after activity',
          ),
          Slider(
            value: _oledSleepSeconds,
            min: 0.0,
            max: 120.0,
            divisions: 12,
            label: _oledSleepSeconds == 0
                ? 'Always On'
                : '${_oledSleepSeconds.toInt()}s',
            onChanged: (v) => setState(() => _oledSleepSeconds = v),
          ),

          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: const Icon(Icons.tune),
              label: const Text('Apply Configuration to W.A.S.T.E. Node'),
              onPressed: () async {
                final cfg = WasteBinConfig(
                  fullCm: _fullCm,
                  emptyCm: _emptyCm,
                  periodicIntervalS: (_periodicMinutes * 60).toInt(),
                  oledSleepTimeoutS: _oledSleepSeconds.toInt(),
                );
                await widget.service.updateBinConfig(cfg);
                if (context.mounted) {
                  Navigator.pop(context);
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}
