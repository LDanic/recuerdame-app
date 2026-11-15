# Recuérdame

App Android (Flutter) de recordatorios por voz con roles gestor/receptor; backend FastAPI + SQLite en este servidor.

- **Plan y decisiones:** `docs/plan.md` — léelo antes de empezar cualquier tarea. Si una tarea contradice el plan, pregunta.
- **Forma de trabajo:** usa las skills (karpathy-guidelines, ponytail). Pregúntame solo decisiones de negocio; las técnicas resuélvelas tú siguiendo el plan.
- **Dónde corre cada cosa:** este proyecto se trabaja desde el PC local (Flutter, Android SDK y los celulares por USB viven aquí). El servidor `milo` es remoto: se opera con `ssh milo@192.168.0.19 '<comando>'` (misma LAN, autenticación por llave). Las rutas `/home/milo/...` del plan y del historial son del servidor.
- **Servidor en producción:** sus reglas y su mapa de servicios están abajo (copia del `~/CLAUDE.md` del servidor). Aplícalas a todo lo que hagas por SSH.

@docs/servidor.md
