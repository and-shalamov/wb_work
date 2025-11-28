#!/bin/bash

# Скрипт проверки статуса Patroni и репликации PostgreSQL
# Использование: ./check_patroni_replication.sh <pod_name> <port> <namespace> <patroni_version> [password]

set -e

# Цвета для вывода
RED='\033[0;31m'
LIGHT_RED='\033[1;31m'  # Добавьте эту строку
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
ORANGE='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Проверка аргументов
if [ $# -lt 4 ]; then
    echo -e "${RED}${BOLD}Использование: $0 <pod_name> <port> <namespace> <patroni_version> [password]${NC}"
    echo -e "  ${YELLOW}patroni_version: v2 или v4${NC}"
    echo -e "  ${YELLOW}password: опционально - если не указан, будет получен из секрета${NC}"
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
    
    echo -e "${YELLOW}Найдено несколько подходящих секретов:${NC}" >&2
    echo -e "${YELLOW}----------------------------------------${NC}" >&2
    
    local i=1
    for secret in "${secrets[@]}"; do
        echo -e "${YELLOW}$i) $secret${NC}" >&2
        ((i++))
    done
    
    echo -e "${YELLOW}----------------------------------------${NC}" >&2
    
    while true; do
        read -p "$(echo -e ${YELLOW}"Выберите номер секрета (1-${#secrets[@]}): "${NC})" selection
        
        # Проверяем, что ввод является числом и в диапазоне
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#secrets[@]}" ]; then
            local selected_index=$((selection - 1))
            echo "${secrets[$selected_index]}"
            return 0
        else
            echo -e "${RED}Неверный выбор. Пожалуйста, введите число от 1 до ${#secrets[@]}.${NC}" >&2
        fi
    done
}

# Функция для получения пароля из секрета
get_password_from_secret() {
    local base_pod_name=$(get_base_pod_name "$POD_NAME")
    
    # Извлекаем имя ветки из имени пода (часть между дефисами, соответствующая ветке)
    local branch_name=$(echo "$POD_NAME" | grep -oE '-(main|stage[0-9]+|prod|dev|test)-' | sed 's/-//g')
    
    # Если не удалось извлечь по шаблону, берем предпоследнюю часть
    if [ -z "$branch_name" ]; then
        branch_name=$(echo "$POD_NAME" | awk -F'-' '{print $(NF-1)}')
    fi
    
    echo -e "${CYAN}Поиск секретов для пода: $POD_NAME (базовое имя: $base_pod_name, ветка: $branch_name)${NC}" >&2
    echo -e "${CYAN}Пространство имен: $NAMESPACE${NC}" >&2
    
    # Получаем все секреты в неймспейсе
    local all_secrets=($(kubectl get secrets -n $NAMESPACE --no-headers -o custom-columns=":metadata.name" 2>/dev/null))
    
    if [ ${#all_secrets[@]} -eq 0 ]; then
        echo -e "${RED}Ошибка: в неймспейсе $NAMESPACE не найдено ни одного секрета${NC}" >&2
        return 1
    fi
    
    echo -e "${CYAN}Всего секретов в неймспейсе: ${#all_secrets[@]}${NC}" >&2
    
    # Фильтруем секреты: должны содержать имя ветки И одно из ключевых слов
    local filtered_secrets=()
    for secret in "${all_secrets[@]}"; do
        if [[ "$secret" == *"$branch_name"* ]] && 
           ([[ "$secret" == *"acid"* ]] || [[ "$secret" == *"postgres"* ]] || [[ "$secret" == *"psql"* ]]); then
            filtered_secrets+=("$secret")
        fi
    done
    
    if [ ${#filtered_secrets[@]} -eq 0 ]; then
        echo -e "${RED}Ошибка: не найдено секретов для ветки '$branch_name' с ключевыми словами (acid|postgres|psql)${NC}" >&2
        echo -e "${YELLOW}Критерии поиска:${NC}" >&2
        echo -e "${YELLOW}  - Содержит ветку: $branch_name${NC}" >&2
        echo -e "${YELLOW}  - И содержит одно из: acid, postgres, psql${NC}" >&2
        echo -e "${YELLOW}Доступные секреты в неймспейсе $NAMESPACE:${NC}" >&2
        printf '  %s\n' "${all_secrets[@]}" >&2
        return 1
    fi
    
    echo -e "${GREEN}Найдено ${#filtered_secrets[@]} секретов для ветки '$branch_name' с ключевыми словами:${NC}" >&2
    for secret in "${filtered_secrets[@]}"; do
        echo -e "  ${GREEN}- $secret${NC}" >&2
    done
    
    # Сортируем секреты для удобства выбора
    local sorted_secrets=($(printf '%s\n' "${filtered_secrets[@]}" | sort))
    
    local secret_name
    if [ ${#sorted_secrets[@]} -eq 1 ]; then
        secret_name="${sorted_secrets[0]}"
        echo -e "${GREEN}Используется единственный подходящий секрет: $secret_name${NC}" >&2
    else
        echo -e "${CYAN}Найдено ${#sorted_secrets[@]} секретов для ветки '$branch_name'${NC}" >&2
        secret_name=$(select_secret "${sorted_secrets[@]}")
        echo -e "${GREEN}Выбран секрет: $secret_name${NC}" >&2
    fi
    
    # Попробуем разные возможные ключи в секрете
    local password_keys=("password" "postgres-password" "pgpassword" "postgresql-password" "postgresql-postgres-password" "patroni-password")
    
    echo -e "${CYAN}Поиск пароля в секрете $secret_name...${NC}" >&2
    
    # Получаем все данные секрета для отладки
    local secret_data=$(kubectl get secret -n $NAMESPACE "$secret_name" -o json 2>/dev/null)
    
    for key in "${password_keys[@]}"; do
        echo -e "  ${CYAN}Проверка ключа: $key${NC}" >&2
        local password=$(echo "$secret_data" | jq -r ".data.\"$key\" // empty" 2>/dev/null | base64 -d 2>/dev/null)
        if [ -n "$password" ] && [ "$password" != "null" ]; then
            echo -e "  ${GREEN}Пароль найден в ключе: $key${NC}" >&2
            echo "$password"
            return 0
        fi
    done
    
    # Если не нашли по стандартным ключам, покажем доступные ключи
    echo -e "${YELLOW}Доступные ключи в секрете $secret_name:${NC}" >&2
    echo "$secret_data" | jq -r '.data | keys[]' >&2
    
    # Попробуем получить пароль напрямую через kubectl
    echo -e "${CYAN}Попытка прямого извлечения пароля...${NC}" >&2
    local direct_password=$(kubectl get secret -n $NAMESPACE "$secret_name" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)
    if [ -n "$direct_password" ] && [ "$direct_password" != "null" ]; then
        echo -e "${GREEN}Пароль найден через прямое извлечение${NC}" >&2
        echo "$direct_password"
        return 0
    fi
    
    echo -e "${RED}Ошибка: не удалось извлечь пароль из секрета $secret_name${NC}" >&2
    echo -e "${YELLOW}Попробуйте указать пароль явно в аргументах скрипта${NC}" >&2
    return 1
}

# Функция для получения логов пода
get_pod_logs() {
    kubectl logs -n $NAMESPACE $POD_NAME --tail=100 2>/dev/null || echo -e "${RED}Не удалось получить логи пода${NC}"
}

# Функция для вывода логов с цветовым кодированием
show_pod_logs() {
    local all_logs="$1"
    
    echo -e "\n${PURPLE}${BOLD}12. Логи пода (последние 5 сообщений каждого уровня):${NC}"
    
    # ERROR логи (красный)
    echo -e "\n${RED}${BOLD}ERROR логи:${NC}"
    echo "$all_logs" | grep -i "error" | tail -5 | while read line; do
        echo -e "${RED}$line${NC}"
    done
    if [ $(echo "$all_logs" | grep -i "error" | tail -5 | wc -l) -eq 0 ]; then
        echo -e "${GREEN}Нет ERROR сообщений${NC}"
    fi
    
    # WARN логи (оранжевый)
    echo -e "\n${ORANGE}${BOLD}WARN логи:${NC}"
    echo "$all_logs" | grep -i "warn" | tail -5 | while read line; do
        echo -e "${ORANGE}$line${NC}"
    done
    if [ $(echo "$all_logs" | grep -i "warn" | tail -5 | wc -l) -eq 0 ]; then
        echo -e "${GREEN}Нет WARN сообщений${NC}"
    fi
    
    # INFO логи (синий)
    echo -e "\n${BLUE}${BOLD}INFO логи:${NC}"
    echo "$all_logs" | grep -i "info" | tail -5 | while read line; do
        echo -e "${BLUE}$line${NC}"
    done
    if [ $(echo "$all_logs" | grep -i "info" | tail -5 | wc -l) -eq 0 ]; then
        echo -e "${GREEN}Нет INFO сообщений${NC}"
    fi
    
    # DEBUG логи (голубой)
    echo -e "\n${CYAN}${BOLD}DEBUG логи:${NC}"
    echo "$all_logs" | grep -i "debug" | tail -5 | while read line; do
        echo -e "${CYAN}$line${NC}"
    done
    if [ $(echo "$all_logs" | grep -i "debug" | tail -5 | wc -l) -eq 0 ]; then
        echo -e "${GREEN}Нет DEBUG сообщений${NC}"
    fi
    
    # FATAL логи (фиолетовый + красный фон)
    echo -e "\n${PURPLE}${BOLD}FATAL логи:${NC}"
    echo "$all_logs" | grep -i "fatal" | tail -5 | while read line; do
        echo -e "${PURPLE}${BOLD}$line${NC}"
    done
    if [ $(echo "$all_logs" | grep -i "fatal" | tail -5 | wc -l) -eq 0 ]; then
        echo -e "${GREEN}Нет FATAL сообщений${NC}"
    fi
    
    # Общий обзор логов - ИСПРАВЛЕНО: корректно ограничиваем 10 строками
    echo -e "\n${YELLOW}${BOLD}Общий обзор логов (последние 10 строк):${NC}"
    echo "$all_logs" | tail -10
}

# Функция для проверки критических ошибок в логах
check_critical_errors() {
    local logs="$1"
    local has_critical_errors=false
    
    # Паттерны критических ошибок
    local critical_patterns=(
        "Failed to bootstrap cluster"
        "password authentication failed"
        "no pg_hba.conf entry"
        "FATAL:"
        "patroni.exceptions.PatroniFatalException"
        "connection to server.*failed"
        "bootstrap failed"
        "removing data directory"
    )
    
    echo -e "\n${RED}${BOLD}ПРОВЕРКА КРИТИЧЕСКИХ ОШИБОК:${NC}"
    
    for pattern in "${critical_patterns[@]}"; do
        # Используем grep только для строк с ошибками (без контекста)
        local error_lines=$(echo "$logs" | grep -n -i "$pattern" 2>/dev/null || true)
        
        if [ -n "$error_lines" ]; then
            echo -e "\n${RED}❌ Найдена критическая ошибка: $pattern${NC}"
            echo -e "${YELLOW}Строки с ошибками:${NC}"
            # Выводим только строки с ошибками светло-красным цветом
            while IFS= read -r line; do
                echo -e "${LIGHT_RED}$line${NC}"
            done <<< "$error_lines"
            has_critical_errors=true
        fi
    done
    
    if [ "$has_critical_errors" = true ]; then
        echo -e "\n${RED}${BOLD}╔═══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}${BOLD}║                 ОБНАРУЖЕНЫ КРИТИЧЕСКИЕ ОШИБКИ!                 ║${NC}"
        echo -e "${RED}${BOLD}╚═══════════════════════════════════════════════════════════════╝${NC}"
        
        echo -e "\n${YELLOW}${BOLD}Возможные причины и решения:${NC}"
        echo -e "${YELLOW}1. Проблемы аутентификации:${NC}"
        echo -e "   • Проверьте пароль пользователя 'standby' в секретах"
        echo -e "   • Убедитесь, что в pg_hba.conf разрешены подключения с данного хоста"
        echo -e "   • Проверьте правильность настроек репликации"
        
        echo -e "\n${YELLOW}2. Проблемы сети:${NC}"
        echo -e "   • Проверьте доступность мастера PostgreSQL (172.16.0.212:30122)"
        echo -e "   • Убедитесь, что нет блокировки сетевых подключений"
        
        echo -e "\n${YELLOW}3. Проблемы конфигурации Patroni:${NC}"
        echo -e "   • Проверьте настройки bootstrap в конфигурации Patroni"
        echo -e "   • Убедитесь в правильности параметров standby_cluster"
        
        echo -e "\n${YELLOW}4. Проблемы с данными:${NC}"
        echo -e "   • Проверьте, что data directory чиста перед инициализацией"
        echo -e "   • Убедитесь в достаточности места на диске"
        
        return 1
    else
        echo -e "${GREEN}✅ Критических ошибок не обнаружено${NC}"
        return 0
    fi
}

# Если пароль не передан как аргумент, получаем его из секрета
if [ -z "$PG_PASSWORD" ]; then
    echo -e "${CYAN}Пароль не указан, получение из секрета...${NC}"
    PG_PASSWORD=$(get_password_from_secret)
    if [ $? -ne 0 ]; then
        exit 1
    fi
    echo -e "${GREEN}Пароль успешно получен из секрета${NC}"
else
    echo -e "${GREEN}Используется пароль из аргументов${NC}"
fi

echo -e "${BLUE}${BOLD}==============================================${NC}"
echo -e "${BLUE}${BOLD}Проверка Patroni и репликации PostgreSQL${NC}"
echo -e "${BLUE}${BOLD}==============================================${NC}"
echo -e "${CYAN}Pod: $POD_NAME${NC}"
echo -e "${CYAN}Namespace: $NAMESPACE${NC}"
echo -e "${CYAN}Port: $PORT${NC}"
echo -e "${CYAN}Patroni version: $PATRONI_VERSION${NC}"
echo -e "${BLUE}${BOLD}==============================================${NC}"

# Функция для выполнения команд в pod
exec_in_pod() {
    kubectl exec -it -n $NAMESPACE $POD_NAME -- $@
}

# Функция для выполнения SQL запросов с табличным выводом
exec_sql_table() {
    local sql_query=$(echo "$1" | sed 's/"/\\"/g')
    local description="$2"
    
    echo -e "\n${PURPLE}${BOLD}$description:${NC}"
    kubectl exec -it -n $NAMESPACE $POD_NAME -- bash -c "PGPASSWORD=\"$PG_PASSWORD\" psql -U postgres -c \"$sql_query\""
}

# Функция для выполнения SQL запросов (для случаев когда нужен простой вывод)
exec_sql() {
    local sql_query=$(echo "$1" | sed 's/"/\\"/g')
    # Убираем флаг -t чтобы избежать проблем с TTY
    kubectl exec -i -n $NAMESPACE $POD_NAME -- bash -c "PGPASSWORD=\"$PG_PASSWORD\" psql -U postgres -Aqtc \"$sql_query\" 2>/dev/null"
}

# 1. Проверка статуса Patroni через API
echo -e "\n${GREEN}${BOLD}1. Статус Patroni через API:${NC}"
if [ "$PATRONI_VERSION" = "v4" ]; then
    echo -e "${CYAN}Запрос: curl -s http://127.0.0.1:8008/ | jq '{role, replication_state}'${NC}"
    result=$(kubectl exec -it -n $NAMESPACE $POD_NAME -- curl -s http://127.0.0.1:8008/ 2>/dev/null | jq '{role, replication_state}' 2>/dev/null || echo -e "${RED}Ошибка при запросе к API${NC}")
    echo -e "${YELLOW}Результат: $result${NC}"
    expected='{"role":"standby_leader","replication_state":"streaming"}'
elif [ "$PATRONI_VERSION" = "v2" ]; then
    echo -e "${CYAN}Запрос: curl -s http://127.0.0.1:8008/ | jq -c '{role, state}'${NC}"
    result=$(kubectl exec -it -n $NAMESPACE $POD_NAME -- curl -s http://127.0.0.1:8008/ 2>/dev/null | jq -c '{role, state}' 2>/dev/null || echo -e "${RED}Ошибка при запросе к API${NC}")
    echo -e "${YELLOW}Результат: $result${NC}"
    expected='{"role":"standby_leader","state":"running"}'
else
    echo -e "${RED}Неверная версия Patroni: $PATRONI_VERSION${NC}"
    exit 1
fi

# 2. Проверка через patronictl
echo -e "\n${GREEN}${BOLD}2. Статус через patronictl:${NC}"
exec_in_pod patronictl list 2>/dev/null || echo -e "${RED}Ошибка при выполнении patronictl list${NC}"

# Получаем логи один раз и используем для всех проверок
echo -e "\n${GREEN}${BOLD}3. Анализ логов пода:${NC}"
POD_LOGS=$(get_pod_logs)

# Проверка критических ошибок
if ! check_critical_errors "$POD_LOGS"; then
    echo -e "\n${RED}${BOLD}Скрипт остановлен из-за критических ошибок!${NC}"
    echo -e "${YELLOW}Необходимо устранить указанные проблемы перед продолжением работы.${NC}"
    exit 1
fi

# Дальнейшие проверки выполняются только если нет критических ошибок

# 4. Проверка репликации в PostgreSQL
exec_sql_table "SELECT 
    client_addr, 
    usename,
    application_name,
    state, 
    sync_state,
    pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) as replay_lag_bytes,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) as replay_lag_pretty,
    ROUND(EXTRACT(EPOCH FROM (now() - reply_time))::numeric, 2) as replay_lag_seconds
FROM pg_stat_replication;" "4. Статус репликации"

# 5. Проверка лага репликации
exec_sql_table "SELECT 
    application_name,
    pg_wal_lsn_diff(sent_lsn, replay_lsn) as replication_lag_bytes,
    pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) as replication_lag_pretty
FROM pg_stat_replication;" "5. Лаг репликации"

# 6. Проверка слотов репликации
exec_sql_table "SELECT 
    slot_name, 
    plugin, 
    slot_type, 
    database, 
    active, 
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) as restart_lag,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) as confirmed_lag
FROM pg_replication_slots;" "6. Слоты репликации"

# 7. Размер базы данных
exec_sql_table "SELECT 
    datname, 
    pg_size_pretty(pg_database_size(datname)) as size 
FROM pg_database 
WHERE datistemplate = false 
ORDER BY pg_database_size(datname) DESC;" "7. Размер базы данных"

# 8. Общий размер data directory
echo -e "\n${PURPLE}${BOLD}8. Размер data directory (реальный):${NC}"
echo -e "${CYAN}Команда: du -smx /home/postgres/pgdata/pgroot/data${NC}"
exec_in_pod du -smxh /home/postgres/pgdata/pgroot/data 2>/dev/null || echo -e "${RED}Ошибка при проверке размера data directory${NC}"

# 9. Проверка активности WAL
echo -e "\n${PURPLE}${BOLD}9. Активность WAL:${NC}"
# Проверяем, находится ли база в режиме восстановления (реплика)
IS_RECOVERY=$(exec_sql "SELECT pg_is_in_recovery();")
if [ "$IS_RECOVERY" = "t" ]; then
    exec_sql_table "SELECT 
        pg_last_wal_receive_lsn() as last_receive_lsn,
        pg_last_wal_replay_lsn() as last_replay_lsn,
        pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()) as replay_lag_bytes,
        pg_size_pretty(pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())) as replay_lag_pretty,
        pg_is_wal_replay_paused() as is_replay_paused;" "9. Активность WAL (реплика)"
else
    exec_sql_table "SELECT 
        pg_current_wal_lsn() as current_wal_lsn,
        'N/A' as last_receive_lsn,
        'N/A' as last_replay_lsn,
        0 as replay_lag_bytes,
        '0 bytes' as replay_lag_pretty,
        false as is_replay_paused;" "9. Активность WAL (мастер)"
fi

# 10. Проверка статуса репликации из pg_stat_wal_receiver
# Эта функция работает только на репликах, поэтому проверяем режим
IS_RECOVERY=$(exec_sql "SELECT pg_is_in_recovery();")
if [ "$IS_RECOVERY" = "t" ]; then
    exec_sql_table "SELECT 
        status, 
        last_msg_send_time, 
        last_msg_receipt_time,
        latest_end_lsn, 
        latest_end_time,
        pg_wal_lsn_diff(pg_last_wal_replay_lsn(), latest_end_lsn) as lag_bytes,
        pg_size_pretty(pg_wal_lsn_diff(pg_last_wal_replay_lsn(), latest_end_lsn)) as lag_pretty
    FROM pg_stat_wal_receiver;" "10. Статус получения WAL (для standby)"
else
    echo -e "\n${PURPLE}${BOLD}10. Статус получения WAL:${NC}"
    echo -e "${YELLOW}Не применимо для мастера - функция pg_stat_wal_receiver работает только на репликах${NC}"
fi

# 11. Проверка табличных пространств
exec_sql_table "SELECT 
    spcname, 
    pg_tablespace_location(oid) as location,
    pg_size_pretty(pg_tablespace_size(oid)) as size 
FROM pg_tablespace 
WHERE spcname != 'pg_default';" "11. Табличные пространства"

# 12. Вывод логов пода (как было изначально)
show_pod_logs "$POD_LOGS"

echo -e "\n${BLUE}${BOLD}==============================================${NC}"
echo -e "${GREEN}${BOLD}Проверка завершена${NC}"
echo -e "${BLUE}${BOLD}==============================================${NC}"

# Дополнительные полезные команды
echo -e "\n${CYAN}${BOLD}Дополнительные команды для мониторинга:${NC}"
echo -e "${YELLOW}1. Панель мониторинга Patroni:${NC}"
echo -e "   ${CYAN}kubectl exec -it -n $NAMESPACE $POD_NAME -- patronictl list${NC}"
echo ""
echo -e "${YELLOW}2. Топ самых больших таблиц:${NC}"
echo -e "   ${CYAN}kubectl exec -it -n $NAMESPACE $POD_NAME -- bash -c \"PGPASSWORD=\\\"$PG_PASSWORD\\\" psql -U postgres -c \\\"SELECT schemaname, tablename, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as size FROM pg_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema') ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC LIMIT 10;\\\"\"${NC}"
echo ""
echo -e "${YELLOW}3. Мониторинг репликации в реальном времени:${NC}"
echo -e "   ${CYAN}watch -n1 'kubectl exec -it -n $NAMESPACE $POD_NAME -- patronictl list'${NC}"
echo ""
echo -e "${YELLOW}4. Просмотр всех логов пода:${NC}"
echo -e "   ${CYAN}kubectl logs -n $NAMESPACE $POD_NAME --tail=50${NC}"
echo ""
echo -e "${YELLOW}5. Просмотр логов в реальном времени:${NC}"
echo -e "   ${CYAN}kubectl logs -n $NAMESPACE $POD_NAME -f${NC}"