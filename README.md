# mysql-meu-local

Configuração Docker para MySQL local com replicação de dois bancos de produção.

## Bancos disponíveis

| Banco          | Container        | Porta padrão |
|----------------|------------------|--------------|
| PROD OLD ECOM  | mysql-shoplive   | 3306         |
| CROSS PROD     | mysql-cross-prod | 3307         |

## Pré-requisitos

- Docker e Docker Compose instalados.
- Copie `.env.example` para `.env` e ajuste as credenciais.

## Como usar

### Início

```
./start.sh
```

O script pergunta qual banco replicar:
```
  1) PROD OLD ECOM (live_db)       - porta 3306
  2) CROSS PROD (live_shopify)     - porta 3307
```

Também aceita argumento direto: `./start.sh 1`, `./start.sh cross-prod`, etc.

Cada banco roda em seu próprio container. Startar um **não interfere** no outro que já esteja rodando.

### Gerenciar containers individualmente

Parar apenas um:
```
docker stop mysql-shoplive
docker stop mysql-cross-prod
```

Iniciar apenas um:
```
docker start mysql-shoplive
docker start mysql-cross-prod
```

Replicar apenas um banco (com containers já rodando):
```
./replicate.sh old-ecom
./replicate.sh cross-prod
```

### Início Manual

1. Execute `docker compose up -d` para iniciar os dois containers.
2. Execute `./replicate.sh old-ecom` e `./replicate.sh cross-prod`.

## Replicação de Tabelas

O script `replicate.sh` replica tabelas do banco de produção para o container local correspondente. Tabelas excluídas (definidas em `EXCLUDE_TABLES` e padrões `bck_/cashback_/log*/historico*/*_bkp`) têm apenas a estrutura criada.

## Observações

- Credenciais são gerenciadas via `.env` (não commitado).
- Cada banco tem seu próprio volume Docker (dados independentes).
- Para parar tudo: `docker compose down`.
- Para remover dados: `docker compose down -v`.
