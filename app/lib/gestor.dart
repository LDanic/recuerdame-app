// Pantallas del gestor: sus personas, cada persona (hoy, recordatorios, celulares) y su
// configuración y vinculación.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'ajustes.dart';
import 'datos.dart';
import 'editor.dart';
import 'hoy.dart';
import 'main.dart';

/// Redibuja con cada foto nueva. Las pantallas apiladas no reciben la foto de [Raiz].
class ConFoto extends StatelessWidget {
  const ConFoto({super.key, required this.builder});
  final Widget Function(BuildContext, Foto) builder;

  @override
  Widget build(BuildContext context) => StreamBuilder<Foto?>(
    stream: cambios,
    initialData: ultimaFoto,
    builder: (context, s) => s.data == null ? const Scaffold() : builder(context, s.data!),
  );
}

/// Un celular está bien si tiene todos los permisos y sincronizó hace menos de una hora.
bool celularSano(Map<String, dynamic> c) {
  final ultima = DateTime.tryParse(c['last_sync_at'] ?? '');
  return ultima != null &&
      DateTime.now().difference(ultima) < const Duration(hours: 1) &&
      (c['health'] as Map).values.every((v) => v == true);
}

class InicioGestor extends StatelessWidget {
  const InicioGestor({super.key, required this.foto});
  final Foto foto;

  @override
  Widget build(BuildContext context) {
    ultimaFoto ??= foto;
    final personas = [...foto.personas]..sort((a, b) => a.id == foto.yo ? -1 : (b.id == foto.yo ? 1 : a.nombre.compareTo(b.nombre)));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recuérdame'),
        actions: [
          IconButton(
            tooltip: 'Ajustes de este celular',
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const Ajustes())),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.person_add),
        label: const Text('Persona'),
        onPressed: () => _agregarPersona(context),
      ),
      body: RefreshIndicator(
        onRefresh: sincronizar,
        child: ListView(
          children: [
            const AvisoSalud(),
            for (final p in personas) _FilaPersona(foto: foto, persona: p),
          ],
        ),
      ),
    );
  }

  Future<void> _agregarPersona(BuildContext context) async {
    final nombre = await pedirTexto(context, 'Nombre de la persona', 'Ej.: Papá');
    if (nombre == null || nombre.isEmpty) return;
    try {
      final r = await llamar('POST', '/v1/persons', json: {'name': nombre});
      await sincronizar();
      if (context.mounted) abrirPersona(context, jsonDecode(r.body)['id']);
    } catch (e) {
      if (context.mounted) avisar(context, '$e');
    }
  }
}

void abrirPersona(BuildContext context, String id) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => PantallaPersona(personaId: id)));

class _FilaPersona extends StatelessWidget {
  const _FilaPersona({required this.foto, required this.persona});
  final Foto foto;
  final Persona persona;

  @override
  Widget build(BuildContext context) {
    final cels = persona.celulares;
    final sano = cels.isNotEmpty && cels.every(celularSano);
    return FutureBuilder(
      future: deHoy(foto, persona.id),
      builder: (context, s) {
        final items = s.data ?? [];
        int n(Estado e) => items.where((i) => i.estado == e).length;
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: cels.isEmpty ? Colors.grey : (sano ? Colors.green.shade700 : Colors.red.shade700),
            child: Icon(persona.id == foto.yo ? Icons.person : Icons.elderly, color: Colors.white),
          ),
          title: Text(persona.id == foto.yo ? '${persona.nombre} (yo)' : persona.nombre),
          subtitle: Text(
            cels.isEmpty
                ? 'Sin celular vinculado'
                : 'Hoy: ${n(Estado.hecho)} ✔ · ${n(Estado.pendiente) + n(Estado.proximo)} pendientes · ${n(Estado.vencido)} ⚠',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => abrirPersona(context, persona.id),
        );
      },
    );
  }
}

class PantallaPersona extends StatelessWidget {
  const PantallaPersona({super.key, required this.personaId});
  final String personaId;

  @override
  Widget build(BuildContext context) => ConFoto(
    builder: (context, foto) {
      final p = foto.persona(personaId);
      if (p == null) return const Scaffold(body: Center(child: Text('Esta persona ya no está vinculada')));
      final recordatorios = foto.recordatorios.where((r) => r.personaId == personaId).toList()
        ..sort((a, b) => a.texto.compareTo(b.texto));
      return Scaffold(
        appBar: AppBar(
          title: Text(p.nombre),
          actions: [
            IconButton(
              tooltip: 'Vincular un celular',
              icon: const Icon(Icons.qr_code),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => Vincular(persona: p))),
            ),
            IconButton(
              tooltip: 'Configurar',
              icon: const Icon(Icons.tune),
              onPressed: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => AjustesPersona(personaId: personaId))),
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          icon: const Icon(Icons.add_alarm),
          label: const Text('Recordatorio'),
          onPressed: () => abrirEditor(context, personaId: personaId),
        ),
        body: RefreshIndicator(
          onRefresh: sincronizar,
          child: ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              _titulo(context, 'Hoy'),
              ListaHoy(foto: foto, personaId: personaId, grande: false),
              _titulo(context, 'Recordatorios'),
              if (recordatorios.isEmpty) const ListTile(title: Text('Aún no tiene recordatorios')),
              for (final r in recordatorios)
                ListTile(
                  leading: Icon(switch (r.nivel) {
                    'alarma' => Icons.alarm,
                    'notificacion' => Icons.notifications,
                    _ => Icons.list,
                  }),
                  title: Text(r.texto),
                  subtitle: Text(describir(r)),
                  onTap: () => abrirEditor(context, personaId: personaId, r: r),
                ),
              _titulo(context, 'Celulares'),
              if (p.celulares.isEmpty)
                ListTile(
                  title: const Text('Ninguno. Toca el QR de arriba para vincular uno.'),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => Vincular(persona: p))),
                ),
              for (final c in p.celulares) _Celular(c),
            ],
          ),
        ),
      );
    },
  );

  Widget _titulo(BuildContext context, String t) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(t, style: Theme.of(context).textTheme.titleLarge),
  );
}

class _Celular extends StatelessWidget {
  const _Celular(this.c);
  final Map<String, dynamic> c;

  @override
  Widget build(BuildContext context) {
    final ultima = DateTime.tryParse(c['last_sync_at'] ?? '')?.toLocal();
    final faltan = [
      for (final e in (c['health'] as Map).entries)
        if (e.value != true) e.key.toString().replaceAll('_', ' '),
    ];
    return ListTile(
      leading: Icon(
        celularSano(c) ? Icons.phone_android : Icons.phonelink_erase,
        color: celularSano(c) ? Colors.green.shade800 : Colors.red.shade800,
      ),
      title: Text('${c['model'] == '' ? 'Celular' : c['model']} · ${c['role']}'),
      subtitle: Text([
        ultima == null ? 'Nunca sincronizó' : 'Última vez: ${fecha(ultima)}, ${hora(ultima)}',
        if (faltan.isNotEmpty) 'Le falta: ${faltan.join(', ')}',
        'App ${c['app_version']}',
      ].join('\n')),
      isThreeLine: true,
      trailing: IconButton(
        tooltip: 'Quitar este celular',
        icon: const Icon(Icons.delete_outline),
        onPressed: () async {
          if (!await confirmarAccion(context, '¿Quitar este celular?', 'Dejará de sonar en él.')) return;
          try {
            await llamar('DELETE', '/v1/devices/${c['id']}');
            await sincronizar();
          } catch (e) {
            if (context.mounted) avisar(context, '$e');
          }
        },
      ),
    );
  }
}

class AjustesPersona extends StatefulWidget {
  const AjustesPersona({super.key, required this.personaId});
  final String personaId;
  @override
  State<AjustesPersona> createState() => _AjustesPersonaState();
}

class _AjustesPersonaState extends State<AjustesPersona> {
  Future<void> _cambiar(Map<String, dynamic> cambio) async {
    try {
      await llamar('PATCH', '/v1/persons/${widget.personaId}', json: cambio);
      await sincronizar();
    } catch (e) {
      if (mounted) avisar(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) => ConFoto(
    builder: (context, foto) {
      final p = foto.persona(widget.personaId);
      if (p == null) return const Scaffold();
      final grande = p.enGrande;
      Widget nivel(String clave, String titulo) => SwitchListTile(
        title: Text(titulo),
        subtitle: Text(grande.contains(clave) ? 'Pantalla completa' : 'Solo banner'),
        value: grande.contains(clave),
        onChanged: (v) => _cambiar({
          'full_screen': [...grande.where((x) => x != clave), if (v) clave],
        }),
      );
      return Scaffold(
        appBar: AppBar(title: Text('Configurar a ${p.nombre}')),
        body: ListView(
          children: [
            ListTile(
              leading: const Icon(Icons.badge),
              title: Text(p.nombre),
              subtitle: const Text('Cambiar nombre'),
              onTap: () async {
                final n = await pedirTexto(context, 'Nombre', p.nombre, inicial: p.nombre);
                if (n != null && n.isNotEmpty) await _cambiar({'name': n});
              },
            ),
            const Divider(),
            const ListTile(
              title: Text('Con el celular en uso, abrir en grande:'),
              subtitle: Text('Con el celular bloqueado siempre se abre en grande.'),
            ),
            nivel('alarma', 'Alarma'),
            nivel('notificacion', 'Notificación'),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.pin),
              title: Text(p.pinHash == null ? 'Poner PIN a los ajustes' : 'Cambiar el PIN'),
              subtitle: const Text('Evita que se cambien los ajustes de su celular por error'),
              onTap: () async {
                final pin = await pedirTexto(context, 'PIN de 4 números', '', numerico: true);
                if (pin != null && RegExp(r'^\d{4}$').hasMatch(pin)) await _cambiar({'pin': pin});
              },
            ),
            if (p.pinHash != null)
              ListTile(
                leading: const Icon(Icons.lock_open),
                title: const Text('Quitar el PIN'),
                onTap: () => _cambiar({'pin': ''}),
              ),
            if (p.id != foto.yo) ...[
              const Divider(),
              ListTile(
                leading: Icon(Icons.person_remove, color: Colors.red.shade800),
                title: const Text('Desvincular a esta persona'),
                subtitle: const Text('Si nadie más la gestiona, se borran sus recordatorios, historial y celulares.'),
                onTap: () async {
                  if (!await confirmarAccion(context, '¿Desvincular a ${p.nombre}?', 'Esto no se puede deshacer.')) {
                    return;
                  }
                  try {
                    await llamar('DELETE', '/v1/persons/${p.id}');
                    await sincronizar();
                    if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
                  } catch (e) {
                    if (context.mounted) avisar(context, '$e');
                  }
                },
              ),
            ],
          ],
        ),
      );
    },
  );
}

/// Código de vinculación: QR + 6 dígitos, vence en 10 min (plan §2).
class Vincular extends StatefulWidget {
  const Vincular({super.key, required this.persona});
  final Persona persona;
  @override
  State<Vincular> createState() => _VincularState();
}

class _VincularState extends State<Vincular> {
  String? _codigo, _error;
  DateTime? _vence;
  Timer? _reloj;
  late final StreamSubscription<Foto?> _sub;
  late final int _antes = widget.persona.celulares.length;

  @override
  void initState() {
    super.initState();
    _pedir();
    _reloj = Timer.periodic(const Duration(seconds: 5), (_) {
      setState(() {});
      sincronizar(); // para enterarse de que el otro celular ya se vinculó
    });
    _sub = cambios.listen((f) {
      if ((f?.persona(widget.persona.id)?.celulares.length ?? 0) > _antes && mounted) {
        avisar(context, '¡Celular vinculado!');
        Navigator.of(context).pop();
      }
    });
  }

  @override
  void dispose() {
    _reloj?.cancel();
    _sub.cancel();
    super.dispose();
  }

  Future<void> _pedir() async {
    try {
      final r = jsonDecode((await llamar('POST', '/v1/persons/${widget.persona.id}/pairing')).body);
      setState(() {
        _codigo = r['code'];
        _vence = DateTime.parse(r['expires_at']);
        _error = null;
      });
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final vencido = _vence != null && DateTime.now().isAfter(_vence!);
    final codigo = _codigo;
    return Scaffold(
      appBar: AppBar(title: Text('Vincular celular de ${widget.persona.nombre}')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text(
            'En el otro celular: instala Recuérdame, ábrela, toca «Vincular este celular» y apunta la cámara aquí.',
            style: TextStyle(fontSize: 18),
          ),
          const SizedBox(height: 24),
          if (_error != null) Text(_error!, style: TextStyle(color: Colors.red.shade800)),
          if (codigo != null && !vencido) ...[
            Center(child: QrImageView(data: 'recuerdame:$codigo', size: 260)),
            const SizedBox(height: 16),
            SelectableText(
              '${codigo.substring(0, 3)} ${codigo.substring(3)}',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 48, letterSpacing: 6, fontWeight: FontWeight.bold),
            ),
            Text(
              'Vence en ${_vence!.difference(DateTime.now()).inMinutes + 1} min · sirve una sola vez',
              textAlign: TextAlign.center,
            ),
          ],
          if (vencido) FilledButton(onPressed: _pedir, child: const Text('El código venció: pedir otro')),
          const SizedBox(height: 24),
          Text('Instalar la app: $servidor/descargar', textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

Future<String?> pedirTexto(BuildContext context, String titulo, String ayuda, {String? inicial, bool numerico = false}) {
  final t = TextEditingController(text: inicial);
  return showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(titulo),
      content: TextField(
        controller: t,
        autofocus: true,
        keyboardType: numerico ? TextInputType.number : TextInputType.text,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(hintText: ayuda),
        onSubmitted: (v) => Navigator.of(c).pop(v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(c).pop(), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.of(c).pop(t.text.trim()), child: const Text('Aceptar')),
      ],
    ),
  );
}

Future<bool> confirmarAccion(BuildContext context, String titulo, String texto) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(titulo),
        content: Text(texto),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.of(c).pop(true), child: const Text('Sí')),
        ],
      ),
    ) ==
    true;
