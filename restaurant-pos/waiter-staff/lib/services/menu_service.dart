import 'dart:convert';
import 'package:http/http.dart' as http;

import '../models/menu_item.dart';
import 'hub_config.dart';

/// Fetches the menu from the POS Hub's `/menu` feed (which caches the portal's
/// MongoDB-backed export), falling back to an explicit menu URL if configured.
class MenuService {
  static Future<List<MenuItem>> fetchMenu() async {
    if (!HubConfig.hasHost && HubConfig.menuUrl.trim().isEmpty) {
      throw Exception('Host or menu URL is not configured');
    }

    final resp = await http.get(
      Uri.parse(HubConfig.resolvedMenuUrl),
      headers: {'Accept': 'application/json', ...HubConfig.authHeaders},
    ).timeout(const Duration(seconds: 10));

    if (resp.statusCode == 401) {
      throw Exception('Host rejected the credentials (401)');
    }
    if (resp.statusCode != 200) {
      throw Exception('Menu API returned ${resp.statusCode}');
    }

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final items = (data['items'] as List?) ?? [];
    return items
        .map((e) => MenuItem.fromJson(e as Map<String, dynamic>))
        .where((m) => m.name.isNotEmpty)
        .toList();
  }
}
