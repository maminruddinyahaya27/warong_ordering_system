import 'dart:convert';

/// Connection + credentials for the POS Hub tablet, shared by the order and
/// menu services.
class HubConfig {
  static String hostIp = '';
  static int hostPort = 8080;
  static String user = '';
  static String pass = '';

  /// Optional explicit menu URL. When empty the hub's `/menu` is used.
  static String menuUrl = '';

  static bool get hasHost => hostIp.trim().isNotEmpty;

  static String get baseUrl => 'http://${hostIp.trim()}:$hostPort';

  static String get resolvedMenuUrl =>
      menuUrl.trim().isNotEmpty ? menuUrl.trim() : '$baseUrl/menu';

  static bool get authEnabled => user.isNotEmpty || pass.isNotEmpty;

  static Map<String, String> get authHeaders {
    if (!authEnabled) return const {};
    final token = base64Encode(utf8.encode('$user:$pass'));
    return {'authorization': 'Basic $token'};
  }
}
