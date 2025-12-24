#!/bin/bash

# Функция для вывода справки
show_help() {
    echo "Использование: $0 [опции]"
    echo ""
    echo "Опции:"
    echo "  -n, --namespace NAME     Вывести поды только из указанного неймспейса"
    echo "  -A, --all-namespaces     Вывести поды из всех неймспейсов (по умолчанию)"
    echo "  -h, --help               Показать эту справку"
    echo ""
    echo "Примеры:"
    echo "  $0                          # Вывести все поды из всех неймспейсов"
    echo "  $0 -n default               # Вывести поды только из неймспейса default"
    echo "  $0 --namespace kube-system  # Вывести поды только из неймспейса kube-system"
}

# Парсинг аргументов командной строки
NAMESPACE_OPTION="--all-namespaces"

while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--namespace)
            if [[ -n $2 ]]; then
                NAMESPACE="$2"
                NAMESPACE_OPTION="-n $2"
                shift 2
            else
                echo "Ошибка: Не указано имя неймспейса для параметра -n/--namespace"
                exit 1
            fi
            ;;
        -A|--all-namespaces)
            NAMESPACE_OPTION="--all-namespaces"
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Неизвестный параметр: $1"
            show_help
            exit 1
            ;;
    esac
done

# Если namespace не задан, но мы не используем --all-namespaces, ставим "all"
if [[ -z "$NAMESPACE" && "$NAMESPACE_OPTION" != "--all-namespaces" ]]; then
    NAMESPACE="all"
fi

echo "Сбор информации о подах с ресурсами, портами и PVC..."
if [[ -n "$NAMESPACE" ]]; then
    echo "Неймспейс: $NAMESPACE"
fi
echo ""

# Функция для форматирования информации о томах с размером PVC в начале
format_volumes_info() {
    local pod_json="$1"
    local namespace="$2"
    local volumes_info=""
    
    # Получаем информацию о всех томах из JSON пода
    local volumes=$(echo "$pod_json" | jq -r '.spec.volumes[]? | .name' 2>/dev/null)
    
    if [ -z "$volumes" ] || [ "$volumes" = "null" ]; then
        echo "none"
        return
    fi
    
    # Для каждого тома получаем его тип и информацию
    while read -r volume_name; do
        if [ -z "$volume_name" ]; then
            continue
        fi
        
        # Получаем тип тома и его специфичную информацию
        local volume_type_info=$(echo "$pod_json" | jq -r --arg vname "$volume_name" '
            .spec.volumes[] | select(.name == $vname) | 
            if .persistentVolumeClaim then "pvc:" + .persistentVolumeClaim.claimName
            elif .configMap then "configmap:" + (.configMap.name // $vname)
            elif .secret then "secret:" + (.secret.secretName // $vname)
            elif .emptyDir then 
                if .emptyDir.medium then "emptydir:" + .emptyDir.medium 
                else "emptydir:default" 
                end
            elif .projected then "projected"
            elif .downwardAPI then "downwardapi"
            else "other:" + $vname
            end
        ')
        
        local volume_type=$(echo "$volume_type_info" | cut -d: -f1)
        local volume_value=$(echo "$volume_type_info" | cut -d: -f2-)
        
        case "$volume_type" in
            "pvc")
                local pvc_name="$volume_value"
                # Получаем размер PVC
                local size=$(kubectl get pvc -n "$namespace" "$pvc_name" -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || echo "unknown")
                
                # Выводим размер в начале, затем имя PVC
                if [ -t 1 ]; then
                    # Вывод в терминал - используем ANSI escape codes для выделения
                    volumes_info+="\033[1m${size} - ${pvc_name}\033[0m "
                else
                    # Вывод в файл или пайп
                    volumes_info+="${size} - ${pvc_name} "
                fi
                ;;
            "configmap")
                local cm_name="$volume_value"
                volumes_info+="configmap:${cm_name} "
                ;;
            "secret")
                local secret_name="$volume_value"
                volumes_info+="secret:${secret_name} "
                ;;
            "emptydir")
                local medium="$volume_value"
                if [ "$medium" = "Memory" ]; then
                    volumes_info+="emptydir(Memory) "
                else
                    volumes_info+="emptydir "
                fi
                ;;
            "projected")
                volumes_info+="projected "
                ;;
            "downwardapi")
                volumes_info+="downwardapi "
                ;;
            "other")
                volumes_info+="other($volume_value) "
                ;;
            *)
                # Для остальных типов выводим тип и значение
                if [ "$volume_value" != "$volume_type" ]; then
                    volumes_info+="${volume_type}:${volume_value} "
                else
                    volumes_info+="${volume_type} "
                fi
                ;;
        esac
    done <<< "$volumes"
    
    # Убираем последний пробел
    echo "${volumes_info% }"
}

# Собираем все данные
declare -a namespaces
declare -a pods
declare -a ports
declare -a cpu_reqs
declare -a cpu_lims
declare -a mem_reqs
declare -a mem_lims
declare -a volumes_info

index=0
while read -r pod; do
    ns=$(echo "$pod" | jq -r '.metadata.namespace // "unknown"')
    name=$(echo "$pod" | jq -r '.metadata.name // "unknown"')
    
    # Извлекаем порты из всех контейнеров
    ports_str=$(echo "$pod" | jq -r '[.spec.containers[]?.ports[]?.containerPort] | join(", ")')
    if [ -z "$ports_str" ] || [ "$ports_str" = "null" ]; then
        ports_str="none"
    fi
    
    # Извлекаем ресурсы CPU и памяти (берем первый контейнер для простоты)
    cpu_req=$(echo "$pod" | jq -r '.spec.containers[0].resources.requests.cpu // "none"')
    cpu_lim=$(echo "$pod" | jq -r '.spec.containers[0].resources.limits.cpu // "none"')
    mem_req=$(echo "$pod" | jq -r '.spec.containers[0].resources.requests.memory // "none"')
    mem_lim=$(echo "$pod" | jq -r '.spec.containers[0].resources.limits.memory // "none"')
    
    # Форматируем информацию о томах
    volumes_str=$(format_volumes_info "$pod" "$ns")
    
    # Сохраняем данные
    namespaces[$index]="$ns"
    pods[$index]="$name"
    ports[$index]="$ports_str"
    cpu_reqs[$index]="$cpu_req"
    cpu_lims[$index]="$cpu_lim"
    mem_reqs[$index]="$mem_req"
    mem_lims[$index]="$mem_lim"
    volumes_info[$index]="$volumes_str"
    
    ((index++))
done < <(kubectl get pods $NAMESPACE_OPTION -o json 2>/dev/null | jq -c '.items[]' 2>/dev/null)

# Функция для вычисления ширины колонки с учетом отступа
calculate_column_width() {
    local data_array_name=$1
    local header=$2
    local min_width=$3
    local -n data_array=$data_array_name
    local max_width=${#header}
    
    # Находим максимальную длину в данных
    for data in "${data_array[@]}"; do
        # Убираем ANSI escape codes для вычисления длины
        clean_data=$(echo -e "$data" | sed 's/\x1b\[[0-9;]*m//g')
        if [ ${#clean_data} -gt $max_width ]; then
            max_width=${#clean_data}
        fi
    done
    
    # Обеспечиваем минимальную ширину
    if [ $max_width -lt $min_width ]; then
        max_width=$min_width
    fi
    
    echo $max_width
}

# Вычисляем ширины колонок
NS_WIDTH=$(calculate_column_width namespaces "NAMESPACE" 15)
POD_WIDTH=$(calculate_column_width pods "POD" 50)
PORTS_WIDTH=$(calculate_column_width ports "PORTS" 15)
CPU_REQ_WIDTH=$(calculate_column_width cpu_reqs "CPU_REQ" 8)
CPU_LIM_WIDTH=$(calculate_column_width cpu_lims "CPU_LIM" 8)
MEM_REQ_WIDTH=$(calculate_column_width mem_reqs "MEM_REQ" 8)
MEM_LIM_WIDTH=$(calculate_column_width mem_lims "MEM_LIM" 8)
VOLUMES_WIDTH=$(calculate_column_width volumes_info "VOLUMES/PVC" 40)

# Увеличиваем ширину для POD на 4 для отступа (но не добавляем в вычисление)
POD_OUTPUT_WIDTH=$((POD_WIDTH + 4))

# Форматирование строк
HEADER_FORMAT="%-${NS_WIDTH}s  %-${POD_WIDTH}s  %-${PORTS_WIDTH}s  %-${CPU_REQ_WIDTH}s  %-${CPU_LIM_WIDTH}s  %-${MEM_REQ_WIDTH}s  %-${MEM_LIM_WIDTH}s  %-${VOLUMES_WIDTH}s\n"
DATA_FORMAT="%-${NS_WIDTH}s  %-${POD_OUTPUT_WIDTH}s  %-${PORTS_WIDTH}s  %-${CPU_REQ_WIDTH}s  %-${CPU_LIM_WIDTH}s  %-${MEM_REQ_WIDTH}s  %-${MEM_LIM_WIDTH}s  %-${VOLUMES_WIDTH}s\n"

# Вывод заголовка
printf "$HEADER_FORMAT" "NAMESPACE" "POD" "PORTS" "CPU_REQ" "CPU_LIM" "MEM_REQ" "MEM_LIM" "VOLUMES/PVC"

# Вывод разделительной линии
TOTAL_WIDTH=$((NS_WIDTH + POD_OUTPUT_WIDTH + PORTS_WIDTH + CPU_REQ_WIDTH + CPU_LIM_WIDTH + MEM_REQ_WIDTH + MEM_LIM_WIDTH + VOLUMES_WIDTH + 14))
printf "%-${TOTAL_WIDTH}s\n" "" | tr ' ' '-'

# Вывод данных
for ((i=0; i<index; i++)); do
    # Добавляем 4 пробела перед именем пода
    padded_name="${pods[$i]}"
    
    # Выводим строку с данными
    printf "$DATA_FORMAT" \
        "${namespaces[$i]}" \
        "$padded_name" \
        "${ports[$i]}" \
        "${cpu_reqs[$i]}" \
        "${cpu_lims[$i]}" \
        "${mem_reqs[$i]}" \
        "${mem_lims[$i]}" \
        "${volumes_info[$i]}"
done

echo ""
echo "Примечания:"
echo "  - configmap:имя: ConfigMap том с указанным именем"
echo "  - secret:имя: Secret том с указанным именем"
echo "  - emptydir: временное хранилище (default - диск, Memory - RAM)"
echo "  - projected: том, объединяющий несколько источников (configMap, secret, downwardAPI)"
echo "  - none: томов не настроено"