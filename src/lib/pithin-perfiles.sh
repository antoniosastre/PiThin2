#!/usr/bin/env bash
# pithin-perfiles.sh - combinaciones probadas de ajustes de sesión.
#
# ---------------------------------------------------------------------
#  Por qué perfiles y no veinte mandos sueltos
# ---------------------------------------------------------------------
#
# Los ejes que afectan al rendimiento son cinco: backend gráfico,
# resolución de sesión, modo de salida HDMI, códec y profundidad de
# color. Expuestos por separado dan casi doscientas combinaciones, y
# ninguna persona sensata las va a probar. Muchas estarían rotas y el
# usuario las descubriría en el peor momento posible.
#
# Así que la puerta de entrada son cuatro combinaciones que sí se
# prueban y se documentan. Los ajustes sueltos siguen accesibles desde
# "Avanzado" para quien los necesite; al tocar uno, el perfil pasa a
# llamarse "personalizado" y se deja de prometer nada sobre él.

[[ -n "${PITHIN_PERFILES_CARGADO:-}" ]] && return 0
PITHIN_PERFILES_CARGADO=1

# shellcheck source=/dev/null
source "${PITHIN_LIB:-/usr/local/lib/pithin}/pithin-common.sh"
# shellcheck source=/dev/null
source "${PITHIN_LIB:-/usr/local/lib/pithin}/pithin-config.sh"

PERFIL_BUENO="$PITHIN_VAR/perfil-bueno"
PERFIL_VALIDADOS="$PITHIN_VAR/backends-validados"

# Orden en que se ofrecen en el menú.
PERFILES_DISPONIBLES=(equilibrado nitidez fluidez compatibilidad)

# ---------------------------------------------------------------------
#  Definiciones
# ---------------------------------------------------------------------
#
#  Formato:  backend|resolución|salida|códec|color
#
#  El campo "salida" decide quién reescala, que es donde estaba el error
#  de la primera versión:
#
#    nativa  La pantalla va a su resolución nativa y la imagen remota se
#            estira para llenarla. Con el backend SDL ese estirado lo
#            hace la GPU y sale gratis. Con X11 lo haría la CPU, que es
#            justo lo que no sobra aquí.
#
#    sesion  La salida HDMI se fija a la misma resolución que la sesión,
#            así que no hay que escalar nada: se encarga el escalador
#            del monitor. Ahorra además ancho de banda de memoria,
#            porque el framebuffer que hay que leer 60 veces por segundo
#            es la mitad de grande.

perfil_definicion() {
    case "$1" in
        equilibrado)    printf 'sdl|1280x720|nativa|progressive|32' ;;
        nitidez)        printf 'sdl|1920x1080|nativa|progressive|32' ;;
        fluidez)        printf 'sdl|1280x720|sesion|progressive|16' ;;
        compatibilidad) printf 'x11|1920x1080|nativa|progressive|32' ;;
        *) return 1 ;;
    esac
}

perfil_titulo() {
    case "$1" in
        equilibrado)    printf 'Equilibrado' ;;
        nitidez)        printf 'Máxima nitidez' ;;
        fluidez)        printf 'Máxima fluidez' ;;
        compatibilidad) printf 'Compatibilidad' ;;
        personalizado)  printf 'Personalizado' ;;
        *)              printf '%s' "$1" ;;
    esac
}

perfil_resumen() {
    case "$1" in
        equilibrado)    printf '720p escalado por GPU · buen punto medio' ;;
        nitidez)        printf '1080p nativo · sin escalar nada' ;;
        fluidez)        printf '720p de punta a punta · para WiFi flojo' ;;
        compatibilidad) printf 'X11 como en la primera versión · si algo falla' ;;
        personalizado)  printf 'Ajustes tocados a mano' ;;
        *)              printf '' ;;
    esac
}

# Explicación larga, para la pantalla de detalle.
perfil_detalle() {
    case "$1" in
        equilibrado)
            printf '%s' \
"La sesión va a 1280x720 y la pantalla sigue a 1080p: se transmite y se
descodifica menos de la mitad de píxeles, y la GPU estira la imagen sin
coste de CPU.

Es el mejor punto de partida para trabajo de escritorio." ;;
        nitidez)
            printf '%s' \
"La sesión va a la misma resolución que la pantalla, así que no se
escala nada y el texto sale perfectamente nítido.

A cambio hay que descodificar el doble de píxeles. Úsalo si tienes buen
WiFi y te molesta cualquier suavizado." ;;
        fluidez)
            printf '%s' \
"Todo a 720p, incluida la salida HDMI, y color de 16 bits.

Es lo más ligero posible: menos píxeles que transmitir, menos que
descodificar y la mitad de ancho de banda de memoria gastado en refrescar
la pantalla.

El reescalado lo hace tu monitor, así que el resultado depende de lo
bueno que sea el suyo. En algunos televisores además añade retardo." ;;
        compatibilidad)
            printf '%s' \
"Usa X11 en lugar de SDL/KMSDRM, que es como funcionaba la primera
versión de PiThin.

Es el perfil al que recurrir si el teclado o la pantalla no responden
con los otros. Más lento, pero es terreno conocido." ;;
        *) printf 'Ajustes configurados a mano desde Avanzado.' ;;
    esac
}

_perfil_campo() {
    local nombre="$1" indice="$2" definicion
    definicion="$(perfil_definicion "$nombre")" || return 1
    printf '%s' "$definicion" | cut -d'|' -f"$indice"
}

perfil_backend()    { _perfil_campo "$1" 1; }
perfil_resolucion() { _perfil_campo "$1" 2; }
perfil_salida()     { _perfil_campo "$1" 3; }
perfil_codec()      { _perfil_campo "$1" 4; }
perfil_color()      { _perfil_campo "$1" 5; }

# ---------------------------------------------------------------------
#  Aplicar
# ---------------------------------------------------------------------

# Un perfil es una macro: escribe los cinco ajustes individuales en
# pithin.conf. Así el fichero sigue siendo autoexplicativo aunque se
# lea desde otro ordenador sin saber nada de perfiles.
perfil_aplicar() {
    local nombre="$1"

    if ! perfil_definicion "$nombre" >/dev/null; then
        log_error "Perfil desconocido: $nombre"
        return 1
    fi

    local fallos=0
    config_guardar_ajuste BACKEND            "$(perfil_backend "$nombre")"    || fallos=1
    config_guardar_ajuste RESOLUCION         "$(perfil_resolucion "$nombre")" || fallos=1
    config_guardar_ajuste SALIDA_HDMI        "$(perfil_salida "$nombre")"     || fallos=1
    config_guardar_ajuste CODEC              "$(perfil_codec "$nombre")"      || fallos=1
    config_guardar_ajuste PROFUNDIDAD_COLOR  "$(perfil_color "$nombre")"      || fallos=1
    config_guardar_ajuste PERFIL             "$nombre"                        || fallos=1

    config_validar

    if (( fallos )); then
        log_aviso "El perfil '$nombre' se aplicó solo en parte: no se pudo escribir en la tarjeta."
        return 1
    fi

    log_info "Perfil aplicado: $nombre"
    return 0
}

# ¿Los ajustes actuales coinciden con algún perfil conocido? Devuelve su
# nombre, o "personalizado".
perfil_detectar() {
    local actual nombre
    # Las variables de configuración las define config_cargar, en otro
    # módulo; shellcheck no puede verlo.
    # shellcheck disable=SC2153
    actual="${BACKEND}|${RESOLUCION}|${SALIDA_HDMI}|${CODEC}|${PROFUNDIDAD_COLOR}"
    for nombre in "${PERFILES_DISPONIBLES[@]}"; do
        if [[ "$(perfil_definicion "$nombre")" == "$actual" ]]; then
            printf '%s' "$nombre"
            return 0
        fi
    done
    printf 'personalizado'
    return 0
}

# Mantiene PERFIL sincronizado con los ajustes reales. Se llama tras
# tocar cualquier ajuste suelto desde Avanzado.
perfil_resincronizar() {
    local detectado
    detectado="$(perfil_detectar)"
    if [[ "$detectado" != "${PERFIL:-}" ]]; then
        config_guardar_ajuste PERFIL "$detectado" >/dev/null 2>&1 || true
    fi
}

# ---------------------------------------------------------------------
#  Perfil bueno conocido
# ---------------------------------------------------------------------
#
# El perfil vive en la tarjeta. Sin una copia de seguridad de la última
# combinación que funcionó, un ajuste desafortunado obligaría a apagar,
# sacar la tarjeta y buscar un ordenador donde editarla. Que es
# exactamente lo que no se puede hacer estando de viaje.

perfil_marcar_bueno() {
    install -d -m 0700 "$PITHIN_VAR" 2>/dev/null || true
    {
        printf 'BACKEND=%s\n'           "$BACKEND"
        printf 'RESOLUCION=%s\n'        "$RESOLUCION"
        printf 'SALIDA_HDMI=%s\n'       "$SALIDA_HDMI"
        printf 'CODEC=%s\n'             "$CODEC"
        printf 'PROFUNDIDAD_COLOR=%s\n' "$PROFUNDIDAD_COLOR"
        printf 'PERFIL=%s\n'            "${PERFIL:-personalizado}"
    } >"$PERFIL_BUENO" 2>/dev/null || return 1
    chmod 0600 "$PERFIL_BUENO" 2>/dev/null || true
    log_info "Guardada la configuración como buena conocida."
    return 0
}

perfil_hay_bueno() { [[ -s "$PERFIL_BUENO" ]]; }

# ¿Los ajustes de ahora son distintos de los que sabemos que funcionan?
perfil_sin_validar() {
    perfil_hay_bueno || return 0
    local clave valor
    while IFS='=' read -r clave valor; do
        case "$clave" in
            BACKEND)           [[ "$valor" == "$BACKEND" ]]           || return 0 ;;
            RESOLUCION)        [[ "$valor" == "$RESOLUCION" ]]        || return 0 ;;
            SALIDA_HDMI)       [[ "$valor" == "$SALIDA_HDMI" ]]       || return 0 ;;
            CODEC)             [[ "$valor" == "$CODEC" ]]             || return 0 ;;
            PROFUNDIDAD_COLOR) [[ "$valor" == "$PROFUNDIDAD_COLOR" ]] || return 0 ;;
        esac
    done <"$PERFIL_BUENO"
    return 1
}

perfil_bueno_descripcion() {
    perfil_hay_bueno || { printf 'ninguna'; return 1; }
    local clave valor perfil="" backend="" resolucion=""
    while IFS='=' read -r clave valor; do
        case "$clave" in
            PERFIL)     perfil="$valor" ;;
            BACKEND)    backend="$valor" ;;
            RESOLUCION) resolucion="$valor" ;;
        esac
    done <"$PERFIL_BUENO"
    printf '%s (%s, %s)' "$(perfil_titulo "$perfil")" "$backend" "$resolucion"
}

perfil_restaurar_bueno() {
    perfil_hay_bueno || { log_error "No hay ninguna configuración buena guardada."; return 1; }

    local clave valor fallos=0
    while IFS='=' read -r clave valor; do
        case "$clave" in
            BACKEND|RESOLUCION|SALIDA_HDMI|CODEC|PROFUNDIDAD_COLOR|PERFIL)
                config_guardar_ajuste "$clave" "$valor" >/dev/null 2>&1 || fallos=1
                ;;
        esac
    done <"$PERFIL_BUENO"

    config_validar

    # No tragarse el fallo: si la tarjeta está de solo lectura,
    # config_guardar_ajuste no toca ni disco ni memoria, así que no se ha
    # restaurado nada. Quien llama debe saberlo para no prometer lo contrario.
    if (( fallos )); then
        log_error "No se pudo escribir la configuración restaurada en la tarjeta."
        return 1
    fi

    log_info "Restaurada la última configuración que funcionaba."
    return 0
}

# ---------------------------------------------------------------------
#  Validación de backends
# ---------------------------------------------------------------------
#
# El fallo característico de SDL sobre KMSDRM es que la imagen aparece
# pero el teclado no responde. Y sin teclado dentro de la sesión tampoco
# se puede salir de ella: no hay escapatoria desde dentro.
#
# Por eso la primera sesión con un backend nuevo se lanza con límite de
# tiempo. Al vencer, se vuelve a la consola de texto y se pregunta si el
# teclado respondía. Si no, se revierte. Ver rdp_conectar y
# menu_probar_backend.

backend_validado() {
    local backend="$1"
    [[ -r "$PERFIL_VALIDADOS" ]] || return 1
    grep -qx "$backend" "$PERFIL_VALIDADOS" 2>/dev/null
}

backend_marcar_validado() {
    local backend="$1"
    backend_validado "$backend" && return 0
    install -d -m 0700 "$PITHIN_VAR" 2>/dev/null || true
    printf '%s\n' "$backend" >>"$PERFIL_VALIDADOS" 2>/dev/null || return 1
    chmod 0600 "$PERFIL_VALIDADOS" 2>/dev/null || true
    log_info "Backend '$backend' validado: el teclado responde."
    return 0
}

backend_invalidar() {
    local backend="$1"
    [[ -r "$PERFIL_VALIDADOS" ]] || return 0
    local tmp
    tmp="$(mktemp "$PERFIL_VALIDADOS.XXXXXX")" || return 1
    grep -vx "$backend" "$PERFIL_VALIDADOS" >"$tmp" 2>/dev/null || true
    mv -f "$tmp" "$PERFIL_VALIDADOS"
    chmod 0600 "$PERFIL_VALIDADOS" 2>/dev/null || true
    log_aviso "Backend '$backend' marcado como no funcional."
}
