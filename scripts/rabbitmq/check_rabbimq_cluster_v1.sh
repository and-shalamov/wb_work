#!/bin/bash

# Скрипт проверки статуса RabbitMQ кластера и нод
# Использование: ./check_rabbitmq_cluster.sh <pod_name> <namespace> [port] [password]

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
    echo -e "  ${YELLOW}pod_name: имя пода с RabbitMQ (rmq-* или amqp-*)${NC}"
    echo -e "  ${YELLOW}port: опционально - если не указан, будет определен автоматически${NC}"
    echo -e "  ${YELLOW}password: опционально - если не указан, будет получен из секрета${NC}"
    exit 1
fi

POD_NAME=$1
NAMESPACE=$2
PORT=$3
RABBITMQ_PASSWORD=$4

# Определяем тип пода и порт по умолчанию
if [[ "$POD_NAME" == rmq-* ]] || [[ "$POD_NAME" == amqp-* ]]; then
    POD_TYPE="rabbitmq"
    DEFAULT_PORT=5672
    MANAGEMENT_PORT=15672
else
    echo -e "${RED}Неизвестный тип пода: $POD_NAME${NC}"
    echo -e "${YELLOW}Ожидаются префиксы: rmq-* или amqp-* (RabbitMQ)${NC}"
    exit 1
fi

# Устанавливаем порт по умолчанию, если не указан
if [ -z "$PORT" ]; then
    PORT=$DEFAULT_PORT
    echo -e "${YELLOW}Порт не указан, используется порт по умолчанию: $PORT${NC}"
fi

# Функция для извлечения идентификатора кластера
get_cluster_info() {
    local pod_name="$1"
    
    # Разбиваем имя пода на части по дефисам
    # Формат: rmq-<service>-<environment>-<index>
    # Пример: rmq-notifications-main-0 -> notifications-main
    
    # Удаляем префикс rmq- или amqp-
    local without_prefix="${pod_name#rmq-}"
    without_prefix="${without_prefix#amqp-}"
    
    # Удаляем суффикс -[0-9]* (индекс пода)
    local cluster_id=$(echo "$without_prefix" | sed 's/-[0-9]\+$//')
    
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

# Функция для поиска всех RabbitMQ подов в кластере
find_all_rabbitmq_pods() {
    echo -e "${CYAN}Поиск RabbitMQ подов по шаблону: ${BASE_POD_NAME}-*${NC}"
    
    # Получаем все поды RabbitMQ в неймспейсе по шаблону
    local all_rabbitmq_pods=($(kubectl get pods -n $NAMESPACE --no-headers -o custom-columns=":metadata.name" | grep "${BASE_POD_NAME}-" || true))
    
    if [ ${#all_rabbitmq_pods[@]} -eq 0 ]; then
        # Если не нашли по шаблону, попробуем найти любой RabbitMQ под с тем же кластером
        echo -e "${YELLOW}Не найдено RabbitMQ подов по шаблону ${BASE_POD_NAME}-*, используем расширенный поиск${NC}"
        all_rabbitmq_pods=($(kubectl get pods -n $NAMESPACE --no-headers -o custom-columns=":metadata.name" | grep -E "rmq-.*$CLUSTER_ID|amqp-.*$CLUSTER_ID" || true))
    fi
    
    echo "${all_rabbitmq_pods[@]}"
}

# Функция для получения пароля из секрета
get_password_from_secret() {
    echo -e "${CYAN}Поиск секрета для RabbitMQ...${NC}"
    
    # Ищем секреты по различным шаблонам
    local secret_name=""
    
    # Попробуем разные варианты имен секретов
    local possible_secrets=(
        "rabbitmq-${CLUSTER_ID}-secret"
        "rmq-${CLUSTER_ID}-secret" 
        "${CLUSTER_ID}-rabbitmq-secret"
        "rabbitmq-secret"
        "rmq-secret"
        "rabbitmq-credentials"
    )
    
    for secret in "${possible_secrets[@]}"; do
        if kubectl get secret -n $NAMESPACE "$secret" &>/dev/null; then
            secret_name="$secret"
            break
        fi
    done
    
    if [ -z "$secret_name" ]; then
        # Если не нашли по шаблонам, ищем любой секрет с rabbitmq в имени
        secret_name=$(kubectl get secrets -n $NAMESPACE --no-headers -o custom-columns=":metadata.name" | grep -i rabbitmq | head -1)
    fi
    
    if [ -n "$secret_name" ]; then
        echo -e "${GREEN}Найден секрет: $secret_name${NC}"
        
        # Пробуем разные ключи в секрете
        local password_keys=("password" "rabbitmq-password" "rmq-password" "admin-password")
        
        for key in "${password_keys[@]}"; do
            local password=$(kubectl get secret -n $NAMESPACE "$secret_name" -o jsonpath="{.data.$key}" 2>/dev/null | base64 -d 2>/dev/null || true)
            if [ -n "$password" ]; then
                echo "$password"
                return 0
            fi
        done
    fi
    
    echo -e "${YELLOW}Не удалось найти пароль в секретах${NC}"
    return 1
}

# Функция для выполнения команд RabbitMQ через rabbitmqctl
exec_rabbitmqctl() {
    local cmd="$1"
    local pod="${2:-$POD_NAME}"
    
    local result
    if [ -n "$RABBITMQ_PASSWORD" ]; then
        # Для выполнения rabbitmqctl команд обычно не нужен пароль, так как они выполняются внутри пода
        result=$(kubectl exec -n $NAMESPACE $pod -- sh -c "rabbitmqctl $cmd" 2>&1 || echo "ERROR: $?")
    else
        result=$(kubectl exec -n $NAMESPACE $pod -- sh -c "rabbitmqctl $cmd" 2>&1 || echo "ERROR: $?")
    fi
    
    echo "$result"
}

# Функция для выполнения команд через rabbitmqadmin (HTTP API)
exec_rabbitmqadmin() {
    local cmd="$1"
    local pod="${2:-$POD_NAME}"
    
    local result
    if [ -n "$RABBITMQ_PASSWORD" ]; then
        result=$(kubectl exec -n $NAMESPACE $pod -- sh -c "rabbitmqadmin -u guest -p '$RABBITMQ_PASSWORD' $cmd" 2>&1 || echo "ERROR")
    else
        result=$(kubectl exec -n $NAMESPACE $pod -- sh -c "rabbitmqadmin -u guest $cmd" 2>&1 || echo "ERROR")
    fi
    
    echo "$result"
}

# Функция для проверки доступности RabbitMQ
check_connection() {
    echo -e "${CYAN}Проверка подключения к RabbitMQ...${NC}"
    
    # Сначала проверяем, что под запущен
    local pod_status=$(kubectl get pod -n $NAMESPACE $POD_NAME -o jsonpath='{.status.phase}' 2>/dev/null)
    if [ "$pod_status" != "Running" ]; then
        echo -e "${RED}Под не в состоянии Running. Текущий статус: $pod_status${NC}"
        return 1
    fi
    
    # Проверяем статус RabbitMQ через rabbitmqctl
    local response=$(exec_rabbitmqctl "status" 2>/dev/null | head -5 || true)
    
    if [[ "$response" == *"RabbitMQ"* ]] || [[ "$response" == *"running"* ]]; then
        echo -e "${GREEN}✓ RabbitMQ запущен и доступен${NC}"
        return 0
    elif [[ "$response" == *"ERROR"* ]]; then
        echo -e "${RED}✗ Ошибка подключения к RabbitMQ${NC}"
        echo -e "${YELLOW}Ответ: $response${NC}"
        return 1
    else
        echo -e "${YELLOW}⚠ Не удалось проверить статус RabbitMQ${NC}"
        return 1
    fi
}

# Функция для получения IP адреса пода
get_pod_ip() {
    local pod="$1"
    kubectl get pod -n $NAMESPACE $pod -o jsonpath='{.status.podIP}' 2>/dev/null || echo "неизвестный IP"
}

# Функция для проверки состояния кластера RabbitMQ
check_rabbitmq_cluster() {
    echo -e "\n${PURPLE}${BOLD}1. СОСТОЯНИЕ КЛАСТЕРА RABBITMQ:${NC}"
    
    # Получаем информацию о кластере
    local cluster_status=$(exec_rabbitmqctl "cluster_status")
    
    if [[ "$cluster_status" == *"ERROR"* ]]; then
        echo -e "${RED}✗ Ошибка получения статуса кластера${NC}"
        return 1
    fi
    
    # Парсим информацию о кластере
    local running_nodes=$(echo "$cluster_status" | grep -o "running_nodes.*" | sed 's/running_nodes,\[//' | sed 's/\]//' | tr -d ' ')
    local disc_nodes=$(echo "$cluster_status" | grep -o "disc,\[.*\]" | sed 's/disc,\[//' | sed 's/\]//' | tr -d ' ')
    local ram_nodes=$(echo "$cluster_status" | grep -o "ram,\[.*\]" | sed 's/ram,\[//' | sed 's/\]//' | tr -d ' ')
    
    echo -e "${CYAN}Текущий узел: $POD_NAME${NC}"
    echo -e "${GREEN}Запущенные узлы: $running_nodes${NC}"
    echo -e "${CYAN}Дисковые узлы: $disc_nodes${NC}"
    echo -e "${CYAN}RAM узлы: $ram_nodes${NC}"
    
    # Проверяем, является ли узел частью кластера
    if [[ "$running_nodes" == *"$POD_NAME"* ]]; then
        echo -e "${GREEN}✓ Узел является частью кластера${NC}"
    else
        echo -e "${YELLOW}⚠ Узел не в кластере или standalone${NC}"
    fi
}

# Функция для проверки всех RabbitMQ нод в кластере
get_all_rabbitmq_nodes_info() {
    echo -e "\n${PURPLE}${BOLD}1.1. Все RabbitMQ ноды в кластере $CLUSTER_ID:${NC}"
    
    local rabbitmq_pods=($(find_all_rabbitmq_pods))
    
    if [ ${#rabbitmq_pods[@]} -eq 0 ]; then
        echo -e "${YELLOW}RabbitMQ поды не найдены в кластере $CLUSTER_ID${NC}"
        return 1
    fi
    
    echo -e "${CYAN}Найдено RabbitMQ подов: ${#rabbitmq_pods[@]}${NC}"
    
    for rabbitmq_pod in "${rabbitmq_pods[@]}"; do
        echo -e "\n${CYAN}RabbitMQ: $rabbitmq_pod${NC}"
        
        # Получаем IP адрес
        local pod_ip=$(get_pod_ip "$rabbitmq_pod")
        echo -e "  ${YELLOW}IP: $pod_ip${NC}"
        
        # Проверяем статус пода
        local pod_status=$(kubectl get pod -n $NAMESPACE $rabbitmq_pod -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        echo -e "  ${YELLOW}Статус: $pod_status${NC}"
        
        if [ "$pod_status" = "Running" ]; then
            # Проверяем статус RabbitMQ
            local node_status=$(exec_rabbitmqctl "status" "$rabbitmq_pod" 2>/dev/null | head -3 || echo "Недоступен")
            
            if [[ "$node_status" == *"RabbitMQ"* ]]; then
                echo -e "  ${GREEN}✓ RabbitMQ запущен${NC}"
                
                # Получаем информацию о кластере для этого узла
                local cluster_info=$(exec_rabbitmqctl "cluster_status" "$rabbitmq_pod" 2>/dev/null | grep "running_nodes" | head -1 || echo "")
                if [[ "$cluster_info" == *"$rabbitmq_pod"* ]]; then
                    echo -e "  ${GREEN}✓ Узел в кластере${NC}"
                else
                    echo -e "  ${YELLOW}⚠ Узел не в кластере${NC}"
                fi
            else
                echo -e "  ${RED}✗ RabbitMQ не доступен${NC}"
            fi
        else
            echo -e "  ${RED}Под не в состоянии Running, детальная информация недоступна${NC}"
        fi
    done
}

# Функция для проверки виртуальных хостов
check_virtual_hosts() {
    echo -e "\n${PURPLE}${BOLD}2. ВИРТУАЛЬНЫЕ ХОСТЫ:${NC}"
    
    local vhosts=$(exec_rabbitmqctl "list_vhosts" | grep -v "Listing vhosts" | grep -v "^name" | grep -v "^\s*$")
    
    if [ -n "$vhosts" ]; then
        echo -e "${CYAN}Найдено виртуальных хостов:$(echo "$vhosts" | wc -l)${NC}"
        while IFS= read -r vhost; do
            if [ -n "$vhost" ]; then
                echo -e "  ${GREEN}✓ $vhost${NC}"
            fi
        done <<< "$vhosts"
    else
        echo -e "${YELLOW}Виртуальные хосты не найдены${NC}"
    fi
}

# Функция для проверки пользователей
check_users() {
    echo -e "\n${PURPLE}${BOLD}3. ПОЛЬЗОВАТЕЛИ:${NC}"
    
    local users=$(exec_rabbitmqctl "list_users" | grep -v "Listing users" | grep -v "^user" | grep -v "^\s*$")
    
    if [ -n "$users" ]; then
        echo -e "${CYAN}Найдено пользователей:$(echo "$users" | wc -l)${NC}"
        while IFS= read -r user; do
            if [ -n "$user" ]; then
                local username=$(echo "$user" | awk '{print $1}')
                local tags=$(echo "$user" | awk '{$1=""; print $0}' | sed 's/^ *//')
                echo -e "  ${CYAN}👤 $username${NC} [${YELLOW}$tags${NC}]"
            fi
        done <<< "$users"
    else
        echo -e "${YELLOW}Пользователи не найдены${NC}"
    fi
}

# Функция для проверки очередей
check_queues() {
    echo -e "\n${PURPLE}${BOLD}4. ОЧЕРЕДИ:${NC}"
    
    local queues=$(exec_rabbitmqctl "list_queues" name messages messages_ready messages_unacknowledged consumers | \
        grep -v "Listing queues" | grep -v "^name" | grep -v "^\s*$")
    
    if [ -n "$queues" ]; then
        local total_queues=$(echo "$queues" | wc -l)
        local total_messages=0
        local total_ready=0
        local total_unack=0
        local total_consumers=0
        
        echo -e "${CYAN}Найдено очередей: $total_queues${NC}"
        echo -e "${YELLOW}Имя очереди | Сообщений | Готово | Неподтверждено | Потребители${NC}"
        
        while IFS= read -r queue; do
            if [ -n "$queue" ]; then
                local name=$(echo "$queue" | awk '{print $1}')
                local messages=$(echo "$queue" | awk '{print $2}')
                local ready=$(echo "$queue" | awk '{print $3}')
                local unack=$(echo "$queue" | awk '{print $4}')
                local consumers=$(echo "$queue" | awk '{print $5}')
                
                total_messages=$((total_messages + messages))
                total_ready=$((total_ready + ready))
                total_unack=$((total_unack + unack))
                total_consumers=$((total_consumers + consumers))
                
                # Цветовая маркировка в зависимости от нагрузки
                local msg_color=$GREEN
                if [ "$messages" -gt 1000 ]; then
                    msg_color=$RED
                elif [ "$messages" -gt 100 ]; then
                    msg_color=$YELLOW
                fi
                
                echo -e "  ${CYAN}$name${NC} | ${msg_color}$messages${NC} | ${msg_color}$ready${NC} | ${msg_color}$unack${NC} | ${GREEN}$consumers${NC}"
            fi
        done <<< "$queues"
        
        echo -e "\n${PURPLE}${BOLD}СВОДКА ПО ОЧЕРЕДЯМ:${NC}"
        echo -e "  ${CYAN}Всего сообщений: $total_messages${NC}"
        echo -e "  ${CYAN}Сообщений готово: $total_ready${NC}"
        echo -e "  ${CYAN}Сообщений неподтверждено: $total_unack${NC}"
        echo -e "  ${CYAN}Всего потребителей: $total_consumers${NC}"
    else
        echo -e "${YELLOW}Очереди не найдены${NC}"
    fi
}

# Функция для проверки обменников
check_exchanges() {
    echo -e "\n${PURPLE}${BOLD}5. ОБМЕННИКИ:${NC}"
    
    local exchanges=$(exec_rabbitmqctl "list_exchanges" name type | grep -v "Listing exchanges" | grep -v "^name" | grep -v "^\s*$")
    
    if [ -n "$exchanges" ]; then
        echo -e "${CYAN}Найдено обменников:$(echo "$exchanges" | wc -l)${NC}"
        while IFS= read -r exchange; do
            if [ -n "$exchange" ]; then
                local name=$(echo "$exchange" | awk '{print $1}')
                local type=$(echo "$exchange" | awk '{print $2}')
                echo -e "  ${CYAN}🔁 $name${NC} [${GREEN}$type${NC}]"
            fi
        done <<< "$exchanges"
    else
        echo -e "${YELLOW}Обменники не найдены${NC}"
    fi
}

# Функция для проверки подключений
check_connections() {
    echo -e "\n${PURPLE}${BOLD}6. ПОДКЛЮЧЕНИЯ:${NC}"
    
    local connections=$(exec_rabbitmqctl "list_connections" state channels | head -20 | grep -v "Listing connections" | grep -v "^peer" | grep -v "^\s*$")
    
    if [ -n "$connections" ]; then
        echo -e "${CYAN}Активные подключения (первые 20):${NC}"
        while IFS= read -r connection; do
            if [ -n "$connection" ]; then
                local peer=$(echo "$connection" | awk '{print $1}')
                local state=$(echo "$connection" | awk '{print $2}')
                local channels=$(echo "$connection" | awk '{print $3}')
                
                local state_color=$GREEN
                if [ "$state" != "running" ]; then
                    state_color=$RED
                fi
                
                echo -e "  ${CYAN}🌐 $peer${NC} | ${state_color}$state${NC} | ${YELLOW}$channels каналов${NC}"
            fi
        done <<< "$connections"
    else
        echo -e "${YELLOW}Активные подключения не найдены${NC}"
    fi
}

# Функция для проверки каналов
check_channels() {
    echo -e "\n${PURPLE}${BOLD}7. КАНАЛЫ:${NC}"
    
    local channels=$(exec_rabbitmqctl "list_channels" connection consumer_count | head -15 | grep -v "Listing channels" | grep -v "^connection" | grep -v "^\s*$")
    
    if [ -n "$channels" ]; then
        echo -e "${CYAN}Активные каналы (первые 15):${NC}"
        while IFS= read -r channel; do
            if [ -n "$channel" ]; then
                local connection=$(echo "$channel" | awk '{print $1}')
                local consumers=$(echo "$channel" | awk '{print $2}')
                echo -e "  ${CYAN}📡 $connection${NC} | ${GREEN}$consumers потребителей${NC}"
            fi
        done <<< "$channels"
    else
        echo -e "${YELLOW}Активные каналы не найдены${NC}"
    fi
}

# Функция для проверки производительности
check_performance() {
    echo -e "\n${PURPLE}${BOLD}8. ПРОИЗВОДИТЕЛЬНОСТЬ:${NC}"
    
    # Получаем общую статистику
    local node_stats=$(exec_rabbitmqctl "status" | grep -A 10 "pid," || echo "")
    
    # Парсим информацию о памяти
    local memory_info=$(exec_rabbitmqctl "status" | grep -A 5 "memory" | grep "total" | head -1 | sed 's/.*total,//' | sed 's/}.//' || echo "неизвестно")
    
    # Парсим информацию о диске
    local disk_info=$(exec_rabbitmqctl "status" | grep -A 5 "disk_free" | head -1 | sed 's/.*disk_free,//' | sed 's/}.//' || echo "неизвестно")
    
    echo -e "${CYAN}Использование памяти: $memory_info${NC}"
    echo -e "${CYAN}Свободное место на диске: $disk_info${NC}"
    
    # Получаем информацию о файловых дескрипторах
    local fd_info=$(exec_rabbitmqctl "status" | grep -A 3 "file_descriptors" | grep "total_used" | sed 's/.*total_used,//' | sed 's/}.//' || echo "неизвестно")
    echo -e "${CYAN}Использовано файловых дескрипторов: $fd_info${NC}"
    
    # Получаем информацию о сокетах
    local sockets_info=$(exec_rabbitmqctl "status" | grep -A 3 "sockets" | grep "total_used" | sed 's/.*total_used,//' | sed 's/}.//' || echo "неизвестно")
    echo -e "${CYAN}Использовано сокетов: $sockets_info${NC}"
}

# Функция для вывода логов
show_pod_logs() {
    echo -e "\n${PURPLE}${BOLD}9. ПОСЛЕДНИЕ ЛОГИ:${NC}"
    
    # Получаем последние 10 строк логов
    local recent_logs=$(kubectl logs -n $NAMESPACE $POD_NAME --tail=10 2>/dev/null || echo "Логи недоступны")
    
    echo -e "${CYAN}Последние 10 строк логов:${NC}"
    echo -e "${YELLOW}$recent_logs${NC}"
}

# Основная функция проверки RabbitMQ
check_rabbitmq() {
    echo -e "${GREEN}${BOLD}=== ПРОВЕРКА RABBITMQ КЛАСТЕРА ===${NC}"
    
    # 1. Состояние кластера
    check_rabbitmq_cluster
    
    # 2. Все ноды в кластере
    get_all_rabbitmq_nodes_info
    
    # 3. Виртуальные хосты
    check_virtual_hosts
    
    # 4. Пользователи
    check_users
    
    # 5. Очереди
    check_queues
    
    # 6. Обменники
    check_exchanges
    
    # 7. Подключения
    check_connections
    
    # 8. Каналы
    check_channels
    
    # 9. Производительность
    check_performance
}

# Если пароль не передан как аргумент, получаем его из секрета
if [ -z "$RABBITMQ_PASSWORD" ]; then
    echo -e "${CYAN}Пароль не указан, получение из секрета...${NC}"
    RABBITMQ_PASSWORD=$(get_password_from_secret)
    if [ $? -ne 0 ]; then
        echo -e "${YELLOW}Продолжаем без пароля...${NC}"
        RABBITMQ_PASSWORD=""
    else
        echo -e "${GREEN}Пароль успешно получен из секрета${NC}"
    fi
else
    echo -e "${GREEN}Используется пароль из аргументов${NC}"
fi

echo -e "${BLUE}${BOLD}==============================================${NC}"
echo -e "${BLUE}${BOLD}Проверка RabbitMQ кластера${NC}"
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

# Проверяем подключение к RabbitMQ
if ! check_connection; then
    echo -e "${RED}Не удалось установить подключение. Проверьте параметры и повторите попытку.${NC}"
    exit 1
fi

# Выполняем проверки RabbitMQ
check_rabbitmq

# Вывод логов
show_pod_logs

echo -e "\n${BLUE}${BOLD}==============================================${NC}"
echo -e "${GREEN}${BOLD}Проверка завершена${NC}"
echo -e "${BLUE}${BOLD}==============================================${NC}"

# Получаем список всех RabbitMQ подов
RABBITMQ_PODS=($(find_all_rabbitmq_pods))

# Дополнительные команды для мониторинга
echo -e "\n${CYAN}${BOLD}ДОПОЛНИТЕЛЬНЫЕ КОМАНДЫ ДЛЯ МОНИТОРИНГА:${NC}"

echo -e "${YELLOW}Команды для RabbitMQ (выполнять на RabbitMQ подах):${NC}"

# Используем первый RabbitMQ под из списка
local first_rabbitmq_pod=""
if [ ${#RABBITMQ_PODS[@]} -gt 0 ]; then
    first_rabbitmq_pod="${RABBITMQ_PODS[0]}"
else
    first_rabbitmq_pod="$POD_NAME"
fi

echo -e "  ${CYAN}Быстрая проверка всех RabbitMQ подов:${NC}"
echo -e "    kubectl get pods -n $NAMESPACE | grep '${BASE_POD_NAME}-'"

echo -e "  ${CYAN}Проверить статус RabbitMQ:${NC}"
echo -e "    kubectl exec -n $NAMESPACE $first_rabbitmq_pod -- rabbitmqctl status"

echo -e "  ${CYAN}Проверить состояние кластера:${NC}"
echo -e "    kubectl exec -n $NAMESPACE $first_rabbitmq_pod -- rabbitmqctl cluster_status"

echo -e "  ${CYAN}Просмотреть все очереди:${NC}"
echo -e "    kubectl exec -n $NAMESPACE $first_rabbitmq_pod -- rabbitmqctl list_queues name messages messages_ready messages_unacknowledged consumers"

echo -e "  ${CYAN}Просмотреть все подключения:${NC}"
echo -e "    kubectl exec -n $NAMESPACE $first_rabbitmq_pod -- rabbitmqctl list_connections"

echo -e "  ${CYAN}Просмотреть все каналы:${NC}"
echo -e "    kubectl exec -n $NAMESPACE $first_rabbitmq_pod -- rabbitmqctl list_channels"

echo -e "  ${CYAN}Просмотреть виртуальные хосты:${NC}"
echo -e "    kubectl exec -n $NAMESPACE $first_rabbitmq_pod -- rabbitmqctl list_vhosts"

echo -e "  ${CYAN}Просмотреть пользователей:${NC}"
echo -e "    kubectl exec -n $NAMESPACE $first_rabbitmq_pod -- rabbitmqctl list_users"

echo -e "  ${CYAN}Просмотреть обменники:${NC}"
echo -e "    kubectl exec -n $NAMESPACE $first_rabbitmq_pod -- rabbitmqctl list_exchanges"

echo -e "  ${CYAN}Проверить политики:${NC}"
echo -e "    kubectl exec -n $NAMESPACE $first_rabbitmq_pod -- rabbitmqctl list_policies"

echo -e "  ${CYAN}Просмотр логов RabbitMQ:${NC}"
echo -e "    kubectl logs -n $NAMESPACE $first_rabbitmq_pod -f"

# Команды для мониторинга через HTTP API (если включен management plugin)
echo -e "\n${YELLOW}Команды для HTTP API (management plugin):${NC}"
echo -e "  ${CYAN}Получить обзор кластера:${NC}"
echo -e "    kubectl exec -n $NAMESPACE $first_rabbitmq_pod -- curl -s -u guest:guest http://localhost:15672/api/overview"

echo -e "  ${CYAN}Получить список нод:${NC}"
echo -e "    kubectl exec -n $NAMESPACE $first_rabbitmq_pod -- curl -s -u guest:guest http://localhost:15672/api/nodes"

echo -e "  ${CYAN}Получить детальную информацию об очередях:${NC}"
echo -e "    kubectl exec -n $NAMESPACE $first_rabbitmq_pod -- curl -s -u guest:guest http://localhost:15672/api/queues"

# Общие команды
echo -e "\n${YELLOW}Общие команды:${NC}"
echo -e "  ${CYAN}Все поды RabbitMQ в кластере $CLUSTER_ID:${NC}"
echo -e "    kubectl get pods -n $NAMESPACE | grep '${BASE_POD_NAME}-'"

echo -e "  ${CYAN}Проверка ресурсов:${NC}"
echo -e "    kubectl top pod -n $NAMESPACE $POD_NAME 2>/dev/null || echo 'Метрики не доступны'"

echo -e "  ${CYAN}Получить все поды в неймспейсе:${NC}"
echo -e "    kubectl get pods -n $NAMESPACE"

# Вывод списков найденных подов
echo -e "\n${CYAN}${BOLD}НАЙДЕННЫЕ ПОДЫ В КЛАСТЕРЕ $CLUSTER_ID:${NC}"
if [ ${#RABBITMQ_PODS[@]} -gt 0 ]; then
    echo -e "${GREEN}RabbitMQ поды (${#RABBITMQ_PODS[@]}):${NC}"
    for rabbitmq_pod in "${RABBITMQ_PODS[@]}"; do
        echo -e "  - $rabbitmq_pod"
    done
fi