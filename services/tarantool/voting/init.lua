#!/usr/bin/env tarantool

-- Включаем строгий режим для раннего выявления ошибок
require('strict').on()

local log = require('log')


-- 2) Корректируем пути поиска модулей, чтобы запускаться из любого каталога
if package.setsearchroot ~= nil then
    package.setsearchroot()
else
    -- Совместимость с tarantool 1.10: добавляем пути до .rocks и модулей приложения
    local fio = require('fio')
    local app_dir = fio.abspath(fio.dirname(arg[0]))
    package.path = app_dir .. '/?.lua;' .. package.path
    package.path = app_dir .. '/?/init.lua;' .. package.path
    package.path = app_dir .. '/.rocks/share/tarantool/?.lua;' .. package.path
    package.path = app_dir .. '/.rocks/share/tarantool/?/init.lua;' .. package.path
    package.cpath = app_dir .. '/?.so;' .. package.cpath
    package.cpath = app_dir .. '/?.dylib;' .. package.cpath
    package.cpath = app_dir .. '/.rocks/lib/tarantool/?.so;' .. package.cpath
    package.cpath = app_dir .. '/.rocks/lib/tarantool/?.dylib;' .. package.cpath
end

-- Утилиты для чтения конфигурации из окружения с безопасными значениями по умолчанию
local fio = require('fio')
local function getenv_num(name, default)
    local v = os.getenv(name)
    local n = v and tonumber(v)
    if n and n > 0 then return n end
    return default
end

local function getenv_bool(name, default)
    local v = os.getenv(name)
    if v == nil then return default end
    v = tostring(v):lower()
    return v == '1' or v == 'true' or v == 'yes' or v == 'on'
end

-- 3) Лог: убеждаемся, что каталог существует; путь можно переопределить через TARANTOOL_LOG
local log_path = os.getenv('TARANTOOL_LOG') or '/var/log/tarantool/voting.log'
pcall(function()
    local dir = fio.dirname(log_path)
    if dir and dir ~= '' then fio.mktree(dir) end
end)

-- 4) box.cfg: параметры настраиваются через окружение
local memtx_bytes = tonumber(os.getenv('MEMTX_MEMORY_BYTES'))
if not memtx_bytes then
    memtx_bytes = getenv_num('MEMTX_MEMORY_MB', 512) * 1024 * 1024 -- по умолчанию 512MB
end

local box_cfg_options = {
    -- Базовые настройки хранилища и WAL
    memtx_memory = memtx_bytes,
    memtx_max_tuple_size = getenv_num('MEMTX_MAX_TUPLE_MB', 10) * 1024 * 1024,
    wal_mode = os.getenv('WAL_MODE') or 'write',
    readahead = getenv_num('READAHEAD', 10485760),
    net_msg_max = getenv_num('NET_MSG_MAX', 4096),
    worker_pool_threads = getenv_num('WORKER_POOL_THREADS', 16),
    memtx_use_mvcc_engine = getenv_bool('MEMTX_USE_MVCC', false),

    -- Логирование
    log = log_path,
    log_format = os.getenv('TARANTOOL_LOG_FORMAT') or 'json',
    log_level = getenv_num('TARANTOOL_LOG_LEVEL', 4),
}

-- 5) Инициализация Cartridge и ролей с повышенной устойчивостью
local cartridge = require('cartridge')

-- Без аварийного завершения, если модули отсутствуют: просто предупреждаем
local ok_membership, membership_opts = pcall(require, 'membership.options')
if ok_membership and membership_opts then
    -- Уменьшаем размер UDP пакета для совместимости со средами с маленьким MTU
    membership_opts.MAX_PACKET_SIZE = 1432 -- 1500 - 60 - 8
else
    log.warn('module membership.options недоступен; пропускаем настройку MAX_PACKET_SIZE')
end

local ok_vshard, vshard_consts = pcall(require, 'vshard.consts')
if ok_vshard and vshard_consts then
    -- Ускоряем обнаружение бакетов после рестарта
    vshard_consts.BUCKET_CHUNK_SIZE = 30000
else
    log.warn('module vshard.consts недоступен; пропускаем тюнинг BUCKET_CHUNK_SIZE')
end


local app_cfg = {
    roles = {
        'cartridge.roles.vshard-storage',
        'cartridge.roles.vshard-router',
        'cartridge.roles.metrics',
        'app.roles.voting',
    },
}

-- Optionally disable WebUI to suppress GraphQL spam if desired
app_cfg.webui_enabled = getenv_bool('WEBUI_ENABLED', true)
local ok, err = cartridge.cfg(app_cfg, box_cfg_options)

assert(ok, tostring(err))

-- 6) Регистрация админ-команд; не падаем при ошибках, просто логируем
local ok_admin, admin = pcall(require, 'app.admin')
if ok_admin and admin and type(admin.init) == 'function' then
    local ok_ai, err_ai = pcall(admin.init)
    if not ok_ai then
        log.error('admin.init завершился ошибкой: %s', tostring(err_ai))
    end
else
    log.warn('модуль app.admin недоступен; команды admin не будут зарегистрированы')
end

-- 7) Экспорт метрик и health с защитой от ошибок
local ok_metrics, metrics = pcall(require, 'cartridge.roles.metrics')
if ok_metrics and metrics and type(metrics.set_export) == 'function' then
    local ok_me, err_me = pcall(function()
        metrics.set_export({
            { path = '/metrics', format = 'prometheus' },
            { path = '/health', format = 'health' },
        })
    end)
    if not ok_me then
        log.error('metrics.set_export завершился ошибкой: %s', tostring(err_me))
    end
else
    log.warn('роль metrics недоступна; эндпоинты /metrics и /health не будут настроены')
end

-- 8) Явный простой эндпоинт готовности, всегда 200 OK
local ok_httpd, httpd = pcall(require('cartridge').service_get, 'httpd')
if ok_httpd and httpd then
    local ok_route, err_route = pcall(function()
        httpd:route({ path = '/ready', method = 'GET' }, function()
            return { status = 200, body = 'OK' }
        end)
    end)
    if not ok_route then
        log.error('не удалось зарегистрировать /ready: %s', tostring(err_route))
    end
else
    log.warn('httpd сервис недоступен; /ready не будет зарегистрирован')
end

local confapplier = require('cartridge.confapplier')
if ok_httpd and httpd then
    httpd:route({ path = '/state', method = 'GET' }, function()
        local st = confapplier.get_state() -- например: 'ConfigLoaded', 'RolesConfigured', 'Ready'
        return { status = 200, body = st }
    end)
end
