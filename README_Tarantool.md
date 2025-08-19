# Приложение В: Tarantool (Cartridge) — кластер voting

Состав кластера (в одном контейнере):
- stateboard: используется для failover/координации (порт 4401)
- 3 инстанса storage: voting.storage-replica-1..3
  - iproto (TCP) порты: 3302, 3303, 3304
  - HTTP порты: 8081, 8082, 8083 (эндпоинты /ready, /state, /metrics, /health)

Контейнер инициализирует и настраивает кластер автоматически (bootstrap) через entrypoint.sh, регистрирует health/metrics и корректно завершает работу при остановке.


## Быстрый старт
1) Запуск всей инфраструктуры (рекомендуется):
```
make init     # первая инициализация
make up       # если сертификаты и образы уже готовы
make status   # дождаться healthy
```

2) Либо запустить только Tarantool (при уже созданной сети "infrastructure"):
```
docker compose up -d tarantool
```

3) Проверка готовности (ожидаем HTTP 200):
```
curl -fsS http://localhost:8081/ready
curl -fsS http://localhost:8081/state   
curl -fsS http://localhost:8081/metrics   # Prometheus-метрики
```
Если 8081 занят, используйте 8082/8083 (второй/третий инстанс storage).


## Порты
- 4401 — stateboard (TCP)
- 3302, 3303, 3304 — iproto (Tarantool TCP)
- 8081, 8082, 8083 — HTTP (Cartridge httpd: /ready, /state, /metrics, /health)

Имена инстансов и порты описаны в services/tarantool/voting/instances.yml.


## Логи и данные
- Логи: монтируются в ./logs/tarantool. Основной лог приложения: /var/log/tarantool/voting.log
  - Просмотр: `make logs-tail SERVICE=tarantool`
- Данные: volume `tarantool-data` → /var/lib/tarantool
  - Полный сброс состояния кластера: остановить контейнер и удалить volume `tarantool-data` (например, `make down DOWN_FLAGS="--volumes"`), затем снова запустить `make init`/`make up`.


## Переменные окружения (важные)
Устанавливаются в docker-compose (см. корневой docker-compose.yml):
- DB_USER, DB_PASSWORD — при старте создаётся пользователь БД и выдаются права (roles/voting.lua)
- CENTRIFUGO_URL, CENTRIFUGO_AUTH — параметры публикации событий в Centrifugo из фоновых задач роли voting
- Тюнинг Tarantool (init.lua):
  - MEMTX_MEMORY_MB (по умолчанию 512) или MEMTX_MEMORY_BYTES
  - MEMTX_MAX_TUPLE_MB (по умолчанию 10)
  - WAL_MODE (по умолчанию write)
  - READAHEAD (по умолчанию 10485760)
  - NET_MSG_MAX (по умолчанию 4096)
  - WORKER_POOL_THREADS (по умолчанию 16)
  - MEMTX_USE_MVCC (true/false, по умолчанию false)
  - TARANTOOL_LOG, TARANTOOL_LOG_FORMAT (json|plain), TARANTOOL_LOG_LEVEL
  - WEBUI_ENABLED (true/false; включение WebUI Cartridge)


## Эндпоинты и проверки
- /ready — простой 200 OK, готовность HTTP‑сервера
- /state — состояние конфигуратора Cartridge: ConfigLoaded/RolesConfigured
- /metrics — Prometheus‑метрики Tarantool/Cartridge
- /health — формат health
Примеры:
```
# базовая готовность
curl -fsS http://localhost:8081/ready

# состояние кластера
curl -fsS http://localhost:8081/state

# метрики
curl -fsS http://localhost:8081/metrics | head -n 20
```


## Подключение к Tarantool (iproto)
- Локально: iproto на 127.0.0.1:3302 (или 3303/3304)
- Внутри сети Docker: `tarantool:3302` (имя контейнера)

Примеры:
- Войти в контейнер и открыть консоль Tarantool:
```
docker exec -it tarantool tarantool
```
- Подключиться к инстансу через net.box из консоли tarantool:
```
net = require('net.box')
c = net.connect('127.0.0.1:3302')
assert(c:ping())
```
- Проверка доступности TCP:
```
nc -zv 127.0.0.1 3302
```

Заданы DB_USER/DB_PASSWORD, используйте их для аутентификации (`net.box.connect('voting_user:voting_password@localhost:3302')`).


## Web UI Cartridge
Если WEBUI_ENABLED=true (по умолчанию так и есть), веб-интерфейс Cartridge доступен на 8081..8083. Он показывает топологию, роли и состояние. Для локальной разработки аутентификация не включена.


## Роль voting (кратко)
Роль `app.roles.voting`:
- Создаёт пользователя БД (DB_USER/DB_PASSWORD) и выдаёт необходимые права
- Поддерживает фоновые публикации в Centrifugo (CENTRIFUGO_URL/CENTRIFUGO_AUTH)
- Работает со спейсом `VOTES_STAT` (ожидается в схеме)

Детали: `services/tarantool/voting/app/roles/voting.lua`.


## Эксплуатация
- Перезапуск: `make restart SERVICE=tarantool`
- Просмотр логов: `make logs-tail SERVICE=tarantool`
- Проверка здоровья: см. раздел «Эндпоинты и проверки»
- Сброс состояния (полный): остановить контейнер и удалить volume `tarantool-data` (будет выполнен новый bootstrap)
- Обновление зависимостей приложения: при изменении rockspec или отсутствии .rocks entrypoint выполнит `cartridge build` автоматически


## Устранение неполадок
- Контейнер не healthy: проверьте `curl -fsS http://localhost:8081/ready` и логи ./logs/tarantool
- Порты заняты: освободите 4401, 3302-3304, 8081-8083
- Ошибка публикации в Centrifugo: проверьте CENTRIFUGO_URL/CENTRIFUGO_AUTH и доступность сервиса Centrifugo (http://localhost:8000/)
- Сбросить кластерное состояние: удалите volume `tarantool-data`


## Полезные команды
```
# Запуск только Tarantool
docker compose up -d tarantool

# Перезапуск
make restart SERVICE=tarantool

# Логи Tarantool
make logs-tail SERVICE=tarantool

# Проверка HTTP готовности/метрик
curl -fsS http://localhost:8081/ready && echo OK
curl -fsS http://localhost:8081/metrics | head -n 10
```
