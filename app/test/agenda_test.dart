import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:recuerdame/agenda.dart';
import 'package:recuerdame/editor.dart';

import 'package:recuerdame/datos.dart';

Foto _foto(List<Map<String, dynamic>> recordatorios, {List<String> grande = const ['alarma']}) => Foto({
  'me': {'person_id': 'yo', 'device_id': 'd', 'role': 'receptor'},
  'persons': [
    {'id': 'yo', 'name': 'Yo', 'full_screen': grande, 'pin_hash': null, 'is_manager': false, 'devices': []},
  ],
  'reminders': recordatorios,
  'events': [],
});

Map<String, dynamic> _r(String id, DateTime inicio, {String nivel = 'alarma', List<int> avisos = const [0]}) => {
  'id': id,
  'person_id': 'yo',
  'dtstart': iso(inicio),
  'text': 'Pastilla',
  'voice': 'tts',
  'audio_id': null,
  'alert_level': nivel,
  'repeat_every_min': 10,
  'max_repeats': 3,
  'notify_managers': true,
  'rrule': 'FREQ=DAILY',
  'exdates': [],
  'alert_offsets': avisos,
  'rev': 1,
  'updated_at': '2026-01-01T00:00:00+00:00',
};

void main() {
  final manana = DateTime.now().add(const Duration(days: 1));
  final ocho = DateTime(manana.year, manana.month, manana.day, 8);

  test('una ocurrencia: el aviso previo una vez y la hora con sus repeticiones', () {
    final f = _foto([_r('r1', ocho, avisos: [-60, 0])]);
    final a = alertas(f, ocho.subtract(const Duration(hours: 2)), ocho.add(const Duration(hours: 1))).toList();
    expect(a.map((x) => x.hora), [
      ocho.subtract(const Duration(hours: 1)),
      ocho,
      ocho.add(const Duration(minutes: 10)),
      ocho.add(const Duration(minutes: 20)),
      ocho.add(const Duration(minutes: 30)),
    ]);
    // Las repeticiones comparten ocurrencia (bits altos) y se distinguen por el intento.
    final deLaHora = a.where((x) => x.aviso == 0);
    expect(deLaHora.map((x) => x.id >> 5).toSet().length, 1);
    expect(deLaHora.map((x) => x.id & 7), [0, 1, 2, 3]);
    expect(a.first.id >> 5, isNot(a[1].id >> 5)); // el aviso previo es otra ocurrencia
  });

  test('los bits que lee Alarmas.kt: nivel y pantalla completa', () {
    final alarma = alertas(_foto([_r('r1', ocho)]), ocho, ocho).single;
    expect(alarma.id >> 3 & 1, 0);
    expect(alarma.id >> 4 & 1, 1);
    final aviso = alertas(_foto([_r('r1', ocho, nivel: 'notificacion')], grande: []), ocho, ocho).single;
    expect(aviso.id >> 3 & 1, 1);
    expect(aviso.id >> 4 & 1, 0);
    expect(alertas(_foto([_r('r1', ocho, nivel: 'discreto')]), ocho, ocho), isEmpty);
  });

  test('el timbre dura al menos un minuto aunque la voz sea corta', () {
    final pcm = Uint8List(22050 * 2); // 1 s a 22 kHz, 16 bits, mono
    final wav = alargarWav(Uint8List.fromList([..._cabecera(pcm.length), ...pcm]), duracionTimbre);
    final datos = ByteData.sublistView(wav).getUint32(40, Endian.little);
    expect(datos, greaterThanOrEqualTo(22050 * 2 * 60));
    expect(wav.length, 44 + datos);
  });

  test('el editor lee las reglas que escribe', () {
    for (final regla in [
      null,
      'FREQ=DAILY',
      'FREQ=DAILY;BYHOUR=8,14,20',
      'FREQ=DAILY;INTERVAL=15',
      'FREQ=WEEKLY;BYDAY=MO,WE,FR',
      'FREQ=MONTHLY;BYMONTHDAY=17',
      'FREQ=MONTHLY;BYDAY=-1TU',
      'FREQ=YEARLY',
    ]) {
      expect(Repeticion.leer(regla)!.regla(DateTime(2026, 11, 17, 8)), regla); // 17-11-2026 es martes
    }
    expect(Repeticion.leer('FREQ=DAILY;COUNT=3'), isNull);
  });
}

List<int> _cabecera(int bytes) {
  final b = ByteData(44)
    ..setUint32(0, 0x52494646)
    ..setUint32(4, 36 + bytes, Endian.little)
    ..setUint32(8, 0x57415645)
    ..setUint32(12, 0x666d7420)
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little)
    ..setUint16(22, 1, Endian.little)
    ..setUint32(24, 22050, Endian.little)
    ..setUint32(28, 44100, Endian.little)
    ..setUint16(32, 2, Endian.little)
    ..setUint16(34, 16, Endian.little)
    ..setUint32(36, 0x64617461)
    ..setUint32(40, bytes, Endian.little);
  return b.buffer.asUint8List();
}
