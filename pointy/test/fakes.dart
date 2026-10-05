import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy/api.dart';

/// Reads a JSON response captured from a running backend.
String fixture(String name) => File('test/fixtures/$name.json').readAsStringSync();

/// An ApiClient answered from fixtures, so widget tests run without a
/// server. [overrides] maps "METHOD /path" to (status, body).
ApiClient fakeApi({Map<String, (int, String)> overrides = const {}, List<http.Request>? log}) {
  final trips = jsonDecode(fixture('trips')) as List;
  final routes = <String, (int, String)>{
    'GET /api/me': (200, fixture('me')),
    'GET /api/trips': (200, fixture('trips')),
    'GET /api/history': (200, fixture('history')),
    'GET /api/alerts': (200, fixture('alerts')),
    'GET /api/contacts': (200, fixture('contacts')),
    'GET /api/money-requests': (200, fixture('money_requests')),
    'POST /api/suggestions': (200, fixture('suggestion')),
    'POST /api/alerts/seen': (200, '{"ok":true}'),
    for (final t in trips) 'GET /api/trips/${(t as Map)['id']}': (200, jsonEncode(t)),
    ...overrides,
  };
  final client = MockClient((req) async {
    log?.add(req);
    final hit = routes['${req.method} ${req.url.path}'];
    if (hit == null) return http.Response(jsonEncode({'error': {'code': 'not_found', 'message': 'no fixture for ${req.url.path}'}}), 404);
    return http.Response.bytes(utf8.encode(hit.$2), hit.$1, headers: {'content-type': 'application/json'});
  });
  return ApiClient(baseUrl: 'http://test', client: client)..token = 'test-token';
}
