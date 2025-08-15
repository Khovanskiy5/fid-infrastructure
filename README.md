# Инфраструктурное окружение для локальной разработки (docker-compose), приближенное к production

Готовая инфраструктура для локальной разработки, максимально повторяющая ключевые элементы production: обратный прокси (Nginx), PHP‑FPM, Node.js, PostgreSQL с репликацией + PgBouncer/HAProxy, Redis с Sentinel, RabbitMQ кластер + HAProxy, ClickHouse кластер, Elasticsearch (3 ноды) + Kibana, MinIO (S3), Centrifugo, логирование и ротация логов.

— Сделано для быстрого старта, повторяемости окружения и удобной отладки.


## Оглавление
- [Требования](#требования)
- [Быстрый старт](#быстрый-старт-tldr)
- [Переменные окружения (.env)](#переменные-окружения-env)
- [Команды Makefile](#команды-makefile)
- [Сервисы и порты](#сервисы-и-порты)
- [Структура проекта](#структура-проекта)
- [Логи и ротация](#логи-и-ротация)
- [TLS/SSL сертификаты](#tlsssl-сертификаты)
- [Проверка работоспособности](#проверка-работоспособности)
- [Подключение из контейнеров и внешних проектов](#подключение-из-контейнеров-и-внешних-проектов)
- [Инструкция по подключениям (детально по сервисам)](#инструкция-по-подключениям-детально-по-сервисам)
- [Устранение неполадок](#устранение-неполадок)
- [Приложение A: Elasticsearch + Hunspell тесты](#приложение-a-elasticsearch--hunspell-тесты)


## Требования
- Docker (20+ рекомендуется)
- Docker Compose v2 (docker compose) или v1 (docker-compose) — autodetect в Makefile
- make, sh/bash
- jq (опционально, для красивого вывода JSON в примерах Elasticsearch)
- openssl (обычно уже есть; для генерации сертификатов)
- ОС: macOS / Linux / Windows (через WSL2)

Проверить окружение: make doctor


## Быстрый старт
1) Скопируйте переменные окружения:
```
cp .env.example .env
```
2) Первая инициализация (генерация сертификатов + запуск):
```
make init
```
3) Проверка статуса контейнеров (ожидается healthy/running):
```
make status
```
4) Откройте:
- Nginx (тест): https://localhost/healthz (самоподписанный сертификат)
- MailHog UI: http://localhost:8025 или https://localhost/mailhog/
- RabbitMQ UI: http://localhost:15672 (admin/adminpass)
- Kibana: http://localhost:5601
- MinIO Console: https://localhost:9001 (minioadmin/minioadminpass)
- Centrifugo: http://localhost:8000

Полезно: make help — список всех целей с описаниями.


## Переменные окружения (.env)
См. .env.example. По умолчанию заданы простые для разработки значения:
- PostgreSQL:
  - POSTGRES_USER=postgres
  - POSTGRES_PASSWORD=postgres_password
  - POSTGRES_DB=postgres
  - POSTGRES_REPMGR_PASSWORD=repmgrsecret
- RabbitMQ:
  - RABBITMQ_COOKIE=supersecretcookie
  - RABBITMQ_USER=admin
  - RABBITMQ_PASSWORD=adminpass
- MinIO:
  - MINIO_ROOT_USER=minioadmin
  - MINIO_ROOT_PASSWORD=minioadminpass


## Команды Makefile
Ключевые (полный список: make help):
- init — первая инициализация: генерация сертификатов + up --build
- up — поднять контейнеры в фоне
- down — остановить и удалить контейнеры (доп. флаги: DOWN_FLAGS="--volumes")
- rebuild — пересборка образов и перезапуск
- build — сборка образов (SERVICE=имя для конкретного)
- stop — остановка без удаления (SERVICE=...)
- restart — перезапуск (SERVICE=...)
- exec — войти в контейнер, CMD="команда" (SERVICE=...)
- run — одноразовый контейнер для запуска команды (SERVICE=..., CMD=...)
- logs-tail — онлайн‑логи (всех или SERVICE=...)
- clean — очистка логов в каталоге logs
- wait — дождаться готовности (healthy/running), можно SERVICE=...
- port — показать проброшенный порт (SERVICE=..., PORT=...)
- pull, top, config, events, ps, status — служебные
- certs — сгенерировать самоподписанные сертификаты
- certs-upload — сгенерировать и загрузить сертификаты в MinIO (UPLOAD_TO_MINIO=1)
- doctor — проверка зависимостей

Переменные: SERVICE, DOWN_FLAGS, DC, COMPOSE_FILE, CMD, PORT, WAIT_TIMEOUT, WAIT_INTERVAL


## Сервисы и порты
- Nginx: 80 (HTTP), 443 (HTTPS)
- PostgreSQL: 5432
- PgBouncer/HAProxy (PostgreSQL): 6432
- Redis: 6379 (Sentinel: 26379, 26380, 26381)
- MailHog UI: 8025 (также через https://localhost/mailhog/)
- ClickHouse: 8123 (HTTP), 9004 (TCP/native)
- RabbitMQ через HAProxy: 5672 (AMQP), 15672 (UI)
- Elasticsearch: 9200 (HTTP)
- Kibana: 5601 (UI)
- MinIO: 9000 (S3 API), 9001 (Console)
- Centrifugo: 8000 (WS/API)

DNS‑имена внутри сети Docker (bridge): postgres-master, postgres-replica, pgbouncer, haproxy, redis-master, redis-slave, redis-sentinel-1..3, rabbit-haproxy, rabbit-1..3, clickhouse-1/2, es01..es03, kibana, minio, centrifugo, php-fpm, nginx и др.


## Структура проекта
- docker-compose.yml — главный файл оркестрации
- services/* — конфиги всех сервисов (nginx, php, postgres, redis, rabbitmq, clickhouse, es, kibana, minio, centrifugo, haproxy, logrotate)
- src/ — код приложения (пример: public/index.php)
- logs/ — каталоги логов по сервисам (создаются автоматически)
- scripts/generate-certs.sh — генерация самоподписанных сертификатов
- .env.example — пример переменных окружения


## Логи и ротация
- Все сервисы пишут логи в ./logs/... (монтируется внутрь контейнеров)
- Отдельный контейнер logrotate с cron выполняет ротацию по правилам в services/logrotate/conf.d/* (по умолчанию — ежечасно)
- Команды:
  - Просмотр: make logs-tail SERVICE=nginx
  - Очистка: make logs clean


## TLS/SSL сертификаты
Сертификаты генерируются скриптом scripts/generate-certs.sh (самоподписанные):
- make certs — сгенерировать
- UPLOAD_TO_MINIO=1 make certs — сгенерировать и загрузить в MinIO
- FORCE=1 make certs — перегенерировать (перезаписать)

Пути файлов:
- Nginx: services/nginx/certs/server.crt, services/nginx/certs/server.key
- MinIO: services/minio/certs/public.crt, services/minio/certs/private.key

Настройки через переменные окружения:
- MINIO_ROOT_USER, MINIO_ROOT_PASSWORD — учётные данные MinIO
- MINIO_BUCKET — бакет для загрузки (по умолчанию certs)
- MINIO_HOST, MINIO_S3_PORT — адрес MinIO для проверки готовности (по умолчанию localhost:9000)
- TLS_CERT_CN, TLS_CERT_DAYS — CN и срок действия (по умолчанию localhost, 825 дней)

Браузер будет предупреждать о самоподписанном сертификате — это ожидаемо в DEV.


## Проверка работоспособности
Общие примеры:
- Nginx/PHP: `curl -k https://localhost/healthz`
- PHP-FPM: смотрите ./logs/php и откройте `src/public/index.php`
- Node.js: `docker exec -it infra_nodejs node -v`

PostgreSQL:
```
psql -h localhost -U postgres -d postgres -c 'select now();'
psql -h localhost -p 6432 -U postgres -d postgres -c 'select now();'  # через PgBouncer/HAProxy
docker exec -it infra_pg_master psql -U postgres -c 'select * from pg_stat_replication;'
```

Redis:
```
redis-cli -h 127.0.0.1 -p 6379 ping
# Sentinel (внутри сети Docker):
docker exec -it infra_redis_sentinel-1 redis-cli -p 26379 info | head -n 20
```

ClickHouse:
```
curl 'http://localhost:8123/?query=SELECT%201'
clickhouse-client --host 127.0.0.1 --port 9004 --query "select 1"
docker exec -it infra_clickhouse_1 clickhouse-client --query "select 1"
```

RabbitMQ:
- UI: http://localhost:15672 (admin/adminpass)
- AMQP: amqp://localhost:5672

Elasticsearch:
```
curl http://localhost:9200
```

Kibana: http://localhost:5601

MinIO:
- Console: http://localhost:9001 (minioadmin/minioadminpass)
- S3 API: http://localhost:9000

Centrifugo:
- Admin UI: http://localhost:8000
- WebSocket: ws://localhost:8000/connection/websocket


## Подключение из контейнеров и внешних проектов
- Внутри сети Docker все сервисы доступны по DNS‑именам (см. «Сервисы и порты»).
- Для подключения внешних проектов используйте общую сеть `infrastructure`.

Подключение запущенного контейнера к сети `infrastructure` (Инфраструктура должна быть запущена):
```
docker network connect infrastructure <container_name>
docker exec -it <container_name> ping -c1 postgres-master
```

Одноразовый контейнер в сети `infrastructure`:
```
docker run --rm -it --network infrastructure alpine sh
```

Подключение другого docker‑compose проекта (фрагмент docker-compose.yml):
```yaml
networks:
  infrastructure:
    external: true
    name: infrastructure

services:
  my-app:
    image: your/image
    networks:
      - infrastructure
```


## Инструкция по подключениям (детально по сервисам)

### PgBouncer + HAProxy (PostgreSQL)
- Снаружи: localhost:6432 (HAProxy → PgBouncer → PostgreSQL)
- Внутри Docker: haproxy:6432 или pgbouncer:6432
- Переменные: POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB (из .env)
- Примеры:
```
psql -h localhost -p 6432 -U postgres -d postgres -c 'select now();'
# DSN: postgres://postgres:${POSTGRES_PASSWORD}@localhost:6432/postgres
```

### PostgreSQL (Bitnami repmgr)
- Снаружи: localhost:5432
- Внутри: postgres-master:5432 (реплика: postgres-replica:5432)
- Примеры:
```
psql -h localhost -U postgres -d postgres
psql -h postgres-master -U postgres -d postgres
```

### Redis (master/slave + 3 Sentinel)
- Redis: localhost:6379 (внутри: redis-master:6379; slave: redis-slave:6379)
- Sentinel: 26379, 26380, 26381 (внутри: redis-sentinel-1..3:26379)

### RabbitMQ (3 ноды) + HAProxy
- AMQP: localhost:5672 (внутри: rabbit-haproxy:5672)
- UI: http://localhost:15672 (внутри: rabbit-haproxy:15672)
- DSN: amqp://admin:adminpass@localhost:5672/

### ClickHouse (2 ноды + Keeper)
- HTTP: localhost:8123; TCP(native): localhost:9004 → контейнерный 9000
- Пользователи: default (без пароля), admin/123
- JDBC URL (современный драйвер com.clickhouse):
```
HTTP:  jdbc:ch://127.0.0.1:8123/default?ssl=false&user=admin&password=123
Native: jdbc:ch://127.0.0.1:9004/default?protocol=native&ssl=false&user=admin&password=123
```

### Elasticsearch (3 ноды) + Kibana
- Elasticsearch: http://localhost:9200 (внутри: es01:9200, es02:9200, es03:9200)
- Kibana: http://localhost:5601
- Hunspell словари: services/elasticsearch/hunspell/ru_RU → /usr/share/elasticsearch/config/hunspell/ru_RU

### MinIO (S3)
- Console: http://localhost:9001 (minioadmin/minioadminpass)
- API: http://localhost:9000
- Пример (mc): `mc alias set local http://localhost:9000 minioadmin minioadminpass`

### Centrifugo
- UI: http://localhost:8000 (логин admin; пароль из services/centrifugo/config.json → admin_password)
- WS: ws://localhost:8000/connection/websocket

### Nginx + PHP‑FPM
- 80/443 на хосте; внутри: php-fpm:9000
- Проверка: `curl -k https://localhost/healthz`

### MailHog
- UI: http://localhost:8025 (также https://localhost/mailhog/ через Nginx)


## Устранение неполадок
- Порты заняты: освободите 80/443/5432/6379/9200/9000/9001/9004/8000
- Сертификаты: самоподписанные — используйте -k в curl или добавьте в доверенные
- Healthcheck не становится healthy: проверьте логи `make logs-tail SERVICE=<имя>`
- DNS внутри сети: проверьте `docker network inspect infrastructure` и `ping postgres-master` из контейнера
- Сброс окружения: `make down DOWN_FLAGS="--volumes" && make init`


## Приложение A: Elasticsearch + Hunspell тесты
Ниже приведён полный набор запросов для проверки морфологии (Hunspell), устойчивости к опечаткам (fuzzy), suggesters и поиска по префиксу. Для удобства установлен jq.

0) Проверка кластера:
```
curl -sS http://localhost:9200
```

1) Удалить индекс, если существовал:
```
curl -sS -X DELETE "http://localhost:9200/ru_hunspell_test" | jq . 2>/dev/null || true
```

2) Создать индекс с анализаторами и маппингом:
```
curl -sS -X PUT "http://localhost:9200/ru_hunspell_test" \
-H 'Content-Type: application/json' \
-d '{
  "settings": {
    "analysis": {
      "char_filter": { "yo_to_e": { "type": "mapping", "mappings": ["ё=>е", "Ё=>Е"] } },
      "filter": {
        "ru_hunspell": { "type": "hunspell", "locale": "ru_RU", "dedup": true },
        "ru_shingles": { "type": "shingle", "min_shingle_size": 2, "max_shingle_size": 3, "output_unigrams": false },
        "edge_2_20": { "type": "edge_ngram", "min_gram": 2, "max_gram": 20 }
      },
      "analyzer": {
        "ru_hunspell_analyzer": { "tokenizer": "standard", "char_filter": ["yo_to_e"], "filter": ["lowercase", "ru_hunspell"] },
        "ru_trigrams_analyzer": { "tokenizer": "standard", "char_filter": ["yo_to_e"], "filter": ["lowercase", "ru_hunspell", "ru_shingles"] },
        "ru_prefix_analyzer": { "tokenizer": "standard", "char_filter": ["yo_to_e"], "filter": ["lowercase", "edge_2_20"] }
      }
    }
  },
  "mappings": { "properties": {
    "title": { "type": "text", "analyzer": "ru_hunspell_analyzer" },
    "text": { "type": "text", "analyzer": "ru_hunspell_analyzer",
      "fields": {
        "trigrams": { "type": "text", "analyzer": "ru_trigrams_analyzer" },
        "prefix": { "type": "text", "analyzer": "ru_prefix_analyzer", "search_analyzer": "ru_hunspell_analyzer" }
      }
    },
    "suggest": { "type": "completion", "preserve_separators": true, "preserve_position_increments": true }
  }}
}'
```

3) Анализатор (пример):
```
curl -sS -X POST "http://localhost:9200/ru_hunspell_test/_analyze" \
-H 'Content-Type: application/json' \
-d '{ "analyzer": "ru_hunspell_analyzer", "text": "проверяющего" }'
```

4) Bulk‑индексация примеров:
```
curl -sS -X POST "http://localhost:9200/ru_hunspell_test/_doc/_bulk?refresh=true" \
-H 'Content-Type: application/x-ndjson' \
--data-binary $'
{"index":{}}
{"title":"Быстрая машина","text":"Быстрая машина едет по дороге","suggest":["быстрая машина","машина"]}
{"index":{}}
{"title":"Проверяющий документ","text":"Сотрудник проверяющий отчёты нашёл ошибку","suggest":["проверяющий","отчёт","документ"]}
{"index":{}}
{"title":"Машины и двигатели","text":"Ремонт машины и двигателя","suggest":["ремонт машины","двигатель"]}
'
```

5) Примеры запросов:
- Fuzzy‑поиск опечатки:
```
curl -sS -X POST "http://localhost:9200/ru_hunspell_test/_search" \
-H 'Content-Type: application/json' \
-d '{
  "query": { "match": { "text": { "query": "машиа", "fuzziness": "AUTO", "prefix_length": 1, "max_expansions": 50, "fuzzy_transpositions": true } } }
}' | jq '.hits.hits[]._source'
```
- Multi‑match с бустами:
```
curl -sS -X POST "http://localhost:9200/ru_hunspell_test/_search" \
-H 'Content-Type: application/json' \
-d '{
  "query": { "multi_match": { "query": "быстрая машиа", "fields": ["title^3", "text^2", "text.prefix"], "fuzziness": "AUTO", "prefix_length": 1 } }
}' | jq '.hits.hits[]._source'
```
- Term suggester:
```
curl -sS -X POST "http://localhost:9200/ru_hunspell_test/_search" \
-H 'Content-Type: application/json' \
-d '{ "size": 0, "suggest": { "term_s": { "text": "машиа", "term": { "field": "text", "suggest_mode": "always", "min_word_length": 3, "string_distance": "ngram" } } } }' | jq .suggest.term_s
```
- Phrase suggester (шинглы text.trigrams):
```
curl -sS -X POST "http://localhost:9200/ru_hunspell_test/_search" \
-H 'Content-Type: application/json' \
-d '{ "size": 0, "suggest": { "phrase_s": { "text": "быстая машиа", "phrase": { "field": "text.trigrams", "analyzer": "ru_hunspell_analyzer", "gram_size": 2, "max_errors": 2, "confidence": 0.0, "highlight": {"pre_tag":"<em>","post_tag":"</em>"}, "direct_generator": [ { "field": "text", "suggest_mode": "always", "min_word_length": 2, "prefix_length": 1, "max_edits": 2, "string_distance": "ngram" } ] } } } }' | jq '.suggest.phrase_s[0].options'
```
- Completion suggester:
```
curl -sS -X POST "http://localhost:9200/ru_hunspell_test/_search" \
-H 'Content-Type: application/json' \
-d '{ "size": 0, "suggest": { "auto": { "prefix": "маш", "completion": { "field": "suggest", "skip_duplicates": true } } } }' | jq .suggest.auto
```
- Search‑as‑you‑type через edge_ngram:
```
curl -sS -X POST "http://localhost:9200/ru_hunspell_test/_search" \
-H 'Content-Type: application/json' \
-d '{ "query": { "match": { "text.prefix": { "query": "маш", "operator": "and" } } } }' | jq '.hits.hits[]._source'
```

6) Диагностика анализаторов:
```
curl -sS -X POST "http://localhost:9200/ru_hunspell_test/_analyze" \
-H 'Content-Type: application/json' \
-d '{ "analyzer": "ru_hunspell_analyzer", "text": "отчёт" }'
```

Подсказки: регулируйте prefix_length и max_expansions для fuzzy; edge_ngram повышает объём индекса; для phrase suggester используйте поле‑шинглы.
