# Servidor de automação: n8n + Postgres com backup externo

[English version](README.en.md)

Instalação de produção do [n8n](https://n8n.io) numa VPS: banco Postgres, HTTPS, segredos fora do código e **backup diário criptografado fora da máquina, com restauração testada**. É o padrão de instalação que ofereço para pequenas empresas.

**No ar:** https://n8n.ilmartec.com.br (a página pública mostra só o login).

## O problema
Muita instalação de n8n é um `docker run` com SQLite, sem backup e com a chave de criptografia perdida em algum lugar. Funciona até o dia em que o disco falha ou uma atualização dá errado. Nesse dia, os workflows e as credenciais somem.

Esta instalação foi feita para esse dia:
- os dados podem ser recuperados de um backup que fica fora do servidor;
- o processo de restauração está escrito e foi testado;
- nada além do proxy fica exposto na internet.

## O que tem
- **n8n 2.46.6 + Postgres 16** em Docker Compose, com versões fixas.
- **Task runners em modo externo:** o código dos nós *Code* (JS e Python) roda num container separado.
- **HTTPS** com nginx + Let's Encrypt (Certbot), com suporte a WebSocket para o editor.
- **Backup diário às 03:30** com restic → Cloudflare R2:
  - dump do Postgres + `data/n8n` + `.env`;
  - criptografado;
  - retenção de 7 diárias, 4 semanais e 6 mensais;
  - verificação de integridade aos domingos.
- **Segredos gerados por script**, com permissão 600, fora do Git.

## Arquitetura

```
Internet ──HTTPS──▶ nginx (80/443, certificado Let's Encrypt)
                      │  proxy (com WebSocket)
                      ▼
               127.0.0.1:5678   ← única porta do n8n, e só local
┌──────────────── rede interna do Docker Compose ─────────────────┐
│  n8n ─────────────▶ postgres   (dados em data/postgres)          │
│   ▲                                                              │
│   └── runners → n8n:5679   (broker; executa o código dos nós     │
│                             Code, sem porta publicada)           │
└──────────────────────────────────────────────────────────────────┘

systemd timer 03:30 ─▶ scripts/backup.sh
   pg_dump + data/n8n + .env ─▶ restic (criptografa) ─▶ Cloudflare R2
```

## Por que assim
| Decisão | Motivo |
|---|---|
| Postgres, não SQLite | Mais robusto para uso contínuo e permite um dump consistente com `pg_dump`, sem parar o serviço |
| Task runners externos | O código dos workflows roda fora do processo principal do n8n. É o modo que a [documentação oficial](https://docs.n8n.io/deploy/host-n8n/configure-n8n/set-up-task-runners) recomenda para produção |
| n8n só em `127.0.0.1` | Nada chega ao n8n sem passar pelo proxy com HTTPS |
| Backup do dump, não da pasta do Postgres | Copiar a pasta com o banco rodando pode gerar uma cópia inconsistente |
| `.env` dentro do backup | Sem a `N8N_ENCRYPTION_KEY`, as credenciais salvas no n8n não abrem depois de restaurar. O restic criptografa tudo, e a senha dele fica só no gerenciador de senhas |
| Token do R2 restrito a um bucket | Se o servidor for comprometido, o token não dá acesso a outros buckets da conta |
| Versões fixas | Atualização é uma decisão, com backup antes, e não uma surpresa num `pull` |
| Primeiro acesso restrito por IP | No n8n, quem abre a página primeiro vira dono da instância. O nginx libera só o IP do instalador até o dono ser criado |

## Instalação
Requisitos: Linux com Docker Engine + Compose v2, nginx, Certbot, restic e openssl, além de um domínio com registro `A` apontando para a máquina. Testado numa VPS ARM64 (Oracle Cloud) com Ubuntu; as imagens também existem para amd64.

```bash
git clone https://github.com/ilmar-n/servidor-automacao.git
cd servidor-automacao

# 1. Segredos: cria o .env com senhas aleatórias e prepara data/
scripts/gerar-env.sh n8n.seudominio.com.br
#    → copie o conteúdo do .env para o gerenciador de senhas AGORA

# 2. Sobe os containers
docker compose up -d
docker compose ps
curl -s http://127.0.0.1:5678/healthz      # {"status":"ok"}

# 3. nginx + HTTPS (o template começa liberado só para o seu IP)
sudo cp deploy/nginx/n8n.conf.example /etc/nginx/sites-available/n8n.conf
sudo sed -i -e "s/N8N_HOST/n8n.seudominio.com.br/" -e "s/SEU_IP/<seu IP público>/" \
     /etc/nginx/sites-available/n8n.conf
sudo ln -s /etc/nginx/sites-available/n8n.conf /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d n8n.seudominio.com.br

# 4. Abra https://n8n.seudominio.com.br e crie a conta dona.
#    Depois apague as linhas allow/deny do n8n.conf:
sudo nginx -t && sudo systemctl reload nginx
```

Depois de criar o dono, ative o 2FA da conta (*Settings → Personal*).

### Backup
```bash
# Pede o Account ID, a chave e o segredo do token do R2 (digitados na máquina,
# nunca em arquivo versionado). Gera a senha do restic e a mostra UMA vez:
# guarde-a no gerenciador de senhas.
scripts/configurar-backup.sh
sudo scripts/backup.sh init        # cria o repositório restic no bucket
sudo scripts/backup.sh             # primeiro backup

# Agendamento diário
sudo cp deploy/systemd/backup-n8n.service deploy/systemd/backup-n8n.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now backup-n8n.timer
```

**Ajuste antes de instalar:**
- o caminho `/home/ubuntu/servidor-automacao` em `deploy/systemd/backup-n8n.service`;
- o nome do bucket (variável `BUCKET` do `configurar-backup.sh`);
- o `--host` usado no `backup.sh`.

O backup roda como root porque `data/n8n` pertence ao uid 1000, o usuário do container do n8n.

## Restauração
Para restaurar, você precisa de três coisas:
- este repositório;
- a **senha do restic**, que está no gerenciador de senhas;
- um token do R2 com acesso ao bucket.

```bash
# Máquina nova, com Docker e restic. NÃO rode o gerar-env.sh: o .env vem do backup.
git clone https://github.com/ilmar-n/servidor-automacao.git
cd servidor-automacao

# 1. Crie o .env.backup à mão (permissão 600), com a MESMA senha do restic.
#    O modelo está em scripts/configurar-backup.sh. O script em si gera
#    uma senha nova, então não serve para restaurar.

# 2. Liste os snapshots e restaure o último dentro da pasta do projeto
#    (o restic devolve .env, data/n8n e backups/n8n.dump nos caminhos certos)
sudo bash -c 'set -a; source .env.backup; restic snapshots && restic restore latest --target .'
sudo chown "$USER": .env && chmod 600 .env
sudo chown -R 1000:1000 data/n8n

# 3. Suba só o Postgres e carregue o dump
docker compose up -d postgres
docker compose cp backups/n8n.dump postgres:/tmp/n8n.dump
docker compose exec postgres sh -c 'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner /tmp/n8n.dump'

# 4. Suba o resto e confira
docker compose up -d
curl -s http://127.0.0.1:5678/healthz
```

**Teste de 09/11/2026:**
- O snapshot foi restaurado e o `.env` e o `data/n8n` saíram idênticos aos da produção.
- O dump foi carregado num Postgres 16 descartável e bateu com a produção: 173 tabelas e as mesmas contagens de registros.

O roteiro completo numa VM limpa, com o tempo medido, é o próximo teste (ver "Limites").

## Operação
| Tarefa | Comando |
|---|---|
| Estado dos containers | `docker compose ps` |
| Logs do n8n | `docker compose logs -f n8n` |
| Backup manual | `sudo systemctl start backup-n8n` |
| Log do backup | `journalctl -u backup-n8n` |
| Listar snapshots | `sudo bash -c 'set -a; source .env.backup; restic snapshots'` |
| Atualizar o n8n | 1. backup manual · 2. trocar `N8N_VERSION` no `.env` (n8n e runners usam a mesma) · 3. `docker compose pull && docker compose up -d` · 4. `healthz` |

## Limites e próximos passos
Isto é o que ainda **não** está feito:
- **Monitoramento e alertas:** se o backup falhar ou o site cair, ninguém é avisado. Próximo passo: Uptime Kuma.
- **Restauração numa VM limpa**, com o tempo medido.
- **Uma única máquina, sem alta disponibilidade.** O plano de recuperação é o backup.
- **Endurecimento do sistema operacional** (SSH só por chave, firewall, atualizações automáticas) fica fora deste repositório.
- **Versão para servidor sem IP público**, atrás do Cloudflare Tunnel: planejada.

## Licença do n8n
O n8n usa a *Sustainable Use License*. Este repositório serve para instalar o n8n na infraestrutura de quem vai usá-lo, seja sua ou do seu cliente. Ele **não** serve para vender acesso a uma instância compartilhada. Detalhes na [central de ajuda do n8n](https://support.n8n.io/article/can-i-use-your-license-for-my-use-case).
