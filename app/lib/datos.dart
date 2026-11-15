// Lo que la app sabe y cómo habla con el servidor (contrato: docs/api.md).
//
// Todo el estado es la última `Foto` que mandó el servidor más la bandeja de salida
// (confirmaciones pendientes de enviar). Ambas viven en el almacén cifrado de Android
// (Keystore), igual que el token del celular.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:alarm/alarm.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'agenda.dart';

const servidor = String.fromEnvironment('SERVIDOR', defaultValue: 'https://recuerdame.danihami.xyz');
const almacen = FlutterSecureStorage();
const sistema = MethodChannel('recuerdame/sistema'); // solo existe con la app abierta

String nuevoId() {
  final b = List.generate(16, (_) => Random.secure().nextInt(256));
  b[6] = b[6] & 0x0f | 0x40; // UUID v4
  b[8] = b[8] & 0x3f | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// Hora local sin zona, como la guarda el servidor: "2026-11-15T08:00:00".
String iso(DateTime d) => d.toIso8601String().substring(0, 19);

// ---- modelo ----

class Persona {
  Persona(this.j);
  final Map<String, dynamic> j;
  String get id => j['id'];
  String get nombre => j['name'];
  List<String> get enGrande => (j['full_screen'] as List).cast();
  String? get pinHash => j['pin_hash'];
  bool get esGestor => j['is_manager'];
  List<Map<String, dynamic>> get celulares => (j['devices'] as List).cast();
}

class Recordatorio {
  Recordatorio({
    required this.id,
    required this.personaId,
    required this.inicio,
    this.texto = '',
    this.voz = 'tts',
    this.audioId,
    this.nivel = 'alarma',
    this.repetirCada = 10,
    this.repeticiones = 3,
    this.avisarGestores = true,
    this.regla,
    this.excepciones = const [],
    this.avisos = const [0],
    this.rev = 0,
    this.actualizado,
  });

  factory Recordatorio.desde(Map<String, dynamic> j) => Recordatorio(
    id: j['id'],
    personaId: j['person_id'],
    inicio: DateTime.parse(j['dtstart']),
    texto: j['text'],
    voz: j['voice'],
    audioId: j['audio_id'],
    nivel: j['alert_level'],
    repetirCada: j['repeat_every_min'],
    repeticiones: j['max_repeats'],
    avisarGestores: j['notify_managers'],
    regla: j['rrule'],
    excepciones: [for (final x in j['exdates']) DateTime.parse(x)],
    avisos: (j['alert_offsets'] as List).cast(),
    rev: j['rev'],
    actualizado: DateTime.parse(j['updated_at']),
  );

  String id, personaId, texto, voz, nivel;
  String? audioId, regla;
  DateTime inicio; // hora local del receptor
  int repetirCada, repeticiones, rev;
  bool avisarGestores;
  List<DateTime> excepciones;
  List<int> avisos; // minutos respecto a la hora, <= 0
  DateTime? actualizado;

  Map<String, dynamic> aJson() => {
    'person_id': personaId,
    'text': texto,
    'voice': voz,
    'audio_id': voz == 'recording' ? audioId : null,
    'alert_level': nivel,
    'repeat_every_min': repetirCada,
    'max_repeats': repeticiones,
    'notify_managers': avisarGestores,
    'dtstart': iso(inicio),
    'rrule': regla,
    'exdates': [for (final x in excepciones) iso(x)],
    'alert_offsets': avisos,
    'rev': rev,
  };
}

class Foto {
  Foto(this.j);
  final Map<String, dynamic> j;
  String get yo => j['me']['person_id'];
  bool get soyGestor => j['me']['role'] == 'gestor';
  late final personas = [for (final p in j['persons']) Persona(p)];
  late final recordatorios = [for (final r in j['reminders']) Recordatorio.desde(r)];
  List<Map<String, dynamic>> get eventos => (j['events'] as List).cast();
  Persona? persona(String id) => personas.where((p) => p.id == id).firstOrNull;
}

Future<Foto?> fotoGuardada() async {
  final t = await almacen.read(key: 'foto');
  return t == null ? null : Foto(jsonDecode(t));
}

// ---- servidor ----

class ErrorApi implements Exception {
  ErrorApi(this.estado, this.mensaje);
  final int estado;
  final String mensaje;
  @override
  String toString() => mensaje;
}

Future<http.Response> llamar(String metodo, String ruta, {Object? json, List<int>? wav}) async {
  final token = await almacen.read(key: 'token');
  final pedido = http.Request(metodo, Uri.parse('$servidor$ruta'));
  if (token != null) pedido.headers['Authorization'] = 'Bearer $token';
  if (json != null) {
    pedido.headers['Content-Type'] = 'application/json';
    pedido.body = jsonEncode(json);
  }
  if (wav != null) {
    pedido.headers['Content-Type'] = 'audio/wav';
    pedido.bodyBytes = wav;
  }
  final r = await http.Response.fromStream(await pedido.send().timeout(const Duration(seconds: 40)));
  if (r.statusCode < 400) return r;
  if (r.statusCode == 401 && token != null) await salir(); // celular revocado o desvinculado
  final detalle = r.headers['content-type'] == 'application/json' ? jsonDecode(r.body)['detail'] : null;
  throw ErrorApi(r.statusCode, detalle is String ? detalle : 'El servidor respondió ${r.statusCode}');
}

// ---- sesión ----

Future<void> ingresarGestor() async {
  // Auth Tab de Chrome: un Custom Tab normal no devuelve el control a la app porque
  // Chrome bloquea abrir el esquema propio sin un toque del usuario.
  const authentik = 'https://auth.danihami.xyz/application/o';
  const cliente = 'recuerdame-app';
  const vuelta = 'xyz.danihami.recuerdame:/oauth';
  String aleatorio() =>
      base64Url.encode(List.generate(32, (_) => Random.secure().nextInt(256))).replaceAll('=', '');
  final verificador = aleatorio();
  final estado = aleatorio();
  final respuesta = Uri.parse(
    await FlutterWebAuth2.authenticate(
      url: Uri.parse('$authentik/authorize/')
          .replace(
            queryParameters: {
              'response_type': 'code',
              'client_id': cliente,
              'redirect_uri': vuelta,
              // Sin `offline_access`: Authentik metería una página de consentimiento.
              'scope': 'openid profile email',
              'state': estado,
              'code_challenge': base64Url
                  .encode(sha256.convert(ascii.encode(verificador)).bytes)
                  .replaceAll('=', ''),
              'code_challenge_method': 'S256',
            },
          )
          .toString(),
      callbackUrlScheme: 'xyz.danihami.recuerdame',
    ),
  ).queryParameters;
  if (respuesta['state'] != estado) throw ErrorApi(0, 'Respuesta de login inesperada');
  final tokens = await http.post(
    Uri.parse('$authentik/token/'),
    body: {
      'grant_type': 'authorization_code',
      'code': respuesta['code'] ?? '',
      'redirect_uri': vuelta,
      'client_id': cliente,
      'code_verifier': verificador,
    },
  );
  if (tokens.statusCode != 200) throw ErrorApi(tokens.statusCode, 'Authentik rechazó el login');
  final r = await llamar(
    'POST',
    '/v1/auth/oidc',
    json: {'id_token': jsonDecode(tokens.body)['id_token'], 'model': await _modelo()},
  );
  await almacen.write(key: 'token', value: jsonDecode(r.body)['token']);
  await sincronizar();
}

Future<void> vincular(String codigo) async {
  final r = await llamar('POST', '/v1/pair', json: {'code': codigo, 'model': await _modelo()});
  await almacen.write(key: 'token', value: jsonDecode(r.body)['token']);
  await sincronizar();
}

Future<void> salir() async {
  await almacen.deleteAll();
  await Alarm.stopAll();
  await borrarAudios();
  _cambios.add(ultimaFoto = null);
}

// ---- sincronización ----

final _cambios = StreamController<Foto?>.broadcast();

/// La última foto emitida, para las pantallas que se abren después.
Foto? ultimaFoto;

/// Cada foto nueva (o null al cerrar sesión), para que las pantallas se redibujen.
Stream<Foto?> get cambios => _cambios.stream;

Future<void> encolar(Map<String, dynamic> evento) =>
    almacen.write(key: 'bandeja.${evento['id']}', value: jsonEncode(evento));

Future<Foto?>? _enCurso;

/// Envía lo pendiente, trae la foto nueva y reprograma las alarmas. Sin red, reprograma
/// con lo que hay: las alarmas no dependen del servidor.
Future<Foto?> sincronizar() => _enCurso ??= _sincronizar().whenComplete(() => _enCurso = null);

Future<Foto?> _sincronizar() async {
  if (await almacen.read(key: 'token') == null) return null;
  var foto = await fotoGuardada();
  if (foto != null) await recogerAccionesNativas(foto);
  try {
    final todo = await almacen.readAll();
    final bandeja = {for (final e in todo.entries) if (e.key.startsWith('bandeja.')) e.key: e.value};
    final r = await llamar(
      'POST',
      '/v1/sync',
      json: {
        'app_version': (await PackageInfo.fromPlatform()).version,
        'model': await _modelo(),
        'tz_offset_min': DateTime.now().timeZoneOffset.inMinutes,
        'health': await salud(),
        'events': [for (final v in bandeja.values) jsonDecode(v)],
        'audios': await audiosDescargados(),
      },
    );
    for (final k in bandeja.keys) {
      await almacen.delete(key: k);
    }
    await almacen.write(key: 'foto', value: r.body);
    foto = Foto(jsonDecode(r.body));
    await descargarAudios(foto);
  } on ErrorApi catch (e) {
    if (e.estado == 401) return null;
  } catch (_) {
    // sin red: se sigue con la foto guardada
  }
  if (foto == null) return null;
  await programar(foto);
  if (foto.soyGestor) await revisarConfirmaciones(foto);
  _cambios.add(ultimaFoto = foto);
  return foto;
}

/// Salud del celular (plan §6). Se reporta en cada sincronización y el gestor la ve.
Future<Map<String, Object?>> salud() async {
  try {
    final s = {
      'notificaciones': await Permission.notification.isGranted,
      'alarmas_exactas': await Permission.scheduleExactAlarm.isGranted,
      'sin_ahorro_bateria': await Permission.ignoreBatteryOptimizations.isGranted,
      'sobre_otras_apps': await Permission.systemAlertWindow.isGranted,
    };
    await almacen.write(key: 'salud', value: jsonEncode(s));
    return s;
  } catch (_) {
    return jsonDecode(await almacen.read(key: 'salud') ?? '{}'); // sin acceso desde segundo plano
  }
}

Future<String> _modelo() async {
  try {
    final m = await sistema.invokeMethod<String>('modelo') ?? '';
    await almacen.write(key: 'modelo', value: m);
    return m;
  } on MissingPluginException {
    return await almacen.read(key: 'modelo') ?? '';
  }
}
