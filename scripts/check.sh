#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PROJECT="check-$(date +%s)-$$"
TEST_ENV="$(mktemp)"
printf 'HOST_PORT=0\nGREETING=test\n' > "$TEST_ENV"

if docker info >/dev/null 2>&1; then
    DOCKER=(docker)
else
    DOCKER=(sudo docker)
fi

compose() {
    "${DOCKER[@]}" compose --env-file "$TEST_ENV" -p "$PROJECT" "$@"
}

cleanup() {
    status=$?
    trap - EXIT

    compose down -v --remove-orphans >/dev/null || true
    rm -f "$TEST_ENV"

    exit "$status"
}

trap cleanup EXIT

compose up -d --build >/dev/null

PORT_INFO="$(compose port app 8000)"
PORT="${PORT_INFO##*:}"
BASE_URL="http://127.0.0.1:$PORT"

for attempt in {1..30}; do
    if curl -fsS --connect-timeout 2 --max-time 2 "$BASE_URL/readyz" >/dev/null 2>&1; then
        break
    fi

    if (( attempt == 30 )); then
        echo "ошибка: app не запустился" >&2
        compose logs --tail 30
        exit 1
    fi

    sleep 2
done

N=3

get_count() {
    local response="$1"

    if [[ "$response" =~ \"count\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "нет count в ответе" >&2
        return 1
    fi
}

response="$(curl -fsS --connect-timeout 2 --max-time 5 "$BASE_URL/")"
count="$(get_count "$response")"

if [[ "$count" != "0" ]]; then
    echo "ошибка начальный счётчик $count вместо 0" >&2
    exit 1
fi

for ((i=1; i<=N; i++)); do
    response="$(curl -fsS --connect-timeout 2 --max-time 5 -X POST "$BASE_URL/increment")"
    count="$(get_count "$response")"

    if [[ "$count" != "$i" ]]; then
        echo "ошибка: ожидалось $i, получилось $count" >&2
        exit 1
    fi
done

response="$(curl -fsS --connect-timeout 2 --max-time 5 "$BASE_URL/")"
count="$(get_count "$response")"

if [[ "$count" != "$N" ]]; then
    echo "ожидалось $N, получилось $count" >&2
    exit 1
fi

echo "счётчик: $count"

OLD_APP_ID="$(compose ps -q app)"
OLD_REDIS_ID="$(compose ps -q redis)"

compose up -d --no-deps --force-recreate app >/dev/null

NEW_APP_ID="$(compose ps -q app)"
NEW_REDIS_ID="$(compose ps -q redis)"

if [[ -z "$NEW_APP_ID" ]]; then
    echo "ошибка: app не найден" >&2
    exit 1
fi

if [[ "$OLD_APP_ID" == "$NEW_APP_ID" ]]; then
    echo "ошибка: app не пересоздался" >&2
    exit 1
fi

if [[ "$OLD_REDIS_ID" != "$NEW_REDIS_ID" ]]; then
    echo "ошибка: redis был пересоздан" >&2
    exit 1
fi

PORT_INFO="$(compose port app 8000)"
PORT="${PORT_INFO##*:}"
BASE_URL="http://127.0.0.1:$PORT"

for attempt in {1..30}; do
    if response="$(curl -fsS --connect-timeout 2 --max-time 3 "$BASE_URL/" 2>/dev/null)"; then
        count="$(get_count "$response")"

        if [[ "$count" != "$N" ]]; then
            echo "ошибка: счётчик после пересоздания $count" >&2
            exit 1
        fi

        break
    fi

    if (( attempt == 30 )); then
        echo "ошибка: app не отвечает" >&2
        exit 1
    fi

    sleep 1
done

echo "после пересоздания: $count"

check_http() {
    local method="$1"
    local path="$2"
    local expected="$3"
    local actual

    actual="$(curl -sS -o /dev/null -w '%{http_code}' \
        --connect-timeout 2 --max-time 5 \
        -X "$method" "$BASE_URL$path")"

    if [[ "$actual" != "$expected" ]]; then
        echo "ошибка: $path вернул $actual вместо $expected" >&2
        exit 1
    fi

    echo "${method,,} $path: $actual"
}

compose stop redis >/dev/null

check_http GET /healthz 200
check_http GET /readyz 503
check_http POST /increment 503

APP_ID_BEFORE="$(compose ps -q app)"

compose start redis >/dev/null

READY=0

for attempt in {1..30}; do
    code="$(curl -s -o /dev/null -w '%{http_code}' \
        --connect-timeout 2 --max-time 3 \
        "$BASE_URL/readyz" || true)"

    if [[ "$code" == "200" ]]; then
        READY=1
        break
    fi

    sleep 2
done

if [[ "$READY" != "1" ]]; then
    echo "ошибка: redis не восстановился" >&2
    exit 1
fi

APP_ID_AFTER="$(compose ps -q app)"

if [[ "$APP_ID_BEFORE" != "$APP_ID_AFTER" ]]; then
    echo "ошибка: app был перезапущен" >&2
    exit 1
fi

response="$(curl -fsS --connect-timeout 2 --max-time 5 "$BASE_URL/")"
count="$(get_count "$response")"

if [[ "$count" != "$N" ]]; then
    echo "ошибка: после redis счётчик $count вместо $N" >&2
    exit 1
fi

response="$(curl -fsS --connect-timeout 2 --max-time 5 -X POST "$BASE_URL/increment")"
count="$(get_count "$response")"

if [[ "$count" != "$((N + 1))" ]]; then
    echo "ошибка: после post счётчик $count" >&2
    exit 1
fi

echo "после восстановления: $count"

compose stop app >/dev/null
compose stop redis >/dev/null

BACKUP_FILE="$(mktemp "${TMPDIR:-/tmp}/${PROJECT}-redis-backup-XXXXXX.tar")"

"${DOCKER[@]}" run --rm \
    --mount "type=volume,source=${PROJECT}_redis_data,target=/data,readonly" \
    --entrypoint tar \
    redis:7.4-alpine -C /data -cf - . > "$BACKUP_FILE"

if [[ ! -s "$BACKUP_FILE" ]]; then
    echo "ошибка пустая копия" >&2
    exit 1
fi

if ! "${DOCKER[@]}" run --rm -i \
    --entrypoint tar redis:7.4-alpine \
    -tf - < "$BACKUP_FILE" >/dev/null; then
    echo "ошибка: архив не читается" >&2
    exit 1
fi

echo "копия: $BACKUP_FILE"
echo "фул проверки пройдены"
