#!/usr/bin/env bash
# pithin-menus.sh - pantallas de la interfaz de texto.
#
# Todo lo que no sea "encender y conectar" vive aquí: perfiles, asistente
# de redes, ajustes, credenciales, diagnóstico y apagado.

[[ -n "${PITHIN_MENUS_CARGADO:-}" ]] && return 0
PITHIN_MENUS_CARGADO=1

# shellcheck source=/dev/null
source "${PITHIN_LIB:-/usr/local/lib/pithin}/pithin-tui.sh"
# shellcheck source=/dev/null
source "${PITHIN_LIB:-/usr/local/lib/pithin}/pithin-config.sh"
# shellcheck source=/dev/null
source "${PITHIN_LIB:-/usr/local/lib/pithin}/pithin-perfiles.sh"
# shellcheck source=/dev/null
source "${PITHIN_LIB:-/usr/local/lib/pithin}/pithin-pantalla.sh"
# shellcheck source=/dev/null
source "${PITHIN_LIB:-/usr/local/lib/pithin}/pithin-wifi.sh"
# shellcheck source=/dev/null
source "${PITHIN_LIB:-/usr/local/lib/pithin}/pithin-vpn.sh"
# shellcheck source=/dev/null
source "${PITHIN_LIB:-/usr/local/lib/pithin}/pithin-rdp.sh"

MOTIVO_ULTIMA_SESION="/run/pithin/ultimo-motivo"
ESTADO_ULTIMA_SESION="/run/pithin/estado-sesion"

# ---------------------------------------------------------------------
#  Asistente de redes WiFi
# ---------------------------------------------------------------------

WIFI_RESULTADO_ESCANEO="/run/pithin/redes-encontradas"

_wifi_escanear_a_fichero() {
    install -d -m 0700 /run/pithin 2>/dev/null || true
    wifi_escanear >"$WIFI_RESULTADO_ESCANEO" 2>/dev/null
}

# Muestra las redes al alcance y conecta a la elegida.
# Devuelve 0 si se consiguió conexión.
asistente_wifi() {
    local -a opciones
    local ssid senal seguridad eleccion clave abierta candado

    while true; do
        tui_esperando "Buscando redes WiFi..." _wifi_escanear_a_fichero || true

        opciones=()
        while IFS=$'\t' read -r ssid senal seguridad; do
            [[ -n "$ssid" ]] || continue
            candado="abierta"
            [[ -n "$seguridad" && "$seguridad" != "--" ]] && candado="con clave"
            opciones+=("$ssid" "señal ${senal}%  ·  $candado")
        done <"$WIFI_RESULTADO_ESCANEO"

        if (( ${#opciones[@]} == 0 )); then
            opciones+=("__ninguna__" "No se ha encontrado ninguna red")
        fi

        opciones+=("__manual__"     "Escribir el nombre de una red a mano")
        opciones+=("__reescanear__" "Volver a buscar")

        eleccion="$(tui_menu "Redes WiFi" \
"Elige la red a la que conectarte.

Actual: $(wifi_conectado && wifi_ssid_actual || printf 'sin conexión')" \
            22 74 12 "${opciones[@]}")" || return 1

        case "$eleccion" in
            ""|__ninguna__) [[ -z "$eleccion" ]] && return 1; continue ;;
            __reescanear__) continue ;;
            __manual__)
                ssid="$(tui_entrada "Red oculta" "Nombre exacto de la red (SSID):")" || continue
                [[ -n "$ssid" ]] || continue
                clave="$(tui_contrasena "Contraseña" \
"Contraseña de '$ssid'. Déjalo vacío si la red es abierta.")" || continue
                _wifi_intentar "$ssid" "$clave" "si" && return 0
                continue
                ;;
        esac

        ssid="$eleccion"

        # Reutilizamos el escaneo que ya tenemos para saber si la red
        # pide clave, y así no preguntar de más en las abiertas.
        abierta=1
        while IFS=$'\t' read -r _s _n _sec; do
            [[ "$_s" == "$ssid" && -n "$_sec" && "$_sec" != "--" ]] && abierta=0
        done <"$WIFI_RESULTADO_ESCANEO"

        clave=""
        if (( ! abierta )); then
            clave="$(tui_contrasena "Contraseña" "Contraseña de '$ssid':")" || continue
        fi

        _wifi_intentar "$ssid" "$clave" "no" && return 0
    done
}

_wifi_intentar() {
    local ssid="$1" clave="$2" oculta="$3"

    if ! tui_esperando "Conectando a '$ssid'..." wifi_conectar_nueva "$ssid" "$clave" "$oculta"; then
        tui_error "No se pudo conectar a '$ssid'.

Comprueba la contraseña y que estés dentro de cobertura."
        return 1
    fi

    if es_si "$GUARDAR_REDES_NUEVAS"; then
        if wifi_guardar_en_fichero "$ssid" "$clave" "$oculta"; then
            tui_mensaje "Conectado" \
"Conectado a '$ssid'.

La red se ha guardado en la tarjeta: la próxima vez se conectará sola." 12 68
        else
            tui_mensaje "Conectado" \
"Conectado a '$ssid'.

No se pudo guardar en la tarjeta, así que habrá que repetirlo en el próximo arranque." 12 68
        fi
    fi
    return 0
}

# Bucle que no deja seguir hasta que haya red o el usuario decida otra
# cosa. Se usa en el arranque cuando no aparece ninguna red conocida.
asistente_wifi_necesario() {
    while true; do
        if wifi_conectado; then return 0; fi

        if asistente_wifi; then return 0; fi

        local eleccion
        eleccion="$(tui_menu "Sin conexión" \
"No hay conexión a Internet, así que no se puede llegar a tu PC.

¿Qué quieres hacer?" 15 70 4 \
            "reintentar" "Buscar redes otra vez" \
            "menu"       "Ir al menú principal de todas formas" \
            "consola"    "Abrir una consola de texto" \
            "apagar"     "Apagar el equipo")" || return 1

        case "$eleccion" in
            reintentar) continue ;;
            menu)       return 1 ;;
            consola)    abrir_consola ;;
            apagar)     apagar_equipo ;;
            *)          return 1 ;;
        esac
    done
}

menu_redes() {
    local eleccion
    while true; do
        eleccion="$(tui_menu "Redes WiFi" \
"Conexión actual: $(wifi_conectado && wifi_ssid_actual || printf 'ninguna')" 16 72 4 \
            "conectar"   "Conectarse a una red" \
            "guardadas"  "Ver las redes guardadas en la tarjeta" \
            "reimportar" "Releer redes.conf de la tarjeta" \
            "estado"     "Ver el estado de la red")" || return 0

        case "$eleccion" in
            conectar)  asistente_wifi || true ;;
            guardadas) _mostrar_redes_guardadas ;;
            reimportar)
                tui_esperando "Releyendo redes.conf..." wifi_importar_redes
                tui_mensaje "Hecho" "Se han vuelto a importar las redes de la tarjeta." 9 60
                ;;
            estado)    _mostrar_estado_red ;;
            *) return 0 ;;
        esac
    done
}

_mostrar_redes_guardadas() {
    local texto="" ssid prioridad
    while IFS=$'\t' read -r ssid prioridad; do
        [[ -n "$ssid" ]] || continue
        texto+="  · $ssid   (prioridad $prioridad)"$'\n'
    done < <(wifi_listar_guardadas)

    [[ -n "$texto" ]] || texto="No hay ninguna red guardada todavía."

    tui_mensaje "Redes guardadas" \
"Estas son las redes de $PITHIN_REDES

$texto
Puedes editarlas metiendo la tarjeta en cualquier ordenador." 20 74
}

_mostrar_estado_red() {
    local dev ip
    dev="$(wifi_interfaz)"
    ip="$(ip -4 addr show "$dev" 2>/dev/null | awk '/inet /{print $2; exit}')"

    tui_mensaje "Estado de la red" \
"Interfaz ....... $dev
Red ............ $(wifi_conectado && wifi_ssid_actual || printf 'sin conexión')
Dirección IP ... ${ip:-ninguna}

Tailscale ...... $(vpn_estado)
IP de Tailscale  $(vpn_ip_propia || printf 'ninguna')" 16 70
}

# ---------------------------------------------------------------------
#  Perfiles
# ---------------------------------------------------------------------

menu_perfiles() {
    local eleccion actual
    while true; do
        actual="$(perfil_detectar)"

        local -a opciones=()
        local nombre marca
        for nombre in "${PERFILES_DISPONIBLES[@]}"; do
            marca=" "
            [[ "$nombre" == "$actual" ]] && marca="•"
            opciones+=("$nombre" "$marca $(perfil_titulo "$nombre") — $(perfil_resumen "$nombre")")
        done
        opciones+=("__detalle__" "  Ver en qué se diferencian")

        eleccion="$(tui_menu "Perfil de sesión" \
"Combinaciones probadas de backend, resolución, salida y códec.

Actual: $(perfil_titulo "$actual")" 20 84 6 "${opciones[@]}")" || return 0

        case "$eleccion" in
            "") return 0 ;;
            __detalle__) _comparar_perfiles ;;
            *)
                if [[ "$eleccion" == "$actual" ]]; then
                    tui_mensaje "Sin cambios" "Ya estabas usando ese perfil." 9 56
                    continue
                fi
                _aplicar_perfil_interactivo "$eleccion"
                ;;
        esac
    done
}

_aplicar_perfil_interactivo() {
    local nombre="$1"

    if ! tui_confirmar "$(perfil_titulo "$nombre")" \
"$(perfil_detalle "$nombre")

¿Aplicar este perfil?" 22 76 "Aplicar" "Cancelar"; then
        return 0
    fi

    # Un perfil con salida 'sesion' fuerza la resolución de sesión en la
    # pantalla; si el monitor no la anuncia, forzarla dejaría la pantalla en
    # negro. Se comprueba antes de escribir nada para no dejar pithin.conf y
    # cmdline.txt descuadrados de forma permanente.
    if [[ "$(perfil_salida "$nombre")" == "sesion" ]] \
       && ! pantalla_admite "$(perfil_resolucion "$nombre")"; then
        tui_error "El perfil «$(perfil_titulo "$nombre")» fija la salida a $(perfil_resolucion "$nombre"), un modo que tu monitor no anuncia.

No se aplica, para no dejarte sin imagen. Mira los modos admitidos en Pantalla."
        return 0
    fi

    if ! perfil_aplicar "$nombre"; then
        tui_error "No se pudo guardar el perfil en la tarjeta.

¿Está protegida contra escritura? El cambio no se ha aplicado."
        return 0
    fi

    # El modo de salida HDMI se fija en cmdline.txt, así que necesita
    # reinicio. Se hace ahora y se avisa.
    _sincronizar_pantalla_si_hace_falta
}

_comparar_perfiles() {
    local texto="" nombre
    texto+=$(printf '%-16s %-5s %-10s %-8s %s\n' "PERFIL" "VÍDEO" "SESIÓN" "SALIDA" "COLOR")$'\n'
    for nombre in "${PERFILES_DISPONIBLES[@]}"; do
        texto+=$(printf '%-16s %-5s %-10s %-8s %s\n' \
            "$(perfil_titulo "$nombre")" \
            "$(perfil_backend "$nombre")" \
            "$(perfil_resolucion "$nombre")" \
            "$(perfil_salida "$nombre")" \
            "$(perfil_color "$nombre") bits")$'\n'
    done

    tui_mensaje "Comparativa" \
"$texto
SALIDA nativa: la pantalla va a su resolución y estira la imagen.
SALIDA sesion: la salida HDMI baja a la resolución de la sesión y
               reescala tu monitor. Gasta menos memoria, pero la
               calidad depende del monitor.

VÍDEO sdl:     sin servidor X. Más ligero y escala por GPU.
VÍDEO x11:     la ruta clásica. Red de seguridad." 24 80
}

# ---------------------------------------------------------------------
#  Pantalla
# ---------------------------------------------------------------------

menu_pantalla() {
    local eleccion nativa forzada
    while true; do
        nativa="$(pantalla_resolucion_nativa 2>/dev/null || printf 'desconocida')"
        forzada="$(pantalla_modo_forzado 2>/dev/null || printf '')"

        eleccion="$(tui_menu "Pantalla" \
"Monitor detectado: $nativa
Salida forzada:    ${forzada:-ninguna (se usa la nativa)}
Sesión remota:     $RESOLUCION" 18 76 4 \
            "salida"     "Modo de salida ......... $SALIDA_HDMI" \
            "resolucion" "Resolución de sesión ... $RESOLUCION" \
            "modos"      "Ver los modos que admite el monitor" \
            "explicar"   "¿Qué diferencia hay entre las dos salidas?")" || return 0

        case "$eleccion" in
            salida)     _ajustar_salida_hdmi ;;
            resolucion) _ajustar_resolucion ;;
            modos)      _mostrar_modos_monitor ;;
            explicar)   _explicar_salidas ;;
            *) return 0 ;;
        esac
    done
}

_ajustar_salida_hdmi() {
    local eleccion
    eleccion="$(tui_menu "Modo de salida" \
"¿Quién reescala la imagen?" 17 78 2 \
        "nativa" "La pantalla a su resolución, estira la Raspberry" \
        "sesion" "La salida HDMI baja a $RESOLUCION, reescala el monitor")" || return 0
    [[ -n "$eleccion" ]] || return 0

    if [[ "$eleccion" == "sesion" ]] && ! pantalla_admite "$RESOLUCION"; then
        tui_error "El monitor no anuncia el modo $RESOLUCION.

Forzarlo dejaría la pantalla en negro, así que no se hace. Mira los modos que admite en el menú anterior."
        return 0
    fi

    config_guardar_ajuste SALIDA_HDMI "$eleccion" || {
        tui_error "No se pudo guardar el ajuste."
        return 0
    }
    config_validar
    perfil_resincronizar
    _sincronizar_pantalla_si_hace_falta
}

# Aplica el modo de salida a cmdline.txt y ofrece reiniciar. El modo
# KMS se fija en el arranque del kernel: no hay forma de cambiarlo en
# caliente sin reiniciar.
_sincronizar_pantalla_si_hace_falta() {
    pantalla_requiere_reinicio || return 0

    local resultado=0
    pantalla_sincronizar || resultado=$?

    case "$resultado" in
        0) ;;
        2) tui_error "No se detecta ningún monitor HDMI, así que no se puede fijar el modo."
           return 0 ;;
        3) tui_error "El monitor no admite ese modo. No se ha tocado nada para no dejarte sin imagen."
           return 0 ;;
        *) tui_error "No se pudo modificar cmdline.txt. ¿Está la tarjeta protegida contra escritura?"
           return 0 ;;
    esac

    if tui_confirmar "Hace falta reiniciar" \
"El modo de salida de pantalla se fija al arrancar el kernel, así que este cambio necesita un reinicio.

¿Reiniciar ahora?" 13 72 "Reiniciar" "Luego"; then
        clear
        systemctl reboot
        exit 0
    fi

    tui_mensaje "Pendiente" \
"El cambio se aplicará en el próximo arranque." 9 60
}

_mostrar_modos_monitor() {
    local modos
    modos="$(pantalla_modos_disponibles 2>/dev/null)"

    if [[ -z "$modos" ]]; then
        tui_mensaje "Modos del monitor" \
"No se ha podido leer la lista de modos.

¿Está el HDMI conectado?" 11 62
        return 0
    fi

    tui_mensaje "Modos del monitor" \
"Resoluciones que anuncia tu monitor. Solo se puede forzar la salida a una de estas:

$modos" 22 60
}

_explicar_salidas() {
    tui_mensaje "Modos de salida" \
"NATIVA
La pantalla funciona a su resolución (normalmente 1080p) y la imagen de la sesión se estira para llenarla. Con el backend sdl ese estirado lo hace la GPU y no cuesta nada de CPU.

Es la opción segura: funciona con cualquier monitor.

SESION
La salida HDMI baja a la misma resolución que la sesión, así que en la Raspberry no se escala nada. Además el controlador de vídeo lee un framebuffer la mitad de grande sesenta veces por segundo, lo que libera bastante ancho de banda de memoria para la CPU.

A cambio reescala tu monitor, y ahí la calidad varía mucho de uno a otro. Algunos televisores además añaden retardo." 24 78
}

# ---------------------------------------------------------------------
#  Ajustes
# ---------------------------------------------------------------------

menu_ajustes() {
    local eleccion
    while true; do
        # shellcheck disable=SC2153  # variables de configuración, definidas en pithin-config.sh
        eleccion="$(tui_menu "Ajustes" \
"Perfil: $(perfil_titulo "$(perfil_detectar)")   ·   $RESOLUCION   ·   $BACKEND" 20 80 8 \
            "host"        "PC de destino .......... ${RDP_HOST:-sin definir}" \
            "usuario"     "Usuario de Windows ..... ${RDP_USER:-sin definir}" \
            "backend"     "Sistema de vídeo ....... $BACKEND" \
            "codec"       "Códec de vídeo ......... $CODEC" \
            "color"       "Profundidad de color ... $PROFUNDIDAD_COLOR bits" \
            "teclado"     "Teclado ................ $TECLADO" \
            "autoconectar" "Conectar al encender ... $AUTOCONECTAR" \
            "sonido"      "Sonido remoto .......... $SONIDO")" || return 0

        case "$eleccion" in
            host)       _ajustar_texto RDP_HOST "PC de destino" \
"Nombre del PC en tu red de Tailscale, o su dirección 100.x.y.z" ;;
            usuario)    _ajustar_texto RDP_USER "Usuario de Windows" \
"Cuenta local:      Antonio
Cuenta Microsoft:  MicrosoftAccount\\\\tu@correo.com" ;;
            backend)    menu_backend ;;
            codec)      _ajustar_codec ;;
            color)      _ajustar_color ;;
            teclado)    _ajustar_teclado ;;
            autoconectar) _alternar AUTOCONECTAR ;;
            sonido)     _alternar SONIDO ;;
            *) return 0 ;;
        esac
    done
}

_ajustar_texto() {
    local clave="$1" titulo="$2" ayuda="$3"
    local nuevo
    nuevo="$(tui_entrada "$titulo" "$ayuda" "${!clave}" 14 72)" || return 0
    [[ -n "$nuevo" ]] || return 0
    if config_guardar_ajuste "$clave" "$nuevo"; then
        config_validar
    else
        tui_error "No se pudo guardar. ¿Está la tarjeta protegida contra escritura?"
    fi
}

_alternar() {
    local clave="$1" nuevo
    if es_si "${!clave}"; then nuevo="no"; else nuevo="si"; fi
    config_guardar_ajuste "$clave" "$nuevo" \
        || tui_error "No se pudo guardar el ajuste."
}

_ajustar_resolucion() {
    local eleccion
    eleccion="$(tui_menu "Resolución de la sesión" \
"Cuántos píxeles genera Windows, viajan por el WiFi y hay que descodificar aquí.

Es el ajuste que más influye en la fluidez." 19 78 4 \
        "1920x1080" "Nítido. Para buen WiFi" \
        "1600x900"  "Punto intermedio" \
        "1280x720"  "Bastante más fluido. Recomendado" \
        "1024x768"  "Mínimo. Solo si todo lo demás va mal")" || return 0
    [[ -n "$eleccion" ]] || return 0

    # Con la salida atada a la resolución de sesión, esa resolución tiene que
    # ser una que el monitor admita; si no, al sincronizar cmdline.txt se
    # quedaría un estado imposible (config pide 'sesion' a un modo que no
    # existe). Se comprueba antes de guardar.
    if [[ "$SALIDA_HDMI" == "sesion" ]] && ! pantalla_admite "$eleccion"; then
        tui_error "Tu monitor no anuncia el modo $eleccion, y con la salida en «sesion» habría que forzarlo (pantalla en negro).

Cambia antes la salida a «nativa», o elige una resolución que el monitor admita."
        return 0
    fi

    if ! config_guardar_ajuste RESOLUCION "$eleccion"; then
        tui_error "No se pudo guardar. ¿Está la tarjeta protegida contra escritura?"
        return 0
    fi
    config_validar
    perfil_resincronizar

    # Si la salida estaba atada a la resolución de sesión, hay que
    # rehacer cmdline.txt con la nueva.
    _sincronizar_pantalla_si_hace_falta
}

_ajustar_codec() {
    local eleccion
    eleccion="$(tui_menu "Códec de vídeo" \
"La Zero 2 W descodifica por software: no puede acelerar H.264 por hardware.

Por eso 'progressive' suele ir mejor que 'avc420' aunque comprima peor." 18 78 4 \
        "progressive" "RemoteFX Progressive. Recomendado aquí" \
        "rfx"         "RemoteFX clásico. Alternativa" \
        "avc420"      "H.264. Comprime mejor pero exige mucha más CPU" \
        "auto"        "Que lo negocien Windows y FreeRDP")" || return 0
    [[ -n "$eleccion" ]] || return 0
    if config_guardar_ajuste CODEC "$eleccion"; then
        config_validar
        perfil_resincronizar
    else
        tui_error "No se pudo guardar. ¿Está la tarjeta protegida contra escritura?"
    fi
}

_ajustar_color() {
    local eleccion
    eleccion="$(tui_menu "Profundidad de color" \
"16 bits ahorra ancho de banda y algo de CPU, a costa de degradados menos finos." 14 72 2 \
        "32" "Color completo. Recomendado" \
        "16" "Ahorra ancho de banda")" || return 0
    [[ -n "$eleccion" ]] || return 0
    if config_guardar_ajuste PROFUNDIDAD_COLOR "$eleccion"; then
        config_validar
        perfil_resincronizar
    else
        tui_error "No se pudo guardar. ¿Está la tarjeta protegida contra escritura?"
    fi
}

_ajustar_teclado() {
    local eleccion
    eleccion="$(tui_menu "Teclado" "Distribución del teclado conectado a la Raspberry:" 16 66 5 \
        "es"    "Español (España)" \
        "latam" "Español (Latinoamérica)" \
        "us"    "Inglés (EEUU)" \
        "uk"    "Inglés (Reino Unido)" \
        "pt"    "Portugués")" || return 0
    [[ -n "$eleccion" ]] || return 0
    if config_guardar_ajuste TECLADO "$eleccion"; then
        config_validar
    else
        tui_error "No se pudo guardar. ¿Está la tarjeta protegida contra escritura?"
    fi
    # El keymap de la consola se cambia igual, aunque no se pudiera guardar:
    # así el teclado responde ya en esta sesión.
    loadkeys "$eleccion" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------
#  Backend gráfico
# ---------------------------------------------------------------------

menu_backend() {
    local eleccion disponible_sdl="no" disponible_x11="no"
    rdp_backend_disponible sdl && disponible_sdl="sí"
    rdp_backend_disponible x11 && disponible_x11="sí"

    eleccion="$(tui_menu "Sistema de vídeo" \
"Cómo se dibuja la sesión en la pantalla.

sdl instalado: $disponible_sdl   ·   x11 instalado: $disponible_x11" 19 80 3 \
        "sdl"  "SDL/KMSDRM — sin servidor X. Más ligero $(backend_validado sdl && printf '(probado)')" \
        "x11"  "X11 — la ruta clásica $(backend_validado x11 && printf '(probado)')" \
        "auto" "Elegir solo el que esté disponible")" || return 0
    [[ -n "$eleccion" ]] || return 0

    if [[ "$eleccion" != "auto" ]] && ! rdp_backend_disponible "$eleccion"; then
        tui_error "El backend '$eleccion' no está instalado en este equipo.

Vuelve a ejecutar el instalador para añadirlo."
        return 0
    fi

    if ! config_guardar_ajuste BACKEND "$eleccion"; then
        tui_error "No se pudo guardar. ¿Está la tarjeta protegida contra escritura?"
        return 0
    fi
    config_validar
    perfil_resincronizar

    if [[ "$eleccion" != "auto" ]] && ! backend_validado "$eleccion"; then
        tui_mensaje "Se probará al conectar" \
"La primera sesión con '$eleccion' será una prueba con tiempo limitado.

El fallo típico de este cambio es que la imagen aparezca pero el teclado no responda, y en ese caso no habría forma de salir de la sesión desde dentro. Por eso se cierra sola y luego se te pregunta si funcionaba." 16 76
    fi
}

# ---------------------------------------------------------------------
#  Credenciales
# ---------------------------------------------------------------------

menu_credenciales() {
    local eleccion estado
    while true; do
        if cred_existe; then
            estado="guardada y cifrada"
        else
            estado="no guardada (se pide cada vez)"
        fi

        eleccion="$(tui_menu "Contraseña de Windows" \
"Estado actual: $estado

La contraseña se cifra con Argon2id y con el número de serie de esta Raspberry: una copia de la tarjeta en otro equipo no basta para descifrarla." 18 76 3 \
            "cambiar" "Guardar o cambiar la contraseña y el PIN" \
            "borrar"  "Borrar la contraseña guardada" \
            "info"    "Explicación de cómo se protege")" || return 0

        case "$eleccion" in
            cambiar) _cambiar_credencial ;;
            borrar)
                if cred_existe && tui_confirmar "Borrar credencial" \
"¿Seguro que quieres borrar la contraseña guardada?

A partir de ahora habrá que escribirla en cada conexión." 12 68; then
                    cred_borrar
                    tui_mensaje "Hecho" "La contraseña guardada se ha eliminado." 9 60
                fi
                ;;
            info) _explicar_seguridad ;;
            *) return 0 ;;
        esac
    done
}

_cambiar_credencial() {
    local secreto
    secreto="$(tui_contrasena "Contraseña de Windows" \
"Escribe la contraseña de tu cuenta de Windows." 11 72)" || return 0
    [[ -n "$secreto" ]] || return 0
    _tui_establecer_pin "$secreto" || true
}

_explicar_seguridad() {
    tui_mensaje "Cómo se protege la contraseña" \
"Un PIN corto tiene poca entropía: cuatro dígitos son diez mil combinaciones y se prueban en segundos. Por eso hay tres refuerzos:

1. Argon2id para derivar la clave. Cada intento exige 64 MB de memoria, lo que arruina los ataques masivos con tarjetas gráficas.

2. La clave se deriva del PIN Y del número de serie del SoC. Copiar la tarjeta a otro equipo no sirve de nada.

3. El fichero vive en la partición ext4, que Windows y macOS ni siquiera montan sin herramientas extra.

Aun así: usa al menos 6 caracteres y mete alguna letra." 22 78
}

# ---------------------------------------------------------------------
#  Diagnóstico
# ---------------------------------------------------------------------

menu_diagnostico() {
    local eleccion
    while true; do
        eleccion="$(tui_menu "Diagnóstico" "¿Qué quieres comprobar?" 16 70 4 \
            "completo" "Comprobarlo todo de arriba abajo" \
            "equipos"  "Ver los equipos de mi red Tailscale" \
            "registro" "Ver el registro de PiThin" \
            "sesion"   "Ver el registro de la última sesión RDP")" || return 0

        case "$eleccion" in
            completo) _diagnostico_completo ;;
            equipos)  _listar_equipos_tailnet ;;
            registro) _ver_fichero "$PITHIN_LOG" "Registro de PiThin" ;;
            sesion)   _ver_fichero "$RDP_LOG_SESION" "Última sesión RDP" ;;
            *) return 0 ;;
        esac
    done
}

_diagnostico_completo() {
    local informe="" destino

    informe+="RED"$'\n'
    if wifi_conectado; then
        informe+="  [ok]  Conectado a $(wifi_ssid_actual)"$'\n'
    else
        informe+="  [--]  Sin conexión WiFi"$'\n'
    fi

    informe+=$'\n'"TAILSCALE"$'\n'
    if ! vpn_disponible; then
        informe+="  [--]  No está instalado"$'\n'
    elif vpn_activa; then
        informe+="  [ok]  Activo, IP $(vpn_ip_propia)"$'\n'
    else
        informe+="  [--]  Estado: $(vpn_estado)"$'\n'
        informe+="        Puede faltar la auth key en la tarjeta."$'\n'
    fi

    informe+=$'\n'"PC DE DESTINO"$'\n'
    if [[ -z "$RDP_HOST" ]]; then
        informe+="  [--]  No hay ningún PC configurado (RDP_HOST)"$'\n'
    else
        destino="$(vpn_ip_de "$RDP_HOST")"
        informe+="  ..... $RDP_HOST -> $destino"$'\n'
        if vpn_puerto_abierto "$destino" "$RDP_PUERTO" 5; then
            informe+="  [ok]  El puerto $RDP_PUERTO responde"$'\n'
        else
            informe+="  [--]  El puerto $RDP_PUERTO no responde."$'\n'
            informe+="        Revisa: PC encendido, Tailscale corriendo en él,"$'\n'
            informe+="        Escritorio Remoto activado y el firewall de Windows"$'\n'
            informe+="        permitiendo 3389 desde 100.64.0.0/10."$'\n'
        fi
    fi

    informe+=$'\n'"VÍDEO"$'\n'
    informe+="  ..... Perfil: $(perfil_titulo "$(perfil_detectar)")"$'\n'
    informe+="  $(rdp_backend_disponible sdl && printf '[ok]' || printf '[--]')  Cliente SDL   $(backend_validado sdl && printf '(probado)')"$'\n'
    informe+="  $(rdp_backend_disponible x11 && printf '[ok]' || printf '[--]')  Cliente X11   $(backend_validado x11 && printf '(probado)')"$'\n'
    informe+="  ..... En uso: $(rdp_backend_efectivo 2>/dev/null || printf 'ninguno')"$'\n'

    informe+=$'\n'"PANTALLA"$'\n'
    informe+="  ..... Monitor: $(pantalla_resolucion_nativa 2>/dev/null || printf 'no detectado')"$'\n'
    informe+="  ..... Salida:  $(pantalla_resolucion_efectiva 2>/dev/null || printf '?')  (modo $SALIDA_HDMI)"$'\n'
    informe+="  ..... Sesión:  $RESOLUCION"$'\n'
    if pantalla_requiere_reinicio 2>/dev/null; then
        informe+="  [!!]  Hay un cambio de salida pendiente de reiniciar"$'\n'
    fi

    informe+=$'\n'"PROGRAMAS Y MEMORIA"$'\n'
    informe+="  $(hay_comando argon2 && printf '[ok]' || printf '[--]')  argon2"$'\n'
    informe+="  $(free -h | awk '/^Mem:/{print "..... total " $2 "  ·  libre " $7}')"$'\n'

    tui_mensaje "Diagnóstico" "$informe" 30 78
}

_listar_equipos_tailnet() {
    local texto="" nombre ip estado
    while IFS=$'\t' read -r nombre ip estado; do
        [[ -n "$nombre" ]] || continue
        texto+=$(printf '  %-24s %-16s %s\n' "$nombre" "$ip" "$estado")$'\n'
    done < <(vpn_listar_equipos)

    [[ -n "$texto" ]] || texto="No se ve ningún equipo. ¿Está Tailscale activo?"

    tui_mensaje "Equipos en tu red Tailscale" \
"Usa el nombre de la primera columna como RDP_HOST.

$texto" 22 76
}

_ver_fichero() {
    local fichero="$1" titulo="$2"
    if [[ ! -r "$fichero" ]]; then
        tui_mensaje "$titulo" "Todavía no hay nada que mostrar." 9 60
        return 0
    fi
    if tui_disponible; then
        whiptail --title "$TUI_TITULO — $titulo" \
                 --scrolltext --textbox "$fichero" 24 100 >/dev/tty 2>&1
    else
        tail -n 200 "$fichero" | less
    fi
}

# ---------------------------------------------------------------------
#  Sistema
# ---------------------------------------------------------------------

abrir_consola() {
    clear
    printf '\n  Consola de PiThin. Escribe "exit" para volver al menú.\n\n'
    # El shell de login relee /root/.bash_profile, que en tty1 relanzaría
    # pithin-arranque -> menu_principal (que no retorna): en vez de una
    # consola saldría otra vez el menú, y la consola de rescate —la
    # escapatoria cuando no hay red— quedaría inservible. Esta marca le dice
    # al perfil de arranque que NO auto-arranque en este shell.
    PITHIN_NO_AUTOARRANQUE=1 "${SHELL:-/bin/bash}" -l || true
}

apagar_equipo() {
    if tui_confirmar "Apagar" "¿Apagar el equipo?

Espera a que se apague el LED verde antes de desenchufarlo: así no se corrompe la tarjeta." 12 68; then
        clear
        systemctl poweroff
        exit 0
    fi
}

reiniciar_equipo() {
    if tui_confirmar "Reiniciar" "¿Reiniciar el equipo?" 9 50; then
        clear
        systemctl reboot
        exit 0
    fi
}

menu_sistema() {
    local eleccion
    while true; do
        eleccion="$(tui_menu "Sistema" "" 16 66 4 \
            "consola"   "Abrir una consola de texto" \
            "reiniciar" "Reiniciar el equipo" \
            "apagar"    "Apagar el equipo" \
            "acerca"    "Acerca de PiThin")" || return 0

        case "$eleccion" in
            consola)   abrir_consola ;;
            reiniciar) reiniciar_equipo ;;
            apagar)    apagar_equipo ;;
            acerca)    _acerca_de ;;
            *) return 0 ;;
        esac
    done
}

_acerca_de() {
    tui_mensaje "Acerca de PiThin" \
"Cliente ligero de escritorio remoto para Raspberry Pi Zero 2 W.

Se conecta a un PC con Windows a través de Tailscale y abre una sesión RDP a pantalla completa.

Configuración editable desde cualquier ordenador metiendo la tarjeta:
  $PITHIN_CONF
  $PITHIN_REDES

Registro: $PITHIN_LOG" 18 76
}

# ---------------------------------------------------------------------
#  Menú principal
# ---------------------------------------------------------------------

menu_principal() {
    local eleccion

    while true; do
        _informar_sesion_anterior

        eleccion="$(tui_menu "Menú principal" \
"$(wifi_conectado && printf 'WiFi: %s' "$(wifi_ssid_actual)" || printf 'WiFi: sin conexión')   ·   Tailscale: $(vpn_estado)
Destino: ${RDP_HOST:-sin definir}   ·   Perfil: $(perfil_titulo "$(perfil_detectar)")" 21 80 7 \
            "conectar"     "Conectar con mi PC" \
            "perfil"       "Perfil de sesión" \
            "pantalla"     "Pantalla y resolución" \
            "redes"        "Redes WiFi" \
            "ajustes"      "Ajustes de la conexión" \
            "credenciales" "Contraseña de Windows y PIN" \
            "diagnostico"  "Diagnóstico y sistema")" || { menu_sistema; continue; }

        case "$eleccion" in
            conectar)     lanzar_sesion || true ;;
            perfil)       menu_perfiles ;;
            pantalla)     menu_pantalla ;;
            redes)        menu_redes ;;
            ajustes)      menu_ajustes ;;
            credenciales) menu_credenciales ;;
            diagnostico)  _menu_diagnostico_y_sistema ;;
            "")           menu_sistema ;;
        esac
    done
}

_menu_diagnostico_y_sistema() {
    local eleccion
    eleccion="$(tui_menu "Diagnóstico y sistema" "" 13 62 2 \
        "diagnostico" "Diagnóstico" \
        "sistema"     "Consola, reiniciar, apagar")" || return 0
    case "$eleccion" in
        diagnostico) menu_diagnostico ;;
        sistema)     menu_sistema ;;
    esac
}

# Explica una sola vez por qué terminó la sesión anterior, y si la
# configuración es nueva y falló, ofrece volver a la que funcionaba.
_informar_sesion_anterior() {
    [[ -s "$MOTIVO_ULTIMA_SESION" ]] || return 0

    local motivo estado
    motivo="$(cat "$MOTIVO_ULTIMA_SESION")"
    estado="$(cat "$ESTADO_ULTIMA_SESION" 2>/dev/null || printf 'desconocido')"
    rm -f "$MOTIVO_ULTIMA_SESION" "$ESTADO_ULTIMA_SESION"

    if [[ "$estado" == "fallo" ]] && perfil_sin_validar && perfil_hay_bueno; then
        if tui_confirmar "Se cerró la sesión" \
"$motivo

Estás usando una configuración que todavía no había funcionado nunca. La última que sí funcionó fue:

  $(perfil_bueno_descripcion)

¿Quieres volver a ella?" 19 76 "Volver a la buena" "Seguir con esta"; then
            if perfil_restaurar_bueno; then
                _sincronizar_pantalla_si_hace_falta
                tui_mensaje "Restaurada" "Se ha vuelto a la configuración anterior." 9 60
            else
                tui_error "No se pudo restaurar la configuración anterior.

¿Está la tarjeta protegida contra escritura? Se sigue con la configuración actual."
            fi
        fi
        return 0
    fi

    tui_mensaje "Se cerró la sesión" "$motivo" 14 74
}

# ---------------------------------------------------------------------
#  Lanzamiento de la sesión
# ---------------------------------------------------------------------

# Pide el PIN en la consola de texto, arranca el backend elegido y
# espera a que la sesión termine. El secreto viaja por un fichero en
# tmpfs porque whiptail necesita un terminal de verdad, y dentro de la
# sesión gráfica no hay ninguno.
lanzar_sesion() {
    if ! config_completa; then
        tui_error "Falta por configurar el PC de destino.

Ve a Ajustes y rellena el nombre del PC y el usuario de Windows."
        return 1
    fi

    local backend
    if ! backend="$(rdp_backend_efectivo)"; then
        tui_error "No hay ningún cliente FreeRDP instalado. Vuelve a ejecutar el instalador."
        return 1
    fi

    if ! vpn_activa; then
        if ! tui_confirmar "Tailscale no está activo" \
"Tailscale está en estado '$(vpn_estado)', así que probablemente no se pueda llegar al PC.

¿Intentarlo de todas formas?" 13 70; then
            return 1
        fi
    fi

    # Primera vez con este backend: sesión de prueba acotada en el
    # tiempo. Ver la explicación en pithin-perfiles.sh.
    local modo_prueba=0
    if ! backend_validado "$backend"; then
        if ! tui_confirmar "Primera prueba de '$backend'" \
"Es la primera vez que se usa el sistema de vídeo '$backend' en este equipo.

La sesión se abrirá durante $PRUEBA_BACKEND_SEGUNDOS segundos y se cerrará sola. Aprovecha para comprobar que el teclado y el ratón responden; después se te preguntará.

Se hace así porque si la entrada no funcionara, no habría forma de salir de la sesión desde dentro." 19 76 "Probar" "Cancelar"; then
            return 1
        fi
        modo_prueba=1
    fi

    tui_preparar_secreto || return 1

    clear
    if (( modo_prueba )); then
        printf '\n  Prueba de %s: %s segundos.\n  Comprueba el teclado y el ratón.\n\n' \
            "$backend" "$PRUEBA_BACKEND_SEGUNDOS"
        export PITHIN_LIMITE_SESION="$PRUEBA_BACKEND_SEGUNDOS"
    else
        printf '\n  Conectando con %s...\n\n' "$RDP_HOST"
    fi

    _arrancar_backend "$backend"

    unset PITHIN_LIMITE_SESION
    tui_olvidar_secreto
    _restaurar_consola

    if (( modo_prueba )); then
        _resolver_prueba_backend "$backend"
    else
        # Una sesión que termina limpiamente confirma que esta
        # combinación de ajustes sirve.
        [[ "$(cat "$ESTADO_ULTIMA_SESION" 2>/dev/null)" == "ok" ]] && perfil_marcar_bueno
    fi

    return 0
}

_arrancar_backend() {
    local backend="$1"

    install -d -m 0700 /run/pithin 2>/dev/null || true

    if [[ "$backend" == "x11" ]]; then
        # -keeptty deja los mensajes de X en esta consola en vez de
        # saltar a otra, lo que hace mucho más fácil ver qué ha fallado.
        startx "$PITHIN_LIB/xinitrc" -- :0 vt1 -keeptty -nolisten tcp \
            >/run/pithin/xorg.log 2>&1 || true
    else
        # Sin servidor X: el cliente habla directamente con el
        # controlador de pantalla del kernel.
        /usr/local/bin/pithin-sesion >/run/pithin/sdl.log 2>&1 || true
    fi
}

# Tras una sesión KMSDRM la consola puede quedar sin repintar.
_restaurar_consola() {
    printf '\033[?25h' >/dev/tty 2>/dev/null || true
    tput reset >/dev/tty 2>/dev/null || clear || true
}

_resolver_prueba_backend() {
    local backend="$1" estado motivo
    estado="$(cat "$ESTADO_ULTIMA_SESION" 2>/dev/null)"
    motivo="$(cat "$MOTIVO_ULTIMA_SESION" 2>/dev/null)"

    # Fallo específico del vídeo (SDL no tomó la pantalla): se revierte sin
    # preguntar, porque el problema es claramente el backend.
    if [[ "$estado" == "fallo" && "$motivo" == *"SDL no pudo"* ]]; then
        backend_invalidar "$backend"
        tui_error "$motivo"
        rm -f "$MOTIVO_ULTIMA_SESION" "$ESTADO_ULTIMA_SESION"
        _revertir_backend "$backend"
        return 0
    fi

    # Fallo que NO tiene que ver con el vídeo (PC apagado, contraseña,
    # Tailscale, argumentos): no es culpa del backend. Preguntar "¿se veía la
    # imagen?" a quien no vio nada y tomar su "No" como que el backend está
    # roto degradaría el aparato a x11 por una causa ajena. En su lugar se
    # muestra la causa REAL (que antes se borraba sin enseñarse) y se deja el
    # backend sin validar para reintentar cuando el problema esté resuelto.
    if [[ "$estado" == "fallo" ]]; then
        tui_error "La sesión de prueba no llegó a mostrarse, así que todavía no se sabe si «$backend» funciona:

$motivo

Cuando eso esté resuelto, al conectar se volverá a hacer la prueba."
        rm -f "$MOTIVO_ULTIMA_SESION" "$ESTADO_ULTIMA_SESION"
        return 0
    fi

    # La sesión llegó a mostrarse (agotó el tiempo de prueba o se cerró
    # limpiamente): ahora sí tiene sentido preguntar por el teclado.
    if tui_confirmar "¿Funcionaba?" \
"¿Se veía la imagen y respondían el teclado y el ratón con '$backend'?" 12 70 "Sí, todo bien" "No"; then
        backend_marcar_validado "$backend"
        perfil_marcar_bueno
        rm -f "$MOTIVO_ULTIMA_SESION" "$ESTADO_ULTIMA_SESION"
        tui_mensaje "Listo" \
"'$backend' queda confirmado. Las próximas sesiones ya no tendrán límite de tiempo." 10 66
        return 0
    fi

    backend_invalidar "$backend"
    rm -f "$MOTIVO_ULTIMA_SESION" "$ESTADO_ULTIMA_SESION"
    _revertir_backend "$backend"
}

_revertir_backend() {
    local fallido="$1" alternativo

    [[ "$fallido" == "sdl" ]] && alternativo="x11" || alternativo="sdl"

    if ! rdp_backend_disponible "$alternativo"; then
        tui_error "'$fallido' no funciona y no hay ningún otro cliente instalado.

Vuelve a ejecutar el instalador."
        return 1
    fi

    if ! config_guardar_ajuste BACKEND "$alternativo"; then
        tui_error "No se pudo guardar el cambio a «$alternativo» en la tarjeta.

¿Está protegida contra escritura?"
        return 1
    fi
    config_validar
    perfil_resincronizar

    tui_mensaje "Cambiado a '$alternativo'" \
"Se ha vuelto al sistema de vídeo '$alternativo'.

Si quieres volver a intentarlo con '$fallido' más adelante, está en Ajustes → Sistema de vídeo." 13 72
}
