import 'package:shelf/shelf.dart';

/// CORS for the embedded server, so browser clients (the web mockups) can call
/// the hub directly from another device on the same Wi-Fi.
///
/// Preflight requests are answered before authentication: browsers never send
/// credentials on an OPTIONS preflight, so the hub must not 401 it.
const Map<String, String> _corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, PATCH, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, content-type',
  'Access-Control-Max-Age': '86400',
};

Middleware corsMiddleware() {
  return (Handler inner) {
    return (Request request) async {
      if (request.method == 'OPTIONS') {
        return Response(204, headers: Map.of(_corsHeaders));
      }
      final response = await inner(request);
      return response.change(headers: _corsHeaders);
    };
  };
}
