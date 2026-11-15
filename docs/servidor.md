# Servidor `milo` — contexto general

**Esto es un servidor en PRODUCCIÓN.** Hay servicios reales en uso. Ten mucho cuidado:
- Antes de reiniciar, recrear, borrar o cambiar configuración: explica qué vas a hacer y confirma conmigo.
- Haz respaldo (`.bak`) de cualquier config antes de editarla.
- No toques datos (bases de datos, volúmenes, `~/hamidani-data`, `~/hamidani-backups`) sin pedirlo explícitamente.
- No muestres tokens/secretos en la conversación salvo que los pida.

## Acceso por SSH — no me dejes fuera
Me conecto **por SSH**. Cualquier cambio de red, firewall, `ssh`, `cloudflared` o reinicio de servicios de sistema
debe ser seguro: usar comandos que se auto-recuperen (p. ej. con reversión automática si algo falla, `nohup`/`systemd-run`),
y nunca algo que corte la sesión sin vuelta atrás. Si existe riesgo de perder acceso, avísame antes.

## Servicios (Docker, definidos en `~/servers/<servicio>/` salvo indicación)
- **llama** (`llama_api`): API LLM sobre Ollama (puerto 8084, network host). Ollama en `localhost:11434`.
- **hamidani**: backend de `~/app_hamidani` (127.0.0.1:8787), público en `hamidani.danihami.xyz`. Docs en `~/app_hamidani/docs/`.
- **firefly** (`firefly_app` 8082, `firefly_importer` 8083, `firefly_db`).
- **outline** (3000) + **authentik** (9000) como SSO, cada uno con su db/redis.
- **vaultwarden** (8080).
- **mcp** (`jaramillo_mcp` 127.0.0.1:8790 + `jaramillo_indexer` semanal): MCP para claude.ai con las transcripciones del canal del Dr. Carlos Jaramillo, público en `mcp.danihami.xyz`. Embeddings con bge-m3 en Ollama. Ver `~/servers/mcp/README.md`.

## Sistema
- **cloudflared** (systemd) expone los servicios; config en `/etc/cloudflared/config.yml`.
- **CUPS**: comparte una impresora Epson L210 por USB a equipos Windows de la LAN (IP fija 192.168.0.19).
- **cron**: respaldo diario de hamidani 03:30; `claude -p "Hola"` diario a las 04:00.
- `~/migracion/`: dumps/volúmenes de una migración anterior. `~/logs/`: logs varios.

El detalle de cada servicio vive en su carpeta y en las sesiones de cada proyecto; esto es solo el mapa general.
