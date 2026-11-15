# API de Recuérdame (v1)

Base: `https://recuerdame.danihami.xyz`. JSON salvo los audios (`audio/wav`). Errores:
`{"detail": "mensaje"}` con su código HTTP. Autenticación: `Authorization: Bearer <token>`
del celular (256 bits; en la base solo queda su hash).

| Método y ruta | Quién | Qué |
|---|---|---|
| `POST /v1/auth/oidc` `{id_token, model}` | público | Login del gestor con el id_token de Authentik → `{token}`. Solo usuarios de `RECUERDAME_GESTORES` |
| `POST /v1/pair` `{code, model}` | público | Vincula un celular receptor con el código de 6 dígitos → `{token}`. Un solo uso, 10 min, 20 fallos/10 min en total |
| `POST /v1/sync` | celular | Envía bandeja (`events`, `audios` descargados, `health`, versión, `tz_offset_min`) y devuelve la foto completa: `me`, `persons` (con `devices` solo para el gestor), `reminders`, `events` de 8 días |
| `POST /v1/persons` `{name}` | gestor | Crea una persona y la vincula al gestor |
| `PATCH /v1/persons/{id}` `{name?, full_screen?, pin?}` | gestor | `full_screen`: niveles que abren en grande con el celular en uso. `pin: ""` lo quita |
| `DELETE /v1/persons/{id}` | gestor | Desvincula; sin gestores, borra persona, celulares, recordatorios, historial y audios |
| `POST /v1/persons/{id}/pairing` | gestor | Nuevo código de vinculación `{code, expires_at}` (invalida el anterior) |
| `DELETE /v1/devices/{id}` | gestor | Revoca un celular |
| `PUT /v1/reminders/{id}` | gestor | Crea o edita (UUID del cliente). `rev` = versión editada (0 = nuevo); otra → `409`. Con `voice=tts` el servidor genera la voz |
| `DELETE /v1/reminders/{id}` | gestor | Borra el recordatorio, su historial y su audio |
| `POST /v1/tts` `{text}` | gestor | Vista previa de la voz (WAV), no se guarda |
| `PUT /v1/audio/{id}` (WAV, ≤ 3 MB) | gestor | Sube una grabación; luego se usa como `audio_id` con `voice=recording` |
| `GET /v1/audio/{id}` | quien ve el recordatorio | WAV descifrado. La voz TTS ya entregada se regenera desde el texto |
| `GET /v1/app/latest` · `GET /descargar` | público | Versión publicada `{version_code, version_name, sha256}` y el APK |

Recordatorio: `person_id, text, voice (tts|recording|none), audio_id, alert_level
(alarma|notificacion|discreto), repeat_every_min, max_repeats (≤ 7), notify_managers,
dtstart (hora local sin zona), rrule (FREQ HOURLY..YEARLY, sin DTSTART), exdates,
alert_offsets (minutos ≤ 0, p. ej. [-1440, 0]), rev`.

Evento: `id (UUID del cliente), reminder_id, occurrence_at (hora local), offset_min,
type (acked|snoozed), at (con zona)`. Solo se aceptan los de recordatorios propios.
