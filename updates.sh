#!/bin/bash
set -e

# ============================================================
# Скрипт автоматизации: конфиг, БД, postgres.conf
# ============================================================

DC_DIR="/home/centos/dc_boomq/project-srv"
DC_FILE="dc.local.ent.project-srv.yml"
DC_PATH="$DC_DIR/$DC_FILE"

# ============================================================
# 1. КОНФИГУРАЦИОННЫЙ ФАЙЛ И ПЕРЕЗАПУСК КОНТЕЙНЕРА
# ============================================================
echo "==> [1/3] Обновление docker-compose файла..."

# 1.1 Копируем старый файл с расширением .txt
if [ -f "$DC_PATH" ]; then
    cp "$DC_PATH" "${DC_PATH}.txt"
    echo "    Резервная копия создана: ${DC_FILE}.txt"
else
    echo "    ВНИМАНИЕ: Файл $DC_PATH не найден, создаём новый."
fi

# 1.2 Записываем новый docker-compose файл
cat > "$DC_PATH" << 'EOF'
version: "3.7"

services:
  project-srv:
    image: 284940552014.dkr.ecr.us-east-1.amazonaws.com/ent_project_srv:${backend_tag}
    container_name: project_srv
    hostname: project-srv
    restart: always

    environment:
      - SPRING_PROFILES_ACTIVE=docker
      - SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE=30
      - SPRING_DATASOURCE_HIKARI_MINIMUM_IDLE=10
      - SPRING_DATASOURCE_HIKARI_CONNECTION_TIMEOUT=30000
      - SPRING_DATASOURCE_HIKARI_IDLE_TIMEOUT=600000
      - SPRING_DATASOURCE_HIKARI_MAX_LIFETIME=1800000

    command: ["java","-Xms2g","-Xmx2g","-jar","/app/project-service-1.0.0.jar"]

    mem_limit: 4g
    mem_reservation: 3g
    cpus: "4.0"

    ports:
      - "7050:7050"
      - "7051:7051"
      - "7055:7055"

    networks:
      - boomq_network

    volumes:
      - /etc/machine-id:/etc/machine-id:rw

    healthcheck:
      test: wget localhost:7051/actuator/health -q -O - | grep "\"status\":\"UP\"" || exit 1
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 1m30s

    logging:
      driver: "json-file"
      options:
        max-size: "100Mb"
        max-file: "10"

networks:
  boomq_network:
    external: true
EOF

echo "    Новый docker-compose файл записан."

# 1.3 Останавливаем контейнер
echo "    Останавливаем контейнер..."
docker compose -f "$DC_PATH" down

# 1.4 Запускаем контейнер
echo "    Запускаем контейнер..."
docker compose -f "$DC_PATH" up -d --force-recreate

echo "==> [1/3] Готово."

# ============================================================
# 2. ОЧИСТКА БД
# ============================================================
echo ""
echo "==> [2/3] Очистка БД и создание триггера..."

docker exec -i postgresql psql -U postgres << 'PSQL'

-- Очистка project
\c project

DELETE FROM project_version 
WHERE test_project_id IN (SELECT id FROM test_project WHERE team_id = 21);

DELETE FROM test_project WHERE team_id = 21;

-- Очистка backend (тесты)
\c backend

BEGIN;

DELETE FROM test_result_charts_data 
WHERE test_id IN (SELECT id FROM test_v2 WHERE team_id = 21);

DELETE FROM test_result_files_data 
WHERE test_id IN (SELECT id FROM test_v2 WHERE team_id = 21);

DELETE FROM test_result_sla_data 
WHERE test_id IN (SELECT id FROM test_v2 WHERE team_id = 21);

DELETE FROM test_label 
WHERE test_id IN (SELECT id FROM test_v2 WHERE team_id = 21);

DELETE FROM test_resources_estimate 
WHERE test_id IN (SELECT id FROM test_v2 WHERE team_id = 21);

DELETE FROM test_error 
WHERE test_id IN (SELECT id FROM test_v2 WHERE team_id = 21);

DELETE FROM test_result 
WHERE test_id IN (SELECT id FROM test_v2 WHERE team_id = 21);

DELETE FROM test_v2 WHERE team_id = 21;

COMMIT;

-- Очистка sla_report_profile
\c backend

DELETE FROM sla_report_profile WHERE team_id = 21;

-- Очистка report
\c report

DELETE FROM report WHERE team_id = 21;

-- Создание индекса и триггера
\c backend

CREATE INDEX IF NOT EXISTS ix_sla_report_profile_team_id_id
ON sla_report_profile (team_id, id);

CREATE OR REPLACE FUNCTION cleanup_sla_safe()
RETURNS INTEGER AS $$
DECLARE
    deleted_count INTEGER := 0;
    got_lock BOOLEAN;
BEGIN
    got_lock := pg_try_advisory_lock(21, 400);
    
    IF NOT got_lock THEN
        RETURN 0;
    END IF;
    
    WITH need AS (
        SELECT EXISTS (
            SELECT 1
            FROM sla_report_profile
            WHERE team_id = 21
            ORDER BY id DESC
            OFFSET 400
            LIMIT 1
        ) AS need_cleanup
    ),
    del AS (
        SELECT id
        FROM sla_report_profile
        WHERE team_id = 21
        ORDER BY id ASC
        LIMIT 100
    ),
    deleted AS (
        DELETE FROM sla_report_profile
        WHERE (SELECT need_cleanup FROM need)
          AND id IN (SELECT id FROM del)
        RETURNING id
    )
    SELECT COUNT(*) INTO deleted_count FROM deleted;
    
    PERFORM pg_advisory_unlock(21, 400);
    
    RETURN deleted_count;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION trigger_cleanup_sla()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM cleanup_sla_safe();
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_cleanup_sla ON sla_report_profile;

CREATE TRIGGER trg_cleanup_sla
AFTER INSERT ON sla_report_profile
FOR EACH STATEMENT
EXECUTE FUNCTION trigger_cleanup_sla();

PSQL

echo "==> [2/3] Готово."

# ============================================================
# 3. ИЗМЕНЕНИЕ postgresql.conf И ПЕРЕЗАПУСК POSTGRES
# ============================================================
echo ""
echo "==> [3/3] Обновление postgresql.conf..."

docker exec -i postgresql bash << 'BASH'
cd /var/lib/postgresql/data

echo "max_connections = 200"      >> postgresql.conf
echo "shared_buffers = 1GB"       >> postgresql.conf
echo "work_mem = 16MB"            >> postgresql.conf
echo "maintenance_work_mem = 256MB" >> postgresql.conf

echo "    Параметры добавлены в postgresql.conf"
BASH

docker restart postgresql
echo "    Контейнер postgresql перезапущен."

echo ""
echo "==> [3/3] Готово."
echo ""
echo "============================================"
echo " Все шаги выполнены успешно!"
echo "============================================"