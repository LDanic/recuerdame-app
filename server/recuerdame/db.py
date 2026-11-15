"""Base SQLite (WAL). Una conexión por petición; el esquema se crea al arrancar."""

import sqlite3
from pathlib import Path

ESQUEMA = """
CREATE TABLE IF NOT EXISTS person (
    id            TEXT PRIMARY KEY,
    name          TEXT NOT NULL,
    authentik_sub TEXT UNIQUE,            -- solo los gestores
    full_screen   TEXT NOT NULL DEFAULT '["alarma"]',  -- niveles que abren en grande
    pin_hash      TEXT,                   -- sha256(id:pin), protege los ajustes del receptor
    created_at    TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS care_link (
    manager_id   TEXT NOT NULL REFERENCES person(id) ON DELETE CASCADE,
    recipient_id TEXT NOT NULL REFERENCES person(id) ON DELETE CASCADE,
    created_by   TEXT NOT NULL,
    created_at   TEXT NOT NULL,
    PRIMARY KEY (manager_id, recipient_id)
);
CREATE TABLE IF NOT EXISTS device (
    id            TEXT PRIMARY KEY,
    person_id     TEXT NOT NULL REFERENCES person(id) ON DELETE CASCADE,
    role          TEXT NOT NULL CHECK (role IN ('gestor', 'receptor')),
    token_hash    TEXT NOT NULL UNIQUE,
    model         TEXT NOT NULL DEFAULT '',
    app_version   TEXT NOT NULL DEFAULT '',
    health        TEXT NOT NULL DEFAULT '{}',
    tz_offset_min INTEGER,
    last_sync_at  TEXT,
    created_at    TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS pairing_code (
    code_hash  TEXT PRIMARY KEY,
    person_id  TEXT NOT NULL REFERENCES person(id) ON DELETE CASCADE,
    expires_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS reminder (
    id               TEXT PRIMARY KEY,    -- UUID del cliente
    person_id        TEXT NOT NULL REFERENCES person(id) ON DELETE CASCADE,
    text             TEXT NOT NULL,
    voice            TEXT NOT NULL CHECK (voice IN ('tts', 'recording', 'none')),
    audio_id         TEXT,
    alert_level      TEXT NOT NULL CHECK (alert_level IN ('alarma', 'notificacion', 'discreto')),
    repeat_every_min INTEGER NOT NULL,
    max_repeats      INTEGER NOT NULL,
    notify_managers  INTEGER NOT NULL,
    dtstart          TEXT NOT NULL,       -- hora local del receptor, sin zona
    rrule            TEXT,
    exdates          TEXT NOT NULL,       -- JSON
    alert_offsets    TEXT NOT NULL,       -- JSON, minutos respecto a la hora (<= 0)
    rev              INTEGER NOT NULL,    -- para detectar ediciones simultáneas
    created_by       TEXT NOT NULL,
    updated_by       TEXT NOT NULL,
    created_at       TEXT NOT NULL,
    updated_at       TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS occurrence_event (
    id            TEXT PRIMARY KEY,       -- UUID del cliente: reenviar no duplica
    reminder_id   TEXT NOT NULL REFERENCES reminder(id) ON DELETE CASCADE,
    occurrence_at TEXT NOT NULL,          -- inicio original, hora local
    offset_min    INTEGER NOT NULL,
    type          TEXT NOT NULL CHECK (type IN ('acked', 'snoozed')),
    person_id     TEXT NOT NULL,
    device_id     TEXT NOT NULL,
    at            TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS occurrence_event_at ON occurrence_event(at);
CREATE TABLE IF NOT EXISTS audio (
    id         TEXT PRIMARY KEY,
    kind       TEXT NOT NULL CHECK (kind IN ('tts', 'recording')),
    owner_id   TEXT NOT NULL,             -- persona que lo creó
    text       TEXT,                      -- TTS: para regenerarlo
    stored     INTEGER NOT NULL DEFAULT 1, -- 0: TTS ya entregado y borrado del disco
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS audio_delivery (
    audio_id  TEXT NOT NULL REFERENCES audio(id) ON DELETE CASCADE,
    device_id TEXT NOT NULL REFERENCES device(id) ON DELETE CASCADE,
    PRIMARY KEY (audio_id, device_id)
);
CREATE TABLE IF NOT EXISTS audit_log (
    at        TEXT NOT NULL,
    person_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    action    TEXT NOT NULL,
    target    TEXT NOT NULL
);
"""


def conectar(ruta: Path) -> sqlite3.Connection:
    # Escrituras en bloques `with con:` (una transacción cada uno).
    con = sqlite3.connect(ruta, check_same_thread=False)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA foreign_keys=ON")
    con.execute("PRAGMA busy_timeout=5000")
    return con


def crear(ruta: Path) -> None:
    con = conectar(ruta)
    con.executescript(ESQUEMA)
    con.close()
