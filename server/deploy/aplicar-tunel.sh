#!/bin/sh
# Agrega recuerdame.danihami.xyz al túnel. Igual que ~/servers/hamidani/apply-tunnel.sh:
# corre desacoplado de la sesión SSH y, si el túnel no vuelve a estar listo en 60 s,
# restaura el config anterior y reinicia cloudflared otra vez.
#   sudo systemd-run --unit=recuerdame-tunel sh /home/milo/servers/recuerdame/aplicar-tunel.sh
set -u
CFG=/etc/cloudflared/config.yml
NEW=/home/milo/servers/recuerdame/config.yml.new
BAK=/etc/cloudflared/config.yml.bak-recuerdame
LOG=/home/milo/servers/recuerdame/aplicar-tunel.log

listo() {
    for i in $(seq 1 30); do
        sleep 2
        systemctl is-active -q cloudflared \
            && [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:20241/ready)" = 200 ] \
            && return 0
    done
    return 1
}

{
    echo "$(date) inicio"
    /usr/bin/cloudflared tunnel --config "$NEW" ingress validate || { echo "config inválido, no se toca nada"; exit 1; }
    cp -p "$CFG" "$BAK"
    install -m 644 "$NEW" "$CFG"
    systemctl restart cloudflared
    if listo; then
        echo "$(date) OK: túnel listo con la regla nueva"
    else
        echo "$(date) FALLO: restaurando config anterior"
        cp -p "$BAK" "$CFG"
        systemctl restart cloudflared
        listo && echo "$(date) restaurado y listo" || echo "$(date) restaurado, pero el túnel NO está listo"
    fi
} >> "$LOG" 2>&1
