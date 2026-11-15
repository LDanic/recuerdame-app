#!/bin/sh
# Respaldo en caliente de la base y los audios cifrados. Conserva los últimos 30.
# Corre dentro del contenedor (cron 03:45): docker exec recuerdame sh /app/deploy/respaldo.sh
# La llave de cifrado NO va en el respaldo (plan §10): vive en Vaultwarden.
set -eu

DEST="/backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$DEST"
# .backup es seguro con el servidor corriendo: no copia a medio escribir.
sqlite3 /data/recuerdame.db ".backup '$DEST/recuerdame.db'"
cp -a /data/audios "$DEST/"

ls -1dt /backups/2* 2>/dev/null | tail -n +31 | while read -r viejo; do
    rm -rf "$viejo"
done
echo "$(date) respaldo en $DEST"
