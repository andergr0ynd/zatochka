--[[
    Автозаточка Arizona (CEF). Команда /mt
]]
script_name('AutoZatochka')
script_version('1.38')
script_author('andergr0ynd')
script_description('Автозаточка Arizona: одежда, оружие, Эликсир мастер (карты)')

local ok_ev, sampev = pcall(require, 'lib.samp.events')
if not ok_ev then ok_ev, sampev = pcall(require, 'samp.events') end
if not ok_ev then sampev = nil end
local ok_imgui, imgui = pcall(require, 'mimgui')
if not ok_imgui then
    function main()
        while not isSampAvailable() do wait(100) end
        sampAddChatMessage('[AutoZatochka] mimgui is required', -1)
    end
    return
end
local ok_cef, cefDlg = pcall(require, 'arizona-cef-dialogs')
if not ok_cef then cefDlg = nil end
local encoding = require 'encoding'
encoding.default = 'CP1251'
local u8 = encoding.UTF8
local new = imgui.new

-- Определение типов предметов встроено в основной скрипт.
local itemDatabase = (function()
-- Read item kinds from the installed Arizona client database. No ID ranges.
local M = {}
local function readItemsData(path, isZip)
    local file, err = io.open(path, 'rb')
    if not file then return nil, err end
    local ok, result = pcall(function()
        if not isZip then return assert(file:read('*a')) end
        local size = assert(file:seek('end'))
        local tailSize = math.min(size, 65557)
        assert(file:seek('set', size - tailSize))
        local tail = assert(file:read(tailSize))
        local function u16(s, p)
            local a, b = s:byte(p, p + 1)
            assert(b, 'Truncated ZIP header')
            return a + b * 256
        end
        local function u32(s, p)
            return u16(s, p) + u16(s, p + 2) * 65536
        end
        local eocd
        for p = #tail - 21, 1, -1 do
            if tail:sub(p, p + 3) == 'PK\005\006'
                and p + 21 + u16(tail, p + 20) == #tail then
                eocd = p
                break
            end
        end
        assert(eocd, 'ZIP directory not found')
        assert(u16(tail, eocd + 4) == 0 and u16(tail, eocd + 6) == 0,
            'Multipart ZIP is unsupported')
        local count = u16(tail, eocd + 10)
        local offset = u32(tail, eocd + 16)
        assert(count < 65535 and offset < 4294967295, 'ZIP64 is unsupported')
        assert(file:seek('set', offset))
        for i = 1, count do
            local header = assert(file:read(46))
            assert(#header == 46 and header:sub(1, 4) == 'PK\001\002', 'Invalid ZIP directory')
            local nameLen = u16(header, 29)
            local name = assert(file:read(nameLen))
            if name:gsub('\\', '/'):lower() == 'items.bin' then
                assert(u16(header, 9) % 2 == 0, 'Encrypted items.bin is unsupported')
                local method = u16(header, 11)
                local packed, unpacked = u32(header, 21), u32(header, 25)
                assert(packed <= 64 * 1024 * 1024 and unpacked <= 64 * 1024 * 1024,
                    'items.bin exceeds 64 MiB')
                assert(file:seek('set', u32(header, 43)))
                local localHeader = assert(file:read(30))
                assert(#localHeader == 30 and localHeader:sub(1, 4) == 'PK\003\004', 'Invalid ZIP entry')
                assert(file:seek('cur', u16(localHeader, 27) + u16(localHeader, 29)))
                local data = assert(file:read(packed))
                assert(#data == packed, 'Truncated items.bin in ZIP')
                if method == 0 then
                    assert(packed == unpacked, 'Invalid items.bin size')
                    return data
                end
                -- Existing Arizona archive uses method 0. For other archives,
                -- place an extracted items.bin next to this script.
                error('ZIP compression method ' .. method .. ': extract items.bin next to the script')
            end
            assert(file:seek('cur', u16(header, 31) + u16(header, 33)))
        end
        error('items.bin not found inside ZIP')
    end)
    file:close()
    if not ok then return nil, tostring(result) end
    return result
end

local function parseItems(data)
    local pos, size = 5, #data
    local function check(n)
        assert(pos + n - 1 <= size, 'Unexpected EOF at ' .. pos)
    end
    local function skip(n)
        check(n)
        pos = pos + n
    end
    local function readU8()
        check(1)
        local v = data:byte(pos)
        pos = pos + 1
        return v
    end
    local function readU16()
        check(2)
        local a, b = data:byte(pos, pos + 1)
        pos = pos + 2
        return a + b * 256
    end
    local function readString16()
        local n = readU16()
        check(n)
        local s = data:sub(pos, pos + n - 1)
        pos = pos + n
        return s
    end
    assert(data:sub(1, 4) == 'ITM2', 'Unsupported items.bin format (expected ITM2)')
    for i = 1, readU8() do skip(readU8()) end
    local count = readU16()
    readU16() -- maxIndex
    local result = {}
    for i = 1, count do
        local id = readU16()
        readU16() -- index; item ID is the lookup key
        local name = readString16()
        skip(readU16()) -- description
        check(13)
        local itemType, equipSlot = data:byte(pos), data:byte(pos + 2)
        local patch = itemType == 22 and name:match('^Нашивка на аксессуар%s*%(') ~= nil
        local kind
        if itemType == 78 then kind = 1
        elseif itemType == 79 then kind = 2
        elseif itemType == 10 then kind = 3
        elseif itemType == 6 and equipSlot == 9 then kind = 4
        elseif itemType == 3 or patch then kind = 0 end
        skip(13)
        skip(readU16()) -- extra
        skip(4) -- D0, D1, D4, D3
        for group = 1, 3 do skip(readU8() * 2) end
        assert(result[id] == nil, 'Duplicate item ID: ' .. id)
        result[id] = {name=name, kind=kind, itemType=itemType, equipSlot=equipSlot, patch=patch}
    end
    assert(pos == size + 1, 'Unexpected trailing data in items.bin')
    return result
end


M.parse = parseItems
function M.load(root)
    local paths = {
        {root .. '/items.bin', false},
        {root .. '/../items.bin', false},
        {root .. '/../arizona/items.bin', false},
        {root .. '/../arizona/items.zip', true},
        {root .. '/../items.zip', true},
    }
    local errors = {}
    for _, candidate in ipairs(paths) do
        local data, err = readItemsData(candidate[1], candidate[2])
        if data then
            local ok, items = pcall(parseItems, data)
            if ok then return items end
            errors[#errors+1] = tostring(items)
        end
    end
    return nil, table.concat(errors, '; ')
end
return M
end)()

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

local function nowSeconds()
    if type(getGameTimer) == 'function' then return getGameTimer() / 1000 end
    return os.time()
end

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
    local bust = url .. (url:find('?', 1, true) and '&' or '?') .. 't=' .. tostring(nowSeconds())
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
    local bust = url .. (url:find('?', 1, true) and '&' or '?') .. 't=' .. tostring(nowSeconds())
    local done, success = false, false
    downloadUrlToFile(bust, path, function(_, status)
        if status == d.STATUSEX_ENDDOWNLOAD or status == d.STATUS_ENDDOWNLOADDATA then
            done = true
            success = true
        end
    end)
    local t0 = nowSeconds()
    while not done and nowSeconds() - t0 < (timeout_sec or 45) do wait(50) end
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

local decodeJson = decodeJson
-- The bundled pure Lua decoder accepts root arrays without native cjson quirks.
do
    local ok, j = pcall(require, 'json')
    if ok and j and j.decode then decodeJson = j.decode end
end
if type(decodeJson) == 'function' then
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


local eventOf
local incomingCef, incomingChat = {}, {}
local function queueCef(str)
    if type(str) ~= 'string' or str == '' then return end
    if str:find('event.storage', 1, true) then return end
    local keep = str:find('playerInventory', 1, true) or str:find('workShop', 1, true)
        or str:find('setWorkshop', 1, true)
        or str:find('setResourceNeedItems', 1, true)
        or str:find('updateEnchantSlots', 1, true)
        or str:find('event.notify.initialize', 1, true)
        or str:find('startEnchant', 1, true)
    if not keep then return end
    incomingCef[#incomingCef + 1] = str .. ''
    if #incomingCef > 2048 then table.remove(incomingCef, 1) end
end
local function queueChat(text)
    if type(text) ~= 'string' or text == '' then return end
    incomingChat[#incomingChat + 1] = text .. ''
    if #incomingChat > 40 then table.remove(incomingChat, 1) end
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
-- Keep models and text labels separate: either RPC may arrive first.
function ws.rebuildCards()
    local c = ws.card
    local visible = c.visible or {}
    local old = c.inv or {}
    local inv, labels = {}, {}
    c.leftTd, c.rightTd, c.improveTd = -1, -1, -1
    c.leftFilled, c.rightFilled, c.improveReady = false, false, false
    c.leftLevel, c.rightLevel = nil, nil
    for id, td in pairs(visible) do
        local x, y = td.x, td.y
        local text = tostring(td.text or ''):gsub('~[^~]*~', '')
        local level = tonumber(text:upper():match('LEVEL%s*:%s*(%d+)'))
        local slotLevel = tonumber(text:match('%+%s*(%d+)'))
        if slotLevel and nearPos(x,y,171.13,245.136,3) then c.leftLevel = slotLevel end
        if slotLevel and nearPos(x,y,291.87,245.136,3) then c.rightLevel = slotLevel end
        if level then labels[#labels + 1] = {id=id, x=x, y=y, level=level} end
        -- Do not let a text overlay replace a model occupying the same position.
        if td.model == 19168 or td.style == 5 then
            if nearPos(x,y,168.03,182.28,4) then
                c.leftTd, c.leftFilled = id, td.model == 19168
            elseif nearPos(x,y,261.37,193.28,4) then
                c.rightTd, c.rightFilled = id, td.model == 19168
            end
        end
        if td.style ~= 5 and nearPos(x,y,185.66,258.65,4) then
            c.improveTd, c.improveReady = id, td.sel == 1
        end
        if td.model == 19168 and x >= CARD_INV_MIN_X and x <= 510 and y >= 140 and y <= 350 then
            -- Key by actual textdraw, not a floating point coordinate string.
            local previous = old[id]
            inv[id] = {id=id, model=td.model, level=-1, sel=td.sel, x=x, y=y, at=td.at}
            if previous and previous.x == x and previous.y == y then
                inv[id].used = previous.used
            end
        end
    end
    -- Match each level label to one card. Text labels must never remove models.
    for _, label in ipairs(labels) do
        local best, distance = nil, math.huge
        for _, info in pairs(inv) do
            local dx, dy = label.x-info.x, label.y-info.y
            -- Real LEVEL labels sit 24.5px to the right of a card; the next
            -- column is 26.5px away. Match inside the cell, not nearest model.
            if dx >= 0 and dx < 26.5 and dy >= 0 and dy < 30.5 then
                local d = dx*dx + dy*dy
                if d < distance then best, distance = info, d end
            end
        end
        if best then best.level = label.level; best.labelId = label.id end
        if c.leftFilled and nearPos(label.x,label.y,168.03,182.28,24) then
            ws.itemEnchant = label.level
        end
    end
    c.inv = inv
    -- Inventory alone does not mean that the card workshop is open.
    c.open = c.leftTd >= 0 and c.rightTd >= 0 and c.improveTd >= 0
    if c.leftFilled and c.leftLevel then ws.itemEnchant = c.leftLevel end
end

function ws.noteCardTd(id, td, x, y, text)
    id, x, y = tonumber(id), tonumber(x), tonumber(y)
    if not id or not x or not y then return end
    local c = ws.card
    c.visible = c.visible or {}
    local selectable = td.selectable
    if selectable == nil then selectable = td.selectAble end
    c.visible[id] = {x=x,y=y,text=text,model=tonumber(td.modelId or td.model or td.modelID) or 0,
        style=tonumber(td.style), sel=(selectable == true or tonumber(selectable) == 1) and 1 or 0,
        at=nowSeconds()}
    ws.rebuildCards()
end

function ws.cardTextChanged(id, text)
    local td = ws.card.visible and ws.card.visible[id]
    if td then td.text = text; td.at = nowSeconds(); ws.rebuildCards() end
end

function ws.cardTdHidden(id)
    if ws.card.visible then ws.card.visible[id] = nil end
    for slot, tid in pairs(ws.invTd) do if tid == id then ws.invTd[slot] = nil end end
    ws.rebuildCards()
end

function ws.isCard()
    return tonumber(ws.tab) == 5
end

function ws.cardCount(maxLvl)
    maxLvl = tonumber(maxLvl) or 99
    if maxLvl <= 0 then maxLvl = 99 end
    local n = 0
    for _, info in pairs(ws.card.inv or {}) do
        local lv = tonumber(info.level)
        if lv == nil then lv = -1 end
        local sel = tonumber(info.sel) or 0
        local tid = tonumber(info.id) or -1
        local ix = tonumber(info.x) or 0
        if lv >= 0 and not info.used and tid >= 0 and sel == 1 and ix >= CARD_INV_MIN_X and lv < maxLvl then
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
        if lv == nil then lv = -1 end
        local sel = tonumber(info.sel) or 0
        local tid = tonumber(info.id) or -1
        local ix = tonumber(info.x) or 0
        if lv >= 0 and not info.used and tid >= 0 and sel == 1 and ix >= CARD_INV_MIN_X and not ban[tid] and (target <= 0 or lv < target) then
            list[#list + 1] = { slot = slot, id = tid, level = lv }
        end
    end
    if c.placed == 1 then
        for _, item in ipairs(list) do
            if item.level == c.pairLevel then return item end
        end
        return nil, nil
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
    return nil, nil
end

function ws.clickTd(id)
    id = tonumber(id) or -1
    if id < 0 or type(sampSendClickTextdraw) ~= 'function' then return false end
    local now = nowSeconds()
    if (now - (tonumber(ws.card.lastClickAt) or 0)) < 0.4 then return false end
    ws.card.lastClickAt = now
    ws.card.seenAt = now
    sampSendClickTextdraw(id)
    return true
end

function ws.cardReady()
    local c = ws.card
    if c.waitingChat or ws.busy then return false end
    if nowSeconds() - (c.resultAt or -10) < 0.8 then return false end
    -- Both populated server slots take precedence over our local click counter.
    -- The server disables inventory cards once they are selected (sel=0).
    return c.open
        and c.leftFilled and c.rightFilled
        and c.improveReady
        and (tonumber(c.improveTd) or -1) >= 0
end

-- Всегда 2 карты из инвентаря заново (правый слот верстака часто фантомный)
function ws.placeCards()
    local c = ws.card
    if not c.open or c.waitingChat or ws.busy then return false end
    if nowSeconds() - (c.resultAt or -10) < 0.8 then return false end
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
            sampAddChatMessage(u8:decode('[AutoZatochka] Не найдены две доступные карты одного уровня.'), 0xFF3333)
        end
        return false
    end
    local pick = a
    if placed == 0 then
        if not b then return false end
        c.pairLevel = a.level
    end

    if ws.clickTd(pick.id) then
        if c.inv[pick.slot] then c.inv[pick.slot].used = true end
        c.placed = placed + 1
        c.step = (c.placed == 1) and 'waitLeft' or 'waitRight'
    end
    return false
end

function ws.startCardEnchant()
    local c = ws.card
    if not ws.cardReady() then return false end
    local target = tonumber(max_toch) or 0
    if target > 0 and c.leftLevel and c.leftLevel >= target then
        status = false
        max_toch = 0
        sampAddChatMessage(u8:decode('[AutoZatochka] Карта уже достигла выбранного уровня.'), -1)
        return false
    end
    if not ws.clickTd(c.improveTd) then return false end
    c.step = 'busy'
    c.placed = 0
    ws.busy = true
    ws.busyAt = nowSeconds()
    c.waitingChat = true
    return true
end

function parsePlayerInventory(str)
    local ev, payload = eventOf(str)
    if not ev or not ev:find('playerInventory', 1, true) then return end
    local data = decodeJson(payload)
    if type(data) ~= 'table' then return end
    if data[1] ~= nil then
        for _, message in ipairs(data) do ws.inventoryMessage(message) end
    else
        ws.inventoryMessage(data)
    end
end

function ws.inventoryMessage(message)
    if type(message) ~= 'table' or type(message.data) ~= 'table' then return end
    local data = message.data
    if tonumber(data.type) ~= 1 then return end
    if tonumber(message.action) == 2 and type(data.items) == 'table' then
        ws.cefInv = true
        ws.ingestItems(data.items, 1)
    elseif tonumber(message.action) == 1 and data.slot ~= nil then
        ws.ingestItems({{slot = data.slot, item = 0, amount = 0}}, 1)
    end
end

local sendQ = {}
eventOf = function(str)
    local ev, payload = str:match("window%.executeEvent%(%s*'([^']+)'%s*,%s*`(.*)`%s*%)")
    if ev then return ev, payload end
    ev, payload = str:match("window%.executeEvent%(%s*'([^']+)'%s*,%s*'(.*)'%s*%)")
    if ev then return ev, payload end
    return str:match('^([%w%.]+)|(.*)$')
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
    evalcef('(() => {' .. code .. '})()')
end

function evalcef(code, encoded)
    encoded = encoded or 0
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
    local bs = raknetNewBitStream()
    raknetBitStreamWriteInt8(bs, 220)
    raknetBitStreamWriteInt8(bs, 18)
    raknetBitStreamWriteInt16(bs, #str)
    raknetBitStreamWriteString(bs, str)
    raknetBitStreamWriteInt32(bs, 0)
    raknetSendBitStream(bs)
    raknetDeleteBitStream(bs)
end

function startEnchant()
    if not ws.loopReady() or ws.attempt then return false end
    if ws.isPatch() then
        local progress=ws.patchProgress()
        local target=math.min(3,tonumber(max_toch) or 3)
        if progress.level>=3 or (target>0 and progress.level>=target) then status=false;max_toch=0;return false end
    end
    if not ws.beginAttempt() then return false end
    sendCEF('startEnchant')
    return true
end

function ws.beginAttempt()
    if ws.attempt then return false end
    local progress=ws.isPatch() and ws.patchProgress()
    if progress and progress.level>=3 then return false end
    ws.attempt = { from = progress and progress.level or tonumber(ws.itemEnchant) or -1,
        slot = enchantSlotsData.index, tab = ws.tab }
    ws.busy = true
    ws.busyAt = nowSeconds()
    ws.available = 0
    return true
end

function ws.completeAttempt(success, toLvl)
    local attempt = ws.attempt
    if not attempt or attempt.tab ~= ws.tab or attempt.slot ~= enchantSlotsData.index then return end
    local progress=ws.isPatch() and ws.patchProgress()
    if progress and success then
        toLvl=math.min(3,attempt.from+1)
        progress.level=math.max(progress.level,toLvl)
    end
    if success and not toLvl then
        if attempt.from < 0 then ws.pendingResult = 1; return end
        toLvl = attempt.from + 1
    end
    ws.attempt = nil
    ws.pendingResult = nil
    ws.busy = false
    ws.available = 0
    ws.resultAt = nowSeconds()
    if success then
        ws.itemEnchant = toLvl
        ws.finishSuccess(attempt.from, toLvl)
    else
        ws.statFail()
    end
end

-- Разбор updateEnchantSlots: только regex, decodeJson не трогаем
local function parseEnchantSlotsPayload(jsonData)
    if not jsonData or #jsonData == 0 then return end
    if jsonData:gsub('^%s+', ''):sub(1, 1) == '[' then return end
    local index = jsonData:match('"index":%s*(%-?%d+)')
    local left = jsonData:match('"left":%s*(%-?%d+)')
    local right = jsonData:match('"right":%s*(%-?%d+)')
    local color = jsonData:match('"color":%s*(%-?%d+)')
    if index then
        local n = tonumber(index)
        -- Смена предмета в слоте (вставка / снятие) — это не результат заточки.
        if n ~= enchantSlotsData.index then
            ws.expectedSlots = nil
            ws.pendingResult = nil
            ws.chatHold = nil
            ws.itemEnchant = -1
            ws.itemId = -1
            ws.itemSlot = -1
            ws.leftItemId = nil
            ws.rightItemId = -1
            if ws.autoShop then ws.leftNeed = 0; ws.rightNeed = 1 end
            -- Новый предмет на станке → снова камень, пока не придёт ошибка про амулет.
            ws.amuletNeed = false
            ws.attempt = nil
            ws.busy = false
            ws.available = 0
            ws.lastPlaceAt = -10
            local item = ws.inventory and ws.inventory[n]
            if item then
                ws.itemSlot = n
                ws.itemId = tonumber(item.item) or -1
                ws.itemEnchant = tonumber(item.enchant) or tonumber(tostring(item.text or ''):match('%+(%d+)')) or -1
            end
        end
        enchantSlotsData.index = n
    end
    if left then enchantSlotsData.left = tonumber(left) end
    if right then enchantSlotsData.right = tonumber(right) end
    if color then enchantSlotsData.color = tonumber(color) end
    if ws.autoShop then ws.detectSelectedItem() end
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

function ws.isPatch()
    if not ws.isCloth() then return false end
    ws.ensureItemKinds()
    local selected = ws.inventory and ws.inventory[tonumber(enchantSlotsData.index)]
    local id = selected and tonumber(selected.item) or tonumber(ws.itemId)
    local meta = ws.itemKinds and ws.itemKinds[id]
    return meta and meta.patch == true or false
end

function ws.patchReportedLevel(item)
    if type(item)~='table' then return end
    -- Ordinary accessory patches store their actual level in unic_id / "3 lvl".
    -- The enchant field and chat's +0 -> +1 are not their level.
    local code=tonumber(item.unic_id)
    local text=tonumber(tostring(item.text or ''):match('(%d+)%s*[lL][vV][lL]'))
    local level
    for _,value in pairs({code=code,text=text}) do
        if value>=1 and value<=3 and value==math.floor(value) then level=math.max(level or 1,value) end
    end
    return level
end

function ws.patchProgress()
    local slot=tonumber(enchantSlotsData.index)
    local item=ws.inventory and ws.inventory[slot]
    local id=item and tonumber(item.item) or tonumber(ws.itemId)
    ws.patchLevels=ws.patchLevels or {}
    local progress=ws.patchLevels[slot]
    local reported=ws.patchReportedLevel(item)
    if not progress or progress.id~=id then
        progress={id=id,level=reported or 1}
        ws.patchLevels[slot]=progress
    elseif reported and reported>progress.level then
        progress.level=reported
    end
    ws.itemEnchant=progress.level
    return progress
end

function ws.isWeaponTab()
    return ws.isGun() or ws.isAttach()
end

function ws.ensureItemKinds()
    if ws.itemKinds or ws.itemKindsTried then return end
    ws.itemKindsTried = true
    if type(getWorkingDirectory) == 'function' then
        local items, err = itemDatabase.load(getWorkingDirectory())
        ws.itemKinds = items
        if not items then print('[AutoZatochka] Item database unavailable: ' .. tostring(err)) end
    end
end

function ws.applyAutoKind(kind)
    if not ws.autoShop or ws.isCard() or kind == nil then return end
    local weapon = kind == 1 or kind == 2
    if weapon ~= (ws.autoShop == 'gun') then return end
    if tonumber(ws.tab) == kind then return end
    ws.tab = kind
    ws.expectedSlots = nil
    ws.available = 0
    enchantSlotsData.left, enchantSlotsData.right = -1, -1
    ws.lastPlaceAt = -10
    ws.bestStone()
    ws.bestRes()
    if max_toch > ws.maxLevel() then max_toch = ws.maxLevel() end
end

function ws.detectSelectedItem()
    if not ws.autoShop or ws.isCard() then return end
    ws.ensureItemKinds()
    local item = ws.inventory and ws.inventory[tonumber(enchantSlotsData.index)]
    local id = item and tonumber(item.item) or tonumber(ws.itemId)
    local meta = ws.itemKinds and ws.itemKinds[id]
    if meta then
        ws.applyAutoKind(meta.kind)
        if meta.patch and ws.autoShop == 'cloth' then ws.setAmuletNeed(true) end
        if meta.patch and ws.autoShop == 'cloth' then ws.patchProgress() end
        if max_toch > ws.maxLevel() then max_toch = ws.maxLevel() end
    end
end

function ws.detectResourceKind(id)
    if not ws.autoShop or ws.isCard() then return end
    if id == GUN_STONE_ID then ws.applyAutoKind(1)
    elseif id == ATTACH_STONE_ID then ws.applyAutoKind(2)
    elseif id == ARMOR_STONE_ID then ws.applyAutoKind(4) end
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
    if ws.isPatch() then return 3 end
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
    c.placed = 0
    c.resultAt = nowSeconds()
    c.step = 'idle'
    for _, info in pairs(c.inv) do info.used = nil end
    ws.rebuildCards()
    c.open = c.leftTd >= 0 and c.rightTd >= 0 and c.improveTd >= 0
    c.seenAt = nowSeconds()
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

function ws.statFail()
    local now = nowSeconds()
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
    local now = nowSeconds()
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
    local cat = ws.isGun() and 6 or 0
    if ws.lastCat == cat then
        return
    end
    ws.lastCat = cat
    sendCEF('updateCategory|{"category": ' .. tostring(cat) .. '}')
end

function ws.setTab(t, skipCategory)
    ws.autoShop = nil
    t = tonumber(t) or 0
    if tonumber(ws.tab) == t then return false end
    ws.tab = t
    ws.expectedSlots = nil
    ws.attempt = nil
    ws.busy = false
    ws.pendingResult = nil
    ws.available = 0
    ws.leftNeed = 0
    ws.rightNeed = 1
    ws.lastPlaceAt = -10
    ws.card.waitingChat = false
    ws.card.placed = 0
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
        if not skipCategory then ws.sendCategory() end
    else
        ws.card.step = 'idle'
        -- Textdraws may already have arrived before the user picked this mode.
        ws.lowMatSaid = false
    end
    return true
end

function ws.slotsJson(idx, left, right, color)
    return '{"index":' .. tostring(idx) .. ',"left":' .. tostring(left)
        .. ',"right":' .. tostring(right) .. ',"color":' .. tostring(color) .. '}'
end

function ws.sendSlots(idx, left, right, color)
    local json = ws.slotsJson(idx, left, right, color)
    -- Native injected sends bypass onSendPacket in this MoonLoader build.
    parseEnchantSlotsPayload(json)
    ws.expectedSlots = {index=idx, left=left, right=right, color=color}
    ws.available = 0
    sendCEF('updateEnchantSlots|' .. json)
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
    if side == 'right' then ws.detectResourceKind(id) end
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
        if ws.autoShop then ws.available = 0; ws.expectedSlots = nil end
    end
end

function ws.pickRightId()
    if ws.isPatch() then return AMULET_ID end
    local explicit = tonumber(ws.rightItemId)
    if ws.autoShop and explicit and explicit > 0 and ws.isResourceId(explicit) then return explicit end
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
        '"' .. side .. 'ResourceItem":%s*(%d+)',
        '"' .. side .. 'ItemId":%s*(%d+)',
        '"' .. side .. 'Item":%s*(%d+)',
        '"' .. side .. 'ResourceId":%s*(%d+)',
        '"' .. side .. 'Resource":%s*(%d+)',
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
    if ws.isPatch() then on = true end
    on = not not on
    local id = on and AMULET_ID or Whetstone_ITEM_ID
    if ws.amuletNeed == on and (tonumber(ws.rightItemId) or -1) == id then
        return false
    end
    ws.amuletNeed = on
    ws.expectedSlots = nil
    ws.attempt = nil
    ws.available = 0
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
    if ws.attempt then return false end
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
    if (tonumber(enchantSlotsData.right) or -1) == slot and ws.available == 1 then
        return true
    end
    local now = nowSeconds()
    if (now - (tonumber(ws.lastPlaceAt) or 0)) < 0.8 then
        return false
    end
    ws.lastPlaceAt = now
    ws.available = 0
    local left = -1
    if ws.isPair() then
        local res = tonumber(ws.resSlot) or -1
        if res >= 0 then left = res end
    end
    ws.sendSlots(idx, left, slot, -1)
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

function ws.loopReady()
    return workshop_check and not ws.attempt and ws.available == 1
        and (tonumber(enchantSlotsData.index) or -1) >= 0
        and (not ws.isCloth() or ws.resourcesReady())
        and nowSeconds() - (ws.lastPlaceAt or -10) >= 0.4
        and nowSeconds() - (ws.resultAt or -10) >= 0.8
end

function ws.placeStone()
    if ws.attempt then return false end
    if ws.isPatch() and ws.patchProgress().level>=3 then status=false;max_toch=0;return false end
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
    if ws.resourcesReady() and ws.available == 1 then
        return true
    end
    local now = nowSeconds()
    local gap = pair and 1.0 or 2.5
    if (now - (tonumber(ws.lastPlaceAt) or 0)) < gap then
        return false
    end
    ws.lastPlaceAt = now
    ws.available = 0
    local left = tonumber(enchantSlotsData.left) or -1
    local right = tonumber(enchantSlotsData.right) or -1
    if pair then
        -- Оружие: слева материалы, справа заточка. Обвес: слева камень, справа заточка обвеса.
        -- Одежда: правый слот камень, амулет или заточка брони; левый — укроп или материалы, если станок просит.
        left = tonumber(ws.resSlot) or -1
        right = stone
    else
        right = stone
    end
    -- Assign slots once. Inventory clicks toggle selection and can undo this
    -- assignment when CEF subsequently emits its own updateEnchantSlots.
    ws.sendSlots(idx, left, right, -1)
    return idx >= 0
end

function ws.handleSend(text)
    local json = text:match('^updateEnchantSlots|(.+)')
    if json then parseEnchantSlotsPayload(json) end
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
    ws.inventory = ws.inventory or {}
    local targetSlot = tonumber(enchantSlotsData.index) or -1
    for _, item in pairs(items) do
        if type(item) == 'table' then
            local slot = tonumber(item.slot)
            if slot then
                local previous = ws.inventory[slot]
                local merged = {}
                if previous and (tonumber(previous.amount) or 1)>0
                    and (tonumber(item.amount) or 1)>0
                    and (item.item == nil or tonumber(item.item) == tonumber(previous.item)) then
                    for k, v in pairs(previous) do merged[k] = v end
                end
                for k, v in pairs(item) do merged[k] = v end
                item = merged
                ws.inventory[slot] = merged
            end
            local id = tonumber(item.item)
            if slot then
                local amt = tonumber(item.amount) or 1
                if ws.patchLevels and ws.patchLevels[slot] and (amt<=0 or ws.patchLevels[slot].id~=id) then ws.patchLevels[slot]=nil end
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
                    ws.detectSelectedItem()
                    if newLvl ~= nil then
                        local patch=ws.isPatch()
                        if patch then newLvl=ws.patchProgress().level end
                        -- Успех только если уровень того же предмета вырос ровно на 1 после попытки.
                        -- Первое появление +11 в слоте и «уже +11» успехом не считаем.
                        ws.itemEnchant = newLvl
                        local attempt = ws.attempt
                        if not patch and attempt and attempt.slot == slot and attempt.from >= 0 and newLvl == attempt.from + 1 then
                            ws.completeAttempt(true, newLvl)
                        elseif not patch and attempt and ws.pendingResult == 1 and newLvl >= 0 then
                            ws.completeAttempt(true, newLvl)
                        end

                    end
                end
            end
        end
    end
    ws.bestStone()
    ws.bestRes()
end

function ws.handle(ev, payload)
    if not ev then return end
    payload = payload or ''
    local decoded = decodeJson(payload)
    local arg = type(decoded) == 'table' and (decoded[1] ~= nil and decoded[1] or decoded) or nil
    if ev == 'event.inventory.setWorkshopVisible' then
        local on = arg == true
        workshop_check = on
        if not on then
            ws.expectedSlots = nil
            ws.busy = false
            ws.attempt = nil
            status = false
            max_toch = 0
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
        local on = arg == true
        ws.gunCtx = on and true or false
        if ws.autoShop and not ws.isCard() then
            ws.autoShop = on and 'gun' or 'cloth'
            ws.shop = ws.autoShop
            ws.detectSelectedItem()
        end
        if on then
            ws.lastCat = 6
            -- Context identifies the workshop, not its selected category.
        else
            -- Keep the mode chosen by the user.
        end
        return
    end
    if ev == 'event.workshop.setResourceNeedItems' then
        workshop_check = true
        local ln = tonumber(payload:match('"leftResourceAmount":%s*(%-?%d+)'))
        local rn = tonumber(payload:match('"rightResourceAmount":%s*(%-?%d+)'))
        if ln then ws.leftNeed = ln end
        if rn then ws.rightNeed = rn end
        -- An explicit resource ID from this demand event is authoritative.
        -- Do not require a failed first attempt to discover the amulet.
        if ws.isAmuletTab() and type(arg) == 'table' then
            local id = tonumber(arg.rightResourceItem or arg.rightItemId or arg.rightItem
                or arg.rightResourceId or arg.rightResource)
            if id == AMULET_ID or id == Whetstone_ITEM_ID then
                ws.setAmuletNeed(id == AMULET_ID)
            end
        end
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
        if low and ws.attempt and not ws.attempt.started then
            ws.attempt = nil
            ws.busy = false
            ws.available = 0
        end
        return
    end
    if ev == 'event.inventory.workShop' and type(arg) == 'table' then
        workshop_check = true
        if ws.isCard() then return end
        local action = tonumber(arg.action)
        local data = type(arg.data) == 'table' and arg.data or {}
        if action == 2 then
            ws.available = (data.available == true or tonumber(data.available) == 1) and 1 or 0
        elseif action == 0 then
            ws.beginAttempt()
            if ws.attempt then ws.attempt.started = true end
        elseif action == 1 then
            if data.success == true or tonumber(data.success) == 1 then
                ws.completeAttempt(true)
            elseif data.success == false or tonumber(data.success) == 0 then
                ws.completeAttempt(false)
            end
        end
        return
    end
end

local function processCefText(str)
    if type(str) ~= 'string' or str == '' then return end
    if str:find('playerInventory', 1, true) then parsePlayerInventory(str); return end
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
    if ws.isCard() and ws.card.waitingChat then
        ws.afterCardResult(isSuccess, fromLvl, toLvl)
        return
    end
    if not ws.attempt then return end
    if not ws.isPatch() and ws.attempt.from >= 0 and fromLvl ~= ws.attempt.from then return end
    ws.completeAttempt(isSuccess, toLvl)
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

-- Read our own copy from offset zero and always restore the caller's cursor.
-- For compressed strings the advertised length is OUTPUT capacity, not wire size.
local transport = { packets = 0, inventory = 0, errors = 0, lastError = '' }
local function readCefPacket(bs, outgoing)
    local saved = raknetBitStreamGetReadOffset(bs)
    local ok, text, serverId = pcall(function()
        raknetBitStreamSetReadOffset(bs, 0)
        raknetBitStreamIgnoreBits(bs, 8)
        local kind = raknetBitStreamReadInt8(bs)
        if kind < 0 then kind = kind + 256 end
        if outgoing then
            if kind ~= 18 then return end
        elseif kind == 17 then
            raknetBitStreamIgnoreBits(bs, 32)
        else
            return
        end
        local length = raknetBitStreamReadInt16(bs)
        if length < 0 then length = length + 65536 end
        if length == 0 then return '' end
        local encoded = not outgoing and raknetBitStreamReadInt8(bs) or 0
        if encoded ~= 0 then
            return raknetBitStreamDecodeString(bs, length + 1)
        end
        if length * 8 > raknetBitStreamGetNumberOfUnreadBits(bs) then
            error('truncated CEF packet')
        end
        local value = raknetBitStreamReadString(bs, length)
        local server = 0
        if outgoing and raknetBitStreamGetNumberOfUnreadBits(bs) >= 32 then
            server = raknetBitStreamReadInt32(bs)
        end
        return value, server
    end)
    raknetBitStreamSetReadOffset(bs, saved)
    if not ok then
        transport.errors = transport.errors + 1
        transport.lastError = tostring(text)
        if transport.errors <= 3 then print('[AutoZatochka] CEF read: ' .. tostring(text)) end
        return
    end
    return text, serverId
end

local function receiveCefPacket(id, bs)
    if id ~= 220 then return end
    local text = readCefPacket(bs, false)
    if type(text) ~= 'string' or text == '' then return end
    transport.packets = transport.packets + 1
    if text:find('playerInventory', 1, true) then transport.inventory = transport.inventory + 1 end
    queueCef(text)
end

function ws.preserveSlots(text)
    if not ws.autoOn() or ws.isCard() then return text end
    local json = text:match('^updateEnchantSlots|(.+)')
    local want = ws.expectedSlots
    if not json or not want then return text end
    local data = decodeJson(json)
    if type(data) ~= 'table' then return text end
    if tonumber(data.index) ~= want.index then
        ws.expectedSlots = nil
        return text
    end
    return 'updateEnchantSlots|' .. ws.slotsJson(want.index, want.left, want.right, tonumber(data.color) or -1)
end

local function sendCefPacket(id, bs)
    if id ~= 220 then return end
    local text, serverId = readCefPacket(bs, true)
    if type(text) ~= 'string' then return end
    local corrected = ws.preserveSlots(text)
    if corrected ~= text then
        raknetBitStreamSetWriteOffset(bs, 0)
        raknetBitStreamWriteInt8(bs, 220)
        raknetBitStreamWriteInt8(bs, 18)
        raknetBitStreamWriteInt16(bs, #corrected)
        raknetBitStreamWriteString(bs, corrected)
        raknetBitStreamWriteInt32(bs, serverId or 0)
    end
    queueSend(corrected)
end

-- Independent of arizona-events: that library rejects some compressed packets
-- before onArizonaDisplay, so a successful require is not evidence of delivery.
if type(addEventHandler) == 'function' then
    addEventHandler('onReceivePacket', receiveCefPacket)
    addEventHandler('onSendPacket', sendCefPacket)
end

function main()
    while not isSampAvailable() do wait(100) end
    sampRegisterChatCommand('mt', function() WinState[0] = not WinState[0] end)
    sampAddChatMessage('[AutoZatochka] ' .. u8:decode('загружен. /mt'), -1)

    -- Загрузка звука успешной заточки с GitHub в фоне
    lua_thread.create(function()
        wait(500)
        initSuccessSound()
    end)

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
                    if nowSeconds() - (tonumber(ws.busyAt) or 0) > 25 then
                        status = false
                        max_toch = 0
                        sampAddChatMessage(u8:decode('[AutoZatochka] Нет результата улучшения карт. Открой мастерскую заново.'), -1)
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
                        if nowSeconds() - (tonumber(ws.busyAt) or 0) > 20 then
                            status = false
                            max_toch = 0
                            sampAddChatMessage(u8:decode('[AutoZatochka] Нет результата попытки. Открой мастерскую заново.'), -1)
                        else
                            wait(120)
                        end
                    else
                        local ready = ws.loopReady()
                        if ready then
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
    if ws.isPatch() and i < 2 then return end
    if ws.isPatch() and i > 3 then i = 3 end
    if ws.isCard() and i < 2 then return end
    if ws.isCard() and i > 3 then i = 3 end
    if max_toch ~= i then
        status = true
        max_toch = i
        ws.lowMatSaid = false
        -- The main loop owns placement and starting in every workshop.
        -- Selecting a goal must not run a second controller or reset progress.
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
    if ws.autoShop then return ws.autoShop == 'gun' and 'Магазин оружия' or 'Мастерская одежды' end
    if ws.isGun() then return 'Скины на оружие' end
    if ws.isAttach() then return 'Обвесы' end
    if ws.isArmor() then return 'Бронежилеты' end
    if ws.isSkin() then return 'Скины' end
    return 'Аксессуары'
end

function ws.chooseMode(tab)
    tab = tonumber(tab) or 0
    local shop = (tab == 5) and 'card' or ((tab == 1 or tab == 2) and 'gun' or 'cloth')
    if ws.shop ~= shop or (shop ~= 'card' and not ws.autoShop) or (shop == 'card' and not ws.isCard()) then
        ws.setTab(shop == 'card' and 5 or (shop == 'gun' and 1 or 0), true)
    end
    ws.autoShop = shop ~= 'card' and shop or nil
    ws.shop = shop
    ws.picker = nil
    ws.screen = 'work'
    if ws.autoShop then ws.detectSelectedItem() end
end

function ws.drawHome()
    imgui.SetCursorPos(imgui.ImVec2(16, 64))
    imgui.TextDisabled('Выбери мастерскую')
    imgui.SetCursorPos(imgui.ImVec2(16, 96))
    if ws.uiNav('Мастерская одежды', ws.autoShop == 'cloth', 476, 52) then
        ws.chooseMode(0)
    end
    imgui.SetCursorPos(imgui.ImVec2(16, 160))
    if ws.uiNav('Магазин оружия', ws.autoShop == 'gun', 476, 52) then
        ws.chooseMode(1)
    end
    imgui.SetCursorPos(imgui.ImVec2(16, 224))
    if ws.uiNav('Эликсир мастер', ws.isCard() or ws.picker == 'card', 476, 52) then
        ws.chooseMode(5)
    end
end

function ws.drawWork()
    imgui.SetCursorPos(imgui.ImVec2(16, 48))
    if ws.uiNav('Назад', false, 88, 32) then
        status = false
        max_toch = 0
        ws.screen = 'home'
        ws.picker = nil
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
            local filled = (c.leftFilled and 1 or 0) + (c.rightFilled and 1 or 0)
            imgui.TextDisabled('Карт для выбора: ' .. tostring(nCards) .. '  ·  на станке: ' .. tostring(filled) .. '/2')
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
        local minL = (ws.isCard() or ws.isPatch()) and 2 or 1
        for i = minL, maxL do
            local col = (i - minL) % 4
            local row = math.floor((i - minL) / 4)
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

    local prevTdText = sampev.onTextDrawSetString
    function sampev.onTextDrawSetString(id, text)
        ws.cardTextChanged(id, text)
        if prevTdText then return prevTdText(id, text) end
    end
    local prevTdHide = sampev.onTextDrawHide
    function sampev.onTextDrawHide(id)
        ws.cardTdHidden(id)
        if prevTdHide then return prevTdHide(id) end
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
