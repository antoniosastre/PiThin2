#!/usr/bin/env bash
# pithin-vpn.sh - túnel Tailscale hacia el PC de destino.
#
# Tailscale se autentica una sola vez, en el primer arranque, con una
# auth key que se deja en la partición de arranque. Después el estado
# vive en /var/lib/tailscale y la clave ya no hace falta: se borra.
#
# IMPORTANTE: usa una auth key *con etiqueta* (tag ACL). Los nodos
# etiquetados tienen desactivada la caducidad de clave; sin etiqueta, la
# Raspberry dejaría de conectar a los 180 días sin previo aviso y sin
# forma cómoda de recuperarla estando de viaje. El procedimiento está en
# docs/windows.md

[[ -n "${PITHIN_VPN_CARGADO:-}" ]] && return 0
PITHIN_VPN_CARGADO=1

# shellcheck source=/dev/null
source "${PITHIN_LIB:-/usr/local/lib/pithin}/pithin-common.sh"

# Copia interna de la auth key, por si la partición de arranque está en
# solo lectura y no podemos borrar el original.
VPN_AUTHKEY_INTERNA="$PITHIN_VAR/tailscale-authkey"

# ---------------------------------------------------------------------
#  Estado
# ---------------------------------------------------------------------

vpn_disponible() { hay_comando tailscale; }

# Devuelve el BackendState de Tailscale: Running, NeedsLogin, Stopped,
# NoState... Se extrae del JSON con grep para no depender de jq, que
# sería un paquete más solo para leer un campo.
vpn_estado() {
    local json
    json="$(tailscale status --json 2>/dev/null)" || { printf 'Desconocido'; return 1; }
    local estado
    estado="$(printf '%s' "$json" \
        | grep -o '"BackendState"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -n1 \
        | sed 's/.*:[[:space:]]*"\(.*\)"$/\1/')"
    printf '%s' "${estado:-Desconocido}"
}

vpn_activa() { [[ "$(vpn_estado)" == "Running" ]]; }

vpn_ip_propia() { tailscale ip -4 2>/dev/null | head -n1; }

# ---------------------------------------------------------------------
#  Autenticación y arranque
# ---------------------------------------------------------------------

# Busca la auth key en la SD; si la encuentra, la copia a un sitio
# privado y borra el original de la partición FAT32, que es legible por
# cualquiera que meta la tarjeta en un ordenador.
_vpn_recoger_authkey() {
    if [[ -s "$VPN_AUTHKEY_INTERNA" ]]; then
        cat "$VPN_AUTHKEY_INTERNA"
        return 0
    fi

    [[ -s "$PITHIN_AUTHKEY" ]] || return 1

    local clave
    clave="$(grep -v '^[[:space:]]*#' "$PITHIN_AUTHKEY" 2>/dev/null \
             | tr -d '\r' | grep -m1 '^[[:space:]]*tskey-' | xargs)" || true

    if [[ -z "$clave" ]]; then
        log_aviso "$PITHIN_AUTHKEY existe pero no contiene ninguna clave 'tskey-...'."
        return 1
    fi

    install -d -m 0700 "$PITHIN_VAR" 2>/dev/null || true
    printf '%s\n' "$clave" >"$VPN_AUTHKEY_INTERNA"
    chmod 0600 "$VPN_AUTHKEY_INTERNA"

    printf '%s' "$clave"
    return 0
}

# Borra la auth key de la partición de arranque una vez usada.
_vpn_retirar_authkey() {
    rm -f "$VPN_AUTHKEY_INTERNA" 2>/dev/null || true

    [[ -f "$PITHIN_AUTHKEY" ]] || return 0

    if ! boot_escribible; then
        log_aviso "No se pudo borrar la auth key de la SD: partición de solo lectura."
        return 1
    fi

    # FAT32 no admite shred con garantías, pero sobrescribir antes de
    # borrar es mejor que nada frente a una recuperación trivial.
    : >"$PITHIN_AUTHKEY" 2>/dev/null || true
    rm -f "$PITHIN_AUTHKEY" 2>/dev/null || true
    sync
    log_info "Auth key consumida y eliminada de la tarjeta."
}

# Levanta el túnel. Idempotente: si ya está autenticado no vuelve a
# pedir clave.
vpn_arrancar() {
    if ! vpn_disponible; then
        log_error "Tailscale no está instalado."
        return 1
    fi

    systemctl is-active --quiet tailscaled || {
        log_info "Arrancando el servicio tailscaled..."
        systemctl start tailscaled 2>/dev/null || true
        sleep 2
    }

    local estado; estado="$(vpn_estado)"
    log_info "Estado de Tailscale: $estado"

    if [[ "$estado" == "Running" ]]; then
        _vpn_retirar_authkey
        return 0
    fi

    local nombre; nombre="$(hostname)"
    local -a args=(up --hostname="$nombre" --accept-routes=false)

    local clave
    if clave="$(_vpn_recoger_authkey)" && [[ -n "$clave" ]]; then
        log_info "Autenticando con la auth key de la tarjeta..."
        args+=(--authkey="$clave")
    else
        log_info "Sin auth key nueva; se intenta reutilizar la sesión guardada."
    fi

    local salida
    if salida="$(tailscale "${args[@]}" 2>&1)"; then
        log_info "Túnel Tailscale levantado."
        _vpn_retirar_authkey
        return 0
    fi

    # Nunca volcamos $salida tal cual: 'tailscale up' repite la auth key
    # en sus mensajes de error y acabaría en el fichero de registro.
    log_error "No se pudo levantar Tailscale. Estado: $(vpn_estado)"
    log_debug "Detalle: ${salida//tskey-*/tskey-<oculta>}"
    return 1
}

vpn_esperar() {
    local limite="${1:-30}" transcurrido=0
    while (( transcurrido < limite )); do
        vpn_activa && return 0
        sleep 2
        transcurrido=$((transcurrido + 2))
    done
    log_aviso "Tailscale no llegó a estado Running en ${limite}s."
    return 1
}

vpn_parar() { tailscale down >/dev/null 2>&1; }

vpn_cerrar_sesion() {
    tailscale logout >/dev/null 2>&1
    rm -f "$VPN_AUTHKEY_INTERNA" 2>/dev/null || true
}

# ---------------------------------------------------------------------
#  Destino
# ---------------------------------------------------------------------

# Resuelve un nombre del tailnet a su IP 100.x.y.z. Si ya nos dan una
# IP o el nombre no está en el tailnet, lo devuelve tal cual para que
# el intento de conexión decida.
vpn_ip_de() {
    local host="$1" ip
    [[ -n "$host" ]] || return 1

    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf '%s' "$host"
        return 0
    fi

    ip="$(tailscale ip -4 "$host" 2>/dev/null | head -n1)"
    if [[ -n "$ip" ]]; then
        printf '%s' "$ip"
        return 0
    fi

    printf '%s' "$host"
    return 0
}

# ¿Responde el puerto RDP? Se usa /dev/tcp de bash para no depender de
# netcat, que no viene instalado en la imagen Lite.
vpn_puerto_abierto() {
    local host="$1" puerto="${2:-3389}" espera="${3:-5}"
    timeout "$espera" bash -c "exec 3<>/dev/tcp/$host/$puerto" 2>/dev/null
}

# Lista los equipos visibles en el tailnet: nombre<TAB>IP<TAB>estado
vpn_listar_equipos() {
    tailscale status 2>/dev/null | awk '
        NF >= 2 && $1 ~ /^100\./ {
            estado = ($NF == "offline") ? "desconectado" : "conectado"
            print $2 "\t" $1 "\t" estado
        }'
}
