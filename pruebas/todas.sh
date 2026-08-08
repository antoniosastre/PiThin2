#!/usr/bin/env bash
# Ejecuta todas las pruebas. No necesita root ni una Raspberry.

set -uo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FALLOS=0

for prueba in "$RAIZ"/pruebas/prueba-*.sh; do
    printf '\n\033[1m══ %s\033[0m\n' "$(basename "$prueba")"
    "$prueba" || FALLOS=$((FALLOS + 1))
done

# El análisis estático forma parte de la suite: casi todos los fallos
# de un proyecto en shell son cosas que shellcheck ve.
if command -v shellcheck >/dev/null 2>&1; then
    printf '\n\033[1m══ shellcheck\033[0m\n'
    if LC_ALL=C.UTF-8 shellcheck -s bash -x \
            "$RAIZ"/install.sh \
            "$RAIZ"/src/lib/pithin-*.sh \
            "$RAIZ"/src/bin/pithin-* \
            "$RAIZ"/pruebas/*.sh; then
        printf '  \033[32m✓\033[0m sin avisos\n'
    else
        FALLOS=$((FALLOS + 1))
    fi
else
    printf '\n  (shellcheck no está instalado; se omite el análisis estático)\n'
fi

printf '\n'
if (( FALLOS == 0 )); then
    printf '\033[32m  Todo correcto.\033[0m\n\n'
    exit 0
fi
printf '\033[31m  %s conjuntos con fallos.\033[0m\n\n' "$FALLOS"
exit 1
