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
