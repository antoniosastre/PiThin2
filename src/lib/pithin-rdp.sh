#!/usr/bin/env bash
# pithin-rdp.sh - construcción y lanzamiento de la sesión FreeRDP.
#
# ---------------------------------------------------------------------
#  Dos backends
# ---------------------------------------------------------------------
#
#   sdl   sdl-freerdp3 sobre SDL3/KMSDRM. No hay servidor X en absoluto:
#         el cliente habla directamente con el controlador de pantalla
#         del kernel. Ahorra los 40-60 MB del servidor X y una pieza
#         móvil entera. Además el reescalado lo hace la GPU.
#
#   x11   xfreerdp3 dentro de un servidor X mínimo. Es la ruta clásica y
#         la que sirve de red de seguridad si SDL da problemas: el fallo
#         típico de KMSDRM es que la imagen aparece pero el teclado no
#         responde.
#
# ---------------------------------------------------------------------
#  La contraseña
# ---------------------------------------------------------------------
#
# Nunca viaja en la línea de órdenes: /proc/PID/cmdline es legible por
# cualquier proceso del sistema. FreeRDP 3 admite /args-from:<fichero>
# ("Read command line from a file, stdin or file descriptor... one
# argument per line"), así que los argumentos se escriben en un fichero
# 0600 dentro de /run, que es tmpfs y por tanto nunca toca la tarjeta.

[[ -n "${PITHIN_RDP_CARGADO:-}" ]] && return 0
PITHIN_RDP_CARGADO=1

# shellcheck source=/dev/null
source "${PITHIN_LIB:-/usr/local/lib/pithin}/pithin-common.sh"
# shellcheck source=/dev/null
source "${PITHIN_LIB:-/usr/local/lib/pithin}/pithin-pantalla.sh"

RDP_DIR_EJECUCION="/run/pithin"
RDP_LOG_SESION="$RDP_DIR_EJECUCION/sesion.log"

# Última causa de desconexión, en texto legible. La rellena rdp_conectar
# y la leen el menú y pithin-sesion para explicar qué ha pasado.
# shellcheck disable=SC2034
RDP_ULTIMO_MOTIVO=""

# Límite de duración en segundos. Solo se usa en la sesión de prueba que
# estrena un backend; 0 significa sin límite.
RDP_LIMITE_SEGUNDOS=0

# Lo pone rdp_conectar a 1 si la sesión terminó por agotar ese límite.
RDP_TERMINO_POR_LIMITE=0

# ---------------------------------------------------------------------
#  Backends y binarios
# ---------------------------------------------------------------------

rdp_binario_sdl() {
    if   hay_comando sdl-freerdp3; then printf 'sdl-freerdp3'
    elif hay_comando sdl-freerdp;  then printf 'sdl-freerdp'
    elif hay_comando sdl3-freerdp; then printf 'sdl3-freerdp'
    else return 1
    fi
}

rdp_binario_x11() {
    if   hay_comando xfreerdp3; then printf 'xfreerdp3'
    elif hay_comando xfreerdp;  then printf 'xfreerdp'
    else return 1
    fi
}

rdp_backend_disponible() {
    case "$1" in
        sdl) rdp_binario_sdl >/dev/null 2>&1 ;;
        x11) rdp_binario_x11 >/dev/null 2>&1 && hay_comando startx ;;
        *)   return 1 ;;
    esac
}

# Resuelve "auto" y comprueba que lo pedido existe de verdad. Si el
# backend configurado no está instalado, cae al otro en vez de dejar al
# usuario mirando un error: tener imagen es más importante que respetar
# la preferencia.
rdp_backend_efectivo() {
    local pedido="${BACKEND:-sdl}"

    if [[ "$pedido" == "auto" ]]; then
        if rdp_backend_disponible sdl; then printf 'sdl'; return 0; fi
        if rdp_backend_disponible x11; then printf 'x11'; return 0; fi
        return 1
    fi

    if rdp_backend_disponible "$pedido"; then
        printf '%s' "$pedido"
        return 0
    fi

    local alternativo
    [[ "$pedido" == "sdl" ]] && alternativo="x11" || alternativo="sdl"
    if rdp_backend_disponible "$alternativo"; then
        log_aviso "El backend '$pedido' no está instalado; se usa '$alternativo'."
        printf '%s' "$alternativo"
        return 0
    fi

    return 1
}

rdp_binario() {
    local backend
    backend="$(rdp_backend_efectivo)" || return 1
    case "$backend" in
        sdl) rdp_binario_sdl ;;
        x11) rdp_binario_x11 ;;
    esac
}

rdp_disponible() { rdp_backend_efectivo >/dev/null 2>&1; }

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
#  Escalado
# ---------------------------------------------------------------------
#
# Aquí estaba el error de la primera versión: se añadía /smart-sizing
# siempre que la sesión y la pantalla no coincidían. Pero /smart-sizing
# escala por software, así que en el cliente X11 metía un reescalado de
# 2,25x por fotograma en la CPU, comiéndose buena parte del ahorro que
# justificaba bajar la resolución.
#
# La regla correcta:
#
#   La salida ya va a la resolución de la sesión  ->  no escalar nada.
#   Backend sdl                                   ->  escalar (lo hace la GPU).
#   Backend x11                                   ->  escalar avisando del coste.

# Rellena RDP_ARGS_ESCALADO. Vacío si no hace falta escalar.
_rdp_calcular_escalado() {
    RDP_ARGS_ESCALADO=()

    local backend salida
    backend="$(rdp_backend_efectivo)" || return 0

    if ! salida="$(pantalla_resolucion_efectiva 2>/dev/null)" || [[ -z "$salida" ]]; then
        log_debug "No se pudo leer la resolución de la pantalla; no se escala."
        return 0
    fi

    if [[ "$salida" == "$RESOLUCION" ]]; then
        log_info "Sesión y pantalla a $RESOLUCION: no hay que escalar nada."
        return 0
    fi

    RDP_ARGS_ESCALADO=("/smart-sizing:${salida}")

    if [[ "$backend" == "sdl" ]]; then
        log_info "Sesión a $RESOLUCION estirada a $salida por la GPU."
    else
        log_aviso "Sesión a $RESOLUCION estirada a $salida POR LA CPU (backend x11). Con el backend sdl saldría gratis."
    fi
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

    _rdp_calcular_escalado
    (( ${#RDP_ARGS_ESCALADO[@]} )) && RDP_ARGS+=("${RDP_ARGS_ESCALADO[@]}")

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

    if (( RDP_TERMINO_POR_LIMITE )); then
        RDP_ULTIMO_MOTIVO="La sesión de prueba terminó al agotarse el tiempo previsto."
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
        *"kmsdrm"*|*"KMSDRM"*|*"No available video device"*|*"Could not initialize SDL"*)
            RDP_ULTIMO_MOTIVO="SDL no pudo tomar la pantalla. Prueba el perfil Compatibilidad, que usa X11." ;;
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

# Ejecuta el cliente con el entorno propio del backend.
_rdp_ejecutar() {
    local backend="$1" binario="$2" fichero_args="$3"
    local codigo=0

    local -a envoltorio=()
    if (( RDP_LIMITE_SEGUNDOS > 0 )); then
        # --kill-after cubre el caso de que el cliente ignore el TERM.
        envoltorio=(timeout --signal=TERM --kill-after=5 "$RDP_LIMITE_SEGUNDOS")
    fi

    if [[ "$backend" == "sdl" ]]; then
        # Sin esto SDL podría elegir X11 o Wayland si los detectase.
        # Aquí no hay ninguno de los dos: hablamos con el controlador de
        # pantalla del kernel directamente.
        export SDL_VIDEODRIVER=kmsdrm

        # El cursor de la consola de texto parpadearía por encima de la
        # imagen: se apaga mientras dura la sesión.
        _rdp_cursor_consola off
    fi

    "${envoltorio[@]}" "$binario" "/args-from:$fichero_args" \
        >"$RDP_LOG_SESION" 2>&1 || codigo=$?

    [[ "$backend" == "sdl" ]] && _rdp_cursor_consola on

    # 124 es el código con que timeout señala que se agotó el plazo.
    if (( RDP_LIMITE_SEGUNDOS > 0 )) && (( codigo == 124 || codigo == 137 )); then
        RDP_TERMINO_POR_LIMITE=1
    fi

    return "$codigo"
}

_rdp_cursor_consola() {
    local estado="$1"
    if [[ "$estado" == "off" ]]; then
        printf '\033[?25l' >/dev/tty 2>/dev/null || true
        printf '0\n' >/sys/class/graphics/fbcon/cursor_blink 2>/dev/null || true
    else
        printf '\033[?25h' >/dev/tty 2>/dev/null || true
        printf '1\n' >/sys/class/graphics/fbcon/cursor_blink 2>/dev/null || true
    fi
}

# rdp_conectar <contraseña>
# Devuelve el código de salida de FreeRDP. Deja el motivo legible en
# RDP_ULTIMO_MOTIVO.
rdp_conectar() {
    local secreto="$1"
    local backend binario

    RDP_TERMINO_POR_LIMITE=0

    if ! backend="$(rdp_backend_efectivo)"; then
        RDP_ULTIMO_MOTIVO="No hay ningún cliente FreeRDP instalado."
        return 127
    fi
    binario="$(rdp_binario)" || { RDP_ULTIMO_MOTIVO="No hay cliente FreeRDP."; return 127; }

    install -d -m 0700 "$RDP_DIR_EJECUCION" || return 1

    rdp_construir_argumentos "$secreto"
    log_info "Lanzando ($backend) $binario $(rdp_argumentos_censurados)"

    local fichero_args
    fichero_args="$(mktemp "$RDP_DIR_EJECUCION/args.XXXXXX")" || return 1
    chmod 0600 "$fichero_args"
    # shellcheck disable=SC2064
    trap "rm -f '$fichero_args'" RETURN

    printf '%s\n' "${RDP_ARGS[@]}" >"$fichero_args"

    local codigo=0
    _rdp_ejecutar "$backend" "$binario" "$fichero_args" || codigo=$?

    # Si FreeRDP se ha quejado de los argumentos, casi siempre es por la
    # forma exacta de /gfx, que varía entre versiones. Se reintenta una
    # vez con lo mínimo imprescindible antes de dar el error por bueno.
    if (( codigo != 0 )) && ! (( RDP_TERMINO_POR_LIMITE )) \
       && _rdp_error_de_argumentos "$RDP_LOG_SESION"; then
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
        _rdp_ejecutar "$backend" "$binario" "$fichero_args" || codigo=$?
    fi

    _rdp_interpretar_salida "$codigo" "$RDP_LOG_SESION" || true
    log_info "Sesión terminada (código $codigo): $RDP_ULTIMO_MOTIVO"

    return "$codigo"
}

# ¿Merece la pena reintentar solo, o hace falta que intervenga alguien?
# Un fallo de credenciales o de argumentos no se arregla reintentando. Y un
# cierre deliberado (el usuario cerró sesión, u otra conexión tomó el PC)
# NO es un fallo: reconectar volvería a entrar en Windows en bucle, o pelearía
# por la sesión con quien acaba de tomarla.
rdp_fallo_recuperable() {
    (( RDP_TERMINO_POR_LIMITE )) && return 1
    case "$RDP_ULTIMO_MOTIVO" in
        *"contraseña incorrectos"*|*bloqueada*|*deshabilitada*|*caducado*|*rechazó*|*"SDL no pudo"*| \
        *"Cerraste sesión"*|*"tomado la sesión"*)
            return 1 ;;
        *)  return 0 ;;
    esac
}
