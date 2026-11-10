--[[
    Автозаточка Arizona (CEF). Команда /mt
]]
script_name('AutoZatochka')
script_version('1.26')
script_author('andergr0ynd')
script_description('Автозаточка Arizona: одежда, оружие, Эликсир мастер (карты)')

local ok_ev, sampev = pcall(require, 'lib.samp.events')
if not ok_ev then ok_ev, sampev = pcall(require, 'samp.events') end
if not ok_ev then sampev = nil end
local ok_imgui, imgui = pcall(require, 'mimgui')
if not ok_imgui then
    function main()
        while not isSampAvailable() do wait(100) end
        sampAddChatMessage(u8:decode('[AutoZatochka] Нужен mimgui'), -1)
    end
    return
end
local ok_cef, cefDlg = pcall(require, 'arizona-cef-dialogs')
if not ok_cef then cefDlg = nil end
local encoding = require 'encoding'
encoding.default = 'CP1251'
local u8 = encoding.UTF8
local new = imgui.new

-- Arizona CEF: подключается в main() после проверки файлов (см. bootstrap библиотек)
local arizona = nil

-- == Settings == --
local WinState, playSound, SetWin = new.bool(), new.bool(), new.bool()
local status = false
local max_toch = 0

-- Звук при успешной заточке (скачивается с GitHub / CDN)
local GITHUB_RAW_BASE = 'https://github.com/andergr0ynd/zatochka/raw/refs/heads/main/'
local GITHUB_CDN_BASE = 'https://cdn.jsdelivr.net/gh/andergr0ynd/zatochka@main/'
local RAW_GH_BASE = 'https://raw.githubusercontent.com/andergr0ynd/zatochka/refs/heads/main/'
local SOUND_FILENAME = 'applepay.mp3'
local SOUND_SUBDIR = 'autozatochka'
local success_sound_stream = nil

local function ensureDirForFile(path)
    local dir = path:match('^(.*\\)[^\\]+$')
    if dir and not doesDirectoryExist(dir) then
        createDirectory(dir)
    end
end

local function readFileHead(path, n)
    local f = io.open(path, 'rb')
    if not f then return '' end
    local s = f:read(n or 64) or ''
    f:close()
    return s
end

local function contentLooksLikeHtml(data)
    if not data or #data == 0 then return true end
    local head = data:sub(1, 64):lower()
    return head:find('^<!doctype') ~= nil or head:find('^<html') ~= nil
end

local function writeBinaryFile(path, data)
    if not data or #data == 0 then return false end
    ensureDirForFile(path)
    local f = io.open(path, 'wb')
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

-- MoonLoader downloadUrlToFile + fallback через lib/requests (luasocket)
local function downloadViaRequests(url, path, timeout_sec)
    local ok_req, requests = pcall(require, 'requests')
    if not ok_req or not requests or not requests.get then return false end
    local bust = url .. (url:find('?', 1, true) and '&' or '?') .. 't=' .. tostring(os.clock())
    local ok, resp = pcall(requests.get, bust, {
        timeout = timeout_sec or 30,
        allow_redirects = true,
        headers = { ['User-Agent'] = 'MoonLoader-AutoZatochka/6.20' },
    })
    if not ok or not resp or not resp.text or #resp.text == 0 then return false end
    if resp.status_code and resp.status_code >= 400 then return false end
    if contentLooksLikeHtml(resp.text) then return false end
    return writeBinaryFile(path, resp.text)
end

local function downloadViaMoonLoader(url, path, timeout_sec)
    if type(downloadUrlToFile) ~= 'function' then return false end
    local ml_ok, ml = pcall(require, 'moonloader')
    if not ml_ok or not ml or not ml.download_status then return false end
    local d = ml.download_status
    local bust = url .. (url:find('?', 1, true) and '&' or '?') .. 't=' .. tostring(os.clock())
    local done, success = false, false
    downloadUrlToFile(bust, path, function(_, status)
        if status == d.STATUSEX_ENDDOWNLOAD or status == d.STATUS_ENDDOWNLOADDATA then
            done = true
            success = true
        end
    end)
    local t0 = os.clock()
    while not done and os.clock() - t0 < (timeout_sec or 45) do wait(50) end
    if not success or not doesFileExist(path) then return false end
    wait(200)
    return not contentLooksLikeHtml(readFileHead(path, 128))
end

local function downloadToFile(url, path, timeout_sec)
    ensureDirForFile(path)
    if doesFileExist(path) then
        pcall(os.remove, path)
    end
    if downloadViaMoonLoader(url, path, timeout_sec) then return true end
    if doesFileExist(path) then
        pcall(os.remove, path)
    end
    if downloadViaRequests(url, path, timeout_sec) then return true end
    return false
end

-- Пробует несколько зеркал (jsDelivr часто доступен, когда github.com заблокирован)
local function downloadToFileMirrors(urls, path, timeout_sec)
    for _, url in ipairs(urls) do
        if downloadToFile(url, path, timeout_sec) then
            return true, url
        end
    end
    return false, nil
end

local function mirrorUrlsFor(relative_path)
    return {
        GITHUB_CDN_BASE .. relative_path,
        RAW_GH_BASE .. relative_path,
        GITHUB_RAW_BASE .. relative_path,
    }
end

local as_action = require('moonloader').audiostream_state

if not decodeJson then
    local ok, j = pcall(require, 'json')
    if ok and j and j.decode then decodeJson = j.decode end
end
if type(decodeJson) == 'function' and not _G.__azJsonWrapped then
    _G.__azJsonWrapped = true
    local rawDecodeJson = decodeJson
    decodeJson = function(s)
        if type(s) ~= 'string' then return nil end
        local t = s:gsub('^%s+', ''):gsub('%s+$', '')
        local c = t:sub(1, 1)
        if c == '[' then
            if t:match('^%[%s*%]') then return {} end
            t = '{"az":' .. t .. '}'
        else
            if c ~= '{' then
                return nil
            end
        end
        local ok, data = pcall(rawDecodeJson, t)
        if not ok or data == nil then return nil end
        if c == '[' then
            if type(data) == 'table' then return data.az end
            return nil
        end
        return data
    end
end


local function safeDecodeJson(raw)
    if type(raw) ~= 'string' or not decodeJson then return false, nil end
    local s = raw:gsub('^%s+', ''):gsub('%s+$', '')
    if s == '' or s == 'null' then return false, nil end
    if s:sub(1, 1) ~= '{' then return false, nil end
    local ok, data = pcall(decodeJson, s)
    if not ok or data == nil then return false, nil end
    return true, data
end

local incomingCef, incomingChat = {}, {}
local function queueCef(str)
    if type(str) ~= 'string' or str == '' then return end
    if str:find('playerInventory', 1, true) then
        pcall(parsePlayerInventory, str)
        return
    end
    if str:find('event.storage', 1, true) then return end
    local keep = str:find('workShop', 1, true)
        or str:find('setWorkshop', 1, true)
        or str:find('setResourceNeedItems', 1, true)
        or str:find('updateEnchantSlots', 1, true)
        or str:find('event.notify.initialize', 1, true)
        or str:find('startEnchant', 1, true)
    if not keep then return end
    incomingCef[#incomingCef + 1] = str .. ''
    if #incomingCef > 40 then table.remove(incomingCef, 1) end
end
local function queueChat(text)
    if type(text) ~= 'string' or text == '' then return end
    incomingChat[#incomingChat + 1] = text .. ''
    if #incomingChat > 40 then table.remove(incomingChat, 1) end
end

-- Синхронизация lib/arizona-events с GitHub -> moonloader\lib\arizona-events
-- Источник на GitHub: zatochka/arizona-events/*.lua (raw). На диск: moonloader\lib\arizona-events\
-- Если файлов нет или они битые — скрипт качает, перезагружается, затем продолжает работу.
local LIB_ARIZONA_EVENTS_DIR = 'lib\\arizona-events'
local LIB_ARIZONA_EVENTS_FILES = { 'init.lua', 'core.lua', 'bitstream.lua', 'subprocess.lua' }

local function libFileLooksBad(path)
    local f = io.open(path, 'rb')
    if not f then return true end
    local s = f:read('*a') or ''
    f:close()
    if #s < 32 then return true end
    return contentLooksLikeHtml(s)
end

local function arizonaEventsLibPaths()
    local root = getWorkingDirectory()
    local dir = root .. '\\' .. LIB_ARIZONA_EVENTS_DIR
    return root, dir
end

-- У части пользователей нет папки lib\arizona-events — создаём lib и вложенную arizona-events отдельно
local function ensureArizonaEventsLibDir()
    local root, dir = arizonaEventsLibPaths()
    local libDir = root .. '\\lib'
    if not doesDirectoryExist(libDir) then
        createDirectory(libDir)
    end
    if not doesDirectoryExist(dir) then
        createDirectory(dir)
    end
end

local function arizonaEventsLibPresent()
    local _, dir = arizonaEventsLibPaths()
    for _, name in ipairs(LIB_ARIZONA_EVENTS_FILES) do
        local path = dir .. '\\' .. name
        if not doesFileExist(path) or libFileLooksBad(path) then
            return false
        end
    end
    return true
end

-- force_all: скачать все файлы заново (первый запуск / восстановление)
-- возвращает true, если после операции все четыре файла на месте и валидны
local function syncArizonaEventsLib(force_all)
    ensureArizonaEventsLibDir()
    local _, dir = arizonaEventsLibPaths()
    local all_ok = true
    for _, name in ipairs(LIB_ARIZONA_EVENTS_FILES) do
        local path = dir .. '\\' .. name
        local need = force_all or not doesFileExist(path) or libFileLooksBad(path)
        if need then
            local rel = 'arizona-events/' .. name
            local ok = downloadToFileMirrors(mirrorUrlsFor(rel), path, 45)
            if not ok or libFileLooksBad(path) then
                all_ok = false
                if doesFileExist(path) then pcall(os.remove, path) end
            end
        end
    end
    return all_ok and arizonaEventsLibPresent()
end

-- Stone
local workshop_check = false
local lost_stone_onLVL, all_lost = 0, 0
local lost_stone = {}
local enchantSlotsData = { index = -1, left = -1, right = -1, color = -1 }
local ws = {
    available = 0,
    busy = false,
    busyAt = 0,
    pendingResult = nil,
    stoneSlot = -1,
    stoneAmount = 0,
    itemSlot = -1,
    itemId = -1,
    itemEnchant = -1,
    leftNeed = 0,
    rightNeed = 1,
    lastPlaceAt = 0,
    tab = 0,
    gunCtx = false,
    resSlot = -1,
    resAmount = 0,
    gAll = 0,
    gLvl = 0,
    gRows = {},
    aAll = 0,
    aLvl = 0,
    aRows = {},
    dAll = 0,
    dLvl = 0,
    dRows = {},
    vAll = 0,
    vLvl = 0,
    vRows = {},
    screen = 'home',
    shop = nil,
    picker = nil,
    rightItemId = -1,
    amuletNeed = false, -- true только по чату «используйте 'Точильный амулет'»
    slots1187 = {},
    slots10253 = {},
    slots511 = {},
    slots8701 = {},
    slots510 = {},
    slots5736 = {},
    slots1420 = {},
    invTd = {},
    cefInv = false,
    -- Эликсир мастер (текстдравы): 2 карты → Улучшить
    cAll = 0,
    cLvl = 0,
    cRows = {},
    card = {
        open = false,
        seenAt = 0,
        leftTd = -1,
        rightTd = -1,
        improveTd = -1,
        leftFilled = false,
        rightFilled = false,
        improveReady = false,
        inv = {}, -- [slot] = { id, level, sel, x }
        lastClickAt = 0,
        waitingChat = false, -- после Улучшить ждём Увы/Успех
        placed = 0, -- сколько карт взяли из инвентаря в этой попытке (правый слот часто фантом)
        step = 'idle',
    },
}

-- Сетка инвентаря игрока, как в ArzMarket: экранная позиция текстдрава -> слот 0..35.
-- 6 колонок, шаг по X ~26.5; 6 рядов, шаг по Y ~30.5. Страница инвентаря = 36 слотов.
local INV_XS = { 325, 351.5, 378, 404.5, 431, 457.5 }
local INV_YS = {
    164.74285888672,
    195.24285888672,
    225.74285888672,
    256.24285888672,
    286.74285888672,
    317.24285888672,
}
local INV_GRID = {}
for row = 0, 5 do
    for col = 0, 5 do
        INV_GRID[INV_XS[col + 1] .. ', ' .. INV_YS[row + 1]] = row * 6 + col
    end
end
-- Панель инвентаря карт справа; левее — слоты верстака (не кликать как «взять карту»)
local CARD_INV_MIN_X = 310

function ws.slotFromTd(x, y)
    x, y = tonumber(x), tonumber(y)
    if not x or not y then return nil end
    local hit = INV_GRID[x .. ', ' .. y]
    if hit ~= nil then return hit end
    for row = 0, 5 do
        if math.abs(INV_YS[row + 1] - y) < 0.05 then
            for col = 0, 5 do
                if math.abs(INV_XS[col + 1] - x) < 0.05 then
                    return row * 6 + col
                end
            end
        end
    end
    return nil
end

local function nearPos(x, y, tx, ty, tol)
    x, y = tonumber(x), tonumber(y)
    if not x or not y then return false end
    tol = tol or 3
    return math.abs(x - tx) <= tol and math.abs(y - ty) <= tol
end

function ws.noteTd(id, td)
    if type(td) ~= 'table' then return end
    local pos = td.position or td
    local x = pos.x or td.x
    local y = pos.y or td.y
    local text = tostring(td.text or '')
    if text == 'INVENTORY' or text == '\x85H\x8BEH\x8FAP\x92' then
        ws.invTd = {}
        ws.cefInv = false
    elseif text == 'CLOSE' or text == '\x88AKP\x91\x8F\x92' then
        ws.invTd = {}
    end
    local slot = ws.slotFromTd(x, y)
    if slot ~= nil then
        ws.invTd[slot] = id
    end
    pcall(ws.noteCardTd, id, td, x, y, text)
end

-- Эликсир мастер: слоты верстака + карты из инвентаря справа (x>=310)
function ws.noteCardTd(id, td, x, y, text)
    id = tonumber(id) or -1
    x, y = tonumber(x), tonumber(y)
    if not x or not y or id < 0 then return end
    local model = tonumber(td.modelId or td.model or td.modelID) or 0
    local sel = td.selectable
    if sel == nil then sel = td.selectAble end
    if sel == true then sel = 1 elseif sel == false then sel = 0 else sel = tonumber(sel) or 0 end
    local c = ws.card

    if nearPos(x, y, 168.03, 182.28, 4) then
        c.leftTd = id
        c.leftFilled = (model == 19168)
        c.open = true
        c.seenAt = os.clock()
    elseif nearPos(x, y, 261.37, 193.28, 4) then
        c.rightTd = id
        c.rightFilled = (model == 19168)
        c.open = true
        c.seenAt = os.clock()
    elseif nearPos(x, y, 185.66, 258.65, 4) then
        c.improveTd = id
        c.improveReady = (sel == 1)
        c.open = true
        c.seenAt = os.clock()
    elseif nearPos(x, y, 163.26, 245.38, 4) then
        c.open = true
        c.seenAt = os.clock()
    end

    -- Инвентарь карт только справа
    if x >= CARD_INV_MIN_X and model == 19168 then
        local invSlot = ws.slotFromTd(x, y)
        if invSlot == nil then
            invSlot = 'p:' .. tostring(math.floor(x * 10)) .. ':' .. tostring(math.floor(y * 10))
        end
        local prev = c.inv[invSlot] or {}
        c.inv[invSlot] = {
            id = id,
            level = tonumber(prev.level) or -1,
            sel = sel,
            x = x,
            at = os.clock(),
        }
        c.open = true
        c.seenAt = os.clock()
    elseif x >= CARD_INV_MIN_X and (model == 1649 or model == 0) then
        local invSlot = ws.slotFromTd(x, y)
        if invSlot and c.inv[invSlot] then c.inv[invSlot] = nil end
    end

    local lvl = tonumber(text:match('LEVEL:(%d+)')) or tonumber(text:match('~w~~n~LEVEL:(%d+)'))
    if lvl and x >= CARD_INV_MIN_X then
        local bestSlot, bestD = nil, 1e9
        for col = 1, 6 do
            for row = 1, 6 do
                local sx, sy = INV_XS[col], INV_YS[row]
                local dx, dy = x - sx, y - sy
                if dx > -5 and dx < 40 and dy > -5 and dy < 30 then
                    local d = dx * dx + dy * dy
                    if d < bestD then
                        bestD = d
                        bestSlot = (row - 1) * 6 + (col - 1)
                    end
                end
            end
        end
        if bestSlot ~= nil then
            local prev = c.inv[bestSlot] or {}
            if (tonumber(prev.id) or -1) >= 0 then
                prev.level = lvl
                prev.at = os.clock()
                c.inv[bestSlot] = prev
            end
        end
    elseif lvl and c.leftFilled and nearPos(x, y, 168.03, 182.28, 50) then
        ws.itemEnchant = lvl
    end

    if c.open and not ws.busy and not c.waitingChat and (os.clock() - (tonumber(c.seenAt) or 0)) > 15 then
        c.open = false
    end
end

function ws.isCard()
    return tonumber(ws.tab) == 5
end

function ws.cardCount(maxLvl)
    maxLvl = tonumber(maxLvl) or 99
    local n = 0
    for _, info in pairs(ws.card.inv or {}) do
        local lv = tonumber(info.level)
        if lv == nil or lv < 0 then lv = 0 end
        local sel = tonumber(info.sel) or 0
        local tid = tonumber(info.id) or -1
        local ix = tonumber(info.x) or 0
        if tid >= 0 and sel == 1 and ix >= CARD_INV_MIN_X and lv < maxLvl then
            n = n + 1
        end
    end
    return n
end

function ws.pickInvCard(target)
    target = tonumber(target) or 0
    if target > 3 then target = 3 end
    local list = {}
    local c = ws.card
    local ban = {
        [tonumber(c.leftTd) or -3] = true,
        [tonumber(c.rightTd) or -3] = true,
        [tonumber(c.improveTd) or -3] = true,
    }
    for slot, info in pairs(c.inv or {}) do
        local lv = tonumber(info.level)
        if lv == nil or lv < 0 then lv = 0 end
        local sel = tonumber(info.sel) or 0
        local tid = tonumber(info.id) or -1
        local ix = tonumber(info.x) or 0
        if tid >= 0 and sel == 1 and ix >= CARD_INV_MIN_X and not ban[tid] and (target <= 0 or lv < target) then
            list[#list + 1] = { slot = slot, id = tid, level = lv }
        end
    end
    table.sort(list, function(a, b)
        if a.level ~= b.level then return a.level > b.level end
        return tostring(a.slot) < tostring(b.slot)
    end)
    -- две одного уровня
    for i = 1, #list do
        for j = i + 1, #list do
            if list[i].level == list[j].level then
                return list[i], list[j]
            end
        end
    end
    return list[1], list[2]
end

function ws.clickTd(id)
    id = tonumber(id) or -1
    if id < 0 or type(sampSendClickTextdraw) ~= 'function' then return false end
    local now = os.clock()
    if (now - (tonumber(ws.card.lastClickAt) or 0)) < 0.4 then return false end
    ws.card.lastClickAt = now
    ws.card.seenAt = now
    sampSendClickTextdraw(id)
    return true
end

function ws.cardReady()
    local c = ws.card
    if c.waitingChat or ws.busy then return false end
    -- rightFilled не доверяем (фантом на правом слоте) — только 2 клика из инвентаря + Улучшить
    return c.open
        and (tonumber(c.placed) or 0) >= 2
        and c.improveReady
        and (tonumber(c.improveTd) or -1) >= 0
end

-- Всегда 2 карты из инвентаря заново (правый слот верстака часто фантомный)
function ws.placeCards()
    local c = ws.card
    if not c.open or c.waitingChat or ws.busy then return false end
    if ws.cardReady() then return true end
    local target = tonumber(max_toch) or 0
    if target > 3 then target = 3 end
    local placed = tonumber(c.placed) or 0
    if placed >= 2 then
        ws.lowMatSaid = false
        return c.improveReady
    end
    local a, b = ws.pickInvCard(target)
    if not a then
        if not ws.lowMatSaid then
            ws.lowMatSaid = true
            sampAddChatMessage(u8:decode('[AutoZatochka] Нужны 2 карты в инвентаре справа'), 0xFF3333)
        end
        return false
    end
    local pick = a
    if placed == 1 then
        pick = b
        if not pick then
            a, b = ws.pickInvCard(target)
            pick = a
        end
        if not pick then
            if not ws.lowMatSaid then
                ws.lowMatSaid = true
                sampAddChatMessage(u8:decode('[AutoZatochka] Нужна ещё 1 карта в инвентаре'), 0xFF3333)
            end
            return false
        end
    end
    if ws.clickTd(pick.id) then
        if c.inv[pick.slot] then c.inv[pick.slot].sel = 0 end
        c.placed = placed + 1
        c.step = (c.placed == 1) and 'waitLeft' or 'waitRight'
    end
    return false
end

function ws.startCardEnchant()
    local c = ws.card
    if not ws.cardReady() then return false end
    if not ws.clickTd(c.improveTd) then return false end
    c.step = 'busy'
    c.placed = 0
    ws.busy = true
    ws.busyAt = os.clock()
    c.waitingChat = true
    return true
end

function ws.clickOnBlock(slot, typ)
    slot = tonumber(slot) or -1
    if slot < 0 then return end
    sendCEF(string.format('clickOnBlock|{"slot": %d, "type": %d}', slot, typ or 1))
end

local function itemsFromInventory(data)
    if type(data) ~= 'table' then return nil end
    local items
    if type(data[1]) == 'table' and type(data[1].data) == 'table' then
        items = data[1].data.items
    elseif type(data.data) == 'table' then
        items = data.data.items
    else
        items = data.items
    end
    if type(items) ~= 'table' then return nil end
    if items[1] ~= nil then return items end
    local list = {}
    for _, item in pairs(items) do
        if type(item) == 'table' then
            list[#list + 1] = item
        end
    end
    return list
end

function parsePlayerInventory(str)
    if type(str) ~= 'string' or not str:find('playerInventory', 1, true) then return end
    local payload = str:match("window%.executeEvent%(%s*'[^']+'%s*,%s*`([^`]+)`")
        or str:match('playerInventory|(.*)')
    if not payload or not decodeJson then return end
    -- action 2 — полный снимок; другие action тоже могут нести слоты с 1420/1187
    local ok, data = pcall(decodeJson, payload)
    if not ok then return end
    local items = itemsFromInventory(data)
    if not items then return end
    ws.cefInv = true
    ws.ingestItems(items, 1)
end

local sendQ = {}
local function eventOf(str)
    local ev, payload = str:match("window%.executeEvent%(%s*'([^']+)'%s*,%s*`([^`]*)`")
    if ev then return ev, payload end
    return str:match("window%.executeEvent%(%s*'([^']+)'%s*,%s*'([^']*)'")
end
local function queueSend(s)
    if type(s) ~= 'string' or s == '' then return end
    sendQ[#sendQ + 1] = s .. ''
    if #sendQ > 80 then table.remove(sendQ, 1) end
end
local function pumpSend()
    if #sendQ == 0 then return end
    local q = sendQ
    sendQ = {}
    for i = 1, #q do
        pcall(ws.handleSend, q[i])
    end
end

-- ID точильного камня: [1187] = "Точильный камень"
local Whetstone_ITEM_ID = 1187
local GUN_STONE_ID = 10253
local GUN_RES_ID = 511
local ATTACH_STONE_ID = 8701
local ATTACH_RES_ID = 1187
local DILL_ID = 510
local ARMOR_STONE_ID = 5736
local AMULET_ID = 1420

local function soundFileLooksBad(path)
    if not doesFileExist(path) then return true end
    local f = io.open(path, 'rb')
    if not f then return true end
    local s = f:read('*a') or ''
    f:close()
    if #s < 512 then return true end
    return contentLooksLikeHtml(s)
end

local function initSuccessSound()
    local dir = getWorkingDirectory() .. '\\' .. SOUND_SUBDIR
    if not doesDirectoryExist(dir) then
        createDirectory(dir)
    end
    local path = dir .. '\\' .. SOUND_FILENAME
    local function tryLoadStream()
        if doesFileExist(path) and not success_sound_stream and not soundFileLooksBad(path) then
            success_sound_stream = loadAudioStream(path)
        end
    end
    if doesFileExist(path) and not soundFileLooksBad(path) then
        tryLoadStream()
        return
    end
    if doesFileExist(path) then pcall(os.remove, path) end
    if downloadToFileMirrors(mirrorUrlsFor('applepay.mp3'), path, 45) and not soundFileLooksBad(path) then
        tryLoadStream()
    else
        if doesFileExist(path) then
            pcall(os.remove, path)
        end
    end
end

-- Воспроизведение звука успешной заточки
local wantSound = false
local function queueSuccessSound()
    wantSound = true
end
local function playSuccessSound()
    if not playSound[0] then return end
    local path = getWorkingDirectory() .. '\\' .. SOUND_SUBDIR .. '\\' .. SOUND_FILENAME
    if not success_sound_stream then
        if doesFileExist(path) and not soundFileLooksBad(path) then
            success_sound_stream = loadAudioStream(path)
        else
            lua_thread.create(initSuccessSound)
        end
    end
    if success_sound_stream then
        setAudioStreamState(success_sound_stream, as_action.STOP)
        setAudioStreamState(success_sound_stream, as_action.PLAY)
        setAudioStreamVolume(success_sound_stream, 1.0)
    else
        addOneOffSound(0.0, 0.0, 0.0, 1139)
    end
end

-- Склонение для статистики: "N попытка" / "N попытки" / "N попыток" (должна быть выше imgui.OnFrame)
local function attemptsWord(n)
    n = math.floor(tonumber(n) or 0)
    if n < 0 then n = 0 end
    local n10 = n % 10
    local n100 = n % 100
    if n10 == 1 and n100 ~= 11 then
        return tostring(n) .. " попытка"
    end
    if n10 >= 2 and n10 <= 4 and (n100 < 12 or n100 > 14) then
        return tostring(n) .. " попытки"
    end
    return tostring(n) .. " попыток"
end

-- == CEF функции == --
function evalanon(code)
    code = tostring(code or '')
    if arizona and arizona.eval then
        pcall(arizona.eval, code, 0)
        return
    end
    evalcef('(() => {' .. code .. '})()')
end

function evalcef(code, encoded)
    encoded = encoded or 0
    if arizona and arizona.eval and encoded == 0 then
        arizona.eval(code, 0)
        return
    end
    local bs = raknetNewBitStream()
    raknetBitStreamWriteInt8(bs, 17)
    raknetBitStreamWriteInt32(bs, 0)
    raknetBitStreamWriteInt16(bs, #code)
    raknetBitStreamWriteInt8(bs, encoded)
    raknetBitStreamWriteString(bs, code)
    raknetEmulPacketReceiveBitStream(220, bs)
    raknetDeleteBitStream(bs)
end

-- == Функции отправки CEF команд == --
function sendCEF(str)
    if arizona and arizona.send then
        local ok = pcall(arizona.send, 'onArizonaSend', { text = str, server_id = 0 })
        if ok then return end
    end
    local bs = raknetNewBitStream()
    raknetBitStreamWriteInt8(bs, 220)
    raknetBitStreamWriteInt8(bs, 18)
    raknetBitStreamWriteInt16(bs, #str)
    raknetBitStreamWriteString(bs, str)
    raknetBitStreamWriteInt32(bs, 0)
    raknetSendBitStream(bs)
    raknetDeleteBitStream(bs)
end

-- == Отправка события startEnchant == --
function ws.clickEnchantBtn()
    local code = [[
        var needles = ['\u0417\u0430\u0442\u043e\u0447\u0438\u0442\u044c', 'ENCHANT'];
        var nodes = document.querySelectorAll('button, [role="button"], [class*="button"], [class*="btn"], div, span');
        var i, j;
        for (i = 0; i < nodes.length; i++) {
            var n = nodes[i];
            var r = n.getBoundingClientRect();
            if (r.width < 8 || r.height < 8) continue;
            var t = String(n.innerText || n.textContent || '').replace(/\s+/g, ' ');
            if (t.length > 80) continue;
            var hit = false;
            for (j = 0; j < needles.length; j++) {
                if (t.indexOf(needles[j]) !== -1) { hit = true; break; }
            }
            if (!hit) continue;
            if (typeof n.click === 'function') n.click();
            return t;
        }
        return 0;
    ]]
    return ws.jsQuery(code, 800)
end

function startEnchant()
    if ws.isPair() and not ws.loopReady() then
        return
    end
    ws.clickEnchantBtn()
    sendCEF('startEnchant')
end

-- Разбор updateEnchantSlots: только regex, decodeJson не трогаем
local function parseEnchantSlotsPayload(jsonData)
    if not jsonData or #jsonData == 0 then return end
    if jsonData:gsub('^%s+', ''):sub(1, 1) == '[' then return end
    local index = jsonData:match('"index":(%-?%d+)')
    local left = jsonData:match('"left":(%-?%d+)')
    local right = jsonData:match('"right":(%-?%d+)')
    local color = jsonData:match('"color":(%-?%d+)')
    if index then
        local n = tonumber(index)
        -- Смена предмета в слоте (вставка / снятие) — это не результат заточки.
        if n ~= enchantSlotsData.index then
            ws.pendingResult = nil
            ws.chatHold = nil
            ws.itemEnchant = -1
            ws.itemId = -1
            ws.itemSlot = -1
            ws.leftItemId = nil
            ws.rightItemId = -1
            -- Новый предмет на станке → снова камень, пока не придёт ошибка про амулет.
            ws.amuletNeed = false
        end
        enchantSlotsData.index = n
    end
    if left then enchantSlotsData.left = tonumber(left) end
    if right then enchantSlotsData.right = tonumber(right) end
    if color then enchantSlotsData.color = tonumber(color) end
end

-- Паттерны чата: заточка только по «с +X на +Y»
-- Файл UTF-8: u8:decode → CP1251 для матча чата; _U8 — сырой UTF-8
-- «c»/«с» перед уровнем: берём любой один символ (латиница/кириллица)
local PATTERN_FAIL       = u8:decode("Увы, вам не удалось улучшить предмет .- %+([0-9]+) на %+([0-9]+)")
local PATTERN_FAIL_U8    = "Увы, вам не удалось улучшить предмет .- %+([0-9]+) на %+([0-9]+)"
local PATTERN_SUCCESS    = u8:decode("Успех! Вам удалось улучшить предмет .- %+([0-9]+) на %+([0-9]+)")
local PATTERN_SUCCESS_U8 = "Успех! Вам удалось улучшить предмет .- %+([0-9]+) на %+([0-9]+)"
local PATTERN_GUN_FAIL   = u8:decode("не удалось улучшить .- до %+([0-9]+)")
local PATTERN_GUN_FAIL_U8 = "не удалось улучшить .- до %+([0-9]+)"
local PATTERN_GUN_OK     = u8:decode("успешно улучшили .- до %+([0-9]+)")
local PATTERN_GUN_OK_U8  = "успешно улучшили .- до %+([0-9]+)"

local function parseEnchantLevelsFromChat(text)
    local fromLvl, toLvl = text:match(PATTERN_SUCCESS)
    if not fromLvl then fromLvl, toLvl = text:match(PATTERN_SUCCESS_U8) end
    if fromLvl and toLvl then
        return true, tonumber(fromLvl), tonumber(toLvl)
    end
    fromLvl, toLvl = text:match(PATTERN_FAIL)
    if not fromLvl then fromLvl, toLvl = text:match(PATTERN_FAIL_U8) end
    if fromLvl and toLvl then
        return false, tonumber(fromLvl), tonumber(toLvl)
    end
    toLvl = text:match(PATTERN_GUN_OK) or text:match(PATTERN_GUN_OK_U8)
    if toLvl then
        toLvl = tonumber(toLvl)
        return true, toLvl - 1, toLvl
    end
    toLvl = text:match(PATTERN_GUN_FAIL) or text:match(PATTERN_GUN_FAIL_U8)
    if toLvl then
        toLvl = tonumber(toLvl)
        return false, toLvl - 1, toLvl
    end
    return nil, nil, nil
end

function ws.isGun()
    return tonumber(ws.tab) == 1
end

function ws.isAttach()
    return tonumber(ws.tab) == 2
end

function ws.isDill()
    return tonumber(ws.tab) == 3
end

function ws.isSkin()
    return ws.isDill()
end

function ws.isAcc()
    return tonumber(ws.tab) == 0
end

function ws.isArmor()
    return tonumber(ws.tab) == 4
end

function ws.isCloth()
    return ws.isAcc() or ws.isSkin() or ws.isArmor()
end

function ws.isWeaponTab()
    return ws.isGun() or ws.isAttach()
end

function ws.clothNeedsLeft()
    if not ws.isCloth() then return false end
    local needL = tonumber(ws.leftNeed) or 0
    if needL >= 1 then return true end
    local id = tonumber(ws.leftItemId)
    -- Амулет/камень — правый ресурс, не левый. Иначе ломается укладка 1420.
    return id == DILL_ID or id == GUN_RES_ID or id == ARMOR_STONE_ID
end

-- Скины и аксессуары (не броня, не оружие) — сюда относится точильный амулет.
function ws.isAmuletTab()
    return ws.isAcc() or ws.isSkin()
end

-- Два ресурса: магазин оружия всегда, одежда — когда станок просит левый слот.
function ws.isPair()
    if ws.isWeaponTab() then return true end
    return ws.clothNeedsLeft()
end

function ws.maxLevel()
    if ws.isAttach() then return 5 end
    if ws.isCard() then return 3 end -- карты: максимум +3
    return 12
end

-- Только после чата [Информация] Увы/Успех — снова кладём 2 карты из инвентаря
function ws.afterCardResult(isSuccess, fromLvl, toLvl)
    local c = ws.card
    ws.busy = false
    ws.pendingResult = nil
    c.waitingChat = false
    c.placed = 0 -- всегда заново из инвентаря (правый фантом не считаем)
    c.step = 'idle'
    c.open = true
    c.seenAt = os.clock()
    if isSuccess then
        if toLvl then ws.itemEnchant = toLvl end
        queueSuccessSound()
        ws.statOk(toLvl)
        local target = tonumber(max_toch) or 0
        if target > 0 and toLvl and toLvl >= target then
            max_toch = 0
            status = false
            sampAddChatMessage(u8:decode("У вас заточился предмет до указанной вами заточки, выбери другой предмет или другой уровень"), -1)
            return
        end
    else
        ws.statFail()
        if fromLvl then ws.itemEnchant = fromLvl end
    end
end

function ws.applyFail()
    ws.pendingResult = nil
    ws.busy = false
    ws.statFail()
end

function ws.statFail()
    local now = os.clock()
    if (now - (tonumber(ws.statAt) or 0)) < 1.2 then return end
    ws.statAt = now
    if ws.isGun() then
        ws.gAll = (tonumber(ws.gAll) or 0) + 1
        ws.gLvl = (tonumber(ws.gLvl) or 0) + 1
    elseif ws.isAttach() then
        ws.aAll = (tonumber(ws.aAll) or 0) + 1
        ws.aLvl = (tonumber(ws.aLvl) or 0) + 1
    elseif ws.isDill() then
        ws.dAll = (tonumber(ws.dAll) or 0) + 1
        ws.dLvl = (tonumber(ws.dLvl) or 0) + 1
    elseif ws.isArmor() then
        ws.vAll = (tonumber(ws.vAll) or 0) + 1
        ws.vLvl = (tonumber(ws.vLvl) or 0) + 1
    elseif ws.isCard() then
        ws.cAll = (tonumber(ws.cAll) or 0) + 1
        ws.cLvl = (tonumber(ws.cLvl) or 0) + 1
    else
        all_lost = all_lost + 1
        lost_stone_onLVL = lost_stone_onLVL + 1
    end
end

function ws.statOk(toLvl)
    local now = os.clock()
    if (now - (tonumber(ws.statAt) or 0)) < 1.2 then return end
    ws.statAt = now
    if ws.isGun() then
        ws.gLvl = (tonumber(ws.gLvl) or 0) + 1
        ws.gAll = (tonumber(ws.gAll) or 0) + 1
        ws.gRows = ws.gRows or {}
        table.insert(ws.gRows, { ws.gLvl, toLvl })
        ws.gLvl = 0
    elseif ws.isAttach() then
        ws.aLvl = (tonumber(ws.aLvl) or 0) + 1
        ws.aAll = (tonumber(ws.aAll) or 0) + 1
        ws.aRows = ws.aRows or {}
        table.insert(ws.aRows, { ws.aLvl, toLvl })
        ws.aLvl = 0
    elseif ws.isDill() then
        ws.dLvl = (tonumber(ws.dLvl) or 0) + 1
        ws.dAll = (tonumber(ws.dAll) or 0) + 1
        ws.dRows = ws.dRows or {}
        table.insert(ws.dRows, { ws.dLvl, toLvl })
        ws.dLvl = 0
    elseif ws.isArmor() then
        ws.vLvl = (tonumber(ws.vLvl) or 0) + 1
        ws.vAll = (tonumber(ws.vAll) or 0) + 1
        ws.vRows = ws.vRows or {}
        table.insert(ws.vRows, { ws.vLvl, toLvl })
        ws.vLvl = 0
    elseif ws.isCard() then
        ws.cLvl = (tonumber(ws.cLvl) or 0) + 1
        ws.cAll = (tonumber(ws.cAll) or 0) + 1
        ws.cRows = ws.cRows or {}
        table.insert(ws.cRows, { ws.cLvl, toLvl })
        ws.cLvl = 0
    else
        lost_stone_onLVL = lost_stone_onLVL + 1
        all_lost = all_lost + 1
        table.insert(lost_stone, { lost_stone_onLVL, toLvl })
        lost_stone_onLVL = 0
    end
end

function ws.finishSuccess(fromLvl, toLvl)
    queueSuccessSound()
    ws.statOk(toLvl)
    ws.pendingResult = nil
    ws.busy = false
    local target = tonumber(max_toch) or 0
    if status and target > 0 and toLvl >= target then
        max_toch = 0
        status = false
        sampAddChatMessage(u8:decode("У вас заточился предмет до указанной вами заточки, выбери другой предмет или другой уровень"), -1)
    end
end

function ws.autoOn()
    return status and (tonumber(max_toch) or 0) > 0
end

function ws.clearStats()
    if ws.isGun() then
        ws.gRows = {}
        ws.gAll = 0
        ws.gLvl = 0
    elseif ws.isAttach() then
        ws.aRows = {}
        ws.aAll = 0
        ws.aLvl = 0
    elseif ws.isDill() then
        ws.dRows = {}
        ws.dAll = 0
        ws.dLvl = 0
    elseif ws.isArmor() then
        ws.vRows = {}
        ws.vAll = 0
        ws.vLvl = 0
    elseif ws.isCard() then
        ws.cRows = {}
        ws.cAll = 0
        ws.cLvl = 0
    else
        lost_stone = {}
        all_lost = 0
        lost_stone_onLVL = 0
    end
end

function ws.sendCategory()
    local cat = ws.isWeaponTab() and 6 or 0
    if ws.isWeaponTab() and ws.gunCtx then
        ws.lastCat = cat
        return
    end
    if ws.lastCat == cat then
        return
    end
    ws.lastCat = cat
    sendCEF('updateCategory|{"category": ' .. tostring(cat) .. '}')
end

function ws.setTab(t)
    t = tonumber(t) or 0
    if tonumber(ws.tab) == t then return false end
    ws.tab = t
    status = false
    max_toch = 0
    ws.lastCat = nil
    ws.leftItemId = nil
    ws.rightItemId = -1
    ws.amuletNeed = false
    enchantSlotsData.left = -1
    enchantSlotsData.right = -1
    if not ws.isCard() then
        ws.bestStone()
        ws.bestRes()
        ws.sendCategory()
    else
        ws.card.step = 'idle'
        ws.card.inv = {}
        ws.lowMatSaid = false
    end
    return true
end

function ws.slotsJson(idx, left, right, color)
    return '{"index":' .. tostring(idx) .. ',"left":' .. tostring(left)
        .. ',"right":' .. tostring(right) .. ',"color":' .. tostring(color) .. '}'
end

function ws.enoughMats()
    local needR = tonumber(ws.rightNeed) or 1
    if needR < 1 then needR = 1 end
    if (tonumber(ws.stoneAmount) or 0) < needR then return false end
    if ws.isPair() then
        local needL = tonumber(ws.leftNeed) or 0
        if (tonumber(ws.resAmount) or 0) < needL then return false end
    end
    return true
end

function ws.resourcesReady()
    local stone = tonumber(ws.stoneSlot) or -1
    local right = tonumber(enchantSlotsData.right) or -1
    local idx = tonumber(enchantSlotsData.index) or -1
    if idx < 0 or stone < 0 or right ~= stone then return false end
    if ws.isPair() then
        local res = tonumber(ws.resSlot) or -1
        local left = tonumber(enchantSlotsData.left) or -1
        if res < 0 or left ~= res then return false end
    end
    return ws.enoughMats()
end

function ws.mapFor(id)
    id = tonumber(id)
    if id == Whetstone_ITEM_ID then return ws.slots1187 end
    if id == GUN_STONE_ID then return ws.slots10253 end
    if id == GUN_RES_ID then return ws.slots511 end
    if id == ATTACH_STONE_ID then return ws.slots8701 end
    if id == DILL_ID then return ws.slots510 end
    if id == ARMOR_STONE_ID then return ws.slots5736 end
    if id == AMULET_ID then return ws.slots1420 end
    return {}
end

function ws.resName(id)
    id = tonumber(id)
    if id == Whetstone_ITEM_ID then return 'Точильный камень' end
    if id == GUN_STONE_ID then return 'Заточка на оружие' end
    if id == GUN_RES_ID then return 'Материалы' end
    if id == ATTACH_STONE_ID then return 'Заточка обвеса' end
    if id == DILL_ID then return 'Укроп' end
    if id == ARMOR_STONE_ID then return 'Заточка бронежилета' end
    if id == AMULET_ID then return 'Точильный амулет' end
    return 'Ресурс'
end

function ws.isResourceId(id)
    return ws.resName(id) ~= 'Ресурс'
end

function ws.setSideItem(side, id)
    id = tonumber(id)
    if not id or not ws.isResourceId(id) then return end
    -- Правый ресурс камень/амулет только через чат (amuletNeed). CEF/UI не переключают сами.
    if side == 'right' then
        if id == AMULET_ID and not ws.amuletNeed then return end
        if id == Whetstone_ITEM_ID and ws.amuletNeed then return end
    end
    if side == 'left' then
        if id == tonumber(ws.leftItemId) then return end
        ws.leftItemId = id
        enchantSlotsData.left = -1
    else
        if id == tonumber(ws.rightItemId) then return end
        ws.rightItemId = id
        enchantSlotsData.right = -1
    end
end

function ws.pickRightId()
    if ws.isGun() then return GUN_STONE_ID end
    if ws.isAttach() then return ATTACH_STONE_ID end
    if ws.isArmor() then return ARMOR_STONE_ID end
    -- Одежда/скины: камень по умолчанию; амулет — только после уведомления в чате.
    if ws.amuletNeed then return AMULET_ID end
    return Whetstone_ITEM_ID
end

function ws.pickLeftId()
    if ws.isAttach() then return Whetstone_ITEM_ID end
    if ws.isGun() then return GUN_RES_ID end
    local id = tonumber(ws.leftItemId)
    if ws.isResourceId(id) then return id end
    return ws.pickDillLeft()
end

function ws.bestStone()
    local map = ws.mapFor(ws.pickRightId()) or {}
    local bestSlot, bestAmt, total = -1, -1, 0
    for slot, amt in pairs(map) do
        slot = tonumber(slot) or -1
        amt = tonumber(amt) or 0
        if slot >= 0 and amt > 0 then
            total = total + amt
            if amt > bestAmt then
                bestAmt = amt
                bestSlot = slot
            end
        end
    end
    ws.stoneTotal = total
    if bestSlot >= 0 then
        ws.stoneSlot = bestSlot
        ws.stoneAmount = bestAmt
    else
        ws.stoneSlot = -1
        ws.stoneAmount = 0
    end
    return bestSlot, bestAmt
end

function ws.noteSideId(payload, side)
    local keys = {
        '"' .. side .. 'ResourceItem":(%d+)',
        '"' .. side .. 'ItemId":(%d+)',
        '"' .. side .. 'Item":(%d+)',
        '"' .. side .. 'ResourceId":(%d+)',
        '"' .. side .. 'Resource":(%d+)',
    }
    local i
    for i = 1, #keys do
        local id = tonumber(payload:match(keys[i]))
        if ws.isResourceId(id) then
            ws.setSideItem(side, id)
            return
        end
    end
end

function ws.textHas(payload, needle)
    if type(payload) ~= 'string' then return false end
    if payload:find(needle, 1, true) then return true end
    local dec = u8:decode(needle)
    return dec and payload:find(dec, 1, true) ~= nil
end

function ws.textHasUse(payload, itemName)
    return ws.textHas(payload, "используйте '" .. itemName .. "'")
        or ws.textHas(payload, 'используйте "' .. itemName .. '"')
        or ws.textHas(payload, 'используйте «' .. itemName .. '»')
end

local function stackTotal(map)
    local n = 0
    for _, amt in pairs(map or {}) do
        n = n + (tonumber(amt) or 0)
    end
    return n
end

-- Только [Ошибка] Чтобы заточить предмет, используйте 'Точильный амулет'
-- НЕ трогаем [Подсказка] Для заточки нужен: Точильный камень или Точильный амулет
local function clothResError(payload, itemName)
    if type(payload) ~= 'string' or payload == '' then return false end
    -- Подсказка с обоими ресурсами — всегда игнор
    if ws.textHas(payload, 'Для заточки нужен') then return false end
    if ws.textHas(payload, 'Точильный амулет') and ws.textHas(payload, 'Точильный камень') then
        return false
    end
    -- Только форма ошибки «Чтобы заточить предмет, используйте ...»
    if not ws.textHas(payload, 'Чтобы заточить предмет') then return false end
    if not ws.textHas(payload, 'используйте') and not ws.textHas(payload, 'Используйте') then
        return false
    end
    local hasA = ws.textHas(payload, 'Точильный амулет')
    local hasS = ws.textHas(payload, 'Точильный камень')
    if itemName == 'Точильный амулет' then
        return hasA and not hasS
    end
    if itemName == 'Точильный камень' then
        return hasS and not hasA
    end
    return false
end

function ws.setAmuletNeed(on)
    on = not not on
    local id = on and AMULET_ID or Whetstone_ITEM_ID
    if ws.amuletNeed == on and (tonumber(ws.rightItemId) or -1) == id then
        return false
    end
    ws.amuletNeed = on
    ws.rightItemId = id
    enchantSlotsData.right = -1
    ws.busy = false
    ws.pendingResult = nil
    ws.lowMatSaid = false
    ws.bestStone()
    -- Сразу кладём амулет 1420 только при включении режима
    if on and ws.autoOn() then
        lua_thread.create(function()
            wait(150)
            local ok = ws.placeAmulet()
            if not ok and (tonumber(ws.stoneSlot) or -1) < 0 then
                sampAddChatMessage(u8:decode('[AutoZatochka] Нужен точильный амулет (1420) в инвентаре'), 0xFF3333)
            end
        end)
    end
    return true
end

-- Инвентарь больше сам не включает амулет (из‑за этого липло на предметах под камень).
function ws.syncAmuletFromInv()
    return false
end

function ws.noteAmuletDemand(payload)
    -- Только скины / аксессуары
    if not ws.isAmuletTab() then return false end
    if clothResError(payload, 'Точильный амулет') then
        ws.setAmuletNeed(true)
        return true
    end
    if clothResError(payload, 'Точильный камень') then
        ws.setAmuletNeed(false)
        return true
    end
    return false
end

-- Ищет слот с item id 1420 в CEF-инвентаре, если пакет ещё не пришёл.
function ws.findAmuletSlotJs()
    local code = [[
        try {
            var want = 1420;
            var all = document.querySelectorAll('.inventory-item-hoc, [data-slot], [data-index], img');
            var i;
            for (i = 0; i < all.length; i++) {
                var n = all[i];
                var alt = '';
                var src = '';
                var img = (n.tagName === 'IMG') ? n : n.querySelector('img');
                if (img) {
                    alt = img.getAttribute('alt') || '';
                    src = img.getAttribute('src') || '';
                }
                var text = (n.innerText || n.textContent || '').toString();
                var combined = alt + ' ' + src + ' ' + text;
                var byId = combined.indexOf(String(want)) !== -1
                    || combined.indexOf('Точильный амулет') !== -1
                    || combined.indexOf('точильный амулет') !== -1;
                if (!byId) continue;
                var slotNum = -1;
                var el = (n.tagName === 'IMG') ? (n.closest('[data-slot], [data-index], .inventory-item-hoc') || n) : n;
                var sa = el.getAttribute('data-slot') || el.getAttribute('data-index');
                if (sa != null) slotNum = parseInt(sa, 10);
                if (!(slotNum >= 0)) continue;
                window.__azAmuletSlot = slotNum;
                return slotNum;
            }
            return -1;
        } catch (e) { return -1; }
    ]]
    local val = ws.jsQuery(code, 700)
    local n = tonumber(val)
    if n and n >= 0 then
        ws.slots1420 = ws.slots1420 or {}
        ws.slots1420[n] = ws.slots1420[n] or 1
        ws.stoneSlot = n
        ws.stoneAmount = tonumber(ws.slots1420[n]) or 1
        return n
    end
    return -1
end

-- Кладёт точильный амулет 1420 в правый слот станка (скины/аксессуары).
function ws.placeAmulet()
    if not ws.amuletNeed then return false end
    ws.bestStone()
    local idx = tonumber(enchantSlotsData.index) or -1
    local slot = tonumber(ws.stoneSlot) or -1
    if idx < 0 then return false end
    if slot < 0 or (tonumber(ws.stoneAmount) or 0) <= 0 then
        slot = ws.findAmuletSlotJs()
        if slot < 0 then return false end
    end
    -- Уже лежит нужный амулет — не кликаем снова
    if (tonumber(enchantSlotsData.right) or -1) == slot then
        return true
    end
    local now = os.clock()
    if (now - (tonumber(ws.lastPlaceAt) or 0)) < 0.8 then
        return false
    end
    ws.lastPlaceAt = now
    ws.clickOnBlock(slot, 1)
    wait(80)
    ws.clickInvSlot(slot, '1420')
    local left = -1
    if ws.isPair() then
        local res = tonumber(ws.resSlot) or -1
        if res >= 0 then left = res end
    end
    local json = ws.slotsJson(idx, left, slot, -1)
    sendCEF('updateEnchantSlots|' .. json)
    enchantSlotsData.right = slot
    return true
end

function ws.noteFromText(payload)
    if ws.noteAmuletDemand(payload) then return end
    if not ws.isCloth() then return end
    if ws.isArmor() and (tonumber(ws.rightItemId) or -1) < 0 then
        if ws.textHas(payload, 'Заточка для бронежилета') or ws.textHas(payload, 'Заточка бронежилета') then
            ws.setSideItem('right', ARMOR_STONE_ID)
        end
    end
    if (tonumber(ws.leftItemId) or -1) < 0 then
        local dill = ws.textHas(payload, 'Укроп')
        local mat = ws.textHas(payload, 'Материал')
        if dill and not mat then
            ws.setSideItem('left', DILL_ID)
        elseif mat and not dill then
            ws.setSideItem('left', GUN_RES_ID)
        end
    end
end

function ws.notePayload(payload)
    if type(payload) ~= 'string' or payload == '' then return end
    ws.noteSideId(payload, 'right')
    ws.noteSideId(payload, 'left')
    ws.noteFromText(payload)
end

function ws.noteLeftItem(payload)
    ws.notePayload(payload)
end

function ws.tryCost()
    local needR = tonumber(ws.rightNeed)
    if not needR or needR < 1 then
        needR = ws.isGun() and 2 or 1
    end
    local needL = tonumber(ws.leftNeed) or 0
    if needL < 0 then needL = 0 end
    return needR, needL
end

-- Сколько полных попыток выйдет из всех стаков ресурсов, не из одной пачки.
function ws.attemptsLeft()
    local needR, needL = ws.tryCost()
    local stones = stackTotal(ws.mapFor(ws.pickRightId()))
    local n = math.floor(stones / needR)
    if not ws.isPair() or needL < 1 then return n end
    local res = stackTotal(ws.mapFor(ws.pickLeftId()))
    local byRes = math.floor(res / needL)
    if byRes < n then return byRes end
    return n
end

function ws.pickDillLeft()
    local id = tonumber(ws.leftItemId)
    if id == DILL_ID or id == GUN_RES_ID then return id end
    local dill = stackTotal(ws.slots510)
    local mat = stackTotal(ws.slots511)
    if dill > 0 and mat <= 0 then return DILL_ID end
    if mat > 0 and dill <= 0 then return GUN_RES_ID end
    if mat > 0 then return GUN_RES_ID end
    return DILL_ID
end

function ws.bestRes()
    local map = ws.mapFor(ws.pickLeftId()) or {}
    local bestSlot, bestAmt, total = -1, -1, 0
    for slot, amt in pairs(map) do
        slot = tonumber(slot) or -1
        amt = tonumber(amt) or 0
        if slot >= 0 and amt > 0 then
            total = total + amt
            if amt > bestAmt then
                bestAmt = amt
                bestSlot = slot
            end
        end
    end
    ws.resTotal = total
    if bestSlot >= 0 then
        ws.resSlot = bestSlot
        ws.resAmount = bestAmt
    else
        ws.resSlot = -1
        ws.resAmount = 0
    end
    return bestSlot, bestAmt
end

function ws.jsQuery(code, timeout)
    if cefDlg and cefDlg.cefQuery then
        return cefDlg.cefQuery(code, timeout or 800)
    end
    evalanon(code)
    return nil
end

function ws.clickInvSlot(slot, needle)
    slot = tonumber(slot) or -1
    if slot < 0 then return nil end
    -- CEF-инвентарь: клик по номеру слота, как ArzMarket clickOnBlock.
    if ws.cefInv then
        ws.clickOnBlock(slot, 1)
        return 1
    end
    -- Текстдравовый инвентарь: номер клетки с сетки 6x6, клик по её id.
    local localSlot = slot % 36
    local td = ws.invTd[localSlot]
    if td and slot < 36 and type(sampSendClickTextdraw) == 'function' then
        sampSendClickTextdraw(td)
        return 1
    end
    ws.clickOnBlock(slot, 1)
    return 1
end

function ws.clickStoneJs()
    return ws.clickInvSlot(ws.stoneSlot, tostring(ws.pickRightId()))
end

function ws.loopReady()
    if ws.isPair() then
        if not ws.resourcesReady() then return false end
        if (os.clock() - (tonumber(ws.lastPlaceAt) or 0)) < 0.4 then return false end
        return true
    end
    return (tonumber(ws.available) or 0) == 1 or ws.resourcesReady()
end

function ws.placeStone()
    -- Скины/аксессуары после ошибки про амулет — кладём именно 1420
    if ws.amuletNeed and ws.isAmuletTab() then
        return ws.placeAmulet()
    end
    ws.bestStone()
    ws.bestRes()
    local idx = tonumber(enchantSlotsData.index) or -1
    local stone = tonumber(ws.stoneSlot) or -1
    local pair = ws.isPair()
    if idx < 0 then
        return false
    end
    if stone < 0 or (tonumber(ws.stoneAmount) or 0) <= 0 then
        return false
    end
    if pair then
        local res = tonumber(ws.resSlot) or -1
        if res < 0 or (tonumber(ws.resAmount) or 0) <= 0 then
            return false
        end
        if not ws.enoughMats() then
            if not ws.lowMatSaid then
                ws.lowMatSaid = true
                if ws.isAttach() then
                    sampAddChatMessage(u8:decode('Не хватает заточки обвеса или точильного камня'), 0xFF3333)
                elseif ws.isGun() then
                    sampAddChatMessage(u8:decode('Не хватает заточки на оружие или ресурса'), 0xFF3333)
                else
                    local miss = ws.resName(ws.pickRightId())
                    if ws.isPair() then
                        miss = miss .. ' или ' .. ws.resName(ws.pickLeftId())
                    end
                    sampAddChatMessage(u8:decode('Не хватает: ' .. miss), 0xFF3333)
                end
            end
            return false
        end
        ws.lowMatSaid = false
    end
    if ws.resourcesReady() then
        return true
    end
    local now = os.clock()
    local gap = pair and 1.0 or 2.5
    if (now - (tonumber(ws.lastPlaceAt) or 0)) < gap then
        return false
    end
    ws.lastPlaceAt = now
    local left = tonumber(enchantSlotsData.left) or -1
    local right = tonumber(enchantSlotsData.right) or -1
    if pair then
        -- Оружие: слева материалы, справа заточка. Обвес: слева камень, справа заточка обвеса.
        -- Одежда: правый слот камень, амулет или заточка брони; левый — укроп или материалы, если станок просит.
        left = tonumber(ws.resSlot) or -1
        right = stone
    else
        if right ~= stone then
            ws.clickStoneJs()
        end
        right = stone
    end
    local json = ws.slotsJson(idx, left, right, -1)
    sendCEF('updateEnchantSlots|' .. json)
    return idx >= 0
end

function ws.handleSend(text)
    if type(text) ~= 'string' or text == '' then return end
    local json = text:match('^updateEnchantSlots|(.+)')
    if not json then return end
    parseEnchantSlotsPayload(json)
    if not ws.autoOn() then return end
    local stone = tonumber(ws.stoneSlot) or -1
    if ws.isPair() then
        local res = tonumber(ws.resSlot) or -1
        if res >= 0 and (tonumber(enchantSlotsData.left) or -1) < 0 then
            enchantSlotsData.left = res
        end
        if stone >= 0 and (tonumber(enchantSlotsData.right) or -1) < 0 then
            enchantSlotsData.right = stone
        end
        return
    end
    if stone >= 0 and (tonumber(enchantSlotsData.right) or -1) == -1 then
        enchantSlotsData.right = stone
    end
end

function ws.ingestItems(items, invType)
    if type(items) ~= 'table' then return end
    invType = tonumber(invType) or 1
    if invType ~= 1 then return end
    -- Пакет часто содержит один изменившийся слот. Остальные стаки не стираем.
    ws.slots1187 = ws.slots1187 or {}
    ws.slots10253 = ws.slots10253 or {}
    ws.slots511 = ws.slots511 or {}
    ws.slots8701 = ws.slots8701 or {}
    ws.slots510 = ws.slots510 or {}
    ws.slots5736 = ws.slots5736 or {}
    ws.slots1420 = ws.slots1420 or {}
    local function dropSlot(slot)
        ws.slots1187[slot] = nil
        ws.slots10253[slot] = nil
        ws.slots511[slot] = nil
        ws.slots8701[slot] = nil
        ws.slots510[slot] = nil
        ws.slots5736[slot] = nil
        ws.slots1420[slot] = nil
    end
    local targetSlot = tonumber(enchantSlotsData.index) or -1
    for _, item in pairs(items) do
        if type(item) == 'table' then
            local id = tonumber(item.item)
            local slot = tonumber(item.slot)
            if slot then
                local amt = tonumber(item.amount) or 1
                dropSlot(slot)
                if amt > 0 then
                    if id == Whetstone_ITEM_ID then
                        ws.slots1187[slot] = amt
                    elseif id == GUN_STONE_ID then
                        ws.slots10253[slot] = amt
                    elseif id == GUN_RES_ID then
                        ws.slots511[slot] = amt
                    elseif id == ATTACH_STONE_ID then
                        ws.slots8701[slot] = amt
                    elseif id == DILL_ID then
                        ws.slots510[slot] = amt
                    elseif id == ARMOR_STONE_ID then
                        ws.slots5736[slot] = amt
                    elseif id == AMULET_ID then
                        ws.slots1420[slot] = amt
                    end
                end
            end
            local ench = item.enchant
            local txtLvl = tostring(item.text or ''):match('%+(%d+)')
            local isTarget = (targetSlot >= 0 and slot == targetSlot)
            if isTarget then
                local newLvl = tonumber(ench)
                if newLvl == nil then newLvl = tonumber(txtLvl) end
                if id and not ws.isResourceId(id) then
                    local knownId = tonumber(ws.itemId) or -1
                    local prev = -1
                    if knownId == id and (tonumber(ws.itemSlot) or -1) == slot then
                        prev = tonumber(ws.itemEnchant) or -1
                    end
                    -- Другой предмет на станке → снова камень (амулет только после своей ошибки)
                    if knownId > 0 and knownId ~= id and ws.amuletNeed then
                        ws.amuletNeed = false
                        ws.rightItemId = Whetstone_ITEM_ID
                        enchantSlotsData.right = -1
                    end
                    ws.itemSlot = slot or ws.itemSlot
                    ws.itemId = id
                    if newLvl ~= nil then
                        -- Успех только если уровень того же предмета вырос ровно на 1 после попытки.
                        -- Первое появление +11 в слоте и «уже +11» успехом не считаем.
                        local hold = ws.chatHold
                        if hold and (os.clock() - (tonumber(hold.at) or 0)) > 8 then
                            ws.chatHold = nil
                            hold = nil
                        end
                        if hold and prev < 0 and newLvl == hold.toLvl then
                            ws.chatHold = nil
                            hold = nil
                        end
                        local grew = ws.pendingResult == 1 and prev >= 0 and newLvl == prev + 1
                        if not grew and hold and prev >= 0 and prev == hold.fromLvl and newLvl == hold.toLvl and newLvl == prev + 1 then
                            grew = true
                            ws.chatHold = nil
                        elseif hold and prev >= 0 and newLvl ~= hold.fromLvl and newLvl ~= hold.toLvl then
                            ws.chatHold = nil
                        end
                        ws.itemEnchant = newLvl
                        if grew then
                            ws.finishSuccess(prev, newLvl)
                        elseif ws.pendingResult == 1 then
                            ws.pendingResult = nil
                            ws.busy = false
                        end
                    end
                end
            end
        end
    end
    ws.bestStone()
    ws.bestRes()
    if ws.isAmuletTab() then
        ws.syncAmuletFromInv()
    end
end

function ws.handle(ev, payload)
    if not ev then return end
    payload = payload or ''
    if ev == 'event.inventory.setWorkshopVisible' then
        local on = payload:find('true', 1, true) ~= nil
        workshop_check = on
        if not on then
            ws.busy = false
            enchantSlotsData.index = -1
            enchantSlotsData.left = -1
            enchantSlotsData.right = -1
            enchantSlotsData.color = -1
            ws.available = 0
            ws.lastCat = nil
            ws.leftItemId = nil
            ws.rightItemId = -1
            ws.amuletNeed = false
            ws.pendingResult = nil
            ws.chatHold = nil
            ws.itemEnchant = -1
            ws.itemId = -1
            ws.itemSlot = -1
        end
        return
    end
    if ev == 'event.inventory.setWorkshopGunContext' then
        local on = payload:find('true', 1, true) ~= nil
        ws.gunCtx = on and true or false
        if on then
            ws.lastCat = 6
            if not ws.autoOn() and ws.isCloth() then ws.tab = 1 end
        else
            if not ws.autoOn() and ws.isGun() then ws.tab = 0 end
        end
        return
    end
    if ev == 'event.workshop.setResourceNeedItems' then
        workshop_check = true
        local ln = tonumber(payload:match('"leftResourceAmount":(%-?%d+)'))
        local rn = tonumber(payload:match('"rightResourceAmount":(%-?%d+)'))
        if ln then ws.leftNeed = ln end
        if rn then ws.rightNeed = rn end
        ws.noteLeftItem(payload)
        return
    end
    if ev == 'event.notify.initialize' then
        local msg = tostring(payload or '')
        -- Ошибка про амулет 1420 — всегда, даже если workshop_check ещё не успел
        if ws.noteAmuletDemand(msg) then
            return
        end
        if workshop_check then
            ws.notePayload(msg)
        end
        local low = ws.textHas(msg, 'Заточка на оружие') or ws.textHas(msg, 'Заточка обвеса')
            or ws.textHas(msg, 'Точильный камень') or ws.textHas(msg, 'Укроп')
            or ws.textHas(msg, 'Материал') or ws.textHas(msg, 'Точильный амулет')
            or ws.textHas(msg, 'Заточка для бронежилета') or ws.textHas(msg, 'Заточка бронежилета')
        if low and (ws.isPair() or ws.isCloth() or ws.isWeaponTab()) then
            ws.busy = false
        end
        return
    end
    if ev == 'event.inventory.workShop' then
        workshop_check = true
        local action = tonumber(payload:match('"action":(%-?%d+)'))
        if action == 2 then
            local available = tonumber(payload:match('"available":(%-?%d+)'))
            if available == nil and payload:find('"available":true', 1, true) then available = 1 end
            if available == nil and payload:find('"available":false', 1, true) then available = 0 end
            if available ~= nil then ws.available = available end
        else
            if action == 0 then
                ws.busy = true
                ws.busyAt = os.clock()
                ws.attemptFrom = tonumber(ws.itemEnchant)
            else
                if action == 1 then
                    local wasBusy = ws.busy
                    ws.busy = false
                    local suc = tonumber(payload:match('"success":(%-?%d+)'))
                    if suc == nil and (payload:find('"success":true', 1, true) or payload:find('"success": true', 1, true)) then
                        suc = 1
                    end
                    if suc == nil and (payload:find('"success":false', 1, true) or payload:find('"success": false', 1, true)) then
                        suc = 0
                    end
                    -- Вставка скина и обновление слота тоже шлют action 1. Без начатой попытки в статистику не пишем.
                    if wasBusy then
                        if suc == 1 then
                            ws.pendingResult = 1
                            if (tonumber(ws.attemptFrom) or -1) < 0 then
                                ws.attemptFrom = tonumber(ws.itemEnchant)
                            end
                        else
                            ws.applyFail()
                        end
                    end
                end
            end
        end
        return
    end
end

local function processCefText(str)
    if type(str) ~= 'string' or str == '' then return end
    local ev, payload = eventOf(str)
    if ev then
        pcall(ws.handle, ev, payload or '')
    end
    if str:find('updateEnchantSlots', 1, true) then
        workshop_check = true
        parseEnchantSlotsPayload(str:match('updateEnchantSlots|(.+)'))
    end
end

local function processChatLine(text)
    if type(text) ~= 'string' or text == '' then return end
    local t = text:gsub("%{%x%x%x%x%x%x%}", "")
    if ws.noteAmuletDemand(t) then return end
    if (tonumber(max_toch) or 0) <= 0 then return end
    local isSuccess, fromLvl, toLvl = parseEnchantLevelsFromChat(t)
    if isSuccess == nil then
        return
    end
    -- Карты: ждём именно сообщение Увы/Успех, только потом кладём снова
    if ws.isCard() and (ws.busy or ws.card.waitingChat or status) then
        ws.afterCardResult(isSuccess, fromLvl, toLvl)
        return
    end
    local known = tonumber(ws.itemEnchant)
    if known == nil or known < 0 then
        known = tonumber(ws.attemptFrom)
    end
    if known == nil then known = -1 end
    -- Сообщение про другой уровень (скин уже +11, а чат про +10 → +11) — фантом, не пишем.
    if known >= 0 and fromLvl ~= known then
        return
    end
    if known < 0 and not ws.busy and ws.pendingResult ~= 1 then
        return
    end
    if not isSuccess then
        ws.busy = false
        ws.pendingResult = nil
        ws.statFail()
        return
    end
    if isSuccess and toLvl then
        if known >= 0 and toLvl ~= known + 1 then
            return
        end
        -- Уровень предмета ещё не видели: не записываем переход, пока инвентарь не подтвердит рост.
        if known < 0 then
            ws.chatHold = { fromLvl = fromLvl, toLvl = toLvl, at = os.clock() }
            ws.busy = false
            ws.pendingResult = nil
            return
        end
        ws.itemEnchant = toLvl
        ws.attemptFrom = toLvl
        queueSuccessSound()
        ws.statOk(toLvl)
        ws.busy = false
        ws.pendingResult = nil
        local target = tonumber(max_toch) or 0
        if toLvl == target and fromLvl == (target - 1) then
            max_toch = 0
            status = false
            sampAddChatMessage(u8:decode("У вас заточился предмет до указанной вами заточки, выбери другой предмет или другой уровень"), -1)
        end
    end
end

local function pumpIncoming()
    pumpSend()
    if #incomingCef > 0 then
        local batch = incomingCef
        incomingCef = {}
        for i = 1, #batch do pcall(processCefText, batch[i]) end
    end
    if #incomingChat > 0 then
        local batch = incomingChat
        incomingChat = {}
        for i = 1, #batch do pcall(processChatLine, batch[i]) end
    end
end

local function chainArz(name, fn)
    if not arizona then return end
    local prev = arizona[name]
    arizona[name] = function(packet)
        local ok1, r1 = pcall(fn, packet)
        local r2
        if prev then
            local ok2, x = pcall(prev, packet)
            if ok2 then r2 = x end
        end
        if ok1 and r1 == false then return false end
        if ok1 and type(r1) == 'table' then return r1 end
        return r2
    end
end

local function snapCefPacket(packet)
    if not packet then return end
    pcall(function()
        local t = packet.text
        if type(t) ~= 'string' or t == '' then return end
        if t:find('playerInventory', 1, true) then
            pcall(parsePlayerInventory, t)
            return
        end
        if t:find('event.storage', 1, true) then return end
        local keep = t:find('workShop', 1, true)
            or t:find('setWorkshop', 1, true)
            or t:find('setResourceNeedItems', 1, true)
            or t:find('updateEnchantSlots', 1, true)
            or t:find('event.notify.initialize', 1, true)
            or t:find('startEnchant', 1, true)
        if not keep then return end
        queueCef(t)
    end)
end

local function snapSendPacket(packet)
    if not packet or type(packet.text) ~= 'string' or packet.text == '' then return end
    local t = packet.text
    queueSend(t)
    if not ws.autoOn() then return end
    local json = t:match('^updateEnchantSlots|(.+)')
    if not json then return end
    pcall(ws.bestStone)
    pcall(ws.bestRes)
    local stone = tonumber(ws.stoneSlot) or -1
    local res = tonumber(ws.resSlot) or -1
    local idx = tonumber(json:match('"index":(%-?%d+)')) or tonumber(enchantSlotsData.index) or -1
    local left = tonumber(json:match('"left":(%-?%d+)')) or tonumber(enchantSlotsData.left) or -1
    local right = tonumber(json:match('"right":(%-?%d+)')) or -1
    local color = tonumber(json:match('"color":(%-?%d+)')) or -1
    if idx < 0 then return end
    local need = false
    if ws.isPair() then
        if res >= 0 and left ~= res then
            left = res
            need = true
        end
        if stone >= 0 and right ~= stone then
            right = stone
            need = true
        end
    elseif stone >= 0 and right ~= stone then
        right = stone
        need = true
    end
    if color ~= -1 then
        color = -1
        need = true
    end
    if not need then return end
    packet.text = 'updateEnchantSlots|' .. ws.slotsJson(idx, left, right, color)
    return { packet }
end

function main()
    while not isSampAvailable() do wait(100) end
    sampRegisterChatCommand('mt', function() WinState[0] = not WinState[0] end)

    -- У кого нет lib/arizona-events: синхронная докачка -> перезагрузка скрипта -> уже с require
    if not arizonaEventsLibPresent() then
        sampAddChatMessage('[AutoZatochka] ' .. u8:decode('Не найдены библиотеки arizona-events. Скачиваю с GitHub...'), -1)
        local ok = syncArizonaEventsLib(true)
        if ok then
            sampAddChatMessage('[AutoZatochka] ' .. u8:decode('Загрузка завершена. Перезапуск скрипта...'), -1)
            wait(400)
            thisScript():reload()
        else
            sampAddChatMessage('[AutoZatochka] ' .. u8:decode('Скачивание не удалось. Проверьте интернет. Файлы: zatochka/arizona-events на GitHub.'), -1)
        end
        return
    end

    do
        local ok_load, mod = pcall(require, 'arizona-events')
        if ok_load and mod then
            arizona = mod
        else
            arizona = nil
        end
    end

    if arizona then
        chainArz('onArizonaDisplay', snapCefPacket)
        chainArz('onArizonaIncomingCef18', snapCefPacket)
        chainArz('onArizonaSend', snapSendPacket)
    end

    sampAddChatMessage('[AutoZatochka] ' .. u8:decode('загружен. /mt'), -1)

    -- Загрузка звука успешной заточки с GitHub в фоне
    lua_thread.create(function()
        wait(500)
        initSuccessSound()
    end)

    -- Пакет 220 разбирает lib arizona-events (onArizonaDisplay / onArizonaIncomingCef18). Если библиотека не загрузилась — вручную.
    if not arizona then
        pcall(function()
            addEventHandler('onReceivePacket', function(id, bs)
                if id ~= 220 then return end
                local act
                pcall(function()
                    local off
                    if raknetBitStreamGetReadOffset then off = raknetBitStreamGetReadOffset(bs) end
                    if raknetBitStreamSetReadOffset then raknetBitStreamSetReadOffset(bs, 0) end
                    raknetBitStreamIgnoreBits(bs, 8)
                    local packetType = raknetBitStreamReadInt8(bs)
                    if packetType == 17 then
                        raknetBitStreamIgnoreBits(bs, 32)
                        local length = raknetBitStreamReadInt16(bs)
                        local encoded = raknetBitStreamReadInt8(bs)
                        if length and length > 0 then
                            local str = (encoded ~= 0) and raknetBitStreamDecodeString(bs, length + encoded) or raknetBitStreamReadString(bs, length)
                            if type(str) == 'string' then act = str end
                        end
                    else
                        if packetType == 18 then
                            local dataLength = raknetBitStreamReadInt16(bs)
                            local encoded = raknetBitStreamReadInt8(bs)
                            if dataLength and dataLength > 0 then
                                local data = (encoded ~= 0) and raknetBitStreamDecodeString(bs, dataLength + encoded) or raknetBitStreamReadString(bs, dataLength)
                                if type(data) == 'string' then act = data end
                            end
                        end
                    end
                    if off and raknetBitStreamSetReadOffset then raknetBitStreamSetReadOffset(bs, off) end
                end)
                if type(act) == 'string' then queueCef(act) end
            end)
        end)
    end
    
    
    while true do
        pcall(pumpIncoming)
        if wantSound then
            wantSound = false
            playSuccessSound()
        end
        wait(0)
        if ws.autoOn() then
            local target = tonumber(max_toch) or 0
            local lvl = tonumber(ws.itemEnchant) or -1
            if target > 0 and lvl >= target and not ws.isCard() then
                status = false
                max_toch = 0
                sampAddChatMessage(u8:decode("Предмет уже +" .. tostring(lvl) .. ", выбери уровень выше"), -1)
            elseif ws.isCard() then
                -- Эликсир мастер: из инвентаря 2 карты → Улучшить → ждём чат
                local c = ws.card
                if not c.open then
                    wait(400)
                elseif c.waitingChat or ws.busy then
                    if os.clock() - (tonumber(ws.busyAt) or 0) > 25 then
                        ws.busy = false
                        c.waitingChat = false
                    else
                        wait(150)
                    end
                elseif ws.cardReady() then
                    ws.startCardEnchant()
                    wait(800)
                else
                    ws.placeCards()
                    wait(500)
                end
            else
                if not workshop_check then
                    wait(500)
                else
                    if ws.busy then
                        if os.clock() - (tonumber(ws.busyAt) or 0) > 20 then
                            ws.busy = false
                        else
                            wait(120)
                        end
                    else
                        local ready = ws.loopReady()
                        if ready then
                            ws.busy = true
                            ws.busyAt = os.clock()
                            startEnchant()
                            wait(800)
                        else
                            ws.placeStone()
                            wait(ws.isPair() and 600 or 800)
                        end
                    end
                end
            end
        end
    end
end

function ws.uiAccent()
    return imgui.ImVec4(0.36, 0.58, 1.00, 1)
end

function ws.uiNav(label, selected, w, h)
    if selected then
        imgui.PushStyleColor(imgui.Col.Button, ws.uiAccent())
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.46, 0.66, 1, 1))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.30, 0.50, 0.95, 1))
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.07, 0.08, 0.10, 1))
    else
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(1, 1, 1, 0.05))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.36, 0.58, 1, 0.22))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.36, 0.58, 1, 0.35))
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.78, 0.80, 0.86, 1))
    end
    local clicked = imgui.Button(label, imgui.ImVec2(w, h or 32))
    imgui.PopStyleColor(4)
    return clicked
end

function ws.uiIcon(label, w)
    imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(1, 1, 1, 0.06))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.36, 0.58, 1, 0.35))
    imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.36, 0.58, 1, 0.55))
    local clicked = imgui.Button(label, imgui.ImVec2(w or 28, 28))
    imgui.PopStyleColor(3)
    return clicked
end

function ws.uiLvl(i, w, h)
    local on = (i == max_toch)
    if on then
        imgui.PushStyleColor(imgui.Col.Button, ws.uiAccent())
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.46, 0.66, 1, 1))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.30, 0.50, 0.95, 1))
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.07, 0.08, 0.10, 1))
    else
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(1, 1, 1, 0.06))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.36, 0.58, 1, 0.28))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.36, 0.58, 1, 0.45))
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.82, 0.84, 0.90, 1))
    end
    local clicked = imgui.Button('+' .. tostring(i), imgui.ImVec2(w, h))
    imgui.PopStyleColor(4)
    return clicked
end

function ws.pickLevel(i)
    i = tonumber(i) or 0
    if ws.isCard() and i > 3 then i = 3 end
    if max_toch ~= i then
        status = true
        max_toch = i
        ws.lowMatSaid = false
        lua_thread.create(function()
            wait(120)
            if ws.isCard() then
                ws.card.waitingChat = false
                ws.card.placed = 0
                ws.busy = false
                ws.placeCards()
                wait(500)
                if status and ws.cardReady() then
                    ws.startCardEnchant()
                end
                return
            end
            ws.placeStone()
            wait(400)
            if status and ws.loopReady() and not ws.busy then
                ws.busy = true
                ws.busyAt = os.clock()
                startEnchant()
            end
        end)
    else
        status = false
        max_toch = 0
    end
end

function ws.drawSettingsBody()
    imgui.TextDisabled('Версия ' .. tostring(thisScript().version or '1.0'))
    imgui.Dummy(imgui.ImVec2(0, 8))
    if imgui.Checkbox('Звук при успехе', playSound) then
        addOneOffSound(0.0, 0.0, 0.0, 1139)
    end
    imgui.Dummy(imgui.ImVec2(0, 10))
    if imgui.Button('Очистить статистику', imgui.ImVec2(476, 32)) then
        ws.clearStats()
    end
    imgui.Dummy(imgui.ImVec2(0, 4))
    if imgui.Button('Перезагрузить скрипт', imgui.ImVec2(476, 32)) then
        lua_thread.create(function()
            sampAddChatMessage(u8:decode('[AutoZatochka] Перезагрузка скрипта...'), -1)
            wait(1000)
            thisScript():reload()
        end)
    end
    imgui.Dummy(imgui.ImVec2(0, 14))
    imgui.TextDisabled('/mt  — открыть окно')
    imgui.TextDisabled('Шестерёнка ещё раз — назад')
end

function ws.modeTitle()
    if ws.isCard() then return 'Эликсир мастер' end
    if ws.isGun() then return 'Скины на оружие' end
    if ws.isAttach() then return 'Обвесы' end
    if ws.isArmor() then return 'Бронежилеты' end
    if ws.isSkin() then return 'Скины' end
    return 'Аксессуары'
end

function ws.chooseMode(tab)
    tab = tonumber(tab) or 0
    local shop = 'cloth'
    if tab == 1 or tab == 2 then shop = 'gun'
    elseif tab == 5 then shop = 'card' end
    if tonumber(ws.tab) ~= tab then
        ws.setTab(tab)
    end
    ws.shop = shop
    ws.picker = nil
    ws.screen = 'work'
end

function ws.drawHome()
    imgui.SetCursorPos(imgui.ImVec2(16, 64))
    imgui.TextDisabled('Выбери мастерскую')
    imgui.SetCursorPos(imgui.ImVec2(16, 96))
    if ws.uiNav('Мастерская одежды', ws.picker == 'cloth', 476, 52) then
        ws.picker = 'cloth'
        ws.shop = 'cloth'
    end
    imgui.SetCursorPos(imgui.ImVec2(16, 160))
    if ws.uiNav('Магазин оружия', ws.picker == 'gun', 476, 52) then
        ws.picker = 'gun'
        ws.shop = 'gun'
    end
    imgui.SetCursorPos(imgui.ImVec2(16, 224))
    if ws.uiNav('Эликсир мастер', ws.isCard() or ws.picker == 'card', 476, 52) then
        ws.chooseMode(5)
    end
end

function ws.drawPicker()
    local cloth = ws.picker == 'cloth'
    local W = 360
    local H = cloth and 292 or 228
    imgui.SetNextWindowPos(imgui.ImVec2(780, 460), imgui.Cond.FirstUseEver, imgui.ImVec2(0, 0.5))
    imgui.SetNextWindowSize(imgui.ImVec2(W, H), imgui.Cond.Always)
    imgui.Begin('##azPicker', nil, imgui.WindowFlags.NoDecoration)
    local dl = imgui.GetWindowDrawList()
    local p = imgui.GetWindowPos()
    local sz = imgui.GetWindowSize()
    dl:AddRectFilled(p, imgui.ImVec2(p.x + 4, p.y + sz.y), imgui.ColorConvertFloat4ToU32(ws.uiAccent()), 2)
    imgui.SetCursorPos(imgui.ImVec2(16, 14))
    imgui.PushStyleColor(imgui.Col.Text, ws.uiAccent())
    imgui.Text(cloth and 'Мастерская одежды' or 'Магазин оружия')
    imgui.PopStyleColor()
    imgui.SetCursorPos(imgui.ImVec2(W - 44, 8))
    imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.8, 0.22, 0.32, 0.35))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.9, 0.25, 0.35, 0.7))
    imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.9, 0.25, 0.35, 0.9))
    if imgui.Button('X##picker', imgui.ImVec2(28, 28)) then
        ws.picker = nil
    end
    imgui.PopStyleColor(3)
    imgui.SetCursorPos(imgui.ImVec2(16, 56))
    imgui.TextDisabled('Что точить')
    if cloth then
        imgui.SetCursorPos(imgui.ImVec2(16, 86))
        if ws.uiNav('Аксессуары', ws.isAcc(), 328, 44) then ws.chooseMode(0) end
        imgui.SetCursorPos(imgui.ImVec2(16, 138))
        if ws.uiNav('Скины', ws.isSkin(), 328, 44) then ws.chooseMode(3) end
        imgui.SetCursorPos(imgui.ImVec2(16, 190))
        if ws.uiNav('Бронежилеты', ws.isArmor(), 328, 44) then ws.chooseMode(4) end
        imgui.SetCursorPos(imgui.ImVec2(16, 248))
        imgui.TextDisabled('Ресурс скрипт выберет сам')
    else
        imgui.SetCursorPos(imgui.ImVec2(16, 86))
        if ws.uiNav('Скины на оружие', ws.isGun(), 328, 44) then ws.chooseMode(1) end
        imgui.SetCursorPos(imgui.ImVec2(16, 138))
        if ws.uiNav('Обвесы', ws.isAttach(), 328, 44) then ws.chooseMode(2) end
    end
    imgui.End()
end

function ws.drawWork()
    imgui.SetCursorPos(imgui.ImVec2(16, 48))
    if ws.uiNav('Назад', false, 88, 32) then
        status = false
        max_toch = 0
        ws.screen = 'home'
        ws.picker = (ws.shop == 'card') and nil or ws.shop
    end
    imgui.SameLine()
    imgui.Text(ws.modeTitle())

    imgui.SetCursorPos(imgui.ImVec2(16, 90))
    if imgui.BeginChild('##status', imgui.ImVec2(476, 70), false) then
        local ench = tonumber(ws.itemEnchant) or -1
        local run = status and (tonumber(max_toch) or 0) > 0
        if run then
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.45, 0.85, 0.55, 1))
            imgui.Text('Точит до +' .. tostring(max_toch))
            imgui.PopStyleColor()
        else
            imgui.TextDisabled('Выбери уровень')
        end
        if ench >= 0 then
            imgui.SameLine()
            imgui.TextDisabled('  ·  сейчас +' .. tostring(ench))
        end
        if ws.isCard() then
            local nCards = ws.cardCount(tonumber(max_toch) or 99)
            local c = ws.card
            imgui.TextDisabled('Карт в инвентаре: ' .. tostring(nCards) .. '  ·  на попытку 2')
            if not c.open then
                imgui.TextDisabled('Открой Эликсир мастер в игре')
            end
        else
            local needR, needL = ws.tryCost()
            local line = ws.resName(ws.pickRightId()) .. '  ' .. tostring(ws.stoneTotal or 0) .. ' / ' .. tostring(needR)
            if ws.isPair() then
                line = line .. '      ' .. ws.resName(ws.pickLeftId()) .. '  ' .. tostring(ws.resTotal or 0) .. ' / ' .. tostring(needL)
            end
            imgui.TextDisabled(line)
            imgui.TextDisabled('Хватит на ' .. attemptsWord(ws.attemptsLeft()))
        end
        imgui.EndChild()
    end

    imgui.SetCursorPos(imgui.ImVec2(16, 168))
    imgui.TextDisabled('Точить до')
    do
        local i
        local maxL = ws.maxLevel()
        for i = 1, maxL do
            local col = (i - 1) % 4
            local row = math.floor((i - 1) / 4)
            imgui.SetCursorPos(imgui.ImVec2(16 + col * 118, 190 + row * 36))
            if ws.uiLvl(i, 110, 30) then
                ws.pickLevel(i)
            end
        end
    end

    imgui.SetCursorPos(imgui.ImVec2(16, 306))
    if imgui.BeginChild('##stats', imgui.ImVec2(476, 118), false) then
        imgui.PushStyleColor(imgui.Col.Text, ws.uiAccent())
        imgui.Text('Статистика  ·  ' .. ws.modeTitle())
        imgui.PopStyleColor()
        imgui.Separator()
        local rows, total, cur
        if ws.isGun() then
            rows = ws.gRows or {}
            total = tonumber(ws.gAll) or 0
            cur = tonumber(ws.gLvl) or 0
        elseif ws.isAttach() then
            rows = ws.aRows or {}
            total = tonumber(ws.aAll) or 0
            cur = tonumber(ws.aLvl) or 0
        elseif ws.isSkin() then
            rows = ws.dRows or {}
            total = tonumber(ws.dAll) or 0
            cur = tonumber(ws.dLvl) or 0
        elseif ws.isArmor() then
            rows = ws.vRows or {}
            total = tonumber(ws.vAll) or 0
            cur = tonumber(ws.vLvl) or 0
        elseif ws.isCard() then
            rows = ws.cRows or {}
            total = tonumber(ws.cAll) or 0
            cur = tonumber(ws.cLvl) or 0
        else
            rows = lost_stone
            total = all_lost
            cur = lost_stone_onLVL
        end
        local n
        for n = 1, #rows do
            local v = rows[n]
            if type(v) == 'table' then
                imgui.Text('С +' .. tostring((v[2] or 1) - 1) .. ' до +' .. tostring(v[2]) .. '  —  ' .. attemptsWord(v[1]))
            end
        end
        if cur > 0 then
            imgui.TextDisabled('Сейчас  ' .. attemptsWord(cur))
        end
        imgui.TextDisabled('Всего попыток  ' .. tostring(total))
        imgui.EndChild()
    end
end

imgui.OnFrame(function() return WinState[0] end,
    function()
        local W = 508
        local H = 320
        if SetWin[0] then
            H = 400
        elseif (ws.screen or 'home') == 'work' then
            H = 448
        end
        imgui.SetNextWindowPos(imgui.ImVec2(500, 500), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
        imgui.SetNextWindowSize(imgui.ImVec2(W, H), imgui.Cond.Always)
        imgui.Begin('##Window', WinState, imgui.WindowFlags.NoDecoration)
        local dl = imgui.GetWindowDrawList()
        local p = imgui.GetWindowPos()
        local sz = imgui.GetWindowSize()
        dl:AddRectFilled(p, imgui.ImVec2(p.x + 4, p.y + sz.y), imgui.ColorConvertFloat4ToU32(ws.uiAccent()), 2)
        imgui.SetCursorPos(imgui.ImVec2(16, 12))
        imgui.PushStyleColor(imgui.Col.Text, ws.uiAccent())
        imgui.Text('AutoZatochka')
        imgui.PopStyleColor()
        imgui.SameLine()
        imgui.TextDisabled('  Arizona  ·  ' .. tostring(thisScript().version or ''))
        imgui.SetCursorPos(imgui.ImVec2(W - 76, 8))
        if ws.uiIcon('##gear', 28) then
            SetWin[0] = not SetWin[0]
        end
        do
            local a = imgui.GetItemRectMin()
            local b = imgui.GetItemRectMax()
            local cx = (a.x + b.x) * 0.5
            local cy = (a.y + b.y) * 0.5
            local col = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.91, 0.92, 0.94, 1))
            pcall(function()
                dl:AddCircleFilled(imgui.ImVec2(cx - 6, cy), 2.1, col, 8)
                dl:AddCircleFilled(imgui.ImVec2(cx, cy), 2.1, col, 8)
                dl:AddCircleFilled(imgui.ImVec2(cx + 6, cy), 2.1, col, 8)
            end)
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip(SetWin[0] and 'Назад' or 'Настройки')
        end
        imgui.SameLine()
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.8, 0.22, 0.32, 0.35))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.9, 0.25, 0.35, 0.7))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.9, 0.25, 0.35, 0.9))
        if imgui.Button('X', imgui.ImVec2(28, 28)) then
            WinState[0] = false
            SetWin[0] = false
        end
        imgui.PopStyleColor(3)

        if SetWin[0] then
            imgui.SetCursorPos(imgui.ImVec2(16, 52))
            imgui.PushStyleColor(imgui.Col.Text, ws.uiAccent())
            imgui.Text('Настройки')
            imgui.PopStyleColor()
            imgui.Separator()
            imgui.Dummy(imgui.ImVec2(0, 8))
            ws.drawSettingsBody()
        else
            if (ws.screen or 'home') == 'work' then
                ws.drawWork()
            else
                ws.drawHome()
            end
        end
        imgui.End()
        if ws.picker and not SetWin[0] and (ws.screen or 'home') ~= 'work' then
            ws.drawPicker()
        end
    end
)

-- == Обработка событий: копии в очередь, прошлые хуки не затираем == --
if sampev then

    local prevTd = sampev.onShowTextDraw
    function sampev.onShowTextDraw(id, data)
        pcall(ws.noteTd, id, data)
        if prevTd then
            local ok, a = pcall(prevTd, id, data)
            if ok then return a end
        end
    end

    local prevMsg = sampev.onServerMessage
    function sampev.onServerMessage(color, text)
        pcall(function()
            if type(text) == 'string' and text ~= '' then
                queueChat(text)
            end
        end)
        if prevMsg then
            local ok, a = pcall(prevMsg, color, text)
            if ok then return a end
        end
    end
end

imgui.OnInitialize(function()
    imgui.GetIO().IniFilename = nil
    theme()
end)

function theme()
    imgui.SwitchContext()
    local ImVec4 = imgui.ImVec4
    imgui.GetStyle().WindowPadding = imgui.ImVec2(10, 10)
    imgui.GetStyle().FramePadding = imgui.ImVec2(10, 6)
    imgui.GetStyle().ItemSpacing = imgui.ImVec2(8, 8)
    imgui.GetStyle().ItemInnerSpacing = imgui.ImVec2(4, 2)
    imgui.GetStyle().TouchExtraPadding = imgui.ImVec2(0, 0)
    imgui.GetStyle().IndentSpacing = 12
    imgui.GetStyle().ScrollbarSize = 8
    imgui.GetStyle().GrabMinSize = 10
    imgui.GetStyle().WindowBorderSize = 0
    imgui.GetStyle().ChildBorderSize = 0
    imgui.GetStyle().PopupBorderSize = 0
    imgui.GetStyle().FrameBorderSize = 0
    imgui.GetStyle().TabBorderSize = 0
    imgui.GetStyle().WindowRounding = 10
    imgui.GetStyle().ChildRounding = 8
    imgui.GetStyle().FrameRounding = 6
    imgui.GetStyle().PopupRounding = 8
    imgui.GetStyle().ScrollbarRounding = 8
    imgui.GetStyle().GrabRounding = 4
    imgui.GetStyle().TabRounding = 6

    imgui.GetStyle().Colors[imgui.Col.Text]                   = ImVec4(0.94, 0.95, 0.97, 1.00)
    imgui.GetStyle().Colors[imgui.Col.TextDisabled]           = ImVec4(0.54, 0.57, 0.63, 1.00)
    imgui.GetStyle().Colors[imgui.Col.WindowBg]               = ImVec4(0.047, 0.055, 0.078, 0.97)
    imgui.GetStyle().Colors[imgui.Col.ChildBg]                = ImVec4(0.07, 0.08, 0.11, 0.55)
    imgui.GetStyle().Colors[imgui.Col.PopupBg]                = ImVec4(0.09, 0.10, 0.13, 0.98)
    imgui.GetStyle().Colors[imgui.Col.Border]                 = ImVec4(1.00, 1.00, 1.00, 0.06)
    imgui.GetStyle().Colors[imgui.Col.BorderShadow]           = ImVec4(0.00, 0.00, 0.00, 0.00)
    imgui.GetStyle().Colors[imgui.Col.FrameBg]                = ImVec4(1.00, 1.00, 1.00, 0.05)
    imgui.GetStyle().Colors[imgui.Col.FrameBgHovered]         = ImVec4(0.36, 0.58, 1.00, 0.22)
    imgui.GetStyle().Colors[imgui.Col.FrameBgActive]          = ImVec4(0.36, 0.58, 1.00, 0.35)
    imgui.GetStyle().Colors[imgui.Col.TitleBg]                = ImVec4(0.07, 0.08, 0.10, 1.00)
    imgui.GetStyle().Colors[imgui.Col.TitleBgActive]          = ImVec4(0.07, 0.08, 0.10, 1.00)
    imgui.GetStyle().Colors[imgui.Col.TitleBgCollapsed]       = ImVec4(0.07, 0.08, 0.10, 0.75)
    imgui.GetStyle().Colors[imgui.Col.MenuBarBg]             = ImVec4(0.07, 0.08, 0.11, 1.00)
    imgui.GetStyle().Colors[imgui.Col.ScrollbarBg]            = ImVec4(0.00, 0.00, 0.00, 0.00)
    imgui.GetStyle().Colors[imgui.Col.ScrollbarGrab]          = ImVec4(1.00, 1.00, 1.00, 0.12)
    imgui.GetStyle().Colors[imgui.Col.ScrollbarGrabHovered]   = ImVec4(0.36, 0.58, 1.00, 0.45)
    imgui.GetStyle().Colors[imgui.Col.ScrollbarGrabActive]    = ImVec4(0.36, 0.58, 1.00, 1.00)
    imgui.GetStyle().Colors[imgui.Col.CheckMark]              = ImVec4(0.36, 0.58, 1.00, 1.00)
    imgui.GetStyle().Colors[imgui.Col.SliderGrab]             = ImVec4(0.36, 0.58, 1.00, 1.00)
    imgui.GetStyle().Colors[imgui.Col.SliderGrabActive]       = ImVec4(1.00, 1.00, 1.00, 0.90)
    imgui.GetStyle().Colors[imgui.Col.Button]                 = ImVec4(0.36, 0.58, 1.00, 0.28)
    imgui.GetStyle().Colors[imgui.Col.ButtonHovered]          = ImVec4(0.36, 0.58, 1.00, 0.55)
    imgui.GetStyle().Colors[imgui.Col.ButtonActive]           = ImVec4(0.36, 0.58, 1.00, 1.00)
    imgui.GetStyle().Colors[imgui.Col.Header]                 = ImVec4(0.36, 0.58, 1.00, 0.25)
    imgui.GetStyle().Colors[imgui.Col.HeaderHovered]          = ImVec4(0.36, 0.58, 1.00, 0.40)
    imgui.GetStyle().Colors[imgui.Col.HeaderActive]           = ImVec4(0.36, 0.58, 1.00, 1.00)
    imgui.GetStyle().Colors[imgui.Col.Separator]              = ImVec4(1.00, 1.00, 1.00, 0.07)
    imgui.GetStyle().Colors[imgui.Col.SeparatorHovered]       = ImVec4(0.36, 0.58, 1.00, 0.45)
    imgui.GetStyle().Colors[imgui.Col.SeparatorActive]        = ImVec4(0.36, 0.58, 1.00, 0.70)
    imgui.GetStyle().Colors[imgui.Col.ResizeGrip]             = ImVec4(0.36, 0.58, 1.00, 0.25)
    imgui.GetStyle().Colors[imgui.Col.ResizeGripHovered]      = ImVec4(0.36, 0.58, 1.00, 0.55)
    imgui.GetStyle().Colors[imgui.Col.ResizeGripActive]       = ImVec4(0.36, 0.58, 1.00, 0.80)
    imgui.GetStyle().Colors[imgui.Col.Tab]                    = ImVec4(0.16, 0.16, 0.18, 1.00)
    imgui.GetStyle().Colors[imgui.Col.TabHovered]             = ImVec4(0.36, 0.58, 1.00, 0.40)
    imgui.GetStyle().Colors[imgui.Col.TabActive]              = ImVec4(0.36, 0.58, 1.00, 0.55)
    imgui.GetStyle().Colors[imgui.Col.TabUnfocused]          = ImVec4(0.12, 0.12, 0.14, 1.00)
    imgui.GetStyle().Colors[imgui.Col.TabUnfocusedActive]     = ImVec4(0.18, 0.18, 0.20, 1.00)
    imgui.GetStyle().Colors[imgui.Col.PlotLines]              = ImVec4(0.50, 0.50, 0.54, 1.00)
    imgui.GetStyle().Colors[imgui.Col.PlotLinesHovered]       = ImVec4(0.65, 0.65, 0.70, 1.00)
    imgui.GetStyle().Colors[imgui.Col.PlotHistogram]          = ImVec4(0.36, 0.58, 1.00, 0.70)
    imgui.GetStyle().Colors[imgui.Col.PlotHistogramHovered]   = ImVec4(0.36, 0.58, 1.00, 1.00)
    imgui.GetStyle().Colors[imgui.Col.TextSelectedBg]         = ImVec4(0.36, 0.58, 1.00, 0.35)
end
