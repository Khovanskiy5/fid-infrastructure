local cartridge = require('cartridge')
local fiber = require('fiber')
local log = require('log')
local http_client = require('http.client')
local json = require('json')

-- Конфигурация из окружения
local db_user         = os.getenv('DB_USER')
local db_password     = os.getenv('DB_PASSWORD')
local centrifugo_url  = os.getenv('CENTRIFUGO_URL')
local centrifugo_auth = os.getenv('CENTRIFUGO_AUTH')
local batch_size      = tonumber(os.getenv('VOTING_PUBLISH_BATCH') or '500')
local loop_idle_sec   = tonumber(os.getenv('VOTING_LOOP_IDLE_SEC') or '0.5')
local http_timeout    = tonumber(os.getenv('VOTING_HTTP_TIMEOUT_SEC') or '2')
local http_connect_to = tonumber(os.getenv('VOTING_HTTP_CONNECT_TIMEOUT_SEC') or '1')

-- Глобальное состояние роли
local state = {
    leader = false,           -- Единственный источник истины о лидерстве
    stop = false,             -- Флаг остановки всех фоновых задач
    publish_fiber = nil,      -- Файбер, который публикует события в Centrifugo
    http = nil,               -- HTTP клиент с keepalive
    config_ok = false,        -- Валидность конфигурации для публикации
}


-- Утилита: безопасно маскировать секрет в логах
local function mask(s)
    if type(s) ~= 'string' then return s end
    if #s <= 6 then return '***' end
    return s:sub(1, 3) .. '***' .. s:sub(-3)
end

-- Утилита: wall-clock время (os.clock считает CPU-время процесса)
local function now() return fiber.time() end

-- Проверка, что URL HTTPS — тогда включаем проверку TLS
local function is_https(url)
    return type(url) == 'string' and url:match('^https://') ~= nil
end

-- Создание/получение клиента HTTP с keepalive.
local function get_http()
    if state.http ~= nil then return state.http end
    local ok, client = pcall(function() return http_client.new() end)
    if ok and client then
        state.http = client
    else
        -- fallback: сохраним маркер отсутствия клиентского объекта
        state.http = nil
    end
    return state.http
end

-- Совместимая обёртка для POST: если есть клиент с методом post, используем его,
-- иначе используем модульную функцию http_client.post
local function http_post(client, url, body, opts)
    if client and type(client.post) == 'function' then
        return client:post(url, body, opts)
    else
        return http_client.post(url, body, opts)
    end
end

-- Валидация конфигурации публикатора
local function validate_publish_config()
    if centrifugo_url == nil or centrifugo_url == '' then
        log.warn('CENTRIFUGO_URL не задан — публикация отключена')
        return false
    end
    if centrifugo_auth == nil or centrifugo_auth == '' then
        log.warn('CENTRIFUGO_AUTH не задан — публикация отключена')
        return false
    end
    return true
end

-- Получение необходимых объектов схемы и индексов
local function get_stat_space()
    return box.space.VOTES_STAT
end

-- Возвращает индекс для итерации (если есть stat_index_full — используем его, иначе primary)
local function get_iter_index(space)
    if not space then return nil end
    if space.index and space.index.stat_index_full then
        return space.index.stat_index_full
    end
    return space.index[0]
end

-- Извлечь ключ первичного индекса из переданного кортежа для безопасного удаления
local function extract_primary_key(space, tuple)
    local pk = space and space.index and (space.index[0] or space.index.primary)
    if not pk or not pk.parts then return nil end
    local key = {}
    for i = 1, #pk.parts do
        local part = pk.parts[i]
        -- В Tarantool fieldno — 1-индексация
        local fieldno = part.fieldno or part.field
        key[#key + 1] = tuple[fieldno]
    end
    return key
end

-- Построение имени канала публикации по entity/decision
local function build_channel(entity, decision)
    local dnum = tonumber(decision)
    if dnum and dnum ~= 0 then
        return tostring(entity) .. '-' .. tostring(dnum)
    else
        return tostring(entity)
    end
end

-- Публикация в centrifugo счетчиков
local function publish_batch(client, url, token, commands)
    -- Карта успешных публикаций по индексу команды
    local success_by_index = {}

    local request_options = {
        headers = { ['Content-Type'] = 'application/json', Authorization = token },
        timeout = http_timeout,
        connect_timeout = http_connect_to,
        keepalive_idle = 30,
        verify_peer = is_https(url),
        verify_host = is_https(url),
    }

    do
        local has_success = false
        for i = 1, #commands do
            local command = commands[i]
            local request_body
            local ok_encode, encode_err = pcall(function()
                request_body = json.encode({ method = command.method, params = command.params })
            end)
            if not ok_encode then
                log.error('JSON encode - ошибка: %s', tostring(encode_err))
            else
                local response
                local ok_http, http_err = pcall(function()
                    response = http_post(client, url, request_body, request_options)
                end)
                if ok_http and response and response.status == 200 then
                    local ok_decode, decoded_body = pcall(function() return json.decode(response.body or '') end)
                    if ok_decode and decoded_body and decoded_body.error == nil then
                        success_by_index[i] = true
                        has_success = true
                    else
                        local response_preview = response and response.body and tostring(response.body):sub(1,256) or ''
                        log.error('Publish: ответ с ошибкой/непонятный: %s', response_preview)
                    end
                else
                    local status_code = response and response.status or 'nil'
                    local response_preview = response and response.body and tostring(response.body):sub(1,256) or ''
                    if not ok_http then
                        log.error('Publish неуспешен: http_err=%s, req_preview=%s ..., resp_preview=%s ...', tostring(http_err), tostring(request_body):sub(1, 256), response_preview)
                    else
                        log.error('Publish неуспешен: status=%s, req_preview=%s ..., resp_preview=%s ...', tostring(status_code), tostring(request_body):sub(1, 256), response_preview)
                    end
                end
            end
        end
        if has_success then
            return success_by_index
        else
            return nil, 'Publish: Публикация не удалась'
        end
    end

end

-- Файбер публикации событий
local function publish_worker()
    log.info('Публикатор запущен')

    local client = get_http()
    local url = centrifugo_url
    local token = centrifugo_auth

    local error_backoff = 0.5

    while not state.stop do
        -- Публикуем только на лидере, при валидной конфигурации и когда инстанс не read-only
        if not state.leader or not state.config_ok or (box.info ~= nil and box.info.ro) then
            fiber.sleep(loop_idle_sec)
        else
            local space = get_stat_space()
            if space == nil or space:len() == 0 then
                fiber.sleep(loop_idle_sec)
            else
                local idx = get_iter_index(space)
                if not idx then
                    log.error('Не найден индекс для VOTES_STAT — публикация временно остановлена')
                    fiber.sleep(1)
                else
                    -- Собираем батч и одновременно подготавливаем ключи для последующего удаления
                    local batch = {}
                    local del_keys = {}
                    local batch_count = 0
                    for _, t in idx:pairs(nil, { iterator = 'ALL' }) do
                        -- Безопасное извлечение полей
                        local entity   = (t.service_entity_id ~= nil) and t.service_entity_id or t[1]
                        local decision = (t.service_decision_id ~= nil) and t.service_decision_id or t[2]
                        local hash     = (t.bch_hash_number ~= nil)   and t.bch_hash_number   or t[3]

                        if entity == nil or decision == nil or hash == nil then
                            log.warn('VOTES_STAT: пропуск записи (entity/decision/hash отсутствуют): entity=%s, decision=%s, hash=%s', tostring(entity), tostring(decision), tostring(hash))
                        else
                            -- Формируем имя канала по entity/decision
                            local channel = build_channel(entity, decision)

                            -- Отправляем объект с ключом bch_hash_number
                            local data = { bch_hash_number = tostring(hash) }

                            batch_count = batch_count + 1
                            batch[batch_count] = {
                                method = 'publish',
                                params = { channel = channel, data = data },
                            }
                            -- Сохраняем первичный ключ для точного удаления
                            local key = extract_primary_key(space, t)
                            del_keys[batch_count] = key
                            if batch_count >= batch_size then
                                break
                            end
                        end
                    end

                    if batch_count == 0 then
                        fiber.sleep(loop_idle_sec)
                    else
                        local started = now()
                        local successes, err = publish_batch(client, url, token, batch)
                        if successes then
                            -- Удаляем только те кортежи, которые успешно опубликованы
                            local deleted = 0
                            local sent = 0
                            local remove_ok, remove_err = pcall(function()
                                box.atomic(function()
                                    for i = 1, batch_count do
                                        if successes[i] then
                                            sent = sent + 1
                                            local key = del_keys[i]
                                            if key then
                                                local ok_del = pcall(function() space:delete(key) end)
                                                if ok_del then deleted = deleted + 1 end
                                            end
                                        end
                                    end
                                end)
                            end)
                            if not remove_ok then
                                log.error('Ошибка удаления обработанных записей: %s', remove_err)
                            else
                                log.info('%d/%d сообщений опубликовано за %.3f сек. Удалено %d записей', sent, batch_count, now() - started, deleted)
                            end
                            error_backoff = 0.5
                            -- Позволяем другим файберам поработать
                            fiber.yield()
                        else
                            log.error('Ошибка публикации: %s (url=%s, Authorization=%s)', err, url, mask(token))
                            -- Экспоненциальный бэкофф с ограничением до 5 секунд
                            error_backoff = math.min(error_backoff * 2, 5)
                            fiber.sleep(error_backoff)
                        end
                    end
                end
            end
        end
    end

    log.info('Публикатор остановлен')
end

-- Инициализация роли Cartridge
local function init(opts)

    state.leader = opts.is_master or false
    state.stop = false
    state.config_ok = validate_publish_config()


    -- Инициализация схемы (минимальная)
    if opts.is_master then
        box.once('schema', function()
            if db_user ~= nil and db_user ~= '' then
                -- Создание пользователя и прав (идемпотентно).
                box.schema.user.create(db_user, { password = db_password, if_not_exists = true })
                box.schema.user.grant(db_user, 'read,write,execute,create,drop,alter', 'universe', nil, { if_not_exists = true })
            else
                log.warn('DB_USER не задан; пропускаем создание пользователя БД')
            end
        end)
    end

    -- Файбер публикации
    state.publish_fiber = fiber.new(publish_worker)
    state.publish_fiber:name('publish_worker')

    return true
end

-- Корректная остановка всех фоновых задач
local function stop()
    state.stop = true
    if state.publish_fiber then pcall(function() state.publish_fiber:cancel() end) end
    return true
end

-- Валидация конфигурации Cartridge
local function validate_config(conf_new, conf_old) -- luacheck: no unused args
    return true
end

-- Применение конфигурации (реакция на смену роли)
local function apply_config(conf, opts) -- luacheck: no unused args
    -- Обновляем флаг лидерства согласно Cartridge
    state.leader = opts.is_master or false
    -- Перепроверяем валидность конфигурации публикации
    state.config_ok = validate_publish_config()
    return true
end

return {
    role_name = 'app.roles.voting',
    init = init,
    stop = stop,
    validate_config = validate_config,
    apply_config = apply_config,
}
