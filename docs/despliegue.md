# Despliegue en `milo`

Todo se hace desde el PC (repo en `C:\Users\hamil\recuerdame`).

| Qué | Dónde (servidor) |
|---|---|
| Código del servidor (solo lectura en el contenedor) | `~/recuerdame/server` |
| Compose, `.env` (`RECUERDAME_GESTORES=milo,dani`), voz, llave | `~/servers/recuerdame/` |
| Llave AES-256 de los audios (copia en Vaultwarden) | `~/servers/recuerdame/secretos/llave` |
| Base, audios cifrados, APK publicado | `~/recuerdame-data/` |
| Respaldos (30, cron 03:45) | `~/recuerdame-backups/` |
| Contenedor | `recuerdame`, `127.0.0.1:8791`, público en `recuerdame.danihami.xyz` |

## Actualizar el servidor

```powershell
git archive --format=tar -o $env:TEMP\server.tar HEAD server
scp $env:TEMP\server.tar milo@192.168.0.19:/tmp/recuerdame-server.tar
ssh milo@192.168.0.19 'rm -rf ~/recuerdame/server && tar -xf /tmp/recuerdame-server.tar -C ~/recuerdame && rm /tmp/recuerdame-server.tar && cd ~/servers/recuerdame && docker compose up -d --build'
```

(No usar `git archive | ssh`: PowerShell 5.1 corrompe el binario en la tubería.)

## Publicar una versión de la app

1. Subir `version: X.Y.Z+N` en `app/pubspec.yaml` (N = `version_code`, siempre mayor).
2. `flutter build apk --release --target-platform android-arm64` (firma con
   `app/android/key.properties`, fuera de git; keystore en `~\.recuerdame\`, copia en Vaultwarden).
3. Subir `app-release.apk` como `~/recuerdame-data/app/recuerdame.apk` y escribir
   `latest.json` con `version_code`, `version_name` y el `sha256` del APK.

Los celulares lo ven en Ajustes → Buscar actualización.

## Túnel

Regla aplicada con `~/servers/recuerdame/aplicar-tunel.sh` (reversión automática en 60 s,
log en `aplicar-tunel.log`, respaldo en `/etc/cloudflared/config.yml.bak-recuerdame`):
`sudo systemd-run --unit=recuerdame-tunel sh /home/milo/servers/recuerdame/aplicar-tunel.sh`.
Para deshacer: restaurar ese `.bak`, reiniciar cloudflared y borrar el CNAME en Cloudflare.
