#!/usr/bin/env bash
# pithin-config.sh - lectura y validación de pithin.conf.
#
# El fichero de configuración vive en la partición de arranque y lo
# edita una persona desde Windows o macOS. No se hace "source" sobre él:
# se analiza línea a línea. Así un error de sintaxis produce un aviso
# claro en lugar de romper el arranque de forma incomprensible.

[[ -n "${PITHIN_CONFIG_CARGADO:-}" ]] && return 0
PITHIN_CONFIG_CARGADO=1

# shellcheck source=/dev/null
source "${PITHIN_LIB:-/usr/local/lib/pithin}/pithin-common.sh"
# Necesario para avisar de combinaciones que cuestan CPU sin que se note.
# shellcheck source=/dev/null
source "${PITHIN_LIB:-/usr/local/lib/pithin}/pithin-pantalla.sh"

# ---------------------------------------------------------------------
#  Valores por defecto
# ---------------------------------------------------------------------
# Todo ajuste tiene un valor razonable. El fichero solo necesita
# contener lo que se quiera cambiar; si falta o está corrupto, el
# equipo arranca igualmente y se puede arreglar desde el menú.

# Estas variables las consumen los demás módulos, no este fichero: por
# eso shellcheck las ve sin usar.
# shellcheck disable=SC2034
config_defectos() {
    RDP_HOST=""
    RDP_USER=""
    RDP_DOMINIO=""
    RDP_PUERTO="3389"

    # Perfil de sesión. Es una macro que fija los cinco ajustes de
    # abajo; ver pithin-perfiles.sh.
    PERFIL="equilibrado"

    # Backend gráfico: "sdl" prescinde por completo del servidor X
    # (SDL3 sobre KMSDRM), "x11" es la ruta clásica, "auto" prefiere sdl
    # si está disponible y validado.
    BACKEND="sdl"

    # Quién reescala:
    #   nativa  la pantalla va a su resolución y se estira la imagen
    #   sesion  la salida HDMI se fija a la resolución de la sesión
    SALIDA_HDMI="nativa"

    RESOLUCION="1280x720"
    PROFUNDIDAD_COLOR="32"
    CODEC="progressive"
    MODO_CLIENTE_LIGERO="si"
    PERFIL_RED="wan"

    PORTAPAPELES="si"
    SONIDO="no"
    TECLADO="es"
    UNIDADES_USB="no"

    AUTOCONECTAR="si"
    RECONEXION_AUTOMATICA="si"
    RECONEXION_ESPERA="5"
    RECONEXION_MAX_INTENTOS="10"

    ESPERA_WIFI="25"
    ESPERA_TAILSCALE="30"
    GUARDAR_REDES_NUEVAS="si"

    # Segundos que se espera una pulsación antes de conectar sola. Es la
    # única forma de llegar al menú cuando AUTOCONECTAR está activo.
    VENTANA_MENU="3"

    # Duración de la sesión de prueba al estrenar un backend. Ver la
    # explicación en pithin-perfiles.sh.
    PRUEBA_BACKEND_SEGUNDOS="45"

    FREERDP_EXTRA=""
    IGNORAR_CERTIFICADO="si"
}

# Claves que aceptamos. Cualquier otra cosa en el fichero se ignora con
# un aviso: así una errata no se traga en silencio.
PITHIN_CLAVES_VALIDAS=(
    RDP_HOST RDP_USER RDP_DOMINIO RDP_PUERTO
    PERFIL BACKEND SALIDA_HDMI
    RESOLUCION PROFUNDIDAD_COLOR CODEC MODO_CLIENTE_LIGERO PERFIL_RED
    PORTAPAPELES SONIDO TECLADO UNIDADES_USB
    AUTOCONECTAR RECONEXION_AUTOMATICA RECONEXION_ESPERA RECONEXION_MAX_INTENTOS
    ESPERA_WIFI ESPERA_TAILSCALE GUARDAR_REDES_NUEVAS
    VENTANA_MENU PRUEBA_BACKEND_SEGUNDOS
    FREERDP_EXTRA IGNORAR_CERTIFICADO
)

_clave_valida() {
    local clave="$1" v
    for v in "${PITHIN_CLAVES_VALIDAS[@]}"; do
        [[ "$v" == "$clave" ]] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------
#  Carga
# ---------------------------------------------------------------------

config_cargar() {
    local fichero="${1:-$PITHIN_CONF}"

    config_defectos

    if [[ ! -r "$fichero" ]]; then
        log_aviso "No se encuentra $fichero. Se usan los valores por defecto."
        return 1
    fi

    local linea clave valor n=0
    while IFS= read -r linea || [[ -n "$linea" ]]; do
        n=$((n + 1))

        # Quitamos el retorno de carro que deja Windows al editar.
        linea="${linea%$'\r'}"
        linea="$(recortar "$linea")"

        [[ -z "$linea" || "$linea" == \#* ]] && continue

        if [[ ! "$linea" =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            log_aviso "$fichero línea $n: no se entiende, se ignora."
            continue
        fi

        clave="${BASH_REMATCH[1]^^}"
        valor="$(recortar "${BASH_REMATCH[2]}")"

        # Comillas opcionales alrededor del valor.
        if [[ "$valor" == \"*\" && ${#valor} -ge 2 ]]; then
            valor="${valor:1:${#valor}-2}"
        elif [[ "$valor" == \'*\' && ${#valor} -ge 2 ]]; then
            valor="${valor:1:${#valor}-2}"
        fi

        if ! _clave_valida "$clave"; then
            log_aviso "$fichero línea $n: ajuste desconocido '$clave', se ignora."
            continue
        fi

        printf -v "$clave" '%s' "$valor"
    done <"$fichero"

    config_validar
    return 0
}

# ---------------------------------------------------------------------
#  Validación
# ---------------------------------------------------------------------
# Corrige valores imposibles en lugar de abortar. Un fichero mal puesto
# no debe dejar el equipo inservible en un sitio donde no hay teclado
# de rescate.

config_validar() {
    if [[ ! "$RESOLUCION" =~ ^[0-9]{3,5}x[0-9]{3,5}$ ]]; then
        log_aviso "RESOLUCION='$RESOLUCION' no es válida. Se usa 1920x1080."
        RESOLUCION="1920x1080"
    fi

    case "$PROFUNDIDAD_COLOR" in
        15|16|24|32) ;;
        *) log_aviso "PROFUNDIDAD_COLOR='$PROFUNDIDAD_COLOR' no es válida. Se usa 32."
           PROFUNDIDAD_COLOR="32" ;;
    esac

    case "${CODEC,,}" in
        progressive|rfx|avc420|avc444|auto) CODEC="${CODEC,,}" ;;
        *) log_aviso "CODEC='$CODEC' no es válido. Se usa progressive."
           CODEC="progressive" ;;
    esac

    case "${PERFIL_RED,,}" in
        modem|broadband|wan|lan|auto) PERFIL_RED="${PERFIL_RED,,}" ;;
        *) log_aviso "PERFIL_RED='$PERFIL_RED' no es válido. Se usa wan."
           PERFIL_RED="wan" ;;
    esac

    if [[ ! "$RDP_PUERTO" =~ ^[0-9]+$ ]] || (( RDP_PUERTO < 1 || RDP_PUERTO > 65535 )); then
        log_aviso "RDP_PUERTO='$RDP_PUERTO' no es válido. Se usa 3389."
        RDP_PUERTO="3389"
    fi

    case "${BACKEND,,}" in
        sdl|x11|auto) BACKEND="${BACKEND,,}" ;;
        *) log_aviso "BACKEND='$BACKEND' no es válido. Se usa sdl."
           BACKEND="sdl" ;;
    esac

    case "${SALIDA_HDMI,,}" in
        nativa|sesion) SALIDA_HDMI="${SALIDA_HDMI,,}" ;;
        *) log_aviso "SALIDA_HDMI='$SALIDA_HDMI' no es válida. Se usa nativa."
           SALIDA_HDMI="nativa" ;;
    esac

    # Combinación que cuesta CPU sin que se note por qué: X11 no sabe
    # escalar en la GPU, así que estirar la imagen lo hace el procesador
    # justo mientras descodifica vídeo. Se avisa, no se corrige: puede
    # ser lo que el usuario quiere.
    if [[ "$BACKEND" == "x11" && "$SALIDA_HDMI" == "nativa" ]]; then
        local nativa
        if nativa="$(pantalla_resolucion_nativa 2>/dev/null)" \
           && [[ -n "$nativa" && "$nativa" != "$RESOLUCION" ]]; then
            log_aviso "Con X11, estirar de $RESOLUCION a $nativa lo hace la CPU. Considera el backend sdl o SALIDA_HDMI=\"sesion\"."
        fi
    fi

    local numericos=(RECONEXION_ESPERA RECONEXION_MAX_INTENTOS ESPERA_WIFI ESPERA_TAILSCALE
                     VENTANA_MENU PRUEBA_BACKEND_SEGUNDOS)
    local defectos=(5 10 25 30 3 45)
    local i
    for i in "${!numericos[@]}"; do
        local nombre="${numericos[$i]}"
        if [[ ! "${!nombre}" =~ ^[0-9]+$ ]]; then
            log_aviso "$nombre='${!nombre}' no es un número. Se usa ${defectos[$i]}."
            printf -v "$nombre" '%s' "${defectos[$i]}"
        fi
    done

    if [[ ! "$TECLADO" =~ ^[a-z]{2,6}$ ]]; then
        log_aviso "TECLADO='$TECLADO' no es válido. Se usa es."
        TECLADO="es"
    fi
}

# ¿Tenemos lo mínimo para intentar conectar?
config_completa() {
    [[ -n "$RDP_HOST" && -n "$RDP_USER" ]]
}

# ---------------------------------------------------------------------
#  Escritura
# ---------------------------------------------------------------------
# Modifica un ajuste concreto conservando comentarios y orden. Lo usa
# el menú de ajustes para que editar la resolución desde la pantalla no
# destruya el fichero cuidadosamente comentado que hay en la SD.

config_guardar_ajuste() {
    local clave="$1" valor="$2" fichero="${3:-$PITHIN_CONF}"

    if ! _clave_valida "$clave"; then
        log_error "config_guardar_ajuste: clave desconocida '$clave'."
        return 1
    fi

    if ! boot_escribible; then
        log_error "La partición de arranque es de solo lectura: no se puede guardar."
        return 1
    fi

    install -d -m 0755 "$(dirname "$fichero")" 2>/dev/null || true
    [[ -f "$fichero" ]] || : >"$fichero"

    local tmp
    tmp="$(mktemp "${fichero}.XXXXXX")" || return 1

    local encontrada=0 linea limpia
    while IFS= read -r linea || [[ -n "$linea" ]]; do
        limpia="${linea%$'\r'}"
        if [[ "$(recortar "$limpia")" =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*= ]] \
           && [[ "${BASH_REMATCH[1]^^}" == "$clave" ]]; then
            printf '%s="%s"\n' "$clave" "$valor" >>"$tmp"
            encontrada=1
        else
            printf '%s\n' "$limpia" >>"$tmp"
        fi
    done <"$fichero"

    (( encontrada )) || printf '%s="%s"\n' "$clave" "$valor" >>"$tmp"

    # La partición de arranque es FAT32 y no admite chown/chmod de Unix;
    # mv basta y es atómico dentro del mismo sistema de ficheros.
    if mv -f "$tmp" "$fichero"; then
        sync
        log_info "Ajuste guardado: $clave=$valor"
        printf -v "$clave" '%s' "$valor"
        return 0
    fi

    rm -f "$tmp"
    log_error "No se pudo guardar el ajuste $clave."
    return 1
}
