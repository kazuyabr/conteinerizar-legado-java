#!/bin/bash
set -euo pipefail
# Verifica renderizacao JSF dos dois WARs usando o login mock local.
body=$(mktemp)
trap 'rm -f "$body"' EXIT
for app in npco npco_analise; do
    curl --fail --silent --show-error --max-time 15 \
        --user "${HEALTHCHECK_USER:-I919852}:${HEALTHCHECK_PASSWORD:-cambio11}" \
        "http://localhost:8080/$app/content/index.xhtml" -o "$body"
    grep -q 'Banco Bradesco' "$body"
    grep -q 'javax.faces.ViewState' "$body"
done
