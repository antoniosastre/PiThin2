#!/usr/bin/env bash
# pithin-tui.sh - envoltorios de whiptail y pantallas comunes.
#
# whiptail dibuja el cuadro de diálogo por la salida estándar y entrega
# el resultado por la de error. Como muchas de estas funciones se llaman
# dentro de $(...), todos los diálogos se dibujan explícitamente sobre
# /dev/tty: si no, el dibujo acabaría dentro de la variable en lugar de
# en la pantalla.

[[ -n "${PITHIN_TUI_CARGADO:-}" ]] && return 0
PITHIN_TUI_CARGADO=1

# shellcheck source=/dev/null
source "${PITHIN_LIB:-/usr/local/lib/pithin}/pithin-common.sh"
# shellcheck source=/dev/null
source "${PITHIN_LIB:-/usr/local/lib/pithin}/pithin-crypto.sh"

TUI_TITULO="PiThin"

# Paleta sobria; el rojo chillón por defecto de newt cansa en una
# pantalla grande.
export NEWT_COLORS='
root=,black
window=,black
border=white,black
title=white,black
textbox=white,black
button=black,white
actbutton=white,blue
entry=white,black
checkbox=white,black
actcheckbox=black,white
listbox=white,black
actlistbox=black,white
sellistbox=black,white
'

tui_disponible() {
    hay_comando whiptail || return 1
    # /dev/tty existe SIEMPRE como nodo; lo que falla sin terminal de control
    # es abrirlo (ENXIO). Comprobar '-e /dev/tty' daba un falso positivo: sin
    # terminal, whiptail moría al instante y todo se interpretaba como
    # "Cancelar", sin llegar nunca al fallback de texto. Por eso se intenta
    # ABRIR /dev/tty de verdad.
    [[ -t 0 ]] || (: </dev/tty) 2>/dev/null
}

# ---------------------------------------------------------------------
#  Diálogos
# ---------------------------------------------------------------------

tui_mensaje() {
    local titulo="$1" texto="$2" alto="${3:-12}" ancho="${4:-72}"
    if tui_disponible; then
        whiptail --title "$TUI_TITULO — $titulo" --msgbox "$texto" "$alto" "$ancho" >/dev/tty 2>&1
    else
        printf '\n== %s ==\n%s\n' "$titulo" "$texto"
        read -r -p "Pulsa Intro para continuar... " _ || true
    fi
}

tui_error() {
    local texto="$1"
    tui_mensaje "Problema" "$texto" 14 72
}

# Devuelve 0 si el usuario acepta.
tui_confirmar() {
    local titulo="$1" texto="$2" alto="${3:-12}" ancho="${4:-72}"
    local si="${5:-Sí}" no="${6:-No}"
    if tui_disponible; then
        whiptail --title "$TUI_TITULO — $titulo" \
                 --yes-button "$si" --no-button "$no" \
                 --yesno "$texto" "$alto" "$ancho" >/dev/tty 2>&1
    else
        local r
        read -r -p "$texto [s/N] " r
        [[ "${r,,}" == s* ]]
    fi
}

# Imprime lo escrito por salida estándar. Devuelve 1 si se cancela.
tui_entrada() {
    local titulo="$1" texto="$2" valor="${3:-}" alto="${4:-12}" ancho="${5:-72}"
    if tui_disponible; then
        # El orden de las dos redirecciones importa y es deliberado:
        # "2>&1" apunta la salida de error al sitio donde se está
        # capturando (que es de donde whiptail entrega el resultado) y
        # "1>/dev/tty" manda el dibujo del cuadro a la pantalla.
        # Invertirlas haría que el dibujo acabara dentro de la variable.
        # shellcheck disable=SC2069
        whiptail --title "$TUI_TITULO — $titulo" \
                 --inputbox "$texto" "$alto" "$ancho" "$valor" \
                 2>&1 1>/dev/tty
    else
        local r
        read -r -p "$texto " r
        printf '%s' "$r"
    fi
}

tui_contrasena() {
    local titulo="$1" texto="$2" alto="${3:-12}" ancho="${4:-72}"
    if tui_disponible; then
        # Ver la nota sobre el orden de las redirecciones en tui_entrada.
        # shellcheck disable=SC2069
        whiptail --title "$TUI_TITULO — $titulo" \
                 --passwordbox "$texto" "$alto" "$ancho" \
                 2>&1 1>/dev/tty
    else
        local r
        read -r -s -p "$texto " r
        printf '\n' >&2
        printf '%s' "$r"
    fi
}

# tui_menu <titulo> <texto> <alto> <ancho> <lineas> <etiqueta1> <desc1> ...
tui_menu() {
    local titulo="$1" texto="$2" alto="$3" ancho="$4" lineas="$5"
    shift 5

    if ! tui_disponible; then
        # Sin whiptail/terminal no hay menú gráfico. Se listan las etiquetas
        # y se lee la elección por texto. Sin esto, los bucles de menú del
        # arranque girarían en vacío tomando cada intento como "Volver".
        printf '\n== %s ==\n%s\n\n' "$titulo" "$texto" >&2
        while (( $# >= 2 )); do
            printf '  %s) %s\n' "$1" "$2" >&2
            shift 2
        done
        local r
        read -r -p "Elige una opción (Intro para volver): " r || return 1
        [[ -n "$r" ]] || return 1
        printf '%s' "$r"
        return 0
    fi

    # Ver la nota sobre el orden de las redirecciones en tui_entrada.
    # shellcheck disable=SC2069
    whiptail --title "$TUI_TITULO — $titulo" \
             --ok-button "Aceptar" --cancel-button "Volver" \
             --menu "$texto" "$alto" "$ancho" "$lineas" "$@" \
             2>&1 1>/dev/tty
}

# Muestra una barra de actividad mientras se ejecuta algo.
#
# Devuelve el código de salida de la orden, no el de whiptail: como la
# orden corre dentro de una tubería, su estado se traspasa por un
# fichero en tmpfs. Sin esto, comprobar si la conexión ha funcionado
# daría siempre "sí".
tui_esperando() {
    local texto="$1"; shift
    local estado_f="/run/pithin/.estado.$$"

    if ! tui_disponible; then
        printf '%s\n' "$texto"
        "$@"
        return $?
    fi

    install -d -m 0700 /run/pithin 2>/dev/null || true
    rm -f "$estado_f"

    {
        ( "$@" >/dev/null 2>&1; printf '%s' "$?" >"$estado_f" ) &
        local pid=$! pct=0
        while kill -0 "$pid" 2>/dev/null; do
            printf '%s\n' "$pct"
            pct=$(( (pct + 7) % 100 ))
            sleep 1
        done
        printf '100\n'
    } | whiptail --title "$TUI_TITULO" --gauge "$texto" 8 70 0 >/dev/tty 2>&1

    local estado=1
    [[ -r "$estado_f" ]] && estado="$(cat "$estado_f" 2>/dev/null)"
    rm -f "$estado_f"
    [[ "$estado" =~ ^[0-9]+$ ]] || estado=1
    return "$estado"
}

# ---------------------------------------------------------------------
#  Obtención de la contraseña de Windows
# ---------------------------------------------------------------------

# Fichero temporal en tmpfs por el que se pasa la contraseña ya
# descifrada desde la consola de texto hasta la sesión de X. Vive en
# RAM, con permisos 0600, y quien lo lee lo borra en el acto.
TUI_TRASPASO="/run/pithin/traspaso"

# Deja la contraseña en el fichero de traspaso. Devuelve 1 si el
# usuario cancela.
tui_preparar_secreto() {
    local secreto
    secreto="$(_tui_obtener_secreto)" || return 1
    [[ -n "$secreto" ]] || return 1

    install -d -m 0700 "$(dirname "$TUI_TRASPASO")" || return 1
    local previo
    previo="$(umask)"
    umask 077
    printf '%s' "$secreto" >"$TUI_TRASPASO" || { umask "$previo"; return 1; }
    umask "$previo"
    chmod 0600 "$TUI_TRASPASO"
    return 0
}

# Lee y destruye el fichero de traspaso.
tui_recoger_secreto() {
    [[ -r "$TUI_TRASPASO" ]] || return 1
    cat "$TUI_TRASPASO"
    rm -f "$TUI_TRASPASO"
    return 0
}

tui_olvidar_secreto() { rm -f "$TUI_TRASPASO" 2>/dev/null || true; }

_tui_obtener_secreto() {
    if cred_existe; then
        _tui_pedir_pin
    else
        _tui_pedir_contrasena_nueva
    fi
}

_tui_pedir_pin() {
    local intento pin secreto espera

    while true; do
        espera="$(cred_espera_por_intentos)"
        if (( espera > 0 )); then
            tui_mensaje "Demasiados intentos" \
"Se han fallado $(cred_intentos_fallidos) intentos seguidos.

Hay que esperar $espera segundos antes de volver a probar." 12 60
            sleep "$espera"
        fi

        pin="$(tui_contrasena "PIN" \
"Introduce el PIN para desbloquear la contraseña de Windows.

Deja el campo vacío y pulsa Aceptar si prefieres escribir la contraseña a mano esta vez." 13 72)" \
            || return 1

        # Campo vacío: escapatoria para cuando no se recuerda el PIN.
        if [[ -z "$pin" ]]; then
            _tui_pedir_contrasena_suelta
            return $?
        fi

        if secreto="$(cred_leer "$pin")"; then
            printf '%s' "$secreto"
            return 0
        fi

        intento="$(cred_intentos_fallidos)"
        tui_error "PIN incorrecto (intento $intento).

Si lo has olvidado, deja el campo vacío en el siguiente aviso para escribir la contraseña de Windows a mano, y luego cámbialo desde Ajustes."
    done
}

_tui_pedir_contrasena_suelta() {
    local secreto
    secreto="$(tui_contrasena "Contraseña de Windows" \
"Escribe la contraseña de tu cuenta de Windows.

No se guardará en el equipo." 12 72)" || return 1
    [[ -n "$secreto" ]] || return 1
    printf '%s' "$secreto"
    return 0
}

_tui_pedir_contrasena_nueva() {
    local secreto
    secreto="$(tui_contrasena "Contraseña de Windows" \
"Escribe la contraseña de tu cuenta de Windows." 11 72)" || return 1
    [[ -n "$secreto" ]] || return 1

    if tui_confirmar "Guardar la contraseña" \
"¿Quieres guardarla en este equipo, cifrada y protegida por un PIN?

Así las próximas veces solo tendrás que teclear el PIN.

La contraseña se cifra con el número de serie de esta Raspberry: una copia de la tarjeta en otro equipo no serviría para descifrarla." 16 72; then
        _tui_establecer_pin "$secreto" || true
    fi

    printf '%s' "$secreto"
    return 0
}

# Pide un PIN dos veces y guarda la credencial.
_tui_establecer_pin() {
    local secreto="$1" pin1 pin2

    while true; do
        pin1="$(tui_contrasena "PIN nuevo" \
"Elige un PIN de al menos $PIN_LONGITUD_MINIMA caracteres.

Puedes usar letras además de números: 'casa42' protege muchísimo más que '1234', y se teclea igual de rápido." 14 72)" || return 1

        if ! cred_pin_valido "$pin1"; then
            tui_error "$(cred_motivo_pin_invalido)"
            continue
        fi

        pin2="$(tui_contrasena "Repite el PIN" "Escríbelo otra vez para confirmar." 10 72)" || return 1

        if [[ "$pin1" != "$pin2" ]]; then
            tui_error "Los dos PIN no coinciden. Prueba otra vez."
            continue
        fi

        break
    done

    if cred_guardar "$pin1" "$secreto"; then
        tui_mensaje "Listo" "La contraseña ha quedado guardada y cifrada.

A partir de ahora solo se te pedirá el PIN." 11 68
        return 0
    fi

    tui_error "No se pudo guardar la credencial. Mira el registro para el detalle."
    return 1
}
