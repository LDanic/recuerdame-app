import json
from datetime import datetime
from itertools import islice
from pathlib import Path

import pytest

from recuerdame.recurrencias import ocurrencias

CASOS = json.loads((Path(__file__).parents[2] / "shared/recurrencias.json").read_text(encoding="utf-8"))


@pytest.mark.parametrize("caso", CASOS, ids=lambda c: c["nombre"])
def test_paridad_con_la_app(caso):
    inicio = datetime.fromisoformat(caso["dtstart"])
    obtenido = [d.isoformat() for d in islice(ocurrencias(inicio, caso["rrule"]), caso["n"])]
    assert obtenido == caso["esperado"]
