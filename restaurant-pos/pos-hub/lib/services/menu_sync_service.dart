import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/product.dart';
import 'app_settings.dart';
import 'print_queue_db.dart';

class MenuSyncResult {
  final int count;
  final DateTime syncedAt;
  const MenuSyncResult(this.count, this.syncedAt);
}

/// Pulls the menu from the portal's `/api/export?format=array` feed and caches
/// it in SQLite so the counter keeps working when the portal is unreachable.
class MenuSyncService {
  static final MenuSyncService instance = MenuSyncService._internal();
  MenuSyncService._internal();

  final PrintQueueDb _db = PrintQueueDb.instance;
  final SettingsStore _settings = SettingsStore.instance;

  DateTime? lastSync;
  String? lastError;

  /// Pulls the menu, never throwing. A slow or unreachable portal must not block
  /// the app from starting or the Settings screen from saving.
  Future<MenuSyncResult?> syncQuietly() async {
    try {
      return await sync();
    } catch (error) {
      lastError = error.toString().replaceFirst('Exception: ', '');
      await _settings.save({'last_sync_error': lastError!});
      return null;
    }
  }

  /// Builds the export URL from the configured portal base, tolerating a base
  /// that already points at `/api/export`.
  static String exportUrl(String base) {
    var value = base.trim();
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    if (value.endsWith('/api/export')) {
      return '$value?format=array';
    }
    return '$value/api/export?format=array';
  }

  Future<MenuSyncResult> sync() async {
    final base = _settings.portalUrl;
    if (base.isEmpty) {
      throw Exception('Portal URL is not configured');
    }

    final headers = <String, String>{'Accept': 'application/json'};
    if (_settings.portalUser.isNotEmpty || _settings.portalPass.isNotEmpty) {
      final token =
          base64Encode(utf8.encode('${_settings.portalUser}:${_settings.portalPass}'));
      headers['authorization'] = 'Basic $token';
    }

    final response = await http
        .get(Uri.parse(exportUrl(base)), headers: headers)
        .timeout(const Duration(seconds: 15));

    if (response.statusCode == 401) {
      throw Exception('Portal rejected the credentials (401)');
    }
    if (response.statusCode != 200) {
      throw Exception('Portal returned ${response.statusCode}');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('Unexpected export payload');
    }

    final products = <Product>[];
    final menu = decoded['menu'];

    if (menu is List) {
      final grouped = menu.any((entry) =>
          entry is Map && entry['items'] is List);
      if (grouped) {
        // Grouped export: [{ name, color, items: [...] }]
        for (final group in menu) {
          if (group is! Map || group['items'] is! List) continue;
          final groupMap = Map<String, dynamic>.from(group);
          for (final item in (groupMap['items'] as List)) {
            if (item is! Map) continue;
            final map = Map<String, dynamic>.from(item);
            map.putIfAbsent('group', () => groupMap['name']);
            map.putIfAbsent('groupColor', () => groupMap['color']);
            products.add(_fromExport(map));
          }
        }
      } else {
        for (final entry in menu) {
          if (entry is Map) {
            products.add(_fromExport(Map<String, dynamic>.from(entry)));
          }
        }
      }
    } else if (menu is Map) {
      menu.forEach((key, value) {
        if (value is Map) {
          final map = Map<String, dynamic>.from(value);
          map.putIfAbsent('name', () => key.toString());
          products.add(_fromExport(map));
        }
      });
    }

    // Keep the portal's feed order: it carries the group order the portal admin
    // arranged, plus the item order inside each group.
    final ordered = [
      for (var index = 0; index < products.length; index++)
        products[index].withSortOrder(index),
    ];
    await _db.replaceProducts(ordered);

    // The portal's station list drives the hub's station -> printer mapping.
    final stationList = decoded['stations'];
    if (stationList is List) {
      await _db.replaceStations(
        stationList
            .map((value) => value.toString())
            .where((value) => value.trim().isNotEmpty)
            .toList(),
      );
    }

    lastSync = DateTime.now();
    lastError = null;
    await _settings.save({
      'last_sync_at': lastSync!.toIso8601String(),
      'last_sync_error': '',
    });
    return MenuSyncResult(products.length, lastSync!);
  }

  static Product _fromExport(Map<String, dynamic> entry) {
    final name = entry['name']?.toString() ?? '';
    return Product(
      sku: (entry['id'] ?? entry['sku'] ?? name).toString(),
      name: name,
      price: (entry['price'] as num?)?.toDouble() ?? 0,
      station: entry['station']?.toString() ?? 'KITCHEN',
      category: (entry['group'] ?? entry['category'] ?? 'MENU').toString(),
      available: entry['available'] != false,
      color: (entry['groupColor'] ?? entry['color'] ?? '').toString(),
    );
  }
}
