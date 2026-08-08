#!/usr/bin/env bash
# =====================================================================
#  Pruebas de los módulos que no necesitan hardware de Raspberry Pi
# =====================================================================
#
#  Cubren lo que se puede romper en silencio: el análisis de los dos
#  ficheros de configuración y el ciclo completo de cifrado con PIN.
#  Lo demás (WiFi, Tailscale, FreeRDP) necesita el equipo de verdad.
#
#  Uso:  ./pruebas/prueba-modulos.sh
#
#  No hace falta root ni Raspberry: monta un entorno aislado en un
#  directorio temporal.
# =====================================================================

#  Este fichero sustituye funciones de los módulos por dobles de prueba
#  y fija variables que consumen los módulos, no él. El analizador
#  estático no ve ninguna de las dos cosas, así que las señalaría en
#  bloque; de ahí la excepción.
# shellcheck disable=SC2317,SC2034

set -uo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BANCO="$(mktemp -d)"
trap 'rm -rf "$BANCO"' EXIT

# Redirigimos las rutas del programa al banco de pruebas ANTES de cargar
# los módulos: pithin-common.sh las fija al cargarse y respeta lo que ya
# haya en el entorno.
export PITHIN_LIB="$RAIZ/src/lib"
export PITHIN_BOOT="$BANCO"
export PITHIN_VAR="$BANCO/var"
export PITHIN_ETC="$BANCO/etc"
export PITHIN_LOG="$BANCO/pithin.log"

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
        PASADAS=$((PASADAS + 1))
        printf '  \033[32m✓\033[0m %s\n' "$descripcion"
    else
        FALLIDAS=$((FALLIDAS + 1))
        printf '  \033[31m✗\033[0m %s (devolvió %s)\n' "$descripcion" "$?"
    fi
}

comprobar_falla() {
    local descripcion="$1"; shift
    if "$@" >/dev/null 2>&1; then
        FALLIDAS=$((FALLIDAS + 1))
        printf '  \033[31m✗\033[0m %s (debería haber fallado)\n' "$descripcion"
    else
        PASADAS=$((PASADAS + 1))
        printf '  \033[32m✓\033[0m %s\n' "$descripcion"
    fi
}

titulo() { printf '\n\033[1;36m%s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------
#  Preparación del entorno aislado
# ---------------------------------------------------------------------

# shellcheck source=/dev/null
source "$PITHIN_LIB/pithin-common.sh"

mkdir -p "$PITHIN_VAR" "$PITHIN_ETC"

# Las pruebas no corren como root; cred_guardar lo exige. Lo sustituimos
# por una versión permisiva: lo que se está probando es la criptografía,
# no el control de acceso.
requiere_root() { return 0; }

# Y el serial del SoC, que aquí no existe.
serial_dispositivo() { printf '10000000abcdef01'; }

# shellcheck source=/dev/null
source "$PITHIN_LIB/pithin-config.sh"
# shellcheck source=/dev/null
source "$PITHIN_LIB/pithin-wifi.sh"
# shellcheck source=/dev/null
source "$PITHIN_LIB/pithin-crypto.sh"

# Argon2 más flojo para que las pruebas no tarden un minuto. En el
# equipo real se usan 64 MiB.
CRED_ARGON_MEMORIA=10
CRED_ARGON_TIEMPO=1

# ---------------------------------------------------------------------
#  1. Utilidades
# ---------------------------------------------------------------------

titulo "Utilidades"

comprobar_ok    "es_si acepta 'si'"        es_si "si"
comprobar_ok    "es_si acepta 'sí'"        es_si "sí"
comprobar_ok    "es_si acepta 'yes'"       es_si "yes"
comprobar_ok    "es_si acepta '1'"         es_si "1"
comprobar_ok    "es_si acepta 'SI'"        es_si "SI"
comprobar_falla "es_si rechaza 'no'"       es_si "no"
comprobar_falla "es_si rechaza vacío"      es_si ""
comprobar_falla "es_si rechaza 'quizá'"    es_si "quizá"

comprobar "recortar quita espacios" "hola" "$(recortar '   hola   ')"
comprobar "recortar respeta interiores" "a b" "$(recortar '  a b  ')"

# ---------------------------------------------------------------------
#  2. Análisis de pithin.conf
# ---------------------------------------------------------------------

titulo "Configuración (pithin.conf)"

cat >"$PITHIN_CONF" <<'FIN'
# Comentario que hay que ignorar
RDP_HOST="mi-pc"
RDP_USER = "MicrosoftAccount\\yo@correo.com"
RESOLUCION=1280x720
   PROFUNDIDAD_COLOR   =   16
CODEC='progressive'

AJUSTE_QUE_NO_EXISTE="da igual"
esto no es una linea valida
FIN

config_cargar "$PITHIN_CONF" >/dev/null 2>&1

comprobar "lee un valor entrecomillado"        "mi-pc"       "$RDP_HOST"
comprobar "tolera espacios alrededor del ="    'MicrosoftAccount\\yo@correo.com' "$RDP_USER"
comprobar "lee un valor sin comillas"          "1280x720"    "$RESOLUCION"
comprobar "tolera sangría y espacios"          "16"          "$PROFUNDIDAD_COLOR"
comprobar "acepta comillas simples"            "progressive" "$CODEC"
comprobar "aplica el valor por defecto que falta" "3389"     "$RDP_PUERTO"

# Los finales de línea de Windows son el caso más probable: el usuario
# edita el fichero desde el Bloc de notas.
printf 'RDP_HOST="pc-desde-windows"\r\nRESOLUCION="1920x1080"\r\n' >"$PITHIN_CONF"
config_cargar "$PITHIN_CONF" >/dev/null 2>&1
comprobar "aguanta finales de línea CRLF"      "pc-desde-windows" "$RDP_HOST"

# Valores imposibles: tienen que corregirse solos, no romper el arranque.
cat >"$PITHIN_CONF" <<'FIN'
RESOLUCION="enorme"
PROFUNDIDAD_COLOR="7"
CODEC="inventado"
RDP_PUERTO="999999"
ESPERA_WIFI="pronto"
FIN
config_cargar "$PITHIN_CONF" >/dev/null 2>&1

comprobar "corrige una resolución absurda"     "1920x1080"   "$RESOLUCION"
comprobar "corrige una profundidad inválida"   "32"          "$PROFUNDIDAD_COLOR"
comprobar "corrige un códec inexistente"       "progressive" "$CODEC"
comprobar "corrige un puerto fuera de rango"   "3389"        "$RDP_PUERTO"
comprobar "corrige un número que no lo es"     "25"          "$ESPERA_WIFI"

# config_completa
config_cargar "$PITHIN_CONF" >/dev/null 2>&1
comprobar_falla "detecta configuración incompleta" config_completa
RDP_HOST="algo"; RDP_USER="alguien"
comprobar_ok    "detecta configuración completa"   config_completa

# ---------------------------------------------------------------------
#  3. Escritura conservando comentarios
# ---------------------------------------------------------------------

titulo "Guardar ajustes sin destruir el fichero"

cat >"$PITHIN_CONF" <<'FIN'
# Un comentario importante que no se debe perder
RDP_HOST="antiguo"

# Otro comentario
RESOLUCION="1920x1080"
FIN

# La comprobación de partición de arranque no aplica en el banco.
boot_escribible() { return 0; }

config_guardar_ajuste RESOLUCION "1280x720" "$PITHIN_CONF" >/dev/null 2>&1

comprobar "conserva los comentarios" "2" \
    "$(grep -c '^#' "$PITHIN_CONF")"
comprobar "cambia solo el ajuste pedido" "1280x720" \
    "$(grep '^RESOLUCION' "$PITHIN_CONF" | cut -d'"' -f2)"
comprobar "no toca los demás ajustes" "antiguo" \
    "$(grep '^RDP_HOST' "$PITHIN_CONF" | cut -d'"' -f2)"

config_guardar_ajuste CODEC "rfx" "$PITHIN_CONF" >/dev/null 2>&1
comprobar "añade un ajuste que no estaba" "rfx" \
    "$(grep '^CODEC' "$PITHIN_CONF" | cut -d'"' -f2)"

comprobar_falla "rechaza una clave desconocida" \
    config_guardar_ajuste CLAVE_INVENTADA "x" "$PITHIN_CONF"

# ---------------------------------------------------------------------
#  4. Análisis de redes.conf
# ---------------------------------------------------------------------

titulo "Redes WiFi (redes.conf)"

cat >"$PITHIN_REDES" <<'FIN'
# Redes de ejemplo
[MiCasa]
clave = laClave
prioridad = 100

[Red Con Espacios]
clave = otra clave con espacios
prioridad = 80

[WiFi-Abierta]
clave =
prioridad = 10

[RedOculta]
clave = secreta
oculta = si
FIN

RECOGIDAS="$BANCO/recogidas.txt"
: >"$RECOGIDAS"
_recoger() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >>"$RECOGIDAS"; }
_wifi_recorrer_fichero "$PITHIN_REDES" _recoger

comprobar "encuentra las cuatro redes" "4" "$(wc -l <"$RECOGIDAS")"
comprobar "lee SSID y clave" "MiCasa|laClave|100|no" \
    "$(sed -n 1p "$RECOGIDAS")"
comprobar "admite espacios en SSID y clave" "Red Con Espacios|otra clave con espacios|80|no" \
    "$(sed -n 2p "$RECOGIDAS")"
comprobar "admite red abierta sin clave" "WiFi-Abierta||10|no" \
    "$(sed -n 3p "$RECOGIDAS")"
comprobar "detecta red oculta y prioridad por defecto" "RedOculta|secreta|50|si" \
    "$(sed -n 4p "$RECOGIDAS")"

# Contraseñas con caracteres que romperían un analizador ingenuo.
cat >"$PITHIN_REDES" <<'FIN'
[Rara]
clave = a#b"c'd=e$f`g
FIN
: >"$RECOGIDAS"
_wifi_recorrer_fichero "$PITHIN_REDES" _recoger
# El '$f' y el acento grave son literales a propósito: comprobamos que
# el analizador de redes.conf no los interpreta.
# shellcheck disable=SC2016
comprobar "no se atraganta con símbolos raros en la clave" \
    'Rara|a#b"c'"'"'d=e$f`g|50|no' "$(sed -n 1p "$RECOGIDAS")"

# Guardar una red nueva y releerla.
cat >"$PITHIN_REDES" <<'FIN'
[Existente]
clave = uno
FIN
wifi_guardar_en_fichero "Nueva" "dos" "no" "$PITHIN_REDES" >/dev/null 2>&1
: >"$RECOGIDAS"
_wifi_recorrer_fichero "$PITHIN_REDES" _recoger
comprobar "guarda una red nueva al final" "2" "$(wc -l <"$RECOGIDAS")"
comprobar "la red guardada se relee bien" "Nueva|dos|50|no" "$(sed -n 2p "$RECOGIDAS")"

wifi_guardar_en_fichero "Nueva" "dos" "no" "$PITHIN_REDES" >/dev/null 2>&1
: >"$RECOGIDAS"
_wifi_recorrer_fichero "$PITHIN_REDES" _recoger
comprobar "no duplica una red que ya estaba" "2" "$(wc -l <"$RECOGIDAS")"

# ---------------------------------------------------------------------
#  5. Cifrado de la credencial
# ---------------------------------------------------------------------

titulo "Credencial cifrada con PIN"

if ! cred_dependencias_ok 2>/dev/null; then
    printf '  \033[33m!\033[0m argon2 u openssl no están; se omite este bloque\n'
else
    SECRETO='C0ntraseña con espacios, acentos y $ímbolo$ "raros"'

    comprobar_falla "no hay credencial al empezar" cred_existe
    comprobar_falla "rechaza un PIN de 4 dígitos" cred_pin_valido "1234"
    comprobar_ok    "acepta un PIN de 6 caracteres" cred_pin_valido "casa42"

    comprobar_falla "cred_guardar rechaza un PIN corto" \
        cred_guardar "123" "$SECRETO"

    comprobar_ok "guarda la credencial" cred_guardar "casa42" "$SECRETO"
    comprobar_ok "ahora existe la credencial" cred_existe

    comprobar "descifra con el PIN correcto" "$SECRETO" "$(cred_leer 'casa42')"

    comprobar_falla "falla con el PIN equivocado" cred_leer "casa99"
    comprobar_falla "falla con un PIN vacío"      cred_leer ""

    # El fichero cifrado no debe contener el secreto en claro.
    if grep -qF "C0ntraseña" "$CRED_FICHERO" 2>/dev/null; then
        FALLIDAS=$((FALLIDAS + 1))
        printf '  \033[31m✗\033[0m el fichero cifrado contiene el secreto en claro\n'
    else
        PASADAS=$((PASADAS + 1))
        printf '  \033[32m✓\033[0m el fichero cifrado no revela el secreto\n'
    fi

    comprobar "permisos 0600 en el fichero cifrado" "600" \
        "$(stat -c %a "$CRED_FICHERO")"

    # Vinculación al dispositivo: con otro número de serie, el mismo PIN
    # ya no debe abrir nada. Es la defensa contra la tarjeta copiada.
    serial_original="$(declare -f serial_dispositivo)"
    serial_dispositivo() { printf 'OTRA-RASPBERRY-DISTINTA'; }
    comprobar_falla "no descifra en otra Raspberry (PIN correcto)" \
        cred_leer "casa42"
    eval "$serial_original"
    comprobar "vuelve a descifrar en la Raspberry original" "$SECRETO" \
        "$(cred_leer 'casa42')"

    # Contador de intentos y espera creciente.
    cred_reiniciar_intentos
    comprobar "sin fallos, sin espera" "0" "$(cred_espera_por_intentos)"
    cred_leer "malo1" >/dev/null 2>&1
    cred_leer "malo2" >/dev/null 2>&1
    cred_leer "malo3" >/dev/null 2>&1
    comprobar "cuenta los intentos fallidos" "3" "$(cred_intentos_fallidos)"
    comprobar "impone espera tras 3 fallos" "5" "$(cred_espera_por_intentos)"
    cred_leer "casa42" >/dev/null 2>&1
    comprobar "un acierto reinicia el contador" "0" "$(cred_intentos_fallidos)"

    comprobar_ok    "borra la credencial" cred_borrar
    comprobar_falla "ya no existe tras borrarla" cred_existe
fi

# ---------------------------------------------------------------------
#  6. Teclado
# ---------------------------------------------------------------------

titulo "Distribución de teclado"

# shellcheck source=/dev/null
source "$PITHIN_LIB/pithin-rdp.sh"

comprobar "español"                "0x0000040A" "$(rdp_id_teclado es)"
comprobar "latinoamericano"        "0x0000080A" "$(rdp_id_teclado latam)"
comprobar "inglés EEUU"            "0x00000409" "$(rdp_id_teclado us)"
comprobar "acepta hexadecimal"     "0x00000407" "$(rdp_id_teclado 0x00000407)"
comprobar "desconocido cae a español" "0x0000040A" "$(rdp_id_teclado marciano)"

# ---------------------------------------------------------------------

printf '\n'
if (( FALLIDAS == 0 )); then
    printf '\033[32m  %s pruebas superadas.\033[0m\n\n' "$PASADAS"
    exit 0
fi
printf '\033[31m  %s superadas, %s fallidas.\033[0m\n\n' "$PASADAS" "$FALLIDAS"
exit 1
