// Ajustes de ESTE celular: permisos, guía de su marca (plan §6), actualización y sesión.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:ota_update/ota_update.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'datos.dart';

const _permisos = {
  'notificaciones': ('Mostrar avisos', Permission.notification),
  'alarmas_exactas': ('Alarmas a la hora exacta', Permission.scheduleExactAlarm),
  'sin_ahorro_bateria': ('Sin ahorro de batería', Permission.ignoreBatteryOptimizations),
  'sobre_otras_apps': ('Abrir en grande sobre otras apps', Permission.systemAlertWindow),
};

Future<void> pedirPermisos() async {
  for (final (_, p) in _permisos.values) {
    if (!await p.isGranted) await p.request();
  }
  await sincronizar(); // el gestor ve la salud nueva
}

/// Franja roja si a este celular le falta algo para sonar bien.
class AvisoSalud extends StatelessWidget {
  const AvisoSalud({super.key});

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: salud(),
    builder: (context, s) {
      if (s.data?.values.every((v) => v == true) ?? true) return const SizedBox.shrink();
      return Card(
        color: Colors.red.shade50,
        margin: const EdgeInsets.all(12),
        child: ListTile(
          leading: Icon(Icons.warning, color: Colors.red.shade800, size: 36),
          title: const Text('Este celular podría no sonar', style: TextStyle(fontSize: 20)),
          subtitle: const Text('Toca aquí para arreglarlo'),
          onTap: pedirPermisos,
        ),
      );
    },
  );
}

class Ajustes extends StatefulWidget {
  const Ajustes({super.key});
  @override
  State<Ajustes> createState() => _AjustesState();
}

class _AjustesState extends State<Ajustes> with WidgetsBindingObserver {
  Map<String, Object?> _salud = {};
  String _fabricante = '';
  String _version = '';
  String? _actualizacion;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refrescar();
    sistema.invokeMethod<String>('fabricante').then((f) => setState(() => _fabricante = f ?? ''));
    PackageInfo.fromPlatform().then((p) => setState(() => _version = '${p.version} (${p.buildNumber})'));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _refrescar(); // vuelve de los ajustes del sistema
  }

  Future<void> _refrescar() async {
    final s = await salud();
    if (mounted) setState(() => _salud = s);
  }

  Future<void> _abrir(String paquete, String clase) async {
    final ok = await sistema.invokeMethod<bool>('abrir', {'paquete': paquete, 'clase': clase}) ?? false;
    if (!ok) await openAppSettings();
  }

  Future<void> _actualizar() async {
    setState(() => _actualizacion = 'Buscando…');
    try {
      final ultima = jsonDecode((await llamar('GET', '/v1/app/latest')).body);
      final mia = int.parse((await PackageInfo.fromPlatform()).buildNumber);
      if ((ultima['version_code'] as int) <= mia) {
        setState(() => _actualizacion = 'Ya tienes la última versión');
        return;
      }
      // El plugin verifica el sha256 y Android, la firma del APK (plan §10).
      OtaUpdate()
          .execute('$servidor/descargar', destinationFilename: 'recuerdame.apk', sha256checksum: ultima['sha256'])
          .listen(
            (e) => setState(
              () => _actualizacion = e.status == OtaStatus.DOWNLOADING ? 'Descargando ${e.value}%' : e.status.name,
            ),
            onError: (e) => setState(() => _actualizacion = 'No se pudo: $e'),
          );
    } catch (e) {
      setState(() => _actualizacion = 'No se pudo: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ajustes de este celular')),
      body: ListView(
        children: [
          for (final MapEntry(key: k, value: (nombre, permiso)) in _permisos.entries)
            ListTile(
              leading: Icon(
                _salud[k] == true ? Icons.check_circle : Icons.error,
                color: _salud[k] == true ? Colors.green.shade800 : Colors.red.shade800,
              ),
              title: Text(nombre),
              trailing: _salud[k] == true
                  ? null
                  : TextButton(
                      onPressed: () async {
                        await permiso.request();
                        await _refrescar();
                      },
                      child: const Text('Arreglar'),
                    ),
            ),
          const Divider(),
          ..._guia(),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.system_update),
            title: Text('Versión $_version'),
            subtitle: _actualizacion == null ? null : Text(_actualizacion!),
            trailing: TextButton(onPressed: _actualizar, child: const Text('Buscar actualización')),
          ),
          ListTile(
            leading: const Icon(Icons.sync),
            title: const Text('Sincronizar ahora'),
            onTap: () async {
              await sincronizar();
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Listo')));
            },
          ),
          ListTile(
            leading: Icon(Icons.logout, color: Colors.red.shade800),
            title: const Text('Desvincular este celular'),
            subtitle: const Text('Deja de sonar aquí. Para volver hay que vincularlo de nuevo.'),
            onTap: () async {
              final si = await showDialog<bool>(
                context: context,
                builder: (c) => AlertDialog(
                  title: const Text('¿Desvincular este celular?'),
                  actions: [
                    TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('No')),
                    FilledButton(onPressed: () => Navigator.of(c).pop(true), child: const Text('Sí, desvincular')),
                  ],
                ),
              );
              if (si == true) {
                await salir();
                if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
              }
            },
          ),
        ],
      ),
    );
  }

  /// Guías por marca: lo que cada fabricante exige para que la alarma no muera.
  List<Widget> _guia() {
    Widget paso(String texto, [VoidCallback? accion, String boton = 'Abrir']) => ListTile(
      leading: const Icon(Icons.chevron_right),
      title: Text(texto),
      trailing: accion == null ? null : TextButton(onPressed: accion, child: Text(boton)),
    );
    final bateria = paso('Batería de Recuérdame: «Sin restricciones»', openAppSettings);
    final pasos = switch (_fabricante) {
      'xiaomi' || 'redmi' || 'poco' => [
        paso(
          'Activa el «Inicio automático» de Recuérdame',
          () => _abrir('com.miui.securitycenter', 'com.miui.permcenter.autostart.AutoStartManagementActivity'),
        ),
        bateria,
        paso('En Recientes, mantén presionada la tarjeta de Recuérdame y toca el candado'),
      ],
      'samsung' => [
        bateria,
        paso(
          'Ajustes → Batería → Límites de uso en segundo plano: Recuérdame NO debe estar en '
          '«Apps en suspensión» ni «en suspensión profunda»',
        ),
      ],
      'motorola' => [bateria, paso('Ajustes → Batería → Optimización: Recuérdame «No optimizar»')],
      _ => [bateria],
    };
    return [
      ListTile(
        title: Text('Para que suene siempre${_fabricante.isEmpty ? '' : ' (${_fabricante[0].toUpperCase()}${_fabricante.substring(1)})'}'),
      ),
      ...pasos,
    ];
  }
}
