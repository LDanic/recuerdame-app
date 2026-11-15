// SPIKE fase 0(a): Â¿suena la alarma en un celular real (pantalla completa,
// en silencio, con la app cerrada, tras reiniciar)? Se reemplaza en la fase 1.
import 'dart:async';

import 'package:alarm/alarm.dart';
import 'package:alarm/utils/alarm_set.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

const _alarmId = 1;
const _texto = 'Tomar la pastilla de la presiÃ³n (LosartÃ¡n)';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Alarm.init();
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
    // Volumen fijo y forzado: debe sonar aunque el celular estÃ© en silencio.
    volumeSettings: const VolumeSettings.fixed(volume: 0.8, volumeEnforced: true),
    notificationSettings: const NotificationSettings(
      title: 'RecuÃ©rdame',
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
      'Sin ahorro de baterÃ­a': await Permission.ignoreBatteryOptimizations.isGranted,
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
    ].request();
    await _refrescar();
  }

  Future<void> _programar(Duration en) async {
    await programar(en);
    await _refrescar();
  }

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
      appBar: AppBar(title: const Text('RecuÃ©rdame Â· prueba de alarma')),
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
                  child: const Text('âœ”  ENTENDIDO', style: TextStyle(fontSize: 32)),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                height: 72,
                child: OutlinedButton(
                  onPressed: masTarde,
                  child: const Text('â°  MÃ¡s tarde', style: TextStyle(fontSize: 24)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
