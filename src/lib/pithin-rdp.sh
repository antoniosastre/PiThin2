#!/usr/bin/env bash
# pithin-rdp.sh - construcción y lanzamiento de la sesión FreeRDP.
#
# La contraseña nunca viaja en la línea de órdenes: /proc/PID/cmdline es
# legible por cualquier proceso del sistema. FreeRDP 3 admite
# /args-from:<fichero> ("Read command line from a file, stdin or file
# descriptor... one argument per line"), así que los argumentos se
# escriben en un fichero 0600 dentro de /run, que es tmpfs y por tanto
# nunca toca la tarjeta SD.

[[ -n "${PITHIN_RDP_CARGADO:-}" ]] && return 0
PITHIN_RDP_CARGADO=1

# shellcheck source=/dev/null
source "${PITHIN_LIB:-/usr/local/lib/pithin}/pithin-common.sh"

RDP_DIR_EJECUCION="/run/pithin"
RDP_LOG_SESION="$RDP_DIR_EJECUCION/sesion.log"

# Última causa de desconexión, en texto legible. La rellena rdp_conectar
# y la leen el menú y pithin-sesion para explicar qué ha pasado.
# shellcheck disable=SC2034
RDP_ULTIMO_MOTIVO=""

# ---------------------------------------------------------------------
#  Binario
# ---------------------------------------------------------------------

rdp_binario() {
    if hay_comando xfreerdp3; then printf 'xfreerdp3'
    elif hay_comando xfreerdp; then printf 'xfreerdp'
    else return 1
    fi
}

rdp_disponible() { rdp_binario >/dev/null 2>&1; }

# ---------------------------------------------------------------------
#  Teclado
# ---------------------------------------------------------------------
# FreeRDP acepta el identificador hexadecimal de distribución de
# Windows. Se admite también un valor 0x... puesto a mano en el fichero
# de configuración.

rdp_id_teclado() {
    local codigo="${1:-es}"
    case "${codigo,,}" in
        es|es_es|spanish)     printf '0x0000040A' ;;
        latam|es_mx|latin)    printf '0x0000080A' ;;
        us|en_us|english)     printf '0x00000409' ;;
        uk|gb|en_gb)          printf '0x00000809' ;;
        fr|fr_fr)             printf '0x0000040C' ;;
        de|de_de)             printf '0x00000407' ;;
        pt|pt_pt)             printf '0x00000816' ;;
        it|it_it)             printf '0x00000410' ;;
        0x*)                  printf '%s' "$codigo" ;;
        *)                    printf '0x0000040A' ;;
    esac
}

# ---------------------------------------------------------------------
#  Resolución de la pantalla física
# ---------------------------------------------------------------------

# Tamaño real del monitor conectado, si X está corriendo y xrandr está
# disponible. Se usa para decidir si hay que escalar.
rdp_resolucion_pantalla() {
    hay_comando xrandr || return 1
    [[ -n "${DISPLAY:-}" ]] || return 1
    xrandr 2>/dev/null | awk '/\*/ {print $1; exit}'
}

# ---------------------------------------------------------------------
#  Construcción de argumentos
# ---------------------------------------------------------------------

# Rellena el array global RDP_ARGS. Espera que la configuración esté ya
# cargada (config_cargar) y recibe la contraseña como único argumento.
rdp_construir_argumentos() {
    local secreto="$1"
    local destino

    destino="$(vpn_ip_de "$RDP_HOST")"

    RDP_ARGS=(
        "/v:${destino}:${RDP_PUERTO}"
        "/u:${RDP_USER}"
    )

    [[ -n "$RDP_DOMINIO" ]] && RDP_ARGS+=("/d:${RDP_DOMINIO}")
    [[ -n "$secreto" ]]     && RDP_ARGS+=("/p:${secreto}")

    # --- Pantalla -----------------------------------------------------
    RDP_ARGS+=("/size:${RESOLUCION}" "/bpp:${PROFUNDIDAD_COLOR}" "/f")

    # Si se ha pedido una resolución distinta a la del monitor, se
    # escala la imagen para que siga llenando la pantalla. Es el truco
    # que hace utilizable el perfil de 720p en un monitor 1080p: se
    # transmiten menos de la mitad de píxeles y aun así no hay bordes
    # negros.
    local fisica
    if fisica="$(rdp_resolucion_pantalla)" && [[ -n "$fisica" && "$fisica" != "$RESOLUCION" ]]; then
        RDP_ARGS+=("/smart-sizing:${fisica}")
        log_info "Sesión a $RESOLUCION escalada a la pantalla de $fisica."
    fi

    # --- Códec --------------------------------------------------------
    # thin-client y small-cache recortan el uso de memoria, que es el
    # recurso escaso en una Zero 2 W.
    local ligero=""
    es_si "$MODO_CLIENTE_LIGERO" && ligero=",thin-client:on,small-cache:on"

    case "$CODEC" in
        progressive) RDP_ARGS+=("/gfx:progressive${ligero}") ;;
        rfx)         RDP_ARGS+=("/gfx:rfx${ligero}") ;;
        avc420)      RDP_ARGS+=("/gfx:avc420${ligero}") ;;
        avc444)      RDP_ARGS+=("/gfx:avc444${ligero}") ;;
        auto|*)      RDP_ARGS+=("/gfx${ligero:+:${ligero#,}}") ;;
    esac

    # --- Red ----------------------------------------------------------
    RDP_ARGS+=("/network:${PERFIL_RED}")

    # --- Periféricos --------------------------------------------------
    RDP_ARGS+=("/kbd:layout:$(rdp_id_teclado "$TECLADO")")

    if es_si "$PORTAPAPELES"; then RDP_ARGS+=("+clipboard"); else RDP_ARGS+=("-clipboard"); fi

    if es_si "$SONIDO"; then
        RDP_ARGS+=("/sound")
    else
        RDP_ARGS+=("/audio-mode:2")
    fi

    es_si "$UNIDADES_USB" && RDP_ARGS+=("/drive:usb,/media")

    # --- Certificado --------------------------------------------------
    # El canal ya va cifrado extremo a extremo por WireGuard dentro de
    # Tailscale, así que validar además el certificado autofirmado de
    # Windows aporta poco y obliga a aceptarlo en cada arranque.
    if es_si "$IGNORAR_CERTIFICADO"; then
        RDP_ARGS+=("/cert:ignore")
    else
        RDP_ARGS+=("/cert:tofu")
    fi

    # --- Reconexión ---------------------------------------------------
    if es_si "$RECONEXION_AUTOMATICA"; then
        RDP_ARGS+=("+auto-reconnect" "/auto-reconnect-max-retries:3")
    fi

    RDP_ARGS+=("/log-level:INFO")

    # --- Extras del usuario -------------------------------------------
    if [[ -n "$FREERDP_EXTRA" ]]; then
        # Palabra a palabra: son opciones de FreeRDP, no rutas con
        # espacios.
        local extra
        # shellcheck disable=SC2206
        extra=( $FREERDP_EXTRA )
        RDP_ARGS+=("${extra[@]}")
    fi
}

# Copia de los argumentos apta para el registro, sin la contraseña.
rdp_argumentos_censurados() {
    local a
    for a in "${RDP_ARGS[@]}"; do
        case "$a" in
            /p:*) printf '/p:<oculta> ' ;;
            *)    printf '%s ' "$a" ;;
        esac
    done
}

# ---------------------------------------------------------------------
#  Lanzamiento
# ---------------------------------------------------------------------

# Traduce la salida de FreeRDP a algo que se pueda enseñar en pantalla.
_rdp_interpretar_salida() {
    local codigo="$1" log="$2"
    local texto=""
    [[ -r "$log" ]] && texto="$(tail -n 200 "$log" 2>/dev/null)"

    if (( codigo == 0 )); then
        RDP_ULTIMO_MOTIVO="La sesión se cerró con normalidad."
        return 0
    fi

    case "$texto" in
        *ERRCONNECT_LOGON_FAILURE*|*LOGON_FAILURE*)
            RDP_ULTIMO_MOTIVO="Usuario o contraseña incorrectos. Revisa RDP_USER en pithin.conf; si usas cuenta Microsoft debe ir como MicrosoftAccount\\\\tu@correo.com" ;;
        *ERRCONNECT_ACCOUNT_LOCKED_OUT*)
            RDP_ULTIMO_MOTIVO="La cuenta de Windows está bloqueada por intentos fallidos." ;;
        *ERRCONNECT_ACCOUNT_DISABLED*)
            RDP_ULTIMO_MOTIVO="La cuenta de Windows está deshabilitada." ;;
        *PASSWORD_EXPIRED*|*PASSWORD_MUST_CHANGE*)
            RDP_ULTIMO_MOTIVO="La contraseña de Windows ha caducado. Hay que cambiarla desde el propio PC." ;;
        *ERRCONNECT_CONNECT_TRANSPORT_FAILED*|*ERRCONNECT_CONNECT_CANCELLED*|*"unable to connect"*|*"failed to connect"*)
            RDP_ULTIMO_MOTIVO="No se pudo alcanzar el PC. Comprueba que está encendido, que Tailscale corre en él y que el firewall de Windows permite el puerto 3389." ;;
        *ERRINFO_LOGOFF_BY_USER*)
            RDP_ULTIMO_MOTIVO="Cerraste sesión en Windows."
            return 0 ;;
        *ERRINFO_DISCONNECTED_BY_OTHER_CONNECTION*)
            RDP_ULTIMO_MOTIVO="Otra persona ha tomado la sesión de ese PC." ;;
        *ERRCONNECT_SECURITY_NEGO_CONNECT_FAILED*|*"NLA"*)
            RDP_ULTIMO_MOTIVO="Falló la negociación de seguridad. Revisa que el Escritorio Remoto esté activado en Windows." ;;
        *"Failed to parse"*|*"invalid argument"*|*"unknown option"*)
            RDP_ULTIMO_MOTIVO="FreeRDP rechazó algún argumento. Prueba a poner CODEC=\"auto\" y a vaciar FREERDP_EXTRA en pithin.conf." ;;
        *)
            RDP_ULTIMO_MOTIVO="La sesión terminó con un error (código $codigo). Mira el registro para el detalle." ;;
    esac
    return 1
}

# ¿Falló por culpa de la sintaxis de los argumentos? Lo usamos para
# reintentar una vez con una configuración de códec conservadora.
_rdp_error_de_argumentos() {
    local log="$1"
    [[ -r "$log" ]] || return 1
    grep -qiE 'failed to parse|invalid argument|unknown option|unable to parse' "$log"
}

# rdp_conectar <contraseña>
# Devuelve el código de salida de FreeRDP. Deja el motivo legible en
# RDP_ULTIMO_MOTIVO.
rdp_conectar() {
    local secreto="$1"
    local binario

    binario="$(rdp_binario)" || {
        RDP_ULTIMO_MOTIVO="FreeRDP no está instalado."
        return 127
    }

    install -d -m 0700 "$RDP_DIR_EJECUCION" || return 1

    rdp_construir_argumentos "$secreto"
    log_info "Lanzando $binario $(rdp_argumentos_censurados)"

    local fichero_args
    fichero_args="$(mktemp "$RDP_DIR_EJECUCION/args.XXXXXX")" || return 1
    chmod 0600 "$fichero_args"
    # shellcheck disable=SC2064
    trap "rm -f '$fichero_args'" RETURN

    printf '%s\n' "${RDP_ARGS[@]}" >"$fichero_args"

    local codigo=0
    "$binario" "/args-from:$fichero_args" >"$RDP_LOG_SESION" 2>&1 || codigo=$?

    # Si FreeRDP se ha quejado de los argumentos, casi siempre es por la
    # forma exacta de /gfx, que varía entre versiones. Se reintenta una
    # vez con lo mínimo imprescindible antes de dar el error por bueno.
    if (( codigo != 0 )) && _rdp_error_de_argumentos "$RDP_LOG_SESION"; then
        log_aviso "FreeRDP rechazó los argumentos; reintentando con la configuración mínima."

        RDP_ARGS=(
            "/v:$(vpn_ip_de "$RDP_HOST"):${RDP_PUERTO}"
            "/u:${RDP_USER}"
            "/size:${RESOLUCION}"
            "/f"
            "/cert:ignore"
        )
        [[ -n "$RDP_DOMINIO" ]] && RDP_ARGS+=("/d:${RDP_DOMINIO}")
        [[ -n "$secreto" ]]     && RDP_ARGS+=("/p:${secreto}")

        printf '%s\n' "${RDP_ARGS[@]}" >"$fichero_args"

        codigo=0
        "$binario" "/args-from:$fichero_args" >"$RDP_LOG_SESION" 2>&1 || codigo=$?
    fi

    _rdp_interpretar_salida "$codigo" "$RDP_LOG_SESION" || true
    log_info "Sesión terminada (código $codigo): $RDP_ULTIMO_MOTIVO"

    return "$codigo"
}

# ¿Merece la pena reintentar solo, o hace falta que intervenga alguien?
# Un fallo de credenciales o de argumentos no se arregla reintentando.
rdp_fallo_recuperable() {
    case "$RDP_ULTIMO_MOTIVO" in
        *"contraseña incorrectos"*|*bloqueada*|*deshabilitada*|*caducado*|*rechazó*)
            return 1 ;;
        *)  return 0 ;;
    esac
}
