import 'dart:async';

import 'package:flutter/services.dart';

import 'app_settings.dart';

/// Keeps the tablet's screen on while the till is being used, and releases it
/// after [SettingsStore.keepAwakeMinutes] of no interaction so the panel can
/// sleep when the shop is idle.
///
/// Uses the app's existing method channel — no plugin or extra permission.
class ScreenAwake {
  static final ScreenAwake instance = ScreenAwake._internal();
  ScreenAwake._internal();

  static const MethodChannel _channel =
      MethodChannel('com.restaurant.pos/network');

  /// How often the idle clock is checked.
  static const Duration checkInterval = Duration(seconds: 30);

  DateTime _lastInteraction = DateTime.now();
  bool _keepOn = false;
  bool _started = false;
  Timer? _timer;

  bool get keepScreenOn => _keepOn;

  Duration get idleLimit =>
      Duration(minutes: SettingsStore.instance.keepAwakeMinutes);

  Duration get idleFor => DateTime.now().difference(_lastInteraction);

  /// Starts watching while the app is in the foreground.
  void start() {
    _started = true;
    _lastInteraction = DateTime.now();
    _timer ??= Timer.periodic(checkInterval, (_) => _evaluate());
    _evaluate();
  }

  /// Releases the screen when the app goes to the background.
  void stop() {
    _started = false;
    _timer?.cancel();
    _timer = null;
    unawaited(_setKeepOn(false));
  }

  /// Any touch resets the idle clock.
  void noteInteraction() {
    _lastInteraction = DateTime.now();
    if (_started && !_keepOn) _evaluate();
  }

  void _evaluate() {
    if (!_started) return;
    final expired = idleFor >= idleLimit;
    final shouldKeepOn = !expired;
    if (shouldKeepOn != _keepOn) {
      unawaited(_setKeepOn(shouldKeepOn));
    }
  }

  Future<void> _setKeepOn(bool on) async {
    _keepOn = on;
    try {
      await _channel.invokeMethod('setKeepScreenOn', {'on': on});
    } catch (_) {
      // Not on Android / no activity — harmless.
    }
  }
}
