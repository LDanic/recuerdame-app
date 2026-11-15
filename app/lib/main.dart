import 'dart:async';

import 'package:alarm/alarm.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:workmanager/workmanager.dart';

import 'datos.dart';
import 'gestor.dart';
import 'hoy.dart';

/// Sincronización periódica (plan §5): WorkManager cada 15 min, también tras reiniciar.
@pragma('vm:entry-point')
void tareaDeFondo() => Workmanager().executeTask((_, _) async {
  await Alarm.init();
  await sincronizar();
  return true;
});

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Alarm.init();
  await Workmanager().initialize(tareaDeFondo);
  await Workmanager().registerPeriodicTask(
    'sincronizar',
    'sincronizar',
    frequency: const Duration(minutes: 15),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
  );
  runApp(
    MaterialApp(
      title: 'Recuérdame',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.green.shade800, useMaterial3: true),
      home: const Raiz(),
    ),
  );
}

/// Decide la pantalla según la sesión: sin sesión, gestor o receptor.
class Raiz extends StatefulWidget {
  const Raiz({super.key});
  @override
  State<Raiz> createState() => _RaizState();
}

class _RaizState extends State<Raiz> with WidgetsBindingObserver {
  Foto? _foto;
  bool _cargando = true;
  late final StreamSubscription<Foto?> _sub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sub = cambios.listen((f) => setState(() => _foto = f));
    fotoGuardada().then((f) {
      setState(() {
        _foto = f;
        _cargando = false;
      });
      sincronizar();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) sincronizar();
  }

  @override
  Widget build(BuildContext context) {
    final f = _foto;
    if (_cargando) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (f == null) return const Bienvenida();
    return f.soyGestor ? InicioGestor(foto: f) : PantallaHoy(foto: f);
  }
}

class Bienvenida extends StatefulWidget {
  const Bienvenida({super.key});
  @override
  State<Bienvenida> createState() => _BienvenidaState();
}

class _BienvenidaState extends State<Bienvenida> {
  bool _ocupado = false;

  Future<void> _hacer(Future<void> Function() accion) async {
    setState(() => _ocupado = true);
    try {
      await accion();
    } catch (e) {
      if (mounted) avisar(context, '$e');
    }
    if (mounted) setState(() => _ocupado = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              const Icon(Icons.record_voice_over, size: 96),
              const SizedBox(height: 16),
              Text('Recuérdame', textAlign: TextAlign.center, style: Theme.of(context).textTheme.displaySmall),
              const Spacer(),
              if (_ocupado) const Center(child: CircularProgressIndicator()),
              if (!_ocupado) ...[
                BotonGrande(
                  icono: Icons.qr_code_scanner,
                  texto: 'Vincular este celular',
                  alTocar: () async {
                    final codigo = await Navigator.of(
                      context,
                    ).push<String>(MaterialPageRoute(builder: (_) => const PedirCodigo()));
                    if (codigo != null) await _hacer(() => vincular(codigo));
                  },
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  icon: const Icon(Icons.manage_accounts),
                  label: const Padding(padding: EdgeInsets.all(14), child: Text('Soy gestor: iniciar sesión')),
                  onPressed: () => _hacer(ingresarGestor),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Escanea el QR que muestra el gestor, o deja escribir los 6 dígitos.
class PedirCodigo extends StatefulWidget {
  const PedirCodigo({super.key});
  @override
  State<PedirCodigo> createState() => _PedirCodigoState();
}

class _PedirCodigoState extends State<PedirCodigo> {
  final _texto = TextEditingController();
  bool _listo = false;

  void _usar(String? valor) {
    final codigo = RegExp(r'\d{6}').stringMatch(valor ?? '');
    if (codigo == null || _listo) return;
    _listo = true;
    Navigator.of(context).pop(codigo);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Vincular este celular')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text('Apunta la cámara al código que muestra el celular del gestor.', style: TextStyle(fontSize: 20)),
          const SizedBox(height: 16),
          SizedBox(
            height: 280,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: MobileScanner(onDetect: (c) => _usar(c.barcodes.firstOrNull?.rawValue)),
            ),
          ),
          const SizedBox(height: 24),
          const Text('O escribe los 6 números:', style: TextStyle(fontSize: 20)),
          TextField(
            controller: _texto,
            keyboardType: TextInputType.number,
            maxLength: 6,
            style: const TextStyle(fontSize: 32, letterSpacing: 8),
            onChanged: _usar,
          ),
        ],
      ),
    );
  }
}

class BotonGrande extends StatelessWidget {
  const BotonGrande({super.key, required this.icono, required this.texto, required this.alTocar, this.color});
  final IconData icono;
  final String texto;
  final VoidCallback? alTocar;
  final Color? color;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 80,
    child: FilledButton.icon(
      style: FilledButton.styleFrom(backgroundColor: color, textStyle: const TextStyle(fontSize: 24)),
      icon: Icon(icono, size: 32),
      label: Text(texto),
      onPressed: alTocar,
    ),
  );
}

void avisar(BuildContext context, String texto) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(texto)));
