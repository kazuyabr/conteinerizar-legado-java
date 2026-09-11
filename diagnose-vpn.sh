#!/bin/bash
# ============================================
# DIAGNOSTICO DE CONECTIVIDADE
# ============================================

echo "============================================="
echo "  DOCKER-LEGACY - Diagnostico de Rede"
echo "============================================="

# Hostname e IP do container
echo ""
echo "[1] Container Info:"
echo "  Hostname: $(hostname)"
echo "  IP: $(hostname -I 2>/dev/null || echo 'N/A')"

# Testar endpoints TU
echo ""
echo "[2] Testando endpoints TU:"
ENDPOINTS=(
    "FWOP|http://10.193.103.17/FWOP|80"
    "CWS|http://10.193.93.48:3130|3130"
    "FileNet|https://ecmweb.unitario.teste.bradesco.com.br|443"
    "WSDE|http://10.192.60.133:9081|9081"
)

for ep in "${ENDPOINTS[@]}"; do
    IFS='|' read -r name url port <<< "$ep"
    echo -n "  $name ($url): "
    if curl -s -o /dev/null --connect-timeout 3 "$url" 2>/dev/null; then
        echo "OK"
    else
        echo "FALHOU"
    fi
done

# Verificar DNS
echo ""
echo "[3] Teste DNS:"
echo -n "  google.com: "
if nslookup google.com >/dev/null 2>&1; then
    echo "OK"
else
    echo "FALHOU"
fi

# Verificar rotas
echo ""
echo "[4] Rotas de rede:"
ip route 2>/dev/null | head -5 || echo "  N/A"

echo ""
echo "============================================="
echo "  Diagnostico completo"
echo "============================================="
