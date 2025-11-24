#!/bin/bash

# Скрипт проверки статуса Patroni и репликации PostgreSQL
# Использование: ./check_patroni_replication.sh <pod_name> <port> <namespace> <patroni_version> [password]

set -e

# Проверка аргументов
if [ $# -lt 4 ]; then
    echo "Использование: $0 <pod_name> <port> <namespace> <patroni_version> [password]"
    echo "  patroni_version: v2 или v4"
    echo "  password: опционально - если не указан, будет получен из секрета"
    exit 1
fi

POD_NAME=$1
PORT=$2
NAMESPACE=$3
PATRONI_VERSION=$4
PG_PASSWORD=$5

# Функция для извлечения базового имени пода (без числового суффикса)
get_base_pod_name() {
    echo "$1" | sed 's/-[0-9]\+$//'
}

# Функция для выбора секрета из списка
select_secret() {
    local secrets=("$@")
    
    echo "Найдено несколько подходящих секретов:" >&2
    echo "----------------------------------------" >&2
    
    local i=1
    for secret in "${secrets[@]}"; do
        echo "$i) $secret" >&2
        ((i++))
    done
    
    echo "----------------------------------------" >&2
    
    while true; do
        read -p "Выберите номер секрета (1-${#secrets[@]}): " selection
        
        # Проверяем, что ввод является числом и в диапазоне
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#secrets[@]}" ]; then
            local selected_index=$((selection - 1))
            echo "${secrets[$selected_index]}"
            return 0
        else
            echo "Неверный выбор. Пожалуйста, введите число от 1 до ${#secrets[@]}." >&2
        fi
    done
}

# Функция для получения пароля из секрета
get_password_from_secret() {
    local base_pod_name=$(get_base_pod_name "$POD_NAME")
    
    echo "Поиск секретов для пода: $POD_NAME (базовое имя: $base_pod_name)" >&2
    echo "Пространство имен: $NAMESPACE" >&2
    
    # Получаем все секреты в неймспейсе
    local all_secrets=($(kubectl get secrets -n $NAMESPACE --no-headers -o custom-columns=":metadata.name" 2>/dev/null))
    
    if [ ${#all_secrets[@]} -eq 0 ]; then
        echo "Ошибка: в неймспейсе $NAMESPACE не найдено ни одного секрета" >&2
        return 1
    fi
    
    echo "Всего секретов в неймспейсе: ${#all_secrets[@]}" >&2
    
    # Фильтруем секреты по критериям:
    # 1. Содержит часть имени пода (без числового суффикса)
    # 2. ИЛИ содержит ключевые слова: acid, psql, postgresql, postgres
    local filtered_secrets=()
    for secret in "${all_secrets[@]}"; do
        # Проверяем, содержит ли секрет базовое имя пода
        if [[ "$secret" == *"$base_pod_name"* ]]; then
            filtered_secrets+=("$secret")
            continue
        fi
        
        # Проверяем ключевые слова
        if [[ "$secret" == *"acid"* ]] || \
           [[ "$secret" == *"psql"* ]] || \
           [[ "$secret" == *"postgresql"* ]] || \
           [[ "$secret" == *"postgres"* ]]; then
            filtered_secrets+=("$secret")
        fi
    done
    
    if [ ${#filtered_secrets[@]} -eq 0 ]; then
        echo "Ошибка: не найдено подходящих секретов" >&2
        echo "Критерии поиска:" >&2
        echo "  - Содержит имя пода: $base_pod_name" >&2
        echo "  - ИЛИ содержит ключевые слова: acid, psql, postgresql, postgres" >&2
        echo "Доступные секреты в неймспейсе $NAMESPACE:" >&2
        printf '  %s\n' "${all_secrets[@]}" >&2
        return 1
    fi
    
    echo "Найдено ${#filtered_secrets[@]} подходящих секретов:" >&2
    for secret in "${filtered_secrets[@]}"; do
        echo "  - $secret" >&2
    done
    
    # Сортируем секреты по релевантности (сначала те, что содержат имя пода)
    local sorted_secrets=()
    for secret in "${filtered_secrets[@]}"; do
        if [[ "$secret" == *"$base_pod_name"* ]]; then
            # Секреты с именем пода добавляем в начало
            sorted_secrets=("$secret" "${sorted_secrets[@]}")
        else
            # Остальные добавляем в конец
            sorted_secrets+=("$secret")
        fi
    done
    
    local secret_name
    if [ ${#sorted_secrets[@]} -eq 1 ]; then
        secret_name="${sorted_secrets[0]}"
        echo "Используется единственный подходящий секрет: $secret_name" >&2
    else
        echo "Найдено ${#sorted_secrets[@]} подходящих секретов" >&2
        secret_name=$(select_secret "${sorted_secrets[@]}")
        echo "Выбран секрет: $secret_name" >&2
    fi
    
    # Попробуем разные возможные ключи в секрете
    local password_keys=("password" "postgres-password" "pgpassword" "postgresql-password" "postgresql-postgres-password" "patroni-password")
    
    echo "Поиск пароля в секрете $secret_name..." >&2
    
    # Получаем все данные секрета для отладки
    local secret_data=$(kubectl get secret -n $NAMESPACE "$secret_name" -o json 2>/dev/null)
    
    for key in "${password_keys[@]}"; do
        echo "  Проверка ключа: $key" >&2
        local password=$(echo "$secret_data" | jq -r ".data.\"$key\" // empty" 2>/dev/null | base64 -d 2>/dev/null)
        if [ -n "$password" ] && [ "$password" != "null" ]; then
            echo "  Пароль найден в ключе: $key" >&2
            echo "$password"
            return 0
        fi
    done
    
    # Если не нашли по стандартным ключам, покажем доступные ключи
    echo "Доступные ключи в секрете $secret_name:" >&2
    echo "$secret_data" | jq -r '.data | keys[]' >&2
    
    # Попробуем получить пароль напрямую через kubectl
    echo "Попытка прямого извлечения пароля..." >&2
    local direct_password=$(kubectl get secret -n $NAMESPACE "$secret_name" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)
    if [ -n "$direct_password" ] && [ "$direct_password" != "null" ]; then
        echo "Пароль найден через прямое извлечение" >&2
        echo "$direct_password"
        return 0
    fi
    
    echo "Ошибка: не удалось извлечь пароль из секрета $secret_name" >&2
    echo "Попробуйте указать пароль явно в аргументах скрипта" >&2
    return 1
}

# Если пароль не передан как аргумент, получаем его из секрета
if [ -z "$PG_PASSWORD" ]; then
    echo "Пароль не указан, получение из секрета..."
    PG_PASSWORD=$(get_password_from_secret)
    if [ $? -ne 0 ]; then
        exit 1
    fi
    echo "Пароль успешно получен из секрета"
else
    echo "Используется пароль из аргументов"
fi

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
    # Экранируем кавычки в SQL запросе для корректной передачи
    local sql_query=$(echo "$1" | sed 's/"/\\"/g')
    kubectl exec -it -n $NAMESPACE $POD_NAME -- bash -c "PGPASSWORD=\"$PG_PASSWORD\" psql -U postgres -Aqtc \"$sql_query\""
}

# 1. Проверка статуса Patroni через API
echo -e "\n1. Статус Patroni через API:"
if [ "$PATRONI_VERSION" = "v4" ]; then
    echo "Запрос: curl -s http://127.0.0.1:8008/ | jq '{role, replication_state}'"
    result=$(kubectl exec -it -n $NAMESPACE $POD_NAME -- curl -s http://127.0.0.1:8008/ 2>/dev/null | jq '{role, replication_state}' 2>/dev/null || echo "Ошибка при запросе к API")
    echo "Результат: $result"
    expected='{"role":"standby_leader","replication_state":"streaming"}'
elif [ "$PATRONI_VERSION" = "v2" ]; then
    echo "Запрос: curl -s http://127.0.0.1:8008/ | jq -c '{role, state}'"
    result=$(kubectl exec -it -n $NAMESPACE $POD_NAME -- curl -s http://127.0.0.1:8008/ 2>/dev/null | jq -c '{role, state}' 2>/dev/null || echo "Ошибка при запросе к API")
    echo "Результат: $result"
    expected='{"role":"standby_leader","state":"running"}'
else
    echo "Неверная версия Patroni: $PATRONI_VERSION"
    exit 1
fi

# 2. Проверка через patronictl
echo -e "\n2. Статус через patronictl:"
exec_in_pod patronictl list 2>/dev/null || echo "Ошибка при выполнении patronictl list"

# 3. Проверка репликации в PostgreSQL
echo -e "\n3. Статус репликации:"
exec_sql "SELECT client_addr, state, sync_state,
pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) as replay_lag_bytes,
pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) as replay_lag_pretty,
EXTRACT(EPOCH FROM (now() - reply_time)) as replay_lag_seconds
FROM pg_stat_replication;" 2>/dev/null || echo "Ошибка при выполнении SQL запроса"

# 4. Проверка лага репликации
echo -e "\n4. Лаг репликации (в байтах):"
exec_sql "SELECT pg_wal_lsn_diff(sent_lsn, replay_lsn) as replication_lag_bytes,
          pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) as replication_lag_pretty
          FROM pg_stat_replication;" 2>/dev/null || echo "Ошибка при выполнении SQL запроса"

# 5. Проверка слотов репликации
echo -e "\n5. Слоты репликации:"
exec_sql "SELECT slot_name, plugin, slot_type, database, active, 
          pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) as restart_lag,
          pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) as confirmed_lag
          FROM pg_replication_slots;" 2>/dev/null || echo "Ошибка при выполнении SQL запроса"

# 6. Размер базы данных
echo -e "\n6. Размер базы данных:"
exec_sql "SELECT datname, 
          pg_size_pretty(pg_database_size(datname)) as size 
          FROM pg_database 
          WHERE datistemplate = false 
          ORDER BY pg_database_size(datname) DESC;" 2>/dev/null || echo "Ошибка при выполнении SQL запроса"

# 7. Общий размер data directory
echo -e "\n7. Размер data directory (реальный):"
echo "Команда: du -smx /home/postgres/pgdata/pgroot/data"
exec_in_pod du -smxh     /home/postgres/pgdata/pgroot/data 2>/dev/null || echo "Ошибка при проверке размера data directory"

# 8. Проверка активности WAL
echo -e "\n8. Активность WAL:"
exec_sql "SELECT pg_last_wal_receive_lsn() as last_receive_lsn,
       pg_last_wal_replay_lsn() as last_replay_lsn,
       pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()) as replay_lag_bytes,
       pg_size_pretty(pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())) as replay_lag_pretty,
       pg_is_wal_replay_paused() as is_replay_paused;" 2>/dev/null || echo "Ошибка при выполнении SQL запроса"

# 9. Проверка статуса репликации из pg_stat_wal_receiver
echo -e "\n9. Статус получения WAL (для standby):"
exec_sql "SELECT status, last_msg_send_time, last_msg_receipt_time,
       latest_end_lsn, latest_end_time,
       pg_wal_lsn_diff(pg_last_wal_replay_lsn(), latest_end_lsn) as lag_bytes,
       pg_size_pretty(pg_wal_lsn_diff(pg_last_wal_replay_lsn(), latest_end_lsn)) as lag_pretty
FROM pg_stat_wal_receiver;" 2>/dev/null || echo "Ошибка при выполнении SQL запроса"

# 10. Проверка табличных пространств
echo -e "\n10. Табличные пространства:"
exec_sql "SELECT spcname, 
          pg_tablespace_location(oid) as location,
          pg_size_pretty(pg_tablespace_size(oid)) as size 
          FROM pg_tablespace 
          WHERE spcname != 'pg_default';" 2>/dev/null || echo "Ошибка при выполнении SQL запроса"

# 11. Проверка подключений
echo -e "\n11. Активные подключения:"
exec_sql "SELECT datname, usename, state, count(*) 
          FROM pg_stat_activity 
          WHERE state IS NOT NULL 
          GROUP BY datname, usename, state 
          ORDER BY count DESC;" 2>/dev/null || echo "Ошибка при выполнении SQL запроса"

echo -e "\n=============================================="
echo "Проверка завершена"
echo "=============================================="

# Дополнительные полезные команды
echo -e "\nДополнительные команды для мониторинга:"
echo "1. Панель мониторинга Patroni:"
echo "   kubectl exec -it -n $NAMESPACE $POD_NAME -- patronictl list"
echo ""
echo "2. Топ самых больших таблиц:"
echo "   kubectl exec -it -n $NAMESPACE $POD_NAME -- bash -c \"PGPASSWORD=\"$PG_PASSWORD\" psql -U postgres -p $PORT -c \\\"SELECT schemaname, tablename, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as size FROM pg_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema') ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC LIMIT 10;\\\"\""
echo ""
echo "3. Мониторинг репликации в реальном времени:"
echo "   watch -n1 'kubectl exec -it -n $NAMESPACE $POD_NAME -- patronictl list'"