"""API: autorización (IDOR), vinculación, sincronización, audios y purgas."""

import base64
import os
import uuid

import pytest
from fastapi.testclient import TestClient

from recuerdame import db, main, voz

WAV = b"RIFF\x24\x00\x00\x00WAVEfmt " + bytes(28)


@pytest.fixture
def c(tmp_path, monkeypatch):
    llave = tmp_path / "llave"
    llave.write_text(base64.b64encode(os.urandom(32)).decode())
    monkeypatch.setenv("RECUERDAME_DATOS", str(tmp_path / "datos"))
    monkeypatch.setenv("RECUERDAME_LLAVE", str(llave))
    monkeypatch.setenv("RECUERDAME_GESTORES", "ana,beto@x.co")
    monkeypatch.setattr(voz, "sintetizar", lambda texto: WAV + texto.encode())
    # id_token falso: "sub|usuario"
    monkeypatch.setattr(main, "validar_id_token", lambda t: dict(
        zip(["sub", "preferred_username", "email"], [*t.split("|"), "beto@x.co" if "beto" in t else ""])))
    main._fallos.clear()
    with TestClient(main.app) as cliente:
        yield cliente


def h(token):
    return {"Authorization": f"Bearer {token}"}


def gestor(c, usuario="ana"):
    r = c.post("/v1/auth/oidc", json={"id_token": f"sub-{usuario}|{usuario}"})
    assert r.status_code == 200, r.text
    return r.json()["token"]


def sync(c, token, **cuerpo):
    r = c.post("/v1/sync", headers=h(token), json=cuerpo)
    assert r.status_code == 200, r.text
    return r.json()


def persona(c, token, nombre="Papá"):
    return c.post("/v1/persons", headers=h(token), json={"name": nombre}).json()["id"]


def receptor(c, token, pid):
    codigo = c.post(f"/v1/persons/{pid}/pairing", headers=h(token)).json()["code"]
    r = c.post("/v1/pair", json={"code": codigo, "model": "Galaxy A15"})
    assert r.status_code == 200, r.text
    return r.json()["token"]


def cuerpo(pid, **extra):
    return {"person_id": pid, "text": "Tomar la pastilla", "voice": "tts", "alert_level": "alarma",
            "dtstart": "2026-11-15T08:00:00", "rrule": "FREQ=DAILY", **extra}


def guardar(c, token, pid, rid=None, **extra):
    return c.put(f"/v1/reminders/{rid or uuid.uuid4()}", headers=h(token), json=cuerpo(pid, **extra))


def test_solo_entran_gestores_autorizados(c):
    assert c.post("/v1/auth/oidc", json={"id_token": "sub-x|intruso"}).status_code == 403
    assert gestor(c, "beto")  # por email


def test_gestor_se_ve_a_si_mismo_y_repetir_login_no_duplica(c):
    a, b = gestor(c), gestor(c)
    fa, fb = sync(c, a), sync(c, b)
    assert fa["me"]["person_id"] == fb["me"]["person_id"]
    assert [p["is_manager"] for p in fa["persons"]] == [True]


def test_sin_token_no_hay_acceso(c):
    assert c.post("/v1/sync", json={}).status_code == 401
    assert c.post("/v1/sync", headers=h("inventado"), json={}).status_code == 401


def test_codigo_de_vinculacion_es_de_un_solo_uso(c):
    a = gestor(c)
    pid = persona(c, a)
    codigo = c.post(f"/v1/persons/{pid}/pairing", headers=h(a)).json()["code"]
    assert c.post("/v1/pair", json={"code": codigo}).status_code == 200
    assert c.post("/v1/pair", json={"code": codigo}).status_code == 400


def test_codigo_vencido_no_sirve(c):
    a = gestor(c)
    codigo = c.post(f"/v1/persons/{persona(c, a)}/pairing", headers=h(a)).json()["code"]
    con = db.conectar(main.datos() / "recuerdame.db")
    with con:
        con.execute("UPDATE pairing_code SET expires_at = '2000-01-01T00:00:00+00:00'")
    assert c.post("/v1/pair", json={"code": codigo}).status_code == 400


def test_limite_de_intentos_de_vinculacion(c):
    for _ in range(main.MAX_FALLOS):
        assert c.post("/v1/pair", json={"code": "000000"}).status_code == 400
    assert c.post("/v1/pair", json={"code": "000000"}).status_code == 429


def test_receptor_solo_ve_lo_suyo_y_gestor_ve_su_celular(c):
    a = gestor(c)
    papa, mama = persona(c, a), persona(c, a, "Mamá")
    guardar(c, a, papa)
    guardar(c, a, mama)
    r = receptor(c, a, papa)
    f = sync(c, r, health={"alarmas_exactas": True}, model="Galaxy A15")
    assert [p["id"] for p in f["persons"]] == [papa]
    assert {x["person_id"] for x in f["reminders"]} == {papa}
    assert f["persons"][0]["devices"] == []  # la salud la ve solo el gestor
    papa_en_gestor = next(p for p in sync(c, a)["persons"] if p["id"] == papa)
    assert papa_en_gestor["devices"][0]["health"] == {"alarmas_exactas": True}


def test_otro_gestor_no_toca_datos_ajenos(c):
    a, b = gestor(c), gestor(c, "beto")
    papa = persona(c, a)
    rid = guardar(c, a, papa).json()["id"]
    audio = sync(c, a)["reminders"][0]["audio_id"]
    assert guardar(c, b, papa).status_code == 404
    assert guardar(c, b, sync(c, b)["me"]["person_id"], rid=rid).status_code == 404  # no lo roba
    assert c.delete(f"/v1/reminders/{rid}", headers=h(b)).status_code == 404
    assert c.patch(f"/v1/persons/{papa}", headers=h(b), json={"name": "x"}).status_code == 404
    assert c.post(f"/v1/persons/{papa}/pairing", headers=h(b)).status_code == 404
    assert c.delete(f"/v1/persons/{papa}", headers=h(b)).status_code == 404
    assert c.get(f"/v1/audio/{audio}", headers=h(b)).status_code == 404
    assert papa not in [p["id"] for p in sync(c, b)["persons"]]
    assert sync(c, b)["reminders"] == []


def test_receptor_no_edita_ni_crea(c):
    a = gestor(c)
    papa = persona(c, a)
    r = receptor(c, a, papa)
    assert guardar(c, r, papa).status_code == 403
    assert c.post("/v1/persons", headers=h(r), json={"name": "x"}).status_code == 403


def test_edicion_simultanea_da_conflicto(c):
    a = gestor(c)
    papa = persona(c, a)
    rid = str(uuid.uuid4())
    assert guardar(c, a, papa, rid=rid).json()["rev"] == 1
    assert guardar(c, a, papa, rid=rid, rev=0).status_code == 409
    assert guardar(c, a, papa, rid=rid, rev=1, text="Otra").json()["rev"] == 2


@pytest.mark.parametrize("malo", [
    {"rrule": "FREQ=SECONDLY"},
    {"rrule": "FREQ=DAILY;DTSTART=20260101T000000"},
    {"rrule": "FREQ=DAILY;BYDAY=XX"},
    {"dtstart": "2026-11-15T08:00:00Z"},
    {"alert_offsets": [60]},
    {"max_repeats": 8},
    {"voice": "recording"},
])
def test_validaciones(c, malo):
    a = gestor(c)
    assert guardar(c, a, persona(c, a), **malo).status_code == 422


def test_eventos_idempotentes_y_solo_propios(c):
    a = gestor(c)
    papa, mama = persona(c, a), persona(c, a, "Mamá")
    rp = guardar(c, a, papa).json()["id"]
    rm = guardar(c, a, mama).json()["id"]
    r = receptor(c, a, papa)
    ev = {"id": str(uuid.uuid4()), "reminder_id": rp, "occurrence_at": "2026-11-15T08:00:00",
          "offset_min": 0, "type": "acked", "at": "2026-11-15T13:01:00Z"}
    ajeno = {**ev, "id": str(uuid.uuid4()), "reminder_id": rm}
    sync(c, r, events=[ev, ajeno])
    sync(c, r, events=[ev])  # reintento tras perder la respuesta
    eventos = sync(c, a)["events"]
    assert [e["reminder_id"] for e in eventos] == [rp]


def test_voz_tts_se_borra_al_entregarse_y_se_regenera(c, monkeypatch):
    a = gestor(c)
    papa = persona(c, a)
    r = receptor(c, a, papa)
    audio = guardar(c, a, papa).json()["audio_id"]
    assert (main.audios() / audio).exists()
    assert c.get(f"/v1/audio/{audio}", headers=h(r)).content == WAV + b"Tomar la pastilla"
    sync(c, r, audios=[audio])
    assert not (main.audios() / audio).exists()  # el único celular destino ya lo tiene
    assert c.get(f"/v1/audio/{audio}", headers=h(r)).content == WAV + b"Tomar la pastilla"


def test_mismo_texto_no_regenera_la_voz(c):
    a = gestor(c)
    papa = persona(c, a)
    rid = str(uuid.uuid4())
    primero = guardar(c, a, papa, rid=rid).json()["audio_id"]
    assert guardar(c, a, papa, rid=rid, rev=1, alert_level="notificacion").json()["audio_id"] == primero
    nuevo = guardar(c, a, papa, rid=rid, rev=2, text="Otra cosa").json()["audio_id"]
    assert nuevo != primero and not (main.audios() / primero).exists()


def test_grabacion_cifrada_y_solo_del_que_la_subio(c):
    a, b = gestor(c), gestor(c, "beto")
    aid = str(uuid.uuid4())
    assert c.put(f"/v1/audio/{aid}", headers=h(a), content=b"no es wav").status_code == 422
    assert c.put(f"/v1/audio/{aid}", headers=h(a), content=WAV + b"hola").status_code == 200
    assert b"hola" not in (main.audios() / aid).read_bytes()
    otro = sync(c, b)["me"]["person_id"]
    assert guardar(c, b, otro, voice="recording", audio_id=aid).status_code == 422
    papa = persona(c, a)
    assert guardar(c, a, papa, voice="recording", audio_id=aid).status_code == 200
    assert c.get(f"/v1/audio/{aid}", headers=h(receptor(c, a, papa))).content == WAV + b"hola"


def test_purga(c):
    a = gestor(c)
    papa = persona(c, a)
    rid = guardar(c, a, papa).json()["id"]
    con = db.conectar(main.datos() / "recuerdame.db")
    with con:
        con.execute("INSERT INTO occurrence_event VALUES ('viejo-1234', ?, '2025-01-01T08:00:00', 0, 'acked',"
                    " ?, 'x', '2025-01-01T13:00:00+00:00')", (rid, papa))
        con.execute("INSERT INTO audio (id, kind, owner_id, created_at)"
                    " VALUES ('huerfano-1234', 'recording', ?, '2025-01-01T00:00:00+00:00')", (papa,))
    voz.guardar(main.audios(), main.llave(), "huerfano-1234", WAV)
    main.purgar()
    assert con.execute("SELECT count(*) FROM occurrence_event").fetchone()[0] == 0
    assert con.execute("SELECT count(*) FROM audio").fetchone()[0] == 1  # queda la del recordatorio
    assert not (main.audios() / "huerfano-1234").exists()


def test_desvincular_borra_de_verdad(c):
    a = gestor(c)
    papa = persona(c, a)
    r = receptor(c, a, papa)
    audio = guardar(c, a, papa).json()["audio_id"]
    assert c.delete(f"/v1/persons/{sync(c, a)['me']['person_id']}", headers=h(a)).status_code == 400
    assert c.delete(f"/v1/persons/{papa}", headers=h(a)).status_code == 200
    assert c.post("/v1/sync", headers=h(r), json={}).status_code == 401
    assert not (main.audios() / audio).exists()
    assert [p["id"] for p in sync(c, a)["persons"]] == [sync(c, a)["me"]["person_id"]]
