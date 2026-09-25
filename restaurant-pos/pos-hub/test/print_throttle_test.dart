import 'package:flutter_test/flutter_test.dart';

import 'package:restaurant_pos_hub/services/print_throttle.dart';

void main() {
  var waits = <int>[];
  var clock = DateTime(2026, 1, 1, 12, 0, 0);

  PrintThrottle build({int cooldownMs = 1500, int settleMs = 0}) {
    final throttle = PrintThrottle(cooldownMs: cooldownMs, settleMs: settleMs);
    throttle.delay = (ms) async => waits.add(ms);
    throttle.now = () => clock;
    return throttle;
  }

  setUp(() {
    waits = [];
    clock = DateTime(2026, 1, 1, 12, 0, 0);
  });

  test('waits out the remaining cooldown for the same printer', () async {
    final throttle = build(cooldownMs: 1500);

    throttle.markUsed('AA:BB:CC');
    clock = clock.add(const Duration(milliseconds: 500));
    await throttle.waitFor('AA:BB:CC');

    expect(waits, [1000]);
  });

  test('does not wait when the cooldown already elapsed', () async {
    final throttle = build(cooldownMs: 1500);

    throttle.markUsed('AA:BB:CC');
    clock = clock.add(const Duration(seconds: 3));
    await throttle.waitFor('AA:BB:CC');

    expect(waits, isEmpty);
  });

  test('different printers do not block each other', () async {
    final throttle = build(cooldownMs: 1500);

    throttle.markUsed('AA:BB:CC');
    await throttle.waitFor('11:22:33');

    expect(waits, isEmpty);
    expect(throttle.remainingFor('AA:BB:CC'), 1500);
  });

  test('remainingFor counts down and never goes negative', () {
    final throttle = build(cooldownMs: 1200);

    throttle.markUsed('AA:BB:CC');
    expect(throttle.remainingFor('AA:BB:CC'), 1200);
    clock = clock.add(const Duration(milliseconds: 700));
    expect(throttle.remainingFor('AA:BB:CC'), 500);
    clock = clock.add(const Duration(milliseconds: 900));
    expect(throttle.remainingFor('AA:BB:CC'), 0);
  });

  test('a zero cooldown disables the wait', () async {
    final throttle = build(cooldownMs: 0);

    throttle.markUsed('AA:BB:CC');
    await throttle.waitFor('AA:BB:CC');

    expect(waits, isEmpty);
  });

  test('settle pauses after closing the link', () async {
    final throttle = build(settleMs: 250);
    await throttle.settle();
    expect(waits, [250]);
  });
}
