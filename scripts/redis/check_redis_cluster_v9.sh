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
    SENTINEL_PORT=26379
elif [[ "$POD_NAME" == rfs-* ]]; then
    POD_TYPE="sentinel"
    DEFAULT_PORT=26379
    REDIS_PORT=6379
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

# Функция для извлечения идентификатора кластера и базового имени пода
get_cluster_info() {
    local pod_name="$1"
    
    # Разбиваем имя пода на части по дефисам
    # Формат: rfr-<service>-<environment>-redis-<index>
    #         rfs-<service>-<environment>-redis-<index>
    # Пример: rfr-pickup-main-redis-0 -> pickup-main
    #         rfs-pickup-stage2-redis-68bc8fc5c9-q26cv -> pickup-stage2
    
    # Удаляем префикс rfr- или rfs-
    local without_prefix="${pod_name#rfr-}"
    without_prefix="${without_prefix#rfs-}"
    
    # Удаляем суффикс -redis-* 
    local cluster_id=$(echo "$without_prefix" | sed 's/-redis-.*//')
    
    # Получаем базовое имя пода (без индекса)
    local base_pod_name=$(echo "$pod_name" | sed 's/-[0-9]\+$//')
    
    # Если после обработки осталась пустая строка, используем "default"
    if [ -z "$cluster_id" ]; then
        cluster_id="default"
    fi
    
    echo "$cluster_id,$base_pod_name"
}

# Получаем идентификатор кластера и базовое имя
CLUSTER_INFO=$(get_cluster_info "$POD_NAME")
CLUSTER_ID=$(echo "$CLUSTER_INFO" | cut -d',' -f1)
BASE_POD_NAME=$(echo "$CLUSTER_INFO" | cut -d',' -f2)

echo -e "${CYAN}Идентифицирован кластер: $CLUSTER_ID${NC}"
echo -e "${CYAN}Базовое имя пода: $BASE_POD_NAME${NC}"

# Функция для поиска всех Redis подов в кластере по шаблону
find_all_redis_pods() {
    echo -e "${CYAN}Поиск Redis подов по шаблону: ${BASE_POD_NAME}-*${NC}"
    
    # Получаем все поды Redis в неймспейсе по шаблону
    local all_redis_pods=($(kubectl get pods -n $NAMESPACE --no-headers -o custom-columns=":metadata.name" | grep "${BASE_POD_NAME}-" || true))
    
    if [ ${#all_redis_pods[@]} -eq 0 ]; then
        # Если не нашли по шаблону, попробуем найти любой Redis под с тем же кластером
        echo -e "${YELLOW}Не найдено Redis подов по шаблону ${BASE_POD_NAME}-*, используем расширенный поиск${NC}"
        all_redis_pods=($(kubectl get pods -n $NAMESPACE --no-headers -o custom-columns=":metadata.name" | grep "rfr-.*$CLUSTER_ID" || true))
    fi
    
    echo "${all_redis_pods[@]}"
}

# Функция для поиска всех Sentinel подов в кластере по шаблону
find_all_sentinels() {
    echo -e "${CYAN}Поиск Sentinel подов по шаблону: rfs-${CLUSTER_ID}-redis-*${NC}"
    
    # Для Sentinel используем другой шаблон - заменяем rfr- на rfs-
    local sentinel_base_name="rfs-${CLUSTER_ID}-redis"
    local all_sentinel_pods=($(kubectl get pods -n $NAMESPACE --no-headers -o custom-columns=":metadata.name" | grep "$sentinel_base_name" || true))
    
    if [ ${#all_sentinel_pods[@]} -eq 0 ]; then
        echo -e "${YELLOW}Не найдено Sentinel подов по шаблону $sentinel_base_name, используем расширенный поиск${NC}"
        all_sentinel_pods=($(kubectl get pods -n $NAMESPACE --no-headers -o custom-columns=":metadata.name" | grep "rfs-.*$CLUSTER_ID" || true))
    fi
    
    echo "${all_sentinel_pods[@]}"
}

# Функция для получения информации о всех Redis нодах в кластере
get_all_redis_nodes_info() {
    echo -e "\n${PURPLE}${BOLD}1.1. Все Redis ноды в кластере $CLUSTER_ID:${NC}"
    
    local redis_pods=($(find_all_redis_pods))
    
    if [ ${#redis_pods[@]} -eq 0 ]; then
        echo -e "${YELLOW}Redis поды не найдены в кластере $CLUSTER_ID${NC}"
        return 1
    fi
    
    echo -e "${CYAN}Найдено Redis подов: ${#redis_pods[@]}${NC}"
    
    for redis_pod in "${redis_pods[@]}"; do
        echo -e "\n${CYAN}Redis: $redis_pod${NC}"
        
        # Получаем IP адрес
        local redis_ip=$(get_pod_ip "$redis_pod")
        echo -e "  ${YELLOW}IP: $redis_ip${NC}"
        
        # Проверяем статус пода
        local pod_status=$(kubectl get pod -n $NAMESPACE $redis_pod -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        echo -e "  ${YELLOW}Статус: $pod_status${NC}"
        
        if [ "$pod_status" = "Running" ]; then
            # Получаем информацию о репликации
            local replication_info=$(exec_cmd_on_pod "$redis_pod" "info replication" "6379")
            local role=$(echo "$replication_info" | grep "role:" | cut -d: -f2 | tr -d '\r' | head -1)
            echo -e "  ${GREEN}Роль: $role${NC}"
            
            if [ "$role" = "master" ]; then
                local connected_slaves=$(echo "$replication_info" | grep "connected_slaves:" | cut -d: -f2 | tr -d '\r')
                echo -e "  ${CYAN}Подключенных реплик: $connected_slaves${NC}"
                
                # Получаем смещение репликации
                local master_repl_offset=$(echo "$replication_info" | grep "master_repl_offset:" | cut -d: -f2 | tr -d '\r')
                echo -e "  ${CYAN}Смещение репликации: $master_repl_offset${NC}"
                
            elif [ "$role" = "slave" ]; then
                local master_host=$(echo "$replication_info" | grep "master_host:" | cut -d: -f2 | tr -d '\r' | head -1)
                local master_port=$(echo "$replication_info" | grep "master_port:" | cut -d: -f2 | tr -d '\r' | head -1)
                local master_link_status=$(echo "$replication_info" | grep "master_link_status:" | cut -d: -f2 | tr -d '\r' | head -1)
                local slave_repl_offset=$(echo "$replication_info" | grep "slave_repl_offset:" | cut -d: -f2 | tr -d '\r')
                
                echo -e "  ${CYAN}Мастер: $master_host:$master_port${NC}"
                echo -e "  ${CYAN}Статус подключения: $master_link_status${NC}"
                echo -e "  ${CYAN}Смещение репликации: $slave_repl_offset${NC}"
                
                # Определяем имя пода мастера
                local master_pod=$(get_pod_name_by_ip "$master_host" "$master_port")
                echo -e "  ${CYAN}Под мастера: $master_pod${NC}"
            fi
            
            # Получаем информацию о памяти
            local memory_info=$(exec_cmd_on_pod "$redis_pod" "info memory" "6379")
            local used_memory_human=$(echo "$memory_info" | grep "used_memory_human:" | cut -d: -f2 | tr -d '\r')
            echo -e "  ${CYAN}Использовано памяти: $used_memory_human${NC}"
            
            # Получаем информацию о клиентах
            local clients_info=$(exec_cmd_on_pod "$redis_pod" "info clients" "6379")
            local connected_clients=$(echo "$clients_info" | grep "connected_clients:" | cut -d: -f2 | tr -d '\r')
            echo -e "  ${CYAN}Подключенных клиентов: $connected_clients${NC}"
        else
            echo -e "  ${RED}Под не в состоянии Running, детальная информация недоступна${NC}"
        fi
    done
}

# Остальные функции остаются без изменений (get_password_from_secret, exec_redis_cmd, exec_sentinel_cmd, check_connection, и т.д.)
# ... [здесь должны быть все остальные функции из предыдущего скрипта]

# Функция для получения пароля из секрета
get_password_from_secret() {
    # ... [реализация функции get_password_from_secret]
}

# Функция для выполнения команд в Redis
exec_redis_cmd() {
    local cmd="$1"
    local port="${2:-6379}"
    
    local result
    if [ -n "$REDIS_PASSWORD" ]; then
        result=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -a '$REDIS_PASSWORD' -p $port $cmd 2>&1" 2>/dev/null || echo "ERROR")
        # Убираем предупреждение о пароле
        result=$(echo "$result" | grep -v "Warning: Using a password")
    else
        result=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -p $port $cmd 2>&1" 2>/dev/null || echo "ERROR")
    fi
    
    echo "$result"
}

# Функция для выполнения команд в Sentinel
exec_sentinel_cmd() {
    local cmd="$1"
    
    local result
    if [ -n "$REDIS_PASSWORD" ]; then
        result=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -a '$REDIS_PASSWORD' -p 26379 $cmd 2>&1" 2>/dev/null || echo "ERROR")
        # Убираем предупреждение о пароле
        result=$(echo "$result" | grep -v "Warning: Using a password")
    else
        result=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "redis-cli -p 26379 $cmd 2>&1" 2>/dev/null || echo "ERROR")
    fi
    
    echo "$result"
}

# Функция для выполнения команд на конкретном поде
exec_cmd_on_pod() {
    local pod="$1"
    local cmd="$2"
    local port="${3:-$DEFAULT_PORT}"
    
    local result
    if [ -n "$REDIS_PASSWORD" ]; then
        result=$(kubectl exec -n $NAMESPACE $pod -- sh -c "redis-cli -a '$REDIS_PASSWORD' -p $port $cmd 2>&1" 2>/dev/null || echo "ERROR")
        result=$(echo "$result" | grep -v "Warning: Using a password")
    else
        result=$(kubectl exec -n $NAMESPACE $pod -- sh -c "redis-cli -p $port $cmd 2>&1" 2>/dev/null || echo "ERROR")
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
    
    if [ "$POD_TYPE" = "redis" ]; then
        local response=$(exec_redis_cmd "ping")
        if [[ "$response" == *"PONG"* ]] || [[ "$response" == *"pong"* ]]; then
            echo -e "${GREEN}✓ Подключение к Redis успешно${NC}"
            return 0
        elif [[ "$response" == *"WRONGPASS"* ]]; then
            echo -e "${RED}✗ Ошибка аутентификации: неверный пароль${NC}"
            return 1
        else
            echo -e "${RED}✗ Не удалось подключиться к Redis${NC}"
            echo -e "${YELLOW}Ответ: $response${NC}"
            return 1
        fi
    else
        local response=$(exec_sentinel_cmd "ping")
        if [[ "$response" == *"PONG"* ]] || [[ "$response" == *"pong"* ]]; then
            echo -e "${GREEN}✓ Подключение к Sentinel успешно${NC}"
            return 0
        elif [[ "$response" == *"WRONGPASS"* ]]; then
            echo -e "${RED}✗ Ошибка аутентификации: неверный пароль${NC}"
            return 1
        else
            echo -e "${RED}✗ Не удалось подключиться к Sentinel${NC}"
            echo -e "${YELLOW}Ответ: $response${NC}"
            return 1
        fi
    fi
}

# Функция для получения имени пода по IP
get_pod_name_by_ip() {
    local ip="$1"
    local port="$2"
    
    # Получаем все поды в неймспейсе
    local all_pods=($(kubectl get pods -n $NAMESPACE --no-headers -o custom-columns=":metadata.name" 2>/dev/null))
    
    for pod in "${all_pods[@]}"; do
        # Получаем IP пода
        local pod_ip=$(kubectl get pod -n $NAMESPACE $pod -o jsonpath='{.status.podIP}' 2>/dev/null)
        if [ "$pod_ip" = "$ip" ]; then
            echo "$pod"
            return 0
        fi
    done
    
    echo "неизвестный под ($ip)"
}

# Функция для получения IP адреса пода
get_pod_ip() {
    local pod="$1"
    kubectl get pod -n $NAMESPACE $pod -o jsonpath='{.status.podIP}' 2>/dev/null || echo "неизвестный IP"
}

# Функция для проверки Redis
check_redis() {
    echo -e "${GREEN}${BOLD}=== КРИТИЧЕСКИЕ ПАРАМЕТРЫ REDIS ===${NC}"
    
    # 1. Состав кластера и репликация
    echo -e "\n${PURPLE}${BOLD}1. Состав кластера и репликация:${NC}"
    
    local role=$(exec_redis_cmd "info replication" | grep "role:" | cut -d: -f2 | tr -d '\r' | head -1)
    if [ "$role" = "master" ]; then
        echo -e "${GREEN}✓ Роль: MASTER${NC}"
        
        local connected_slaves=$(exec_redis_cmd "info replication" | grep "connected_slaves:" | cut -d: -f2 | tr -d '\r')
        echo -e "${CYAN}  Подключенных реплик: $connected_slaves${NC}"
        
    elif [ "$role" = "slave" ]; then
        echo -e "${CYAN}✓ Роль: REPLICA${NC}"
        
        local master_host=$(exec_redis_cmd "info replication" | grep "master_host:" | cut -d: -f2 | tr -d '\r' | head -1)
        local master_port=$(exec_redis_cmd "info replication" | grep "master_port:" | cut -d: -f2 | tr -d '\r' | head -1)
        local master_link_status=$(exec_redis_cmd "info replication" | grep "master_link_status:" | cut -d: -f2 | tr -d '\r' | head -1)
        
        # Определяем имя пода мастера
        local master_pod_name=$(get_pod_name_by_ip "$master_host" "$master_port")
        
        echo -e "${CYAN}  Мастер: $master_host:$master_port (под: $master_pod_name)${NC}"
        if [ "$master_link_status" = "up" ]; then
            echo -e "${GREEN}  Статус подключения к мастеру: $master_link_status${NC}"
        else
            echo -e "${RED}  Статус подключения к мастеру: $master_link_status${NC}"
        fi
    else
        echo -e "${YELLOW}Роль: $role${NC}"
    fi
    
    # 1.1. Все Redis ноды в кластере (новый пункт)
    get_all_redis_nodes_info
    
    # ... [остальная часть функции check_redis]
}

# Основная логика скрипта
# ... [остальная часть скрипта]

# Если пароль не передан как аргумент, получаем его из секрета
if [ -z "$REDIS_PASSWORD" ]; then
    echo -e "${CYAN}Пароль не указан, получение из секрета...${NC}"
    REDIS_PASSWORD=$(get_password_from_secret)
    if [ $? -ne 0 ]; then
        echo -e "${YELLOW}Продолжаем без пароля...${NC}"
        REDIS_PASSWORD=""
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
echo -e "${CYAN}Базовое имя: $BASE_POD_NAME${NC}"
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

# Получаем списки подов для использования в командах
REDIS_PODS=($(find_all_redis_pods))
SENTINEL_PODS=($(find_all_sentinels))

# Дополнительные команды для мониторинга
echo -e "\n${CYAN}${BOLD}Дополнительные команды для мониторинга:${NC}"

if [ "$POD_TYPE" = "redis" ]; then
    # Команды для Redis пода
    echo -e "${YELLOW}Команды для Redis (выполнять на Redis подах):${NC}"
    
    # Используем первый Redis под из списка
    local first_redis_pod=""
    if [ ${#REDIS_PODS[@]} -gt 0 ]; then
        first_redis_pod="${REDIS_PODS[0]}"
    else
        first_redis_pod="$POD_NAME"
    fi
    
    echo -e "  ${CYAN}Быстрая проверка всех Redis:${NC}"
    echo -e "    kubectl get pods -n $NAMESPACE | grep '${BASE_POD_NAME}-'"
    
    echo -e "  ${CYAN}Проверить информацию о Redis:${NC}"
    echo -e "    kubectl exec -n $NAMESPACE $first_redis_pod -- redis-cli -p 6379 info"
    
    echo -e "  ${CYAN}Проверить репликацию:${NC}"
    echo -e "    kubectl exec -n $NAMESPACE $first_redis_pod -- redis-cli -p 6379 info replication"
    
    echo -e "  ${CYAN}Проверить память:${NC}"
    echo -e "    kubectl exec -n $NAMESPACE $first_redis_pod -- redis-cli -p 6379 info memory"
    
    echo -e "  ${CYAN}Просмотр логов Redis:${NC}"
    echo -e "    kubectl logs -n $NAMESPACE $first_redis_pod -f"
    
    # Команды для Sentinel (отдельный блок)
    echo -e "\n${YELLOW}Команды для Sentinel (выполнять на Sentinel подах):${NC}"
    
    # Используем первый Sentinel под из списка
    local first_sentinel_pod=""
    if [ ${#SENTINEL_PODS[@]} -gt 0 ]; then
        first_sentinel_pod="${SENTINEL_PODS[0]}"
        echo -e "  ${CYAN}Быстрая проверка всех сентинелов:${NC}"
        echo -e "    kubectl get pods -n $NAMESPACE | grep 'rfs-${CLUSTER_ID}-redis-'"
        
        echo -e "  ${CYAN}Проверить информацию о сентинеле:${NC}"
        echo -e "    kubectl exec -n $NAMESPACE $first_sentinel_pod -- redis-cli -p 26379 info sentinel"
        
        echo -e "  ${CYAN}Проверить мастера:${NC}"
        echo -e "    kubectl exec -n $NAMESPACE $first_sentinel_pod -- redis-cli -p 26379 sentinel masters"
        
        echo -e "  ${CYAN}Проверить кворум:${NC}"
        echo -e "    kubectl exec -n $NAMESPACE $first_sentinel_pod -- redis-cli -p 26379 sentinel ckquorum mymaster"
        
        echo -e "  ${CYAN}Проверить все сентинелы:${NC}"
        echo -e "    kubectl exec -n $NAMESPACE $first_sentinel_pod -- redis-cli -p 26379 sentinel sentinels mymaster"
        
        echo -e "  ${CYAN}Проверить реплики:${NC}"
        echo -e "    kubectl exec -n $NAMESPACE $first_sentinel_pod -- redis-cli -p 26379 sentinel slaves mymaster"
        
        echo -e "  ${CYAN}Просмотр логов Sentinel:${NC}"
        echo -e "    kubectl logs -n $NAMESPACE $first_sentinel_pod -f"
    else
        echo -e "  ${YELLOW}Sentinel поды не найдены${NC}"
    fi

else
    # Команды для Sentinel пода
    echo -e "${YELLOW}Команды для Sentinel (выполнять на Sentinel подах):${NC}"
    
    echo -e "  ${CYAN}Быстрая проверка всех сентинелов:${NC}"
    echo -e "    kubectl get pods -n $NAMESPACE | grep 'rfs-${CLUSTER_ID}-redis-'"
    
    echo -e "  ${CYAN}Проверить информацию о сентинеле:${NC}"
    echo -e "    kubectl exec -n $NAMESPACE $POD_NAME -- redis-cli -p 26379 info sentinel"
    
    echo -e "  ${CYAN}Проверить мастера:${NC}"
    echo -e "    kubectl exec -n $NAMESPACE $POD_NAME -- redis-cli -p 26379 sentinel masters"
    
    echo -e "  ${CYAN}Проверить кворум:${NC}"
    echo -e "    kubectl exec -n $NAMESPACE $POD_NAME -- redis-cli -p 26379 sentinel ckquorum mymaster"
    
    echo -e "  ${CYAN}Проверить все сентинелы:${NC}"
    echo -e "    kubectl exec -n $NAMESPACE $POD_NAME -- redis-cli -p 26379 sentinel sentinels mymaster"
    
    echo -e "  ${CYAN}Проверить реплики:${NC}"
    echo -e "    kubectl exec -n $NAMESPACE $POD_NAME -- redis-cli -p 26379 sentinel slaves mymaster"
    
    echo -e "  ${CYAN}Просмотр логов Sentinel:${NC}"
    echo -e "    kubectl logs -n $NAMESPACE $POD_NAME -f"
    
    # Команды для Redis (отдельный блок)
    echo -e "\n${YELLOW}Команды для Redis (выполнять на Redis подах):${NC}"
    
    # Используем первый Redis под из списка
    local first_redis_pod=""
    if [ ${#REDIS_PODS[@]} -gt 0 ]; then
        first_redis_pod="${REDIS_PODS[0]}"
        echo -e "  ${CYAN}Быстрая проверка всех Redis:${NC}"
        echo -e "    kubectl get pods -n $NAMESPACE | grep '${BASE_POD_NAME}-'"
        
        echo -e "  ${CYAN}Проверить информацию о Redis:${NC}"
        echo -e "    kubectl exec -n $NAMESPACE $first_redis_pod -- redis-cli -p 6379 info"
        
        echo -e "  ${CYAN}Проверить репликацию:${NC}"
        echo -e "    kubectl exec -n $NAMESPACE $first_redis_pod -- redis-cli -p 6379 info replication"
        
        echo -e "  ${CYAN}Проверить память:${NC}"
        echo -e "    kubectl exec -n $NAMESPACE $first_redis_pod -- redis-cli -p 6379 info memory"
        
        echo -e "  ${CYAN}Просмотр логов Redis:${NC}"
        echo -e "    kubectl logs -n $NAMESPACE $first_redis_pod -f"
    else
        echo -e "  ${YELLOW}Redis поды не найдены${NC}"
    fi
fi

# Общие команды
echo -e "\n${YELLOW}Общие команды:${NC}"
echo -e "  ${CYAN}Все поды Redis/Sentinel в кластере $CLUSTER_ID:${NC}"
echo -e "    kubectl get pods -n $NAMESPACE | grep -E '${BASE_POD_NAME}-|rfs-${CLUSTER_ID}-redis-'"

echo -e "  ${CYAN}Проверка ресурсов:${NC}"
echo -e "    kubectl top pod -n $NAMESPACE $POD_NAME 2>/dev/null || echo 'Метрики не доступны'"

echo -e "  ${CYAN}Получить все поды в неймспейсе:${NC}"
echo -e "    kubectl get pods -n $NAMESPACE"

# Вывод списков найденных подов
echo -e "\n${CYAN}${BOLD}Найденные поды в кластере $CLUSTER_ID:${NC}"
if [ ${#REDIS_PODS[@]} -gt 0 ]; then
    echo -e "${GREEN}Redis поды (${#REDIS_PODS[@]}):${NC}"
    for redis_pod in "${REDIS_PODS[@]}"; do
        echo -e "  - $redis_pod"
    done
fi

if [ ${#SENTINEL_PODS[@]} -gt 0 ]; then
    echo -e "${GREEN}Sentinel поды (${#SENTINEL_PODS[@]}):${NC}"
    for sentinel_pod in "${SENTINEL_PODS[@]}"; do
        echo -e "  - $sentinel_pod"
    done
fi