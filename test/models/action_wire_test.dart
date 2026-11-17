import 'dart:convert';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:test/test.dart';

void main() {
  test('every RPC method survives request and response JSON serialization', () {
    for (final method in ActionMethod.values) {
      final action = Action(id: 'wire-test', method: method, data: true);
      final request = jsonDecode(jsonEncode(action)) as Map<String, dynamic>;
      expect(request['method'], method.name, reason: method.name);
      expect(Action.fromJson(request).method, method, reason: method.name);
      final result = ActionResult.fromJson({
        'id': action.id,
        'method': method.name,
        'code': 0,
        'data': {'supported': true, 'enabled': false, 'active': false},
      });
      expect(result.method, method, reason: method.name);
      final response = jsonDecode(jsonEncode(result)) as Map<String, dynamic>;
      expect(response['method'], method.name, reason: method.name);
    }
  });
}
