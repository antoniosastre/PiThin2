#!/usr/bin/env bash
# pithin-menus.sh - pantallas de la interfaz de texto.
#
# Todo lo que no sea "encender y conectar" vive aquí: asistente de
# redes, ajustes, credenciales, diagnóstico y apagado.

[[ -n "${PITHIN_MENUS_CARGADO:-}" ]] && return 0
PITHIN_MENUS_CARGADO=1

# shellcheck source=/dev/null
source "${PITHIN_LIB:-/usr/local/lib/pithin}/pithin-tui.sh"
# shellcheck source=/dev/null
source "${PITHIN_LIB:-/usr/local/lib/pithin}/pithin-config.sh"
# shellcheck source=/dev/null
source "${PITHIN_LIB:-/usr/local/lib/pithin}/pithin-wifi.sh"
# shellcheck source=/dev/null
source "${PITHIN_LIB:-/usr/local/lib/pithin}/pithin-vpn.sh"
# shellcheck source=/dev/null
source "${PITHIN_LIB:-/usr/local/lib/pithin}/pithin-rdp.sh"

MOTIVO_ULTIMA_SESION="/run/pithin/ultimo-motivo"

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
"Conexión actual: $(wifi_conectado && wifi_ssid_actual || printf 'ninguna')" 16 72 5 \
            "conectar"  "Conectarse a una red" \
            "guardadas" "Ver las redes guardadas en la tarjeta" \
            "reimportar" "Releer redes.conf de la tarjeta" \
            "estado"    "Ver el estado de la red")" || return 0

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

    if [[ -z "$texto" ]]; then
        texto="No hay ninguna red guardada todavía."
    fi

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
#  Ajustes
# ---------------------------------------------------------------------

menu_ajustes() {
    local eleccion
    while true; do
        eleccion="$(tui_menu "Ajustes" \
"Destino: ${RDP_HOST:-sin definir}   ·   ${RESOLUCION}   ·   códec $CODEC" 18 76 7 \
            "host"       "PC de destino .......... ${RDP_HOST:-sin definir}" \
            "usuario"    "Usuario de Windows ..... ${RDP_USER:-sin definir}" \
            "resolucion" "Resolución ............. $RESOLUCION" \
            "codec"      "Códec de vídeo ......... $CODEC" \
            "teclado"    "Teclado ................ $TECLADO" \
            "autoconectar" "Conectar al encender ... $AUTOCONECTAR" \
            "sonido"     "Sonido remoto .......... $SONIDO")" || return 0

        case "$eleccion" in
            host)       _ajustar_texto RDP_HOST "PC de destino" \
"Nombre del PC en tu red de Tailscale, o su dirección 100.x.y.z" ;;
            usuario)    _ajustar_texto RDP_USER "Usuario de Windows" \
"Cuenta local:      Antonio
Cuenta Microsoft:  MicrosoftAccount\\\\tu@correo.com" ;;
            resolucion) _ajustar_resolucion ;;
            codec)      _ajustar_codec ;;
            teclado)    _ajustar_teclado ;;
            autoconectar) _alternar AUTOCONECTAR "Conectar al encender" ;;
            sonido)     _alternar SONIDO "Sonido remoto" ;;
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
    local clave="$1" titulo="$2" nuevo
    if es_si "${!clave}"; then nuevo="no"; else nuevo="si"; fi
    config_guardar_ajuste "$clave" "$nuevo" \
        || tui_error "No se pudo guardar el ajuste."
}

_ajustar_resolucion() {
    local eleccion
    eleccion="$(tui_menu "Resolución" \
"Es el ajuste que más influye en la fluidez.

Si la sesión va pesada o el WiFi está saturado, baja a 1280x720: se transmiten menos de la mitad de píxeles y la imagen se escala para seguir llenando la pantalla." 19 76 4 \
        "1920x1080" "Nítido. Recomendado para trabajo de escritorio" \
        "1600x900"  "Punto intermedio" \
        "1280x720"  "Bastante más fluido. Para WiFi flojo" \
        "1024x768"  "Mínimo. Solo si todo lo demás va mal")" || return 0
    [[ -n "$eleccion" ]] || return 0
    config_guardar_ajuste RESOLUCION "$eleccion" && config_validar
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
    config_guardar_ajuste CODEC "$eleccion" && config_validar
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
    config_guardar_ajuste TECLADO "$eleccion" && config_validar
    setxkbmap "$eleccion" 2>/dev/null || loadkeys "$eleccion" >/dev/null 2>&1 || true
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

    informe+=$'\n'"PROGRAMAS"$'\n'
    informe+="  $(rdp_disponible && printf '[ok]' || printf '[--]')  FreeRDP"$'\n'
    informe+="  $(hay_comando argon2 && printf '[ok]' || printf '[--]')  argon2"$'\n'
    informe+="  $(hay_comando Xorg && printf '[ok]' || printf '[--]')  Xorg"$'\n'

    informe+=$'\n'"MEMORIA"$'\n'
    informe+="  $(free -h | awk '/^Mem:/{print "total " $2 "  ·  libre " $7}')"$'\n'

    tui_mensaje "Diagnóstico" "$informe" 26 76
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
    "${SHELL:-/bin/bash}" -l || true
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
    local eleccion motivo

    while true; do
        # Si la sesión anterior terminó mal, lo explicamos una sola vez.
        if [[ -s "$MOTIVO_ULTIMA_SESION" ]]; then
            motivo="$(cat "$MOTIVO_ULTIMA_SESION")"
            rm -f "$MOTIVO_ULTIMA_SESION"
            tui_mensaje "Se cerró la sesión" "$motivo" 14 74
        fi

        eleccion="$(tui_menu "Menú principal" \
"$(wifi_conectado && printf 'WiFi: %s' "$(wifi_ssid_actual)" || printf 'WiFi: sin conexión')   ·   Tailscale: $(vpn_estado)
Destino: ${RDP_HOST:-sin definir}" 19 76 6 \
            "conectar"    "Conectar con mi PC" \
            "redes"       "Redes WiFi" \
            "ajustes"     "Ajustes de la conexión" \
            "credenciales" "Contraseña de Windows y PIN" \
            "diagnostico" "Diagnóstico" \
            "sistema"     "Sistema")" || { menu_sistema; continue; }

        case "$eleccion" in
            conectar)     lanzar_sesion || true ;;
            redes)        menu_redes ;;
            ajustes)      menu_ajustes ;;
            credenciales) menu_credenciales ;;
            diagnostico)  menu_diagnostico ;;
            sistema)      menu_sistema ;;
            "")           menu_sistema ;;
        esac
    done
}

# ---------------------------------------------------------------------
#  Lanzamiento de la sesión gráfica
# ---------------------------------------------------------------------

# Pide el PIN en la consola de texto, arranca X y espera a que la
# sesión termine. El secreto viaja por un fichero en tmpfs porque
# whiptail necesita un terminal de verdad y dentro de X no lo hay.
lanzar_sesion() {
    if ! config_completa; then
        tui_error "Falta por configurar el PC de destino.

Ve a Ajustes y rellena el nombre del PC y el usuario de Windows."
        return 1
    fi

    if ! rdp_disponible; then
        tui_error "FreeRDP no está instalado. Vuelve a ejecutar el instalador."
        return 1
    fi

    if ! vpn_activa; then
        if ! tui_confirmar "Tailscale no está activo" \
"Tailscale está en estado '$(vpn_estado)', así que probablemente no se pueda llegar al PC.

¿Intentarlo de todas formas?" 13 70; then
            return 1
        fi
    fi

    tui_preparar_secreto || return 1

    clear
    printf '\n  Conectando con %s...\n\n' "$RDP_HOST"

    # -keeptty deja los mensajes de X en esta consola en vez de saltar a
    # otra, lo que hace mucho más fácil ver qué ha fallado.
    startx "$PITHIN_LIB/xinitrc" -- :0 vt1 -keeptty -nolisten tcp \
        >/run/pithin/xorg.log 2>&1 || true

    tui_olvidar_secreto
    return 0
}
