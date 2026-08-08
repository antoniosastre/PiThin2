#!/usr/bin/env bash
# pithin-wifi.sh - redes conocidas y asistente de conexión.
#
# Las redes se declaran en redes.conf (partición de arranque, editable
# desde cualquier ordenador) y se importan a NetworkManager en cada
# arranque. NetworkManager es quien decide a cuál conectarse según la
# prioridad y lo que haya al alcance.

[[ -n "${PITHIN_WIFI_CARGADO:-}" ]] && return 0
PITHIN_WIFI_CARGADO=1

# shellcheck source=/dev/null
source "${PITHIN_LIB:-/usr/local/lib/pithin}/pithin-common.sh"

# Prefijo de los perfiles que gestionamos nosotros. Nos permite
# reimportar sin tocar conexiones creadas a mano por el usuario.
WIFI_PREFIJO="pithin-"

# ---------------------------------------------------------------------
#  Interfaz
# ---------------------------------------------------------------------

wifi_interfaz() {
    local dev
    dev="$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null \
           | awk -F: '$2=="wifi" {print $1; exit}')"
    printf '%s' "${dev:-wlan0}"
}

wifi_conectado() {
    local dev estado
    dev="$(wifi_interfaz)"
    estado="$(nmcli -t -f DEVICE,STATE device status 2>/dev/null \
              | awk -F: -v d="$dev" '$1==d {print $2; exit}')"
    [[ "$estado" == "connected" ]]
}

wifi_ssid_actual() {
    nmcli -t -f ACTIVE,SSID device wifi list --rescan no 2>/dev/null \
        | sed 's/\\:/\x01/g' \
        | awk -F: '$1=="yes" {print $2; exit}' \
        | tr '\x01' ':'
}

# Espera hasta que haya conexión o se agote el tiempo.
wifi_esperar_conexion() {
    local limite="${1:-25}" transcurrido=0
    log_info "Esperando conexión WiFi (hasta ${limite}s)..."
    while (( transcurrido < limite )); do
        if wifi_conectado; then
            log_info "Conectado a la red: $(wifi_ssid_actual)"
            return 0
        fi
        sleep 2
        transcurrido=$((transcurrido + 2))
    done
    log_aviso "No se consiguió conexión WiFi en ${limite}s."
    return 1
}

# ---------------------------------------------------------------------
#  Importación de redes.conf
# ---------------------------------------------------------------------

# Analiza redes.conf y llama a la función indicada por cada red con los
# argumentos: SSID, clave, prioridad, oculta.
_wifi_recorrer_fichero() {
    local fichero="$1" callback="$2"
    [[ -r "$fichero" ]] || return 1

    local ssid="" clave="" prioridad="50" oculta="no"
    local linea limpia

    _emitir() {
        [[ -n "$ssid" ]] || return 0
        "$callback" "$ssid" "$clave" "$prioridad" "$oculta"
    }

    while IFS= read -r linea || [[ -n "$linea" ]]; do
        limpia="$(recortar "${linea%$'\r'}")"
        [[ -z "$limpia" || "$limpia" == \#* || "$limpia" == \;* ]] && continue

        if [[ "$limpia" =~ ^\[(.+)\]$ ]]; then
            _emitir
            ssid="$(recortar "${BASH_REMATCH[1]}")"
            clave=""; prioridad="50"; oculta="no"
            continue
        fi

        if [[ "$limpia" =~ ^([A-Za-z_]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            local campo valor
            campo="$(recortar "${BASH_REMATCH[1]}")"
            campo="${campo,,}"
            valor="$(recortar "${BASH_REMATCH[2]}")"
            case "$campo" in
                clave|password|psk) clave="$valor" ;;
                prioridad|priority) [[ "$valor" =~ ^-?[0-9]+$ ]] && prioridad="$valor" ;;
                oculta|hidden)      oculta="$valor" ;;
            esac
        fi
    done <"$fichero"

    _emitir
    unset -f _emitir
    return 0
}

# Crea o reemplaza el perfil de NetworkManager de una red.
_wifi_definir_perfil() {
    local ssid="$1" clave="$2" prioridad="$3" oculta="$4"
    local nombre="${WIFI_PREFIJO}${ssid}"
    local dev; dev="$(wifi_interfaz)"

    # Borrar y recrear es más sencillo y más fiable que intentar
    # reconciliar campo a campo un perfil que quizá cambió de tipo de
    # seguridad desde la última vez.
    nmcli connection delete "$nombre" >/dev/null 2>&1 || true

    # Propiedades que van tras el "--" de nmcli connection add.
    local -a props=(
        connection.autoconnect yes
        connection.autoconnect-priority "$prioridad"
    )

    es_si "$oculta" && props+=(802-11-wireless.hidden yes)

    if [[ -n "$clave" ]]; then
        props+=(
            802-11-wireless-security.key-mgmt wpa-psk
            802-11-wireless-security.psk "$clave"
        )
    fi

    if nmcli connection add type wifi con-name "$nombre" ifname "$dev" \
            ssid "$ssid" -- "${props[@]}" >/dev/null 2>&1; then
        log_info "Red importada: $ssid (prioridad $prioridad)"
        return 0
    fi

    log_aviso "No se pudo importar la red '$ssid'."
    return 1
}

# Importa todas las redes del fichero. Elimina primero los perfiles
# nuestros que ya no figuren, para que borrar una red del fichero surta
# efecto de verdad.
wifi_importar_redes() {
    local fichero="${1:-$PITHIN_REDES}"

    if [[ ! -r "$fichero" ]]; then
        log_aviso "No hay fichero de redes en $fichero."
        return 1
    fi

    log_info "Importando redes desde $fichero"

    local -A declaradas=()
    # shellcheck disable=SC2317  # se invoca indirectamente desde _wifi_recorrer_fichero
    _wifi_marcar() { declaradas["$1"]=1; }
    _wifi_recorrer_fichero "$fichero" _wifi_marcar
    unset -f _wifi_marcar

    local nombre ssid
    while IFS= read -r nombre; do
        [[ "$nombre" == "$WIFI_PREFIJO"* ]] || continue
        ssid="${nombre#"$WIFI_PREFIJO"}"
        if [[ -z "${declaradas[$ssid]:-}" ]]; then
            nmcli connection delete "$nombre" >/dev/null 2>&1 \
                && log_info "Red retirada (ya no está en el fichero): $ssid"
        fi
    done < <(nmcli -t -f NAME connection show 2>/dev/null | sed 's/\\:/:/g')

    _wifi_recorrer_fichero "$fichero" _wifi_definir_perfil
    return 0
}

# ---------------------------------------------------------------------
#  Asistente para redes nuevas
# ---------------------------------------------------------------------

# Imprime una línea por red: SSID<TAB>señal<TAB>seguridad
wifi_escanear() {
    local dev; dev="$(wifi_interfaz)"
    nmcli device wifi rescan ifname "$dev" >/dev/null 2>&1 || true
    sleep 2
    nmcli -t -f SSID,SIGNAL,SECURITY device wifi list ifname "$dev" --rescan no 2>/dev/null \
        | sed 's/\\:/\x01/g' \
        | awk -F: 'NF>=3 && $1!="" {print $1 "\t" $2 "\t" $3}' \
        | tr '\x01' ':' \
        | sort -t$'\t' -k2 -rn \
        | awk -F'\t' '!vista[$1]++'
}

# Conecta a una red nueva. Si funciona, deja el perfil creado para la
# próxima vez.
wifi_conectar_nueva() {
    local ssid="$1" clave="$2" oculta="${3:-no}"
    local dev; dev="$(wifi_interfaz)"

    log_info "Conectando a '$ssid'..."

    local -a args=(device wifi connect "$ssid" ifname "$dev" name "${WIFI_PREFIJO}${ssid}")
    [[ -n "$clave" ]] && args+=(password "$clave")
    es_si "$oculta" && args+=(hidden yes)

    local salida
    if salida="$(nmcli "${args[@]}" 2>&1)"; then
        log_info "Conectado a '$ssid'."
        return 0
    fi

    log_aviso "No se pudo conectar a '$ssid': $salida"
    nmcli connection delete "${WIFI_PREFIJO}${ssid}" >/dev/null 2>&1 || true
    return 1
}

# Añade una red al fichero de la SD para que en el próximo arranque
# entre sola. No duplica si ya estaba.
wifi_guardar_en_fichero() {
    # OJO con los nombres de estas variables: bash tiene ámbito
    # dinámico, así que las locales de _wifi_recorrer_fichero (ssid,
    # clave, prioridad, oculta) tapan a las de aquí dentro del callback.
    # Por eso llevan el prefijo "nueva_".
    local nueva_ssid="$1" nueva_clave="$2" nueva_oculta="${3:-no}"
    local fichero="${4:-$PITHIN_REDES}"

    if ! boot_escribible; then
        log_aviso "La partición de arranque es de solo lectura: la red no se guardará."
        return 1
    fi

    local ya=0
    # shellcheck disable=SC2317  # se invoca indirectamente desde _wifi_recorrer_fichero
    _wifi_comparar() { [[ "$1" == "$nueva_ssid" ]] && ya=1; }
    _wifi_recorrer_fichero "$fichero" _wifi_comparar
    unset -f _wifi_comparar

    if (( ya )); then
        log_info "'$nueva_ssid' ya figuraba en el fichero de redes."
        return 0
    fi

    install -d -m 0755 "$(dirname "$fichero")" 2>/dev/null || true

    local -a lineas=(
        ""
        "[$nueva_ssid]"
        "clave = $nueva_clave"
        "prioridad = 50"
    )
    es_si "$nueva_oculta" && lineas+=("oculta = si")

    # printf de una sola vez: si se dejara el 'es_si' como última orden
    # del grupo, su "no" haría creer que la escritura ha fallado.
    if ! printf '%s\n' "${lineas[@]}" >>"$fichero" 2>/dev/null; then
        log_aviso "No se pudo escribir en $fichero."
        return 1
    fi

    sync
    log_info "Red '$nueva_ssid' guardada para próximos arranques."
    return 0
}

wifi_olvidar() {
    local ssid="$1"
    nmcli connection delete "${WIFI_PREFIJO}${ssid}" >/dev/null 2>&1
}

# Lista las redes conocidas: SSID<TAB>prioridad
wifi_listar_guardadas() {
    # shellcheck disable=SC2317  # se invoca indirectamente desde _wifi_recorrer_fichero
    _wifi_listar_una() { printf '%s\t%s\n' "$1" "$3"; }
    _wifi_recorrer_fichero "${1:-$PITHIN_REDES}" _wifi_listar_una
    unset -f _wifi_listar_una
}
