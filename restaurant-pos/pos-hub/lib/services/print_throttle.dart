/// Enforces a cooldown between prints to the same Bluetooth printer.
///
/// Classic SPP printers need time to release the RFCOMM link. Two jobs sent
/// back-to-back to the same device — which happens when several stations share
/// one printer, e.g. a drink ticket followed by a receipt — otherwise fail
/// because the radio is still tearing down.
///
/// The clock and delay are injectable so the timing is unit-testable.
class PrintThrottle {
  PrintThrottle({this.cooldownMs = 1500, this.settleMs = 250});

  /// Minimum gap between two prints to the same device.
  int cooldownMs;

  /// Pause after closing a connection, before anything else may use it.
  int settleMs;

  /// Retries for a failed connection attempt.
  int maxAttempts = 3;

  final Map<String, DateTime> _lastUsed = {};

  DateTime Function() now = DateTime.now;
  Future<void> Function(int milliseconds) delay = _defaultDelay;

  static Future<void> _defaultDelay(int milliseconds) =>
      Future<void>.delayed(Duration(milliseconds: milliseconds));

  /// Milliseconds still to wait before the next print to [address].
  int remainingFor(String address) {
    final last = _lastUsed[address];
    if (last == null) return 0;
    final remaining = cooldownMs - now().difference(last).inMilliseconds;
    return remaining > 0 ? remaining : 0;
  }

  /// Blocks until [address] is free to accept another print.
  Future<void> waitFor(String address) async {
    final remaining = remainingFor(address);
    if (remaining > 0) await delay(remaining);
  }

  /// Records that a print to [address] just happened.
  void markUsed(String address) => _lastUsed[address] = now();

  /// Back-off between retry attempts.
  Future<void> backOff(int attempt) => delay(400 * attempt);

  /// Pause after closing the link so the printer can drain.
  Future<void> settle() async {
    if (settleMs > 0) await delay(settleMs);
  }

  void reset() => _lastUsed.clear();
}
