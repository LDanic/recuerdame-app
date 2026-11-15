"""Expansión de recurrencias (RRULE, RFC 5545).

Todo va en hora local del receptor, sin zona: "8:00" es 8:00 donde esté. Convertir
a un instante real es un paso aparte. La app (Dart) hace lo mismo y ambas deben
dar idéntico resultado sobre `shared/recurrencias.json`.
"""

from collections.abc import Iterator
from datetime import datetime

from dateutil.rrule import rrulestr


def ocurrencias(dtstart: datetime, rrule: str | None) -> Iterator[datetime]:
    """Ocurrencias desde `dtstart` (incluido). Sin regla, ocurre una sola vez."""
    if rrule is None:
        return iter([dtstart])
    return iter(rrulestr(rrule, dtstart=dtstart))
