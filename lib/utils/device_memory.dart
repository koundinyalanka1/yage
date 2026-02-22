import 'dart:io';

import 'package:flutter/services.dart';

/// Cached device memory in MB. Fetched at startup for rewind buffer sizing.
int? deviceMemoryMB;

const _channel = MethodChannel('com.yourmateapps.retropal/device');

/// Fetch and cache total device RAM in MB. Call at app startup.
/// On Android returns total physical memory; on other platforms returns null.
Future<void> initDeviceMemory() async {
  if (deviceMemoryMB != null) return;
  try {
    if (Platform.isAndroid) {
      deviceMemoryMB = await _channel.invokeMethod<int>('getDeviceMemoryMB');
    }
  } catch (_) {
    deviceMemoryMB = null;
  }
}

/// Max rewind snapshots to avoid OOM on low-RAM devices.
/// GBA/SNES save states ~0.5–2 MB each; 720 × 1.5 MB ≈ 1 GB.
/// Returns capacity cap: 120 for <2 GB, 240 for 2–4 GB, 720 for 4+ GB.
int rewindCapacityCap() {
  final mb = deviceMemoryMB;
  if (mb == null || mb < 2048) return 120;   // <2 GB: 10 s at 12 captures/s
  if (mb < 4096) return 240;                 // 2–4 GB: 20 s
  return 720;                                // 4+ GB: 60 s
}
