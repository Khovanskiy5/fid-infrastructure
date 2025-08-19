-- Надёжные admin-команды для "cartridge admin"
-- Добавлена идемпотентность, безопасные require и обработка ошибок.

local log = require('log')

local inited = false -- флаг, чтобы не регистрировать команды повторно

local function safe_err_to_string(e)
    if e == nil then return 'unknown error' end
    if type(e) == 'table' then
        return e.err or e.message or (pcall(require, 'json') and require('json').encode(e) or tostring(e))
    end
    return tostring(e)
end

local function init()
    if inited then
        return true
    end

    -- Пытаемся загрузить расширения CLI для регистрации команд.
    local ok_cli, cli_admin = pcall(require, 'cartridge-cli-extensions.admin')
    if not ok_cli or not cli_admin or type(cli_admin.register) ~= 'function' then
        log.warn('cartridge-cli-extensions.admin недоступен; admin-команды не будут зарегистрированы')
        inited = true
        return true
    end

    -- Инициализируем CLI-надстройку, не падая при ошибках.
    local ok_init, err_init = pcall(function() return cli_admin.init() end)
    if not ok_init then
        log.error('cli_admin.init завершился ошибкой: %s', tostring(err_init))
        -- Продолжаем, попробуем всё равно зарегистрировать команды.
    end

    -- Определяем команду probe с дополнительной валидацией и безопасной обработкой ошибок.
    local probe = {
        usage = 'Проверить доступность инстанса',
        args = {
            uri = {
                type = 'string',
                usage = 'URI инстанса (host:port)',
            },
        },
        call = function(opts)
            opts = opts or {}
            local uri = opts.uri
            if type(uri) ~= 'string' or uri == '' then
                return nil, 'Укажите URI инстанса через --uri'
            end

            -- cartridge.admin может быть недоступен, оборачиваем в pcall
            local ok_ca, cartridge_admin = pcall(require, 'cartridge.admin')
            if not ok_ca or not cartridge_admin or type(cartridge_admin.probe_server) ~= 'function' then
                return nil, 'Модуль cartridge.admin недоступен или не поддерживает probe_server'
            end

            -- Вызов самой проверки с защитой от исключений
            local ok_call, ok_probe, err = pcall(cartridge_admin.probe_server, uri)
            if not ok_call then
                return nil, ('Исключение при вызове probe_server: %s'):format(tostring(ok_probe))
            end
            if not ok_probe then
                return nil, safe_err_to_string(err)
            end

            return {string.format('Probe %q: OK', uri)}
        end,
    }

    -- Регистрируем команду безопасно, без assert
    local ok_reg_call, ok_reg, reg_err = pcall(cli_admin.register, 'probe', probe.usage, probe.args, probe.call)
    if not ok_reg_call then
        log.error('Не удалось зарегистрировать команду probe (исключение): %s', tostring(ok_reg))
    elseif not ok_reg then
        log.error('Регистрация команды probe отклонена: %s', safe_err_to_string(reg_err))
    end

    inited = true
    return true
end

return { init = init }
