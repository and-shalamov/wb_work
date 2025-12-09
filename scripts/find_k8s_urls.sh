#!/bin/bash

# Скрипт для поиска строки в Ingress, Service, Secret и ConfigMap ресурсах Kubernetes
# Использование: ./find_k8s_resources.sh <namespace> <искомая_строка>

set -euo pipefail

# Проверка аргументов
if [ $# -ne 2 ]; then
    echo "Ошибка: Необходимо указать namespace и искомую строку"
    echo "Использование: $0 <namespace> <искомая_строка>"
    exit 1
fi

NAMESPACE="$1"
SEARCH_STRING="$2"
FOUND_RESOURCES=0

# Проверка доступности namespace
if ! kubectl get namespace "$NAMESPACE" > /dev/null 2>&1; then
    echo "❌ Ошибка: Namespace '$NAMESPACE' не существует или недоступен"
    exit 1
fi

echo "🔍 Поиск строки '$SEARCH_STRING' в namespace '$NAMESPACE'"
echo "=========================================================="

# Функция для поиска в ресурсах
search_in_resource() {
    local resource_type="$1"
    local search_string="$2"
    local namespace="$3"
    local count=0
    
    echo -e "\n📋 Поиск в $resource_type..."
    echo "----------------------------------------------"
    
    # Получаем список ресурсов
    local resources
    resources=$(kubectl get "$resource_type" -n "$namespace" -o name 2>/dev/null || echo "")
    
    if [ -z "$resources" ]; then
        echo "   (ресурсы $resource_type не найдены или недоступны)"
        return 0
    fi
    
    # Проходим по каждому ресурсу
    while IFS= read -r resource; do
        if [ -n "$resource" ]; then
            local resource_name=${resource#*/}
            local yaml_content=""
            local found_in_resource=false
            
            # Для секретов
            if [ "$resource_type" = "secret" ]; then
                # Получаем секрет и декодируем данные
                local secret_data
                secret_data=$(kubectl get secret "$resource_name" -n "$namespace" -o json 2>/dev/null || echo "{}")
                
                # Проверяем наличие строки в именах ключей
                if echo "$resource_name" | grep -qi "$search_string"; then
                    found_in_resource=true
                fi
                
                # Проверяем в данных секрета (декодированных)
                local keys
                keys=$(echo "$secret_data" | jq -r '.data | keys[]' 2>/dev/null || echo "")
                
                for key in $keys; do
                    # Проверяем имя ключа
                    if echo "$key" | grep -qi "$search_string"; then
                        found_in_resource=true
                    fi
                    
                    # Проверяем значение (декодированное)
                    local encoded_value
                    encoded_value=$(echo "$secret_data" | jq -r --arg key "$key" '.data[$key]' 2>/dev/null)
                    if [ -n "$encoded_value" ] && [ "$encoded_value" != "null" ]; then
                        local decoded_value
                        decoded_value=$(echo "$encoded_value" | base64 --decode 2>/dev/null || echo "")
                        if echo "$decoded_value" | grep -qi "$search_string"; then
                            found_in_resource=true
                        fi
                    fi
                done
                
                yaml_content="$secret_data"
            else
                # Для остальных ресурсов
                yaml_content=$(kubectl get "$resource_type" "$resource_name" -n "$namespace" -o yaml 2>/dev/null)
                if [ -n "$yaml_content" ] && echo "$yaml_content" | grep -qi "$search_string"; then
                    found_in_resource=true
                fi
            fi
            
            if [ "$found_in_resource" = true ]; then
                echo "✅ Найдено в $resource_type: $resource_name"
                ((count++))
                ((FOUND_RESOURCES++))
                
                # Для разных типов ресурсов разная дополнительная информация
                case "$resource_type" in
                    "ingress")
                        echo "   Правила маршрутизации:"
                        local hosts
                        hosts=$(kubectl get ingress "$resource_name" -n "$namespace" -o jsonpath='{range .spec.rules[*]}{.host}{"\n"}{end}' 2>/dev/null)
                        if [ -n "$hosts" ]; then
                            echo "$hosts" | while IFS= read -r host; do
                                echo "     • Host: $host"
                            done
                        fi
                        
                        # TLS хосты
                        local tls_hosts
                        tls_hosts=$(kubectl get ingress "$resource_name" -n "$namespace" -o jsonpath='{.spec.tls[*].hosts[*]}' 2>/dev/null)
                        if [ -n "$tls_hosts" ]; then
                            echo "   TLS хосты:"
                            for host in $tls_hosts; do
                                echo "     • $host"
                            done
                        fi
                        ;;
                        
                    "service")
                        local service_type
                        service_type=$(kubectl get service "$resource_name" -n "$namespace" -o jsonpath='{.spec.type}' 2>/dev/null || echo "Unknown")
                        echo "   Тип сервиса: $service_type"
                        
                        if [ "$service_type" = "LoadBalancer" ]; then
                            local external_ip
                            external_ip=$(kubectl get service "$resource_name" -n "$namespace" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
                            local external_host
                            external_host=$(kubectl get service "$resource_name" -n "$namespace" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
                            
                            if [ -n "$external_ip" ]; then
                                echo "   Внешний IP: $external_ip"
                            elif [ -n "$external_host" ]; then
                                echo "   Внешний хост: $external_host"
                            fi
                        fi
                        
                        # Порт и таргет
                        echo "   Порты:"
                        kubectl get service "$resource_name" -n "$namespace" -o jsonpath='{range .spec.ports[*]}{.port}{"->"}{.targetPort}{"/"}{.protocol}{"\n"}{end}' 2>/dev/null | while IFS= read -r port; do
                            if [ -n "$port" ]; then
                                echo "     • $port"
                            fi
                        done
                        ;;
                        
                    "secret")
                        local secret_type
                        secret_type=$(kubectl get secret "$resource_name" -n "$namespace" -o jsonpath='{.type}' 2>/dev/null || echo "Unknown")
                        echo "   Тип секрета: $secret_type"
                        
                        # Ключи в секрете
                        echo "   Ключи в секрете:"
                        local keys
                        keys=$(kubectl get secret "$resource_name" -n "$namespace" -o jsonpath='{.data}' 2>/dev/null | jq -r 'keys[]' 2>/dev/null || echo "")
                        if [ -n "$keys" ]; then
                            echo "$keys" | while IFS= read -r key; do
                                echo "     • $key"
                            done
                        else
                            echo "     (нет данных или jq не установлен)"
                        fi
                        ;;
                        
                    "configmap")
                        # Ключи в конфигмапе
                        echo "   Ключи в ConfigMap:"
                        local keys
                        keys=$(kubectl get configmap "$resource_name" -n "$namespace" -o jsonpath='{.data}' 2>/dev/null | jq -r 'keys[]' 2>/dev/null || echo "")
                        if [ -n "$keys" ]; then
                            echo "$keys" | while IFS= read -r key; do
                                echo "     • $key"
                            done
                        else
                            local cm_data
                            cm_data=$(kubectl get configmap "$resource_name" -n "$namespace" -o jsonpath='{.data}' 2>/dev/null)
                            if [ -n "$cm_data" ] && [ "$cm_data" != "map[]" ]; then
                                echo "     (используйте jq для отображения ключей)"
                            else
                                echo "     (нет данных)"
                            fi
                        fi
                        ;;
                esac
                
                # Показываем простые совпадения без подсветки
                echo "   Совпадения в метаданных:"
                if [ "$resource_type" = "secret" ]; then
                    # Для секретов ищем в имени
                    if echo "$resource_name" | grep -qi "$search_string"; then
                        echo "     • Имя ресурса содержит '$SEARCH_STRING'"
                    fi
                else
                    # Для других ресурсов ищем в YAML
                    local matches
                    matches=$(echo "$yaml_content" | grep -i "$search_string" | head -3)
                    if [ -n "$matches" ]; then
                        echo "$matches" | while IFS= read -r match; do
                            # Обрезаем длинные строки
                            if [ ${#match} -gt 80 ]; then
                                match="${match:0:77}..."
                            fi
                            echo "     • $match"
                        done
                    fi
                fi
                
                echo ""
            fi
        fi
    done <<< "$resources"
    
    if [ "$count" -eq 0 ]; then
        echo "   (совпадений не найдено)"
    fi
}

# Проверяем наличие jq для работы с JSON
if ! command -v jq &> /dev/null; then
    echo "⚠️  Внимание: jq не установлен. Некоторые функции могут работать ограниченно."
    echo "   Установите: apt-get install jq или yum install jq"
    echo ""
fi

# Выполняем поиск по всем типам ресурсов
search_in_resource "ingress" "$SEARCH_STRING" "$NAMESPACE"
search_in_resource "service" "$SEARCH_STRING" "$NAMESPACE"
search_in_resource "secret" "$SEARCH_STRING" "$NAMESPACE"
search_in_resource "configmap" "$SEARCH_STRING" "$NAMESPACE"

# Итоговый вывод
echo "=========================================================="
if [ "$FOUND_RESOURCES" -eq 0 ]; then
    echo "❌ Строка '$SEARCH_STRING' не найдена в ресурсах namespace '$NAMESPACE'"
    echo "💡 Проверенные типы ресурсов: Ingress, Service, Secret, ConfigMap"
    exit 2
else
    echo "🎉 Найдено совпадений в $FOUND_RESOURCES ресурсах"
    echo "📊 Типы проверенных ресурсов:"
    echo "   • Ingress (правила маршрутизации)"
    echo "   • Service (внешние endpoints)"
    echo "   • Secret (декодированные данные)"
    echo "   • ConfigMap (конфигурации)"
    exit 0
fi