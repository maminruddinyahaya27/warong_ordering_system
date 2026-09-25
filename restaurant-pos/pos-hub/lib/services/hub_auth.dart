import 'dart:convert';

import 'package:shelf/shelf.dart';

/// HTTP Basic auth for the hub's embedded server.
///
/// When no credentials are configured the server stays open (trusted LAN).
/// `GET /health` is always exempt so clients can probe the host before they
/// have credentials.
class HubAuth {
  static String user = '';
  static String pass = '';

  static bool get enabled => user.isNotEmpty || pass.isNotEmpty;

  static void configure({required String user, required String pass}) {
    HubAuth.user = user.trim();
    HubAuth.pass = pass;
  }

  static bool verify(String? header) {
    if (!enabled) return true;
    if (header == null || !header.startsWith('Basic ')) return false;
    String decoded;
    try {
      decoded = utf8.decode(base64Decode(header.substring(6).trim()));
    } catch (_) {
      return false;
    }
    final separator = decoded.indexOf(':');
    if (separator < 0) return false;
    final givenUser = decoded.substring(0, separator);
    final givenPass = decoded.substring(separator + 1);
    return _constantTimeEquals(givenUser, user) &&
        _constantTimeEquals(givenPass, pass);
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  static Middleware middleware() {
    return (Handler inner) {
      return (Request request) async {
        if (!enabled) return inner(request);
        if (request.method == 'GET' && request.url.path == 'health') {
          return inner(request);
        }
        if (verify(request.headers['authorization'])) {
          return inner(request);
        }
        return Response(
          401,
          body: 'Authentication required',
          headers: {
            'WWW-Authenticate':
                'Basic realm="Restaurant POS Hub", charset="UTF-8"',
          },
        );
      };
    };
  }
}
