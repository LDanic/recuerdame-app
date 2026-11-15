import 'package:rrule/rrule.dart';

/// Expansión de recurrencias (RRULE, RFC 5545).
///
/// Todo va en hora local del receptor, sin zona: "8:00" es 8:00 donde esté.
/// El paquete `rrule` representa esa hora "flotante" con un DateTime en UTC;
/// convertirla a un instante real es un paso aparte. El servidor (Python) hace
/// lo mismo y ambos deben dar idéntico resultado sobre `shared/recurrencias.json`.
Iterable<DateTime> ocurrencias(DateTime dtstart, String? rrule) {
  if (rrule == null) return [dtstart];
  return RecurrenceRule.fromString('RRULE:$rrule').getInstances(start: dtstart);
}
