// Lista "Hoy" en tarjetas grandes (plan §9). La usa el receptor como pantalla única y
// el gestor dentro de cada persona.
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'agenda.dart';
import 'ajustes.dart';
import 'datos.dart';

const _dias = ['lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado', 'domingo'];
const _meses = [
  'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', //
  'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre',
];

String fecha(DateTime d) => '${_dias[d.weekday - 1]} ${d.day} de ${_meses[d.month - 1]}';

String hora(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '$h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'a. m.' : 'p. m.'}';
}

enum Estado { hecho, pendiente, vencido, proximo }

class ItemHoy {
  ItemHoy(this.r, this.ocurrencia, this.estado);
  final Recordatorio r;
  final DateTime ocurrencia;
  final Estado estado;
}

/// Ocurrencias de hoy de una persona, en orden, con su estado.
Future<List<ItemHoy>> deHoy(Foto f, String personaId) async {
  final hechas = await confirmadas(f);
  final ahora = DateTime.now();
  final hoy = DateTime(ahora.year, ahora.month, ahora.day);
  final items = <ItemHoy>[];
  for (final r in f.recordatorios.where((r) => r.personaId == personaId)) {
    final plazo = Duration(minutes: r.repeticiones * r.repetirCada + 5);
    for (final o in ocurrenciasEntre(r, hoy, hoy.add(const Duration(hours: 24)))) {
      final estado = hechas.contains(claveOcurrencia(r.id, o, 0))
          ? Estado.hecho
          : o.isAfter(ahora)
          ? Estado.proximo
          : o.add(plazo).isBefore(ahora)
          ? Estado.vencido
          : Estado.pendiente;
      items.add(ItemHoy(r, o, estado));
    }
  }
  return items..sort((a, b) => a.ocurrencia.compareTo(b.ocurrencia));
}

final _reproductor = AudioPlayer();

/// Reproduce la voz de un recordatorio: la del celular si está, si no la pide al servidor.
Future<void> escuchar(Recordatorio r) async {
  final local = File('${(await getApplicationDocumentsDirectory()).path}/voz/${r.audioId}.wav');
  if (await local.exists()) return _reproductor.play(DeviceFileSource(local.path));
  final wav = (await llamar('GET', '/v1/audio/${r.audioId}')).bodyBytes;
  await _reproductor.play(BytesSource(wav, mimeType: 'audio/wav'));
}

/// Tarjetas de hoy. Con [puedeConfirmar] (los recordatorios son de este celular) muestra ENTENDIDO.
class ListaHoy extends StatelessWidget {
  const ListaHoy({super.key, required this.foto, required this.personaId, this.grande = true});
  final Foto foto;
  final String personaId;
  final bool grande;

  @override
  Widget build(BuildContext context) {
    final puedeConfirmar = personaId == foto.yo;
    return FutureBuilder(
      future: deHoy(foto, personaId),
      builder: (context, s) {
        final items = s.data;
        if (items == null) return const SizedBox(height: 80);
        if (items.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Hoy no hay recordatorios.', style: TextStyle(fontSize: grande ? 26 : 18)),
          );
        }
        return Column(children: [for (final i in items) _Tarjeta(i, puedeConfirmar: puedeConfirmar, grande: grande)]);
      },
    );
  }
}

class _Tarjeta extends StatelessWidget {
  const _Tarjeta(this.i, {required this.puedeConfirmar, required this.grande});
  final ItemHoy i;
  final bool puedeConfirmar, grande;

  @override
  Widget build(BuildContext context) {
    final (color, icono, etiqueta) = switch (i.estado) {
      Estado.hecho => (Colors.green.shade800, Icons.check_circle, 'Hecho'),
      Estado.pendiente => (Colors.orange.shade800, Icons.alarm, 'Ahora'),
      Estado.vencido => (Colors.red.shade800, Icons.warning, 'Sin confirmar'),
      Estado.proximo => (Colors.blueGrey.shade700, Icons.schedule, 'Más tarde hoy'),
    };
    final escala = grande ? 1.0 : 0.65;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: color, width: 2),
      ),
      child: Padding(
        padding: EdgeInsets.all(16 * escala),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  hora(i.ocurrencia),
                  style: TextStyle(fontSize: 34 * escala, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                Icon(icono, color: color, size: 30 * escala),
                const SizedBox(width: 6),
                Text(etiqueta, style: TextStyle(fontSize: 20 * escala, color: color)),
              ],
            ),
            const SizedBox(height: 8),
            Text(i.r.texto, style: TextStyle(fontSize: 26 * escala)),
            SizedBox(height: 12 * escala),
            Row(
              children: [
                if (i.r.voz != 'none')
                  SizedBox(
                    height: 72 * escala,
                    width: 72 * escala,
                    child: IconButton.outlined(
                      tooltip: 'Escuchar',
                      iconSize: 36 * escala,
                      icon: const Icon(Icons.volume_up),
                      onPressed: () => escuchar(i.r).catchError((_) {}),
                    ),
                  ),
                const SizedBox(width: 12),
                if (puedeConfirmar && i.estado != Estado.hecho)
                  Expanded(
                    child: SizedBox(
                      height: 72 * escala,
                      child: FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: Colors.green.shade800),
                        onPressed: () => confirmar(i.r, i.ocurrencia, 0),
                        child: Text('✔  ENTENDIDO', style: TextStyle(fontSize: 26 * escala)),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Pantalla única del receptor en modo simple: sin menús ni gestos; los ajustes van tras el PIN.
class PantallaHoy extends StatelessWidget {
  const PantallaHoy({super.key, required this.foto});
  final Foto foto;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 72,
        title: Text('Hoy, ${fecha(DateTime.now())}', style: const TextStyle(fontSize: 24)),
        actions: [
          IconButton(
            tooltip: 'Ajustes',
            icon: const Icon(Icons.settings, size: 32),
            onPressed: () async {
              if (await pedirPin(context, foto.persona(foto.yo)) && context.mounted) {
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => const Ajustes()));
              }
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: sincronizar,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            const AvisoSalud(),
            ListaHoy(foto: foto, personaId: foto.yo),
          ],
        ),
      ),
    );
  }
}

/// Si la persona tiene PIN, lo pide antes de dejar entrar a los ajustes.
Future<bool> pedirPin(BuildContext context, Persona? p) async {
  final esperado = p?.pinHash;
  if (esperado == null) return true;
  final texto = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('PIN del gestor'),
      content: TextField(
        controller: texto,
        autofocus: true,
        obscureText: true,
        keyboardType: TextInputType.number,
        maxLength: 4,
        style: const TextStyle(fontSize: 28, letterSpacing: 12),
        onSubmitted: (_) => Navigator.of(c).pop(true),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.of(c).pop(true), child: const Text('Entrar')),
      ],
    ),
  );
  return ok == true && sha256.convert(utf8.encode('${p!.id}:${texto.text}')).toString() == esperado;
}
