#!/usr/bin/env bash
# Backup do servidor de automação: dump do Postgres + data/n8n + .env -> restic (R2).
# Uso: sudo scripts/backup.sh          (o timer systemd chama todo dia, como root)
#      sudo scripts/backup.sh init     (cria o repositório restic, uma vez)
# Precisa de root: data/n8n pertence ao uid 1000 (usuário do container do n8n).
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -r .env.backup ]] || { echo "Falta .env.backup (rode scripts/configurar-backup.sh)." >&2; exit 1; }
set -a; source .env.backup; set +a

if [[ "${1:-}" == "init" ]]; then
  exec restic init
fi

# Um backup por vez
mkdir -p backups
exec 9>backups/.lock
flock -n 9 || { echo "Outro backup em andamento." >&2; exit 1; }

log() { echo "[$(date '+%F %T')] $*"; }

PG_USER="$(grep -E '^POSTGRES_USER=' .env | cut -d= -f2-)"
PG_DB="$(grep -E '^POSTGRES_DB=' .env | cut -d= -f2-)"

log "pg_dump"
docker compose exec -T postgres pg_dump -U "$PG_USER" -d "$PG_DB" -Fc > backups/n8n.dump.tmp
mv backups/n8n.dump.tmp backups/n8n.dump

log "restic backup"
restic backup --host vps-oracle --tag n8n \
  --exclude backups/.lock \
  backups data/n8n .env

log "restic forget --prune"
restic forget --host vps-oracle --tag n8n --prune \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 6

if [[ "$(date +%u)" == "7" ]]; then
  log "restic check (domingo)"
  restic check
fi

log "ok"
