#!/usr/bin/env bash
# Cria o .env a partir do .env.example com segredos aleatórios.
# Uso: scripts/gerar-env.sh n8n.seudominio.com.br
set -euo pipefail
cd "$(dirname "$0")/.."

HOST="${1:?informe o domínio, ex.: scripts/gerar-env.sh n8n.seudominio.com.br}"
if [[ -e .env ]]; then
  echo ".env já existe; não vou sobrescrever." >&2
  exit 1
fi

segredo() { openssl rand -hex "$1"; }

umask 077
sed -e "s|^N8N_HOST=.*|N8N_HOST=${HOST}|" \
    -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$(segredo 24)|" \
    -e "s|^N8N_ENCRYPTION_KEY=.*|N8N_ENCRYPTION_KEY=$(segredo 32)|" \
    -e "s|^N8N_RUNNERS_AUTH_TOKEN=.*|N8N_RUNNERS_AUTH_TOKEN=$(segredo 32)|" \
    .env.example > .env

mkdir -p data/n8n data/postgres
# O n8n roda como o usuário "node" (uid 1000) dentro do container
sudo chown -R 1000:1000 data/n8n

echo ".env criado (permissão 600). Copie o conteúdo para o gerenciador de senhas AGORA."
