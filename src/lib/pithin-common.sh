#!/usr/bin/env bash
# pithin-common.sh - rutas, registro y utilidades compartidas.
#
# Se carga con "source" desde el resto de módulos y ejecutables.
# No ejecuta nada por sí solo.

# Evita cargarse dos veces si varios módulos lo incluyen.
[[ -n "${PITHIN_COMMON_CARGADO:-}" ]] && return 0
PITHIN_COMMON_CARGADO=1

# ---------------------------------------------------------------------
#  Rutas
# ---------------------------------------------------------------------

# Todas las rutas admiten sustitución desde el entorno. Así se pueden
# ejecutar los módulos desde el árbol de fuentes, o contra un directorio
# de pruebas, sin tener que instalarlos en el sistema.

# La partición de arranque cambió de sitio en Bookworm. Buscamos la que
# exista para funcionar en ambas.
if [[ -z "${PITHIN_BOOT:-}" ]]; then
    if [[ -d /boot/firmware ]]; then
        PITHIN_BOOT="/boot/firmware/pithin"
    else
        PITHIN_BOOT="/boot/pithin"
    fi
fi

PITHIN_ETC="${PITHIN_ETC:-/etc/pithin}"
PITHIN_VAR="${PITHIN_VAR:-/var/lib/pithin}"
PITHIN_LIB="${PITHIN_LIB:-/usr/local/lib/pithin}"
PITHIN_LOG="${PITHIN_LOG:-/var/log/pithin.log}"

PITHIN_CONF="${PITHIN_CONF:-$PITHIN_BOOT/pithin.conf}"
PITHIN_REDES="${PITHIN_REDES:-$PITHIN_BOOT/redes.conf}"
PITHIN_AUTHKEY="${PITHIN_AUTHKEY:-$PITHIN_BOOT/tailscale-authkey.txt}"

export PITHIN_BOOT PITHIN_ETC PITHIN_VAR PITHIN_LIB PITHIN_LOG
export PITHIN_CONF PITHIN_REDES PITHIN_AUTHKEY

# ---------------------------------------------------------------------
#  Registro
# ---------------------------------------------------------------------

# Tamaño máximo del log antes de rotarlo. La SD es el punto débil de
# estos equipos: no dejamos que un bucle de reconexión la llene.
PITHIN_LOG_MAX_BYTES=$((512 * 1024))

_pithin_rotar_log() {
    [[ -f "$PITHIN_LOG" ]] || return 0
    local tam
    tam=$(stat -c %s "$PITHIN_LOG" 2>/dev/null || echo 0)
    if (( tam > PITHIN_LOG_MAX_BYTES )); then
        mv -f "$PITHIN_LOG" "$PITHIN_LOG.1" 2>/dev/null || true
    fi
}

_pithin_log() {
    local nivel="$1"; shift
    local linea prioridad
    linea="$(date '+%Y-%m-%d %H:%M:%S') [$nivel] $*"

    case "$nivel" in
        ERROR) prioridad=err ;;
        AVISO) prioridad=warning ;;
        DEBUG) prioridad=debug ;;
        *)     prioridad=info ;;
    esac

    # A journald, que vive en RAM y no desgasta la tarjeta.
    if command -v systemd-cat >/dev/null 2>&1; then
        printf '%s\n' "$*" | systemd-cat -t pithin -p "$prioridad" 2>/dev/null || true
    fi

    _pithin_rotar_log
    printf '%s\n' "$linea" >>"$PITHIN_LOG" 2>/dev/null || true

    # Los avisos y errores también van a la consola para que se vean
    # durante el arranque.
    case "$nivel" in
        AVISO|ERROR) printf '%s\n' "$linea" >&2 ;;
    esac
}

log_info()  { _pithin_log "INFO"  "$*"; }
log_aviso() { _pithin_log "AVISO" "$*"; }
log_error() { _pithin_log "ERROR" "$*"; }

log_debug() {
    [[ "${PITHIN_DEBUG:-0}" == "1" ]] || return 0
    _pithin_log "DEBUG" "$*"
}

# ---------------------------------------------------------------------
#  Utilidades
# ---------------------------------------------------------------------

# Interpreta los valores afirmativos que puede escribir una persona en
# el fichero de configuración. Todo lo demás se considera "no".
es_si() {
    case "${1,,}" in
        si|sí|s|yes|y|true|1|on|activado) return 0 ;;
        *) return 1 ;;
    esac
}

hay_comando() { command -v "$1" >/dev/null 2>&1; }

requiere_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "Esta operación necesita privilegios de root."
        return 1
    fi
    return 0
}

# Crea los directorios de trabajo con permisos restrictivos. PITHIN_VAR
# guarda la credencial cifrada, así que no debe ser legible por nadie
# más que root.
preparar_directorios() {
    install -d -m 0755 "$PITHIN_ETC" 2>/dev/null || true
    install -d -m 0700 "$PITHIN_VAR" 2>/dev/null || true
    touch "$PITHIN_LOG" 2>/dev/null || true
    chmod 0640 "$PITHIN_LOG" 2>/dev/null || true
}

# Recorta espacios por delante y por detrás.
recortar() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Comprueba si la partición de arranque está montada en modo escritura.
# En Raspberry Pi OS va montada rw, pero conviene verificarlo antes de
# intentar borrar la auth key o guardar una red nueva.
boot_escribible() {
    local punto
    if [[ -d /boot/firmware ]]; then punto=/boot/firmware; else punto=/boot; fi
    findmnt -no OPTIONS "$punto" 2>/dev/null | grep -qw rw
}

# Número de serie del SoC. Se usa para atar la credencial cifrada a
# esta Raspberry en concreto: copiar la tarjeta a otro equipo no basta
# para descifrarla. Ver docs/seguridad.md
serial_dispositivo() {
    local serie=""
    serie=$(awk -F': ' '/^Serial/ {print $2; exit}' /proc/cpuinfo 2>/dev/null)
    if [[ -z "$serie" && -r /sys/firmware/devicetree/base/serial-number ]]; then
        serie=$(tr -d '\0' </sys/firmware/devicetree/base/serial-number)
    fi
    # Si el kernel no lo expone, seguimos funcionando: la credencial
    # queda protegida solo por el PIN. Se avisa por el log.
    if [[ -z "$serie" ]]; then
        log_aviso "No se pudo leer el serial del SoC: la credencial quedará protegida solo por el PIN."
        serie="pithin-sin-serial"
    fi
    printf '%s' "$serie"
}
