// SPIKE fase 0(a): ¿suena la alarma en un celular real (pantalla completa,
// en silencio, con la app cerrada, tras reiniciar)? Se reemplaza en la fase 1.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:alarm/alarm.dart';
import 'package:alarm/utils/alarm_set.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

const _alarmId = 1;
const _autoSeg = int.fromEnvironment('AUTO_SEG'); // solo pruebas: programa al arrancar
const _texto = 'Tomar la pastilla de la presión (Losartán)';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Alarm.init();
  if (_autoSeg > 0 && !await Alarm.isRinging() && await Alarm.getAlarm(_alarmId) == null) {
    await programar(const Duration(seconds: _autoSeg));
  }
  runApp(const MaterialApp(home: Inicio()));
}

Future<void> programar(Duration en) => Alarm.set(
  alarmSettings: AlarmSettings(
    id: _alarmId,
    dateTime: DateTime.now().add(en),
    assetAudioPath: 'assets/voz_prueba.mp3',
    loopAudio: true,
    vibrate: true,
    androidFullScreenIntent: true,
    // Volumen fijo y forzado: debe sonar aunque el celular esté en silencio.
    volumeSettings: const VolumeSettings.fixed(volume: 0.8, volumeEnforced: true),
    notificationSettings: const NotificationSettings(
      title: 'Recuérdame',
      body: _texto,
      stopButton: 'Entendido',
    ),
  ),
);

class Inicio extends StatefulWidget {
  const Inicio({super.key});
  @override
  State<Inicio> createState() => _InicioState();
}

class _InicioState extends State<Inicio> with WidgetsBindingObserver {
  late final StreamSubscription<AlarmSet> _sub;
  bool _sonando = false;
  Map<String, bool> _salud = {};
  DateTime? _proxima;
  String _sesion = 'Sin sesión';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sub = Alarm.ringing.listen((s) => setState(() => _sonando = s.alarms.isNotEmpty));
    _refrescar();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _refrescar();
  }

  Future<void> _refrescar() async {
    final salud = {
      'Notificaciones': await Permission.notification.isGranted,
      'Alarmas exactas': await Permission.scheduleExactAlarm.isGranted,
      'Sin ahorro de batería': await Permission.ignoreBatteryOptimizations.isGranted,
      'Mostrar sobre otras apps': await Permission.systemAlertWindow.isGranted,
    };
    final a = await Alarm.getAlarm(_alarmId);
    if (!mounted) return;
    setState(() {
      _salud = salud;
      _proxima = a?.dateTime;
    });
  }

  Future<void> _pedirPermisos() async {
    await [
      Permission.notification,
      Permission.scheduleExactAlarm,
      Permission.ignoreBatteryOptimizations,
      Permission.systemAlertWindow,
    ].request();
    await _refrescar();
  }

  Future<void> _programar(Duration en) async {
    await programar(en);
    await _refrescar();
  }

  // SPIKE fase 0(c): login del gestor con Authentik (OIDC + PKCE, cliente público).
  // Usa Auth Tab de Chrome: un Custom Tab normal no devuelve el control a la app
  // porque Chrome bloquea abrir el esquema propio sin un toque del usuario.
  Future<void> _iniciarSesion() async {
    const authentik = 'https://auth.danihami.xyz/application/o';
    const cliente = 'recuerdame-app';
    const vuelta = 'xyz.danihami.recuerdame:/oauth';
    String sesion;
    try {
      final verificador = _aleatorio();
      final estado = _aleatorio();
      final codigo = Uri.parse(
        await FlutterWebAuth2.authenticate(
          url: Uri.parse('$authentik/authorize/').replace(
            queryParameters: {
              'response_type': 'code',
              'client_id': cliente,
              'redirect_uri': vuelta,
              // Sin `offline_access` a propósito: con ese scope Authentik mete una página de
              // consentimiento. La sesión larga la dará el token de dispositivo del servidor.
              'scope': 'openid profile email',
              'state': estado,
              'code_challenge': base64Url
                  .encode(sha256.convert(ascii.encode(verificador)).bytes)
                  .replaceAll('=', ''),
              'code_challenge_method': 'S256',
            },
          ).toString(),
          callbackUrlScheme: 'xyz.danihami.recuerdame',
        ),
      ).queryParameters;
      if (codigo['state'] != estado) throw StateError('state no coincide');
      final r = await http.post(
        Uri.parse('$authentik/token/'),
        body: {
          'grant_type': 'authorization_code',
          'code': codigo['code']!,
          'redirect_uri': vuelta,
          'client_id': cliente,
          'code_verifier': verificador,
        },
      );
      if (r.statusCode != 200) throw StateError('token ${r.statusCode}: ${r.body}');
      final idToken = (jsonDecode(r.body) as Map<String, dynamic>)['id_token'] as String;
      // Solo para mostrar quién entró; la firma del token la valida el servidor.
      final datos =
          jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(idToken.split('.')[1]))))
              as Map<String, dynamic>;
      sesion =
          'Sesión: ${datos['preferred_username']} (${datos['name']})\n'
          'sub: ${(datos['sub'] as String).substring(0, 12)}…';
    } catch (e) {
      sesion = 'Login falló: $e';
    }
    if (mounted) setState(() => _sesion = sesion);
  }

  static String _aleatorio() => base64Url
      .encode(List.generate(32, (_) => Random.secure().nextInt(256)))
      .replaceAll('=', '');

  @override
  Widget build(BuildContext context) {
    if (_sonando) {
      return PantallaAlarma(
        entendido: () => Alarm.stop(_alarmId).then((_) => _refrescar()),
        masTarde: () =>
            Alarm.stop(_alarmId).then((_) => _programar(const Duration(minutes: 1))),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Recuérdame · prueba de alarma')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final e in _salud.entries)
            ListTile(
              leading: Icon(
                e.value ? Icons.check_circle : Icons.error,
                color: e.value ? Colors.green : Colors.red,
              ),
              title: Text(e.key),
            ),
          FilledButton(onPressed: _pedirPermisos, child: const Text('Pedir permisos')),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () => _programar(const Duration(minutes: 1)),
            child: const Text('Alarma en 1 minuto'),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () => _programar(const Duration(minutes: 10)),
            child: const Text('Alarma en 10 minutos'),
          ),
          const SizedBox(height: 16),
          Text(
            _proxima == null ? 'Sin alarma programada' : 'Programada: $_proxima',
            textAlign: TextAlign.center,
          ),
          const Divider(height: 48),
          FilledButton(onPressed: _iniciarSesion, child: const Text('Iniciar sesión (gestor)')),
          const SizedBox(height: 16),
          Text(_sesion, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

class PantallaAlarma extends StatelessWidget {
  const PantallaAlarma({super.key, required this.entendido, required this.masTarde});
  final VoidCallback entendido;
  final VoidCallback masTarde;

  @override
  Widget build(BuildContext context) {
    final ahora = TimeOfDay.now().format(context);
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Text(
                ahora,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 56, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 24),
              const Text(_texto, textAlign: TextAlign.center, style: TextStyle(fontSize: 30)),
              const Spacer(),
              SizedBox(
                height: 110,
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Colors.green.shade700),
                  onPressed: entendido,
                  child: const Text('✔  ENTENDIDO', style: TextStyle(fontSize: 32)),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                height: 72,
                child: OutlinedButton(
                  onPressed: masTarde,
                  child: const Text('⏰  Más tarde', style: TextStyle(fontSize: 24)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
