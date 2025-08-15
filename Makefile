# Makefile для управления инфраструктурой
# Использование:
#   make help                  # Показать список команд
#   make infra init            # Генерация сертификатов и запуск окружения (up --build)
#   make infra up              # Запуск/поднятие контейнеров
#   make infra down            # Остановка и удаление контейнеров
#   make logs clean            # Очистка всех логов
#
# Популярные команды:
#   make ps                    # Список контейнеров (compose ps)
#   make status                # То же, что ps (алиас)
#   make build                 # Сборка образов (без запуска)
#   make rebuild               # Пересборка и перезапуск (up --build -d)
#   make up                    # Запуск в фоне (up -d)
#   make down                  # Остановка и удаление (compose down)
#   make stop                  # Остановить контейнеры без удаления
#   make restart               # Перезапуск (всех или SERVICE=имя)
#   make logs-tail             # Хвост логов (SERVICE=имя для конкретного сервиса)
#
# Переменные окружения (можно переопределять при вызове):
#   SERVICE=<имя>              # Целевой сервис для некоторых команд (build, restart, stop, logs-tail, exec, pull, top, kill, rm)
#   DOWN_FLAGS="--volumes"     # Доп. флаги для down (по умолчанию пусто)
#   DC="docker compose"        # Явный выбор бинаря compose (по умолчанию автодетект)
#   COMPOSE_FILE=docker-compose.yml # Путь к compose-файлу (если файлов несколько)
#   CMD="команда"              # Команда для exec/run
#   PORT=<внутренний порт>     # Для цели port: внутренний порт сервиса (например, 80)
#   WAIT_TIMEOUT=120           # Таймаут ожидания готовности контейнеров (сек)
#   WAIT_INTERVAL=2            # Интервал проверки готовности (сек)
#
# Лучшие практики:
# - По умолчанию используем автодетект docker compose (v2) и docker-compose (v1).
# - «init» выполняет генерацию сертификатов перед стартом окружения.
# - Очистка логов не трогает сами репозитории, удаляет только файлы; пустые директории тоже чистятся.
#

SHELL := /bin/sh

# Автовыбор docker compose CLI: v2 (docker compose) или v1 (docker-compose)
DC ?= $(shell if docker compose version >/dev/null 2>&1; then echo "docker compose"; elif command -v docker-compose >/dev/null 2>&1; then echo "docker-compose"; else echo "docker compose"; fi)

# Каталог логов проекта
LOGS_DIR ?= logs

# Файл(ы) compose (можно переопределить, если их несколько)
COMPOSE_FILE ?= docker-compose.yml

# Настройки ожидания healthcheck
WAIT_TIMEOUT ?= 120
WAIT_INTERVAL ?= 2

# По умолчанию показываем помощь
.DEFAULT_GOAL := help

.PHONY: help infra init up down rebuild build stop restart exec pull top config run wait port kill rm events ps status logs logs-tail clean certs certs-upload doctor

help: ## Показать эту справку по командам
	@echo "Инфраструктурные команды:" && \
	awk 'BEGIN {FS = ":.*##"}; /^[a-zA-Z0-9_.-]+:.*##/ { printf "  %-18s %s\n", $$1, $$2 }' $(MAKEFILE_LIST) | sort && \
	echo "\nПримеры:" && \
	echo "  make infra init" && \
	echo "  make infra up" && \
	echo "  make infra down" && \
	echo "  make logs clean" && \
	echo "  make logs-tail SERVICE=nginx" && \
	echo "  make exec SERVICE=nginx" && \
	echo "  make pull" && \
	echo "  make config" && \
	echo "  make run SERVICE=php CMD=\"php -v\"" && \
	echo "  make wait SERVICE=nginx WAIT_TIMEOUT=60" && \
	echo "  make port SERVICE=nginx PORT=80" && \
	echo "\nПеременные: SERVICE, DOWN_FLAGS, DC, COMPOSE_FILE, CMD, PORT, WAIT_TIMEOUT, WAIT_INTERVAL" && \
	echo "DC детектирован как: $(DC)"

# Группирующие алиасы для удобного вызова "make infra <cmd>" и "make logs <cmd>"
infra: ## Группа команд для инфраструктуры (используйте: make infra init|up|down)
	@true

logs: ## Группа команд для логов (используйте: make logs clean)
	@true

# --- Основные цели инфраструктуры ---

init: certs rebuild ## Первая инициализация: генерация сертификатов и старт окружения (up --build)

up: ## Запуск/поднятие всех контейнеров в фоне
	$(DC) -f $(COMPOSE_FILE) up -d

down: ## Остановка и удаление контейнеров (можно дополнить флагами через DOWN_FLAGS)
	$(DC) -f $(COMPOSE_FILE) down $(DOWN_FLAGS)

rebuild: ## Пересобрать образы и перезапустить окружение
	$(DC) -f $(COMPOSE_FILE) up -d --build

build: ## Сборка образов без запуска контейнеров
	$(DC) -f $(COMPOSE_FILE) build $(SERVICE)

stop: ## Остановить контейнеры без удаления
	$(DC) -f $(COMPOSE_FILE) stop $(SERVICE)

restart: ## Перезапуск контейнеров (всех или SERVICE=<имя>)
	$(DC) -f $(COMPOSE_FILE) restart $(SERVICE)

exec: ## Подключиться к контейнеру (SERVICE=<имя>, optional: CMD="команда"), по умолчанию bash/sh
	@if [ -z "$(SERVICE)" ]; then \
	  echo "Использование: make exec SERVICE=<имя> [CMD=\"команда\"]"; \
	  echo "Например: make exec SERVICE=nginx или make exec SERVICE=nginx CMD=\"ls -la\""; \
	  exit 1; \
	fi; \
	if [ -n "$(CMD)" ]; then \
	  $(DC) -f $(COMPOSE_FILE) exec -it $(SERVICE) sh -lc "$(CMD)"; \
	else \
	  $(DC) -f $(COMPOSE_FILE) exec -it $(SERVICE) bash || $(DC) -f $(COMPOSE_FILE) exec -it $(SERVICE) sh; \
	fi

pull: ## Скачать образы, определенные в compose (всех или SERVICE=<имя>)
	$(DC) -f $(COMPOSE_FILE) pull $(SERVICE)

top: ## Показать процессы внутри контейнеров (всех или SERVICE=<имя>)
	$(DC) -f $(COMPOSE_FILE) top $(SERVICE)

config: ## Проверить и вывести итоговую конфигурацию docker compose
	$(DC) -f $(COMPOSE_FILE) config

run: ## Одноразовый запуск команды в новом контейнере: SERVICE=<имя> [CMD="команда"]
	@if [ -z "$(SERVICE)" ]; then \
	  echo "Использование: make run SERVICE=<имя> [CMD=\"команда\"]"; \
	  exit 1; \
	fi; \
	if [ -n "$(CMD)" ]; then \
	  $(DC) -f $(COMPOSE_FILE) run --rm $(SERVICE) sh -lc "$(CMD)"; \
	else \
	  $(DC) -f $(COMPOSE_FILE) run --rm $(SERVICE) sh; \
	fi

wait: ## Дождаться готовности контейнеров (healthy или running), SERVICE=<имя> для конкретного
	@ids="$$($(DC) -f $(COMPOSE_FILE) ps -q $(SERVICE))"; \
	if [ -z "$$ids" ]; then echo "[warn] Контейнеры не найдены"; exit 1; fi; \
	loops=$$(expr $(WAIT_TIMEOUT) / $(WAIT_INTERVAL)); \
	i=0; \
	while [ $$i -le $$loops ]; do \
	  not_ready=0; \
	  for id in $$ids; do \
	    status=$$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $$id 2>/dev/null || echo "unknown"); \
	    if [ "$$status" != "healthy" ] && [ "$$status" != "running" ]; then not_ready=1; fi; \
	  done; \
	  if [ $$not_ready -eq 0 ]; then echo "[ok] Контейнеры готовы"; exit 0; fi; \
	  sleep $(WAIT_INTERVAL); \
	  i=$$(expr $$i + 1); \
	done; \
	echo "[err] Таймаут ожидания готовности ($(WAIT_TIMEOUT)s)"; exit 1

port: ## Показать проброшенный порт: SERVICE=<имя> PORT=<внутренний порт>
	@if [ -z "$(SERVICE)" ] || [ -z "$(PORT)" ]; then \
	  echo "Использование: make port SERVICE=<имя> PORT=<порт>"; \
	  exit 1; \
	fi; \
	$(DC) -f $(COMPOSE_FILE) port $(SERVICE) $(PORT)

kill: ## Немедленно остановить контейнеры (всех или SERVICE=<имя>)
	$(DC) -f $(COMPOSE_FILE) kill $(SERVICE)

rm: ## Удалить остановленные контейнеры (все или SERVICE=<имя>)
	$(DC) -f $(COMPOSE_FILE) rm -f $(SERVICE)

events: ## Поток событий docker compose (всех или SERVICE=<имя>)
	$(DC) -f $(COMPOSE_FILE) events $(SERVICE)

ps: ## Показать состояние контейнеров (имя: статус (health)) только для текущего проекта
	@$(DC) -f $(COMPOSE_FILE) ps --all -q \
	  | xargs -r docker inspect -f '{{.Name}}: {{.State.Status}}{{if .State.Health}} ({{.State.Health.Status}}){{end}}' \
	  | sed 's#^/##'

status: ps ## Алиас: статус контейнеров

# --- Логи ---

logs-tail: ## Онлайн-просмотр логов (всех сервисов или SERVICE=<имя>), аналог docker compose logs -f
	$(DC) -f $(COMPOSE_FILE) logs -f --tail=200 $(SERVICE)

clean: ## Очистить все лог-файлы в $(LOGS_DIR)
	@if [ -d "$(LOGS_DIR)" ]; then \
	  echo "[info] Очистка логов в $(LOGS_DIR)..."; \
	  find "$(LOGS_DIR)" -type f -print -delete; \
	  find "$(LOGS_DIR)" -type d -empty -delete; \
	  echo "[ok] Логи очищены"; \
	else \
	  echo "[skip] Каталог $(LOGS_DIR) не найден"; \
	fi

# --- Подготовка сертификатов ---

certs: ## Сгенерировать самоподписанные сертификаты через scripts/generate-certs.sh
	@chmod +x ./scripts/generate-certs.sh || true
	@sh ./scripts/generate-certs.sh

certs-upload: ## Сгенерировать и загрузить сертификаты в MinIO (UPLOAD_TO_MINIO=1)
	@chmod +x ./scripts/generate-certs.sh || true
	@UPLOAD_TO_MINIO=1 sh ./scripts/generate-certs.sh

# --- Диагностика окружения ---

doctor: ## Проверка зависимостей: docker, compose, bash/sh
	@echo "Проверка docker..." && command -v docker >/dev/null 2>&1 && echo "  docker: OK" || (echo "  docker: NOT FOUND"; exit 1)
	@echo "Проверка compose..." && ( docker compose version >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1 ) && echo "  compose: OK ($(DC))" || (echo "  compose: NOT FOUND"; exit 1)
	@echo "Проверка shell..." && ( command -v sh >/dev/null 2>&1 ) && echo "  sh: OK" || (echo "  sh: NOT FOUND"; exit 1)

# Алиасы
infra-init: init
infra-up: up
infra-down: down
