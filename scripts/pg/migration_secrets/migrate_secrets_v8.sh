#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Функции для цветного вывода
print_error() { echo -e "${RED}✗ $1${NC}"; }
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ $1${NC}"; }
print_header() { echo -e "${PURPLE}=== $1 ===${NC}"; }
print_step() { echo -e "${CYAN}▶ $1${NC}"; }
print_debug() { 
    if [ "$DEBUG" = "true" ]; then
        echo -e "${YELLOW}🐛 DEBUG: $1${NC}"
    fi
}

# Переменные по умолчанию
DEBUG="false"
FILTER="postgres"  # По умолчанию postgres

# Парсинг аргументов командной строки
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --debug)
            DEBUG="true"
            shift
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done

# Восстанавливаем позиционные аргументы
set -- "${POSITIONAL_ARGS[@]}"

print_debug "DEBUG режим: $DEBUG"
print_debug "Все аргументы: $@"

# Скрипт для миграции секретов между кластерами Kubernetes
# Использование: ./migrate_secrets.sh <old_context> <new_context> <namespace> [project] [branch] [filter]

# Проверка аргументов
if [ $# -lt 3 ]; then
    print_error "Использование: $0 [--debug] <old_context> <new_context> <namespace> [project] [branch] [filter]"
    print_info "Пример (конкретный проект и ветка): $0 old-cluster new-cluster default pickup main"
    print_info "Пример (все секреты проекта): $0 old-cluster new-cluster default pickup"
    print_info "Пример (все секреты в неймспейсе): $0 old-cluster new-cluster default"
    print_info "Фильтры: postgres (по умолчанию), redis, app или любой другой"
    print_info "Доп. параметр: --debug для подробного вывода"
    exit 1
fi

OLD_CONTEXT=$1
NEW_CONTEXT=$2
NAMESPACE=$3
PROJECT=${4:-}  # Проект опционален
BRANCH=${5:-}  # Ветка опциональна
CUSTOM_FILTER=${6:-$FILTER}  # Кастомный фильтр или по умолчанию

print_debug "Старый контекст: $OLD_CONTEXT"
print_debug "Новый контекст: $NEW_CONTEXT"
print_debug "Неймспейс: $NAMESPACE"
print_debug "Проект: $PROJECT"
print_debug "Ветка: $BRANCH"
print_debug "Фильтр: $CUSTOM_FILTER"

# Определяем директорию где находится скрипт
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Создание структуры папок с датой и временем по новому шаблону
TIMESTAMP=$(date +"%Y%m%d-%H_%M")

# Определяем часть имени для ветки
if [ -n "$BRANCH" ]; then
    BRANCH_PART="$BRANCH"
elif [ -n "$PROJECT" ]; then
    BRANCH_PART="all"
else
    BRANCH_PART="all"
fi

# Формируем имя базовой папки по шаблону: <namespace>-<branch|all>-<filter>-<date>-<hh_mm>
BASE_DIR="${SCRIPT_DIR}/${NAMESPACE}-${BRANCH_PART}-${CUSTOM_FILTER}-${TIMESTAMP}"

OLD_SECRETS_DIR="$BASE_DIR/old_secrets"
NEW_SECRETS_DIR="$BASE_DIR/new_secrets"

print_step "Создание структуры папок..."
mkdir -pv "$OLD_SECRETS_DIR"
mkdir -pv "$NEW_SECRETS_DIR"

print_header "Конфигурация миграции"
echo -e "${CYAN}Старый контекст:${NC} $OLD_CONTEXT"
echo -e "${CYAN}Новый контекст:${NC} $NEW_CONTEXT"
echo -e "${CYAN}Неймспейс:${NC} $NAMESPACE"
echo -e "${CYAN}Проект:${NC} ${PROJECT:-'все проекты'}"
echo -e "${CYAN}Ветка:${NC} ${BRANCH:-'все ветки'}"
echo -e "${CYAN}Фильтр:${NC} $CUSTOM_FILTER"
echo -e "${CYAN}Базовая папка:${NC} $BASE_DIR"
echo ""

# Функция для извлечения ветки из имени секрета
extract_branch_from_name() {
    local secret_name=$1
    local branch=""
    
    # Паттерн: acid-<project>-<branch>-dbs
    if [[ $secret_name =~ acid-([^-]+)-([^-]+)-dbs ]]; then
        branch="${BASH_REMATCH[2]}"
        echo "$branch"
        return 0
    # Паттерн: acid-<project>-<branch> (без -dbs)
    elif [[ $secret_name =~ acid-([^-]+)-([^-]+) ]]; then
        branch="${BASH_REMATCH[2]}"
        echo "$branch"
        return 0
    else
        echo "unknown"
        return 1
    fi
}

# Функция для поиска всех секретов по фильтру в неймспейсе
find_all_secrets_by_filter() {
    local context=$1
    local namespace=$2
    local filter=$3
    
    print_header "Поиск секретов с фильтром '$filter' в неймспейсе $namespace"
    
    SECRETS_LIST=$(kubectl --context="$context" -n "$namespace" get secrets --no-headers 2>/dev/null | \
      awk '{print $1}' | \
      grep -E "$filter" | \
      sort) || true
    
    if [ -z "$SECRETS_LIST" ]; then
        print_error "Не найдено секретов с фильтром '$filter' в неймспейсе $namespace"
        return 1
    fi
    
    print_success "Найдены секреты:"
    echo "$SECRETS_LIST"
    echo ""
    return 0
}

# Функция для поиска секретов по проекту, ветке и фильтру
find_secrets_by_project_and_filter() {
    local context=$1
    local namespace=$2
    local project=$3
    local branch=$4
    local filter=$5
    
    print_header "Поиск секретов для проекта $project (фильтр: $filter) в неймспейсе $namespace"
    
    # Базовый паттерн для поиска
    local pattern=".*${project}.*"
    
    # Если указана ветка, добавляем ее в паттерн
    if [ -n "$branch" ]; then
        pattern=".*${project}.*${branch}.*"
    fi
    
    SECRETS_LIST=$(kubectl --context="$context" -n "$namespace" get secrets --no-headers 2>/dev/null | \
      awk '{print $1}' | \
      grep -E "$filter" | \
      grep -E "$pattern" | \
      sort) || true
    
    if [ -z "$SECRETS_LIST" ]; then
        print_error "Не найдено секретов для проекта '$project' с фильтром '$filter'"
        if [ -n "$branch" ]; then
            print_error "с веткой '$branch'"
        fi
        return 1
    fi
    
    print_success "Найдены секреты:"
    echo "$SECRETS_LIST"
    echo ""
    return 0
}

# Функция для генерации нового имени секрета
generate_new_secret_name() {
    local old_name=$1
    local filter=$2
    
    # Для postgres фильтра применяем трансформацию имени
    if [ "$filter" = "postgres" ]; then
        # Заменяем .acid- на .psql-
        local new_name="${old_name/.acid-/.psql-}"
        # Убираем -dbs.
        new_name="${new_name/-dbs./.}"
        echo "$new_name"
    else
        # Для других фильтров оставляем имя без изменений
        echo "$old_name"
    fi
}

# Функция для извлечения проекта и ветки из имени секрета
extract_project_branch_from_name() {
    local secret_name=$1
    local project=""
    local branch=""
    
    # Паттерн: acid-<project>-<branch>-dbs
    if [[ $secret_name =~ acid-([^-]+)-([^-]+)-dbs ]]; then
        project="${BASH_REMATCH[1]}"
        branch="${BASH_REMATCH[2]}"
        echo "$project $branch"
        return 0
    # Паттерн: acid-<project>-<branch> (без -dbs)
    elif [[ $secret_name =~ acid-([^-]+)-([^-]+) ]]; then
        project="${BASH_REMATCH[1]}"
        branch="${BASH_REMATCH[2]}"
        echo "$project $branch"
        return 0
    else
        return 1
    fi
}

# Функция для анализа секретов по веткам (совместимая со старыми версиями bash)
analyze_secrets_by_branches() {
    local secrets_dir=$1
    local file_type=$2
    local filter=$3
    
    print_header "Анализ $file_type секретов по веткам (фильтр: $filter)"
    
    # Используем временные файлы вместо ассоциативных массивов
    local temp_file=$(mktemp)
    local total_files=0
    
    # Считаем файлы по веткам
    for file in "$secrets_dir"/*."$file_type"; do
        if [ -f "$file" ]; then
            filename=$(basename "$file" ".$file_type")
            branch=$(extract_branch_from_name "$filename")
            echo "$branch" >> "$temp_file"
            ((total_files++))
        fi
    done
    
    if [ $total_files -eq 0 ]; then
        print_warning "Нет файлов для анализа"
        rm -f "$temp_file"
        return 1
    fi
    
    # Выводим статистику
    echo -e "${CYAN}Всего $file_type файлов:${NC} $total_files"
    echo ""
    echo -e "${YELLOW}Распределение по веткам:${NC}"
    
    # Сортируем и считаем уникальные ветки
    sort "$temp_file" | uniq -c | sort -rn | while read count branch; do
        percentage=$((count * 100 / total_files))
        echo -e "  ${GREEN}$branch:${NC} $count файлов ($percentage%)"
    done
    
    echo ""
    rm -f "$temp_file"
}

# Функция для сравнения пользователя и пароля
compare_credentials() {
    local old_secret_file=$1
    local new_secret_file=$2
    local old_secret_name=$3
    local new_secret_name=$4
    
    print_header "Сравнение пользователя и пароля"
    
    # Извлекаем username и password из старого секрета
    OLD_USERNAME=$(cat "$old_secret_file" | jq -r '.data.username' | base64 -d 2>/dev/null || echo "Ошибка декодирования")
    OLD_PASSWORD=$(cat "$old_secret_file" | jq -r '.data.password' | base64 -d 2>/dev/null || echo "Ошибка декодирования")
    
    # Извлекаем username и password из нового секрета
    NEW_USERNAME=$(cat "$new_secret_file" | yq eval '.data.username' - | base64 -d 2>/dev/null || echo "Ошибка декодирования")
    NEW_PASSWORD=$(cat "$new_secret_file" | yq eval '.data.password' - | base64 -d 2>/dev/null || echo "Ошибка декодирования")
    
    echo -e "${CYAN}Старый секрет ($old_secret_name):${NC}"
    echo -e "  ${YELLOW}Username:${NC} $OLD_USERNAME"
    echo -e "  ${YELLOW}Password:${NC} $OLD_PASSWORD"
    
    echo -e "${CYAN}Новый секрет ($new_secret_name):${NC}"
    echo -e "  ${YELLOW}Username:${NC} $NEW_USERNAME"
    echo -e "  ${YELLOW}Password:${NC} $NEW_PASSWORD"
    
    echo ""
    
    # Сравнение
    local user_match="✗"
    local pass_match="✗"
    
    if [ "$OLD_USERNAME" = "$NEW_USERNAME" ]; then
        user_match="✓"
    fi
    
    if [ "$OLD_PASSWORD" = "$NEW_PASSWORD" ]; then
        pass_match="✓"
    fi
    
    echo -e "${CYAN}Результат сравнения:${NC}"
    echo -e "  Username: $user_match"
    echo -e "  Password: $pass_match"
    
    if [ "$user_match" = "✓" ] && [ "$pass_match" = "✓" ]; then
        print_success "Данные пользователя и пароля совпадают!"
    else
        print_warning "Есть различия в данных!"
    fi
    echo ""
}

# Функция для миграции одного секрета
migrate_single_secret() {
    local old_secret_name=$1
    local new_secret_name=$2
    local filter=$3
    
    if [ "$DEBUG" = "true" ]; then
        print_header "Миграция: $old_secret_name -> $new_secret_name"
    else
        print_step "Миграция: $old_secret_name"
    fi
    
    # Имена файлов
    local old_secret_file="$OLD_SECRETS_DIR/${old_secret_name}.json"
    local new_secret_file="$NEW_SECRETS_DIR/${new_secret_name}.yaml"
    
    # Экспорт секрета из старого кластера
    if [ "$DEBUG" = "true" ]; then
        print_step "Экспорт секрета $old_secret_name..."
    fi
    kubectl --context="$OLD_CONTEXT" -n "$NAMESPACE" get secret "$old_secret_name" -o json > "$old_secret_file"
    
    # Проверка успешности экспорта
    if [ ! -s "$old_secret_file" ]; then
        print_error "Не удалось экспортировать секрет $old_secret_name"
        return 1
    fi
    
    if [ "$DEBUG" = "true" ]; then
        print_success "Секрет экспортирован в $old_secret_file"
    fi
    
    # Извлечение данных из старого секрета
    local secret_data=$(cat "$old_secret_file" | jq -c '.data')
    
    # Проверка что данные извлечены
    if [ -z "$secret_data" ] || [ "$secret_data" = "null" ]; then
        print_error "Не удалось извлечь данные из секрета $old_secret_name"
        return 1
    fi
    
    # Извлечение типа секрета
    local secret_type=$(cat "$old_secret_file" | jq -r '.type // "Opaque"')
    if [ "$secret_type" = "null" ]; then
        secret_type="Opaque"
    fi
    
    if [ "$DEBUG" = "true" ]; then
        print_debug "Тип секрета: $secret_type"
    fi
    
    # Создание нового секрета в формате YAML
    cat > "$new_secret_file" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: $new_secret_name
  namespace: $NAMESPACE
type: $secret_type
data: $secret_data
EOF
    
    if [ "$DEBUG" = "true" ]; then
        print_success "Новый секрет создан в $new_secret_file"
        
        # Вывод информации о секрете
        echo -e "${YELLOW}Ключи данных:${NC}"
        cat "$old_secret_file" | jq -r '.data | keys[]' | while read key; do
            echo -e "  ${GREEN}- $key${NC}"
        done
        echo -e "${YELLOW}Тип:${NC} $secret_type"
        
        # Извлекаем проект и ветку для информации
        if extract_project_branch_from_name "$old_secret_name" > /dev/null; then
            local project_branch=$(extract_project_branch_from_name "$old_secret_name")
            echo -e "${YELLOW}Проект/Ветка:${NC} $project_branch"
        fi
        echo ""
    fi
    
    return 0
}

# Основная логика поиска секретов в зависимости от параметров
if [ -z "$PROJECT" ]; then
    # Режим: все секреты в неймспейсе по фильтру
    print_info "РЕЖИМ: МИГРАЦИЯ ВСЕХ СЕКРЕТОВ С ФИЛЬТРОМ '$CUSTOM_FILTER' В НЕЙМСПЕЙСЕ $NAMESPACE"
    if ! find_all_secrets_by_filter "$OLD_CONTEXT" "$NAMESPACE" "$CUSTOM_FILTER"; then
        exit 1
    fi
else
    # Режим: конкретный проект (и возможно ветка) по фильтру
    if ! find_secrets_by_project_and_filter "$OLD_CONTEXT" "$NAMESPACE" "$PROJECT" "$BRANCH" "$CUSTOM_FILTER"; then
        exit 1
    fi
fi

# Миграция каждого найденного секрета
MIGRATED_COUNT=0
ERROR_COUNT=0
FIRST_OLD_SECRET=""
FIRST_NEW_SECRET=""

for OLD_SECRET_NAME in $SECRETS_LIST; do
    # Генерация нового имени
    NEW_SECRET_NAME=$(generate_new_secret_name "$OLD_SECRET_NAME" "$CUSTOM_FILTER")
    
    # Сохраняем первый секрет для сравнения
    if [ -z "$FIRST_OLD_SECRET" ]; then
        FIRST_OLD_SECRET="$OLD_SECRET_NAME"
        FIRST_NEW_SECRET="$NEW_SECRET_NAME"
    fi
    
    if migrate_single_secret "$OLD_SECRET_NAME" "$NEW_SECRET_NAME" "$CUSTOM_FILTER"; then
        ((MIGRATED_COUNT++))
        if [ "$DEBUG" = "false" ]; then
            echo -n "."
        fi
    else
        ((ERROR_COUNT++))
        if [ "$DEBUG" = "false" ]; then
            echo -n "!"
        fi
    fi
    
    if [ "$DEBUG" = "true" ]; then
        echo -e "${BLUE}----------------------------------------${NC}"
    fi
done

if [ "$DEBUG" = "false" ] && [ $MIGRATED_COUNT -gt 0 ]; then
    echo ""  # Новая строка после точек прогресса
fi

# Создание скрипта для применения всех секретов в папке new_secrets
print_step "Создание скрипта применения..."

APPLY_SCRIPT="$NEW_SECRETS_DIR/apply_secrets.sh"

cat > "$APPLY_SCRIPT" << EOF
#!/bin/bash
# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== Применение секретов в кластере $NEW_CONTEXT ===${NC}"
echo -e "${BLUE}Неймспейс: $NAMESPACE${NC}"
echo ""

APPLIED_COUNT=0
ERROR_COUNT=0

# Проверяем что мы в правильной папке
if [ ! -f "apply_secrets.sh" ]; then
    echo -e "${RED}Ошибка: Запускайте этот скрипт из папки new_secrets${NC}"
    exit 1
fi

for secret_file in *.yaml; do
    if [ -f "\$secret_file" ] && [ "\$secret_file" != "*.yaml" ]; then
        echo -e "${YELLOW}Применение секрета: \$secret_file${NC}"
        kubectl --context=$NEW_CONTEXT apply -f "\$secret_file"
        
        if [ \$? -eq 0 ]; then
            echo -e "${GREEN}✓ Успешно применен${NC}"
            ((APPLIED_COUNT++))
        else
            echo -e "${RED}✗ Ошибка при применении${NC}"
            ((ERROR_COUNT++))
        fi
        echo ""
    fi
done

echo -e "${BLUE}=== Итоги применения ===${NC}"
echo -e "${GREEN}Успешно применено: \$APPLIED_COUNT секретов${NC}"
echo -e "${RED}С ошибками: \$ERROR_COUNT секретов${NC}"

if [ \$ERROR_COUNT -eq 0 ] && [ \$APPLIED_COUNT -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}Проверка примененных секретов:${NC}"
    kubectl --context=$NEW_CONTEXT -n $NAMESPACE get secrets | grep -E "($CUSTOM_FILTER)" || echo -e "${YELLOW}Секреты не найдены${NC}"
fi
EOF

chmod +x "$APPLY_SCRIPT"
print_success "Скрипт для применения создан: $APPLY_SCRIPT"

# Вывод итогов миграции
echo ""
print_header "Итоги миграции"
echo -e "${GREEN}Успешно мигрировано: $MIGRATED_COUNT секретов${NC}"
if [ $ERROR_COUNT -gt 0 ]; then
    echo -e "${RED}С ошибками: $ERROR_COUNT секретов${NC}"
fi
echo ""

# Сравнение первого секрета если миграция прошла успешно
if [ $MIGRATED_COUNT -gt 0 ] && [ -n "$FIRST_OLD_SECRET" ]; then
    FIRST_OLD_FILE="$OLD_SECRETS_DIR/${FIRST_OLD_SECRET}.json"
    FIRST_NEW_FILE="$NEW_SECRETS_DIR/${FIRST_NEW_SECRET}.yaml"
    
    if [ -f "$FIRST_OLD_FILE" ] && [ -f "$FIRST_NEW_FILE" ]; then
        compare_credentials "$FIRST_OLD_FILE" "$FIRST_NEW_FILE" "$FIRST_OLD_SECRET" "$FIRST_NEW_SECRET"
    else
        print_warning "Не удалось найти файлы для сравнения первого секрета"
    fi
fi

# Анализ секретов по веткам (только в debug режиме или если есть файлы)
if [ "$DEBUG" = "true" ] || [ $MIGRATED_COUNT -gt 0 ]; then
    analyze_secrets_by_branches "$OLD_SECRETS_DIR" "json" "$CUSTOM_FILTER"
    analyze_secrets_by_branches "$NEW_SECRETS_DIR" "yaml" "$CUSTOM_FILTER"
fi

print_header "Структура созданных файлов"
echo -e "${CYAN}Директория скрипта:${NC} $SCRIPT_DIR"
echo -e "${CYAN}Создана папка миграции:${NC} $(basename "$BASE_DIR")"
echo -e "${PURPLE}$(basename "$BASE_DIR")/${NC}"
echo -e "${PURPLE}  ├── old_secrets/ ${YELLOW}(старые секреты в JSON)${NC}"
echo -e "${PURPLE}  └── new_secrets/ ${YELLOW}(новые секреты в YAML + скрипт применения)${NC}"
echo ""

# Проверка что файлы созданы (только в debug режиме)
if [ "$DEBUG" = "true" ]; then
    print_header "Проверка созданных файлов"
    echo -e "${CYAN}Папка старых секретов ($OLD_SECRETS_DIR):${NC}"
    ls -la "$OLD_SECRETS_DIR/" 2>/dev/null | head -10
    if [ $(ls -la "$OLD_SECRETS_DIR/" 2>/dev/null | wc -l) -gt 10 ]; then
        echo -e "${YELLOW}... (показано первые 10 файлов)${NC}"
    fi
    echo ""

    echo -e "${CYAN}Папка новых секретов ($NEW_SECRETS_DIR):${NC}"
    ls -la "$NEW_SECRETS_DIR/" 2>/dev/null | head -10
    if [ $(ls -la "$NEW_SECRETS_DIR/" 2>/dev/null | wc -l) -gt 10 ]; then
        echo -e "${YELLOW}... (показано первые 10 файлов)${NC}"
    fi
    echo ""
fi

if [ $MIGRATED_COUNT -gt 0 ]; then
    # Предложение применить секреты
    print_header "Действия"
    print_success "Миграция завершена успешно для $MIGRATED_COUNT секретов"
    print_info "Для применения секретов перейдите в папку новых секретов и выполните скрипт:"
    echo -e "  ${YELLOW}cd $NEW_SECRETS_DIR && ./apply_secrets.sh${NC}"
    echo ""

    read -p "$(echo -e ${YELLOW}'Перейти в папку новых секретов и применить секреты сейчас? (y/N): '${NC})" -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_step "Переход в папку $NEW_SECRETS_DIR..."
        cd "$NEW_SECRETS_DIR"
        print_step "Запуск скрипта применения..."
        ./apply_secrets.sh
    else
        echo ""
        print_info "Вы можете применить секреты позже:"
        echo -e "  ${YELLOW}cd $NEW_SECRETS_DIR && ./apply_secrets.sh${NC}"
    fi
else
    print_error "Нет секретов для применения"
fi