#!/bin/bash
set -e

# ============================================================
# Скрипт ОТКАТА изменений
# ============================================================

DC_DIR="/home/centos/dc_boomq/project-srv"
DC_FILE="dc.local.ent.project-srv.yml"
DC_PATH="$DC_DIR/$DC_FILE"
DC_BACKUP="${DC_PATH}.txt"

# ============================================================
# 1. ОТКАТ DOCKER-COMPOSE ФАЙЛА
# ============================================================
echo "==> [1/3] Откат docker-compose файла..."

if [ ! -f "$DC_BACKUP" ]; then
    echo "    ОШИБКА: Резервная копия ${DC_BACKUP} не найдена. Пропускаем."
else
    echo "    Останавливаем контейнер..."
    docker compose -f "$DC_PATH" down

    cp "$DC_BACKUP" "$DC_PATH"
    echo "    Файл восстановлен из резервной копии."

    echo "    Запускаем контейнер со старым конфигом..."
    docker compose -f "$DC_PATH" up -d --force-recreate

    echo "==> [1/3] Готово."
fi

# ============================================================
# 2. ОТКАТ БД: удаление триггера, функций и индекса
# ============================================================
echo ""
echo "==> [2/3] Удаление триггера, функций и индекса в БД..."

docker exec -i postgresql psql -U postgres << 'PSQL'

\c backend

DROP TRIGGER IF EXISTS trg_cleanup_sla ON sla_report_profile;
DROP FUNCTION IF EXISTS trigger_cleanup_sla();
DROP FUNCTION IF EXISTS cleanup_sla_safe();
DROP INDEX IF EXISTS ix_sla_report_profile_team_id_id;

PSQL

echo "==> [2/3] Готово."

# ============================================================
# 3. ОТКАТ postgresql.conf
# ============================================================
echo ""
echo "==> [3/3] Откат параметров postgresql.conf..."

docker exec -i postgresql bash << 'BASH'
CONF="/var/lib/postgresql/data/postgresql.conf"

sed -i '/^max_connections = 200$/d'        "$CONF"
sed -i '/^shared_buffers = 1GB$/d'         "$CONF"
sed -i '/^work_mem = 16MB$/d'              "$CONF"
sed -i '/^maintenance_work_mem = 256MB$/d' "$CONF"

echo "    Параметры удалены из postgresql.conf"
BASH

docker restart postgresql
echo "    Контейнер postgresql перезапущен."

echo ""
echo "==> [3/3] Готово."
echo ""
echo "============================================"
echo " Откат выполнен успешно!"
echo "============================================"