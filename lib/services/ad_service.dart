import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

/// AdMob ad unit IDs. Replace with your production IDs before release.
/// Test IDs: https://developers.google.com/admob/android/test-ads
class AdUnitIds {
  AdUnitIds._();

  static String get banner =>
      Platform.isAndroid
          ? 'ca-app-pub-2596031675923197/2825823206'
          : 'ca-app-pub-3940256099942544/2934735716';

  static String get interstitial =>
      Platform.isAndroid
          ? 'ca-app-pub-2596031675923197/3756449851'
          : 'ca-app-pub-3940256099942544/4411468910';
}

/// Manages AdMob initialization and interstitial ads.
/// Banner ads are created inline via [AdWidget] + [BannerAd].
class AdService {
  AdService._();
  static final AdService instance = AdService._();

  bool _initialized = false;

  /// Call at app startup. Safe to call multiple times.
  Future<void> initialize() async {
    if (_initialized) return;
    try {
      await MobileAds.instance.initialize();
      _initialized = true;
      debugPrint('AdService: initialized');
    } catch (e) {
      debugPrint('AdService: init failed — $e');
    }
  }

  /// Returns true if ads are available (mobile only, after init).
  bool get isAvailable => _initialized && (Platform.isAndroid || Platform.isIOS);
}
