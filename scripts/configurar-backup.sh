#!/usr/bin/env bash
# Cria o .env.backup (chaves do Cloudflare R2 + senha do restic).
# Uso (na VPS, com terminal interativo): scripts/configurar-backup.sh
# As chaves são digitadas aqui e ficam só neste arquivo (permissão 600).
set -euo pipefail
cd "$(dirname "$0")/.."

BUCKET="${BUCKET:-ilmartec-backup-vps}"

if [[ -e .env.backup ]]; then
  echo ".env.backup já existe; não vou sobrescrever." >&2
  exit 1
fi

read -rp  "Cloudflare Account ID: " ACCOUNT_ID
read -rp  "R2 Access Key ID: " KEY_ID
read -rsp "R2 Secret Access Key (oculto): " SECRET; echo

[[ -n "$ACCOUNT_ID" && -n "$KEY_ID" && -n "$SECRET" ]] || { echo "Campo vazio; abortando." >&2; exit 1; }

RESTIC_PASS="$(openssl rand -base64 33 | tr -d '\n')"

umask 077
cat > .env.backup <<CONF
# Gerado por scripts/configurar-backup.sh. NUNCA suba para o Git.
RESTIC_REPOSITORY=s3:https://${ACCOUNT_ID}.r2.cloudflarestorage.com/${BUCKET}
AWS_ACCESS_KEY_ID=${KEY_ID}
AWS_SECRET_ACCESS_KEY=${SECRET}
AWS_DEFAULT_REGION=auto
RESTIC_PASSWORD=${RESTIC_PASS}
CONF

echo
echo "=================================================================="
echo " SENHA DO RESTIC (aparece só agora; guarde no gerenciador de senhas):"
echo
echo "   ${RESTIC_PASS}"
echo
echo " Sem ela, os backups NÃO podem ser lidos."
echo "=================================================================="
echo ".env.backup criado (permissão 600)."
