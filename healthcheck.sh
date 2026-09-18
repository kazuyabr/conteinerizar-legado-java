#!/bin/bash
set -euo pipefail
# Verifica os WARs quando publicados; se nao houver apps, valida a pagina de status do runtime.
body=$(mktemp)
trap 'rm -f "$body"' EXIT
status_only=$(curl --fail --silent --show-error --max-time 15 http://localhost:8080/ -o "$body" && grep -q 'Docker Legacy pronto' "$body" && echo true || echo false)

if [ "$status_only" = "true" ]; then
    exit 0
fi

for app in npco npco_analise; do
    curl --fail --silent --show-error --max-time 15 \
        --user "${HEALTHCHECK_USER:-I919852}:${HEALTHCHECK_PASSWORD:-cambio11}" \
        "http://localhost:8080/$app/content/index.xhtml" -o "$body"
    grep -q 'Banco Bradesco' "$body"
    grep -q 'javax.faces.ViewState' "$body"
done
