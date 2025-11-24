#!/bin/bash

# Скрипт проверки статуса Patroni и репликации PostgreSQL
# Использование: ./check_patroni_replication.sh <pod_name> <password> <port> <namespace> <patroni_version>

set -e

# Проверка аргументов
if [ $# -ne 5 ]; then
    echo "Использование: $0 <pod_name> <password> <port> <namespace> <patroni_version>"
    echo "  patroni_version: v2 или v4"
    exit 1
fi

POD_NAME=$1
PG_PASSWORD=$2
PORT=$3
NAMESPACE=$4
PATRONI_VERSION=$5

echo "=============================================="
echo "Проверка Patroni и репликации PostgreSQL"
echo "=============================================="
echo "Pod: $POD_NAME"
echo "Namespace: $NAMESPACE"
echo "Port: $PORT"
echo "Patroni version: $PATRONI_VERSION"
echo "=============================================="

# Функция для выполнения команд в pod
exec_in_pod() {
    kubectl exec -it -n $NAMESPACE $POD_NAME -- $@
}

# Функция для выполнения SQL запросов
exec_sql() {
    kubectl exec -it -n $NAMESPACE $POD_NAME -- bash -c "PGPASSWORD=$PG_PASSWORD psql -U postgres -p $PORT -Aqtc \"$1\""
}

# 1. Проверка статуса Patroni через API
echo -e "\n1. Статус Patroni через API:"
if [ "$PATRONI_VERSION" = "v4" ]; then
    echo "Запрос: curl -s http://127.0.0.1:8008/ | jq '{role, replication_state}'"
    result=$(kubectl exec -it -n $NAMESPACE $POD_NAME -- curl -s http://127.0.0.1:8008/ | jq '{role, replication_state}')
    echo "Результат: $result"
    expected='{"role":"standby_leader","replication_state":"streaming"}'
elif [ "$PATRONI_VERSION" = "v2" ]; then
    echo "Запрос: curl -s http://127.0.0.1:8008/ | jq -c '{role, state}'"
    result=$(kubectl exec -it -n $NAMESPACE $POD_NAME -- curl -s http://127.0.0.1:8008/ | jq -c '{role, state}')
    echo "Результат: $result"
    expected='{"role":"standby_leader","state":"running"}'
else
    echo "Неверная версия Patroni: $PATRONI_VERSION"
    exit 1
fi

# 2. Проверка через patronictl
echo -e "\n2. Статус через patronictl:"
exec_in_pod patronictl list

# 3. Проверка репликации в PostgreSQL
echo -e "\n3. Статус репликации:"
exec_sql "SELECT client_addr, state, sync_state, 
          pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) as replay_lag_bytes,
          pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) as replay_lag_pretty,
          EXTRACT(EPOCH FROM (now() - replay_lag_time)) as replay_lag_seconds
          FROM pg_stat_replication;"

# 4. Проверка лага репликации
echo -e "\n4. Лаг репликации (в байтах):"
exec_sql "SELECT pg_wal_lsn_diff(sent_lsn, replay_lsn) as replication_lag_bytes,
          pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) as replication_lag_pretty
          FROM pg_stat_replication;"

# 5. Проверка слотов репликации
echo -e "\n5. Слоты репликации:"
exec_sql "SELECT slot_name, plugin, slot_type, database, active, 
          pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) as restart_lag,
          pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) as confirmed_lag
          FROM pg_replication_slots;"

# 6. Размер базы данных
echo -e "\n6. Размер базы данных:"
exec_sql "SELECT datname, 
          pg_size_pretty(pg_database_size(datname)) as size 
          FROM pg_database 
          WHERE datistemplate = false 
          ORDER BY pg_database_size(datname) DESC;"

# 7. Общий размер data directory
echo -e "\n7. Размер data directory (реальный):"
echo "Команда: du -smx /home/postgres/pgdata/pgroot/data"
exec_in_pod du -smx /home/postgres/pgdata/pgroot/data

# 8. Проверка активности WAL
echo -e "\n8. Активность WAL:"
exec_sql "SELECT pg_current_wal_lsn(), 
          pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0') as total_wal_bytes,
          pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0')) as total_wal_pretty;"

# 9. Проверка статуса репликации из pg_stat_wal_receiver
echo -e "\n9. Статус получения WAL (для standby):"
exec_sql "SELECT status, last_msg_send_time, last_msg_receipt_time,
          latest_end_lsn, latest_end_time,
          pg_wal_lsn_diff(pg_current_wal_lsn(), latest_end_lsn) as lag_bytes,
          pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), latest_end_lsn)) as lag_pretty
          FROM pg_stat_wal_receiver;"

# 10. Проверка табличных пространств
echo -e "\n10. Табличные пространства:"
exec_sql "SELECT spcname, 
          pg_tablespace_location(oid) as location,
          pg_size_pretty(pg_tablespace_size(oid)) as size 
          FROM pg_tablespace 
          WHERE spcname != 'pg_default';"

# 11. Проверка подключений
echo -e "\n11. Активные подключения:"
exec_sql "SELECT datname, usename, state, count(*) 
          FROM pg_stat_activity 
          WHERE state IS NOT NULL 
          GROUP BY datname, usename, state 
          ORDER BY count DESC;"

# 12. Мониторинг в реальном времени (однократный снимок)
echo -e "\n12. Мониторинг размера data directory (watch можно запустить отдельно):"
echo "Для мониторинга в реальном времени выполните:"
echo "kubectl exec -i -n $NAMESPACE $POD_NAME -- watch -tn1 \"du -smx /home/postgres/pgdata/pgroot/data/base\""

# 13. Сравнение размеров кластеров (пример для двух кластеров)
echo -e "\n13. Сравнение размеров кластеров:"
echo "Для сравнения размеров между старым и новым кластером выполните:"
echo "# В старом кластере:"
echo "kubectl exec -it -n <old_namespace> <old_pod> -- bash -c \"PGPASSWORD=<password> psql -U postgres -p <port> -Aqtc \\\"SELECT pg_size_pretty(sum(pg_database_size(datname))) FROM pg_database WHERE datistemplate = false;\\\"\""
echo ""
echo "# В новом кластере:"
echo "kubectl exec -it -n $NAMESPACE $POD_NAME -- bash -c \"PGPASSWORD=$PG_PASSWORD psql -U postgres -p $PORT -Aqtc \\\"SELECT pg_size_pretty(sum(pg_database_size(datname))) FROM pg_database WHERE datistemplate = false;\\\"\""

echo -e "\n=============================================="
echo "Проверка завершена"
echo "=============================================="

# Дополнительные полезные команды
echo -e "\nДополнительные команды для мониторинга:"
echo "1. Панель мониторинга Patroni:"
echo "   kubectl exec -it -n $NAMESPACE $POD_NAME -- patronictl list"
echo ""
echo "2. Топ самых больших таблиц:"
echo "   kubectl exec -it -n $NAMESPACE $POD_NAME -- bash -c \"PGPASSWORD=$PG_PASSWORD psql -U postgres -p $PORT -c \\\"SELECT schemaname, tablename, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as size FROM pg_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema') ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC LIMIT 10;\\\"\""
echo ""
echo "3. Мониторинг репликации в реальном времени:"
echo "   watch -n1 'kubectl exec -it -n $NAMESPACE $POD_NAME -- patronictl list'"
echo ""
echo "4. Проверка лага через API всех нод:"
echo "   kubectl get pods -n $NAMESPACE -l app=postgres -o name | xargs -I {} kubectl exec -n $NAMESPACE {} -- curl -s http://127.0.0.1:8008/ | jq '{role, state, lag}'"