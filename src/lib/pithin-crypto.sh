#!/usr/bin/env bash
# pithin-crypto.sh - credencial de Windows cifrada y protegida por PIN.
#
# ---------------------------------------------------------------------
#  Qué protege esto y qué no
# ---------------------------------------------------------------------
#
# Un PIN corto tiene poca entropía: cuatro dígitos son diez mil
# combinaciones y un atacante con la tarjeta las prueba todas en
# segundos, por muy bueno que sea el cifrado. La longitud del PIN pesa
# más que el algoritmo. De ahí tres refuerzos:
#
#   1. Argon2id como derivación de clave. Es "memory-hard": cada
#      intento exige decenas de megabytes, lo que estropea el paralelismo
#      masivo en GPU que hace triviales los ataques contra PBKDF2.
#
#   2. La clave se deriva del PIN *y* del número de serie del SoC. Una
#      copia de la tarjeta en otro equipo no sirve para descifrar nada.
#      Esto cubre el caso realista: la SD prestada, copiada u olvidada
#      en un portátil.
#
#   3. La credencial vive en la partición ext4, no en la de arranque
#      FAT32. Windows y macOS no montan ext4 sin herramientas extra,
#      así que ni siquiera queda a la vista.
#
# Aun con todo: un PIN de seis dígitos es defendible, uno de cuatro no.
# Se exige un mínimo de seis caracteres y se admiten letras.
#
# Ver docs/seguridad.md para el modelo de amenazas completo.

[[ -n "${PITHIN_CRYPTO_CARGADO:-}" ]] && return 0
PITHIN_CRYPTO_CARGADO=1

# shellcheck source=/dev/null
source "${PITHIN_LIB:-/usr/local/lib/pithin}/pithin-common.sh"

CRED_FICHERO="$PITHIN_VAR/credencial.enc"
CRED_META="$PITHIN_VAR/credencial.meta"
CRED_INTENTOS="$PITHIN_VAR/intentos"

# Marca que va al principio del texto en claro. Permite distinguir un
# PIN incorrecto de un fichero corrupto: si descifra pero no empieza
# por esto, la clave era otra.
CRED_MAGIC="PITHIN-CRED-1"

# Parámetros de Argon2id por defecto.
#   memoria: exponente en KiB, 16 => 2^16 KiB = 64 MiB
#   tiempo : número de pasadas
#   hilos  : paralelismo
#
# 64 MiB entra de sobra en los 512 MB de la Zero 2 W en el momento en
# que se pide el PIN, antes de arrancar X. Se guardan junto al fichero
# para poder subirlos en el futuro sin invalidar credenciales ya
# creadas.
CRED_ARGON_MEMORIA=16
CRED_ARGON_TIEMPO=3
CRED_ARGON_HILOS=1

PIN_LONGITUD_MINIMA=6

# ---------------------------------------------------------------------
#  Comprobaciones
# ---------------------------------------------------------------------

cred_dependencias_ok() {
    local falta=()
    hay_comando argon2  || falta+=("argon2")
    hay_comando openssl || falta+=("openssl")
    if (( ${#falta[@]} )); then
        log_error "Faltan herramientas necesarias para el cifrado: ${falta[*]}"
        return 1
    fi
    return 0
}

cred_existe() { [[ -s "$CRED_FICHERO" && -s "$CRED_META" ]]; }

# Un PIN aceptable. Se permite cualquier carácter imprimible para no
# obligar a usar solo dígitos: "casa42" es muchísimo mejor que "1234".
cred_pin_valido() {
    local pin="$1"
    (( ${#pin} >= PIN_LONGITUD_MINIMA ))
}

cred_motivo_pin_invalido() {
    printf 'El PIN debe tener al menos %s caracteres. Puedes usar letras y números.' \
        "$PIN_LONGITUD_MINIMA"
}

# ---------------------------------------------------------------------
#  Derivación de clave
# ---------------------------------------------------------------------

# Imprime por salida estándar 32 bytes en hexadecimal.
_cred_derivar_clave() {
    local pin="$1" sal="$2" memoria="$3" tiempo="$4" hilos="$5"
    local material

    # \x1f (separador de unidades) evita que un PIN acabado en dígitos
    # y un serial que empiece por dígitos se confundan entre sí.
    material="${pin}"$'\x1f'"$(serial_dispositivo)"

    printf '%s' "$material" | argon2 "$sal" \
        -id -m "$memoria" -t "$tiempo" -p "$hilos" -l 32 -r 2>/dev/null
}

# openssl recibe la clave por un descriptor de fichero, nunca por la
# línea de órdenes: los argumentos son visibles en la tabla de procesos.
# El PBKDF2 que openssl aplica encima es irrelevante para la seguridad
# (la entrada ya tiene 256 bits de entropía), solo sirve para poder
# usar la interfaz de contraseña en vez de -K.
_cred_cifrar() {
    local clave="$1"
    openssl enc -aes-256-cbc -pbkdf2 -iter 10000 -salt -a -A \
        -pass fd:3 3< <(printf '%s' "$clave") 2>/dev/null
}

_cred_descifrar() {
    local clave="$1"
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -a -A \
        -pass fd:3 3< <(printf '%s' "$clave") 2>/dev/null
}

# ---------------------------------------------------------------------
#  Guardar y leer
# ---------------------------------------------------------------------

# cred_guardar <pin> <contraseña>
cred_guardar() {
    local pin="$1" secreto="$2"

    cred_dependencias_ok || return 1
    requiere_root || return 1

    if ! cred_pin_valido "$pin"; then
        log_error "$(cred_motivo_pin_invalido)"
        return 2
    fi

    install -d -m 0700 "$PITHIN_VAR" || return 1

    local sal
    sal="$(openssl rand -hex 16)" || return 1

    local clave
    clave="$(_cred_derivar_clave "$pin" "$sal" \
        "$CRED_ARGON_MEMORIA" "$CRED_ARGON_TIEMPO" "$CRED_ARGON_HILOS")"
    if [[ -z "$clave" ]]; then
        log_error "Falló la derivación de clave con argon2."
        return 1
    fi

    local cifrado
    cifrado="$(printf '%s\n%s' "$CRED_MAGIC" "$secreto" | _cred_cifrar "$clave")"
    if [[ -z "$cifrado" ]]; then
        log_error "Falló el cifrado de la credencial."
        return 1
    fi

    local tmp_enc tmp_meta
    tmp_enc="$(mktemp "$CRED_FICHERO.XXXXXX")" || return 1
    tmp_meta="$(mktemp "$CRED_META.XXXXXX")" || { rm -f "$tmp_enc"; return 1; }

    printf '%s\n' "$cifrado" >"$tmp_enc"
    {
        printf 'sal=%s\n'     "$sal"
        printf 'memoria=%s\n' "$CRED_ARGON_MEMORIA"
        printf 'tiempo=%s\n'  "$CRED_ARGON_TIEMPO"
        printf 'hilos=%s\n'   "$CRED_ARGON_HILOS"
    } >"$tmp_meta"

    chmod 0600 "$tmp_enc" "$tmp_meta"
    mv -f "$tmp_enc"  "$CRED_FICHERO"
    mv -f "$tmp_meta" "$CRED_META"
    sync

    cred_reiniciar_intentos
    log_info "Credencial guardada y cifrada."
    return 0
}

# cred_leer <pin> -> imprime la contraseña por salida estándar.
# Devuelve 0 si el PIN era correcto, 1 en cualquier otro caso.
cred_leer() {
    local pin="$1"

    cred_dependencias_ok || return 1
    cred_existe || { log_error "No hay ninguna credencial guardada."; return 1; }

    local sal memoria tiempo hilos campo valor
    while IFS='=' read -r campo valor; do
        case "$campo" in
            sal)     sal="$valor" ;;
            memoria) memoria="$valor" ;;
            tiempo)  tiempo="$valor" ;;
            hilos)   hilos="$valor" ;;
        esac
    done <"$CRED_META"

    if [[ -z "$sal" ]]; then
        log_error "El fichero de metadatos de la credencial está corrupto."
        return 1
    fi

    local clave
    clave="$(_cred_derivar_clave "$pin" "$sal" \
        "${memoria:-$CRED_ARGON_MEMORIA}" \
        "${tiempo:-$CRED_ARGON_TIEMPO}" \
        "${hilos:-$CRED_ARGON_HILOS}")"
    [[ -n "$clave" ]] || { log_error "Falló la derivación de clave."; return 1; }

    local plano
    plano="$(_cred_descifrar "$clave" <"$CRED_FICHERO")"

    # Dos filtros: que openssl haya podido quitar el relleno, y que el
    # texto empiece por nuestra marca. El segundo es el que de verdad
    # distingue un PIN equivocado.
    if [[ -z "$plano" || "${plano%%$'\n'*}" != "$CRED_MAGIC" ]]; then
        cred_registrar_fallo
        return 1
    fi

    cred_reiniciar_intentos
    printf '%s' "${plano#*$'\n'}"
    return 0
}

cred_borrar() {
    requiere_root || return 1
    rm -f "$CRED_FICHERO" "$CRED_META" "$CRED_INTENTOS"
    sync
    log_info "Credencial eliminada del equipo."
}

# ---------------------------------------------------------------------
#  Freno a los intentos por fuerza bruta en el propio equipo
# ---------------------------------------------------------------------
# Esto no protege contra un ataque offline sobre la tarjeta (para eso
# está Argon2id), sino contra alguien que se siente delante del equipo
# encendido y empiece a probar.

cred_intentos_fallidos() {
    local n=0
    [[ -r "$CRED_INTENTOS" ]] && n="$(cat "$CRED_INTENTOS" 2>/dev/null)"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
}

cred_registrar_fallo() {
    local n
    n="$(cred_intentos_fallidos)"
    n=$((n + 1))
    install -d -m 0700 "$PITHIN_VAR" 2>/dev/null || true
    printf '%s\n' "$n" >"$CRED_INTENTOS" 2>/dev/null || true
    chmod 0600 "$CRED_INTENTOS" 2>/dev/null || true
    log_aviso "PIN incorrecto (intento fallido nº $n)."
}

cred_reiniciar_intentos() {
    rm -f "$CRED_INTENTOS" 2>/dev/null || true
}

# Segundos que hay que esperar antes de admitir el siguiente intento.
cred_espera_por_intentos() {
    local n
    n="$(cred_intentos_fallidos)"
    if   (( n >= 8 )); then printf '60'
    elif (( n >= 5 )); then printf '30'
    elif (( n >= 3 )); then printf '5'
    else                    printf '0'
    fi
}
