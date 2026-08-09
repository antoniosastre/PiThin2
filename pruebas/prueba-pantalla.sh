#!/usr/bin/env bash
# =====================================================================
#  Pruebas de perfiles y de la manipulación de cmdline.txt
# =====================================================================
#
#  cmdline.txt es el fichero más peligroso del proyecto: es de una sola
#  línea, se lee antes que nada al arrancar, y estropearlo deja el
#  equipo sin arrancar y obliga a sacar la tarjeta. Aquí se comprueba
#  que las salvaguardas hacen su trabajo.
#
#  Uso:  ./pruebas/prueba-pantalla.sh
#
#  Este fichero sustituye funciones de los módulos por dobles de prueba
#  y fija variables que consumen los módulos, no él. El analizador
#  estático no ve ninguna de las dos cosas; de ahí la excepción.
# shellcheck disable=SC2317,SC2034

set -uo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BANCO="$(mktemp -d)"
trap 'rm -rf "$BANCO"' EXIT

export PITHIN_LIB="$RAIZ/src/lib"
export PITHIN_BOOT="$BANCO/boot"
export PITHIN_VAR="$BANCO/var"
export PITHIN_ETC="$BANCO/etc"
export PITHIN_LOG="$BANCO/pithin.log"
export PANTALLA_CMDLINE="$BANCO/boot/cmdline.txt"
export PANTALLA_SYSFS="$BANCO/drm"

mkdir -p "$PITHIN_BOOT" "$PITHIN_VAR" "$PITHIN_ETC" "$PANTALLA_SYSFS"

PASADAS=0
FALLIDAS=0

comprobar() {
    local descripcion="$1" esperado="$2" obtenido="$3"
    if [[ "$esperado" == "$obtenido" ]]; then
        PASADAS=$((PASADAS + 1))
        printf '  \033[32m✓\033[0m %s\n' "$descripcion"
    else
        FALLIDAS=$((FALLIDAS + 1))
        printf '  \033[31m✗\033[0m %s\n' "$descripcion"
        printf '      esperado: [%s]\n' "$esperado"
        printf '      obtenido: [%s]\n' "$obtenido"
    fi
}

comprobar_ok() {
    local descripcion="$1"; shift
    if "$@" >/dev/null 2>&1; then
        PASADAS=$((PASADAS + 1)); printf '  \033[32m✓\033[0m %s\n' "$descripcion"
    else
        FALLIDAS=$((FALLIDAS + 1)); printf '  \033[31m✗\033[0m %s\n' "$descripcion"
    fi
}

comprobar_falla() {
    local descripcion="$1"; shift
    if "$@" >/dev/null 2>&1; then
        FALLIDAS=$((FALLIDAS + 1))
        printf '  \033[31m✗\033[0m %s (debería haber fallado)\n' "$descripcion"
    else
        PASADAS=$((PASADAS + 1)); printf '  \033[32m✓\033[0m %s\n' "$descripcion"
    fi
}

titulo() { printf '\n\033[1;36m%s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------
#  Monitor simulado
# ---------------------------------------------------------------------

CONECTOR="$PANTALLA_SYSFS/card0-HDMI-A-1"
mkdir -p "$CONECTOR"
printf 'connected\n' >"$CONECTOR/status"
printf '1920x1080\n1680x1050\n1280x720\n1024x768\n' >"$CONECTOR/modes"

CMDLINE_ORIGINAL='console=serial0,115200 console=tty1 root=PARTUUID=abcd1234-02 rootfstype=ext4 fsck.repair=yes rootwait quiet'
restaurar_cmdline() {
    printf '%s\n' "$CMDLINE_ORIGINAL" >"$PANTALLA_CMDLINE"
    rm -f "${PANTALLA_CMDLINE}.pithin.bak"
}
restaurar_cmdline

# shellcheck source=/dev/null
source "$PITHIN_LIB/pithin-common.sh"

# En el banco de pruebas no hay partición de arranque de verdad.
boot_escribible() { return 0; }

# shellcheck source=/dev/null
source "$PITHIN_LIB/pithin-pantalla.sh"
# shellcheck source=/dev/null
source "$PITHIN_LIB/pithin-config.sh"
# shellcheck source=/dev/null
source "$PITHIN_LIB/pithin-perfiles.sh"

PITHIN_CONF="$PITHIN_BOOT/pithin.conf"

# ---------------------------------------------------------------------
#  1. Lectura del monitor
# ---------------------------------------------------------------------

titulo "Detección del monitor"

comprobar "detecta el conector"          "HDMI-A-1"  "$(pantalla_conector)"
comprobar "lee la resolución nativa"     "1920x1080" "$(pantalla_resolucion_nativa)"
comprobar "lista todos los modos"        "4"         "$(pantalla_modos_disponibles | wc -l)"
comprobar_ok    "admite un modo anunciado"     pantalla_admite "1280x720"
comprobar_falla "rechaza un modo no anunciado" pantalla_admite "3840x2160"

# Un modo entrelazado (sufijo 'i') NO debe colarse como progresivo: forzar
# el progresivo de una resolución que el monitor solo hace entrelazada da
# pantalla en negro. Es la trampa de recortar 'WxHi' a 'WxH'.
printf '1920x1080i\n1280x720\n' >"$CONECTOR/modes"
comprobar_falla "no admite un modo que el monitor solo anuncia entrelazado" \
    pantalla_admite "1920x1080"
comprobar_ok    "sí admite el progresivo que sí anuncia" pantalla_admite "1280x720"
printf '1920x1080\n1680x1050\n1280x720\n1024x768\n' >"$CONECTOR/modes"

# Monitor desconectado: no debe inventarse nada.
printf 'disconnected\n' >"$CONECTOR/status"
comprobar_falla "sin monitor no detecta conector" pantalla_conector
comprobar_falla "sin monitor no hay resolución"   pantalla_resolucion_nativa
printf 'connected\n' >"$CONECTOR/status"

# ---------------------------------------------------------------------
#  2. Escritura de cmdline.txt
# ---------------------------------------------------------------------

titulo "Modificación de cmdline.txt"

restaurar_cmdline
comprobar "al empezar no hay modo forzado" "" "$(pantalla_modo_forzado)"

pantalla_fijar_modo "1280x720" >/dev/null 2>&1
comprobar "fija el modo pedido" "1280x720" "$(pantalla_modo_forzado)"
comprobar "usa el conector detectado" "1" \
    "$(grep -c 'video=HDMI-A-1:1280x720@60' "$PANTALLA_CMDLINE")"
comprobar "cmdline.txt sigue siendo de una línea" "1" \
    "$(wc -l <"$PANTALLA_CMDLINE")"
comprobar "conserva root=" "1" \
    "$(grep -c 'root=PARTUUID=abcd1234-02' "$PANTALLA_CMDLINE")"
comprobar "conserva el resto de parámetros" "1" \
    "$(grep -c 'fsck.repair=yes' "$PANTALLA_CMDLINE")"
comprobar_ok "hace copia de seguridad" test -f "${PANTALLA_CMDLINE}.pithin.bak"
comprobar "la copia es del original" "$CMDLINE_ORIGINAL" \
    "$(cat "${PANTALLA_CMDLINE}.pithin.bak")"

# Volver a fijar no debe acumular parámetros.
pantalla_fijar_modo "1680x1050" >/dev/null 2>&1
comprobar "cambiar de modo no duplica el parámetro" "1" \
    "$(grep -o 'video=' "$PANTALLA_CMDLINE" | wc -l)"
comprobar "queda el modo nuevo" "1680x1050" "$(pantalla_modo_forzado)"

# Quitar debe dejarlo como estaba.
pantalla_quitar_modo >/dev/null 2>&1
comprobar "quitar elimina el parámetro" "" "$(pantalla_modo_forzado)"
comprobar "al quitar vuelve al original exacto" "$CMDLINE_ORIGINAL" \
    "$(cat "$PANTALLA_CMDLINE")"

# ---------------------------------------------------------------------
#  3. Salvaguardas
# ---------------------------------------------------------------------
# Estas son las que evitan dejar el equipo sin arrancar o sin imagen.

titulo "Salvaguardas"

restaurar_cmdline

# Se comprueba el código EXACTO (1 = formato inválido), no un "distinto de
# cero" cualquiera: si no, borrar la validación de formato no rompería la
# prueba, porque 'muy grande' también lo frenaría pantalla_admite (código 3).
pantalla_fijar_modo "muy grande" >/dev/null 2>&1
comprobar "rechaza una resolución con formato inválido (código 1)" "1" "$?"
comprobar "tras rechazarla no ha tocado nada" "$CMDLINE_ORIGINAL" \
    "$(cat "$PANTALLA_CMDLINE")"

# La importante: un modo que el monitor no anuncia dejaría la pantalla
# en negro, que a efectos prácticos es un equipo estropeado.
pantalla_fijar_modo "3840x2160" >/dev/null 2>&1
comprobar "rechaza un modo que el monitor no admite" "3" "$?"
comprobar "tras rechazarlo no ha tocado nada" "$CMDLINE_ORIGINAL" \
    "$(cat "$PANTALLA_CMDLINE")"

# Sin monitor tampoco debe escribir.
printf 'disconnected\n' >"$CONECTOR/status"
pantalla_fijar_modo "1280x720" >/dev/null 2>&1
comprobar "sin monitor no escribe" "2" "$?"
comprobar "y deja el fichero intacto" "$CMDLINE_ORIGINAL" \
    "$(cat "$PANTALLA_CMDLINE")"
printf 'connected\n' >"$CONECTOR/status"

# Un cmdline sin root= no arranca: no debe llegar a escribirse nunca.
comprobar_falla "no escribe un cmdline sin root=" \
    _pantalla_escribir_cmdline "console=tty1 quiet"
comprobar_falla "no escribe un cmdline vacío" \
    _pantalla_escribir_cmdline ""
comprobar_falla "no escribe un cmdline con salto de línea" \
    _pantalla_escribir_cmdline "root=/dev/mmcblk0p2
segunda linea"

# Finales de línea de Windows: el usuario puede haber editado la
# tarjeta desde el Bloc de notas.
printf '%s\r\n' "$CMDLINE_ORIGINAL" >"$PANTALLA_CMDLINE"
pantalla_fijar_modo "1280x720" >/dev/null 2>&1
comprobar "aguanta finales de línea CRLF" "1280x720" "$(pantalla_modo_forzado)"
comprobar "y no deja un retorno de carro suelto" "0" \
    "$(grep -c $'\r' "$PANTALLA_CMDLINE" || true)"

# ---------------------------------------------------------------------
#  4. Sincronización con la configuración
# ---------------------------------------------------------------------

titulo "Sincronización con SALIDA_HDMI"

restaurar_cmdline
config_defectos
RESOLUCION="1280x720"

SALIDA_HDMI="nativa"
comprobar "con salida nativa no se desea ningún modo" "" "$(pantalla_modo_deseado)"
comprobar_falla "y no hace falta reiniciar" pantalla_requiere_reinicio

SALIDA_HDMI="sesion"
comprobar "con salida sesion se desea la de la sesión" "1280x720" "$(pantalla_modo_deseado)"
comprobar_ok "y hace falta reiniciar" pantalla_requiere_reinicio

pantalla_sincronizar >/dev/null 2>&1
comprobar "sincronizar deja el modo puesto" "1280x720" "$(pantalla_modo_forzado)"
comprobar_falla "y ya no hace falta reiniciar" pantalla_requiere_reinicio

SALIDA_HDMI="nativa"
comprobar_ok "volver a nativa vuelve a pedir reinicio" pantalla_requiere_reinicio
pantalla_sincronizar >/dev/null 2>&1
comprobar "sincronizar quita el modo" "" "$(pantalla_modo_forzado)"

comprobar "resolución efectiva sin forzar es la nativa" "1920x1080" \
    "$(pantalla_resolucion_efectiva)"
pantalla_fijar_modo "1280x720" >/dev/null 2>&1
comprobar "resolución efectiva forzada es la forzada" "1280x720" \
    "$(pantalla_resolucion_efectiva)"

# ---------------------------------------------------------------------
#  5. Perfiles
# ---------------------------------------------------------------------

titulo "Perfiles"

printf 'RDP_HOST="pc"\n' >"$PITHIN_CONF"
config_cargar "$PITHIN_CONF" >/dev/null 2>&1

comprobar "hay cuatro perfiles" "4" "${#PERFILES_DISPONIBLES[@]}"
comprobar_falla "rechaza un perfil inventado" perfil_definicion "inventado"

comprobar "equilibrado usa sdl"            "sdl"        "$(perfil_backend equilibrado)"
comprobar "equilibrado va a 720p"          "1280x720"   "$(perfil_resolucion equilibrado)"
comprobar "nitidez va a 1080p"             "1920x1080"  "$(perfil_resolucion nitidez)"
comprobar "fluidez baja también la salida" "sesion"     "$(perfil_salida fluidez)"
comprobar "fluidez usa 16 bits"            "16"         "$(perfil_color fluidez)"
comprobar "compatibilidad usa x11"         "x11"        "$(perfil_backend compatibilidad)"

# Compatibilidad es la red de seguridad: no debe escalar nada, porque
# X11 lo haría en la CPU.
comprobar "compatibilidad no necesita escalar" "1920x1080" \
    "$(perfil_resolucion compatibilidad)"
comprobar "y saca la pantalla en nativa" "nativa" \
    "$(perfil_salida compatibilidad)"

perfil_aplicar nitidez >/dev/null 2>&1
config_cargar "$PITHIN_CONF" >/dev/null 2>&1
comprobar "aplicar escribe el backend"    "sdl"       "$BACKEND"
comprobar "aplicar escribe la resolución" "1920x1080" "$RESOLUCION"
comprobar "aplicar escribe el códec"      "progressive" "$CODEC"
comprobar "aplicar deja el nombre puesto" "nitidez"   "$PERFIL"
comprobar "se detecta el perfil aplicado" "nitidez"   "$(perfil_detectar)"

# Tocar un ajuste suelto tiene que dejar de llamarse como un perfil.
config_guardar_ajuste CODEC "avc420" >/dev/null 2>&1
config_cargar "$PITHIN_CONF" >/dev/null 2>&1
comprobar "tocar un ajuste lo vuelve personalizado" "personalizado" "$(perfil_detectar)"
perfil_resincronizar
config_cargar "$PITHIN_CONF" >/dev/null 2>&1
comprobar "y se refleja en el fichero" "personalizado" "$PERFIL"

# ---------------------------------------------------------------------
#  6. Perfil bueno conocido
# ---------------------------------------------------------------------

titulo "Perfil bueno conocido"

rm -f "$PERFIL_BUENO"
comprobar_falla "al empezar no hay ninguno guardado" perfil_hay_bueno
comprobar_ok    "sin referencia, todo cuenta como sin validar" perfil_sin_validar

perfil_aplicar equilibrado >/dev/null 2>&1
config_cargar "$PITHIN_CONF" >/dev/null 2>&1
perfil_marcar_bueno
comprobar_ok    "queda guardado como bueno" perfil_hay_bueno
comprobar_falla "y la configuración actual ya está validada" perfil_sin_validar

# Se usa 'nitidez' (1080p) como intermedio a propósito: 'equilibrado' y
# 'fluidez' comparten resolución (720p), así que con fluidez la aserción de
# resolución de abajo pasaría aunque restaurar no escribiera nada. Con
# nitidez, la resolución sí tiene que cambiar de 1080p a 720p al restaurar.
perfil_aplicar nitidez >/dev/null 2>&1
config_cargar "$PITHIN_CONF" >/dev/null 2>&1
comprobar_ok "cambiar de perfil lo deja sin validar" perfil_sin_validar
comprobar "el intermedio cambió de verdad la resolución" "1920x1080" "$RESOLUCION"

perfil_restaurar_bueno >/dev/null 2>&1
config_cargar "$PITHIN_CONF" >/dev/null 2>&1
comprobar "restaurar devuelve la resolución" "1280x720" "$RESOLUCION"
comprobar "restaurar devuelve el perfil"     "equilibrado" "$PERFIL"
comprobar_falla "y vuelve a estar validada"  perfil_sin_validar

# ---------------------------------------------------------------------
#  7. Validación de backends
# ---------------------------------------------------------------------

titulo "Validación de backends"

rm -f "$PERFIL_VALIDADOS"
comprobar_falla "sdl empieza sin validar" backend_validado sdl
comprobar_falla "x11 empieza sin validar" backend_validado x11

backend_marcar_validado sdl
comprobar_ok    "sdl queda validado"           backend_validado sdl
comprobar_falla "x11 sigue sin validar"        backend_validado x11
backend_marcar_validado sdl
comprobar "marcar dos veces no duplica" "1" "$(wc -l <"$PERFIL_VALIDADOS")"

backend_marcar_validado x11
comprobar_ok "x11 también queda validado" backend_validado x11

backend_invalidar sdl
comprobar_falla "invalidar quita sdl"      backend_validado sdl
comprobar_ok    "y no toca x11"            backend_validado x11

# ---------------------------------------------------------------------

printf '\n'
if (( FALLIDAS == 0 )); then
    printf '\033[32m  %s pruebas superadas.\033[0m\n\n' "$PASADAS"
    exit 0
fi
printf '\033[31m  %s superadas, %s fallidas.\033[0m\n\n' "$PASADAS" "$FALLIDAS"
exit 1
