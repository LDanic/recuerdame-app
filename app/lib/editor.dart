// Editor del recordatorio (plan §9): qué, a quién, cuándo y cómo, en una sola página.
import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'datos.dart';
import 'gestor.dart';
import 'hoy.dart';
import 'main.dart';

void abrirEditor(BuildContext context, {required String personaId, Recordatorio? r}) => Navigator.of(
  context,
).push(MaterialPageRoute(builder: (_) => Editor(personaId: personaId, original: r)));

// ---- repeticiones: presets sobre RRULE (plan §7) ----

const _codigosDia = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];
const _letrasDia = ['L', 'M', 'X', 'J', 'V', 'S', 'D'];
const _ordinal = {1: 'primer', 2: 'segundo', 3: 'tercer', 4: 'cuarto', -1: 'último'};

enum Frecuencia { una, diaria, semanal, cadaDias, mensualDia, mensualSemana, anual }

class Repeticion {
  Repeticion(this.tipo, {this.horas = const [], this.dias = const {}, this.cada = 1, this.semanaDelMes = 1});
  Frecuencia tipo;
  List<int> horas; // diaria: horas extra del día (mismo minuto que la primera)
  Set<int> dias; // semanal: 0 = lunes
  int cada; // cada N días
  int semanaDelMes; // 1..4 o -1 (último)

  /// Lee una regla que haya escrito este editor; si no la reconoce, devuelve null.
  static Repeticion? leer(String? regla) {
    if (regla == null) return Repeticion(Frecuencia.una);
    final p = {for (final x in regla.split(';')) x.split('=')[0]: x.split('=')[1]};
    final extra = p.keys.toSet().difference({'FREQ', 'BYHOUR', 'BYDAY', 'INTERVAL', 'BYMONTHDAY'});
    if (extra.isNotEmpty) return null;
    return switch (p['FREQ']) {
      'DAILY' when p['INTERVAL'] != null => Repeticion(Frecuencia.cadaDias, cada: int.parse(p['INTERVAL']!)),
      'DAILY' => Repeticion(Frecuencia.diaria, horas: [for (final h in (p['BYHOUR'] ?? '').split(',')) if (h.isNotEmpty) int.parse(h)]),
      'WEEKLY' => Repeticion(Frecuencia.semanal, dias: {for (final d in (p['BYDAY'] ?? '').split(',')) _codigosDia.indexOf(d)}..remove(-1)),
      'MONTHLY' when p['BYDAY'] != null => Repeticion(
        Frecuencia.mensualSemana,
        semanaDelMes: int.parse(p['BYDAY']!.substring(0, p['BYDAY']!.length - 2)),
      ),
      'MONTHLY' => Repeticion(Frecuencia.mensualDia),
      'YEARLY' => Repeticion(Frecuencia.anual),
      _ => null,
    };
  }

  String? regla(DateTime inicio) => switch (tipo) {
    Frecuencia.una => null,
    Frecuencia.diaria => horas.isEmpty ? 'FREQ=DAILY' : 'FREQ=DAILY;BYHOUR=${({inicio.hour, ...horas}.toList()..sort()).join(',')}',
    Frecuencia.cadaDias => 'FREQ=DAILY;INTERVAL=$cada',
    Frecuencia.semanal => 'FREQ=WEEKLY;BYDAY=${(dias.isEmpty ? {inicio.weekday - 1} : dias).toList().map((d) => _codigosDia[d]).join(',')}',
    Frecuencia.mensualDia => 'FREQ=MONTHLY;BYMONTHDAY=${inicio.day}',
    Frecuencia.mensualSemana => 'FREQ=MONTHLY;BYDAY=$semanaDelMes${_codigosDia[inicio.weekday - 1]}',
    Frecuencia.anual => 'FREQ=YEARLY',
  };
}

String _hh(DateTime d) => '${d.hour}:${d.minute.toString().padLeft(2, '0')}';

/// "Cada día a las 8:00, 14:00 y 20:00", para las listas.
String describir(Recordatorio r) {
  final rep = Repeticion.leer(r.regla);
  final i = r.inicio;
  final cuando = switch (rep?.tipo) {
    null => 'Repetición personalizada',
    Frecuencia.una => 'Una vez, ${fecha(i)}',
    Frecuencia.diaria => 'Cada día',
    Frecuencia.cadaDias => 'Cada ${rep!.cada} días',
    Frecuencia.semanal => 'Los ${rep!.dias.toList().map((d) => _letrasDia[d]).join(' ')}',
    Frecuencia.mensualDia => 'El ${i.day} de cada mes',
    Frecuencia.mensualSemana => 'El ${_ordinal[rep!.semanaDelMes]} ${fecha(i).split(' ').first} de cada mes',
    Frecuencia.anual => 'Cada año, ${i.day}/${i.month}',
  };
  final horas = rep?.tipo == Frecuencia.diaria && rep!.horas.isNotEmpty
      ? ({i.hour, ...rep.horas}.toList()..sort()).map((h) => '$h:${i.minute.toString().padLeft(2, '0')}').join(', ')
      : _hh(i);
  return '$cuando · $horas';
}

// ---- editor ----

class Editor extends StatefulWidget {
  const Editor({super.key, required this.personaId, this.original});
  final String personaId;
  final Recordatorio? original;
  @override
  State<Editor> createState() => _EditorState();
}

class _EditorState extends State<Editor> {
  late final Recordatorio r;
  late final TextEditingController _texto;
  late Repeticion? _rep;
  final _grabadora = AudioRecorder();
  final _reproductor = AudioPlayer();
  String? _grabacion; // ruta local de una grabación nueva, aún sin subir
  bool _grabando = false, _guardando = false;
  Timer? _limite;

  @override
  void initState() {
    super.initState();
    final o = widget.original;
    final manana = DateTime.now().add(const Duration(hours: 1));
    r = o == null
        ? Recordatorio(
            id: nuevoId(),
            personaId: widget.personaId,
            inicio: DateTime(manana.year, manana.month, manana.day, manana.hour),
            regla: 'FREQ=DAILY',
          )
        : Recordatorio.desde({...?_json(o)});
    _texto = TextEditingController(text: r.texto);
    _rep = Repeticion.leer(r.regla);
  }

  // Copia para editar sin tocar la foto.
  Map<String, dynamic>? _json(Recordatorio o) => {
    ...o.aJson(),
    'id': o.id,
    'audio_id': o.audioId,
    'updated_at': o.actualizado?.toIso8601String() ?? DateTime.now().toIso8601String(),
  };

  @override
  void dispose() {
    _limite?.cancel();
    _grabadora.dispose();
    _reproductor.dispose();
    super.dispose();
  }

  Future<void> _grabar() async {
    if (_grabando) {
      _limite?.cancel();
      _grabacion = await _grabadora.stop();
      setState(() => _grabando = false);
      return;
    }
    if (!await _grabadora.hasPermission()) return;
    final ruta = '${(await getTemporaryDirectory()).path}/grabacion-${r.id}.wav';
    await _grabadora.start(
      const RecordConfig(encoder: AudioEncoder.wav, sampleRate: 22050, numChannels: 1),
      path: ruta,
    );
    _limite = Timer(const Duration(seconds: 60), _grabar); // máx. ~60 s (plan §8)
    setState(() => _grabando = true);
  }

  Future<void> _escuchar() async {
    try {
      if (r.voz == 'recording' && _grabacion != null) {
        await _reproductor.play(DeviceFileSource(_grabacion!));
      } else if (r.voz == 'tts') {
        final wav = (await llamar('POST', '/v1/tts', json: {'text': _texto.text.trim()})).bodyBytes;
        await _reproductor.play(BytesSource(wav, mimeType: 'audio/wav'));
      } else if (r.audioId != null) {
        await escuchar(r);
      }
    } catch (e) {
      if (mounted) avisar(context, '$e');
    }
  }

  Future<void> _guardar() async {
    r.texto = _texto.text.trim();
    if (r.texto.isEmpty) return avisar(context, 'Escribe qué hay que recordar');
    if (r.voz == 'recording' && _grabacion == null && r.audioId == null) return avisar(context, 'Falta grabar la voz');
    final rep = _rep;
    if (rep != null) r.regla = rep.regla(r.inicio);
    final tarde = r.inicio.difference(DateTime.now()) < const Duration(minutes: 30) && r.regla == null;
    setState(() => _guardando = true);
    try {
      if (r.voz == 'recording' && _grabacion != null) {
        r.audioId = nuevoId();
        await llamar('PUT', '/v1/audio/${r.audioId}', wav: await File(_grabacion!).readAsBytes());
      }
      await llamar('PUT', '/v1/reminders/${r.id}', json: r.aJson());
      await sincronizar();
      if (!mounted) return;
      if (tarde && widget.personaId != ultimaFoto?.yo) {
        // plan §5: sin push, su celular puede tardar hasta 15 min en enterarse.
        avisar(context, 'Guardado. Ojo: su celular puede tardar hasta 15 minutos en enterarse.');
      }
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) avisar(context, '$e');
    }
    if (mounted) setState(() => _guardando = false);
  }

  Future<void> _borrar() async {
    if (!await confirmarAccion(context, '¿Borrar este recordatorio?', 'Deja de sonar en todos los celulares.')) return;
    try {
      await llamar('DELETE', '/v1/reminders/${r.id}');
      await sincronizar();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) avisar(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final personas = ultimaFoto?.personas ?? [];
    final rep = _rep;
    Widget seccion(String t) => Padding(
      padding: const EdgeInsets.fromLTRB(0, 24, 0, 8),
      child: Text(t, style: Theme.of(context).textTheme.titleLarge),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.original == null ? 'Nuevo recordatorio' : 'Editar recordatorio'),
        actions: [
          if (widget.original != null) IconButton(tooltip: 'Borrar', icon: const Icon(Icons.delete), onPressed: _borrar),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
        children: [
          seccion('Qué'),
          TextField(
            controller: _texto,
            maxLength: 300,
            maxLines: 3,
            minLines: 1,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'Ej.: Tomar la pastilla de la presión',
            ),
          ),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'tts', label: Text('Voz'), icon: Icon(Icons.record_voice_over)),
              ButtonSegment(value: 'recording', label: Text('Grabar'), icon: Icon(Icons.mic)),
              ButtonSegment(value: 'none', label: Text('Sin voz'), icon: Icon(Icons.volume_off)),
            ],
            selected: {r.voz},
            onSelectionChanged: (s) => setState(() => r.voz = s.first),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (r.voz == 'recording')
                FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: _grabando ? Colors.red.shade700 : null),
                  icon: Icon(_grabando ? Icons.stop : Icons.mic),
                  label: Text(_grabando ? 'Detener' : (_grabacion == null && r.audioId == null ? 'Grabar' : 'Grabar otra vez')),
                  onPressed: _grabar,
                ),
              const SizedBox(width: 8),
              if (r.voz != 'none')
                OutlinedButton.icon(icon: const Icon(Icons.play_arrow), label: const Text('Escuchar'), onPressed: _escuchar),
            ],
          ),
          seccion('A quién'),
          DropdownButtonFormField<String>(
            initialValue: r.personaId,
            items: [for (final p in personas) DropdownMenuItem(value: p.id, child: Text(p.nombre))],
            onChanged: (v) => setState(() => r.personaId = v!),
          ),
          seccion('Cuándo'),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.calendar_today),
                  label: Text(fecha(r.inicio)),
                  onPressed: () async {
                    final d = await showDatePicker(
                      context: context,
                      initialDate: r.inicio,
                      firstDate: DateTime.now().subtract(const Duration(days: 365)),
                      lastDate: DateTime.now().add(const Duration(days: 3650)),
                    );
                    if (d != null) setState(() => r.inicio = DateTime(d.year, d.month, d.day, r.inicio.hour, r.inicio.minute));
                  },
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.schedule),
                label: Text(hora(r.inicio)),
                onPressed: () async {
                  final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(r.inicio));
                  if (t != null) {
                    setState(() => r.inicio = DateTime(r.inicio.year, r.inicio.month, r.inicio.day, t.hour, t.minute));
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (rep == null)
            ListTile(
              title: Text('Repetición personalizada: ${r.regla}'),
              trailing: TextButton(
                onPressed: () => setState(() => _rep = Repeticion(Frecuencia.diaria)),
                child: const Text('Cambiar'),
              ),
            )
          else ...[
            DropdownButtonFormField<Frecuencia>(
              initialValue: rep.tipo,
              decoration: const InputDecoration(labelText: 'Se repite'),
              items: [
                for (final (f, t) in [
                  (Frecuencia.una, 'Una sola vez'),
                  (Frecuencia.diaria, 'Cada día'),
                  (Frecuencia.semanal, 'Algunos días de la semana'),
                  (Frecuencia.cadaDias, 'Cada cierto número de días'),
                  (Frecuencia.mensualDia, 'Cada mes, el día ${r.inicio.day}'),
                  (Frecuencia.mensualSemana, 'Cada mes, un ${fecha(r.inicio).split(' ').first} concreto'),
                  (Frecuencia.anual, 'Cada año'),
                ])
                  DropdownMenuItem(value: f, child: Text(t)),
              ],
              onChanged: (f) => setState(() => rep.tipo = f!),
            ),
            if (rep.tipo == Frecuencia.diaria)
              Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('Otras horas:'),
                  for (final h in rep.horas)
                    InputChip(
                      label: Text('$h:${r.inicio.minute.toString().padLeft(2, '0')}'),
                      onDeleted: () => setState(() => rep.horas = [...rep.horas]..remove(h)),
                    ),
                  ActionChip(
                    avatar: const Icon(Icons.add),
                    label: const Text('Agregar hora'),
                    onPressed: () async {
                      final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: (r.inicio.hour + 6) % 24, minute: r.inicio.minute));
                      if (t != null && t.hour != r.inicio.hour) setState(() => rep.horas = {...rep.horas, t.hour}.toList()..sort());
                    },
                  ),
                ],
              ),
            if (rep.tipo == Frecuencia.semanal)
              Wrap(
                spacing: 4,
                children: [
                  for (var d = 0; d < 7; d++)
                    FilterChip(
                      label: Text(_letrasDia[d]),
                      selected: rep.dias.contains(d),
                      onSelected: (v) => setState(() => rep.dias = v ? {...rep.dias, d} : ({...rep.dias}..remove(d))),
                    ),
                ],
              ),
            if (rep.tipo == Frecuencia.cadaDias)
              Row(
                children: [
                  const Text('Cada '),
                  DropdownButton<int>(
                    value: rep.cada,
                    items: [for (final n in [2, 3, 7, 10, 14, 15, 21, 30]) DropdownMenuItem(value: n, child: Text('$n'))],
                    onChanged: (n) => setState(() => rep.cada = n!),
                  ),
                  const Text(' días'),
                ],
              ),
            if (rep.tipo == Frecuencia.mensualSemana)
              DropdownButton<int>(
                value: rep.semanaDelMes,
                items: [
                  for (final MapEntry(key: n, value: t) in _ordinal.entries)
                    DropdownMenuItem(value: n, child: Text('El $t ${fecha(r.inicio).split(' ').first} del mes')),
                ],
                onChanged: (n) => setState(() => rep.semanaDelMes = n!),
              ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text('Avisar antes:'),
              for (final (m, t) in [(-1440, '1 día'), (-120, '2 h'), (-60, '1 h'), (-30, '30 min')])
                FilterChip(
                  label: Text(t),
                  selected: r.avisos.contains(m),
                  onSelected: (v) => setState(() => r.avisos = v ? {...r.avisos, m}.toList() : ([...r.avisos]..remove(m))),
                ),
            ],
          ),
          seccion('Cómo'),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'alarma', label: Text('Alarma'), icon: Icon(Icons.alarm)),
              ButtonSegment(value: 'notificacion', label: Text('Aviso'), icon: Icon(Icons.notifications)),
              ButtonSegment(value: 'discreto', label: Text('Discreto'), icon: Icon(Icons.list)),
            ],
            selected: {r.nivel},
            onSelectionChanged: (s) => setState(() {
              r.nivel = s.first;
              if (r.nivel != 'alarma') r.repeticiones = 0;
            }),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(switch (r.nivel) {
              'alarma' => 'Suena aunque el celular esté en silencio, a pantalla completa.',
              'notificacion' => 'Suena una vez y respeta el modo silencio.',
              _ => 'No suena: solo aparece en la lista de hoy.',
            }),
          ),
          if (r.nivel != 'discreto') ...[
            Row(
              children: [
                const Expanded(child: Text('Si no confirma, repetir')),
                DropdownButton<int>(
                  value: r.repeticiones,
                  items: [for (final n in [0, 1, 2, 3, 5]) DropdownMenuItem(value: n, child: Text(n == 0 ? 'no' : '$n veces'))],
                  onChanged: (n) => setState(() => r.repeticiones = n!),
                ),
              ],
            ),
            if (r.repeticiones > 0)
              Row(
                children: [
                  const Expanded(child: Text('cada')),
                  DropdownButton<int>(
                    value: r.repetirCada,
                    items: [for (final n in [5, 10, 15, 30]) DropdownMenuItem(value: n, child: Text('$n min'))],
                    onChanged: (n) => setState(() => r.repetirCada = n!),
                  ),
                ],
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Avisarme si no confirma'),
              value: r.avisarGestores,
              onChanged: (v) => setState(() => r.avisarGestores = v),
            ),
          ],
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: _guardando
            ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.save),
        label: const Text('Guardar'),
        onPressed: _guardando ? null : _guardar,
      ),
    );
  }
}
