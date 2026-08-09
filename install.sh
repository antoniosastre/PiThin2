#!/usr/bin/env bash
# =====================================================================
#  PiThin - instalador (Fase A)
# =====================================================================
#
#  Convierte una Raspberry Pi OS Lite recién instalada en un cliente
#  ligero de escritorio remoto.
#
#  Uso:
#      sudo ./install.sh                  instalación completa
#      sudo ./install.sh --sin-tailscale  omite Tailscale
#      sudo ./install.sh --solo-ficheros  solo copia scripts (iterar rápido)
#      sudo ./install.sh --desinstalar    deshace los cambios
#
#  Es idempotente: se puede volver a ejecutar tantas veces como haga
#  falta. Es justo lo que se hace al ajustar algo durante las pruebas.
#
#  Estos mismos pasos son los que se empaquetarán como fase de pi-gen
#  para producir la imagen flasheable (Fase B).
# =====================================================================

set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DESTINO_LIB="/usr/local/lib/pithin"
DESTINO_BIN="/usr/local/bin"

if [[ -d /boot/firmware ]]; then
    DESTINO_BOOT="/boot/firmware/pithin"
    FICHERO_CONFIG_TXT="/boot/firmware/config.txt"
else
    DESTINO_BOOT="/boot/pithin"
    FICHERO_CONFIG_TXT="/boot/config.txt"
fi

INSTALAR_TAILSCALE=1
INSTALAR_PAQUETES=1
CONFIGURAR_SISTEMA=1
DESINSTALAR=0

# ---------------------------------------------------------------------
#  Salida por pantalla
# ---------------------------------------------------------------------

if [[ -t 1 ]]; then
    C_OK=$'\033[32m'; C_AV=$'\033[33m'; C_ER=$'\033[31m'
    C_TI=$'\033[1;36m'; C_FIN=$'\033[0m'
else
    C_OK=""; C_AV=""; C_ER=""; C_TI=""; C_FIN=""
fi

titulo() { printf '\n%s==> %s%s\n' "$C_TI" "$*" "$C_FIN"; }
ok()     { printf '    %s[ok]%s %s\n' "$C_OK" "$C_FIN" "$*"; }
aviso()  { printf '    %s[!]%s  %s\n' "$C_AV" "$C_FIN" "$*"; }
error()  { printf '    %s[X]%s  %s\n' "$C_ER" "$C_FIN" "$*" >&2; }
fatal()  { error "$*"; exit 1; }

# ---------------------------------------------------------------------
#  Argumentos
# ---------------------------------------------------------------------

for arg in "$@"; do
    case "$arg" in
        --sin-tailscale) INSTALAR_TAILSCALE=0 ;;
        --sin-paquetes)  INSTALAR_PAQUETES=0 ;;
        --solo-ficheros) INSTALAR_PAQUETES=0; INSTALAR_TAILSCALE=0; CONFIGURAR_SISTEMA=0 ;;
        --desinstalar)   DESINSTALAR=1 ;;
        -h|--help)
            # 2,20: solo el bloque de comentario de cabecera. Hasta la 22
            # colaba la línea 'set -euo pipefail' al final de la ayuda.
            sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,2\}//'
            exit 0 ;;
        *) fatal "Argumento desconocido: $arg (usa --help)" ;;
    esac
done

# ---------------------------------------------------------------------
#  Comprobaciones previas
# ---------------------------------------------------------------------

comprobaciones() {
    titulo "Comprobaciones previas"

    [[ "$(id -u)" -eq 0 ]] || fatal "Hay que ejecutarlo con sudo."

    if [[ ! -e /proc/device-tree/model ]]; then
        aviso "Esto no parece una Raspberry Pi. Se continúa, pero puede fallar."
    else
        ok "$(tr -d '\0' </proc/device-tree/model)"
    fi

    if ! grep -qi 'debian\|raspbian' /etc/os-release 2>/dev/null; then
        aviso "Sistema no reconocido. Pensado para Raspberry Pi OS."
    else
        ok "$(. /etc/os-release && printf '%s' "$PRETTY_NAME")"
    fi

    local total_mb
    total_mb=$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo)
    ok "Memoria: ${total_mb} MB"
    if (( total_mb < 400 )); then
        aviso "Muy poca memoria. La sesión a 1080p puede no caber."
    fi

    if [[ -d /boot/firmware ]]; then
        ok "Partición de arranque en /boot/firmware"
    else
        aviso "No existe /boot/firmware; se usará /boot (sistema antiguo)."
    fi
}

# ---------------------------------------------------------------------
#  Paquetes
# ---------------------------------------------------------------------

PAQUETES_BASE=(
    xserver-xorg-core
    xserver-xorg-input-libinput
    xserver-xorg-video-fbdev
    xinit
    x11-xserver-utils
    x11-xkb-utils
    whiptail
    argon2
    openssl
    network-manager
    ca-certificates
    curl
    console-setup
)

instalar_paquetes() {
    titulo "Instalando programas"

    export DEBIAN_FRONTEND=noninteractive

    ok "Actualizando la lista de paquetes..."
    apt-get update -qq || aviso "apt-get update dio error; se sigue con lo que haya en caché."

    ok "Instalando la base (Xorg mínimo, herramientas y cifrado)..."
    apt-get install -y --no-install-recommends "${PAQUETES_BASE[@]}" \
        || fatal "No se pudieron instalar los paquetes base."

    # Se instalan LOS DOS clientes. El de SDL prescinde del servidor X
    # y es el que se usa por defecto; el de X11 se queda como red de
    # seguridad conmutable desde el menú, porque el fallo típico de
    # SDL/KMSDRM es que la imagen aparezca pero el teclado no responda,
    # y de eso no se sale desde dentro de la sesión.
    local clientes=0

    if apt-get install -y --no-install-recommends freerdp3-sdl 2>/dev/null; then
        ok "Cliente SDL/KMSDRM instalado (sin servidor X)."
        clientes=$((clientes + 1))

        # libudev1 solo figura como recomendado de libsdl3, y con
        # --no-install-recommends se quedaría fuera. SDL lo necesita para
        # detectar teclados y ratones: sin él, la entrada no funciona.
        apt-get install -y libudev1 >/dev/null 2>&1 || \
            aviso "No se pudo asegurar libudev1; la entrada por SDL podría no funcionar."
    else
        aviso "No hay paquete freerdp3-sdl; se irá solo por X11."
    fi

    # FreeRDP 3 es el que trae /args-from, que usamos para no exponer la
    # contraseña en la línea de órdenes. Si no está disponible caemos a
    # la versión 2, que también funciona.
    if apt-get install -y --no-install-recommends freerdp3-x11 2>/dev/null; then
        ok "Cliente X11 instalado (respaldo)."
        clientes=$((clientes + 1))
    elif apt-get install -y --no-install-recommends freerdp2-x11 2>/dev/null; then
        aviso "Solo hay FreeRDP 2 para X11. Funciona, pero la contraseña será visible en la lista de procesos."
        clientes=$((clientes + 1))
    fi

    (( clientes > 0 )) || fatal "No se pudo instalar ningún cliente FreeRDP."

    # zram: comprime memoria en RAM en vez de tirar de la tarjeta SD.
    # Con 512 MB es el colchón que evita quedarse sin memoria al abrir
    # la sesión a 1080p.
    if apt-get install -y --no-install-recommends zram-tools 2>/dev/null; then
        ok "zram-tools instalado."
    else
        aviso "No se pudo instalar zram-tools; se seguirá sin compresión de memoria."
    fi
}

instalar_tailscale() {
    titulo "Instalando Tailscale"

    if command -v tailscale >/dev/null 2>&1; then
        ok "Ya estaba instalado ($(tailscale version 2>/dev/null | head -n1))."
        return 0
    fi

    local nombre_version id_distro
    nombre_version="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"
    id_distro="$(. /etc/os-release && printf '%s' "${ID:-debian}")"

    # Tailscale publica repositorios separados para Raspberry Pi OS y
    # para Debian puro.
    local ruta_repo="debian"
    [[ "$id_distro" == "raspbian" ]] && ruta_repo="raspbian"

    if [[ -z "$nombre_version" ]]; then
        aviso "No se pudo determinar la versión de Debian; se omite Tailscale."
        return 1
    fi

    ok "Añadiendo el repositorio de Tailscale ($ruta_repo/$nombre_version)..."

    install -d -m 0755 /usr/share/keyrings
    if ! curl -fsSL "https://pkgs.tailscale.com/stable/${ruta_repo}/${nombre_version}.noarmor.gpg" \
            -o /usr/share/keyrings/tailscale-archive-keyring.gpg; then
        aviso "No se pudo descargar la clave del repositorio. Se omite Tailscale."
        return 1
    fi

    curl -fsSL "https://pkgs.tailscale.com/stable/${ruta_repo}/${nombre_version}.tailscale-keyring.list" \
        -o /etc/apt/sources.list.d/tailscale.list \
        || { aviso "No se pudo añadir el repositorio."; return 1; }

    apt-get update -qq || true
    if apt-get install -y tailscale; then
        systemctl enable --now tailscaled || true
        ok "Tailscale instalado y arrancado."
    else
        aviso "Falló la instalación de Tailscale."
        return 1
    fi
}

# ---------------------------------------------------------------------
#  Ficheros del proyecto
# ---------------------------------------------------------------------

instalar_ficheros() {
    titulo "Copiando PiThin"

    install -d -m 0755 "$DESTINO_LIB"
    local modulo
    for modulo in common config pantalla perfiles crypto wifi vpn rdp tui menus; do
        install -m 0644 "$RAIZ/src/lib/pithin-${modulo}.sh" "$DESTINO_LIB/"
    done
    install -m 0755 "$RAIZ/src/lib/xinitrc" "$DESTINO_LIB/"
    ok "Módulos en $DESTINO_LIB"

    install -m 0755 "$RAIZ/src/bin/pithin-arranque" "$DESTINO_BIN/"
    install -m 0755 "$RAIZ/src/bin/pithin-sesion"   "$DESTINO_BIN/"
    install -m 0755 "$RAIZ/src/bin/pithin-menu"     "$DESTINO_BIN/"
    ok "Órdenes en $DESTINO_BIN"

    install -d -m 0700 /var/lib/pithin
    install -d -m 0755 /etc/pithin

    # /run es tmpfs: ahí van la contraseña descifrada y los argumentos
    # de FreeRDP, para que nunca toquen la tarjeta SD.
    printf 'd /run/pithin 0700 root root -\n' >/etc/tmpfiles.d/pithin.conf
    systemd-tmpfiles --create /etc/tmpfiles.d/pithin.conf >/dev/null 2>&1 || true
    ok "Directorio temporal en RAM configurado"
}

instalar_configuracion_boot() {
    titulo "Preparando la configuración en la tarjeta"

    install -d -m 0755 "$DESTINO_BOOT"

    # Nunca se pisa lo que ya haya: la configuración es del usuario.
    local f
    for f in pithin.conf redes.conf; do
        if [[ -f "$DESTINO_BOOT/$f" ]]; then
            ok "$f ya existía; se respeta."
        else
            install -m 0644 "$RAIZ/boot-ejemplo/$f" "$DESTINO_BOOT/$f"
            ok "$f creado a partir del ejemplo."
        fi
    done

    if [[ -f "$RAIZ/boot-ejemplo/LEEME.txt" ]]; then
        install -m 0644 "$RAIZ/boot-ejemplo/LEEME.txt" "$DESTINO_BOOT/LEEME.txt"
    fi

    ok "Configuración editable en $DESTINO_BOOT"
}

# ---------------------------------------------------------------------
#  Configuración del sistema
# ---------------------------------------------------------------------

configurar_autologin() {
    titulo "Configurando el arranque automático"

    local dir="/etc/systemd/system/getty@tty1.service.d"
    install -d -m 0755 "$dir"
    cat >"$dir/pithin-autologin.conf" <<'FIN'
# Instalado por PiThin. Entra solo en tty1 para poder lanzar el cliente
# sin que nadie tenga que teclear un usuario.
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
FIN
    ok "Inicio de sesión automático en tty1"

    # El lanzamiento va en el perfil de la shell y no en un servicio de
    # systemd a propósito: whiptail necesita un terminal de verdad, con
    # su tamaño y su teclado, y eso lo da la sesión de login.
    #
    # No se usa 'exec': si algo falla, queda una consola de root en
    # lugar de un bucle de reinicios imposible de depurar.
    local perfil="/root/.bash_profile"
    local marca="# --- PiThin ---"

    if [[ -f "$perfil" ]] && grep -qF "$marca" "$perfil"; then
        ok "El perfil de arranque ya estaba puesto."
    else
        cat >>"$perfil" <<FIN

$marca
# PITHIN_NO_AUTOARRANQUE lo pone "Abrir una consola de texto" del menú, para
# que ese shell de login NO vuelva a lanzar PiThin y dé una consola de verdad.
if [ -z "\$PITHIN_NO_AUTOARRANQUE" ] && [ "\$(tty)" = "/dev/tty1" ] && [ -x $DESTINO_BIN/pithin-arranque ]; then
    $DESTINO_BIN/pithin-arranque
    echo
    echo "PiThin ha terminado. Escribe 'pithin-menu' para volver al menú."
fi
# --- fin PiThin ---
FIN
        ok "Perfil de arranque instalado en $perfil"
    fi
}

configurar_xorg() {
    titulo "Configurando Xorg"

    install -d -m 0755 /etc/X11

    # startx desde una sesión de consola necesita este permiso explícito
    # en Debian.
    cat >/etc/X11/Xwrapper.config <<'FIN'
# Instalado por PiThin.
allowed_users=anybody
needs_root_rights=yes
FIN
    ok "Xwrapper configurado"

    # Sin gestor de ventanas no hay nada que apague la pantalla de forma
    # ordenada, así que se desactiva el ahorro de energía desde el
    # propio servidor X. Un terminal que se queda en negro a los diez
    # minutos parecería estropeado.
    install -d -m 0755 /etc/X11/xorg.conf.d
    cat >/etc/X11/xorg.conf.d/10-pithin-pantalla.conf <<'FIN'
# Instalado por PiThin.
Section "ServerFlags"
    Option "BlankTime"   "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime"     "0"
EndSection
FIN
    ok "Salvapantallas desactivado"
}

configurar_memoria() {
    titulo "Ajustando la memoria"

    if [[ -f /etc/default/zramswap ]]; then
        # Copia de seguridad una sola vez, para poder revertir al
        # desinstalar (el original tiene los valores que trajo la distro).
        [[ -f /etc/default/zramswap.pithin.bak ]] \
            || cp -a /etc/default/zramswap /etc/default/zramswap.pithin.bak
        # Con 512 MB, comprimir la mitad de la RAM da un margen real sin
        # penalizar demasiado: zstd descomprime muy rápido incluso en
        # un Cortex-A53.
        sed -i 's/^#\?ALGO=.*/ALGO=zstd/'    /etc/default/zramswap
        sed -i 's/^#\?PERCENT=.*/PERCENT=50/' /etc/default/zramswap
        systemctl restart zramswap 2>/dev/null || true
        ok "zram configurado (zstd, 50% de la RAM)"
    else
        aviso "zram-tools no está instalado; se omite."
    fi

    # Cuanta menos presión de escritura sobre la tarjeta, mejor: con
    # zram, el intercambio es barato y conviene usarlo antes de tirar
    # cachés que sí hacen falta.
    cat >/etc/sysctl.d/60-pithin.conf <<'FIN'
# Instalado por PiThin.
vm.swappiness=100
vm.vfs_cache_pressure=50
FIN
    sysctl -p /etc/sysctl.d/60-pithin.conf >/dev/null 2>&1 || true
    ok "Parámetros de memoria ajustados"
}

configurar_arranque_firmware() {
    titulo "Ajustando el arranque"

    [[ -f "$FICHERO_CONFIG_TXT" ]] || { aviso "No se encuentra $FICHERO_CONFIG_TXT."; return 0; }

    local marca="# --- PiThin ---"
    if grep -qF "$marca" "$FICHERO_CONFIG_TXT"; then
        ok "config.txt ya estaba ajustado."
        return 0
    fi

    cp -a "$FICHERO_CONFIG_TXT" "${FICHERO_CONFIG_TXT}.pithin.bak"

    cat >>"$FICHERO_CONFIG_TXT" <<'FIN'

# --- PiThin ---
# Salida HDMI aunque el monitor se enchufe después de encender.
hdmi_force_hotplug=1
# Sin bordes negros en televisores y monitores modernos.
disable_overscan=1
# Arranque sin logotipo, para que se vean los mensajes de PiThin.
disable_splash=1
# --- fin PiThin ---
FIN
    ok "config.txt ajustado (copia de seguridad en ${FICHERO_CONFIG_TXT}.pithin.bak)"
}

aligerar_servicios() {
    titulo "Aligerando servicios"

    # triggerhappy vigila teclas globales; aquí no hace nada y ocupa
    # memoria. El Bluetooth se deja en paz a propósito, por si se usa
    # un teclado inalámbrico.
    local s
    local -a prescindibles=(triggerhappy)
    for s in "${prescindibles[@]}"; do
        if systemctl list-unit-files "$s.service" >/dev/null 2>&1 \
           && systemctl is-enabled "$s" >/dev/null 2>&1; then
            systemctl disable --now "$s" >/dev/null 2>&1 || true
            # Marca de que lo desactivamos NOSOTROS: así la desinstalación
            # solo reactiva lo que estaba activo antes, no lo que el usuario
            # ya tenía apagado.
            install -d -m 0700 /var/lib/pithin 2>/dev/null || true
            : >"/var/lib/pithin/.desactivado-$s" 2>/dev/null || true
            ok "$s desactivado"
        fi
    done

    # El registro en disco desgasta la tarjeta; en RAM basta y sobra
    # para un equipo que se apaga a diario.
    install -d -m 0755 /etc/systemd/journald.conf.d
    cat >/etc/systemd/journald.conf.d/pithin.conf <<'FIN'
# Instalado por PiThin.
[Journal]
Storage=volatile
RuntimeMaxUse=16M
FIN
    ok "Registro del sistema en memoria"
}

# ---------------------------------------------------------------------
#  Desinstalación
# ---------------------------------------------------------------------

desinstalar() {
    titulo "Desinstalando PiThin"

    rm -f "$DESTINO_BIN"/pithin-arranque "$DESTINO_BIN"/pithin-sesion "$DESTINO_BIN"/pithin-menu
    rm -rf "$DESTINO_LIB"
    rm -f /etc/systemd/system/getty@tty1.service.d/pithin-autologin.conf
    rm -f /etc/X11/xorg.conf.d/10-pithin-pantalla.conf
    rm -f /etc/sysctl.d/60-pithin.conf
    rm -f /etc/tmpfiles.d/pithin.conf
    rm -f /etc/systemd/journald.conf.d/pithin.conf
    ok "Ficheros del programa eliminados"

    # Xwrapper.config lo crea PiThin (allowed_users=anybody, con implicación
    # de seguridad para Xorg). Se quita solo si lleva nuestra marca, para no
    # tocar uno que hubiera puesto el usuario.
    if [[ -f /etc/X11/Xwrapper.config ]] \
       && grep -qF "Instalado por PiThin" /etc/X11/Xwrapper.config; then
        rm -f /etc/X11/Xwrapper.config
        ok "Xwrapper.config eliminado"
    fi

    # zramswap: se restaura el fichero original que se respaldó al instalar.
    if [[ -f /etc/default/zramswap.pithin.bak ]]; then
        mv -f /etc/default/zramswap.pithin.bak /etc/default/zramswap
        systemctl restart zramswap 2>/dev/null || true
        ok "Configuración de zram restaurada"
    fi

    # Reactiva SOLO los servicios que PiThin desactivó (los que dejaron
    # marca), para no encender uno que el usuario ya tenía apagado antes.
    local marca svc
    for marca in /var/lib/pithin/.desactivado-*; do
        [[ -e "$marca" ]] || continue
        svc="${marca##*/.desactivado-}"
        systemctl enable --now "$svc" >/dev/null 2>&1 || true
        rm -f "$marca"
        ok "$svc reactivado"
    done

    if [[ -f /root/.bash_profile ]]; then
        sed -i '/# --- PiThin ---/,/# --- fin PiThin ---/d' /root/.bash_profile
        ok "Perfil de arranque limpiado"
    fi

    if [[ -f "${FICHERO_CONFIG_TXT}.pithin.bak" ]]; then
        mv -f "${FICHERO_CONFIG_TXT}.pithin.bak" "$FICHERO_CONFIG_TXT"
        ok "config.txt restaurado"
    fi

    # El modo de salida de pantalla se fija en cmdline.txt. Dejarlo
    # puesto tras desinstalar sería desconcertante.
    local cmdline="${FICHERO_CONFIG_TXT%/config.txt}/cmdline.txt"
    if [[ -f "${cmdline}.pithin.bak" ]]; then
        mv -f "${cmdline}.pithin.bak" "$cmdline"
        sync
        ok "cmdline.txt restaurado"
    fi

    aviso "Se conservan la configuración de $DESTINO_BOOT y la credencial de /var/lib/pithin."
    aviso "Bórralos a mano si quieres dejarlo todo limpio."

    systemctl daemon-reload || true
    printf '\nHecho. Reinicia para volver al comportamiento normal.\n\n'
}

# ---------------------------------------------------------------------
#  Resumen final
# ---------------------------------------------------------------------

resumen() {
    local host usuario
    host="$(grep -m1 '^RDP_HOST' "$DESTINO_BOOT/pithin.conf" 2>/dev/null | cut -d'"' -f2 || true)"
    usuario="$(grep -m1 '^RDP_USER' "$DESTINO_BOOT/pithin.conf" 2>/dev/null | cut -d'"' -f2 || true)"

    cat <<FIN

${C_TI}=====================================================================${C_FIN}
  Instalación terminada
${C_TI}=====================================================================${C_FIN}

  Faltan tres cosas antes de reiniciar:

  1. EDITAR LA CONFIGURACIÓN
     $DESTINO_BOOT/pithin.conf
       RDP_HOST  -> nombre de tu PC en Tailscale   (ahora: ${host:-sin definir})
       RDP_USER  -> usuario de Windows             (ahora: ${usuario:-sin definir})

     $DESTINO_BOOT/redes.conf
       Tus redes WiFi.

     Los dos ficheros se pueden editar metiendo la tarjeta en
     cualquier ordenador.

  2. AUTENTICAR TAILSCALE
     Crea una auth key CON ETIQUETA en el panel de Tailscale y
     déjala en:
       $DESTINO_BOOT/tailscale-authkey.txt

     Se usa una sola vez y se borra sola. La etiqueta importa: sin
     ella la clave caduca a los 180 días y la Raspberry se queda
     inaccesible. Ver docs/windows.md

     También puedes autenticar a mano ahora:
       sudo tailscale up

  3. PREPARAR EL PC CON WINDOWS
     Escritorio Remoto activado, Tailscale instalado y el firewall
     permitiendo el 3389 desde 100.64.0.0/10. Paso a paso en
     docs/windows.md

  Después:
       sudo reboot

  En el primer arranque:

     · Se usará el sistema de vídeo SDL/KMSDRM, sin servidor X.
       La primera sesión se abrirá con TIEMPO LIMITADO y después se
       te preguntará si respondía el teclado. Si no, se vuelve solo
       a X11. Es la única forma segura de estrenar KMSDRM.

     · Pulsa una tecla en los primeros 3 segundos para entrar al
       menú en vez de conectar directamente.

     · Si la sesión va pesada: Perfil de sesión -> Máxima fluidez.

  Órdenes útiles:
       pithin-menu     abre el menú sin reiniciar
       tail -f /var/log/pithin.log

FIN
}

# ---------------------------------------------------------------------
#  Programa principal
# ---------------------------------------------------------------------

main() {
    if (( DESINSTALAR )); then
        [[ "$(id -u)" -eq 0 ]] || fatal "Hay que ejecutarlo con sudo."
        desinstalar
        exit 0
    fi

    comprobaciones

    # Con 'set -e' hay que usar if y no '&&': una condición aritmética
    # falsa cuenta como orden fallida y abortaría la instalación al
    # pasar --sin-paquetes.
    if (( INSTALAR_PAQUETES )); then
        instalar_paquetes
    fi

    if (( INSTALAR_TAILSCALE )); then
        instalar_tailscale || aviso "Se continúa sin Tailscale."
    fi

    instalar_ficheros
    instalar_configuracion_boot

    if (( CONFIGURAR_SISTEMA )); then
        configurar_autologin
        configurar_xorg
        configurar_memoria
        configurar_arranque_firmware
        aligerar_servicios
        systemctl daemon-reload || true
    fi

    resumen
}

main "$@"
