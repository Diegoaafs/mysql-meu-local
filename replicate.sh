#!/bin/bash

# Carregar variáveis de ambiente do arquivo .env
if [ -f .env ]; then
  export $(grep -v '^[[:space:]]*#' .env | xargs)
fi

# Receber escolha do banco
DB_CHOICE="${1:-old-ecom}"

case "$DB_CHOICE" in
  old-ecom)
    SRC_HOST="$PROD_HOST"
    SRC_USER="$PROD_USER"
    SRC_PASS="$PROD_PASS"
    SRC_DB="$PROD_DB"
    LOCAL_PORT="$OLD_ECOM_PORT"
    LOCAL_DB_PREFIX="shoplive"
    echo "Replicando de: PROD OLD ECOM ($SRC_DB) -> porta local $LOCAL_PORT"
    ;;
  cross-prod)
    SRC_HOST="$CROSS_HOST"
    SRC_USER="$CROSS_USER"
    SRC_PASS="$CROSS_PASS"
    SRC_DB="$CROSS_DB"
    LOCAL_PORT="$CROSS_PROD_PORT"
    LOCAL_DB_PREFIX="shopify"
    echo "Replicando de: CROSS PROD ($SRC_DB) -> porta local $LOCAL_PORT"
    ;;
  *)
    echo "Opção de banco inválida: $DB_CHOICE"
    exit 1
    ;;
esac

# Definir LOCAL_DB com prefixo claro e data atual
LOCAL_DB="${LOCAL_DB_PREFIX}_dump_$(date +%Y%m%d)"

# Script para replicar tabelas do banco de produção para o banco local MySQL no Docker
# As tabelas a replicar são definidas diretamente neste arquivo na variável TABLES

# Defina aqui as tabelas que não deseja replicar, separadas por espaço
EXCLUDE_TABLES="
  MV_busca_temp1
  MV_busca_temp_2
  async_process
  customer_queue_notifications
  customer_queue_notification_data
  encurtador_cliques
  estoqueLog
  failed_jobs
  idsNeomode
  logger
  pedidoNFTransito_log
  pedidoNotaFiscal
  tempSeguro
  "

# Criar pasta dump se não existir
mkdir -p ./dump

# Obter todas as tabelas do banco de produção
ALL_TABLES=$(mysql -h $SRC_HOST -u $SRC_USER -p"$SRC_PASS" -N -e "SHOW TABLES" $SRC_DB)

# Filtrar as tabelas excluídas
TABLES=""
for table in $ALL_TABLES; do
  skip_table=0
  # Verificar se está na lista de exclusão explícita
  for exclude in $EXCLUDE_TABLES; do
    if [ "$table" == "$exclude" ]; then
      skip_table=1
      break
    fi
  done
  # Verificar se começa com bck_, cashback_ e log ou termina com _bkp
  if [[ $table == bck_* ]] || [[ $table == cashback_* ]] || [[ $table == log* ]] || [[ $table == historico* ]] || [[ $table == *_bkp ]]; then
    skip_table=1
  fi
  if [ $skip_table -eq 0 ]; then
    TABLES="$TABLES $table"
  fi
done

if [ -z "$TABLES" ]; then
  echo "Erro: Nenhuma tabela para replicar após exclusão."
  exit 1
fi

# Criar banco local se não existir
mysql -h 127.0.0.1 -P $LOCAL_PORT -u root -prootpassword -e "CREATE DATABASE IF NOT EXISTS $LOCAL_DB; GRANT ALL PRIVILEGES ON $LOCAL_DB.* TO '$LOCAL_USER'@'%';"

VIEWS=""

echo "Iniciando replicação de tabelas: $TABLES"

for table in $TABLES; do
  echo "Processando tabela: $table"

  # Verificar se é uma view (views serão processadas depois)
  TABLE_TYPE=$(mysql -h $SRC_HOST -u $SRC_USER -p"$SRC_PASS" -N -e "SELECT TABLE_TYPE FROM information_schema.TABLES WHERE TABLE_SCHEMA='$SRC_DB' AND TABLE_NAME='$table';" 2>/dev/null)
  if [ "$TABLE_TYPE" == "VIEW" ]; then
    VIEWS="$VIEWS $table"
    echo "  - View detectada, será replicada após as tabelas: $table"
    continue
  fi

  # Dump da tabela de produção
  echo "  - Fazendo dump de $table do banco de produção..."
  mysqldump -h $SRC_HOST -u $SRC_USER -p"$SRC_PASS" --set-gtid-purged=OFF --skip-triggers $SRC_DB $table > ./dump/${table}.sql

  if [ $? -ne 0 ]; then
    echo "Erro ao fazer dump de $table. Verifique as credenciais e conexão."
    exit 1
  fi

  # Verificar se o dump não está vazio
  if [ ! -s ./dump/${table}.sql ]; then
    echo "  - Dump vazio para $table (tabela não existe ou está vazia), pulando."
    rm ./dump/${table}.sql
    continue
  fi

  # Importar para banco local
  echo "  - Importando $table para o banco local..."
  mysql -h 127.0.0.1 -P $LOCAL_PORT -u $LOCAL_USER -p"$LOCAL_PASS" $LOCAL_DB < ./dump/${table}.sql

  if [ $? -ne 0 ]; then
    echo "  - Erro ao importar $table com dados. Tentando criar apenas a estrutura..."
    # Dump apenas a estrutura da tabela
    mysqldump -h $SRC_HOST -u $SRC_USER -p"$SRC_PASS" --set-gtid-purged=OFF --skip-triggers --no-data $SRC_DB $table > ./dump/${table}_structure.sql
    if [ $? -eq 0 ] && [ -s ./dump/${table}_structure.sql ]; then
      # Importar apenas a estrutura
      mysql -h 127.0.0.1 -P $LOCAL_PORT -u $LOCAL_USER -p"$LOCAL_PASS" $LOCAL_DB < ./dump/${table}_structure.sql
      if [ $? -eq 0 ]; then
        echo "  - Estrutura da tabela $table criada com sucesso (sem dados)."
        rm ./dump/${table}.sql ./dump/${table}_structure.sql
      else
        echo "Erro ao criar estrutura de $table."
        rm ./dump/${table}.sql ./dump/${table}_structure.sql
        exit 1
      fi
    else
      echo "Erro ao fazer dump da estrutura de $table."
      rm ./dump/${table}.sql
      exit 1
    fi
    continue
  fi

  echo "  - Tabela $table replicada com sucesso."
  rm ./dump/${table}.sql
done

echo "Replicação concluída!"

echo "Processando tabelas excluídas para criar estrutura..."

EXCLUDED_TABLES=""
for table in $ALL_TABLES; do
  skip_table=0
  # Verificar se está na lista de exclusão explícita
  for exclude in $EXCLUDE_TABLES; do
    if [ "$table" == "$exclude" ]; then
      skip_table=1
      break
    fi
  done
  # Verificar se começa com bck_, cashback_ e log ou termina com _bkp
  if [[ $table == bck_* ]] || [[ $table == cashback_* ]] || [[ $table == log* ]] || [[ $table == historico* ]] || [[ $table == *_bkp ]]; then
    skip_table=1
  fi
  if [ $skip_table -eq 1 ]; then
    EXCLUDED_TABLES="$EXCLUDED_TABLES $table"
  fi
done

for table in $EXCLUDED_TABLES; do
  echo "Processando tabela excluída: $table"

  # Verificar se é uma view (views serão processadas no bloco de views)
  TABLE_TYPE=$(mysql -h $SRC_HOST -u $SRC_USER -p"$SRC_PASS" -N -e "SELECT TABLE_TYPE FROM information_schema.TABLES WHERE TABLE_SCHEMA='$SRC_DB' AND TABLE_NAME='$table';" 2>/dev/null)
  if [ "$TABLE_TYPE" == "VIEW" ]; then
    VIEWS="$VIEWS $table"
    echo "  - View excluída detectada, será replicada após as tabelas: $table"
    continue
  fi

  # Dump apenas a estrutura da tabela
  mysqldump -h $SRC_HOST -u $SRC_USER -p"$SRC_PASS" --set-gtid-purged=OFF --skip-triggers --no-data $SRC_DB $table > ./dump/${table}_structure.sql

  if [ $? -eq 0 ] && [ -s ./dump/${table}_structure.sql ]; then
    # Importar apenas a estrutura
    mysql -h 127.0.0.1 -P $LOCAL_PORT -u $LOCAL_USER -p"$LOCAL_PASS" $LOCAL_DB < ./dump/${table}_structure.sql
    if [ $? -eq 0 ]; then
      echo "  - Estrutura da tabela excluída $table criada com sucesso."
      rm ./dump/${table}_structure.sql
    else
      echo "Erro ao criar estrutura de $table."
      rm ./dump/${table}_structure.sql
    fi
  else
    echo "Erro ao fazer dump da estrutura de $table."
  fi
done

# Replicar views (após todas as tabelas estarem criadas)
if [ -n "$VIEWS" ]; then
  echo "Replicando views: $VIEWS"
  for view in $VIEWS; do
    echo "  - Fazendo dump da view $view..."
    mysqldump -h $SRC_HOST -u $SRC_USER -p"$SRC_PASS" --set-gtid-purged=OFF --skip-triggers $SRC_DB $view > ./dump/${view}_view.sql

    if [ $? -eq 0 ] && [ -s ./dump/${view}_view.sql ]; then
      mysql -h 127.0.0.1 -P $LOCAL_PORT -u $LOCAL_USER -p"$LOCAL_PASS" $LOCAL_DB < ./dump/${view}_view.sql
      if [ $? -eq 0 ]; then
        echo "  - View $view replicada com sucesso."
      else
        echo "  - Erro ao importar view $view."
      fi
      rm ./dump/${view}_view.sql
    else
      echo "  - Erro ao fazer dump da view $view."
      rm -f ./dump/${view}_view.sql
    fi
  done
else
  echo "Nenhuma view encontrada para replicar."
fi

DUMP_FILE="./dump/${LOCAL_DB}_$(date +%H%M%S).sql"
echo "Criando dump completo do banco local..."
mysqldump -h 127.0.0.1 -P $LOCAL_PORT -u $LOCAL_USER -p"$LOCAL_PASS" $LOCAL_DB > "$DUMP_FILE"

if [ $? -eq 0 ]; then
  echo "Dump completo criado em $DUMP_FILE"
else
  echo "Erro ao criar dump completo."
fi
