// Las alarmas viven en el celular (plan §3): de la foto se calculan las de los próximos
// 7 días y se programan con el plugin `alarm`. Sonar no depende de la red ni de Flutter
// (la pantalla de alarma es nativa: AlarmaActivity.kt).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:alarm/alarm.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';

import 'datos.dart';
import 'recurrencias.dart';

const _ventana = Duration(days: 7);
const _ventanaRepeticiones = Duration(days: 2); // Android permite ~500 alarmas por app
const _gracia = Duration(minutes: 15); // como el plugin: una alarma vencida hace poco aún suena
const duracionTimbre = Duration(seconds: 60); // cada intento suena esto y se calla solo

/// Una vez que suena (o sonaría) algo: un intento de un aviso de una ocurrencia.
class Alerta {
  Alerta(this.r, this.ocurrencia, this.aviso, this.intento, this.hora, this.id);
  final Recordatorio r;
  final DateTime ocurrencia; // hora local de la ocurrencia (sin aviso previo)
  final int aviso; // minutos (<= 0)
  final int intento;
  final DateTime hora;
  final int id;
  String get clave => claveOcurrencia(r.id, ocurrencia, aviso);
}

String claveOcurrencia(String rid, DateTime ocurrencia, int aviso) => '$rid|${iso(ocurrencia)}|$aviso';

/// Base del id de alarma (25 bits). Los bits bajos los lee Alarmas.kt: 0-2 intento,
/// 3 nivel Notificación, 4 abrir en grande.
/// ponytail: hash de 25 bits; con unos cientos de alarmas el choque es improbable.
int _base(String clave) {
  var h = 0x811c9dc5; // FNV-1a
  for (final c in utf8.encode(clave)) {
    h = ((h ^ c) * 0x01000193) & 0xffffffff;
  }
  return (h & 0x1ffffff) | 1;
}

int _id(String clave, {required bool notificacion, required bool grande, required int intento}) =>
    _base(clave) << 5 | (grande ? 16 : 0) | (notificacion ? 8 : 0) | intento;

/// Ocurrencias (hora local) de [r] entre [desde] y [hasta], sin las excepciones.
Iterable<DateTime> ocurrenciasEntre(Recordatorio r, DateTime desde, DateTime hasta) sync* {
  final i = r.inicio;
  for (final o in ocurrencias(DateTime.utc(i.year, i.month, i.day, i.hour, i.minute, i.second), r.regla)) {
    final local = DateTime(o.year, o.month, o.day, o.hour, o.minute, o.second);
    if (local.isAfter(hasta)) return;
    if (!local.isBefore(desde) && !r.excepciones.contains(local)) yield local;
  }
}

/// Lo que debe sonar en ESTE celular entre [desde] y [hasta].
Iterable<Alerta> alertas(Foto f, DateTime desde, DateTime hasta) sync* {
  final yo = f.persona(f.yo);
  final repeticionesHasta = DateTime.now().add(_ventanaRepeticiones);
  for (final r in f.recordatorios) {
    if (r.personaId != f.yo || r.nivel == 'discreto') continue;
    final notif = r.nivel == 'notificacion';
    final grande = yo?.enGrande.contains(r.nivel) ?? false;
    final tramo = Duration(minutes: r.repeticiones * r.repetirCada);
    for (final o in ocurrenciasEntre(r, desde.subtract(tramo), hasta.add(const Duration(days: 7)))) {
      for (final aviso in r.avisos) {
        final clave = claveOcurrencia(r.id, o, aviso);
        final intentos = aviso == 0 ? r.repeticiones : 0;
        for (var k = 0; k <= intentos; k++) {
          final hora = o.add(Duration(minutes: aviso + k * r.repetirCada));
          if (hora.isBefore(desde) || hora.isAfter(hasta) || (k > 0 && hora.isAfter(repeticionesHasta))) continue;
          yield Alerta(r, o, aviso, k, hora, _id(clave, notificacion: notif, grande: grande, intento: k));
        }
      }
    }
  }
}

/// Claves de ocurrencias ya confirmadas (en el servidor o pendientes de enviar).
Future<Set<String>> confirmadas(Foto f) async {
  final pendientes = (await almacen.readAll()).entries
      .where((e) => e.key.startsWith('bandeja.'))
      .map((e) => jsonDecode(e.value) as Map<String, dynamic>);
  return {
    for (final e in [...f.eventos, ...pendientes])
      if (e['type'] == 'acked')
        claveOcurrencia(e['reminder_id'], DateTime.parse(e['occurrence_at']), e['offset_min']),
  };
}

Future<void> programar(Foto f) async {
  final ahora = DateTime.now();
  final hechas = await confirmadas(f);
  final deseadas = {
    for (final a in alertas(f, ahora.subtract(_gracia), ahora.add(_ventana)))
      if (!hechas.contains(a.clave)) a.id: a,
  };
  final actuales = {for (final a in await Alarm.getAlarms()) a.id: a};
  for (final id in actuales.keys) {
    if (!deseadas.containsKey(id) && !await Alarm.isRinging(id)) await Alarm.stop(id);
  }
  for (final a in deseadas.values) {
    if (!a.hora.isAfter(ahora)) continue; // ya sonó (o está sonando): no repetirla
    final nueva = await _ajustes(a);
    final vieja = actuales[a.id];
    if (vieja == null ||
        vieja.dateTime != nueva.dateTime ||
        vieja.assetAudioPath != nueva.assetAudioPath ||
        vieja.notificationSettings != nueva.notificationSettings) {
      await Alarm.set(alarmSettings: nueva);
    }
  }
}

Future<AlarmSettings> _ajustes(Alerta a) async {
  final alarma = a.r.nivel == 'alarma';
  final propia = a.r.audioId != null && await File('${await _voces()}/${a.r.audioId}.wav').exists();
  final audio = propia ? a.r.audioId! : await _aviso();
  final hh = '${a.ocurrencia.hour}:${a.ocurrencia.minute.toString().padLeft(2, '0')}';
  return AlarmSettings(
    id: a.id,
    dateTime: a.hora,
    // Relativo a la carpeta de documentos: el plugin lo resuelve ahí.
    assetAudioPath: alarma ? 'voz/$audio-largo.wav' : 'voz/$audio.wav',
    loopAudio: false, // el audio dura lo que dura el timbre: se calla solo aunque nadie lo toque
    vibrate: alarma,
    androidFullScreenIntent: true, // bloqueado abre siempre; en uso lo decide App.kt
    allowSameSecondScheduling: true,
    warningNotificationOnKill: false,
    volumeSettings: alarma
        ? const VolumeSettings.fixed(volume: 0.8, volumeEnforced: true) // suena aunque esté en silencio
        : const VolumeSettings.fixed(),
    notificationSettings: NotificationSettings(
      title: a.aviso == 0 ? 'Recuérdame · $hh' : '${_antes(-a.aviso)} · $hh',
      body: a.r.texto,
      stopButton: 'Más tarde',
      // Solo el último intento deja el aviso a la vista; los anteriores vuelven a sonar.
      keepNotificationAfterAlarmEnds: a.intento == (a.aviso == 0 ? a.r.repeticiones : 0),
    ),
  );
}

String _antes(int minutos) => minutos % 1440 == 0
    ? (minutos == 1440 ? 'Mañana' : 'En ${minutos ~/ 1440} días')
    : minutos % 60 == 0
    ? 'En ${minutos ~/ 60} h'
    : 'En $minutos min';

/// Confirmación desde la app (no desde la pantalla de alarma, que lo hace en nativo).
Future<void> confirmar(Recordatorio r, DateTime ocurrencia, int aviso) async {
  await encolar(_evento(r, ocurrencia, aviso, 'acked', DateTime.now()));
  final base = _base(claveOcurrencia(r.id, ocurrencia, aviso));
  for (final a in await Alarm.getAlarms()) {
    if (a.id >> 5 == base) await Alarm.stop(a.id);
  }
  await sincronizar();
}

Map<String, dynamic> _evento(Recordatorio r, DateTime ocurrencia, int aviso, String tipo, DateTime en) => {
  'id': nuevoId(),
  'reminder_id': r.id,
  'occurrence_at': iso(ocurrencia),
  'offset_min': aviso,
  'type': tipo,
  'at': en.toUtc().toIso8601String(),
};

/// Pasa a la bandeja lo que se tocó en la pantalla nativa (Alarmas.kt deja un archivo).
Future<void> recogerAccionesNativas(Foto f) async {
  final carpeta = Directory('${(await getApplicationSupportDirectory()).path}/acciones');
  if (!await carpeta.exists()) return;
  final ahora = DateTime.now();
  final porBase = {for (final a in alertas(f, ahora.subtract(const Duration(days: 3)), ahora.add(_ventana))) a.id >> 5: a};
  await for (final archivo in carpeta.list()) {
    if (archivo is! File || !archivo.path.endsWith('.json')) continue;
    final j = jsonDecode(await archivo.readAsString());
    final a = porBase[(j['id'] as int) >> 5];
    if (a != null) {
      await encolar(_evento(a.r, a.ocurrencia, a.aviso, j['type'], DateTime.fromMillisecondsSinceEpoch(j['at'])));
    }
    await archivo.delete();
  }
}

// ---- audios ----

Future<String> _voces() async {
  final d = Directory('${(await getApplicationDocumentsDirectory()).path}/voz');
  await d.create(recursive: true);
  return d.path;
}

/// Ids de las voces que ya están en el celular (el servidor borra la TTS al llegar a todos).
Future<List<String>> audiosDescargados() async => [
  await for (final f in Directory(await _voces()).list())
    if (f.path.endsWith('.wav') && !f.path.endsWith('-largo.wav') && !f.path.endsWith('aviso.wav'))
      f.uri.pathSegments.last.replaceAll('.wav', ''),
];

Future<void> descargarAudios(Foto f) async {
  final carpeta = await _voces();
  for (final r in f.recordatorios) {
    if (r.personaId != f.yo || r.audioId == null || await File('$carpeta/${r.audioId}.wav').exists()) continue;
    try {
      await _guardarVoz(r.audioId!, (await llamar('GET', '/v1/audio/${r.audioId}')).bodyBytes);
    } catch (_) {
      // sin red: suena el aviso genérico y se reintenta en la próxima sincronización
    }
  }
}

Future<void> _guardarVoz(String nombre, Uint8List wav) async {
  final carpeta = await _voces();
  await File('$carpeta/$nombre-largo.wav').writeAsBytes(alargarWav(wav, duracionTimbre));
  await File('$carpeta/$nombre.wav').writeAsBytes(wav); // al final: su existencia marca "listo"
}

/// Aviso genérico ("Tienes un recordatorio") para cuando falta la voz propia o no tiene voz.
Future<String> _aviso() async {
  if (!await File('${await _voces()}/aviso.wav').exists()) {
    await _guardarVoz('aviso', (await rootBundle.load('assets/aviso.wav')).buffer.asUint8List());
  }
  return 'aviso';
}

Future<void> borrarAudios() async {
  final d = Directory('${(await getApplicationDocumentsDirectory()).path}/voz');
  if (await d.exists()) await d.delete(recursive: true);
}

/// Repite la voz (con una pausa) hasta llenar [duracion]: así el timbre se calla solo.
Uint8List alargarWav(Uint8List wav, Duration duracion) {
  final b = ByteData.sublistView(wav);
  int? canales, muestreo, bits;
  Uint8List? pcm;
  for (var i = 12; i + 8 <= wav.length;) {
    final id = String.fromCharCodes(wav, i, i + 4);
    final largo = b.getUint32(i + 4, Endian.little);
    if (id == 'fmt ') {
      canales = b.getUint16(i + 10, Endian.little);
      muestreo = b.getUint32(i + 12, Endian.little);
      bits = b.getUint16(i + 22, Endian.little);
    } else if (id == 'data') {
      pcm = Uint8List.sublistView(wav, i + 8, (i + 8 + largo).clamp(0, wav.length));
    }
    i += 8 + largo + (largo & 1);
  }
  if (canales == null || muestreo == null || bits == null || pcm == null) return wav;
  final porSegundo = muestreo * canales * bits ~/ 8;
  final pausa = Uint8List((porSegundo * 2.5).round() & ~1); // 2,5 s de silencio
  final total = porSegundo * duracion.inSeconds;
  final cuerpo = BytesBuilder(copy: false);
  while (cuerpo.length < total) {
    cuerpo
      ..add(pcm)
      ..add(pausa);
  }
  final datos = cuerpo.takeBytes();
  final cabecera = ByteData(44)
    ..setUint32(0, 0x52494646) // RIFF
    ..setUint32(4, 36 + datos.length, Endian.little)
    ..setUint32(8, 0x57415645) // WAVE
    ..setUint32(12, 0x666d7420) // fmt
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little) // PCM
    ..setUint16(22, canales, Endian.little)
    ..setUint32(24, muestreo, Endian.little)
    ..setUint32(28, porSegundo, Endian.little)
    ..setUint16(32, canales * bits ~/ 8, Endian.little)
    ..setUint16(34, bits, Endian.little)
    ..setUint32(36, 0x64617461) // data
    ..setUint32(40, datos.length, Endian.little);
  return (BytesBuilder(copy: false)
        ..add(cabecera.buffer.asUint8List())
        ..add(datos))
      .takeBytes();
}

// ---- aviso al gestor: "no confirmó" (plan §5) ----

final _notificaciones = FlutterLocalNotificationsPlugin();

/// Tras cada sincronización del gestor: ocurrencias de sus receptores cuyo plazo venció
/// (hora + repeticiones + 5 min) sin confirmación.
/// ponytail: se revisa al sincronizar (cada ~15 min), no con una alarma exacta propia;
/// el aviso puede llegar hasta 15 min tarde.
Future<void> revisarConfirmaciones(Foto f) async {
  final avisados = List<String>.from(jsonDecode(await almacen.read(key: 'avisados') ?? '[]'));
  final hechas = await confirmadas(f);
  final ahora = DateTime.now().toUtc();
  var hubo = false;
  for (final p in f.personas.where((p) => p.id != f.yo)) {
    final desfase = Duration(
      minutes: p.celulares.map((c) => c['tz_offset_min'] as int?).nonNulls.firstOrNull ??
          DateTime.now().timeZoneOffset.inMinutes,
    );
    final sincronias = p.celulares.map((c) => c['last_sync_at'] as String?).nonNulls.map(DateTime.parse);
    final ultima = sincronias.isEmpty ? null : sincronias.reduce((a, b) => a.isAfter(b) ? a : b);
    DateTime local(DateTime utc) {
      final x = utc.add(desfase);
      return DateTime(x.year, x.month, x.day, x.hour, x.minute, x.second);
    }

    for (final r in f.recordatorios) {
      if (r.personaId != p.id || !r.avisarGestores || r.nivel == 'discreto') continue;
      final plazo = Duration(minutes: r.repeticiones * r.repetirCada + 5);
      final desde = ahora.subtract(plazo).subtract(const Duration(hours: 12));
      for (final o in ocurrenciasEntre(r, local(desde), local(ahora.subtract(plazo)))) {
        final clave = claveOcurrencia(r.id, o, 0);
        final instante = DateTime.utc(o.year, o.month, o.day, o.hour, o.minute).subtract(desfase);
        if (avisados.contains(clave) || hechas.contains(clave)) continue;
        if (r.actualizado != null && instante.isBefore(r.actualizado!)) continue; // creado después
        final hh = '${o.hour}:${o.minute.toString().padLeft(2, '0')}';
        final mensaje = ultima == null || ultima.isBefore(instante.add(plazo))
            ? 'Su celular no se ha sincronizado desde ${ultima == null ? 'que se vinculó' : _hora(ultima)}. No sé si vio «${r.texto}» ($hh).'
            : 'No confirmó «${r.texto}» de las $hh.';
        await _avisar(clave.hashCode & 0x7fffffff, p.nombre, mensaje);
        avisados.add(clave);
        hubo = true;
      }
    }
  }
  if (hubo) {
    final ultimos = avisados.length > 300 ? avisados.sublist(avisados.length - 300) : avisados;
    await almacen.write(key: 'avisados', value: jsonEncode(ultimos));
  }
}

String _hora(DateTime utc) {
  final l = utc.toLocal();
  return '${l.day}/${l.month} ${l.hour}:${l.minute.toString().padLeft(2, '0')}';
}

Future<void> _avisar(int id, String titulo, String texto) async {
  await _notificaciones.initialize(
    settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
  );
  await _notificaciones.show(
    id: id,
    title: titulo,
    body: texto,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        'confirmaciones',
        'Confirmaciones',
        channelDescription: 'Avisos cuando alguien no confirma un recordatorio',
        importance: Importance.high,
        priority: Priority.high,
        styleInformation: BigTextStyleInformation(texto),
      ),
    ),
  );
}
