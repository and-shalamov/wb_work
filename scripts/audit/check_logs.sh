#!/bin/bash

NAMESPACE=${1:-default}
SINCE=${2:-1h}

echo "Проверка логов в неймспейсе: $NAMESPACE за период: $SINCE"
echo "======================================================"

for pod in $(kubectl get pods -n $NAMESPACE --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}'); do
  echo ""
  echo "🔍 Pod: $pod"
  echo "----------------------------------------"
  
  # Получить список контейнеров в поде
  containers=$(kubectl get pod $pod -n $NAMESPACE -o jsonpath='{.spec.containers[*].name}')
  
  for container in $containers; do
    echo "  Container: $container"
    
    # Получить логи с фильтрацией
    logs=$(kubectl logs -n $NAMESPACE $pod -c $container --since=$SINCE 2>/dev/null)
    
    # Поиск ошибок
    errors=$(echo "$logs" | grep -i -E "error|failed|exception|panic|critical|fatal" | head -10)
    
    if [ ! -z "$errors" ]; then
      echo "  ❌ Найдены ошибки:"
      echo "$errors" | sed 's/^/    /'
      
      # Посчитать количество ошибок
      count=$(echo "$errors" | wc -l)
      echo "    Всего ошибок: $count"
    else
      echo "  ✅ Ошибок не найдено"
    fi
    
    # Проверить рестарты контейнера
    restarts=$(kubectl get pod $pod -n $NAMESPACE -o jsonpath='{.status.containerStatuses[?(@.name=="'$container'")].restartCount}')
    if [ "$restarts" -gt "0" ]; then
      echo "  ⚠️  Контейнер перезапускался: $restarts раз"
      
      # Посмотреть логи предыдущего запуска
      echo "  Логи предыдущего запуска:"
      kubectl logs -n $NAMESPACE $pod -c $container --previous --since=$SINCE 2>/dev/null | \
        grep -i -E "error|failed|exception" | head -5 | sed 's/^/    /'
    fi
  done
done

echo ""
echo "======================================================"
echo "Проверка завершена"