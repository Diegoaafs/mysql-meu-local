#!/bin/bash

# Script para iniciar um MySQL local e replicar o banco escolhido

# Garantir que estamos no diretório do script
cd "$(dirname "$0")" || exit 1

# Carregar variáveis de ambiente
if [ -f .env ]; then
  export $(grep -v '^[[:space:]]*#' .env | xargs)
fi

# Menu de seleção
DB_CHOICE="${1:-}"

if [ -z "$DB_CHOICE" ]; then
  echo "========================================="
  echo "  Escolha o banco para replicar:"
  echo "========================================="
  echo "  1) PROD OLD ECOM (live_db)       - porta $OLD_ECOM_PORT"
  echo "  2) CROSS PROD (live_shopify)     - porta $CROSS_PROD_PORT"
  echo "========================================="
  printf "Opção [1/2]: "
  read -r DB_CHOICE
fi

case "$DB_CHOICE" in
  1|old-ecom)
    CONTAINER="mysql-shoplive"
    SERVICE="mysql-shoplive"
    PORT="$OLD_ECOM_PORT"
    REPLICATE_ARG="old-ecom"
    echo "Banco selecionado: PROD OLD ECOM (live_db) - porta $PORT"
    ;;
  2|cross-prod)
    CONTAINER="mysql-cross-prod"
    SERVICE="mysql-cross-prod"
    PORT="$CROSS_PROD_PORT"
    REPLICATE_ARG="cross-prod"
    echo "Banco selecionado: CROSS PROD (live_shopify) - porta $PORT"
    ;;
  *)
    echo "Opção inválida."
    exit 1
    ;;
esac

# Verificar se o container selecionado já está rodando
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
  echo "Container $CONTAINER já está rodando."
else
  # Remover container parado se existir
  if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    echo "Removendo container $CONTAINER parado..."
    docker rm -f "$CONTAINER"
  fi

  echo "Iniciando container $CONTAINER..."
  if ! docker compose up -d "$SERVICE"; then
    echo "Erro ao iniciar o container $CONTAINER."
    exit 1
  fi
  echo "Aguardando o banco ficar pronto..."
  sleep 15
fi

# Garantir que o usuário local tenha privilégio para alterar variáveis globais
# (ex.: SET GLOBAL log_bin_trust_function_creators). Idempotente.
echo "Garantindo privilégios SYSTEM_VARIABLES_ADMIN para $LOCAL_USER..."
docker exec "$CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e \
  "GRANT SYSTEM_VARIABLES_ADMIN, SESSION_VARIABLES_ADMIN ON *.* TO '$LOCAL_USER'@'%'; FLUSH PRIVILEGES;" 2>/dev/null \
  || echo "Aviso: não foi possível conceder privilégios (container pode não estar pronto)."

# Executar a replicação apenas do banco escolhido
./replicate.sh "$REPLICATE_ARG"
