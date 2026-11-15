# Recuérdame — Plan v1

> Estado: **planeación aprobada en sesión del 2026-11-14**. Aún no hay código.
> Este documento es la fuente de verdad del alcance. Si algo cambia, se cambia aquí primero.

## 1. Qué es

App Android de recordatorios donde **el recordatorio es una voz**: un audio que graba el gestor o un
texto que el servidor convierte en voz. Hay dos roles:

- **Gestor**: crea y administra recordatorios para las personas que tiene vinculadas (y para sí mismo).
- **Receptor**: ve sus recordatorios y, cuando suenan, confirma con un toque. Pensado para **adultos mayores**.

Es una app **general** de recordatorios. Las medicinas de los papás son el primer caso, pero el modelo
cubre también "cada 15 días", "primer martes de cada mes limpiar los filtros de la lavadora", citas con
avisos previos, etc. Este servidor (`milo`) es el punto central de sincronización. No hay más
infraestructura que el servidor y los celulares.

## 2. Decisiones tomadas

| Tema | Decisión |
|---|---|
| Alcance | Familia primero (por invitación), con datos separados por grupo desde el día uno para poder abrirla después |
| Med_reminder | Eliminado el 2026-11-14 (contenedor, volumen, imágenes, carpeta). Se empieza de cero |
| Plataforma | Solo Android |
| Distribución | APK directo desde este servidor, con autoactualización desde la app |
| Gestores por receptor | Varios, con los mismos permisos; queda registrado quién hizo cada cambio |
| Doble rol | Una cuenta puede ser gestor y receptor de sus propios recordatorios |
| Permisos del receptor | Los define el gestor por receptor: **modo simple** (ver y confirmar) o **modo completo** (también crea los suyos) |
| Login del gestor | Authentik (OIDC) en `auth.danihami.xyz` |
| Vinculación del receptor | QR en persona o código de 6 dígitos (10 min, un solo uso). El receptor nunca usa contraseña |
| Destinatario | Una persona o un grupo ("hogar"). En un grupo, cualquiera marca y queda hecho para todos |
| Privacidad | Estándar fuerte (ver §10). El servidor sí lee el contenido |
| Voz desde texto | La genera el servidor (Piper TTS, local). **Se borra del servidor cuando todos los celulares destino confirman la descarga**; se regenera desde el texto si hace falta |
| Audio grabado | Se conserva cifrado en el servidor mientras exista el recordatorio; se borra al eliminarlo |
| Botones de la alarma | **Entendido** (grande) + **Más tarde** (10 min) + **Escuchar otra vez** |
| Sin confirmación | Repite (p. ej. cada 5 min, hasta 3 veces) y luego avisa a todos los gestores |
| Silencio / No molestar | Según el nivel de alerta: **Alarma** (suena en silencio, pantalla completa), **Notificación** (respeta el silencio), **Discreto** (solo aparece en la lista) |
| Push | **No.** Sincronización periódica (ver §5) |
| Compilación | Todo Flutter en el PC del usuario (código, `analyze`, tests, APK firmado, celulares por USB). El servidor solo corre el backend (actualizado el 2026-11-14 al mudar el trabajo al PC) |
| Backend | FastAPI + SQLite (WAL), igual que hamidani |
| Pantalla del receptor | Lista "Hoy" en tarjetas grandes |
| Extra en v1 | **Salud del celular del receptor** y **avisos previos a eventos** |
| Marcas a soportar | Xiaomi/Redmi/POCO, Samsung, Motorola |
| Nombre | **Recuérdame**: `recuerdame.danihami.xyz`, paquete `xyz.danihami.recuerdame` |
| Primera meta | Fase 1: el usuario solo, con 2 celulares. Fase 2: sus papás. Luego, hogar y otros gestores |
| Sincronización del receptor | Cada 15 min, y además al abrir la app, al encender el celular y al recuperar la red |
| Historial de confirmaciones | 1 año, luego se purga solo |

## 3. Arquitectura

```
 Celular GESTOR ──HTTPS──┐                        ┌─ SQLite (WAL)
   (Authentik OIDC)      ▼                        ├─ audios (cifrados los grabados)
           Cloudflare → cloudflared → API FastAPI ┼─ worker TTS (Piper, en proceso)
                         ▲   127.0.0.1:8791       └─ tareas: purga historial / audios
 Celular RECEPTOR ─HTTPS─┘
   (token de dispositivo)
   └─ las alarmas se programan EN el celular (AlarmManager): suenan sin internet
```

Cinco principios para que los casos futuros quepan sin construirlos hoy:

1. **La alarma vive en el celular.** El servidor solo sincroniza datos; cada teléfono programa sus
   alarmas localmente. Si se cae internet o el servidor, las alarmas suenan igual.
2. **Recurrencia = RRULE (RFC 5545)**, el estándar de los calendarios. Se guarda la regla, no las
   ocurrencias.
3. **El recordatorio (la regla) va separado de la ocurrencia (cada vez que suena).** Solo se guardan
   los *eventos* de una ocurrencia (confirmada, pospuesta, perdida). No se materializan ocurrencias futuras.
4. **El contenido va separado de la entrega.** El contenido es texto, voz o audio grabado (y fotos en
   el futuro); la entrega es el nivel de alerta, los botones y el escalamiento. Por eso lo de la lavadora
   puede ser una notificación discreta sin voz.
5. **Destinatario = persona o grupo.** El grupo existe en el modelo desde el día uno, aunque su
   interfaz llegue en la fase 3.

## 4. Modelo de datos (conceptual)

| Entidad | Campos clave | Notas |
|---|---|---|
| `person` | id, nombre, `authentik_sub?`, tz (IANA), modo (`simple`/`completo`), `pin_hash?` | El gestor tiene `authentik_sub`; un receptor puro no |
| `device` | id, person_id, `token_hash`, versión de la app, marca/modelo, **salud** (JSON), `last_sync_at` | Un token por celular, revocable |
| `care_link` | manager_id → recipient_id, creado_por, fecha | N:M. Un gestor puede enlazarse a sí mismo |
| `group` / `group_member` | id, nombre / group_id, person_id | El "hogar" |
| `reminder` | id (UUID del cliente), título, texto, `voice` (`tts`/`recording`/`none`), `alert_level`, `buttons`, `snooze_min`, escalamiento (`repeat_every_min`, `max_repeats`, `notify_managers`), `dtstart` (hora local) + tz, `rrule?`, `exdates`, `alert_offsets` (p. ej. `[-1d, -2h, 0]`), version, created_by/updated_by, deleted | Los avisos previos son `alert_offsets` sobre cada ocurrencia: un evento con varias alertas |
| `reminder_target` | reminder_id, person_id **o** group_id | |
| `occurrence_event` | reminder_id, `occurrence_at` (inicio original), offset, tipo (`acked`/`snoozed`/`missed`), person_id, device_id, at | Base del historial; se purga a 1 año |
| `audio_asset` | id, reminder_id, tipo (`tts`/`recording`), sha256, tamaño, ruta, `pending_device_ids`, deleted_at | TTS: se borra cuando `pending_device_ids` queda vacío |
| `pairing_code` | code_hash, person_id, expira, usado | 6 dígitos, 10 min, un uso, con límite de intentos |
| `audit_log` | quién, qué, cuándo | Cambios de gestores |
| `meta` | contador global de versión | Para la sincronización incremental |

## 5. Sincronización (sin push)

- **Incremental por cursor:** `GET /v1/sync?since=N` devuelve solo lo que cambió y lo que el llamante
  tiene permiso de ver. Las escrituras son PUT idempotentes con UUID del cliente. Si alguien edita sobre
  una versión vieja, recibe `409 CONFLICT` (dos gestores editando lo mismo).
- **Receptor offline-first:** confirmaciones, posposiciones y salud van a una *outbox* local y se envían
  en cuanto haya red. Al tocar "Entendido" se intenta enviar de inmediato.
- **Gestor online para editar** en la v1 (simplifica conflictos); sus propias confirmaciones como receptor
  sí son offline-first.
- **Disparadores:** WorkManager cada 15 min, al abrir la app, al encender el celular y al volver la red.
- **Aviso "no confirmó" sin push:** el celular del gestor conoce los horarios de sus receptores y programa
  una **alarma de verificación** para *hora + repeticiones + margen*. A esa hora le pregunta al servidor;
  si no hay confirmación, muestra una notificación local. Distingue entre **"no confirmó"** y
  **"su celular no se ha sincronizado desde las X"** para no generar falsas alarmas.
- **Límite conocido:** un recordatorio creado con menos de unos 30 min de anticipación puede no llegar a
  tiempo al receptor. La app lo advierte al guardar.
- Si el uso real muestra que esto no basta, se evalúa FCM como "timbre" sin datos. Hoy no se construye.

## 6. Alarma en Android (el riesgo n.º 1)

- `AlarmManager.setAlarmClock()` (exacta, funciona en Doze), permisos `SCHEDULE_EXACT_ALARM`/`USE_EXACT_ALARM`,
  pantalla completa sobre la pantalla bloqueada (`USE_FULL_SCREEN_INTENT`) y audio por el canal de alarma
  (`USAGE_ALARM`) solo en el nivel **Alarma**.
- Se programa una ventana de los próximos ~7 días, que se reprograma en cada sincronización, al encender
  el celular y al cambiar la hora o la zona horaria.
- Las repeticiones por falta de confirmación son locales (no requieren red).
- **Salud del celular**, reportada en cada sincronización: alarmas exactas permitidas, notificaciones
  activas, pantalla completa permitida, exento de optimización de batería, volumen de alarma > 0,
  batería, última sincronización y versión de la app. El gestor la ve en verde o rojo.
- **Guías por marca** con enlaces directos a los ajustes: Xiaomi/HyperOS (autoarranque, batería "sin
  restricciones", fijar en recientes), Samsung (sacar de "apps en suspensión"), Motorola.
- Fase 0 decide con un spike si basta el paquete `alarm` de pub.dev o si hace falta una pieza nativa
  en Kotlin (MethodChannel).

## 7. Recurrencias

- Subconjunto de RRULE con presets en la interfaz: una vez; diario (varias horas); días de la semana;
  cada N días o semanas; mensual (día N o "primer martes"); anual.
- `dtstart` se guarda en **hora local + zona IANA del receptor**: "8:00" es 8:00 donde está el receptor.
- Se expande en el celular (Dart, para programar) y en el servidor (`python-dateutil`, para verificar y
  purgar). **Tests de paridad:** un archivo JSON de reglas y ocurrencias esperadas que deben pasar ambas
  implementaciones.

## 8. Voz

- **Texto → voz:** Piper TTS en el contenedor, en una cola en proceso (sin servicios extra). El gestor
  escucha la vista previa antes de guardar. El celular descarga el audio por adelantado, así que a la hora
  de sonar no necesita red. Cuando todos los celulares destino confirman la descarga, se borra del servidor.
  Si un celular nuevo lo necesita, se regenera desde el texto.
- **Grabación:** se graba en la app (máx. ~60 s, AAC/Opus), se guarda cifrada en el servidor
  (AES-256-GCM, llave fuera del volumen) y se borra al eliminar el recordatorio.
- El texto siempre se muestra en pantalla. Si falta el audio, se usa la voz del celular como respaldo.

## 9. Experiencia de uso

**Receptor, modo simple.** Pantalla "Hoy" en tarjetas grandes (hora de 32 sp o más, texto de 24 sp o
más, botones de 72 dp o más), alto contraste, sin gestos ni menús, botón 🔊 por tarjeta. Ajustes detrás
del PIN del gestor. En modo completo además puede crear recordatorios propios.

**Pantalla de alarma:**
```
        2:00 p. m.
  Tomar la pastilla de la presión
      [ 🔊 Escuchar otra vez ]
 ╔═══════════════════════════╗
 ║        ✔  ENTENDIDO        ║
 ╚═══════════════════════════╝
     [ ⏰ Más tarde (10 min) ]
```

**Gestor.** Inicio con la lista de personas, cada una con un indicador de salud del celular y el estado
de hoy (✔ / ⏰ / ⚠). Es lo mínimo que exige el aviso de "no confirmó"; el panel con historial y patrones
queda fuera de la v1. Editor del recordatorio en cuatro pasos: **qué** (texto o grabación, con vista
previa), **a quién** (persona o grupo), **cuándo** (preset de recurrencia + avisos previos) y **cómo**
(nivel de alerta, escalamiento).

Solo en español (es-CO). Respeta la escala de fuente del sistema y TalkBack.

## 10. Seguridad y privacidad

- HTTPS de punta a punta vía Cloudflare Tunnel. El backend escucha solo en `127.0.0.1`.
- Gestor: Authentik OIDC (Authorization Code + PKCE, cliente público). El backend valida el JWT con
  JWKS y vincula `sub` → `person`.
- Receptor: token de dispositivo de 256 bits, guardado con hash en el servidor y en almacenamiento seguro
  (Keystore) en el celular. El QR lleva un **código de un solo uso**, nunca el token.
- Autorización centralizada: toda consulta se filtra por `care_link` o pertenencia al grupo, con tests
  específicos contra acceso a datos ajenos (IDOR).
- BD local cifrada (SQLCipher, llave en Android Keystore), como en hamidani.
- Límite de intentos en la vinculación, registro de auditoría y mínimo de datos. Desvincular borra de verdad.
- Retención: confirmaciones 1 año, voz TTS hasta su descarga, grabaciones mientras exista el recordatorio.
- Respaldo diario de la BD y los audios. La llave de cifrado y el keystore de firma del APK se guardan en
  **Vaultwarden**, nunca junto al respaldo.
- Autoactualización: `GET /v1/app/latest` → versión + sha256. La app verifica el hash y Android verifica
  la firma.

## 11. Despliegue

- Monorepo `~/recuerdame/` con `server/`, `app/` y `docs/`, versionado con git.
- Contenedor `recuerdame` en `127.0.0.1:8791`, con un volumen para la BD y los audios.
- Regla `recuerdame.danihami.xyz` en `/etc/cloudflared/config.yml`, aplicada con el patrón de reversión
  automática de `~/servers/hamidani/` (systemd-run + rollback en 60 s).
- Authentik: proveedor OAuth2 + aplicación "Recuérdame" (cliente público, PKCE, redirect
  `xyz.danihami.recuerdame:/oauth`) y flujo de registro por invitación.
- Cron de respaldo a las 03:45 (después del de hamidani a las 03:30).
- El SDK de Flutter vive en el PC del usuario; en el servidor no se instala. El backend se despliega
  por SSH (`ssh milo@192.168.0.19`).

## 12. Fases

| Fase | Meta | Contenido |
|---|---|---|
| **0. Spikes de riesgo** | Eliminar incertidumbre antes de construir | (a) Alarma en celulares reales Xiaomi/Samsung: pantalla completa, sonar en silencio, tras reinicio y en Doze. (b) Muestras de voces de Piper para que el usuario elija. (c) Login con Authentik desde Android. (d) Paridad de RRULE entre Dart y Python |
| **1. Tú solo** | El usuario es gestor y receptor, con 2 celulares | Servidor (personas, dispositivos, vinculación, recordatorios, sincronización, confirmaciones, TTS, grabación, purgas), app del gestor, receptor en modo simple, alarma + repeticiones + verificación del gestor, salud del celular, avisos previos, autoactualización, despliegue y respaldo |
| **2. Papás** | Uso real con adultos mayores | Guías Xiaomi/Samsung/Motorola, vinculación por QR o código pulida, PIN, ajustes de tamaños y textos tras observar el uso |
| **3. Hogar y más gestores** | Abrir a la familia | UI de grupos/hogar, invitar a otros gestores, modo completo del receptor |
| Futuro (no ahora) | — | Panel de cumplimiento con historial, fotos, push FCM si hace falta, iOS, apertura pública (Play Store, PostgreSQL, términos legales) |

## 13. Riesgos

1. **Android mata la app para ahorrar batería** (Xiaomi sobre todo). Mitigación: spike primero, salud
   del celular visible para el gestor y guías por marca.
2. **Sin push:** los cambios tardan hasta 15 min y un recordatorio de último minuto puede no llegar.
   Mitigación: verificación programada en el celular del gestor, advertencia al guardar y revaluar FCM
   con datos reales.
3. **APK fuera de Play Store:** la primera instalación exige permitir "instalar apps desconocidas" y
   Play Protect puede advertir. La primera instalación se hace en persona.
4. **Pantalla completa en Android 14+** para apps instaladas por APK: verificar en el spike que el
   permiso quede concedido. La salud del celular lo vigila.
5. **Dependencia de Authentik:** si se cae, ningún gestor puede iniciar sesión de nuevo, pero las
   sesiones abiertas siguen y los receptores no se ven afectados.
6. **Servidor único:** si cae, las alarmas siguen sonando (son locales), pero no hay cambios ni
   confirmaciones. Hay respaldo diario.
7. **Disco del servidor** (~12 GB libres): los audios son pequeños, pero hay que vigilarlo.

## 14. Por decidir más adelante (decisiones de negocio)

- Qué voz de Piper usar (tras escuchar las muestras de la fase 0).
- Valores por defecto del escalamiento (¿5 min × 3?) y si "Más tarde" tiene un máximo de veces.
- Quién puede desvincular a un receptor y qué pasa con sus datos.
- Textos exactos de las pantallas del adulto mayor.
- Si se vuelve público: términos, política de privacidad (Ley 1581) y Play Store.

## 15. Forma de trabajo

- Plugins **andrej-karpathy-skills** y **ponytail** activos. Durante el código se usan las skills;
  al usuario solo se le consultan **decisiones de negocio**.
- TDD en lo crítico: autorización, sincronización, recurrencias y purgas.
- Todo cambio en el servidor sigue `~/CLAUDE.md`: `.bak` antes de editar, reversión automática para
  túnel y red, y nunca tocar datos de otros servicios.
