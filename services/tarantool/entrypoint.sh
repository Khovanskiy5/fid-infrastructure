#!/usr/bin/env bash
# Надёжный entrypoint для Docker-контейнера с Tarantool Cartridge
# Задачи:
# - Запускает 4 инстанса в одном контейнере: stateboard и 3 storage
# - Обрабатывает SIGTERM/SIGINT, корректно останавливает инстансы и дожидается завершения
# - Проверяет и устанавливает зависимости (cartridge build), если .rocks отсутствует или rockspec изменился
# - Выполняет однократную настройку кластера (bootstrap) с экспоненциальным backoff
# - Проверяет доступность TCP-портов и HTTP-эндпоинтов /health и /metrics
# - Логи в stdout с префиксом [ENTRYPOINT]

set -Eeuo pipefail

# Утилиты логирования
log()  { echo "[ENTRYPOINT][INFO] $*" >&2; }
warn() { echo "[ENTRYPOINT][WARN] $*" >&2; }
err()  { echo "[ENTRYPOINT][ERROR] $*" >&2; }

# Базовые пути и переменные
APP_NAME="voting"
APP_ROOT="/opt/tarantool/${APP_NAME}"
APP_DIR="${APP_ROOT}"
RUN_DIR="/var/run/tarantool/run"
DATA_DIR="/var/lib/tarantool/data"
LOG_DIR="/var/lib/tarantool/log"
BOOTSTRAP_MARKER="${DATA_DIR}/.${APP_NAME}_bootstrapped"
ROCKSPEC_FILE="${APP_DIR}/${APP_NAME}-scm-1.rockspec"
ROCKSPEC_HASH_FILE="${DATA_DIR}/.${APP_NAME}_rockspec.sha256"
CARTRIDGE_BIN="cartridge"
CURL_BIN="curl"
NC_BIN="nc"

# Порты из instances.yml (локально внутри контейнера)
STATEBOARD_URI="localhost:4401"
INST1_TCP="localhost:3302"; INST1_HTTP=8081
INST2_TCP="localhost:3303"; INST2_HTTP=8082
INST3_TCP="localhost:3304"; INST3_HTTP=8083

# Флаг, что инстансы были запущены
STARTED=0

# Обработка сигналов для graceful shutdown
terminate() {
  warn "Пойман сигнал завершения, начинаю корректную остановку Tarantool-инстансов..."
  graceful_shutdown || true
}
trap terminate SIGTERM SIGINT

# Корректная остановка всех инстансов Tarantool
graceful_shutdown() {
  set +e
  if [[ ${STARTED} -eq 1 ]]; then
    log "Останавливаю инстансы через 'cartridge stop'..."
    ( cd "${APP_DIR}" && ${CARTRIDGE_BIN} stop ) || warn "cartridge stop завершился с ошибкой"
    # Дополнительно пытаемся остановить stateboard
    ( cd "${APP_DIR}" && ${CARTRIDGE_BIN} stop --stateboard ) || true
  else
    warn "Инстансы не были запущены текущим entrypoint, пропускаю 'cartridge stop'"
  fi

  # Дожидаемся завершения фоновых tarantool-процессов
  local attempts=30
  while [[ ${attempts} -gt 0 ]]; do
    if ! has_processes; then
      log "Все процессы Tarantool завершены"
      break
    fi
    sleep 1
    attempts=$((attempts-1))
  done

  # Форсируем SIGTERM для оставшихся (как страховка)
  if has_processes; then
    warn "Обнаружены живые процессы Tarantool, отправляю SIGTERM..."
    if has_cmd pkill; then
      pkill -TERM -f "tarantool.*${APP_NAME}" || true
    else
      # Fallback: находим PID процессов и посылаем SIGTERM
      ps -eo pid,cmd | awk '/tarantool.*'"${APP_NAME}"'/ {print $1}' | xargs -r kill -TERM || true
    fi
  fi

  # Финальная пауза
  sleep 1
  set -e
}

# Проверка доступности бинарей
require_bin() {
  local b="$1"
  command -v "$b" >/dev/null 2>&1 || { err "Не найден бинарь: $b"; exit 1; }
}

# Проверка наличия команды
has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

# Проверка наличия процессов tarantool данного приложения
has_processes() {
  if has_cmd pgrep; then
    pgrep -f "tarantool.*${APP_NAME}" >/dev/null 2>&1
  else
    ps aux | grep -E "tarantool.*${APP_NAME}" | grep -v grep >/dev/null 2>&1
  fi
}

# Функция вычисления sha256 для rockspec
rockspec_hash() {
  if [[ -f "${ROCKSPEC_FILE}" ]]; then
    sha256sum "${ROCKSPEC_FILE}" | awk '{print $1}'
  else
    echo ""
  fi
}

# Проверка зависимостей и при необходимости их установка (cartridge build)
ensure_dependencies() {
  require_bin "${CARTRIDGE_BIN}"
  require_bin "sha256sum"
  require_bin "${NC_BIN}"
  require_bin "${CURL_BIN}"

  mkdir -p "${RUN_DIR}" "${DATA_DIR}" "${LOG_DIR}"

  local need_build=0
  if [[ ! -d "${APP_DIR}/.rocks" ]]; then
    log ".rocks не найден, требуется сборка зависимостей"
    need_build=1
  fi

  local new_hash old_hash
  new_hash=$(rockspec_hash || echo "")
  if [[ -n "${new_hash}" ]]; then
    if [[ -f "${ROCKSPEC_HASH_FILE}" ]]; then
      old_hash=$(cat "${ROCKSPEC_HASH_FILE}" || true)
      if [[ "${new_hash}" != "${old_hash}" ]]; then
        log "Изменился rockspec (${old_hash} -> ${new_hash}), требуется пересборка"
        need_build=1
      fi
    else
      log "Хэш rockspec отсутствует, требуется первичная сборка"
      need_build=1
    fi
  else
    warn "Rockspec файл не найден: ${ROCKSPEC_FILE} — сборка может завершиться неудачей"
  fi

  if [[ ${need_build} -eq 1 ]]; then
    ( cd "${APP_DIR}" && ${CARTRIDGE_BIN} build )
    if [[ -n "${new_hash}" ]]; then
      echo "${new_hash}" > "${ROCKSPEC_HASH_FILE}"
    fi
    log "Зависимости установлены/обновлены"
  else
    log "Зависимости актуальны — сборка не требуется"
  fi
}

# Проверка доступности TCP-порта с повторными попытками
wait_tcp() {
  local hostport="$1"; shift || true
  local timeout="${1:-30}"; shift || true
  local delay=1
  local elapsed=0
  while (( elapsed < timeout )); do
    if ${NC_BIN} -z ${hostport%:*} ${hostport##*:} >/dev/null 2>&1; then
      log "TCP ${hostport} доступен"
      return 0
    fi
    sleep "${delay}"
    elapsed=$((elapsed+delay))
    if (( delay < 5 )); then delay=$((delay+1)); fi
  done
  err "TCP ${hostport} не стал доступен за ${timeout} сек"
  return 1
}

# Проверка HTTP эндпоинта с повторными попытками
wait_http_200() {
  local url="$1"; shift || true
  local timeout="${1:-60}"
  local backoff=1
  local elapsed=0
  require_bin "${CURL_BIN}"
  while (( elapsed < timeout )); do
    if ${CURL_BIN} -fsS "${url}" >/dev/null 2>&1; then
      log "HTTP ${url} отвечает 200"
      return 0
    fi
    sleep "${backoff}"
    elapsed=$((elapsed+backoff))
    backoff=$(( backoff < 8 ? backoff*2 : 8 ))
  done
  err "HTTP ${url} не отвечает 200 в течение ${timeout} сек"
  return 1
}

# Старт всех инстансов Tarantool через cartridge -d
start_cluster() {
  log "Запуск Tarantool инстансов (включая stateboard) в фоне..."
  ( cd "${APP_DIR}" && ${CARTRIDGE_BIN} start -d)
  STARTED=1
  sleep 5
}

# Однократный bootstrap и настройка репликасетов/вшарда/фейловера
bootstrap_cluster() {
  if [[ -f "${BOOTSTRAP_MARKER}" ]]; then
    log "Маркер бутстрапа найден — пропускаю настройку кластера"
    return 0
  fi

  log "Начинаю однократную настройку кластера (bootstrap)"

  # Ожидаем доступность TCP портов stateboard и всех стореджей
  wait_tcp "${STATEBOARD_URI}" 60
  wait_tcp "${INST1_TCP}" 60
  wait_tcp "${INST2_TCP}" 60
  wait_tcp "${INST3_TCP}" 60

  # Ожидаем HTTP эндпоинты первого инстанса
  # Сначала liveness: /ready не обращается к box.*
  wait_http_200 "http://localhost:${INST1_HTTP}/ready" 90
  # Затем readiness: появление /metrics означает, что cartridge.cfg отработал и роль metrics активна
  wait_http_200 "http://localhost:${INST1_HTTP}/metrics" 90


  # Экспоненциальные попытки выполнить bootstrap репликасетов
  local attempts=6
  local backoff=1
  local i=1
  while (( i <= attempts )); do
    log "Попытка ${i}/${attempts}: cartridge replicasets setup --bootstrap-vshard"
    local out exit_code
    out="$( cd "${APP_DIR}" && ${CARTRIDGE_BIN} replicasets setup --bootstrap-vshard 2>&1 )"
    exit_code=$?

    if [[ ${exit_code} -eq 0 ]]; then
      log "Успешно настроены репликасеты и vshard"
      # Настройка failover stateful со stateboard
      if ( cd "${APP_DIR}" && ${CARTRIDGE_BIN} failover set stateful --state-provider stateboard --provider-params '{"uri": "localhost:4401", "password": "passwd"}' ); then
        log "Failover настроен (stateful, stateboard)"
      else
        warn "Не удалось настроить failover, повторите вручную при необходимости"
      fi
      touch "${BOOTSTRAP_MARKER}"
      log "Создан маркер бутстрапа: ${BOOTSTRAP_MARKER}"
      return 0
    else
      # Если vshard уже был забутстраплен ранее — считаем успехом и помечаем
      if echo "${out}" | grep -qi "already bootstrapped"; then
        warn "vshard уже был инициализирован ранее — считаю bootstrap успешным"
        if ( cd "${APP_DIR}" && ${CARTRIDGE_BIN} failover set stateful --state-provider stateboard --provider-params '{"uri": "localhost:4401", "password": "passwd"}' ); then
          log "Failover настроен (stateful, stateboard)"
        else
          warn "Не удалось настроить failover, повторите вручную при необходимости"
        fi
        touch "${BOOTSTRAP_MARKER}"
        log "Создан маркер бутстрапа: ${BOOTSTRAP_MARKER}"
        return 0
      fi
      warn "Попытка bootstrap не удалась, жду ${backoff} сек и повторяю"
      warn "Причина: ${out}"
      sleep "${backoff}"
      backoff=$(( backoff < 16 ? backoff*2 : 16 ))
    fi
    i=$((i+1))
  done

  err "Не удалось выполнить bootstrap кластера после ${attempts} попыток"
  return 1
}

main() {
  log "Старт entrypoint для приложения '${APP_NAME}'"

  # Проверка зависимостей
  ensure_dependencies

  # Запускаем инстансы
  start_cluster

  # Выполняем bootstrap при первом запуске
  bootstrap_cluster || {
    warn "Бутстрап завершился ошибкой — инициирую остановку"
    graceful_shutdown
    exit 1
  }

  # Главное ожидание: держим контейнер живым, пока идут процессы tarantool
  log "Кластер запущен. Ожидаю сигналы завершения..."
  while true; do
    if ! pgrep -f "tarantool.*${APP_NAME}" >/dev/null 2>&1; then
      warn "Процессы Tarantool отсутствуют — завершаю контейнер"
      break
    fi
    sleep 5
  done
}

main "$@"


