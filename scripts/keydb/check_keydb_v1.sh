#!/bin/bash

# Скрипт проверки статуса KeyDB кластера
# Использование: ./check_keydb_cluster.sh <pod_name> <namespace> [port] [password]

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
    echo -e "  ${YELLOW}pod_name: имя пода с постфиксом -keydb-sts-* (например: cdb-backend-main-keydb-keydb-sts-0)${NC}"
    echo -e "  ${YELLOW}port: опционально - если не указан, будет использован порт 6379${NC}"
    echo -e "  ${YELLOW}password: опционально - если не указан, будет получен из секрета${NC}"
    exit 1
fi

POD_NAME=$1
NAMESPACE=$2
PORT=$3
KEYDB_PASSWORD=$4

# Устанавливаем порт по умолчанию, если не указан
if [ -z "$PORT" ]; then
    PORT=6379
    echo -e "${YELLOW}Порт не указан, используется порт по умолчанию: $PORT${NC}"
fi

# Функция для извлечения идентификатора кластера и базового имени пода
get_cluster_info() {
    local pod_name="$1"
    
    # Разбиваем имя пода на части по дефисам
    # Формат: <project>-<branch>-keydb-keydb-sts-<index>
    # Пример: cdb-backend-main-keydb-keydb-sts-0
    #   project: cdb-backend
    #   branch: main
    #   index: 0
    
    # Извлекаем кластер ID (project-branch)
    local cluster_id=""
    
    # Удаляем постфикс -keydb-keydb-sts-*
    if [[ "$pod_name" =~ -keydb-sts-[0-9]+$ ]]; then
        # Получаем все до -keydb-sts-
        cluster_id=$(echo "$pod_name" | sed 's/-keydb-sts-[0-9]*$//')
        
        # Удаляем последнее -keydb если оно есть
        cluster_id=$(echo "$cluster_id" | sed 's/-keydb$//')
    else
        # Если формат не соответствует ожидаемому, используем имя без последней части
        cluster_id=$(echo "$pod_name" | rev | cut -d- -f2- | rev)
    fi
    
    # Получаем базовое имя пода (без индекса)
    local base_pod_name=""
    if [[ "$pod_name" =~ -[0-9]+$ ]]; then
        # Удаляем индекс в конце
        base_pod_name=$(echo "$pod_name" | sed 's/-[0-9]*$//')
    else
        base_pod_name="$pod_name"
    fi
    
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

# Извлекаем проект и ветку из имени пода
# Формат: <project>-<branch>-keydb-keydb-sts-<index>
if [[ "$POD_NAME" =~ ^([a-zA-Z0-9-]+)-([a-zA-Z0-9-]+)-keydb-keydb-sts-[0-9]+$ ]]; then
    PROJECT="${BASH_REMATCH[1]}"
    BRANCH="${BASH_REMATCH[2]}"
    SECRET_PREFIX="${PROJECT}-${BRANCH}-keydb"
else
    # Если не соответствует формату, используем CLUSTER_ID-keydb как префикс
    SECRET_PREFIX="${CLUSTER_ID}-keydb"
fi

echo -e "${CYAN}Идентифицирован кластер: $CLUSTER_ID${NC}"
echo -e "${CYAN}Базовое имя пода: $BASE_POD_NAME${NC}"
echo -e "${CYAN}Префикс для поиска секрета: $SECRET_PREFIX${NC}"

# Функция для поиска всех KeyDB подов в кластере по шаблону
find_all_keydb_pods() {
    echo -e "${CYAN}Поиск KeyDB подов по шаблону: ${BASE_POD_NAME}-*${NC}"
    
    # Получаем все поды KeyDB в неймспейсе по шаблону
    local all_keydb_pods=($(kubectl get pods -n $NAMESPACE --no-headers -o custom-columns=":metadata.name" | grep "${BASE_POD_NAME}-" || true))
    
    if [ ${#all_keydb_pods[@]} -eq 0 ]; then
        # Если не нашли по шаблону, попробуем найти по ключевому слову keydb-sts
        echo -e "${YELLOW}Не найдено KeyDB подов по шаблону ${BASE_POD_NAME}-*, используем расширенный поиск${NC}"
        all_keydb_pods=($(kubectl get pods -n $NAMESPACE --no-headers -o custom-columns=":metadata.name" | grep "keydb-sts" || true))
    fi
    
    echo "${all_keydb_pods[@]}"
}

# Функция для получения информации о всех KeyDB нодах в кластере
get_all_keydb_nodes_info() {
    echo -e "\n${PURPLE}${BOLD}1.1. Все KeyDB ноды в кластере $CLUSTER_ID:${NC}"
    
    local keydb_pods=($(find_all_keydb_pods))
    
    if [ ${#keydb_pods[@]} -eq 0 ]; then
        echo -e "${YELLOW}KeyDB поды не найдены в кластере $CLUSTER_ID${NC}"
        return 1
    fi
    
    echo -e "${CYAN}Найдено KeyDB подов: ${#keydb_pods[@]}${NC}"
    
    for keydb_pod in "${keydb_pods[@]}"; do
        echo -e "\n${CYAN}KeyDB: $keydb_pod${NC}"
        
        # Получаем IP адрес
        local keydb_ip=$(get_pod_ip "$keydb_pod")
        echo -e "  ${YELLOW}IP: $keydb_ip${NC}"
        
        # Проверяем статус пода
        local pod_status=$(kubectl get pod -n $NAMESPACE $keydb_pod -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        echo -e "  ${YELLOW}Статус: $pod_status${NC}"
        
        if [ "$pod_status" = "Running" ]; then
            # Получаем информацию о репликации
            local replication_info=$(exec_cmd_on_pod "$keydb_pod" "info replication" "6379")
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
            local memory_info=$(exec_cmd_on_pod "$keydb_pod" "info memory" "6379")
            local used_memory_human=$(echo "$memory_info" | grep "used_memory_human:" | cut -d: -f2 | tr -d '\r')
            echo -e "  ${CYAN}Использовано памяти: $used_memory_human${NC}"
            
            # Получаем информацию о клиентах
            local clients_info=$(exec_cmd_on_pod "$keydb_pod" "info clients" "6379")
            local connected_clients=$(echo "$clients_info" | grep "connected_clients:" | cut -d: -f2 | tr -d '\r')
            echo -e "  ${CYAN}Подключенных клиентов: $connected_clients${NC}"
        else
            echo -e "  ${RED}Под не в состоянии Running, детальная информация недоступна${NC}"
        fi
    done
}

# Функция для получения пароля из секрета с выбором
get_password_from_secret() {
    echo -e "${CYAN}Поиск секретов с префиксом: $SECRET_PREFIX${NC}"
    
    # Получаем все секреты, начинающиеся с префикса
    local secrets
    secrets=($(kubectl get secrets -n $NAMESPACE --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep "^${SECRET_PREFIX}" | sort || true))
    
    if [ ${#secrets[@]} -eq 0 ]; then
        echo -e "${YELLOW}Не найдено секретов с префиксом $SECRET_PREFIX${NC}"
        
        # Пробуем найти секреты, содержащие ключевые слова
        echo -e "${CYAN}Поиск секретов по ключевым словам...${NC}"
        secrets=($(kubectl get secrets -n $NAMESPACE --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep -E "(keydb|auth|password)" | sort || true))
    fi
    
    if [ ${#secrets[@]} -eq 0 ]; then
        echo -e "${YELLOW}Не найден ни один подходящий секрет${NC}"
        
        # Показываем все доступные секреты в неймспейсе
        echo -e "${CYAN}Все доступные секреты в namespace $NAMESPACE:${NC}"
        local all_secrets
        all_secrets=$(kubectl get secrets -n $NAMESPACE --no-headers -o custom-columns=":metadata.name" 2>/dev/null | sort || true)
        if [ -n "$all_secrets" ]; then
            echo "$all_secrets" | head -20
            if [ $(echo "$all_secrets" | wc -l) -gt 20 ]; then
                echo -e "${YELLOW}... и еще $(( $(echo "$all_secrets" | wc -l) - 20 ))${NC}"
            fi
        else
            echo -e "${RED}В неймспейсе $NAMESPACE нет секретов${NC}"
        fi
        
        # Предлагаем ввести пароль вручную
        echo -e "\n${YELLOW}Хотите ввести пароль вручную? (y/n):${NC}"
        read -r manual_choice
        if [[ "$manual_choice" =~ ^[Yy]$ ]]; then
            echo -e "${CYAN}Введите пароль для KeyDB:${NC}"
            read -r -s -p "Пароль: " manual_password
            echo
            if [ -n "$manual_password" ]; then
                echo "$manual_password"
                return 0
            else
                echo -e "${YELLOW}Пароль не введен. Продолжаем без пароля.${NC}"
                return 1
            fi
        else
            echo -e "${YELLOW}Продолжаем без пароля.${NC}"
            return 1
        fi
    fi
    
    # Выводим список найденных секретов
    echo -e "${GREEN}Найдено ${#secrets[@]} секретов:${NC}"
    for i in "${!secrets[@]}"; do
        echo -e "  $((i+1)). ${secrets[$i]}"
    done
    
    if [ ${#secrets[@]} -eq 1 ]; then
        # Если только один секрет, используем его
        local secret_name="${secrets[0]}"
        echo -e "${GREEN}Используем единственный найденный секрет: $secret_name${NC}"
    else
        # Если несколько секретов, предлагаем выбрать
        local choice
        echo -e "\n${YELLOW}Введите номер секрета (1-${#secrets[@]}) или 'q' для выхода:${NC}"
        while true; do
            read -r -p "Ваш выбор: " choice
            if [[ "$choice" == "q" ]]; then
                echo -e "${YELLOW}Отмена выбора секрета${NC}"
                
                # Предлагаем ввести пароль вручную
                echo -e "${YELLOW}Хотите ввести пароль вручную? (y/n):${NC}"
                read -r manual_choice
                if [[ "$manual_choice" =~ ^[Yy]$ ]]; then
                    echo -e "${CYAN}Введите пароль для KeyDB:${NC}"
                    read -r -s -p "Пароль: " manual_password
                    echo
                    if [ -n "$manual_password" ]; then
                        echo "$manual_password"
                        return 0
                    else
                        echo -e "${YELLOW}Пароль не введен. Продолжаем без пароля.${NC}"
                        return 1
                    fi
                else
                    echo -e "${YELLOW}Продолжаем без пароля.${NC}"
                    return 1
                fi
            elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#secrets[@]} ]; then
                local secret_name="${secrets[$((choice-1))]}"
                echo -e "${GREEN}Выбран секрет: $secret_name${NC}"
                break
            else
                echo -e "${RED}Неверный выбор. Попробуйте снова.${NC}"
            fi
        done
    fi
    
    # Пробуем получить пароль из разных возможных полей секрета
    echo -e "${CYAN}Извлечение пароля из секрета $secret_name...${NC}"
    
    # Показываем все ключи в секрете
    echo -e "${CYAN}Доступные ключи в секрете $secret_name:${NC}"
    local secret_keys
    secret_keys=$(kubectl get secret -n $NAMESPACE "$secret_name" -o json 2>/dev/null | grep -o '"data":{[^}]*}' | grep -o '"[^"]*":' | cut -d'"' -f2 || true)
    
    if [ -z "$secret_keys" ]; then
        echo -e "${YELLOW}Не удалось получить ключи из секрета $secret_name${NC}"
        return 1
    fi
    
    for key in $secret_keys; do
        echo -e "  - $key"
    done
    
    # Сначала пробуем keydb_password (как указано в задаче)
    local password
    password=$(kubectl get secret -n $NAMESPACE "$secret_name" -o jsonpath="{.data.keydb_password}" 2>/dev/null | base64 -d 2>/dev/null || true)
    
    if [ -n "$password" ]; then
        echo -e "${GREEN}Пароль найден в поле: keydb_password${NC}"
        echo "$password"
        return 0
    fi
    
    # Пробуем другие возможные ключи
    local password_keys=("password" "auth" "keydb-password" "auth-key" "KEYDB_PASSWORD" "KEYDB_PASS")
    
    for key in "${password_keys[@]}"; do
        password=$(kubectl get secret -n $NAMESPACE "$secret_name" -o jsonpath="{.data.$key}" 2>/dev/null | base64 -d 2>/dev/null || true)
        if [ -n "$password" ]; then
            echo -e "${GREEN}Пароль найден в поле: $key${NC}"
            echo "$password"
            return 0
        fi
    done
    
    # Пробуем получить любой первый непустой ключ
    local first_key
    first_key=$(echo "$secret_keys" | head -1)
    if [ -n "$first_key" ]; then
        password=$(kubectl get secret -n $NAMESPACE "$secret_name" -o jsonpath="{.data.$first_key}" 2>/dev/null | base64 -d 2>/dev/null || true)
        if [ -n "$password" ]; then
            echo -e "${YELLOW}Пароль найден в поле: $first_key (первый доступный ключ)${NC}"
            echo "$password"
            return 0
        fi
    fi
    
    echo -e "${YELLOW}Не удалось получить пароль из секрета $secret_name${NC}"
    
    # Предлагаем ввести пароль вручную
    echo -e "${YELLOW}Хотите ввести пароль вручную? (y/n):${NC}"
    read -r manual_choice
    if [[ "$manual_choice" =~ ^[Yy]$ ]]; then
        echo -e "${CYAN}Введите пароль для KeyDB:${NC}"
        read -r -s -p "Пароль: " manual_password
        echo
        if [ -n "$manual_password" ]; then
            echo "$manual_password"
            return 0
        else
            echo -e "${YELLOW}Пароль не введен. Продолжаем без пароля.${NC}"
            return 1
        fi
    else
        echo -e "${YELLOW}Продолжаем без пароля.${NC}"
        return 1
    fi
}

# Функция для выполнения команд в KeyDB
exec_keydb_cmd() {
    local cmd="$1"
    local port="${2:-6379}"
    
    local result
    if [ -n "$KEYDB_PASSWORD" ]; then
        # Пробуем разные способы аутентификации
        result=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "timeout 10 keydb-cli -a '$KEYDB_PASSWORD' -p $port $cmd 2>&1" 2>/dev/null || echo "ERROR")
        # Если не сработало, пробуем без пароля (если пароль пустой или не требуется)
        if [[ "$result" == *"ERROR"* ]] || [[ "$result" == *"WRONGPASS"* ]]; then
            result=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "timeout 10 keydb-cli -p $port $cmd 2>&1" 2>/dev/null || echo "ERROR")
        fi
    else
        result=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "timeout 10 keydb-cli -p $port $cmd 2>&1" 2>/dev/null || echo "ERROR")
    fi
    
    # Убираем предупреждение о пароле
    result=$(echo "$result" | grep -v "Warning: Using a password")
    
    echo "$result"
}

# Функция для выполнения команд на конкретном поде
exec_cmd_on_pod() {
    local pod="$1"
    local cmd="$2"
    local port="${3:-6379}"
    
    local result
    if [ -n "$KEYDB_PASSWORD" ]; then
        result=$(kubectl exec -n $NAMESPACE $pod -- sh -c "timeout 10 keydb-cli -a '$KEYDB_PASSWORD' -p $port $cmd 2>&1" 2>/dev/null || echo "ERROR")
        result=$(echo "$result" | grep -v "Warning: Using a password")
    else
        result=$(kubectl exec -n $NAMESPACE $pod -- sh -c "timeout 10 keydb-cli -p $port $cmd 2>&1" 2>/dev/null || echo "ERROR")
    fi
    
    echo "$result"
}

# Функция для проверки доступности KeyDB
check_connection() {
    echo -e "${CYAN}Проверка подключения к KeyDB...${NC}"
    
    # Сначала проверяем, что под существует
    if ! kubectl get pod -n $NAMESPACE $POD_NAME >/dev/null 2>&1; then
        echo -e "${RED}✗ Под $POD_NAME не найден в namespace $NAMESPACE${NC}"
        return 1
    fi
    
    # Проверяем статус пода
    local pod_status
    pod_status=$(kubectl get pod -n $NAMESPACE $POD_NAME -o jsonpath='{.status.phase}' 2>/dev/null)
    if [ "$pod_status" != "Running" ]; then
        echo -e "${RED}✗ Под не в состоянии Running. Текущий статус: $pod_status${NC}"
        return 1
    fi
    
    local response
    response=$(exec_keydb_cmd "ping")
    if [[ "$response" == *"PONG"* ]] || [[ "$response" == *"pong"* ]]; then
        echo -e "${GREEN}✓ Подключение к KeyDB успешно${NC}"
        return 0
    elif [[ "$response" == *"WRONGPASS"* ]]; then
        echo -e "${RED}✗ Ошибка аутентификации: неверный пароль${NC}"
        return 1
    elif [[ "$response" == *"NOAUTH"* ]]; then
        echo -e "${RED}✗ Требуется аутентификация${NC}"
        return 1
    elif [[ "$response" == *"ERROR"* ]]; then
        echo -e "${RED}✗ Ошибка выполнения команды${NC}"
        echo -e "${YELLOW}Ответ: $response${NC}"
        return 1
    elif [[ "$response" == *"Connection refused"* ]]; then
        echo -e "${RED}✗ Соединение отклонено. Проверьте, запущен ли KeyDB на порту $PORT${NC}"
        return 1
    else
        echo -e "${RED}✗ Не удалось подключиться к KeyDB${NC}"
        echo -e "${YELLOW}Ответ: $response${NC}"
        return 1
    fi
}

# Функция для получения имени пода по IP
get_pod_name_by_ip() {
    local ip="$1"
    local port="$2"
    
    # Получаем все поды в неймспейсе
    local all_pods
    all_pods=($(kubectl get pods -n $NAMESPACE --no-headers -o custom-columns=":metadata.name" 2>/dev/null))
    
    for pod in "${all_pods[@]}"; do
        # Получаем IP пода
        local pod_ip
        pod_ip=$(kubectl get pod -n $NAMESPACE $pod -o jsonpath='{.status.podIP}' 2>/dev/null)
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

# Функция для проверки KeyDB
check_keydb() {
    echo -e "${GREEN}${BOLD}=== КРИТИЧЕСКИЕ ПАРАМЕТРЫ KEYDB ===${NC}"
    
    # 1. Состав кластера и репликация
    echo -e "\n${PURPLE}${BOLD}1. Состав кластера и репликация:${NC}"
    
    local replication_info
    replication_info=$(exec_keydb_cmd "info replication")
    local role
    role=$(echo "$replication_info" | grep "role:" | cut -d: -f2 | tr -d '\r' | head -1)
    
    if [ -z "$role" ]; then
        echo -e "${RED}Не удалось получить информацию о репликации${NC}"
        echo -e "${YELLOW}Ответ: $replication_info${NC}"
        return 1
    fi
    
    if [ "$role" = "master" ]; then
        echo -e "${GREEN}✓ Роль: MASTER${NC}"
        
        local connected_slaves
        connected_slaves=$(echo "$replication_info" | grep "connected_slaves:" | cut -d: -f2 | tr -d '\r')
        echo -e "${CYAN}  Подключенных реплик: $connected_slaves${NC}"
        
    elif [ "$role" = "slave" ]; then
        echo -e "${CYAN}✓ Роль: REPLICA${NC}"
        
        local master_host
        master_host=$(echo "$replication_info" | grep "master_host:" | cut -d: -f2 | tr -d '\r' | head -1)
        local master_port
        master_port=$(echo "$replication_info" | grep "master_port:" | cut -d: -f2 | tr -d '\r' | head -1)
        local master_link_status
        master_link_status=$(echo "$replication_info" | grep "master_link_status:" | cut -d: -f2 | tr -d '\r' | head -1)
        
        # Определяем имя пода мастера
        local master_pod_name
        master_pod_name=$(get_pod_name_by_ip "$master_host" "$master_port")
        
        echo -e "${CYAN}  Мастер: $master_host:$master_port (под: $master_pod_name)${NC}"
        if [ "$master_link_status" = "up" ]; then
            echo -e "${GREEN}  Статус подключения к мастеру: $master_link_status${NC}"
        else
            echo -e "${RED}  Статус подключения к мастеру: $master_link_status${NC}"
        fi
    else
        echo -e "${YELLOW}Роль: $role${NC}"
    fi
    
    # 1.1. Все KeyDB ноды в кластере (новый пункт)
    get_all_keydb_nodes_info
    
    # 2. Ключевые метрики
    echo -e "\n${PURPLE}${BOLD}2. Ключевые метрики KeyDB:${NC}"
    
    # Использование памяти
    local memory_info
    memory_info=$(exec_keydb_cmd "info memory")
    local used_memory_human
    used_memory_human=$(echo "$memory_info" | grep "used_memory_human:" | cut -d: -f2 | tr -d '\r')
    local used_memory_peak_human
    used_memory_peak_human=$(echo "$memory_info" | grep "used_memory_peak_human:" | cut -d: -f2 | tr -d '\r')
    local mem_fragmentation_ratio
    mem_fragmentation_ratio=$(echo "$memory_info" | grep "mem_fragmentation_ratio:" | cut -d: -f2 | tr -d '\r')
    
    if [ -n "$used_memory_human" ]; then
        echo -e "${CYAN}Использовано памяти: $used_memory_human${NC}"
        echo -e "${CYAN}Пиковое использование памяти: $used_memory_peak_human${NC}"
        echo -e "${CYAN}Коэффициент фрагментации памяти: $mem_fragmentation_ratio${NC}"
    else
        echo -e "${YELLOW}Не удалось получить информацию о памяти${NC}"
    fi
    
    # Клиенты
    local clients_info
    clients_info=$(exec_keydb_cmd "info clients")
    local connected_clients
    connected_clients=$(echo "$clients_info" | grep "connected_clients:" | cut -d: -f2 | tr -d '\r')
    local blocked_clients
    blocked_clients=$(echo "$clients_info" | grep "blocked_clients:" | cut -d: -f2 | tr -d '\r')
    
    if [ -n "$connected_clients" ]; then
        echo -e "${CYAN}Подключенных клиентов: $connected_clients${NC}"
        echo -e "${CYAN}Заблокированных клиентов: $blocked_clients${NC}"
    fi
    
    # Статистика
    local stats_info
    stats_info=$(exec_keydb_cmd "info stats")
    local total_connections_received
    total_connections_received=$(echo "$stats_info" | grep "total_connections_received:" | cut -d: -f2 | tr -d '\r')
    local total_commands_processed
    total_commands_processed=$(echo "$stats_info" | grep "total_commands_processed:" | cut -d: -f2 | tr -d '\r')
    local instantaneous_ops_per_sec
    instantaneous_ops_per_sec=$(echo "$stats_info" | grep "instantaneous_ops_per_sec:" | cut -d: -f2 | tr -d '\r')
    
    if [ -n "$total_commands_processed" ]; then
        echo -e "${CYAN}Всего подключений: $total_connections_received${NC}"
        echo -e "${CYAN}Всего команд обработано: $total_commands_processed${NC}"
        echo -e "${CYAN}Операций в секунду: $instantaneous_ops_per_sec${NC}"
    fi
    
    # 3. Проверка производительности
    echo -e "\n${PURPLE}${BOLD}3. Проверка производительности:${NC}"
    
    echo -e "${CYAN}Тест PING:${NC}"
    local start_time
    start_time=$(date +%s%3N)
    local ping_result
    ping_result=$(exec_keydb_cmd "ping")
    local end_time
    end_time=$(date +%s%3N)
    local ping_time
    ping_time=$((end_time - start_time))
    
    if [[ "$ping_result" == *"PONG"* ]] || [[ "$ping_result" == *"pong"* ]]; then
        echo -e "${GREEN}  ✓ PING успешен за ${ping_time} мс${NC}"
    else
        echo -e "${RED}  ✗ PING не удался: $ping_result${NC}"
    fi
    
    # 4. Проверка репликации (для реплик)
    if [ "$role" = "slave" ]; then
        echo -e "\n${PURPLE}${BOLD}4. Проверка репликации:${NC}"
        
        local master_sync_in_progress
        master_sync_in_progress=$(echo "$replication_info" | grep "master_sync_in_progress:" | cut -d: -f2 | tr -d '\r')
        local slave_repl_offset
        slave_repl_offset=$(echo "$replication_info" | grep "slave_repl_offset:" | cut -d: -f2 | tr -d '\r')
        
        echo -e "${CYAN}Синхронизация с мастером: $master_sync_in_progress${NC}"
        echo -e "${CYAN}Смещение репликации: $slave_repl_offset${NC}"
    fi
}

# Функция для показа логов пода
show_pod_logs() {
    echo -e "\n${PURPLE}${BOLD}Логи пода $POD_NAME:${NC}"
    
    # Получаем последние 10 строк логов
    local logs
    logs=$(kubectl logs -n $NAMESPACE $POD_NAME --tail=10 2>/dev/null || true)
    
    if [ -n "$logs" ]; then
        echo -e "${CYAN}Последние 10 строк логов:${NC}"
        echo "$logs"
    else
        echo -e "${YELLOW}Не удалось получить логи или логи пусты${NC}"
    fi
}

# Если пароль не передан как аргумент, получаем его из секрета
if [ -z "$KEYDB_PASSWORD" ]; then
    echo -e "${CYAN}Пароль не указан, получение из секрета...${NC}"
    KEYDB_PASSWORD=$(get_password_from_secret)
    if [ $? -ne 0 ]; then
        echo -e "${YELLOW}Продолжаем без пароля...${NC}"
        KEYDB_PASSWORD=""
    else
        echo -e "${GREEN}Пароль успешно получен из секрета${NC}"
    fi
else
    echo -e "${GREEN}Используется пароль из аргументов${NC}"
fi

echo -e "${BLUE}${BOLD}==============================================${NC}"
echo -e "${BLUE}${BOLD}Проверка KeyDB кластера${NC}"
echo -e "${BLUE}${BOLD}==============================================${NC}"
echo -e "${CYAN}Pod: $POD_NAME${NC}"
echo -e "${CYAN}Namespace: $NAMESPACE${NC}"
echo -e "${CYAN}Cluster: $CLUSTER_ID${NC}"
echo -e "${CYAN}Базовое имя: $BASE_POD_NAME${NC}"
echo -e "${BLUE}${BOLD}==============================================${NC}"

# Проверяем доступность пода
echo -e "${CYAN}Проверка доступности пода...${NC}"

# Проверяем существование неймспейса
if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo -e "${RED}Неймспейс $NAMESPACE не найден${NC}"
    echo -e "${YELLOW}Доступные неймспейсы:${NC}"
    kubectl get namespaces --no-headers -o custom-columns=":metadata.name" 2>/dev/null || true
    exit 1
fi

# Проверяем существование пода
pod_info=$(kubectl get pod -n $NAMESPACE $POD_NAME 2>/dev/null || true)
if [ -n "$pod_info" ]; then
    pod_status=$(echo "$pod_info" | tail -1 | awk '{print $3}')
    echo -e "${GREEN}Под доступен${NC}"
    echo -e "${CYAN}Статус: $pod_status${NC}"
    
    # Показываем дополнительную информацию о поде
    echo -e "${CYAN}Дополнительная информация о поде:${NC}"
    kubectl get pod -n $NAMESPACE $POD_NAME -o wide 2>/dev/null | tail -1
    
    # Проверяем, готов ли под
    pod_ready=$(echo "$pod_info" | tail -1 | awk '{print $2}')
    if [ "$pod_ready" != "1/1" ]; then
        echo -e "${YELLOW}Внимание: под не готов ($pod_ready)${NC}"
    fi
else
    echo -e "${RED}Под $POD_NAME не найден в namespace $NAMESPACE${NC}"
    
    # Показываем доступные поды
    echo -e "${YELLOW}Доступные поды в неймспейсе $NAMESPACE:${NC}"
    kubectl get pods -n $NAMESPACE --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep "keydb" || kubectl get pods -n $NAMESPACE --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -20
    
    exit 1
fi

# Проверяем подключение к KeyDB
if ! check_connection; then
    echo -e "${RED}Не удалось установить подключение. Проверьте параметры и повторите попытку.${NC}"
    
    # Даем подсказки
    echo -e "\n${YELLOW}Возможные причины:${NC}"
    echo -e "1. KeyDB не запущен на порту $PORT"
    echo -e "2. Неправильный пароль"
    echo -e "3. KeyDB требует аутентификации, но пароль не указан"
    echo -e "4. Проблемы с сетью или конфигурацией"
    
    # Пробуем проверить, слушает ли порт
    echo -e "\n${CYAN}Проверка, слушает ли KeyDB порт $PORT...${NC}"
    local port_check
    port_check=$(kubectl exec -n $NAMESPACE $POD_NAME -- sh -c "netstat -tln 2>/dev/null | grep :$PORT || ss -tln 2>/dev/null | grep :$PORT || echo 'Не удалось проверить порты'" 2>/dev/null)
    if [[ "$port_check" == *"$PORT"* ]]; then
        echo -e "${GREEN}✓ KeyDB слушает порт $PORT${NC}"
    else
        echo -e "${RED}✗ KeyDB не слушает порт $PORT${NC}"
    fi
    
    exit 1
fi

# Выполняем проверки KeyDB
check_keydb

# Вывод логов
show_pod_logs

echo -e "\n${BLUE}${BOLD}==============================================${NC}"
echo -e "${GREEN}${BOLD}Проверка завершена${NC}"
echo -e "${BLUE}${BOLD}==============================================${NC}"

# Получаем список подов для использования в командах
KEYDB_PODS=($(find_all_keydb_pods))

# Дополнительные команды для мониторинга
echo -e "\n${CYAN}${BOLD}Дополнительные команды для мониторинга:${NC}"

# Команды для KeyDB пода
echo -e "${YELLOW}Команды для KeyDB (выполнять на KeyDB подах):${NC}"

# Используем первый KeyDB под из списка
first_keydb_pod=""
if [ ${#KEYDB_PODS[@]} -gt 0 ]; then
    first_keydb_pod="${KEYDB_PODS[0]}"
else
    first_keydb_pod="$POD_NAME"
fi

echo -e "  ${CYAN}Быстрая проверка всех KeyDB:${NC}"
echo -e "    kubectl get pods -n $NAMESPACE | grep '${BASE_POD_NAME}-'"

echo -e "  ${CYAN}Проверить информацию о KeyDB:${NC}"
if [ -n "$KEYDB_PASSWORD" ]; then
    echo -e "    kubectl exec -n $NAMESPACE $first_keydb_pod -- keydb-cli -a '$KEYDB_PASSWORD' -p 6379 info"
else
    echo -e "    kubectl exec -n $NAMESPACE $first_keydb_pod -- keydb-cli -p 6379 info"
fi

echo -e "  ${CYAN}Проверить репликацию:${NC}"
if [ -n "$KEYDB_PASSWORD" ]; then
    echo -e "    kubectl exec -n $NAMESPACE $first_keydb_pod -- keydb-cli -a '$KEYDB_PASSWORD' -p 6379 info replication"
else
    echo -e "    kubectl exec -n $NAMESPACE $first_keydb_pod -- keydb-cli -p 6379 info replication"
fi

echo -e "  ${CYAN}Проверить память:${NC}"
if [ -n "$KEYDB_PASSWORD" ]; then
    echo -e "    kubectl exec -n $NAMESPACE $first_keydb_pod -- keydb-cli -a '$KEYDB_PASSWORD' -p 6379 info memory"
else
    echo -e "    kubectl exec -n $NAMESPACE $first_keydb_pod -- keydb-cli -p 6379 info memory"
fi

echo -e "  ${CYAN}Проверить клиентов:${NC}"
if [ -n "$KEYDB_PASSWORD" ]; then
    echo -e "    kubectl exec -n $NAMESPACE $first_keydb_pod -- keydb-cli -a '$KEYDB_PASSWORD' -p 6379 info clients"
else
    echo -e "    kubectl exec -n $NAMESPACE $first_keydb_pod -- keydb-cli -p 6379 info clients"
fi

echo -e "  ${CYAN}Проверить статистику:${NC}"
if [ -n "$KEYDB_PASSWORD" ]; then
    echo -e "    kubectl exec -n $NAMESPACE $first_keydb_pod -- keydb-cli -a '$KEYDB_PASSWORD' -p 6379 info stats"
else
    echo -e "    kubectl exec -n $NAMESPACE $first_keydb_pod -- keydb-cli -p 6379 info stats"
fi

echo -e "  ${CYAN}Просмотр логов KeyDB:${NC}"
echo -e "    kubectl logs -n $NAMESPACE $first_keydb_pod -f"

echo -e "  ${CYAN}Подключиться к KeyDB консоли:${NC}"
if [ -n "$KEYDB_PASSWORD" ]; then
    echo -e "    kubectl exec -n $NAMESPACE $first_keydb_pod -it -- keydb-cli -a '$KEYDB_PASSWORD' -p 6379"
else
    echo -e "    kubectl exec -n $NAMESPACE $first_keydb_pod -it -- keydb-cli -p 6379"
fi

# Общие команды
echo -e "\n${YELLOW}Общие команды:${NC}"
echo -e "  ${CYAN}Все поды KeyDB в кластере $CLUSTER_ID:${NC}"
echo -e "    kubectl get pods -n $NAMESPACE | grep -E '${BASE_POD_NAME}-'"

echo -e "  ${CYAN}Проверка ресурсов:${NC}"
echo -e "    kubectl top pod -n $NAMESPACE $POD_NAME 2>/dev/null || echo 'Метрики не доступны'"

echo -e "  ${CYAN}Получить все поды в неймспейсе:${NC}"
echo -e "    kubectl get pods -n $NAMESPACE"

echo -e "  ${CYAN}Проверить StatefulSet:${NC}"
echo -e "    kubectl get statefulset -n $NAMESPACE | grep keydb"

echo -e "  ${CYAN}Проверить службы:${NC}"
echo -e "    kubectl get svc -n $NAMESPACE | grep keydb"

echo -e "  ${CYAN}Проверить секреты:${NC}"
echo -e "    kubectl get secrets -n $NAMESPACE | grep -E '(keydb|${SECRET_PREFIX})'"

# Вывод списков найденных подов
echo -e "\n${CYAN}${BOLD}Найденные поды в кластере $CLUSTER_ID:${NC}"
if [ ${#KEYDB_PODS[@]} -gt 0 ]; then
    echo -e "${GREEN}KeyDB поды (${#KEYDB_PODS[@]}):${NC}"
    for keydb_pod in "${KEYDB_PODS[@]}"; do
        echo -e "  - $keydb_pod"
    done
else
    echo -e "${YELLOW}KeyDB поды не найдены${NC}"
fi