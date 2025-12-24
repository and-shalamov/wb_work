#!/bin/bash

# Скрипт проверки статуса Redis кластера и Sentinel
# Использование: ./check_redis_cluster.sh <pod_name> <namespace> [port] [password]

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
ORANGE='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Проверка аргументов
if [ $# -lt 2 ]; then
    echo -e "${RED}${BOLD}Использование: $0 <pod_name> <namespace> [port] [password]${NC}"
    echo -e "  ${YELLOW}pod_name: имя пода (rfr-* для Redis, rfs-* для Sentinel)${NC}"
    echo -e "  ${YELLOW}port: опционально - если не указан, будет определен автоматически${NC}"
    echo -e "  ${YELLOW}password: опционально - если не указан, будет получен из секрета${NC}"
    exit 1
fi

POD_NAME=$1
NAMESPACE=$2
PORT=$3
REDIS_PASSWORD=$4

# Определяем тип пода (Redis или Sentinel) и порт по умолчанию
if [[ "$POD_NAME" == rfr-* ]]; then
    POD_TYPE="redis"
    DEFAULT_PORT=6379
elif [[ "$POD_NAME" == rfs-* ]]; then
    POD_TYPE="sentinel"
    DEFAULT_PORT=26379
else
    echo -e "${RED}Неизвестный тип пода: $POD_NAME${NC}"
    echo -e "${YELLOW}Ожидаются префиксы: rfr- (Redis) или rfs- (Sentinel)${NC}"
    exit 1
fi

# Устанавливаем порт по умолчанию, если не указан
if [ -z "$PORT" ]; then
    PORT=$DEFAULT_PORT
    echo -e "${YELLOW}Порт не указан, используется порт по умолчанию: $PORT${NC}"
fi

# Функция для извлечения идентификатора кластера из имени пода
get_cluster_id() {
    local pod_name="$1"
    
    # Разбиваем имя пода на части по дефисам
    # Формат: rfr-<service>-<environment>-redis-<index>
    # Пример: rfr-pickup-main-redis-0 -> pickup-main
    #         rfs-pickup-stage2-redis-68bc8fc5c9-q26cv -> pickup-stage2
    
    # Удаляем префикс rfr- или rfs-
    local without_prefix="${pod_name#rfr-}"
    without_prefix="${without_prefix#rfs-}"
    
    # Удаляем суффикс -redis-* 
    local cluster_id=$(echo "$without_prefix" | sed 's/-redis-.*//')
    
    # Если после обработки осталась пустая строка, используем "default"
    if [ -z "$cluster_id" ]; then
        echo "default"
    else
        echo "$cluster_id"
    fi
}

# Получаем идентификатор кластера
CLUSTER_ID=$(get_cluster_id "$POD_NAME")
echo -e "${CYAN}Идентифицирован кластер: $CLUSTER_ID${NC}"

# Функция для фильтрации ресурсов по кластеру
filter_by_cluster() {
    local items=("$@")
    local filtered_items=()
    
    for item in "${items[@]}"; do
        if [[ "$item" == *"$CLUSTER_ID"* ]]; then
            filtered_items+=("$item")
        fi
    done
    
    echo "${filtered_items[@]}"
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
    local base_pod_name=$(echo "$POD_NAME" | sed 's/-[0-9]\+$//')
    
    echo -e "${CYAN}Поиск секретов для пода: $POD_NAME (базовое имя: $base_pod_name)${NC}" >&2
    echo -e "${CYAN}Пространство имен: $NAMESPACE${NC}" >&2
    echo -e "${CYAN}Тип пода: $POD_TYPE${NC}" >&2
    echo -e "${CYAN}Кластер: $CLUSTER_ID${NC}" >&2
    
    # Получаем все секреты в неймспейсе
    local all_secrets=($(kubectl get secrets -n $NAMESPACE --no-headers -o custom-columns=":metadata.name" 2>/dev/null))
    
    if [ ${#all_secrets[@]} -eq 0 ]; then
        echo -e "${RED}Ошибка: в неймспейсе $NAMESPACE не найдено ни одного секрета${NC}" >&2
        return 1
    fi
    
    echo -e "${CYAN}Всего секретов в неймспейсе: ${#all_secrets[@]}${NC}" >&2
    
    # Фильтруем секреты по строгим критериям с учетом кластера
    local filtered_secrets=()
    
    # Сначала ищем секреты, которые явно относятся к Redis
    for secret in "${all_secrets[@]}"; do
        # Строгие критерии: должен содержать redis и идентификатор кластера
        if [[ "$secret" == *"redis"* ]] && [[ "$secret" == *"$CLUSTER_ID"* ]]; then
            filtered_secrets+=("$secret")
            continue
        fi
        
        # Или должен содержать rf и идентификатор кластера
        if [[ "$secret" == *"rf"* ]] && [[ "$secret" == *"$CLUSTER_ID"* ]]; then
            filtered_secrets+=("$secret")
            continue
        fi
    done
    
    # Если не нашли по строгим критериям, используем более мягкие
    if [ ${#filtered_secrets[@]} -eq 0 ]; then
        echo -e "${YELLOW}Не найдено секретов по строгим критериям, используем расширенные${NC}" >&2
        
        for secret in "${all_secrets[@]}"; do
            # Содержит redis (без проверки кластера)
            if [[ "$secret" == *"redis"* ]]; then
                filtered_secrets+=("$secret")
                continue
            fi
            
            # Содержит rf (без проверки кластера)
            if [[ "$secret" == *"rf"* ]]; then
                filtered_secrets+=("$secret")
                continue
            fi
            
            # Содержит идентификатор кластера и не содержит явно посторонних ключевых слов
            if [[ "$secret" == *"$CLUSTER_ID"* ]] && 
               [[ "$secret" != *"pg"* ]] && 
               [[ "$secret" != *"postgres"* ]] && 
               [[ "$secret" != *"psql"* ]] && 
               [[ "$secret" != *"registry"* ]] && 
               [[ "$secret" != *"config"* ]] && 
               [[ "$secret" != *"exporter"* ]]; then
                filtered_secrets+=("$secret")
                continue
            fi
        done
    fi
    
    # Если все еще не нашли, используем базовое имя пода
    if [ ${#filtered_secrets[@]} -eq 0 ]; then
        echo -e "${YELLOW}Не найдено секретов по расширенным критериям, используем базовое имя пода${NC}" >&2
        
        for secret in "${all_secrets[@]}"; do
            if [[ "$secret" == *"$base_pod_name"* ]]; then
                filtered_secrets+=("$secret")
                continue
            fi
        done
    fi
    
    # Исключаем секреты, которые явно не относятся к Redis
    local redis_secrets=()
    for secret in "${filtered_secrets[@]}"; do
        # Исключаем секреты с явно посторонними ключевыми словами
        if [[ "$secret" == *"pg"* ]] || 
           [[ "$secret" == *"postgres"* ]] || 
           [[ "$secret" == *"psql"* ]] || 
           [[ "$secret" == *"registry"* ]] || 
           [[ "$secret" == *"exporter"* ]] ||
           [[ "$secret" == *"config"* && "$secret" != *"redis"* ]]; then
            echo -e "  ${YELLOW}Исключен: $secret (не относится к Redis)${NC}" >&2
            continue
        fi
        
        # Включаем только релевантные секреты
        if [[ "$secret" == *"redis"* ]] || 
           [[ "$secret" == *"rf"* ]] || 
           [[ "$secret" == *"$CLUSTER_ID"* ]] || 
           [[ "$secret" == *"$base_pod_name"* ]]; then
            redis_secrets+=("$secret")
        fi
    done
    
    filtered_secrets=("${redis_secrets[@]}")
    
    if [ ${#filtered_secrets[@]} -eq 0 ]; then
        echo -e "${RED}Ошибка: не найдено подходящих секретов Redis${NC}" >&2
        echo -e "${YELLOW}Критерии поиска:${NC}" >&2
        echo -e "${YELLOW}  - Содержит 'redis' и идентификатор кластера: $CLUSTER_ID${NC}" >&2
        echo -e "${YELLOW}  - ИЛИ содержит 'rf' и идентификатор кластера: $CLUSTER_ID${NC}" >&2
        echo -e "${YELLOW}  - ИЛИ содержит 'redis' (без кластера)${NC}" >&2
        echo -e "${YELLOW}  - Исключены: секреты с pg, postgres, psql, registry, exporter${NC}" >&2
        echo -e "${YELLOW}Доступные секреты в неймспейсе $NAMESPACE:${NC}" >&2
        printf '  %s\n' "${all_secrets[@]}" >&2
        return 1
    fi
    
    echo -e "${GREEN}Найдено ${#filtered_secrets[@]} подходящих секретов Redis:${NC}" >&2
    for secret in "${filtered_secrets[@]}"; do
        if [[ "$secret" == *"redis"* ]] && [[ "$secret" == *"$CLUSTER_ID"* ]]; then
            echo -e "  ${GREEN}✓ $secret (идеальное совпадение)${NC}" >&2
        elif [[ "$secret" == *"redis"* ]]; then
            echo -e "  ${GREEN}✓ $secret (содержит redis)${NC}" >&2
        elif [[ "$secret" == *"rf"* ]]; then
            echo -e "  ${GREEN}✓ $secret (содержит rf)${NC}" >&2
        else
            echo -e "  ${YELLOW}✓ $secret (совпадение по кластеру)${NC}" >&2
        fi
    done
    
    # Сортируем секреты по релевантности
    local sorted_secrets=()
    for secret in "${filtered_secrets[@]}"; do
        if [[ "$secret" == *"redis"* ]] && [[ "$secret" == *"$CLUSTER_ID"* ]]; then
            # Самые релевантные - содержат и redis и идентификатор кластера
            sorted_secrets=("$secret" "${sorted_secrets[@]}")
        elif [[ "$secret" == *"redis"* ]]; then
            # Содержат redis - добавляем в начало
            sorted_secrets=("$secret" "${sorted_secrets[@]}")
        elif [[ "$secret" == *"rf"* ]]; then
            # Содержат rf - добавляем после redis
            sorted_secrets=("${sorted_secrets[@]}" "$secret")
        else
            # Остальные - в конец
            sorted_secrets+=("$secret")
        fi
    done
    
    local secret_name
    if [ ${#sorted_secrets[@]} -eq 1 ]; then
        secret_name="${sorted_secrets[0]}"
        echo -e "${GREEN}Используется единственный подходящий секрет: $secret_name${NC}" >&2
    else
        echo -e "${CYAN}Найдено ${#sorted_secrets[@]} подходящих секретов Redis${NC}" >&2
        secret_name=$(select_secret "${sorted_secrets[@]}")
        echo -e "${GREEN}Выбран секрет: $secret_name${NC}" >&2
    fi
    
    # Попробуем разные возможные ключи в секрете
    local password_keys=("password" "redis-password" "auth" "redis-auth" "rf-password")
    
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

# Функция для поиска и отображения ConfigMaps
find_configmaps() {
    echo -e "${CYAN}Поиск ConfigMaps для кластера $CLUSTER_ID...${NC}"
    
    # Получаем все ConfigMaps в неймспейсе
    local all_configmaps=($(kubectl get configmaps -n $NAMESPACE --no-headers -o custom-columns=":metadata.name" 2>/dev/null))
    
    if [ ${#all_configmaps[@]} -eq 0 ]; then
        echo -e "${YELLOW}ConfigMaps не найдены в неймспейсе $NAMESPACE${NC}"
        return 1
    fi
    
    # Фильтруем ConfigMaps по кластеру
    local redis_configmaps=()
    for cm in "${all_configmaps[@]}"; do
        if [[ "$cm" == *"redis"* ]] && [[ "$cm" == *"$CLUSTER_ID"* ]]; then
            redis_configmaps+=("$cm")
        elif [[ "$cm" == *"sentinel"* ]] && [[ "$cm" == *"$CLUSTER_ID"* ]]; then
            redis_configmaps+=("$cm")
        elif [[ "$cm" == *"rf"* ]] && [[ "$cm" == *"$CLUSTER_ID"* ]]; then
            redis_configmaps+=("$cm")
        fi
    done
    
    # Если не нашли по кластеру, ищем любые redis/sentinel configmaps
    if [ ${#redis_configmaps[@]} -eq 0 ]; then
        for cm in "${all_configmaps[@]}"; do
            if [[ "$cm" == *"redis"* ]] || [[ "$cm" == *"sentinel"* ]]; then
                redis_configmaps+=("$cm")
            fi
        done
    fi
    
    if [ ${#redis_configmaps[@]} -eq 0 ]; then
        echo -e "${YELLOW}Не найдено ConfigMaps, связанных с Redis/Sentinel${NC}"
        return 1
    fi
    
    echo -e "${GREEN}Найдено ConfigMaps: ${#redis_configmaps[@]}${NC}"
    
    for cm in "${redis_configmaps[@]}"; do
        echo -e "\n${CYAN}ConfigMap: $cm${NC}"
        
        # Получаем данные ConfigMap
        local config_data=$(kubectl get configmap -n $NAMESPACE "$cm" -o json 2>/dev/null)
        
        # Показываем ключи
        local keys=$(echo "$config_data" | jq -r '.data | keys[]' 2>/dev/null || echo "не удалось получить ключи")
        echo -e "  ${YELLOW}Ключи: $keys${NC}"
        
        # Показываем содержимое основных конфигурационных файлов
        for key in $keys; do
            if [[ "$key" == *".conf"* ]] || [[ "$key" == *"config"* ]] || [[ "$key" == *"sentinel"* ]]; then
                echo -e "  ${CYAN}Содержимое $key:${NC}"
                local content=$(echo "$config_data" | jq -r ".data.\"$key\"" 2>/dev/null)
                if [ -n "$content" ]; then
                    echo "$content" | head -20 | while IFS= read -r line; do
                        if [[ "$line" =~ ^# ]]; then
                            echo -e "    ${GREEN}$line${NC}"
                        elif [[ "$line" =~ ^(bind|port|requirepass|masterauth) ]]; then
                            echo -e "    ${YELLOW}$line${NC}"
                        elif [[ "$line" =~ ^(sentinel) ]]; then
                            echo -e "    ${PURPLE}$line${NC}"
                        else
                            echo -e "    ${CYAN}$line${NC}"
                        fi
                    done
                    if [ $(echo "$content" | wc -l) -gt 20 ]; then
                        echo -e "    ${YELLOW}... (показаны первые 20 строк)${NC}"
                    fi
                fi
            fi
        done
    done
    
    return 0
}

# Функция для выполнения команд в Redis/Sentinel
exec_redis_cmd() {
    local cmd="$1"
    
    local result
    if [ -n "$REDIS_PASSWORD" ]; then
        result=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -a '$REDIS_PASSWORD' $cmd 2>&1" 2>/dev/null || echo "ERROR")
        # Убираем предупреждение о пароле
        result=$(echo "$result" | grep -v "Warning: Using a password")
    else
        result=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli $cmd 2>&1" 2>/dev/null || echo "ERROR")
    fi
    
    echo "$result"
}

# Функция для выполнения команд на конкретном поде с учетом типа пода
exec_cmd_on_pod() {
    local pod="$1"
    local cmd="$2"
    
    # Определяем тип пода по имени
    local target_pod_type
    if [[ "$pod" == rfr-* ]]; then
        target_pod_type="redis"
        local target_port=6379
    elif [[ "$pod" == rfs-* ]]; then
        target_pod_type="sentinel"
        local target_port=26379
    else
        echo -e "${RED}Неизвестный тип пода: $pod${NC}" >&2
        echo "ERROR"
        return 1
    fi
    
    local result
    if [ -n "$REDIS_PASSWORD" ]; then
        result=$(kubectl exec -n $NAMESPACE $pod -- sh -c "redis-cli -a '$REDIS_PASSWORD' -p $target_port $cmd 2>&1" 2>/dev/null || echo "ERROR")
        result=$(echo "$result" | grep -v "Warning: Using a password")
    else
        result=$(kubectl exec -n $NAMESPACE $pod -- sh -c "redis-cli -p $target_port $cmd 2>&1" 2>/dev/null || echo "ERROR")
    fi
    
    echo "$result"
}

# Функция для проверки доступности Redis/Sentinel
check_connection() {
    echo -e "${CYAN}Проверка подключения к $POD_TYPE...${NC}"
    
    # Сначала проверяем, что под запущен
    local pod_status=$(kubectl get pod -n $NAMESPACE $POD_NAME -o jsonpath='{.status.phase}' 2>/dev/null)
    if [ "$pod_status" != "Running" ]; then
        echo -e "${RED}Под не в состоянии Running. Текущий статус: $pod_status${NC}"
        return 1
    fi
    
    if [ "$POD_TYPE" = "sentinel" ]; then
        # Для сентинела используем порт 26379
        local response
        if [ -n "$REDIS_PASSWORD" ]; then
            response=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -a '$REDIS_PASSWORD' -p 26379 ping 2>&1" 2>/dev/null || echo "ERROR")
            response=$(echo "$response" | grep -v "Warning: Using a password")
        else
            response=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -p 26379 ping 2>&1" 2>/dev/null || echo "ERROR")
        fi
        
        if [[ "$response" == *"PONG"* ]] || [[ "$response" == *"pong"* ]]; then
            echo -e "${GREEN}✓ Подключение успешно${NC}"
            return 0
        elif [[ "$response" == *"WRONGPASS"* ]]; then
            echo -e "${RED}✗ Ошибка аутентификации: неверный пароль${NC}"
            return 1
        else
            echo -e "${RED}✗ Не удалось подключиться к $POD_TYPE${NC}"
            return 1
        fi
    else
        # Для Redis используем порт по умолчанию
        if [ -n "$REDIS_PASSWORD" ]; then
            local response=$(exec_redis_cmd "ping")
            if [[ "$response" == *"PONG"* ]] || [[ "$response" == *"pong"* ]]; then
                echo -e "${GREEN}✓ Подключение успешно${NC}"
                return 0
            elif [[ "$response" == *"WRONGPASS"* ]]; then
                echo -e "${RED}✗ Ошибка аутентификации: неверный пароль${NC}"
                return 1
            else
                echo -e "${RED}✗ Не удалось подключиться к $POD_TYPE${NC}"
                return 1
            fi
        else
            local response=$(exec_redis_cmd "ping")
            if [[ "$response" == *"PONG"* ]] || [[ "$response" == *"pong"* ]]; then
                echo -e "${GREEN}✓ Подключение успешно${NC}"
                return 0
            else
                echo -e "${RED}✗ Не удалось подключиться к $POD_TYPE${NC}"
                return 1
            fi
        fi
    fi
}

# Функция для получения информации о лаге репликации
get_replication_lag_info() {
    local role="$1"
    
    if [ "$role" = "slave" ]; then
        local master_host=$(exec_redis_cmd "info replication" | grep "master_host:" | cut -d: -f2 | tr -d '\r' | head -1)
        local master_port=$(exec_redis_cmd "info replication" | grep "master_port:" | cut -d: -f2 | tr -d '\r' | head -1)
        local master_link_status=$(exec_redis_cmd "info replication" | grep "master_link_status:" | cut -d: -f2 | tr -d '\r' | head -1)
        local master_last_io_seconds=$(exec_redis_cmd "info replication" | grep "master_last_io_seconds_ago:" | cut -d: -f2 | tr -d '\r' | head -1)
        
        # Проверяем отставание репликации
        local repl_offset=$(exec_redis_cmd "info replication" | grep "master_repl_offset:" | cut -d: -f2 | tr -d '\r' | head -1)
        local slave_offset=$(exec_redis_cmd "info replication" | grep "slave_repl_offset:" | cut -d: -f2 | tr -d '\r' | head -1)
        
        if [ -n "$repl_offset" ] && [ -n "$slave_offset" ]; then
            local lag=$((repl_offset - slave_offset))
            
            echo -e "\n${PURPLE}${BOLD}Анализ отставания репликации:${NC}"
            echo -e "${CYAN}  Смещение мастера: $repl_offset${NC}"
            echo -e "${CYAN}  Смещение реплики: $slave_offset${NC}"
            echo -e "${CYAN}  Отставание: $lag байт ($((lag/1024)) КБ)${NC}"
            
            # Анализ причин лага
            if [ "$lag" -eq 0 ]; then
                echo -e "${GREEN}  ✓ Репликация синхронизирована${NC}"
            elif [ "$lag" -lt 1024 ]; then
                echo -e "${GREEN}  ✓ Небольшое отставание (менее 1КБ) - в пределах нормы${NC}"
            elif [ "$lag" -lt 1048576 ]; then
                echo -e "${YELLOW}  ⚠️  Умеренное отставание (менее 1МБ) - возможна задержка сети${NC}"
                echo -e "${YELLOW}  Возможные причины:${NC}"
                echo -e "${YELLOW}    - Сетевая задержка между узлами${NC}"
                echo -e "${YELLOW}    - Высокая нагрузка на мастере${NC}"
            else
                echo -e "${RED}  ⚠️  Большое отставание (более 1МБ) - требуется внимание${NC}"
                echo -e "${RED}  Возможные причины:${NC}"
                echo -e "${RED}    - Проблемы с сетью${NC}"
                echo -e "${RED}    - Очень высокая нагрузка на мастере${NC}"
                echo -e "${RED}    - Проблемы с диском на реплике${NC}"
                echo -e "${RED}    - Недостаточно ресурсов на реплике${NC}"
            fi
            
            # Анализ времени последнего IO
            if [ "$master_last_io_seconds" -lt 5 ]; then
                echo -e "${GREEN}  ✓ Стабильное соединение с мастером (последний IO: $master_last_io_seconds секунд назад)${NC}"
            elif [ "$master_last_io_seconds" -lt 30 ]; then
                echo -e "${YELLOW}  ⚠️  Небольшая задержка соединения (последний IO: $master_last_io_seconds секунд назад)${NC}"
            else
                echo -e "${RED}  ⚠️  Высокая задержка соединения (последний IO: $master_last_io_seconds секунд назад)${NC}"
            fi
        fi
    fi
}

# Функция для получения имени мастера из IP
get_pod_name_by_ip() {
    local ip="$1"
    
    # Получаем все поды Redis в неймспейсе, фильтруем по кластеру
    local all_redis_pods=($(kubectl get pods -n $NAMESPACE --no-headers -o custom-columns=":metadata.name" | grep "rfr-" || true))
    local redis_pods=()
    
    for pod in "${all_redis_pods[@]}"; do
        if [[ "$pod" == *"$CLUSTER_ID"* ]]; then
            redis_pods+=("$pod")
        fi
    done
    
    # Если не нашли поды по кластеру, используем все
    if [ ${#redis_pods[@]} -eq 0 ]; then
        redis_pods=("${all_redis_pods[@]}")
        echo -e "${YELLOW}Не найдено подов Redis для кластера $CLUSTER_ID, используем все доступные поды${NC}" >&2
    fi
    
    for pod in "${redis_pods[@]}"; do
        # Получаем IP пода
        local pod_ip=$(kubectl get pod -n $NAMESPACE $pod -o jsonpath='{.status.podIP}' 2>/dev/null)
        if [ "$pod_ip" = "$ip" ]; then
            echo "$pod"
            return 0
        fi
    done
    
    echo "неизвестный под"
}

# Функция для получения IP адреса пода
get_pod_ip() {
    local pod="$1"
    kubectl get pod -n $NAMESPACE $pod -o jsonpath='{.status.podIP}' 2>/dev/null || echo "неизвестный IP"
}

# Функция для проверки конфигурации мониторинга сентинела
check_sentinel_monitoring_config() {
    echo -e "\n${PURPLE}${BOLD}Проверка конфигурации мониторинга Sentinel:${NC}"
    
    # Используем правильную команду для сентинела (порт 26379)
    local masters_info
    if [ -n "$REDIS_PASSWORD" ]; then
        masters_info=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -a '$REDIS_PASSWORD' -p 26379 sentinel masters 2>&1" 2>/dev/null || echo "ERROR")
        masters_info=$(echo "$masters_info" | grep -v "Warning: Using a password")
    else
        masters_info=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -p 26379 sentinel masters 2>&1" 2>/dev/null || echo "ERROR")
    fi
    
    if [[ "$masters_info" == *"ERROR"* ]] || [ -z "$masters_info" ]; then
        echo -e "${RED}✗ Нет настроенных мастеров для мониторинга${NC}"
        echo -e "${YELLOW}Возможные причины:${NC}"
        echo -e "${YELLOW}  1. Sentinel не настроен на мониторинг Redis кластера${NC}"
        echo -e "${YELLOW}  2. Неправильное имя мастера в конфигурации${NC}"
        echo -e "${YELLOW}  3. Проблемы с сетевой связностью${NC}"
        echo -e "${YELLOW}  4. Ошибки аутентификации к Redis мастерам${NC}"
        
        # Ищем ConfigMaps вместо конфигурационных файлов
        echo -e "\n${CYAN}Поиск конфигурации в ConfigMaps:${NC}"
        find_configmaps
        
        return 1
    else
        local master_count=$(echo "$masters_info" | grep -c "name")
        echo -e "${GREEN}✓ Настроено мастеров для мониторинга: $master_count${NC}"
        
        # Выводим информацию о каждом мастере
        echo "$masters_info" | while read line; do
            if [[ "$line" == *"name"* ]]; then
                master_name=$(echo "$line" | awk -F '"' '{print $2}')
                echo -e "\n  ${CYAN}Мастер: $master_name${NC}"
            elif [[ "$line" == *"ip"* ]]; then
                master_ip=$(echo "$line" | awk '{print $2}')
                echo -e "    ${YELLOW}IP: $master_ip${NC}"
            elif [[ "$line" == *"port"* ]]; then
                master_port=$(echo "$line" | awk '{print $2}')
                echo -e "    ${YELLOW}Port: $master_port${NC}"
            elif [[ "$line" == *"flags"* ]]; then
                flags=$(echo "$line" | awk '{print $2}')
                echo -e "    ${YELLOW}Flags: $flags${NC}"
            fi
        done
        return 0
    fi
}

# Функция для проверки discovery сентинелов
check_sentinel_discovery() {
    echo -e "\n${PURPLE}${BOLD}Проверка механизма discovery Sentinel:${NC}"
    
    # Получаем текущие известные сентинелы
    local known_sentinels
    if [ -n "$REDIS_PASSWORD" ]; then
        known_sentinels=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -a '$REDIS_PASSWORD' -p 26379 sentinel sentinels mymaster 2>&1" 2>/dev/null || echo "ERROR")
        known_sentinels=$(echo "$known_sentinels" | grep -v "Warning: Using a password")
    else
        known_sentinels=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -p 26379 sentinel sentinels mymaster 2>&1" 2>/dev/null || echo "ERROR")
    fi
    
    if [[ "$known_sentinels" == *"ERROR"* ]] || [ -z "$known_sentinels" ]; then
        echo -e "${YELLOW}✓ Этот сентинел не знает о других сентинелах (первый в кластере)${NC}"
        echo -e "${YELLOW}  Для добавления других сентинелов выполните:${NC}"
        echo -e "${CYAN}  redis-cli -h <SENTINEL_IP> -p 26379 sentinel monitor mymaster <REDIS_MASTER_IP> 6379 <QUORUM>${NC}"
    else
        local sentinel_count=$(echo "$known_sentinels" | grep -c "name")
        echo -e "${GREEN}✓ Известно сентинелов: $((sentinel_count))${NC}"
    fi
    
    # Проверяем, видит ли сентинел Redis ноды
    local redis_nodes
    if [ -n "$REDIS_PASSWORD" ]; then
        redis_nodes=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -a '$REDIS_PASSWORD' -p 26379 sentinel slaves mymaster 2>&1" 2>/dev/null || echo "ERROR")
        redis_nodes=$(echo "$redis_nodes" | grep -v "Warning: Using a password")
    else
        redis_nodes=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -p 26379 sentinel slaves mymaster 2>&1" 2>/dev/null || echo "ERROR")
    fi
    
    if [[ "$redis_nodes" == *"ERROR"* ]] || [ -z "$redis_nodes" ]; then
        echo -e "${RED}✗ Сентинел не видит Redis ноды${NC}"
        echo -e "${YELLOW}  Необходимо настроить мониторинг:${NC}"
        echo -e "${CYAN}  sentinel monitor mymaster <REDIS_MASTER_IP> 6379 2${NC}"
        echo -e "${CYAN}  sentinel auth-pass mymaster <password>${NC}"
    else
        local node_count=$(echo "$redis_nodes" | grep -c "name")
        echo -e "${GREEN}✓ Обнаружено Redis нод: $node_count${NC}"
    fi
}

# Функция для диагностики проблем сентинела
diagnose_sentinel_issues() {
    echo -e "\n${PURPLE}${BOLD}Диагностика проблем Sentinel:${NC}"
    
    # Проверяем, может ли сентинел подключиться к Redis (порт 6379)
    local redis_pods=($(kubectl get pods -n $NAMESPACE --no-headers -o custom-columns=":metadata.name" | grep "rfr-" | grep "$CLUSTER_ID" || true))
    
    if [ ${#redis_pods[@]} -eq 0 ]; then
        echo -e "${RED}✗ Не найдено Redis подов для кластера $CLUSTER_ID${NC}"
        return 1
    fi
    
    echo -e "${CYAN}Проверка подключения к Redis нодам (порт 6379):${NC}"
    for redis_pod in "${redis_pods[@]}"; do
        local redis_ip=$(get_pod_ip "$redis_pod")
        echo -e "  ${CYAN}Проверка $redis_pod ($redis_ip:6379)...${NC}"
        
        # Пробуем подключиться через redis-cli из пода сентинела к Redis ноде
        local test_result
        if [ -n "$REDIS_PASSWORD" ]; then
            test_result=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -h $redis_ip -p 6379 -a '$REDIS_PASSWORD' ping 2>&1" 2>/dev/null || echo "ERROR")
            test_result=$(echo "$test_result" | grep -v "Warning: Using a password")
        else
            test_result=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -h $redis_ip -p 6379 ping 2>&1" 2>/dev/null || echo "ERROR")
        fi
        
        if [[ "$test_result" == *"PONG"* ]]; then
            echo -e "    ${GREEN}✓ Подключение успешно${NC}"
            
            # Проверяем роль Redis ноды
            local role
            if [ -n "$REDIS_PASSWORD" ]; then
                role=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -h $redis_ip -p 6379 -a '$REDIS_PASSWORD' info replication 2>&1" 2>/dev/null | grep "role:" | cut -d: -f2 | tr -d '\r' | head -1)
            else
                role=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -h $redis_ip -p 6379 info replication 2>&1" 2>/dev/null | grep "role:" | cut -d: -f2 | tr -d '\r' | head -1)
            fi
            
            echo -e "    ${CYAN}Роль: $role${NC}"
            
            # Если это мастер, предлагаем настроить мониторинг
            if [ "$role" = "master" ]; then
                echo -e "    ${GREEN}🎯 Обнаружен Redis MASTER${NC}"
                echo -e "    ${YELLOW}Для настройки мониторинга выполните:${NC}"
                echo -e "    ${CYAN}redis-cli -p 26379 sentinel monitor mymaster $redis_ip 6379 2${NC}"
                if [ -n "$REDIS_PASSWORD" ]; then
                    echo -e "    ${CYAN}redis-cli -p 26379 sentinel auth-pass mymaster $REDIS_PASSWORD${NC}"
                fi
                echo -e "    ${CYAN}redis-cli -p 26379 sentinel flushconfig${NC}"
            fi
        else
            echo -e "    ${RED}✗ Не удалось подключиться${NC}"
            echo -e "    ${YELLOW}Проверьте:${NC}"
            echo -e "    ${YELLOW}  - Сетевую связность между подами${NC}"
            echo -e "    ${YELLOW}  - Настройки firewall${NC}"
            echo -e "    ${YELLOW}  - Правильность пароля${NC}"
        fi
    done
    
    # Проверка связи между сентинелами (порт 26379)
    echo -e "\n${CYAN}Проверка связи между сентинелами (порт 26379):${NC}"
    local sentinel_pods=($(kubectl get pods -n $NAMESPACE --no-headers -o custom-columns=":metadata.name" | grep "rfs-" | grep "$CLUSTER_ID" || true))
    
    for sentinel_pod in "${sentinel_pods[@]}"; do
        if [ "$sentinel_pod" != "$POD_NAME" ]; then
            local sentinel_ip=$(get_pod_ip "$sentinel_pod")
            echo -e "  ${CYAN}Проверка связи с $sentinel_pod ($sentinel_ip:26379)...${NC}"
            
            local test_result
            if [ -n "$REDIS_PASSWORD" ]; then
                test_result=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -h $sentinel_ip -p 26379 -a '$REDIS_PASSWORD' ping 2>&1" 2>/dev/null || echo "ERROR")
                test_result=$(echo "$test_result" | grep -v "Warning: Using a password")
            else
                test_result=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -h $sentinel_ip -p 26379 ping 2>&1" 2>/dev/null || echo "ERROR")
            fi
            
            if [[ "$test_result" == *"PONG"* ]]; then
                echo -e "    ${GREEN}✓ Подключение успешно${NC}"
            else
                echo -e "    ${RED}✗ Не удалось подключиться${NC}"
            fi
        fi
    done
    
check_sentinel_info_consistency() {
    echo -e "\n${PURPLE}${BOLD}6.1. Проверка INFO sentinel на всех Sentinel pod'ах:${NC}"

    # Получаем все Sentinel pod'ы по кластеру
    local sentinel_pods=($(kubectl get pods -n "$NAMESPACE" \
        --no-headers -o custom-columns=":metadata.name" | grep "^rfs-" | grep "$CLUSTER_ID" || true))

    if [ ${#sentinel_pods[@]} -eq 0 ]; then
        echo -e "${RED}✗ Sentinel pod'ы не найдены${NC}"
        return 1
    fi

    echo -e "${CYAN}Найдено Sentinel pod'ов: ${#sentinel_pods[@]}${NC}"

    local reference_line=""
    local reference_pod=""
    local mismatch=0

    for pod in "${sentinel_pods[@]}"; do
        echo -e "\n${CYAN}Sentinel: $pod${NC}"

        # Выполняем INFO sentinel
        local info_out
        info_out=$(exec_cmd_on_pod "$pod" "info sentinel")

        if [[ "$info_out" == *"ERROR"* ]] || [ -z "$info_out" ]; then
            echo -e "${RED}✗ Не удалось получить INFO sentinel${NC}"
            mismatch=1
            continue
        fi

        # Извлекаем строку master0
        local master_line
        master_line=$(echo "$info_out" | grep "^master0:")

        if [ -z "$master_line" ]; then
            echo -e "${RED}✗ Строка master0 не найдена${NC}"
            mismatch=1
            continue
        fi

        echo -e "  ${GREEN}$master_line${NC}"

        # Сравнение
        if [ -z "$reference_line" ]; then
            reference_line="$master_line"
            reference_pod="$pod"
        else
            if [ "$master_line" != "$reference_line" ]; then
                echo -e "${RED}✗ Несовпадение с $reference_pod${NC}"
                mismatch=1
            fi
        fi
    done

    echo -e "\n${PURPLE}${BOLD}Итог проверки INFO sentinel:${NC}"

    if [ $mismatch -eq 0 ]; then
        echo -e "${GREEN}✓ Все Sentinel pod'ы имеют одинаковое состояние${NC}"
        echo -e "${GREEN}  $reference_line${NC}"
    else
        echo -e "${RED}✗ Обнаружены расхождения между Sentinel pod'ами${NC}"
        echo -e "${YELLOW}Проверь:${NC}"
        echo -e "${YELLOW}  - сетевую связность между Sentinel${NC}"
        echo -e "${YELLOW}  - кворум${NC}"
        echo -e "${YELLOW}  - актуальность мастера${NC}"
    fi
}


    # Расширенные команды диагностики
    echo -e "\n${CYAN}Расширенные команды диагностики:${NC}"
    echo -e "  ${YELLOW}Проверить информацию о сентинеле:${NC}"
    echo -e "    ${CYAN}kubectl exec -n $NAMESPACE $POD_NAME -- redis-cli -p 26379 info sentinel${NC}"
    
    echo -e "  ${YELLOW}Проверить кворум:${NC}"
    echo -e "    ${CYAN}kubectl exec -n $NAMESPACE $POD_NAME -- redis-cli -p 26379 sentinel ckquorum mymaster${NC}"
    
    echo -e "  ${YELLOW}Проверить статус failover:${NC}"
    echo -e "    ${CYAN}kubectl exec -n $NAMESPACE $POD_NAME -- redis-cli -p 26379 sentinel failover-status mymaster${NC}"
    
    echo -e "  ${YELLOW}Проверить все сентинелы:${NC}"
    echo -e "    ${CYAN}kubectl exec -n $NAMESPACE $POD_NAME -- redis-cli -p 26379 sentinel sentinels mymaster${NC}"
    
    echo -e "  ${YELLOW}Проверить реплики:${NC}"
    echo -e "    ${CYAN}kubectl exec -n $NAMESPACE $POD_NAME -- redis-cli -p 26379 sentinel slaves mymaster${NC}"
    
    echo -e "  ${YELLOW}Сбросить состояние сентинела (осторожно!):${NC}"
    echo -e "    ${CYAN}kubectl exec -n $NAMESPACE $POD_NAME -- redis-cli -p 26379 sentinel reset mymaster${NC}"
}

# Функция для проверки всех сентинелов
check_all_sentinels() {
    echo -e "\n${PURPLE}${BOLD}6. Проверка всех сентинелов в кластере:${NC}"
    
    # Получаем все поды сентинелов в неймспейсе, фильтруем по кластеру
    local all_sentinel_pods=($(kubectl get pods -n $NAMESPACE --no-headers -o custom-columns=":metadata.name" | grep "rfs-" || true))
    local sentinel_pods=()
    
    for pod in "${all_sentinel_pods[@]}"; do
        if [[ "$pod" == *"$CLUSTER_ID"* ]]; then
            sentinel_pods+=("$pod")
        fi
    done
    
    # Если не нашли поды по кластеру, используем все
    if [ ${#sentinel_pods[@]} -eq 0 ]; then
        sentinel_pods=("${all_sentinel_pods[@]}")
        echo -e "${YELLOW}Не найдено сентинелов для кластера $CLUSTER_ID, используем все доступные сентинелы${NC}"
    fi
    
    if [ ${#sentinel_pods[@]} -eq 0 ]; then
        echo -e "${YELLOW}  Сентинелы не найдены${NC}"
        return 1
    fi
    
    echo -e "${CYAN}  Найдено сентинелов в кластере $CLUSTER_ID: ${#sentinel_pods[@]}${NC}"
    
    local total_sentinels=0
    local running_sentinels=0
    local sentinels_with_issues=0
    
    for sentinel_pod in "${sentinel_pods[@]}"; do
        echo -e "\n${CYAN}  Сентинел: $sentinel_pod${NC}"
        
        # Получаем IP адрес сентинела
        local sentinel_ip=$(get_pod_ip "$sentinel_pod")
        echo -e "    ${CYAN}IP: $sentinel_ip${NC}"
        
        # Проверяем статус пода
        local pod_status=$(kubectl get pod -n $NAMESPACE $sentinel_pod -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        if [ "$pod_status" = "Running" ]; then
            echo -e "    ${GREEN}Статус: $pod_status${NC}"
            ((running_sentinels++))
            
            # Получаем информацию о мастерах с этого сентинела
            local masters_info=$(exec_cmd_on_pod "$sentinel_pod" "sentinel masters")
            
            if [[ "$masters_info" != *"ERROR"* ]] && [ -n "$masters_info" ]; then
                local master_name=$(echo "$masters_info" | grep "name" | head -1 | awk -F '"' '{print $2}' 2>/dev/null)
                local master_status=$(echo "$masters_info" | grep "status" | head -1 | awk '{print $2}' 2>/dev/null)
                
                if [ -n "$master_name" ]; then
                    echo -e "    ${CYAN}Мастер: $master_name${NC}"
                else
                    echo -e "    ${YELLOW}Мастер: не определен${NC}"
                    ((sentinels_with_issues++))
                fi
                
                if [ -n "$master_status" ]; then
                    if [ "$master_status" = "ok" ]; then
                        echo -e "    ${GREEN}Статус мастера: $master_status${NC}"
                    else
                        echo -e "    ${RED}Статус мастера: $master_status${NC}"
                        ((sentinels_with_issues++))
                    fi
                else
                    echo -e "    ${YELLOW}Статус мастера: не определен${NC}"
                    ((sentinels_with_issues++))
                fi
                
                # Получаем количество сентинелов
                local sentinels_count=0
                if [ -n "$master_name" ]; then
                    local sentinels_info=$(exec_cmd_on_pod "$sentinel_pod" "sentinel sentinels $master_name")
                    if [[ "$sentinels_info" != *"ERROR"* ]]; then
                        sentinels_count=$(echo "$sentinels_info" | grep -c "name" 2>/dev/null || echo "0")
                    fi
                fi
                
                echo -e "    ${CYAN}Видимых сентинелов: $((sentinels_count + 1))${NC}"
                
                # Проверяем кворум
                local sentinels_total=${#sentinel_pods[@]}
                local sentinels_required=$(( (sentinels_total / 2) + 1 ))
                local visible_sentinels=$((sentinels_count + 1))
                
                echo -e "    ${CYAN}Всего сентинелов в кластере: $sentinels_total${NC}"
                echo -e "    ${CYAN}Требуется для кворума: $sentinels_required${NC}"
                
                if [ $visible_sentinels -ge $sentinels_required ]; then
                    echo -e "    ${GREEN}✓ Кворум достижим${NC}"
                else
                    echo -e "    ${RED}⚠️  КВОРУМ НЕДОСТИЖИМ${NC}"
                    echo -e "    ${RED}  Причина: недостаточно видимых сентинелов${NC}"
                    echo -e "    ${RED}  Решение: проверьте сетевую связность между сентинелами${NC}"
                    echo -e "    ${RED}  Или увеличьте количество сентинелов в кластере${NC}"
                    ((sentinels_with_issues++))
                fi
                
                # Дополнительная информация о сентинеле
                local sentinel_info=$(exec_cmd_on_pod "$sentinel_pod" "info sentinel")
                if [[ "$sentinel_info" != *"ERROR"* ]]; then
                    local sentinel_tilt=$(echo "$sentinel_info" | grep "sentinel_tilt:" | cut -d: -f2 | tr -d '\r')
                    local sentinel_running_scripts=$(echo "$sentinel_info" | grep "sentinel_running_scripts:" | cut -d: -f2 | tr -d '\r')
                    
                    if [ "$sentinel_tilt" = "0" ]; then
                        echo -e "    ${GREEN}Tilt mode: выключен${NC}"
                    else
                        echo -e "    ${RED}Tilt mode: ВКЛЮЧЕН (требуется внимание)${NC}"
                        ((sentinels_with_issues++))
                    fi
                    
                    if [ "$sentinel_running_scripts" = "0" ]; then
                        echo -e "    ${GREEN}Выполняемые скрипты: $sentinel_running_scripts${NC}"
                    else
                        echo -e "    ${YELLOW}Выполняемые скрипты: $sentinel_running_scripts${NC}"
                    fi
                fi
                
                # Получаем конфигурацию мастера
                if [ -n "$master_name" ]; then
                    local master_config=$(exec_cmd_on_pod "$sentinel_pod" "sentinel master $master_name")
                    echo -e "    ${CYAN}Конфигурация мастера:${NC}"
                    echo "$master_config" | grep -E "(down-after-milliseconds|failover-timeout|parallel-syncs)" | while read line; do
                        echo -e "      ${YELLOW}$line${NC}"
                    done
                    
                    # Получаем кворум для этого мастера
                    local quorum_line=$(echo "$master_config" | grep "quorum")
                    if [ -n "$quorum_line" ]; then
                        echo -e "      ${YELLOW}$quorum_line${NC}"
                    fi
                fi
            else
                echo -e "    ${RED}Не удалось получить информацию о мастерах${NC}"
                ((sentinels_with_issues++))
            fi
            
            # Получаем и анализируем логи сентинела
            echo -e "    ${CYAN}Анализ логов сентинела:${NC}"
            local sentinel_logs=$(kubectl logs -n $NAMESPACE $sentinel_pod --tail=20 2>/dev/null | grep -E -i "quorum|vote|elected|failover|odown|sdown|sentinel|master|slave|sync|mymaster" | tail -5)
            if [ -n "$sentinel_logs" ]; then
                echo "$sentinel_logs" | while IFS= read -r log_line; do
                    if [[ "$log_line" =~ [Ee][Rr][Rr][Oo][Rr] ]]; then
                        echo -e "      ${RED}$log_line${NC}"
                    elif [[ "$log_line" =~ [Ww][Aa][Rr][Nn] ]]; then
                        echo -e "      ${ORANGE}$log_line${NC}"
                    elif [[ "$log_line" =~ ([Ss][Yy][Nn][Cc]|[Rr][Ee][Pp][Ll][Ii][Cc][Aa][Tt][Ii][Oo][Nn]) ]]; then
                        echo -e "      ${GREEN}$log_line${NC}"
                    elif [[ "$log_line" =~ ([Mm][Aa][Ss][Tt][Ee][Rr]|[Ss][Ll][Aa][Vv][Ee]) ]]; then
                        echo -e "      ${PURPLE}$log_line${NC}"
                    else
                        echo -e "      ${YELLOW}$log_line${NC}"
                    fi
                done
            else
                echo -e "      ${YELLOW}Нет релевантных логов${NC}"
            fi
            
        else
            echo -e "    ${RED}Статус: $pod_status${NC}"
            ((sentinels_with_issues++))
        fi
        ((total_sentinels++))
    done
    
    echo -e "\n${PURPLE}${BOLD}Итоги по сентинелам кластера $CLUSTER_ID:${NC}"
    echo -e "${CYAN}  Всего сентинелов: $total_sentinels${NC}"
    echo -e "${GREEN}  Запущено: $running_sentinels${NC}"
    echo -e "${RED}  Не запущено: $((total_sentinels - running_sentinels))${NC}"
    echo -e "${YELLOW}  С проблемами: $sentinels_with_issues${NC}"
    
    # Анализ проблем с кворумом
    if [ $running_sentinels -lt $(( (total_sentinels / 2) + 1 )) ]; then
        echo -e "\n${RED}${BOLD}КРИТИЧЕСКАЯ ПРОБЛЕМА: КВОРУМ НЕВОЗМОЖЕН${NC}"
        echo -e "${RED}Причины и решения:${NC}"
        echo -e "${RED}  1. Недостаточно запущенных сентинелов${NC}"
        echo -e "${RED}  2. Проверьте: kubectl get pods -n $NAMESPACE | grep rfs- | grep $CLUSTER_ID${NC}"
        echo -e "${RED}  3. Убедитесь, что все сентинелы могут общаться друг с другом${NC}"
        echo -e "${RED}  4. Проверьте настройки сети и firewalls${NC}"
    fi
}

# Функция для вывода логов с цветовым кодированием
show_pod_logs() {
    echo -e "\n${PURPLE}${BOLD}Логи пода (последние 50 строк):${NC}"
    
    # Получаем логи с большим количеством строк
    local all_logs=$(kubectl logs -n $NAMESPACE $POD_NAME --tail=50 2>/dev/null || echo -e "${RED}Не удалось получить логи пода${NC}")
    
    if [[ "$all_logs" == *"Не удалось получить логи"* ]]; then
        echo -e "${RED}$all_logs${NC}"
        return 1
    fi
    
    # Выводим все логи с цветовой разметкой
    echo "$all_logs" | while IFS= read -r line; do
        if [[ "$line" =~ [Ee][Rr][Rr][Oo][Rr] ]]; then
            echo -e "${RED}$line${NC}"
        elif [[ "$line" =~ [Ww][Aa][Rr][Nn] ]]; then
            echo -e "${ORANGE}$line${NC}"
        elif [[ "$line" =~ [Ii][Nn][Ff][Oo] ]]; then
            echo -e "${BLUE}$line${NC}"
        elif [[ "$line" =~ [Dd][Ee][Bb][Uu][Gg] ]]; then
            echo -e "${CYAN}$line${NC}"
        elif [[ "$line" =~ ([Ss][Yy][Nn][Cc]|[Rr][Ee][Pp][Ll][Ii][Cc][Aa][Tt][Ii][Oo][Nn]) ]]; then
            echo -e "${GREEN}$line${NC}"
        elif [[ "$line" =~ ([Mm][Aa][Ss][Tt][Ee][Rr]|[Ss][Ll][Aa][Vv][Ee]) ]]; then
            echo -e "${PURPLE}$line${NC}"
        else
            echo -e "${YELLOW}$line${NC}"
        fi
    done
    
    # Анализ логов на предмет успешной репликации
    echo -e "\n${PURPLE}${BOLD}Анализ событий репликации:${NC}"
    local replication_events=$(echo "$all_logs" | grep -i -E "sync|replication|master|slave|connected" | tail -10)
    
    if [ -n "$replication_events" ]; then
        local last_sync=$(echo "$replication_events" | grep -i "sync" | tail -1)
        local last_master=$(echo "$replication_events" | grep -i "master" | tail -1)
        local last_connected=$(echo "$replication_events" | grep -i "connected" | tail -1)
        
        if [ -n "$last_sync" ]; then
            if [[ "$last_sync" =~ "success"|"complete"|"finished" ]]; then
                echo -e "${GREEN}✓ Последняя синхронизация: УСПЕШНО${NC}"
                echo -e "  ${GREEN}$last_sync${NC}"
            else
                echo -e "${YELLOW}⚠ Последняя синхронизация: В ПРОЦЕССЕ${NC}"
                echo -e "  ${YELLOW}$last_sync${NC}"
            fi
        fi
        
        if [ -n "$last_connected" ]; then
            if [[ "$last_connected" =~ "connected" ]]; then
                echo -e "${GREEN}✓ Подключение: АКТИВНО${NC}"
                echo -e "  ${GREEN}$last_connected${NC}"
            fi
        fi
    else
        echo -e "${YELLOW}События репликации не найдены в логах${NC}"
    fi
    
    # Для сентинелов дополнительный анализ
    if [ "$POD_TYPE" = "sentinel" ]; then
        echo -e "\n${PURPLE}${BOLD}Анализ событий Sentinel:${NC}"
        local sentinel_events=$(echo "$all_logs" | grep -i -E "quorum|vote|elected|failover|odown|sdown|mymaster" | tail -10)
        
        if [ -n "$sentinel_events" ]; then
            local last_quorum=$(echo "$sentinel_events" | grep -i "quorum" | tail -1)
            local last_failover=$(echo "$sentinel_events" | grep -i "failover" | tail -1)
            local last_elected=$(echo "$sentinel_events" | grep -i "elected" | tail -1)
            local last_mymaster=$(echo "$sentinel_events" | grep -i "mymaster" | tail -1)
            
            if [ -n "$last_quorum" ]; then
                if [[ "$last_quorum" =~ "enough"|"reached" ]]; then
                    echo -e "${GREEN}✓ Кворум: ДОСТИГНУТ${NC}"
                else
                    echo -e "${RED}⚠ Кворум: НЕ ДОСТИГНУТ${NC}"
                fi
                echo -e "  ${CYAN}$last_quorum${NC}"
            fi
            
            if [ -n "$last_failover" ]; then
                echo -e "${ORANGE}⚠ Событие failover:${NC}"
                echo -e "  ${ORANGE}$last_failover${NC}"
            fi
            
            if [ -n "$last_elected" ]; then
                echo -e "${PURPLE}✓ Выборы: ПРОИЗОШЛИ${NC}"
                echo -e "  ${PURPLE}$last_elected${NC}"
            fi
            
            if [ -n "$last_mymaster" ]; then
                echo -e "${BLUE}Информация о мастере:${NC}"
                echo -e "  ${BLUE}$last_mymaster${NC}"
            fi
        else
            echo -e "${YELLOW}События Sentinel не найдены в логах${NC}"
        fi
    fi
}

# Функция для проверки конфигурации бутстрапа
check_bootstrap_config() {
    echo -e "\n${PURPLE}${BOLD}Проверка конфигурации бутстрапа:${NC}"
    
    if [ "$POD_TYPE" = "sentinel" ]; then
        # Для сентинела проверяем известных мастеров
        local masters
        if [ -n "$REDIS_PASSWORD" ]; then
            masters=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -a '$REDIS_PASSWORD' -p 26379 sentinel masters 2>&1" 2>/dev/null || echo "ERROR")
            masters=$(echo "$masters" | grep -v "Warning: Using a password")
        else
            masters=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -p 26379 sentinel masters 2>&1" 2>/dev/null || echo "ERROR")
        fi
        
        if [[ "$masters" != *"ERROR"* ]] && [ -n "$masters" ]; then
            local master_count=$(echo "$masters" | grep -c "name")
            echo -e "${GREEN}✓ Настроено мастеров: $master_count${NC}"
            
            if [ "$master_count" -gt 0 ]; then
                echo "$masters" | grep "name" | while read line; do
                    local master_name=$(echo "$line" | awk -F '"' '{print $2}')
                    echo -e "  ${CYAN}Мастер: $master_name${NC}"
                    
                    # Проверяем конфигурацию каждого мастера
                    local master_config
                    if [ -n "$REDIS_PASSWORD" ]; then
                        master_config=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -a '$REDIS_PASSWORD' -p 26379 sentinel master $master_name 2>&1" 2>/dev/null || echo "ERROR")
                        master_config=$(echo "$master_config" | grep -v "Warning: Using a password")
                    else
                        master_config=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -p 26379 sentinel master $master_name 2>&1" 2>/dev/null || echo "ERROR")
                    fi
                    
                    echo -e "  ${YELLOW}Конфигурация мастера $master_name:${NC}"
                    echo "$master_config" | grep -E "(down-after-milliseconds|failover-timeout|parallel-syncs|quorum)" | while read config_line; do
                        echo -e "    ${YELLOW}$config_line${NC}"
                    done
                done
            fi
        else
            echo -e "${RED}✗ Мастера не настроены в сентинеле${NC}"
            echo -e "${YELLOW}Необходима настройка бутстрапа сентинелов${NC}"
        fi
    else
        # Для Redis проверяем настройки репликации
        local role=$(exec_redis_cmd "info replication" | grep "role:" | cut -d: -f2 | tr -d '\r')
        if [ "$role" = "slave" ]; then
            local master_host=$(exec_redis_cmd "info replication" | grep "master_host:" | cut -d: -f2 | tr -d '\r')
            local master_port=$(exec_redis_cmd "info replication" | grep "master_port:" | cut -d: -f2 | tr -d '\r')
            echo -e "${GREEN}✓ Репликация настроена на мастер: $master_host:$master_port${NC}"
            
            # Определяем имя пода мастера
            local master_pod_name=$(get_pod_name_by_ip "$master_host")
            echo -e "${CYAN}  Под мастера: $master_pod_name${NC}"
        elif [ "$role" = "master" ]; then
            local slaves_count=$(exec_redis_cmd "info replication" | grep "connected_slaves:" | cut -d: -f2 | tr -d '\r')
            echo -e "${GREEN}✓ Роль: MASTER, подключенных реплик: $slaves_count${NC}"
        fi
    fi
}

# Функция для проверки Redis
check_redis() {
    echo -e "${GREEN}${BOLD}=== КРИТИЧЕСКИЕ ПАРАМЕТРЫ REDIS ===${NC}"
    
    # 1. Состав кластера и репликация
    echo -e "\n${PURPLE}${BOLD}1. Состав кластера и репликация:${NC}"
    
    local role=$(exec_redis_cmd "info replication" | grep "role:" | cut -d: -f2 | tr -d '\r' | head -1)
    if [ "$role" = "master" ]; then
        echo -e "${GREEN}✓ Роль: MASTER${NC}"
        
        # Получаем имя текущего пода
        local current_pod=$(exec_redis_cmd "info server" | grep "run_id:" | cut -d: -f2 | tr -d '\r' | head -1)
        echo -e "${CYAN}  Имя пода (run_id): ${current_pod:0:10}...${NC}"
        
        # Получаем IP текущего пода
        local current_ip=$(get_pod_ip "$POD_NAME")
        echo -e "${CYAN}  IP пода: $current_ip${NC}"
        
        # Получаем master offset
        local master_offset=$(exec_redis_cmd "info replication" | grep "master_repl_offset:" | cut -d: -f2 | tr -d '\r' | head -1)
        echo -e "${CYAN}  Смещение мастера: $master_offset${NC}"
        
        local connected_slaves=$(exec_redis_cmd "info replication" | grep "connected_slaves:" | cut -d: -f2 | tr -d '\r')
        echo -e "${CYAN}  Подключенных реплик: $connected_slaves${NC}"
        
        if [ "$connected_slaves" -eq "0" ]; then
            echo -e "${RED}  ⚠️  ВНИМАНИЕ: Нет подключенных реплик${NC}"
        else
            echo -e "${CYAN}  Информация о репликах:${NC}"
            
            # Исправленный парсинг информации о репликах
            local slave_info=$(exec_redis_cmd "info replication")
            local slave_lines=$(echo "$slave_info" | grep -E "slave[0-9]+:" | head -10)
            
            while IFS= read -r slave_line; do
                if [ -n "$slave_line" ]; then
                    # Парсим информацию о реплике
                    local slave_ip=$(echo "$slave_line" | grep -o "ip=[^,]*" | cut -d= -f2)
                    local slave_port=$(echo "$slave_line" | grep -o "port=[^,]*" | cut -d= -f2)
                    local slave_state=$(echo "$slave_line" | grep -o "state=[^,]*" | cut -d= -f2)
                    local slave_offset=$(echo "$slave_line" | grep -o "offset=[^,]*" | cut -d= -f2)
                    local slave_lag=$(echo "$slave_line" | grep -o "lag=[^,]*" | cut -d= -f2)
                    
                    local slave_pod=$(get_pod_name_by_ip "$slave_ip")
                    
                    # Форматируем вывод
                    if [[ "$slave_lag" =~ ^[0-9]+$ ]] && [[ "$slave_offset" =~ ^[0-9]+$ ]]; then
                        if [ "$slave_lag" -le 1 ]; then
                            echo -e "    ${GREEN}реплика: $slave_pod, IP: $slave_ip, состояние: $slave_state, смещение: $slave_offset, отставание: $slave_lag${NC}"
                        elif [ "$slave_lag" -le 5 ]; then
                            echo -e "    ${YELLOW}реплика: $slave_pod, IP: $slave_ip, состояние: $slave_state, смещение: $slave_offset, отставание: $slave_lag${NC}"
                        else
                            echo -e "    ${RED}реплика: $slave_pod, IP: $slave_ip, состояние: $slave_state, смещение: $slave_offset, отставание: $slave_lag${NC}"
                        fi
                    else
                        echo -e "    ${YELLOW}реплика: $slave_pod, IP: $slave_ip, состояние: $slave_state, смещение: неизвестно, отставание: неизвестно${NC}"
                    fi
                fi
            done <<< "$slave_lines"
        fi
        
    elif [ "$role" = "slave" ]; then
        echo -e "${CYAN}✓ Роль: REPLICA${NC}"
        
        # Получаем имя текущего пода
        local current_pod=$(exec_redis_cmd "info server" | grep "run_id:" | cut -d: -f2 | tr -d '\r' | head -1)
        echo -e "${CYAN}  Имя пода (run_id): ${current_pod:0:10}...${NC}"
        
        # Получаем IP текущего пода
        local current_ip=$(get_pod_ip "$POD_NAME")
        echo -e "${CYAN}  IP пода: $current_ip${NC}"
        
        local master_host=$(exec_redis_cmd "info replication" | grep "master_host:" | cut -d: -f2 | tr -d '\r' | head -1)
        local master_port=$(exec_redis_cmd "info replication" | grep "master_port:" | cut -d: -f2 | tr -d '\r' | head -1)
        local master_link_status=$(exec_redis_cmd "info replication" | grep "master_link_status:" | cut -d: -f2 | tr -d '\r' | head -1)
        local master_last_io_seconds=$(exec_redis_cmd "info replication" | grep "master_last_io_seconds_ago:" | cut -d: -f2 | tr -d '\r' | head -1)
        
        # Получаем slave offset
        local slave_offset=$(exec_redis_cmd "info replication" | grep "slave_repl_offset:" | cut -d: -f2 | tr -d '\r' | head -1)
        echo -e "${CYAN}  Смещение реплики: $slave_offset${NC}"
        
        # Определяем имя пода мастера
        local master_pod_name=$(get_pod_name_by_ip "$master_host")
        
        echo -e "${CYAN}  Мастер: $master_host:$master_port (под: $master_pod_name)${NC}"
        if [ "$master_link_status" = "up" ]; then
            echo -e "${GREEN}  Статус подключения к мастеру: $master_link_status${NC}"
            
            # Проверяем успешность репликации
            local repl_state=$(exec_redis_cmd "info replication" | grep "master_sync_in_progress:" | cut -d: -f2 | tr -d '\r')
            if [ "$repl_state" = "0" ]; then
                echo -e "${GREEN}  ✓ Репликация активна и синхронизирована${NC}"
            else
                echo -e "${YELLOW}  ⚠️  Синхронизация репликации в процессе${NC}"
            fi
        else
            echo -e "${RED}  Статус подключения к мастеру: $master_link_status${NC}"
        fi
        
        # Анализ времени последнего IO с цветовой индикацией
        if [[ "$master_last_io_seconds" =~ ^[0-9]+$ ]]; then
            if [ "$master_last_io_seconds" -lt 5 ]; then
                echo -e "${GREEN}  Последний IO: $master_last_io_seconds секунд назад${NC}"
            elif [ "$master_last_io_seconds" -lt 30 ]; then
                echo -e "${YELLOW}  Последний IO: $master_last_io_seconds секунд назад${NC}"
            else
                echo -e "${RED}  Последний IO: $master_last_io_seconds секунд назад${NC}"
            fi
        else
            echo -e "${RED}  Последний IO: неизвестно${NC}"
        fi
        
        # Детальный анализ лага репликации
        get_replication_lag_info "$role"
        
    else
        echo -e "${YELLOW}Роль: $role${NC}"
    fi
    
    # 2. Использование памяти
    echo -e "\n${PURPLE}${BOLD}2. Использование памяти:${NC}"
    local used_memory=$(exec_redis_cmd "info memory" | grep "used_memory:" | cut -d: -f2 | tr -d '\r' | head -1)
    local used_memory_human=$(exec_redis_cmd "info memory" | grep "used_memory_human:" | cut -d: -f2 | tr -d '\r' | head -1)
    local used_memory_peak=$(exec_redis_cmd "info memory" | grep "used_memory_peak:" | cut -d: -f2 | tr -d '\r' | head -1)
    local used_memory_peak_human=$(exec_redis_cmd "info memory" | grep "used_memory_peak_human:" | cut -d: -f2 | tr -d '\r' | head -1)
    local maxmemory=$(exec_redis_cmd "info memory" | grep "maxmemory:" | cut -d: -f2 | tr -d '\r' | head -1)
    
    echo -e "${CYAN}  Использовано: $used_memory_human ($used_memory байт)${NC}"
    echo -e "${CYAN}  Пиковое использование: $used_memory_peak_human${NC}"
    
    if [ "$maxmemory" != "0" ]; then
        local memory_usage=$((used_memory * 100 / maxmemory))
        if [ "$memory_usage" -gt 90 ]; then
            echo -e "${RED}  ⚠️  Использование памяти: $memory_usage% (КРИТИЧЕСКИЙ УРОВЕНЬ)${NC}"
        elif [ "$memory_usage" -gt 80 ]; then
            echo -e "${YELLOW}  ⚠️  Использование памяти: $memory_usage% (ВЫСОКИЙ УРОВЕНЬ)${NC}"
        else
            echo -e "${GREEN}  Использование памяти: $memory_usage%${NC}"
        fi
    fi
    
    # 3. Клиентские подключения
    echo -e "\n${PURPLE}${BOLD}3. Клиентские подключения:${NC}"
    local connected_clients=$(exec_redis_cmd "info clients" | grep "connected_clients:" | cut -d: -f2 | tr -d '\r' | head -1)
    local maxclients=$(exec_redis_cmd "info clients" | grep "maxclients:" | cut -d: -f2 | tr -d '\r' | head -1)
    
    echo -e "${CYAN}  Подключенных клиентов: $connected_clients${NC}"
    echo -e "${CYAN}  Максимум клиентов: $maxclients${NC}"
    
    if [ "$maxclients" != "0" ]; then
        local client_usage=$((connected_clients * 100 / maxclients))
        if [ "$client_usage" -gt 90 ]; then
            echo -e "${RED}  ⚠️  Использование подключений: $client_usage% (КРИТИЧЕСКИЙ УРОВЕНЬ)${NC}"
        elif [ "$client_usage" -gt 80 ]; then
            echo -e "${YELLOW}  ⚠️  Использование подключений: $client_usage% (ВЫСОКИЙ УРОВЕНЬ)${NC}"
        fi
    fi
    
    # 4. Сохранность данных
    echo -e "\n${PURPLE}${BOLD}4. Сохранность данных:${NC}"
    local rdb_last_save_time=$(exec_redis_cmd "info persistence" | grep "rdb_last_save_time:" | cut -d: -f2 | tr -d '\r' | head -1)
    local rdb_last_bgsave_status=$(exec_redis_cmd "info persistence" | grep "rdb_last_bgsave_status:" | cut -d: -f2 | tr -d '\r' | head -1)
    local aof_enabled=$(exec_redis_cmd "info persistence" | grep "aof_enabled:" | cut -d: -f2 | tr -d '\r' | head -1)
    
    local current_time=$(date +%s)
    local last_save_ago=$((current_time - rdb_last_save_time))
    
    echo -e "${CYAN}  Последнее сохранение RDB: $last_save_ago секунд назад${NC}"
    if [ "$rdb_last_bgsave_status" = "ok" ]; then
        echo -e "${GREEN}  Статус последнего RDB: $rdb_last_bgsave_status${NC}"
    else
        echo -e "${RED}  Статус последнего RDB: $rdb_last_bgsave_status${NC}"
    fi
    echo -e "${CYAN}  AOF включен: $aof_enabled${NC}"
    
    if [ "$last_save_ago" -gt 3600 ]; then
        echo -e "${RED}  ⚠️  ВНИМАНИЕ: Последнее сохранение было более часа назад${NC}"
    fi
    
    # 5. Статистика операций
    echo -e "\n${PURPLE}${BOLD}5. Статистика операций:${NC}"
    local instantaneous_ops_per_sec=$(exec_redis_cmd "info stats" | grep "instantaneous_ops_per_sec:" | cut -d: -f2 | tr -d '\r' | head -1)
    local keyspace_hits=$(exec_redis_cmd "info stats" | grep "keyspace_hits:" | cut -d: -f2 | tr -d '\r' | head -1)
    local keyspace_misses=$(exec_redis_cmd "info stats" | grep "keyspace_misses:" | cut -d: -f2 | tr -d '\r' | head -1)
    
    echo -e "${CYAN}  Операций в секунду: $instantaneous_ops_per_sec${NC}"
    
    if [ "$keyspace_hits" -gt 0 ] || [ "$keyspace_misses" -gt 0 ]; then
        local total=$((keyspace_hits + keyspace_misses))
        local hit_rate=0
        if [ "$total" -gt 0 ]; then
            hit_rate=$((keyspace_hits * 100 / total))
        fi
        echo -e "${CYAN}  Hit Rate: $hit_rate% ($keyspace_hits попаданий / $keyspace_misses промахов)${NC}"
        
        if [ "$hit_rate" -lt 80 ]; then
            echo -e "${YELLOW}  ⚠️  Низкий показатель попаданий${NC}"
        fi
    fi
    
    # 6. Ключи и данные
    echo -e "\n${PURPLE}${BOLD}6. Ключи и данные:${NC}"
    local total_keys=0
    for db in {0..15}; do
        local count=$(exec_redis_cmd "select $db\ndbsize" | grep -E '^[0-9]+$' | head -1)
        if [ -n "$count" ] && [ "$count" -gt "0" ]; then
            echo -e "${CYAN}  База данных $db: $count ключей${NC}"
            total_keys=$((total_keys + count))
        fi
    done
    echo -e "${GREEN}  Всего ключей: $total_keys${NC}"
    
    # 7. Расширенная диагностика архитектуры Redis
    echo -e "\n${PURPLE}${BOLD}7. Расширенная диагностика архитектуры Redis:${NC}"
    
    # Инициализация переменных
    local IS_CLUSTER=0
    local IS_SENTINEL=0
    
    # 7.1 Определение архитектуры Redis
    echo -e "${CYAN}7.1 Определение архитектуры Redis:${NC}"
    
    # Проверка поддержки Redis Cluster
    local cluster_info_output=$(exec_redis_cmd "CLUSTER INFO" 2>&1)
    if [[ "$cluster_info_output" == *"cluster_state:"* ]]; then
        echo -e "${GREEN}  ✓ Архитектура: Redis Cluster [обнаружен]${NC}"
        local cluster_state=$(echo "$cluster_info_output" | grep "cluster_state:" | cut -d: -f2 | tr -d '\r')
        echo -e "${CYAN}  Состояние кластера: $cluster_state${NC}"
        IS_CLUSTER=1
    else
        echo -e "${CYAN}  Архитектура: Redis Cluster не активирован${NC}"
        IS_CLUSTER=0
    fi
    
    # Проверка поддержки Sentinel
    local sentinel_info_output=$(exec_redis_cmd "SENTINEL masters" 2>&1)
    if [[ "$sentinel_info_output" != *"ERR unknown command"* ]] && [[ "$sentinel_info_output" != *"ERROR"* ]]; then
        echo -e "${GREEN}  ✓ Архитектура: Redis Sentinel [обнаружен]${NC}"
        IS_SENTINEL=1
    else
        echo -e "${CYAN}  Архитектура: Sentinel не активирован${NC}"
        IS_SENTINEL=0
    fi
    
    # 7.2 Детальный анализ Sentinel
    if [ "$IS_SENTINEL" -eq 1 ]; then
        echo -e "\n${CYAN}7.2 Детальный анализ Sentinel:${NC}"
        
        # Проверка кворума и количества сентинелов
        local sentinel_masters=$(exec_redis_cmd "SENTINEL masters")
        local master_name=$(echo "$sentinel_masters" | grep "name" | head -1 | awk -F '"' '{print $2}')
        
        if [ -n "$master_name" ]; then
            local sentinel_count=$(exec_redis_cmd "SENTINEL sentinels $master_name" | grep -c "name" 2>/dev/null || echo "0")
            local total_sentinels=$((sentinel_count + 1)) # +1 для текущего
            local quorum=$(exec_redis_cmd "SENTINEL master $master_name" | grep "quorum" | awk '{print $2}')
            
            echo -e "${CYAN}  Мастер: $master_name | Видимых сентинелов: $total_sentinels | Кворум: $quorum${NC}"
            
            # Оценка надежности конфигурации
            if [ "$total_sentinels" -lt 3 ]; then
                echo -e "${RED}  ⚠️  НЕНАДЕЖНАЯ КОНФИГУРАЦИЯ: Для отказоустойчивости требуется минимум 3 узла Sentinel.${NC}"
            elif [ "$total_sentinels" -ge 3 ] && [ "$total_sentinels" -lt 5 ]; then
                echo -e "${YELLOW}  ⚠️  Ограниченная отказоустойчивость: Конфигурация с $total_sentinels узлами работоспособна, но чувствительна к потере узлов.${NC}"
            else
                echo -e "${GREEN}  ✓ Надежная конфигурация: Достаточно узлов для отказоустойчивости.${NC}"
            fi
            
            # Анализ состояния failover
            local is_failover=$(exec_redis_cmd "SENTINEL failover-status $master_name" 2>&1)
            if [[ "$is_failover" != *"NOFAILOVER"* ]]; then
                echo -e "${YELLOW}  ⚠️  Обнаружена активная процедура failover!${NC}"
            fi
            
            # Получаем информацию о репликах
            local slaves_info=$(exec_redis_cmd "SENTINEL slaves $master_name")
            local slave_count=$(echo "$slaves_info" | grep -c "name" 2>/dev/null || echo "0")
            echo -e "${CYAN}  Количество реплик мастера: $slave_count${NC}"
            
            if [ "$slave_count" -eq 0 ]; then
                echo -e "${RED}  ⚠️  ОПАСНО: Мастер не имеет реплик! Отсутствует отказоустойчивость.${NC}"
            fi
        else
            echo -e "${YELLOW}  Не удалось определить имя мастера${NC}"
        fi
    fi
    
    # 7.3 Детальный анализ Redis Cluster
    if [ "$IS_CLUSTER" -eq 1 ]; then
        echo -e "\n${CYAN}7.3 Детальный анализ Redis Cluster:${NC}"
        
        local cluster_info=$(exec_redis_cmd "CLUSTER INFO")
        local cluster_state=$(echo "$cluster_info" | grep "cluster_state:" | cut -d: -f2 | tr -d '\r')
        local slots_assigned=$(echo "$cluster_info" | grep "cluster_slots_assigned:" | cut -d: -f2 | tr -d '\r')
        local slots_ok=$(echo "$cluster_info" | grep "cluster_slots_ok:" | cut -d: -f2 | tr -d '\r')
        local known_nodes=$(echo "$cluster_info" | grep "cluster_known_nodes:" | cut -d: -f2 | tr -d '\r')
        
        echo -e "${CYAN}  Узлов в кластере: $known_nodes | Назначено слотов: $slots_assigned/16384${NC}"
        
        # Проверка целостности кластера
        if [ "$cluster_state" != "ok" ]; then
            echo -e "${RED}  ⚠️  КРИТИЧЕСКОЕ СОСТОЯНИЕ: Кластер не в состоянии 'ok'[$cluster_state]. Возможна потеря данных!${NC}"
        elif [ "$slots_assigned" -ne 16384 ]; then
            echo -e "${RED}  ⚠️  ПРОБЛЕМА: Не все хеш-слоты назначены ($slots_assigned/16384).${NC}"
        elif [ "$slots_ok" -ne 16384 ]; then
            echo -e "${YELLOW}  ⚠️  ПРЕДУПРЕЖДЕНИЕ: Не все слоты находятся в состоянии 'ok' ($slots_ok/16384).${NC}"
        else
            echo -e "${GREEN}  ✓ Кластер здоров: Все слоты назначены и работают корректно.${NC}"
        fi
        
        # Проверка распределения узлов
        local nodes_info=$(exec_redis_cmd "CLUSTER NODES")
        local masters_count=$(echo "$nodes_info" | grep -c "master")
        local replicas_count=$(echo "$nodes_info" | grep -c "slave")
        
        echo -e "${CYAN}  Распределение: Мастеров - $masters_count, Реплик - $replicas_count${NC}"
        
        # Проверка балансировки реплик
        if [ "$replicas_count" -lt "$masters_count" ]; then
            echo -e "${YELLOW}  ⚠️  Дисбаланс: Не у всех мастеров есть реплика для отказоустойчивости.${NC}"
        fi
        
        # Анализ состояния каждого узла
        echo -e "${CYAN}  Состояние узлов кластера:${NC}"
        echo "$nodes_info" | head -10 | while read line; do
            local node_id=$(echo "$line" | awk '{print $1}' | cut -c-8)
            local node_ip=$(echo "$line" | awk '{print $2}' | cut -d: -f1)
            local node_port=$(echo "$line" | awk '{print $2}' | cut -d: -f2)
            local node_flags=$(echo "$line" | awk '{print $3}')
            local node_status=$(echo "$line" | awk '{print $8}')
            
            if [[ "$node_flags" == *"master"* ]]; then
                if [[ "$node_status" == "connected" ]]; then
                    echo -e "    ${GREEN}Мастер $node_ip:$node_port: $node_status${NC}"
                else
                    echo -e "    ${RED}Мастер $node_ip:$node_port: $node_status${NC}"
                fi
            elif [[ "$node_flags" == *"slave"* ]]; then
                if [[ "$node_status" == "connected" ]]; then
                    echo -e "    ${CYAN}Реплика $node_ip:$node_port: $node_status${NC}"
                else
                    echo -e "    ${YELLOW}Реплика $node_ip:$node_port: $node_status${NC}"
                fi
            fi
        done
    fi
    
    # 7.4 Глубокий анализ репликации
    echo -e "\n${CYAN}7.4 Глубокий анализ репликации:${NC}"
    
    local replication_info=$(exec_redis_cmd "INFO REPLICATION")
    local role=$(echo "$replication_info" | grep "role:" | cut -d: -f2 | tr -d '\r')
    
    echo -e "${CYAN}  Роль узла: $role${NC}"
    
    if [ "$role" = "master" ]; then
        local connected_slaves=$(echo "$replication_info" | grep "connected_slaves:" | cut -d: -f2 | tr -d '\r')
        echo -e "${CYAN}  Подключено реплик: $connected_slaves${NC}"
        
        if [ "$connected_slaves" -eq "0" ]; then
            echo -e "${RED}  ⚠️  ВНИМАНИЕ: Отсутствуют подключенные реплики! Нет отказоустойчивости.${NC}"
        else
            # Анализ лага каждой реплики
            for i in $(seq 0 $(($connected_slaves - 1))); do
                local slave_info=$(echo "$replication_info" | grep -A 5 "slave${i}:" | tr '\r' ' ')
                local slave_ip=$(echo "$slave_info" | grep -o "ip=[^,]*" | cut -d= -f2)
                local slave_lag=$(echo "$slave_info" | grep -o "lag=[^,]*" | cut -d= -f2)
                local slave_offset=$(echo "$slave_info" | grep -o "offset=[^,]*" | cut -d= -f2)
                local master_offset=$(echo "$replication_info" | grep "master_repl_offset:" | cut -d: -f2 | tr -d '\r')
                
                if [[ "$slave_lag" =~ ^[0-9]+$ ]] && [ "$slave_lag" -gt 10 ]; then
                    echo -e "${RED}    Реплика $slave_ip: КРИТИЧЕСКИЙ ЛАГ $slave_lag сек. | Отставание: $(($master_offset - $slave_offset)) байт${NC}"
                elif [[ "$slave_lag" =~ ^[0-9]+$ ]] && [ "$slave_lave_lag" -gt 3 ]; then
                    echo -e "${YELLOW}    Реплика $slave_ip: Высокий лаг $slave_lag сек.${NC}"
                elif [[ "$slave_lag" =~ ^[0-9]+$ ]]; then
                    echo -e "${GREEN}    Реплика $slave_ip: Нормальный лаг $slave_lag сек.${NC}"
                fi
            done
        fi
    elif [ "$role" = "slave" ]; then
        local master_host=$(echo "$replication_info" | grep "master_host:" | cut -d: -f2 | tr -d '\r')
        local master_port=$(echo "$replication_info" | grep "master_port:" | cut -d: -f2 | tr -d '\r')
        local master_link_status=$(echo "$replication_info" | grep "master_link_status:" | cut -d: -f2 | tr -d '\r')
        local seconds_since_last_io=$(echo "$replication_info" | grep "master_last_io_seconds_ago:" | cut -d: -f2 | tr -d '\r')
        
        echo -e "${CYAN}  Мастер: $master_host:$master_port | Статус связи: $master_link_status | Последний IO: $seconds_since_last_io сек. назад${NC}"
        
        # Анализ данных на предмет рассинхронизации
        if [ "$master_link_status" != "up" ]; then
            echo -e "${RED}  ⚠️  КРИТИЧЕСКОЕ СОСТОЯНИЕ: Связь с мастером разорвана!${NC}"
        elif [ "$seconds_since_last_io" -gt 10 ]; then
            echo -e "${RED}  ⚠️  ВЫСОКИЙ ЛАГ: Репликация сильно отстает (>10 сек).${NC}"
        elif [ "$seconds_since_last_io" -gt 2 ]; then
            echo -e "${YELLOW}  ⚠️  Задержка репликации: $seconds_since_last_io сек.${NC}"
        fi
        
        # Проверка отставания репликации
        local slave_repl_offset=$(echo "$replication_info" | grep "slave_repl_offset:" | cut -d: -f2 | tr -d '\r')
        local master_repl_offset=$(echo "$replication_info" | grep "master_repl_offset:" | cut -d: -f2 | tr -d '\r' | head -1)
        
        if [ -n "$slave_repl_offset" ] && [ -n "$master_repl_offset" ]; then
            local replication_lag=$((master_repl_offset - slave_repl_offset))
            if [ "$replication_lag" -gt 1048576 ]; then  # Более 1 МБ
                echo -e "${RED}  ⚠️  Большое отставание репликации: $replication_lag байт ($((replication_lag/1024)) КБ)${NC}"
            elif [ "$replication_lag" -gt 10240 ]; then  # Более 10 КБ
                echo -e "${YELLOW}  ⚠️  Умеренное отставание репликации: $replication_lag байт${NC}"
            else
                echo -e "${GREEN}  ✓ Отставание репликации в норме: $replication_lag байт${NC}"
            fi
        fi
    fi
    
    # 7.5 Информация о связанных сентинелах (только для Redis нод)
    echo -e "\n${CYAN}7.5 Информация о связанных Sentinel:${NC}"
    
    # Ищем сентинелы в том же кластере
    local sentinel_pods=($(kubectl get pods -n $NAMESPACE --no-headers -o custom-columns=":metadata.name" | grep "rfs-" | grep "$CLUSTER_ID" || true))
    
    if [ ${#sentinel_pods[@]} -eq 0 ]; then
        echo -e "${YELLOW}  ⚠️  Не найдено сентинелов для кластера $CLUSTER_ID${NC}"
        echo -e "${YELLOW}  Возможные причины:${NC}"
        echo -e "${YELLOW}    - Сентинелы не развернуты${NC}"
        echo -e "${YELLOW}    - Сети между Redis и Sentinel нет${NC}"
        echo -e "${YELLOW}    - Ошибки в именах подов${NC}"
    else
        echo -e "${GREEN}  ✓ Найдено сентинелов в кластере: ${#sentinel_pods[@]}${NC}"
        
        # Проверяем первый сентинел для получения информации
        local first_sentinel="${sentinel_pods[0]}"
        echo -e "${CYAN}  Проверка сентинела: $first_sentinel${NC}"
        
        # Получаем IP сентинела
        local sentinel_ip=$(get_pod_ip "$first_sentinel")
        
        # Проверяем, видит ли Redis сентинелы через команду INFO SENTINEL
        local sentinel_info=$(exec_redis_cmd "info sentinel")
        if [[ "$sentinel_info" != *"ERROR"* ]] && [[ "$sentinel_info" != *"ERR"* ]]; then
            local sentinel_masters=$(echo "$sentinel_info" | grep "sentinel_masters:" | cut -d: -f2 | tr -d '\r')
            if [ -n "$sentinel_masters" ] && [[ "$sentinel_masters" =~ ^[0-9]+$ ]] && [ "$sentinel_masters" -gt 0 ]; then
                echo -e "${GREEN}  ✓ Redis знает о сентинелах (masters: $sentinel_masters)${NC}"
            else
                echo -e "${YELLOW}  ⚠️  Redis не знает о сентинелах (или сентинелы не настроены)${NC}"
            fi
        else
            echo -e "${YELLOW}  ℹ️  Команда INFO SENTINEL не поддерживается (только Redis 2.8+)${NC}"
        fi
        
        # Показываем список сентинелов
        echo -e "${CYAN}  Список сентинелов кластера:${NC}"
        for sentinel_pod in "${sentinel_pods[@]}"; do
            local pod_status=$(kubectl get pod -n $NAMESPACE $sentinel_pod -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
            local pod_ip=$(get_pod_ip "$sentinel_pod")
            
            if [ "$pod_status" = "Running" ]; then
                echo -e "    ${GREEN}✓ $sentinel_pod ($pod_ip) - $pod_status${NC}"
            else
                echo -e "    ${RED}✗ $sentinel_pod ($pod_ip) - $pod_status${NC}"
            fi
        done
        
        # Рекомендации по настройке
        echo -e "${CYAN}  Рекомендации:${NC}"
        echo -e "    ${YELLOW}Для настройки мониторинга выполните на сентинеле:${NC}"
        echo -e "    ${CYAN}  redis-cli -h $sentinel_ip -p 26379 sentinel monitor mymaster $current_ip 6379 2${NC}"
        if [ -n "$REDIS_PASSWORD" ]; then
            echo -e "    ${CYAN}  redis-cli -h $sentinel_ip -p 26379 sentinel auth-pass mymaster $REDIS_PASSWORD${NC}"
        fi
    fi
    
    # 8. Проверка конфигурации бутстрапа
    check_bootstrap_config
}

# Функция для проверки Sentinel
check_sentinel() {
    echo -e "${GREEN}${BOLD}=== КРИТИЧЕСКИЕ ПАРАМЕТРЫ SENTINEL ===${NC}"
    
    # 0. Проверка конфигурации мониторинга
    check_sentinel_monitoring_config
    
    # 1. Основная информация о мастерах
    echo -e "\n${PURPLE}${BOLD}1. Мониторинг мастеров:${NC}"
    
    # Используем правильную команду для сентинела
    local masters_info
    if [ -n "$REDIS_PASSWORD" ]; then
        masters_info=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -a '$REDIS_PASSWORD' -p 26379 sentinel masters 2>&1" 2>/dev/null || echo "ERROR")
        masters_info=$(echo "$masters_info" | grep -v "Warning: Using a password")
    else
        masters_info=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -p 26379 sentinel masters 2>&1" 2>/dev/null || echo "ERROR")
    fi
    
    if [[ "$masters_info" != *"ERROR"* ]]; then
        local master_count=$(echo "$masters_info" | grep -c "name")
        echo -e "${GREEN}✓ Количество отслеживаемых мастеров: $master_count${NC}"
        
        # Информация о каждом мастере
        echo "$masters_info" | while read line; do
            if [[ "$line" == *"name"* ]]; then
                master_name=$(echo "$line" | awk -F '"' '{print $2}')
                echo -e "\n${CYAN}  Мастер: $master_name${NC}"
            elif [[ "$line" == *"status"* ]]; then
                status=$(echo "$line" | awk '{print $2}')
                if [ "$status" = "ok" ]; then
                    echo -e "    ${GREEN}Статус: $status${NC}"
                else
                    echo -e "    ${RED}Статус: $status${NC}"
                fi
            elif [[ "$line" == *"address"* ]]; then
                address=$(echo "$line" | awk '{print $2}')
                echo -e "    ${CYAN}Адрес: $address${NC}"
                
                # Определяем имя пода мастера
                local master_ip=$(echo "$address" | cut -d: -f1)
                local master_port=$(echo "$address" | cut -d: -f2)
                local master_pod=$(get_pod_name_by_ip "$master_ip")
                echo -e "    ${CYAN}Под мастера: $master_pod${NC}"
            elif [[ "$line" == *"slaves"* ]]; then
                slaves=$(echo "$line" | awk '{print $2}')
                echo -e "    ${CYAN}Реплики: $slaves${NC}"
            elif [[ "$line" == *"sentinels"* ]]; then
                sentinels=$(echo "$line" | awk '{print $2}')
                echo -e "    ${CYAN}Сентинелы: $sentinels${NC}"
            fi
        done
    else
        echo -e "${RED}✗ Не удалось получить информацию о мастерах${NC}"
    fi
    
    # 2. Discovery механизм
    check_sentinel_discovery
    
    # 3. Детальная информация о первом мастере
    echo -e "\n${PURPLE}${BOLD}3. Детальная информация о мастере:${NC}"
    
    # Получаем имя первого мастера
    local master_name
    if [ -n "$REDIS_PASSWORD" ]; then
        master_name=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -a '$REDIS_PASSWORD' -p 26379 sentinel masters 2>&1" 2>/dev/null | grep "name" | head -1 | awk -F '"' '{print $2}')
    else
        master_name=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -p 26379 sentinel masters 2>&1" 2>/dev/null | grep "name" | head -1 | awk -F '"' '{print $2}')
    fi
    
    if [ -n "$master_name" ]; then
        echo -e "${CYAN}  Мастер: $master_name${NC}"
        
        # Информация о мастере
        local master_detail
        if [ -n "$REDIS_PASSWORD" ]; then
            master_detail=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -a '$REDIS_PASSWORD' -p 26379 sentinel master $master_name 2>&1" 2>/dev/null || echo "ERROR")
            master_detail=$(echo "$master_detail" | grep -v "Warning: Using a password")
        else
            master_detail=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -p 26379 sentinel master $master_name 2>&1" 2>/dev/null || echo "ERROR")
        fi
        
        if [[ "$master_detail" != *"ERROR"* ]]; then
            echo "$master_detail" | grep -E "(ip|port|runid|flags|link-pending-commands|link-refcount|last-ping-sent|last-ok-ping-reply|last-ping-reply|down-after-milliseconds|info-refresh|role-reported|role-reported-time|config-epoch)" | while read line; do
                echo -e "    ${YELLOW}$line${NC}"
            done
            
            # Информация о репликах
            echo -e "\n${CYAN}  Реплики мастера:${NC}"
            local slaves_info
            if [ -n "$REDIS_PASSWORD" ]; then
                slaves_info=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -a '$REDIS_PASSWORD' -p 26379 sentinel slaves $master_name 2>&1" 2>/dev/null || echo "ERROR")
                slaves_info=$(echo "$slaves_info" | grep -v "Warning: Using a password")
            else
                slaves_info=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -p 26379 sentinel slaves $master_name 2>&1" 2>/dev/null || echo "ERROR")
            fi
            
            if [[ "$slaves_info" != *"ERROR"* ]]; then
                local slave_count=$(echo "$slaves_info" | grep -c "name")
                echo -e "    ${GREEN}Количество реплик: $slave_count${NC}"
                
                if [ "$slave_count" -eq "0" ]; then
                    echo -e "    ${RED}⚠️  ВНИМАНИЕ: Нет реплик${NC}"
                else
                    # Показываем информацию о каждой реплике
                    echo "$slaves_info" | while read line; do
                        if [[ "$line" == *"name"* ]]; then
                            slave_name=$(echo "$line" | awk -F '"' '{print $2}')
                            echo -e "    ${CYAN}Реплика: $slave_name${NC}"
                        elif [[ "$line" == *"ip"* ]]; then
                            slave_ip=$(echo "$line" | awk '{print $2}')
                            slave_port=$(echo "$line" | grep -o "port=[0-9]*" | cut -d= -f2)
                            slave_pod=$(get_pod_name_by_ip "$slave_ip")
                            echo -e "      ${CYAN}Под: $slave_pod ($slave_ip:$slave_port)${NC}"
                        elif [[ "$line" == *"flags"* ]]; then
                            flags=$(echo "$line" | awk '{print $2}')
                            if [[ "$flags" == *"s_down"* ]] || [[ "$flags" == *"o_down"* ]]; then
                                echo -e "      ${RED}Флаги: $flags${NC}"
                            else
                                echo -e "      ${GREEN}Флаги: $flags${NC}"
                            fi
                        fi
                    done
                fi
            fi
            
            # Информация о других сентинелах
            echo -e "\n${CYAN}  Другие сентинелы:${NC}"
            local sentinels_info
            if [ -n "$REDIS_PASSWORD" ]; then
                sentinels_info=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -a '$REDIS_PASSWORD' -p 26379 sentinel sentinels $master_name 2>&1" 2>/dev/null || echo "ERROR")
                sentinels_info=$(echo "$sentinels_info" | grep -v "Warning: Using a password")
            else
                sentinels_info=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -p 26379 sentinel sentinels $master_name 2>&1" 2>/dev/null || echo "ERROR")
            fi
            
            if [[ "$sentinels_info" != *"ERROR"* ]]; then
                local sentinel_count=$(echo "$sentinels_info" | grep -c "name")
                echo -e "    ${GREEN}Количество сентинелов: $((sentinel_count))${NC}"
                
                if [ "$sentinel_count" -eq "0" ]; then
                    echo -e "    ${RED}⚠️  ВНИМАНИЕ: Только один Sentinel${NC}"
                fi
                
                # Проверяем кворум
                local sentinels_required=$(( (sentinel_count + 1) / 2 + 1 ))
                if [ $((sentinel_count + 1)) -ge $sentinels_required ]; then
                    echo -e "    ${GREEN}✓ Кворум достижим (требуется: $sentinels_required)${NC}"
                else
                    echo -e "    ${RED}⚠️  Кворум недостижим (доступно: $((sentinel_count + 1)), требуется: $sentinels_required)${NC}"
                    echo -e "    ${RED}  Причина: недостаточно сентинелов для принятия решений${NC}"
                fi
            fi
        fi
    fi
    
    # 4. Текущий мастер
    echo -e "\n${PURPLE}${BOLD}4. Текущий мастер:${NC}"
    if [ -n "$master_name" ]; then
        local current_master
        if [ -n "$REDIS_PASSWORD" ]; then
            current_master=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -a '$REDIS_PASSWORD' -p 26379 sentinel get-master-addr-by-name $master_name 2>&1" 2>/dev/null || echo "ERROR")
            current_master=$(echo "$current_master" | grep -v "Warning: Using a password")
        else
            current_master=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -p 26379 sentinel get-master-addr-by-name $master_name 2>&1" 2>/dev/null || echo "ERROR")
        fi
        
        if [[ "$current_master" != *"ERROR"* ]]; then
            local master_ip=$(echo "$current_master" | head -1)
            local master_port=$(echo "$current_master" | tail -1)
            local master_pod=$(get_pod_name_by_ip "$master_ip")
            echo -e "${GREEN}✓ $master_ip:$master_port (под: $master_pod)${NC}"
        else
            echo -e "${RED}✗ Не удалось определить текущего мастера${NC}"
        fi
    fi
    
    # 5. Общая статистика Sentinel
    echo -e "\n${PURPLE}${BOLD}5. Статистика Sentinel:${NC}"
    local sentinel_info
    if [ -n "$REDIS_PASSWORD" ]; then
        sentinel_info=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -a '$REDIS_PASSWORD' -p 26379 info sentinel 2>&1" 2>/dev/null || echo "ERROR")
        sentinel_info=$(echo "$sentinel_info" | grep -v "Warning: Using a password")
    else
        sentinel_info=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -p 26379 info sentinel 2>&1" 2>/dev/null || echo "ERROR")
    fi
    
    echo "$sentinel_info" | while read line; do
        if [[ "$line" == *":"* ]]; then
            echo -e "  ${CYAN}$line${NC}"
        fi
    done
    
    # 6. Проверка всех сентинелов в кластере
    check_all_sentinels

    check_sentinel_info_consistency
    
    # 7. Проверка конфигурации бутстрапа
    check_bootstrap_config
    
    # Если мастеров не найдено, проводим диагностику
    if [ -z "$master_name" ] || [ -z "$master_count" ] || [ "$master_count" -eq 0 ]; then
        diagnose_sentinel_issues
    fi
}

# Если пароль не передан как аргумент, получаем его из секрета
if [ -z "$REDIS_PASSWORD" ]; then
    echo -e "${CYAN}Пароль не указан, получение из секрета...${NC}"
    REDIS_PASSWORD=$(get_password_from_secret)
    if [ $? -ne 0 ]; then
        echo -e "${YELLOW}Продолжаем без пароля...${NC}"
    else
        echo -e "${GREEN}Пароль успешно получен из секрета${NC}"
    fi
else
    echo -e "${GREEN}Используется пароль из аргументов${NC}"
fi

echo -e "${BLUE}${BOLD}==============================================${NC}"
echo -e "${BLUE}${BOLD}Проверка Redis кластера и Sentinel${NC}"
echo -e "${BLUE}${BOLD}==============================================${NC}"
echo -e "${CYAN}Pod: $POD_NAME${NC}"
echo -e "${CYAN}Namespace: $NAMESPACE${NC}"
echo -e "${CYAN}Type: $POD_TYPE${NC}"
echo -e "${CYAN}Cluster: $CLUSTER_ID${NC}"
echo -e "${BLUE}${BOLD}==============================================${NC}"

# Проверяем доступность пода
echo -e "${CYAN}Проверка доступности пода...${NC}"
pod_info=$(kubectl get pod -n $NAMESPACE $POD_NAME 2>/dev/null | grep "$POD_NAME" || true)
if [ -n "$pod_info" ]; then
    echo -e "${GREEN}Под доступен${NC}"
    echo -e "${CYAN}Статус: $(echo "$pod_info" | awk '{print $3}')${NC}"
else
    echo -e "${RED}Под не найден или недоступен${NC}"
    exit 1
fi

# Проверяем подключение к Redis/Sentinel
if ! check_connection; then
    echo -e "${RED}Не удалось установить подключение. Проверьте параметры и повторите попытку.${NC}"
    exit 1
fi

# Поиск связанных ConfigMaps
echo -e "\n${CYAN}Поиск связанных ConfigMaps...${NC}"
find_configmaps

# Выполняем проверки в зависимости от типа пода
if [ "$POD_TYPE" = "redis" ]; then
    check_redis
else
    check_sentinel
fi

# Вывод логов
show_pod_logs

echo -e "\n${BLUE}${BOLD}==============================================${NC}"
echo -e "${GREEN}${BOLD}Проверка завершена${NC}"
echo -e "${BLUE}${BOLD}==============================================${NC}"

# Дополнительные команды для мониторинга
echo -e "\n${CYAN}${BOLD}Дополнительные команды для мониторинга:${NC}"

if [ "$POD_TYPE" = "redis" ]; then
    echo -e "${YELLOW}Для Redis (порт 6379):${NC}"
    echo -e "  ${CYAN}kubectl exec -n $NAMESPACE $POD_NAME -- redis-cli info replication${NC}"
    echo -e "  ${CYAN}kubectl exec -n $NAMESPACE $POD_NAME -- redis-cli info memory${NC}"
    echo -e "  ${CYAN}kubectl exec -n $NAMESPACE $POD_NAME -- redis-cli info stats${NC}"
    echo -e "  ${CYAN}kubectl exec -n $NAMESPACE $POD_NAME -- redis-cli info persistence${NC}"
    echo -e "  ${CYAN}kubectl exec -n $NAMESPACE $POD_NAME -- redis-cli cluster info${NC}"
    echo -e "  ${CYAN}kubectl exec -n $NAMESPACE $POD_NAME -- redis-cli client list${NC}"
    
    # Ищем сентинелы для этого кластера
    local sentinel_pods=($(kubectl get pods -n $NAMESPACE --no-headers -o custom-columns=":metadata.name" | grep "rfs-" | grep "$CLUSTER_ID" || true))
    if [ ${#sentinel_pods[@]} -gt 0 ]; then
        echo -e "${YELLOW}Для Sentinel (используйте один из подов):${NC}"
        for sentinel_pod in "${sentinel_pods[@]:0:3}"; do  # Показываем первые 3
            echo -e "  ${CYAN}kubectl exec -n $NAMESPACE $sentinel_pod -- redis-cli -p 26379 sentinel masters${NC}"
            echo -e "  ${CYAN}kubectl exec -n $NAMESPACE $sentinel_pod -- redis-cli -p 26379 info sentinel${NC}"
            echo -e "  ${CYAN}kubectl exec -n $NAMESPACE $sentinel_pod -- redis-cli -p 26379 sentinel ckquorum mymaster${NC}"
        done
        if [ ${#sentinel_pods[@]} -gt 3 ]; then
            echo -e "  ${CYAN}... и еще $(( ${#sentinel_pods[@]} - 3 )) сентинелов${NC}"
        fi
    fi
else
    # Для сентинела
    echo -e "${YELLOW}Для Sentinel (порт 26379):${NC}"
    echo -e "  ${CYAN}kubectl exec -n $NAMESPACE $POD_NAME -- redis-cli -p 26379 info sentinel${NC}"
    echo -e "  ${CYAN}kubectl exec -n $NAMESPACE $POD_NAME -- redis-cli -p 26379 sentinel masters${NC}"
    echo -e "  ${CYAN}kubectl exec -n $NAMESPACE $POD_NAME -- redis-cli -p 26379 sentinel ckquorum mymaster${NC}"
    echo -e "  ${CYAN}kubectl exec -n $NAMESPACE $POD_NAME -- redis-cli -p 26379 sentinel slaves mymaster${NC}"
    echo -e "  ${CYAN}kubectl exec -n $NAMESPACE $POD_NAME -- redis-cli -p 26379 sentinel sentinels mymaster${NC}"
    
    # Показываем также Redis поды
    echo -e "${YELLOW}Для Redis (используйте один из подов):${NC}"
    local redis_pods=($(kubectl get pods -n $NAMESPACE --no-headers -o custom-columns=":metadata.name" | grep "rfr-" | grep "$CLUSTER_ID" || true))
    for redis_pod in "${redis_pods[@]:0:3}"; do  # Показываем первые 3
        echo -e "  ${CYAN}kubectl exec -n $NAMESPACE $redis_pod -- redis-cli info replication${NC}"
        echo -e "  ${CYAN}kubectl exec -n $NAMESPACE $redis_pod -- redis-cli info memory${NC}"
        echo -e "  ${CYAN}kubectl exec -n $NAMESPACE $redis_pod -- redis-cli info server${NC}"
    done
    if [ ${#redis_pods[@]} -gt 3 ]; then
        echo -e "  ${CYAN}... и еще $(( ${#redis_pods[@]} - 3 )) Redis подов${NC}"
    fi
fi

echo -e "${YELLOW}Общие команды:${NC}"
echo -e "  ${CYAN}kubectl get pods -n $NAMESPACE | grep -E 'rfr-|rfs-' | grep '$CLUSTER_ID'${NC}"
echo -e "  ${CYAN}kubectl get configmaps -n $NAMESPACE | grep -E 'redis|sentinel' | grep '$CLUSTER_ID'${NC}"
echo -e "  ${CYAN}kubectl get secrets -n $NAMESPACE | grep -E 'redis|sentinel' | grep '$CLUSTER_ID'${NC}"
echo -e "  ${CYAN}kubectl logs -n $NAMESPACE $POD_NAME -f${NC}"
echo -e "  ${CYAN}kubectl top pod -n $NAMESPACE $POD_NAME 2>/dev/null || echo 'Метрики не доступны'${NC}"
echo -e "  ${CYAN}kubectl describe pod -n $NAMESPACE $POD_NAME | grep -A 5 'Containers:'${NC}"