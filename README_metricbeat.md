## Приложение Б: Мониторинг Elasticsearch (Metricbeat)

Для отображения метрик в Kibana → Stack Monitoring добавлен сервис Metricbeat.

Запуск только Metricbeat:

```
docker compose up -d metricbeat
```

После запуска перейдите в Kibana → Stack Monitoring → Overview — ноды Elasticsearch  появятся в списке.

Детали:
- Конфиг: services/metricbeat/metricbeat.yml (включены модули elasticsearch и kibana с xpack.enabled: true)
- Подключение: http://elasticsearch-1:9200, http://elasticsearch-2:9200, http://elasticsearch-3:9200 и http://kibana:5601