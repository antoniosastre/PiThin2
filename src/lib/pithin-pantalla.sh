#!/usr/bin/env bash
# pithin-pantalla.sh - modo de salida HDMI.
#
# ---------------------------------------------------------------------
#  Qué hace y por qué importa
# ---------------------------------------------------------------------
#
# Fijar la salida HDMI a la misma resolución que la sesión remota evita
# reescalar nada en la Raspberry, y de paso reduce a la mitad el ancho de
# banda de memoria que consume refrescar la pantalla: el controlador de
# vídeo tiene que leer el framebuffer entero sesenta veces por segundo,
# y ese tráfico va por delante del de la CPU. A 1080p son unos 475 MiB/s;
# a 720p, unos 211 MiB/s.
#
# A cambio, el reescalado lo hace el monitor, y ahí la calidad es una
# lotería.
#
# ---------------------------------------------------------------------
#  Cuidado con cmdline.txt
# ---------------------------------------------------------------------
#
# El modo se fija con un parámetro del kernel en cmdline.txt, que es un
# fichero de UNA SOLA LÍNEA. Romperlo deja el equipo sin arrancar, y
# recuperarlo obliga a sacar la tarjeta. Por eso aquí se hace copia de
# seguridad, se valida el contenido antes de escribir y se comprueba
# que el monitor admite el modo que se le va a pedir: pedirle uno que no
# soporte da pantalla en negro, que a efectos prácticos es lo mismo que
# un equipo estropeado.

[[ -n "${PITHIN_PANTALLA_CARGADO:-}" ]] && return 0
PITHIN_PANTALLA_CARGADO=1

# shellcheck source=/dev/null
source "${PITHIN_LIB:-/usr/local/lib/pithin}/pithin-common.sh"

if [[ -d /boot/firmware ]]; then
    PANTALLA_CMDLINE="${PANTALLA_CMDLINE:-/boot/firmware/cmdline.txt}"
else
    PANTALLA_CMDLINE="${PANTALLA_CMDLINE:-/boot/cmdline.txt}"
fi

# Ruta de sysfs con los conectores DRM. Se puede sustituir en pruebas.
PANTALLA_SYSFS="${PANTALLA_SYSFS:-/sys/class/drm}"

# ---------------------------------------------------------------------
#  Consulta del monitor conectado
# ---------------------------------------------------------------------

# Nombre del conector HDMI en uso, p. ej. "HDMI-A-1". Se lee de sysfs y
# no de xrandr a propósito: esto tiene que funcionar antes de que exista
# ningún servidor gráfico, y con el backend SDL no hay ninguno en
# absoluto.
pantalla_conector() {
    local d nombre
    for d in "$PANTALLA_SYSFS"/card*-HDMI-A-*; do
        [[ -r "$d/status" ]] || continue
        [[ "$(cat "$d/status" 2>/dev/null)" == "connected" ]] || continue
        nombre="${d##*/}"          # card0-HDMI-A-1
        printf '%s' "${nombre#*-}" # HDMI-A-1
        return 0
    done
    return 1
}

_pantalla_fichero_modos() {
    local d nombre
    for d in "$PANTALLA_SYSFS"/card*-HDMI-A-*; do
        [[ -r "$d/modes" ]] || continue
        [[ "$(cat "$d/status" 2>/dev/null)" == "connected" ]] || continue
        printf '%s' "$d/modes"
        return 0
    done
    return 1
}

# Resolución preferida del monitor: la primera de la lista de modos.
pantalla_resolucion_nativa() {
    local fichero
    fichero="$(_pantalla_fichero_modos)" || return 1
    local modo
    modo="$(head -n1 "$fichero" 2>/dev/null)"
    [[ "$modo" =~ ^[0-9]+x[0-9]+ ]] || return 1
    printf '%s' "${BASH_REMATCH[0]}"
}

# Todos los modos PROGRESIVOS que anuncia el monitor, uno por línea, sin
# repetir. Solo cuentan las líneas que son exactamente 'AnchoxAlto': DRM
# escribe los modos entrelazados con sufijo 'i' (p. ej. 1920x1080i), y
# forzar el modo progresivo de una resolución que el monitor solo hace
# entrelazada da pantalla en negro. Por eso 'grep -x' (línea completa) y no
# '-oE', que recortaba la 'i' y colaba un modo que el monitor no soporta.
pantalla_modos_disponibles() {
    local fichero
    fichero="$(_pantalla_fichero_modos)" || return 1
    grep -xE '[0-9]+x[0-9]+' "$fichero" 2>/dev/null | awk '!v[$0]++'
}

# ¿Admite el monitor esta resolución? Es la comprobación que evita
# dejar el equipo con la pantalla en negro.
pantalla_admite() {
    local resolucion="$1" modos
    modos="$(pantalla_modos_disponibles)" || return 1
    printf '%s\n' "$modos" | grep -qx "$resolucion"
}

# ---------------------------------------------------------------------
#  Lectura de cmdline.txt
# ---------------------------------------------------------------------

_pantalla_leer_cmdline() {
    [[ -r "$PANTALLA_CMDLINE" ]] || return 1
    # Puede haber varias líneas por un editor descuidado; el kernel solo
    # lee la primera, así que trabajamos con ella.
    head -n1 "$PANTALLA_CMDLINE" | tr -d '\r\n'
}

# Resolución forzada ahora mismo, o cadena vacía si no hay ninguna.
pantalla_modo_forzado() {
    local linea
    linea="$(_pantalla_leer_cmdline)" || return 1
    if [[ "$linea" =~ video=[A-Za-z0-9-]+:([0-9]+x[0-9]+) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    printf ''
    return 0
}

# ---------------------------------------------------------------------
#  Escritura de cmdline.txt
# ---------------------------------------------------------------------

# Escribe una línea nueva solo si supera las comprobaciones de sanidad.
_pantalla_escribir_cmdline() {
    local nueva="$1"

    # Un cmdline sin root= no arranca. Antes de tocar nada, verificamos
    # que lo que vamos a escribir sigue teniendo sentido.
    if [[ -z "$nueva" ]]; then
        log_error "Se iba a escribir un cmdline.txt vacío. Cancelado."
        return 1
    fi
    if [[ "$nueva" != *root=* ]]; then
        log_error "El cmdline.txt resultante no tiene root=. Cancelado."
        return 1
    fi
    if [[ "$nueva" == *$'\n'* ]]; then
        log_error "El cmdline.txt resultante tiene más de una línea. Cancelado."
        return 1
    fi

    if ! boot_escribible; then
        log_error "La partición de arranque es de solo lectura."
        return 1
    fi

    # Copia de seguridad, una sola vez: si ya existe, es del estado
    # original y no la queremos pisar con uno ya modificado.
    if [[ ! -f "${PANTALLA_CMDLINE}.pithin.bak" ]]; then
        cp -a "$PANTALLA_CMDLINE" "${PANTALLA_CMDLINE}.pithin.bak" 2>/dev/null || true
    fi

    local tmp
    tmp="$(mktemp "${PANTALLA_CMDLINE}.XXXXXX")" || return 1
    printf '%s\n' "$nueva" >"$tmp" || { rm -f "$tmp"; return 1; }

    if mv -f "$tmp" "$PANTALLA_CMDLINE"; then
        sync
        return 0
    fi

    rm -f "$tmp"
    log_error "No se pudo escribir en $PANTALLA_CMDLINE."
    return 1
}

# Quita cualquier parámetro video= que hubiéramos puesto.
pantalla_quitar_modo() {
    local linea nueva
    linea="$(_pantalla_leer_cmdline)" || return 1

    # shellcheck disable=SC2001  # el patrón necesita una expresión regular
    nueva="$(printf '%s' "$linea" | sed -E 's/[[:space:]]*video=[A-Za-z0-9-]+:[^[:space:]]*//g')"
    nueva="$(recortar "$nueva")"

    if [[ "$nueva" == "$linea" ]]; then
        log_info "No había ningún modo de vídeo forzado."
        return 0
    fi

    if _pantalla_escribir_cmdline "$nueva"; then
        log_info "Modo de vídeo forzado eliminado: la pantalla volverá a su resolución nativa."
        return 0
    fi
    return 1
}

# Fuerza la salida HDMI a una resolución concreta.
pantalla_fijar_modo() {
    local resolucion="$1"

    if [[ ! "$resolucion" =~ ^[0-9]+x[0-9]+$ ]]; then
        log_error "Resolución no válida: $resolucion"
        return 1
    fi

    local conector
    if ! conector="$(pantalla_conector)"; then
        log_aviso "No se detecta ningún monitor HDMI conectado."
        return 2
    fi

    # La comprobación que evita quedarse sin imagen.
    if ! pantalla_admite "$resolucion"; then
        log_error "El monitor no anuncia el modo $resolucion. No se fuerza para no quedarnos sin imagen."
        return 3
    fi

    local linea nueva
    linea="$(_pantalla_leer_cmdline)" || return 1
    # shellcheck disable=SC2001  # el patrón necesita una expresión regular
    nueva="$(printf '%s' "$linea" | sed -E 's/[[:space:]]*video=[A-Za-z0-9-]+:[^[:space:]]*//g')"
    nueva="$(recortar "$nueva") video=${conector}:${resolucion}@60"

    if _pantalla_escribir_cmdline "$nueva"; then
        log_info "Salida HDMI fijada a ${resolucion} en ${conector}. Hace falta reiniciar."
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------
#  Puesta en marcha desde la configuración
# ---------------------------------------------------------------------

# Qué modo debería estar forzado según SALIDA_HDMI y RESOLUCION.
# Cadena vacía = ninguno.
pantalla_modo_deseado() {
    if [[ "${SALIDA_HDMI:-nativa}" == "sesion" ]]; then
        printf '%s' "${RESOLUCION:-1280x720}"
    else
        printf ''
    fi
}

# ¿Hay que reiniciar para que lo configurado surta efecto?
pantalla_requiere_reinicio() {
    local deseado actual
    deseado="$(pantalla_modo_deseado)"
    actual="$(pantalla_modo_forzado)" || return 1
    [[ "$deseado" != "$actual" ]]
}

# Deja cmdline.txt acorde con la configuración. No reinicia: eso lo
# decide quien llama.
pantalla_sincronizar() {
    local deseado
    deseado="$(pantalla_modo_deseado)"

    if [[ -z "$deseado" ]]; then
        pantalla_quitar_modo
        return $?
    fi

    pantalla_fijar_modo "$deseado"
    return $?
}

# Resolución a la que está saliendo la pantalla ahora mismo: la forzada
# si hay una, y si no la nativa del monitor.
pantalla_resolucion_efectiva() {
    local forzada
    forzada="$(pantalla_modo_forzado 2>/dev/null)" || forzada=""
    if [[ -n "$forzada" ]]; then
        printf '%s' "$forzada"
        return 0
    fi
    pantalla_resolucion_nativa
}
