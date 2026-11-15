"""API de Recuérdame. Contrato en docs/api.md.

Correr: uvicorn recuerdame.main:app --host 127.0.0.1 --port 8791
"""

import base64
import hashlib
import json
import os
import re
import secrets
import sqlite3
import threading
import time
import uuid
from collections import deque
from contextlib import asynccontextmanager
from datetime import UTC, datetime, timedelta
from functools import cache
from pathlib import Path
from typing import Annotated, Literal

import fastapi
import jwt
from dateutil.rrule import rrulestr
from fastapi import Depends, FastAPI, Header, HTTPException, Request, Response
from fastapi.responses import FileResponse
from pydantic import AwareDatetime, BaseModel, Field, NaiveDatetime, model_validator

from . import db, voz

EMISOR = os.environ.get("RECUERDAME_EMISOR", "https://auth.danihami.xyz/application/o/recuerdame/")
# Las llaves se leen de Authentik local: Cloudflare rechaza a Python-urllib (error 1010).
JWKS = os.environ.get("RECUERDAME_JWKS", EMISOR + "jwks/")
CLIENTE = "recuerdame-app"
ID = r"^[A-Za-z0-9-]{8,64}$"
Id = Annotated[str, Field(pattern=ID)]
IdRuta = Annotated[str, fastapi.Path(pattern=ID)]
Nivel = Literal["alarma", "notificacion", "discreto"]
MAX_GRABACION = 3 * 1024 * 1024  # ~60 s de WAV a 22 kHz


def datos() -> Path:
    return Path(os.environ.get("RECUERDAME_DATOS", "datos"))


def audios() -> Path:
    return datos() / "audios"


def llave() -> bytes:
    # Fuera del volumen de datos (plan §10): un respaldo robado no trae la llave.
    return base64.b64decode(Path(os.environ["RECUERDAME_LLAVE"]).read_text().strip())


def _ahora() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


def _hace(**delta) -> str:
    return (datetime.now(UTC) - timedelta(**delta)).isoformat(timespec="seconds")


def _hash(texto: str) -> str:
    return hashlib.sha256(texto.encode()).hexdigest()


def _nuevo_id() -> str:
    return str(uuid.uuid4())


# ---- arranque y purgas ----

def purgar() -> None:
    """Retención del plan §10: historial 1 año, códigos vencidos, audios sin recordatorio."""
    con = db.conectar(datos() / "recuerdame.db")
    with con:
        con.execute("DELETE FROM occurrence_event WHERE at < ?", (_hace(days=365),))
        con.execute("DELETE FROM audit_log WHERE at < ?", (_hace(days=365),))
        con.execute("DELETE FROM pairing_code WHERE expires_at < ?", (_ahora(),))
    # Un día de gracia: una grabación recién subida aún no tiene recordatorio.
    huerfanos = [f[0] for f in con.execute(
        "SELECT id FROM audio WHERE created_at < ? AND id NOT IN"
        " (SELECT audio_id FROM reminder WHERE audio_id IS NOT NULL)", (_hace(days=1),))]
    _borrar_audios(con, huerfanos)
    con.close()


def _purgar_cada_dia() -> None:
    while True:
        purgar()
        time.sleep(24 * 3600)


@asynccontextmanager
async def _vida(_app):
    audios().mkdir(parents=True, exist_ok=True)
    db.crear(datos() / "recuerdame.db")
    threading.Thread(target=_purgar_cada_dia, daemon=True).start()
    yield


app = FastAPI(title="Recuérdame", version="1", lifespan=_vida)


# ---- sesión y autorización (todo pasa por aquí) ----

def conexion():
    con = db.conectar(datos() / "recuerdame.db")
    try:
        yield con
    finally:
        con.close()


Con = Annotated[sqlite3.Connection, Depends(conexion)]


def dispositivo(con: Con, authorization: str = Header("")) -> sqlite3.Row:
    token = authorization.removeprefix("Bearer ").strip()
    fila = con.execute("SELECT * FROM device WHERE token_hash = ?", (_hash(token),)).fetchone()
    if not token or fila is None:
        raise HTTPException(401, "Sesión no válida")
    return fila


Disp = Annotated[sqlite3.Row, Depends(dispositivo)]


def gestor(d: Disp) -> sqlite3.Row:
    if d["role"] != "gestor":
        raise HTTPException(403, "Solo un gestor puede hacer esto")
    return d


Gestor = Annotated[sqlite3.Row, Depends(gestor)]


def visibles(con: sqlite3.Connection, d: sqlite3.Row) -> list[str]:
    """Personas que este celular puede ver: un receptor, solo la suya."""
    if d["role"] == "receptor":
        return [d["person_id"]]
    return [f[0] for f in con.execute(
        "SELECT recipient_id FROM care_link WHERE manager_id = ?", (d["person_id"],))]


def _exigir_gestion(con: sqlite3.Connection, d: sqlite3.Row, person_id: str) -> None:
    # 404 y no 403: no revelar que la persona existe.
    if d["role"] != "gestor" or person_id not in visibles(con, d):
        raise HTTPException(404, "No existe")


def _auditar(con: sqlite3.Connection, d: sqlite3.Row, accion: str, objetivo: str) -> None:
    con.execute("INSERT INTO audit_log VALUES (?, ?, ?, ?, ?)",
                (_ahora(), d["person_id"], d["id"], accion, objetivo))


def _nuevo_dispositivo(con: sqlite3.Connection, person_id: str, rol: str, modelo: str) -> str:
    token = secrets.token_urlsafe(32)  # 256 bits; en la base solo queda el hash
    con.execute(
        "INSERT INTO device (id, person_id, role, token_hash, model, created_at) VALUES (?, ?, ?, ?, ?, ?)",
        (_nuevo_id(), person_id, rol, _hash(token), modelo, _ahora()))
    return token


# ---- login del gestor (Authentik) y vinculación del receptor ----

class Ingreso(BaseModel):
    id_token: str = Field(max_length=8000)
    model: str = Field("", max_length=100)


@cache
def _jwks() -> jwt.PyJWKClient:
    return jwt.PyJWKClient(JWKS)


def validar_id_token(token: str) -> dict:
    clave = _jwks().get_signing_key_from_jwt(token).key
    return jwt.decode(token, clave, algorithms=["RS256"], audience=CLIENTE, issuer=EMISOR)


@app.post("/v1/auth/oidc")
def ingresar_gestor(datos_: Ingreso, con: Con):
    try:
        c = validar_id_token(datos_.id_token)
    except jwt.PyJWTError:
        raise HTTPException(401, "Login no válido")
    # ponytail: lista fija de gestores; el registro por invitación llega en la fase 3.
    permitidos = {x.strip().lower() for x in os.environ.get("RECUERDAME_GESTORES", "").split(",") if x.strip()}
    if not permitidos & {str(c.get("preferred_username", "")).lower(), str(c.get("email", "")).lower()}:
        raise HTTPException(403, "Esta cuenta no está autorizada como gestor")
    with con:
        fila = con.execute("SELECT id FROM person WHERE authentik_sub = ?", (c["sub"],)).fetchone()
        if fila:
            pid = fila["id"]
        else:
            pid = _nuevo_id()
            nombre = (c.get("name") or c.get("preferred_username") or "Gestor")[:60]
            con.execute("INSERT INTO person (id, name, authentik_sub, created_at) VALUES (?, ?, ?, ?)",
                        (pid, nombre, c["sub"], _ahora()))
            # Doble rol: el gestor también recibe sus propios recordatorios.
            con.execute("INSERT INTO care_link VALUES (?, ?, ?, ?)", (pid, pid, pid, _ahora()))
        token = _nuevo_dispositivo(con, pid, "gestor", datos_.model)
    return {"token": token}


class Vinculo(BaseModel):
    code: str = Field(pattern=r"^\d{6}$")
    model: str = Field("", max_length=100)


# Límite global: quien adivina no sabe a qué persona apunta, así que se cuenta todo junto.
_fallos: deque[float] = deque()
_candado_fallos = threading.Lock()
MAX_FALLOS = 20  # por cada 10 minutos


@app.post("/v1/pair")
def vincular(v: Vinculo, con: Con):
    with _candado_fallos:
        while _fallos and _fallos[0] < time.monotonic() - 600:
            _fallos.popleft()
        if len(_fallos) >= MAX_FALLOS:
            raise HTTPException(429, "Demasiados intentos. Espera unos minutos.")
    with con:
        fila = con.execute(
            "DELETE FROM pairing_code WHERE code_hash = ? AND expires_at > ? RETURNING person_id",
            (_hash(v.code), _ahora())).fetchone()
        token = fila and _nuevo_dispositivo(con, fila["person_id"], "receptor", v.model)
    if not token:
        with _candado_fallos:
            _fallos.append(time.monotonic())
        raise HTTPException(400, "Código incorrecto o vencido")
    return {"token": token}


@app.post("/v1/persons/{pid}/pairing")
def codigo_vinculacion(pid: IdRuta, d: Gestor, con: Con):
    _exigir_gestion(con, d, pid)
    vence = (datetime.now(UTC) + timedelta(minutes=10)).isoformat(timespec="seconds")
    with con:
        con.execute("DELETE FROM pairing_code WHERE person_id = ?", (pid,))
        while True:
            codigo = f"{secrets.randbelow(10**6):06d}"
            try:
                con.execute("INSERT INTO pairing_code VALUES (?, ?, ?)", (_hash(codigo), pid, vence))
                break
            except sqlite3.IntegrityError:  # choca con otro código vigente
                continue
        _auditar(con, d, "codigo_vinculacion", pid)
    return {"code": codigo, "expires_at": vence}


# ---- personas y celulares ----

class NuevaPersona(BaseModel):
    name: str = Field(min_length=1, max_length=60)


class CambioPersona(BaseModel):
    name: str | None = Field(None, min_length=1, max_length=60)
    full_screen: list[Nivel] | None = None
    pin: str | None = Field(None, pattern=r"^(\d{4})?$")  # "" quita el PIN


@app.post("/v1/persons")
def crear_persona(p: NuevaPersona, d: Gestor, con: Con):
    pid = _nuevo_id()
    with con:
        con.execute("INSERT INTO person (id, name, created_at) VALUES (?, ?, ?)", (pid, p.name.strip(), _ahora()))
        con.execute("INSERT INTO care_link VALUES (?, ?, ?, ?)", (d["person_id"], pid, d["person_id"], _ahora()))
        _auditar(con, d, "crear_persona", pid)
    return {"id": pid}


@app.patch("/v1/persons/{pid}")
def cambiar_persona(pid: IdRuta, p: CambioPersona, d: Gestor, con: Con):
    _exigir_gestion(con, d, pid)
    with con:
        if p.name is not None:
            con.execute("UPDATE person SET name = ? WHERE id = ?", (p.name.strip(), pid))
        if p.full_screen is not None:
            con.execute("UPDATE person SET full_screen = ? WHERE id = ?", (json.dumps(sorted(set(p.full_screen))), pid))
        if p.pin is not None:
            # ponytail: 4 dígitos se adivinan; es un seguro contra toques accidentales, no una clave.
            con.execute("UPDATE person SET pin_hash = ? WHERE id = ?", (_hash(f"{pid}:{p.pin}") if p.pin else None, pid))
        _auditar(con, d, "cambiar_persona", pid)
    return {}


@app.delete("/v1/persons/{pid}")
def desvincular(pid: IdRuta, d: Gestor, con: Con):
    _exigir_gestion(con, d, pid)
    if pid == d["person_id"]:
        raise HTTPException(400, "No puedes desvincularte de ti mismo")
    audios_ = [f[0] for f in con.execute(
        "SELECT audio_id FROM reminder WHERE person_id = ? AND audio_id IS NOT NULL", (pid,))]
    with con:
        con.execute("DELETE FROM care_link WHERE manager_id = ? AND recipient_id = ?", (d["person_id"], pid))
        # Sin gestores, desvincular borra de verdad: celulares, recordatorios, historial y audios.
        borrada = con.execute(
            "DELETE FROM person WHERE id = ? AND authentik_sub IS NULL"
            " AND NOT EXISTS (SELECT 1 FROM care_link WHERE recipient_id = ?)", (pid, pid)).rowcount
        _auditar(con, d, "desvincular", pid)
    if borrada:
        _borrar_audios(con, audios_)
    return {}


@app.delete("/v1/devices/{did}")
def revocar_dispositivo(did: IdRuta, d: Gestor, con: Con):
    fila = con.execute("SELECT person_id FROM device WHERE id = ?", (did,)).fetchone()
    if fila is None:
        raise HTTPException(404, "No existe")
    _exigir_gestion(con, d, fila["person_id"])
    with con:
        con.execute("DELETE FROM device WHERE id = ?", (did,))
        _auditar(con, d, "revocar_dispositivo", did)
    return {}


# ---- recordatorios ----

class Recordatorio(BaseModel):
    person_id: Id
    text: str = Field(min_length=1, max_length=300)
    voice: Literal["tts", "recording", "none"]
    audio_id: Id | None = None  # solo con voice=recording
    alert_level: Nivel
    repeat_every_min: int = Field(10, ge=1, le=60)
    max_repeats: int = Field(3, ge=0, le=7)  # el id de alarma en el celular reserva 3 bits
    notify_managers: bool = True
    dtstart: NaiveDatetime  # hora local del receptor
    rrule: str | None = Field(None, max_length=200)
    exdates: list[NaiveDatetime] = Field([], max_length=200)
    alert_offsets: list[int] = Field([0], min_length=1, max_length=5)  # minutos, <= 0
    rev: int = Field(0, ge=0)  # versión que el cliente editó; 0 = nuevo

    @model_validator(mode="after")
    def _coherente(self):
        if any(not -7 * 1440 <= o <= 0 for o in self.alert_offsets):
            raise ValueError("los avisos previos van de 7 días antes hasta la hora")
        if self.rrule is not None:
            # Sin SECONDLY/MINUTELY: millones de ocurrencias tumbarían al celular.
            if not re.fullmatch(r"FREQ=(HOURLY|DAILY|WEEKLY|MONTHLY|YEARLY)(;[A-Z]+=[A-Z0-9,+\-]+)*", self.rrule):
                raise ValueError("rrule no soportada")
            try:
                rrulestr(self.rrule, dtstart=self.dtstart)
            except (ValueError, TypeError) as e:
                raise ValueError(f"rrule inválida: {e}")
        if (self.voice == "recording") != (self.audio_id is not None):
            raise ValueError("audio_id va solo con voice=recording")
        return self


def _recordatorio(f: sqlite3.Row) -> dict:
    r = dict(f)
    r["exdates"] = json.loads(r["exdates"])
    r["alert_offsets"] = json.loads(r["alert_offsets"])
    r["notify_managers"] = bool(r["notify_managers"])
    return r


class _Conflicto(Exception):
    pass


@app.put("/v1/reminders/{rid}")
def guardar_recordatorio(rid: IdRuta, r: Recordatorio, d: Gestor, con: Con):
    _exigir_gestion(con, d, r.person_id)
    actual = con.execute("SELECT * FROM reminder WHERE id = ?", (rid,)).fetchone()
    if actual is not None:
        _exigir_gestion(con, d, actual["person_id"])
    if (actual["rev"] if actual else 0) != r.rev:
        raise HTTPException(409, "Otro gestor cambió este recordatorio. Vuelve a abrirlo.")

    audio_id, nuevo_tts = r.audio_id, None
    if r.voice == "recording" and not (actual and actual["audio_id"] == audio_id):
        a = con.execute("SELECT kind, owner_id FROM audio WHERE id = ?", (audio_id,)).fetchone()
        if a is None or a["kind"] != "recording" or a["owner_id"] != d["person_id"]:
            raise HTTPException(422, "No encuentro esa grabación")
    if r.voice == "tts":
        if actual and actual["voice"] == "tts" and actual["text"] == r.text:
            audio_id = actual["audio_id"]
        else:
            audio_id = nuevo_tts = _nuevo_id()
            voz.guardar(audios(), llave(), nuevo_tts, voz.sintetizar(r.text))

    ahora = _ahora()
    campos = (r.person_id, r.text, r.voice, audio_id, r.alert_level, r.repeat_every_min,
              r.max_repeats, int(r.notify_managers), r.dtstart.isoformat(timespec="seconds"), r.rrule,
              json.dumps([x.isoformat(timespec="seconds") for x in r.exdates]),
              json.dumps(sorted(set(r.alert_offsets))), d["person_id"], ahora)
    try:
        with con:
            if nuevo_tts:
                con.execute("INSERT INTO audio (id, kind, owner_id, text, created_at) VALUES (?, 'tts', ?, ?, ?)",
                            (nuevo_tts, d["person_id"], r.text, ahora))
            if actual is None:
                con.execute(
                    "INSERT INTO reminder (person_id, text, voice, audio_id, alert_level,"
                    " repeat_every_min, max_repeats, notify_managers, dtstart, rrule, exdates, alert_offsets,"
                    " updated_by, updated_at, id, rev, created_by, created_at)"
                    " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)",
                    (*campos, rid, d["person_id"], ahora))
            elif con.execute(
                    "UPDATE reminder SET person_id = ?, text = ?, voice = ?, audio_id = ?, alert_level = ?,"
                    " repeat_every_min = ?, max_repeats = ?, notify_managers = ?, dtstart = ?,"
                    " rrule = ?, exdates = ?, alert_offsets = ?, updated_by = ?, updated_at = ?, rev = rev + 1"
                    " WHERE id = ? AND rev = ?", (*campos, rid, r.rev)).rowcount == 0:
                raise _Conflicto
            _auditar(con, d, "guardar_recordatorio", rid)
    except (_Conflicto, sqlite3.IntegrityError):
        if nuevo_tts:
            voz.borrar(audios(), nuevo_tts)
        raise HTTPException(409, "Otro gestor cambió este recordatorio. Vuelve a abrirlo.")
    if actual and actual["audio_id"] and actual["audio_id"] != audio_id:
        _borrar_audios(con, [actual["audio_id"]])
    return _recordatorio(con.execute("SELECT * FROM reminder WHERE id = ?", (rid,)).fetchone())


@app.delete("/v1/reminders/{rid}")
def borrar_recordatorio(rid: IdRuta, d: Gestor, con: Con):
    actual = con.execute("SELECT person_id, audio_id FROM reminder WHERE id = ?", (rid,)).fetchone()
    if actual is None:
        raise HTTPException(404, "No existe")
    _exigir_gestion(con, d, actual["person_id"])
    with con:
        con.execute("DELETE FROM reminder WHERE id = ?", (rid,))
        _auditar(con, d, "borrar_recordatorio", rid)
    if actual["audio_id"]:
        _borrar_audios(con, [actual["audio_id"]])
    return {}


# ---- audios ----

def _borrar_audios(con: sqlite3.Connection, ids: list[str]) -> None:
    for aid in ids:
        with con:
            con.execute("DELETE FROM audio WHERE id = ?", (aid,))
        voz.borrar(audios(), aid)


class Texto(BaseModel):
    text: str = Field(min_length=1, max_length=300)


@app.post("/v1/tts")
def vista_previa(t: Texto, _d: Gestor):
    return Response(voz.sintetizar(t.text), media_type="audio/wav")


@app.put("/v1/audio/{aid}")
async def subir_grabacion(aid: IdRuta, request: Request, d: Gestor, con: Con):
    if int(request.headers.get("content-length") or 0) > MAX_GRABACION:
        raise HTTPException(413, "La grabación es muy larga")
    cuerpo = await request.body()
    if len(cuerpo) > MAX_GRABACION or cuerpo[:4] != b"RIFF" or cuerpo[8:12] != b"WAVE":
        raise HTTPException(422, "Se espera un WAV de menos de 3 MB")
    try:
        with con:
            con.execute("INSERT INTO audio (id, kind, owner_id, created_at) VALUES (?, 'recording', ?, ?)",
                        (aid, d["person_id"], _ahora()))
            voz.guardar(audios(), llave(), aid, cuerpo)
    except sqlite3.IntegrityError:
        raise HTTPException(409, "Ese audio ya existe")
    return {"id": aid}


@app.get("/v1/audio/{aid}")
def bajar_audio(aid: IdRuta, d: Disp, con: Con):
    a = con.execute("SELECT a.*, r.person_id FROM audio a LEFT JOIN reminder r ON r.audio_id = a.id"
                    " WHERE a.id = ?", (aid,)).fetchone()
    propio = d["role"] == "gestor" and a is not None and a["owner_id"] == d["person_id"]
    if a is None or not (propio or a["person_id"] in visibles(con, d)):
        raise HTTPException(404, "No existe")
    wav = voz.leer(audios(), llave(), aid)
    if wav is None and a["kind"] == "tts":  # ya entregado y borrado: se regenera del texto
        wav = voz.sintetizar(a["text"])
        voz.guardar(audios(), llave(), aid, wav)
    if wav is None:
        raise HTTPException(404, "El audio se perdió")
    return Response(wav, media_type="audio/wav")


def _confirmar_descargas(con: sqlite3.Connection, d: sqlite3.Row, ids: list[str], vis: list[str]) -> None:
    for aid in ids:
        a = con.execute("SELECT a.kind, r.person_id FROM audio a JOIN reminder r ON r.audio_id = a.id"
                        " WHERE a.id = ?", (aid,)).fetchone()
        if a is None or a["person_id"] not in vis:
            continue
        with con:
            con.execute("INSERT OR IGNORE INTO audio_delivery VALUES (?, ?)", (aid, d["id"]))
        faltan = con.execute(
            "SELECT 1 FROM device WHERE person_id = ? AND id NOT IN"
            " (SELECT device_id FROM audio_delivery WHERE audio_id = ?)", (a["person_id"], aid)).fetchone()
        if a["kind"] == "tts" and not faltan:  # plan §2: la voz TTS se borra al llegar a todos
            voz.borrar(audios(), aid)


# ---- sincronización ----

Salud = dict[str, bool | int | float | Annotated[str, Field(max_length=100)] | None]


class Evento(BaseModel):
    id: Id
    reminder_id: Id
    occurrence_at: NaiveDatetime
    offset_min: int
    type: Literal["acked", "snoozed"]
    at: AwareDatetime


class Sincro(BaseModel):
    app_version: str = Field("", max_length=20)
    model: str = Field("", max_length=100)
    tz_offset_min: int | None = Field(None, ge=-840, le=840)
    health: Salud = Field({}, max_length=30)
    events: list[Evento] = Field([], max_length=500)
    audios: list[Id] = Field([], max_length=200)  # descargados desde la última vez


@app.post("/v1/sync")
def sincronizar(s: Sincro, d: Disp, con: Con):
    """Recibe la bandeja de salida del celular y devuelve todo lo que puede ver.

    ponytail: foto completa en cada llamada; con una familia son pocos KB. Cursor
    incremental si algún día pesa.
    """
    vis = visibles(con, d)
    with con:
        con.execute("UPDATE device SET app_version = ?, model = ?, tz_offset_min = ?, health = ?, last_sync_at = ?"
                    " WHERE id = ?", (s.app_version, s.model, s.tz_offset_min, json.dumps(s.health), _ahora(), d["id"]))
        for e in s.events:
            # Solo se confirma lo propio, aunque sea gestor.
            if con.execute("SELECT 1 FROM reminder WHERE id = ? AND person_id = ?",
                           (e.reminder_id, d["person_id"])).fetchone():
                con.execute("INSERT OR IGNORE INTO occurrence_event VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                            (e.id, e.reminder_id, e.occurrence_at.isoformat(timespec="seconds"), e.offset_min,
                             e.type, d["person_id"], d["id"], e.at.astimezone(UTC).isoformat(timespec="seconds")))
    _confirmar_descargas(con, d, s.audios, vis)
    return _foto(con, d, vis)


def _foto(con: sqlite3.Connection, d: sqlite3.Row, vis: list[str]) -> dict:
    marcas = ",".join("?" * len(vis))
    personas = {}
    for p in con.execute(f"SELECT * FROM person WHERE id IN ({marcas})", vis):
        personas[p["id"]] = {"id": p["id"], "name": p["name"], "full_screen": json.loads(p["full_screen"]),
                             "pin_hash": p["pin_hash"], "is_manager": p["authentik_sub"] is not None,
                             "devices": []}
    if d["role"] == "gestor":  # la salud de los celulares solo la ve el gestor
        for c in con.execute(f"SELECT id, person_id, role, model, app_version, health, tz_offset_min, last_sync_at"
                             f" FROM device WHERE person_id IN ({marcas})", vis):
            personas[c["person_id"]]["devices"].append({**dict(c), "health": json.loads(c["health"])})
    recordatorios = [_recordatorio(f) for f in con.execute(
        f"SELECT * FROM reminder WHERE person_id IN ({marcas})", vis)]
    eventos = [dict(f) for f in con.execute(
        f"SELECT * FROM occurrence_event WHERE at >= ? AND reminder_id IN"
        f" (SELECT id FROM reminder WHERE person_id IN ({marcas}))", (_hace(days=8), *vis))]
    return {"me": {"person_id": d["person_id"], "device_id": d["id"], "role": d["role"]},
            "persons": list(personas.values()), "reminders": recordatorios, "events": eventos}


# ---- app ----

@app.get("/v1/salud")
def salud():
    return {"ok": True}


@app.get("/v1/app/latest")
def ultima_version():
    ruta = datos() / "app" / "latest.json"
    if not ruta.exists():
        raise HTTPException(404, "Sin versión publicada")
    return json.loads(ruta.read_text())


@app.get("/descargar")
def descargar_apk():
    ruta = datos() / "app" / "recuerdame.apk"
    if not ruta.exists():
        raise HTTPException(404, "Sin versión publicada")
    return FileResponse(ruta, media_type="application/vnd.android.package-archive", filename="recuerdame.apk")
