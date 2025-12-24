#!/bin/bash

NAMESPACE=${1:-default}
POD_PATTERN=${2:-""}  # Паттерн для фильтрации подов по имени
SEVERITY_FILTER=${3:-"all"}  # Фильтр по критичности: all, warning, error, normal

echo "Проверка событий (events) в неймспейсе: $NAMESPACE"
if [ ! -z "$POD_PATTERN" ]; then
  echo "Фильтр по имени пода: $POD_PATTERN"
fi
echo "Фильтр по критичности: $SEVERITY_FILTER"
echo "======================================================================"

# Функция для фильтрации событий по типу (TYPE)
filter_by_type() {
  local events="$1"
  local filter="$2"
  
  case $filter in
    "warning")
      # Только события с TYPE=Warning
      echo "$events" | awk 'NR==1 || $2 == "Warning"'
      ;;
    "error")
      # Только критические события - фильтруем по REASON
      echo "$events" | awk 'NR==1 || $3 ~ /^(Failed|BackOff|CrashLoopBackOff|Error|Unrecoverable)$/'
      ;;
    "normal")
      # Только события с TYPE=Normal
      echo "$events" | awk 'NR==1 || $2 == "Normal"'
      ;;
    "all")
      echo "$events"
      ;;
    *)
      echo "$events"
      ;;
  esac
}

# Функция для фильтрации событий по REASON (для анализа)
filter_by_reason() {
  local events="$1"
  local reason="$2"
  
  if [ "$reason" = "all" ]; then
    echo "$events"
  else
    echo "$events" | awk -v reason="$reason" 'NR==1 || $3 == reason'
  fi
}

# Получаем все поды в неймспейсе
ALL_PODS=$(kubectl get pods -n $NAMESPACE -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

# Если задан паттерн, фильтруем поды
if [ ! -z "$POD_PATTERN" ]; then
  PODS=""
  for pod in $ALL_PODS; do
    if echo "$pod" | grep -qi "$POD_PATTERN"; then
      PODS="$PODS $pod"
    fi
  done
else
  PODS=$ALL_PODS
fi

# Получаем все события в неймспейсе
echo "Получение событий..."
ALL_EVENTS=$(kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null)

# Проверяем, есть ли события
if echo "$ALL_EVENTS" | grep -q "No resources found" || [ -z "$ALL_EVENTS" ] || [ "$(echo "$ALL_EVENTS" | wc -l)" -le 1 ]; then
  echo "Событий не найдено в неймспейсе $NAMESPACE"
else
  echo "События в неймспейсе (фильтр: $SEVERITY_FILTER):"
  echo "----------------------------------------"
  
  # Применяем фильтр по критичности
  FILTERED_EVENTS=$(filter_by_type "$ALL_EVENTS" "$SEVERITY_FILTER")
  
  if [ -z "$FILTERED_EVENTS" ] || [ "$(echo "$FILTERED_EVENTS" | wc -l)" -le 1 ]; then
    echo "Событий с фильтром '$SEVERITY_FILTER' не найдено"
  else
    echo "$FILTERED_EVENTS"
    
    # Статистика по всем событиям
    TOTAL_EVENTS=$(($(echo "$ALL_EVENTS" | wc -l) - 1))
    WARNING_COUNT=$(echo "$ALL_EVENTS" | awk '$2 == "Warning"' | wc -l)
    NORMAL_COUNT=$(echo "$ALL_EVENTS" | awk '$2 == "Normal"' | wc -l)
    
    # Для фильтра error считаем по-другому
    if [ "$SEVERITY_FILTER" = "error" ]; then
      ERROR_COUNT=$(echo "$ALL_EVENTS" | awk '$3 ~ /^(Failed|BackOff|CrashLoopBackOff|Error|Unrecoverable)$/' | wc -l)
      echo ""
      echo "📊 Статистика событий (фильтр: $SEVERITY_FILTER):"
      echo "   Всего событий: $TOTAL_EVENTS"
      echo "   ⚠️  Warning: $WARNING_COUNT"
      echo "   ℹ️  Normal: $NORMAL_COUNT"
      echo "   🔴 Критические ошибки: $ERROR_COUNT"
    else
      echo ""
      echo "📊 Общая статистика событий:"
      echo "   Всего событий: $TOTAL_EVENTS"
      echo "   ⚠️  Warning: $WARNING_COUNT"
      echo "   ℹ️  Normal: $NORMAL_COUNT"
    fi
    
    # Анализ самых частых причин Warning событий
    if [ "$WARNING_COUNT" -gt 0 ]; then
      echo ""
      echo "🔍 Анализ Warning событий:"
      
      # Получаем уникальные REASON из Warning событий
      WARNING_REASONS=$(echo "$ALL_EVENTS" | awk '$2 == "Warning" {print $3}' | sort | uniq -c | sort -rn)
      
      if [ ! -z "$WARNING_REASONS" ]; then
        echo "Частые причины Warning событий:"
        echo "$WARNING_REASONS" | head -10 | while read count reason; do
          if [ ! -z "$reason" ]; then
            # Определяем критичность причины
            case $reason in
              Failed|BackOff|CrashLoopBackOff|Error|Unrecoverable)
                severity="🔴 КРИТИЧЕСКАЯ"
                ;;
              Unhealthy|FailedMount|FailedScheduling)
                severity="🟡 ВАЖНО"
                ;;
              *)
                severity="🟢 ИНФО"
                ;;
            esac
            echo "   $severity $reason: $count"
          fi
        done
      fi
    fi
  fi
fi

echo ""
echo "======================================================================"

# Если есть поды для анализа
if [ ! -z "$PODS" ]; then
  echo "Анализ событий по подам (фильтр: $SEVERITY_FILTER):"
  echo "======================================================================"

  for pod in $PODS; do
    echo ""
    echo "🔍 Pod: $pod"
    echo "----------------------------------------"
    
    # Получить статус пода
    pod_phase=$(kubectl get pod $pod -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    echo "  Статус: $pod_phase"
    
    # Получить события для конкретного пода
    pod_events=$(kubectl get events -n $NAMESPACE --field-selector involvedObject.name=$pod,involvedObject.kind=Pod --sort-by='.lastTimestamp' 2>/dev/null)
    
    # Проверяем, есть ли события
    if echo "$pod_events" | grep -q "No resources found" || [ -z "$pod_events" ] || [ "$(echo "$pod_events" | wc -l)" -le 1 ]; then
      echo "  ℹ️  Событий для пода не найдено"
    else
      # Применяем фильтр по критичности
      FILTERED_POD_EVENTS=$(filter_by_type "$pod_events" "$SEVERITY_FILTER")
      
      if [ -z "$FILTERED_POD_EVENTS" ] || [ "$(echo "$FILTERED_POD_EVENTS" | wc -l)" -le 1 ]; then
        echo "  ℹ️  Событий с фильтром '$SEVERITY_FILTER' не найдено"
        
        # Для фильтра error показываем критические события, даже если их нет в основном выводе
        if [ "$SEVERITY_FILTER" = "error" ]; then
          CRITICAL_EVENTS=$(echo "$pod_events" | awk '$3 ~ /^(Failed|BackOff|CrashLoopBackOff|Error|Unrecoverable)$/')
          if [ ! -z "$CRITICAL_EVENTS" ] && [ "$(echo "$CRITICAL_EVENTS" | wc -l)" -gt 0 ]; then
            echo "  🔴 Критические события для пода:"
            echo "$CRITICAL_EVENTS" | sed 's/^/    /'
          fi
        fi
      else
        # Счетчики по типам событий
        warning_count=$(echo "$FILTERED_POD_EVENTS" | awk '$2 == "Warning"' | wc -l)
        normal_count=$(echo "$FILTERED_POD_EVENTS" | awk '$2 == "Normal"' | wc -l)
        total_events=$(($warning_count + $normal_count))
        
        echo "  📊 Статистика событий (фильтр: $SEVERITY_FILTER):"
        echo "    Всего событий: $total_events"
        echo "    ⚠️  Warning: $warning_count"
        echo "    ℹ️  Normal: $normal_count"
        echo ""
        
        # Для фильтра error показываем только критические события
        if [ "$SEVERITY_FILTER" = "error" ]; then
          CRITICAL_EVENTS=$(echo "$FILTERED_POD_EVENTS" | awk '$3 ~ /^(Failed|BackOff|CrashLoopBackOff|Error|Unrecoverable)$/')
          if [ ! -z "$CRITICAL_EVENTS" ]; then
            critical_count=$(echo "$CRITICAL_EVENTS" | wc -l)
            echo "  🔴 Критические ошибки: $critical_count"
            echo "$CRITICAL_EVENTS" | head -10 | sed 's/^/    /'
          fi
        else
          # Показать последние Warning события (если есть)
          if [ "$warning_count" -gt "0" ]; then
            echo "  ⚠️  Последние Warning события:"
            echo "$FILTERED_POD_EVENTS" | awk '$2 == "Warning"' | head -5 | sed 's/^/    /'
          fi
          
          # Показать последние Normal события (если есть)
          if [ "$normal_count" -gt "0" ] && [ "$SEVERITY_FILTER" != "warning" ]; then
            echo "  ℹ️  Последние Normal события:"
            echo "$FILTERED_POD_EVENTS" | awk '$2 == "Normal"' | head -3 | sed 's/^/    /'
          fi
        fi
      fi
    fi
    
    # Дополнительная информация о статусе пода
    echo ""
    echo "  🔧 Детальный статус пода:"
    pod_status=$(kubectl get pod $pod -n $NAMESPACE -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}' 2>/dev/null)
    if [ ! -z "$pod_status" ]; then
      echo "$pod_status" | sed 's/^/    /'
    fi
    
    # Проверить рестарты контейнеров
    restarts=$(kubectl get pod $pod -n $NAMESPACE -o jsonpath='{.status.containerStatuses[*].restartCount}' 2>/dev/null | awk '{for(i=1;i<=NF;i++) sum+=$i} END{print sum}')
    if [ ! -z "$restarts" ] && [ "$restarts" -gt "0" ]; then
      echo "  🔄 Всего рестартов контейнеров: $restarts"
      
      # Если есть рестарты, проверяем наличие CrashLoopBackOff
      if kubectl get events -n $NAMESPACE --field-selector involvedObject.name=$pod,involvedObject.kind=Pod 2>/dev/null | grep -q "CrashLoopBackOff"; then
        echo "  🔴 Обнаружен CrashLoopBackOff!"
      fi
    fi
  done
fi

echo ""
echo "======================================================================"

# Анализ всех событий по паттерну (если указан)
if [ ! -z "$POD_PATTERN" ]; then
  echo "Анализ событий для объектов с паттерном '$POD_PATTERN' (фильтр: $SEVERITY_FILTER):"
  echo "======================================================================"
  
  # Ищем события, связанные с объектами, содержащими паттерн в имени
  PATTERN_EVENTS=$(echo "$ALL_EVENTS" | grep -i "$POD_PATTERN")
  
  if [ ! -z "$PATTERN_EVENTS" ] && [ "$(echo "$PATTERN_EVENTS" | wc -l)" -gt 1 ]; then
    # Применяем фильтр по критичности
    FILTERED_PATTERN_EVENTS=$(filter_by_type "$PATTERN_EVENTS" "$SEVERITY_FILTER")
    
    if [ -z "$FILTERED_PATTERN_EVENTS" ] || [ "$(echo "$FILTERED_PATTERN_EVENTS" | wc -l)" -le 1 ]; then
      echo "Событий с паттерном '$POD_PATTERN' и фильтром '$SEVERITY_FILTER' не найдено"
      
      # Для фильтра error показываем критические события отдельно
      if [ "$SEVERITY_FILTER" = "error" ]; then
        CRITICAL_PATTERN_EVENTS=$(echo "$PATTERN_EVENTS" | awk '$3 ~ /^(Failed|BackOff|CrashLoopBackOff|Error|Unrecoverable)$/')
        if [ ! -z "$CRITICAL_PATTERN_EVENTS" ] && [ "$(echo "$CRITICAL_PATTERN_EVENTS" | wc -l)" -gt 0 ]; then
          echo ""
          echo "🔴 Критические ошибки для объектов с паттерном '$POD_PATTERN':"
          echo "$CRITICAL_PATTERN_EVENTS" | head -10 | sed 's/^/  /'
        fi
      fi
    else
      pattern_count=$(($(echo "$FILTERED_PATTERN_EVENTS" | wc -l) - 1))
      echo "Найдено событий: $pattern_count"
      echo ""
      
      # Показываем события по паттерну
      echo "$FILTERED_PATTERN_EVENTS"
      
      # Для фильтра error дополнительная информация
      if [ "$SEVERITY_FILTER" = "error" ]; then
        CRITICAL_COUNT=$(echo "$FILTERED_PATTERN_EVENTS" | awk '$3 ~ /^(Failed|BackOff|CrashLoopBackOff|Error|Unrecoverable)$/' | wc -l)
        if [ "$CRITICAL_COUNT" -gt 0 ]; then
          echo ""
          echo "🔴 Критических ошибок: $CRITICAL_COUNT"
        fi
      fi
    fi
  else
    echo "Событий для объектов с паттерном '$POD_PATTERN' не найдено"
  fi
fi

echo ""
echo "======================================================================"
echo "Рекомендации по диагностике:"
echo "======================================================================"

echo "  📋 Команды для проверки:"
echo "    1. Все события: kubectl get events -n $NAMESPACE"
echo "    2. Только Warning: kubectl get events -n $NAMESPACE --field-selector type=Warning"
echo "    3. Только для пода: kubectl describe pod <pod-name> -n $NAMESPACE"

# Проверка на наличие проблем
if [ "$WARNING_COUNT" -gt 0 ]; then
  echo ""
  echo "  ⚠️  Обнаружены проблемы:"
  
  # Проверяем конкретные типы проблем по REASON
  CRITICAL_REASONS=$(echo "$ALL_EVENTS" | awk '$3 ~ /^(Failed|BackOff|CrashLoopBackOff|Error|Unrecoverable)$/' | awk '{print $3}' | sort -u)
  WARNING_REASONS=$(echo "$ALL_EVENTS" | awk '$3 ~ /^(Unhealthy|FailedMount|FailedScheduling|FailedAttachVolume)$/' | awk '{print $3}' | sort -u)
  
  if [ ! -z "$CRITICAL_REASONS" ]; then
    echo "    🔴 Критические ошибки:"
    for reason in $CRITICAL_REASONS; do
      echo "      • $reason"
    done
  fi
  
  if [ ! -z "$WARNING_REASONS" ]; then
    echo "    🟡 Важные предупреждения:"
    for reason in $WARNING_REASONS; do
      echo "      • $reason"
    done
  fi
else
  echo ""
  echo "  ✅ Критических проблем не обнаружено"
fi

echo ""
echo "======================================================================"
echo "Проверка завершена"