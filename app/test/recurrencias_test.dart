import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:recuerdame/recurrencias.dart';

void main() {
  final casos = jsonDecode(File('../shared/recurrencias.json').readAsStringSync()) as List;

  for (final caso in casos.cast<Map<String, dynamic>>()) {
    test('paridad con el servidor: ${caso['nombre']}', () {
      final inicio = DateTime.parse('${caso['dtstart']}Z');
      final obtenido = ocurrencias(inicio, caso['rrule'] as String?)
          .take(caso['n'] as int)
          .map((d) => d.toIso8601String().substring(0, 19))
          .toList();
      expect(obtenido, caso['esperado']);
    });
  }
}
