#!/usr/bin/env bash
# odata.sh - клиент стандартного интерфейса OData 1С:Предприятия (bash + curl).
#
# Работает в Linux, macOS и Git Bash под Windows. Параметры подключения
# берутся из env-файла профиля, пароль не попадает ни в командную строку, ни в вывод.
# Справка: odata.sh help

set -euo pipefail

VERSION="0.1.0"

usage() {
    cat <<'EOF'
odata.sh [-p ПРОФИЛЬ | -e ENV-ФАЙЛ] [--snapshot-id ИД] КОМАНДА [АРГУМЕНТЫ]

--snapshot-id ИД   идентификатор снимка метаданных, под который снят кеш $metadata и списка
                   наборов (смысл задает вызывающий: хеш коммита, номер версии и т. п.).
                   Отличается от сохраненного - кеш скачивается заново. Без ключа кеш
                   обновляется только через meta ... --refresh.

Команды:
  info                       адрес публикации профиля (без пароля) и проверка доступа
  sets [REGEX]               опубликованные наборы сущностей, отбор по регулярному выражению
  meta ИМЯ [--refresh]       ключи, свойства, навигация и функции типа сущности из $metadata
  get РЕСУРС [ОПЦИИ]         GET-запрос к ресурсу
  count РЕСУРС [--filter F]  количество записей ($count)
  write МЕТОД РЕСУРС [--body ФАЙЛ] [--if-match ВЕРСИЯ] [--load-mode] --confirmed
                             POST | PATCH | PUT | DELETE; только после подтверждения пользователя
  link НАБОР [GUID]          навигационная ссылка 1С на объект (с GUID) или на список (без GUID),
                             при заданном ONEC_WEB_URL - и ссылка веб-клиента

Опции get:
  --filter ВЫРАЖЕНИЕ   --select СПИСОК   --expand СПИСОК   --orderby СПИСОК
  --top N   --skip N   --inlinecount   --allowed-only
  --param ИМЯ=ЗНАЧЕНИЕ   произвольный параметр запроса (например, Condition=... для SliceLast)
  --meta none|minimal|full   объем служебных полей json (по умолчанию none)
  --xml                формат atom-xml вместо json
  --out ФАЙЛ           сохранить тело ответа в файл
  --max-print БАЙТ     тело больше порога пишется в файл, в вывод - начало (по умолчанию 20000)

РЕСУРС и значения опций передаются как есть, с кириллицей, пробелами и $:
кодирование URL скрипт делает сам.

Профиль -p ИМЯ: <корень git-репозитория текущего каталога>/.onec-odata/ИМЯ.env,
каталог исключен из git.
Без -p и -e: $ONEC_ODATA_PROFILE, затем уже заданные переменные ONEC_*, затем профиль default.
Профиль внутри рабочего дерева git, не исключенный из него, не читается.
Переменные профиля (описание - README skill):
  обязательные   ONEC_SERVER, ONEC_PUBLICATION, ONEC_USER, ONEC_PASSWORD;
  необязательные ONEC_TIMEOUT (с, по умолчанию 120), ONEC_READONLY=1 (запрет write),
                 ONEC_OUT_DIR (каталог результатов и кеша, по умолчанию $TMPDIR/onec-odata),
                 ONEC_LINKS=off|on-request|always (ссылки на объекты в ответах, по умолчанию on-request),
                 ONEC_WEB_URL (адрес веб-клиента для внешних ссылок).
EOF
}

die() { printf 'odata.sh: %s\n' "$*" >&2; exit 2; }


# Percent-кодирование UTF-8 по байтам. Второй аргумент - символы, которые оставить как есть.
urlenc() {
    local LC_ALL=C s="$1" safe="${2-}" out="" c h i
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9._~-]) out+="$c" ;;
            *)
                if [[ -n "$safe" && "$safe" == *"$c"* ]]; then
                    out+="$c"
                else
                    printf -v h '%%%02X' "'$c"
                    out+="${h: -3}"
                fi
                ;;
        esac
    done
    printf '%s' "$out"
}

# --- разбор глобальных ключей ---------------------------------------------

PROFILE="${ONEC_ODATA_PROFILE-}"
ENV_FILE=""
SNAPSHOT_ID=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--profile) PROFILE="$2"; shift 2 ;;
        -e|--env) ENV_FILE="$2"; shift 2 ;;
        --snapshot-id) SNAPSHOT_ID="$2"; shift 2 ;;
        -h|--help|help) usage; exit 0 ;;
        --version) echo "$VERSION"; exit 0 ;;
        *) break ;;
    esac
done
[[ $# -gt 0 ]] || { usage; exit 2; }
CMD="$1"; shift

# Файл профиля по имени: <корень git-репозитория текущего каталога>/.onec-odata/ИМЯ.env.
find_profile() {
    local name="$1" top f
    top="$(git rev-parse --show-toplevel 2>/dev/null)" \
        || die "профиль '$name' не найден: текущий каталог не в git-репозитории, запустите скрипт из каталога проекта или укажите -e ФАЙЛ"
    f="$top/.onec-odata/$name.env"
    [[ -f "$f" ]] || die "профиль '$name' не найден: нет файла $f (см. README skill, раздел о профилях)"
    printf '%s' "$f"
}

# Профиль с паролем не должен попасть в коммит: внутри рабочего дерева git он обязан быть исключен.
check_not_tracked() {
    local f="$1" dir
    command -v git >/dev/null 2>&1 || return 0
    dir="$(cd "$(dirname "$f")" && pwd)"
    git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
    git -C "$dir" check-ignore -q "$f" && return 0
    die "файл профиля $f лежит в рабочем дереве git и не исключен из него: добавьте каталог в .gitignore"
}

if [[ -z "$ENV_FILE" ]]; then
    if [[ -n "$PROFILE" ]]; then
        ENV_FILE="$(find_profile "$PROFILE")"
    elif [[ -z "${ONEC_SERVER-}" ]]; then
        PROFILE="default"
        ENV_FILE="$(find_profile default)"
    fi
fi
if [[ -n "$ENV_FILE" ]]; then
    [[ -f "$ENV_FILE" ]] || die "нет файла профиля $ENV_FILE"
    check_not_tracked "$ENV_FILE"
fi


# --- загрузка профиля -------------------------------------------------------

if [[ -n "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    . <(tr -d '\r' < "$ENV_FILE")
    set +a
fi
for v in ONEC_SERVER ONEC_PUBLICATION ONEC_USER ONEC_PASSWORD; do
    [[ -n "${!v-}" ]] || die "в профиле не задана переменная $v"
done
TIMEOUT="${ONEC_TIMEOUT:-120}"
LINKS_MODE="${ONEC_LINKS:-on-request}"
case "$LINKS_MODE" in off|on-request|always) ;; *) die "ONEC_LINKS должен быть off, on-request или always, а не '$LINKS_MODE'" ;; esac
OUT_DIR="${ONEC_OUT_DIR:-${TMPDIR:-/tmp}/onec-odata}"
BASE="${ONEC_SERVER%/}/$(urlenc "${ONEC_PUBLICATION#/}" "/")/odata/standard.odata"
# Кеш - по имени профиля; при -e без -p - по имени файла, без профиля - по публикации.
CACHE_NAME="${PROFILE:-}"
[[ -n "$CACHE_NAME" || -z "$ENV_FILE" ]] || CACHE_NAME="$(basename "$ENV_FILE" .env)"
CACHE_DIR="$OUT_DIR/cache/$(urlenc "${CACHE_NAME:-$ONEC_PUBLICATION}" "")"
mkdir -p "$OUT_DIR" "$CACHE_DIR"

# Кеш снят под другой снимок метаданных - сбрасываем, он скачается заново при обращении.
CACHED_SNAPSHOT_ID="$(cat "$CACHE_DIR/snapshot-id" 2>/dev/null || true)"
if [[ -n "$SNAPSHOT_ID" && "$SNAPSHOT_ID" != "$CACHED_SNAPSHOT_ID" ]]; then
    rm -f "$CACHE_DIR/metadata.xml" "$CACHE_DIR/sets.txt"
    printf '%s' "$SNAPSHOT_ID" > "$CACHE_DIR/snapshot-id"
    [[ -n "$CACHED_SNAPSHOT_ID" ]] && printf 'кеш сброшен: идентификатор снимка %s -> %s\n' "$CACHED_SNAPSHOT_ID" "$SNAPSHOT_ID" >&2
    CACHED_SNAPSHOT_ID="$SNAPSHOT_ID"
fi

# --- HTTP ------------------------------------------------------------------

LAST_CODE=""
LAST_BODY=""

# http МЕТОД URL ФАЙЛ-ТЕЛА [заголовки...]; тело ответа - в $LAST_BODY, код - в $LAST_CODE.
http() {
    local method="$1" url="$2" body_file="$3"; shift 3
    LAST_BODY="$(mktemp "$OUT_DIR/resp.XXXXXX")"
    local args=(-sS -X "$method" --max-time "$TIMEOUT" -o "$LAST_BODY" -w '%{http_code} %{time_total} %{size_download}')
    local h
    for h in "$@"; do args+=(-H "$h"); done
    [[ -n "$body_file" ]] && args+=(--data-binary "@$body_file")
    local meta rc=0
    # Учетные данные передаются curl через stdin-конфиг, а не аргументом.
    meta="$(printf 'user = "%s:%s"\n' "$ONEC_USER" "$ONEC_PASSWORD" | curl -K - "${args[@]}" "$url")" || rc=$?
    if [[ $rc -ne 0 ]]; then
        rm -f "$LAST_BODY"
        die "curl завершился с кодом $rc (сеть, таймаут ${TIMEOUT} с или адрес): $url"
    fi
    read -r LAST_CODE time size <<<"$meta"
    printf 'HTTP %s | %s s | %s B | %s %s\n' "$LAST_CODE" "$time" "$size" "$method" "$(printf '%b' "${url//%/\\x}")" >&2
}

# Показ тела: ошибка выводится целиком, крупный ответ сохраняется в файл.
show_body() {
    local out_file="${1-}" max="${2:-20000}" size
    size=$(wc -c < "$LAST_BODY" | tr -d ' ')
    if [[ "$LAST_CODE" -ge 400 ]]; then
        cat "$LAST_BODY"; echo
        rm -f "$LAST_BODY"
        exit 1
    fi
    if [[ -n "$out_file" ]]; then
        mv "$LAST_BODY" "$out_file"
        printf 'тело ответа сохранено: %s (%s B)\n' "$out_file" "$size" >&2
    elif [[ "$size" -gt "$max" ]]; then
        local f="$OUT_DIR/result-$(date +%Y%m%d-%H%M%S)-$$.txt"
        mv "$LAST_BODY" "$f"
        head -c "$max" "$f"; echo
        printf -- '--- показаны первые %s из %s B; полностью: %s\n' "$max" "$size" "$f" >&2
    else
        cat "$LAST_BODY"; echo
        rm -f "$LAST_BODY"
    fi
}

# Символы, которые в пути ресурса оставляются как есть.
PATH_SAFE="/(),'=:*\$@"
# В значениях параметров дополнительно экранируются & + # ; и пробел.
VALUE_SAFE="/(),'=:*\$@"

build_query() {
    local q="" kv k v
    for kv in "$@"; do
        k="${kv%%=*}"; v="${kv#*=}"
        q+="${q:+&}$(urlenc "$k" "\$")=$(urlenc "$v" "$VALUE_SAFE")"
    done
    printf '%s' "$q"
}

format_param() {
    local meta="$1" xml="$2"
    if [[ "$xml" == "1" ]]; then
        printf '%s' '$format=atom'
    else
        printf '%s' "\$format=application/json;odata=${meta}metadata"
    fi
}

# --- кеш описания сервиса ---------------------------------------------------

metadata_file() {
    local f="$CACHE_DIR/metadata.xml"
    if [[ ! -s "$f" || "${1-}" == "refresh" ]]; then
        http GET "$BASE/\$metadata" ""
        [[ "$LAST_CODE" == "200" ]] || show_body
        mv "$LAST_BODY" "$f"
    fi
    printf '%s' "$f"
}

sets_file() {
    local f="$CACHE_DIR/sets.txt"
    if [[ ! -s "$f" || "${1-}" == "refresh" ]]; then
        http GET "$BASE/?\$format=json" ""
        [[ "$LAST_CODE" == "200" ]] || show_body
        tr -d '\r' < "$LAST_BODY" | sed -n 's/^[[:space:]]*"name":[[:space:]]*"\(.*\)",*[[:space:]]*$/\1/p' | sort > "$f"
        rm -f "$LAST_BODY"
    fi
    printf '%s' "$f"
}

# --- команды ----------------------------------------------------------------

cmd_info() {
    printf 'профиль: %s\nфайл профиля: %s\nсервис: %s\nпользователь: %s\nкеш: %s (идентификатор снимка: %s)\n' \
        "${PROFILE:-<переменные окружения>}" "${ENV_FILE:-<нет>}" "$BASE" "$ONEC_USER" "$CACHE_DIR" "${CACHED_SNAPSHOT_ID:-<не задан>}"
    # Всегда свежий запрос: info - это проверка доступа, а не чтение кеша.
    local n
    n=$(wc -l < "$(sets_file refresh)" | tr -d ' ')
    printf 'опубликовано наборов сущностей: %s\n' "$n"
    [[ "$n" -gt 0 ]] || printf 'внимание: список пуст - состав стандартного интерфейса OData не настроен (references/publication.md)\n'
    printf 'ссылки на объекты: %s; веб-клиент: %s\n' "$LINKS_MODE" "${ONEC_WEB_URL:-<не задан>}"
}

# Вид объекта для навигационной ссылки: префикс набора OData -> имя вида метаданных.
# Ссылочные виды - со ссылкой на объект, прочие - только на список.
declare -A NAV_KIND=(
    [Catalog]=Справочник [Document]=Документ [ChartOfCharacteristicTypes]=ПланВидовХарактеристик
    [ChartOfAccounts]=ПланСчетов [ChartOfCalculationTypes]=ПланВидовРасчета [ExchangePlan]=ПланОбмена
    [BusinessProcess]=БизнесПроцесс [Task]=Задача
    [DocumentJournal]=ЖурналДокументов [InformationRegister]=РегистрСведений
    [AccumulationRegister]=РегистрНакопления [AccountingRegister]=РегистрБухгалтерии
    [CalculationRegister]=РегистрРасчета
)
NAV_REF_KINDS=" Catalog Document ChartOfCharacteristicTypes ChartOfAccounts ChartOfCalculationTypes ExchangePlan BusinessProcess Task "

cmd_link() {
    [[ $# -ge 1 ]] || die "link: укажите набор сущностей и, для объекта, GUID"
    local set="$1" guid="${2-}"
    # Допускается и форма канонического URL: Document_X(guid'...').
    if [[ "$set" =~ ^([^\(]+)\(guid\'([0-9a-fA-F-]{36})\'\)$ ]]; then
        set="${BASH_REMATCH[1]}"; guid="${BASH_REMATCH[2]}"
    fi
    local prefix="${set%%_*}" name="${set#*_}"
    [[ "$set" == *_* && -n "${NAV_KIND[$prefix]-}" ]] || die "link: для набора '$set' навигационная ссылка не строится"
    local nav
    if [[ -n "$guid" ]]; then
        [[ "$NAV_REF_KINDS" == *" $prefix "* ]] || die "link: у '$prefix' нет ссылки на объект, только на список (без GUID)"
        guid="${guid,,}"
        [[ "$guid" =~ ^([0-9a-f]{8})-([0-9a-f]{4})-([0-9a-f]{4})-([0-9a-f]{4})-([0-9a-f]{12})$ ]] || die "link: неверный GUID '$guid'"
        # Внутреннее представление ссылки 1С: группы GUID в порядке 4, 5, 3, 2, 1.
        local ref="${BASH_REMATCH[4]}${BASH_REMATCH[5]}${BASH_REMATCH[3]}${BASH_REMATCH[2]}${BASH_REMATCH[1]}"
        nav="e1cib/data/${NAV_KIND[$prefix]}.$name?ref=$ref"
    else
        nav="e1cib/list/${NAV_KIND[$prefix]}.$name"
    fi
    printf '%s\n' "$nav"
    [[ -z "${ONEC_WEB_URL-}" ]] || printf '%s/#%s\n' "${ONEC_WEB_URL%/}" "$(urlenc "$nav" "/.?=")"
}

cmd_sets() {
    local re="${1-}" f
    f="$(sets_file "${2-}")"
    if [[ -n "$re" ]]; then grep -E -- "$re" "$f" || { echo "нет наборов по отбору '$re' (всего $(wc -l < "$f"))" >&2; exit 1; }
    else cat "$f"; fi
}

cmd_meta() {
    [[ $# -ge 1 ]] || die "meta: укажите имя типа сущности, например Document_ЗаказПокупателя"
    local name="$1" refresh=""
    [[ "${2-}" == "--refresh" ]] && refresh="refresh"
    local f
    f="$(metadata_file "$refresh")"
    # Элементы $metadata у 1С разнесены по строкам: склеиваем каждый тег в одну строку.
    awk -v want="$name" '
        function attr(s, a,   r) { if (match(s, a "=\"[^\"]*\"")) { r = substr(s, RSTART + length(a) + 2, RLENGTH - length(a) - 3); return r } return "" }
        { buf = buf " " $0 }
        />/ {
            gsub(/[\t ]+/, " ", buf); t = buf; buf = ""
            if (t ~ /<EntityType /) { cur = attr(t, "Name"); intype = (cur == want); if (intype) { found = 1; print "EntityType " cur } next }
            if (t ~ /<\/EntityType>/) { intype = 0; next }
            if (intype && t ~ /<PropertyRef /) { print "  key       " attr(t, "Name"); next }
            if (intype && t ~ /<Property /) { printf "  prop      %-40s %s%s\n", attr(t, "Name"), attr(t, "Type"), (attr(t, "Nullable") == "false" ? " not null" : ""); next }
            if (intype && t ~ /<NavigationProperty /) { printf "  nav       %-40s %s\n", attr(t, "Name"), attr(t, "ToRole"); next }
            if (t ~ /<FunctionImport /) { fn = attr(t, "Name"); ret = attr(t, "ReturnType"); side = attr(t, "IsSideEffecting"); params = ""; bound = 0; infn = 1; next }
            if (infn && t ~ /<Parameter /) {
                pn = attr(t, "Name"); pt = attr(t, "Type")
                if (pn == "bindingParameter") { bound = (pt == "StandardODATA." want) }
                else params = params (params == "" ? "" : ", ") pn ":" pt
                next
            }
            if (infn && t ~ /<\/FunctionImport>/) {
                infn = 0
                if (bound) { found = 1; printf "  function  %s(%s)%s%s\n", fn, params, (ret != "" ? " -> " ret : ""), (side == "true" ? "  [изменяет данные]" : "") }
                next
            }
        }
        END { if (!found) exit 3 }
    ' "$f" || rc=$?
    # Код 3 - тип не найден; прочие ненулевые коды (например, SIGPIPE при `| head`) не ошибка.
    if [[ "${rc:-0}" == "3" ]]; then
        echo "тип '$name' не найден в \$metadata. Похожие наборы:" >&2
        grep -i -- "${name#*_}" "$(sets_file)" | head -20 >&2 || true
        exit 1
    fi
}

cmd_get() {
    [[ $# -ge 1 ]] || die "get: укажите ресурс"
    local res="$1"; shift
    local params=() meta="no" xml="" out="" max="20000"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --filter) params+=("\$filter=$2"); shift 2 ;;
            --select) params+=("\$select=$2"); shift 2 ;;
            --expand) params+=("\$expand=$2"); shift 2 ;;
            --orderby) params+=("\$orderby=$2"); shift 2 ;;
            --top) params+=("\$top=$2"); shift 2 ;;
            --skip) params+=("\$skip=$2"); shift 2 ;;
            --inlinecount) params+=("\$inlinecount=allpages"); shift ;;
            --allowed-only) params+=("allowedOnly=true"); shift ;;
            --param) params+=("$2"); shift 2 ;;
            --meta) meta="$2"; [[ "$meta" == "none" ]] && meta="no"; shift 2 ;;
            --xml) xml=1; shift ;;
            --out) out="$2"; shift 2 ;;
            --max-print) max="$2"; shift 2 ;;
            *) die "get: неизвестная опция $1" ;;
        esac
    done
    local q url
    q="$(build_query "${params[@]+"${params[@]}"}")"
    url="$BASE/$(urlenc "$res" "$PATH_SAFE")?${q:+$q&}$(urlenc "$(format_param "$meta" "$xml")" "\$=/")"
    http GET "$url" ""
    show_body "$out" "$max"
}

cmd_count() {
    [[ $# -ge 1 ]] || die "count: укажите ресурс"
    local res="$1"; shift
    local params=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --filter) params+=("\$filter=$2"); shift 2 ;;
            --param) params+=("$2"); shift 2 ;;
            *) die "count: неизвестная опция $1" ;;
        esac
    done
    local q
    q="$(build_query "${params[@]+"${params[@]}"}")"
    http GET "$BASE/$(urlenc "$res" "$PATH_SAFE")/\$count${q:+?$q}" ""
    show_body
}

cmd_write() {
    [[ $# -ge 2 ]] || die "write: укажите метод и ресурс"
    local method="$1" res="$2"; shift 2
    local body="" confirmed="" headers=("Accept: application/json")
    case "$method" in POST|PATCH|PUT|DELETE) ;; *) die "write: метод должен быть POST, PATCH, PUT или DELETE" ;; esac
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --body) body="$2"; shift 2 ;;
            --if-match) headers+=("If-Match: $2"); shift 2 ;;
            --load-mode) headers+=("1C_OData-DataLoadMode: true"); shift ;;
            --confirmed) confirmed=1; shift ;;
            *) die "write: неизвестная опция $1" ;;
        esac
    done
    [[ "${ONEC_READONLY-}" != "1" ]] || die "write: профиль только для чтения (ONEC_READONLY=1)"
    [[ -n "$confirmed" ]] || die "write: изменение данных выполняется только после явного подтверждения пользователя (--confirmed)"
    if [[ -n "$body" ]]; then
        [[ -f "$body" ]] || die "write: нет файла тела $body"
        headers+=("Content-Type: application/json")
    fi
    http "$method" "$BASE/$(urlenc "$res" "$PATH_SAFE")?\$format=json" "$body" "${headers[@]}"
    show_body
}

case "$CMD" in
    info) cmd_info "$@" ;;
    sets) cmd_sets "$@" ;;
    meta) cmd_meta "$@" ;;
    get) cmd_get "$@" ;;
    count) cmd_count "$@" ;;
    write) cmd_write "$@" ;;
    link) cmd_link "$@" ;;
    *) usage; exit 2 ;;
esac
