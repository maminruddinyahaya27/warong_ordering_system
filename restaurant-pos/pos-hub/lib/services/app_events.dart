import 'package:flutter/foundation.dart';

/// Lightweight in-app notifications so screens can refresh when orders arrive
/// over HTTP or are settled by the counter.
class AppEvents {
  static final ValueNotifier<int> ordersRevision = ValueNotifier<int>(0);
  static final ValueNotifier<int> queueRevision = ValueNotifier<int>(0);

  static void ordersChanged() => ordersRevision.value++;
  static void queueChanged() => queueRevision.value++;
}
