local success, msg = lib.checkDependency('oxmysql', '2.7.3')

if success then
    success, msg = lib.checkDependency('ox_lib', '3.10.0')
end

---@diagnostic disable-next-line: param-type-mismatch
if not success then return warn(msg) end


local cfg = lib.require('config.config')
local Vending = {}
local slotCounter = 0

local function generateSlotId()
    slotCounter += 1
    return 'slot_' .. slotCounter .. '_' .. os.time()
end

-- Migrate old shop format (keyed by itemName) to new slot-based format
local function migrateShop(shop)
    if not shop or table.type(shop) == 'empty' then return {} end

    -- Check if already migrated (first key starts with 'slot_')
    for k, _ in pairs(shop) do
        if type(k) == 'string' and k:find('^slot_') then
            return shop -- already new format
        end
        break
    end

    -- Old format: shop[itemName] = {count, price, label, ...}
    local newShop = {}
    for itemName, itemData in pairs(shop) do
        if type(itemData) == 'table' and itemData.count and itemData.price then
            local slotId = generateSlotId()
            newShop[slotId] = {
                itemName = itemName,
                count = itemData.count,
                price = itemData.price,
                currency = itemData.currency or 'money',
                label = itemData.label or itemName,
                metadata = itemData.metadata
            }
        end
    end

    return newShop
end

---------------------------------------------------------------
-- Helper: Sync stash contents -> shop table
-- Reads ox_inventory stash, updates counts, removes gone items
---------------------------------------------------------------
local function SyncStashToShop(name)
    if not cfg.useInventory then return end
    if not Vending[name] then return end

    local stashId = 'vending_' .. name
    local stashItems = exports.ox_inventory:GetInventory(stashId, false)

    if not stashItems or not stashItems.items then
        -- Stash is empty -> clear shop
        Vending[name].shop = {}
        return
    end

    local oldShop = Vending[name].shop or {}
    local newShop = {}
    local usedSlots = {}

    for _, item in pairs(stashItems.items) do
        if item and item.name then
            -- Try to find matching existing slot (same item, same metadata)
            local matchedSlotId = nil
            for slotId, slotData in pairs(oldShop) do
                if not usedSlots[slotId] and slotData.itemName == item.name
                    and json.encode(slotData.metadata or {}) == json.encode(item.metadata or {}) then
                    matchedSlotId = slotId
                    break
                end
            end

            if matchedSlotId then
                usedSlots[matchedSlotId] = true
                newShop[matchedSlotId] = {
                    itemName = item.name,
                    count = item.count,
                    price = oldShop[matchedSlotId].price,
                    currency = oldShop[matchedSlotId].currency or 'money',
                    label = item.label or oldShop[matchedSlotId].label,
                    metadata = item.metadata
                }
            else
                -- New item in stash without price -> price 0, owner must set
                local slotId = generateSlotId()
                newShop[slotId] = {
                    itemName = item.name,
                    count = item.count,
                    price = 0,
                    currency = 'money',
                    label = item.label or GetItemLabel(item.name) or item.name,
                    metadata = item.metadata
                }
            end
        end
    end

    Vending[name].shop = newShop
end

---------------------------------------------------------------
-- Helper: Sync shop table -> stash (after buy/remove from shop)
---------------------------------------------------------------
local function SyncShopToStash(name)
    if not cfg.useInventory then return end
    if not Vending[name] then return end

    local stashId = 'vending_' .. name

    exports.ox_inventory:ClearInventory(stashId)

    if Vending[name].shop then
        for _, slotData in pairs(Vending[name].shop) do
            if slotData.count > 0 then
                exports.ox_inventory:AddItem(stashId, slotData.itemName, slotData.count, slotData.metadata)
            end
        end
    end
end

---------------------------------------------------------------
-- Register ox_inventory shop with current items
---------------------------------------------------------------
function RegisterVendingInventory(name)
    if not cfg.useInventory then return end
    if not Vending[name] then return end

    exports.ox_inventory:RegisterStash('vending_' .. name, L('context.vending_title') .. ' - ' .. name, 50, 100000, nil,
        nil)

    local shopItems = {}
    if Vending[name].shop then
        for _, slotData in pairs(Vending[name].shop) do
            if slotData.price > 0 and slotData.count > 0 then
                local item = {
                    name = slotData.itemName,
                    price = slotData.price,
                    count = slotData.count,
                    metadata = slotData.metadata,
                }

                if slotData.currency and slotData.currency ~= 'money' then
                    item.currency = slotData.currency
                end

                shopItems[#shopItems + 1] = item
            end
        end
    end

    if #shopItems == 0 then
        return
    end

    exports.ox_inventory:RegisterShop('shop_vending_' .. name, {
        name = L('context.vending_title') .. ' - ' .. name,
        groups = false,
        inventory = shopItems
    })
end

---------------------------------------------------------------
-- DB Load
---------------------------------------------------------------
MySQL.ready(function()
    Wait(1000)
    local success, error = pcall(MySQL.scalar.await, 'SELECT 1 FROM `uniq-vending`')

    if not success then
        MySQL.query([[
            CREATE TABLE IF NOT EXISTS `uniq-vending` (
                `name` varchar(50) DEFAULT NULL,
                `data` longtext DEFAULT NULL,
                `shop` longtext DEFAULT '[]',
                `balance` int(11) DEFAULT 0,
                UNIQUE KEY `name` (`name`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
        ]])
    end

    Wait(50)

    local result = MySQL.query.await('SELECT * FROM `uniq-vending`')

    if result[1] then
        for k, v in pairs(result) do
            local data = json.decode(v.data)
            local shop = json.decode(v.shop)

            Vending[v.name] = data
            Vending[v.name].shop = migrateShop(shop)
            Vending[v.name].balance = v.balance

            if cfg.useInventory then
                SyncShopToStash(v.name)
                RegisterVendingInventory(v.name)
            end
        end
    end
end)

---------------------------------------------------------------
-- Owner adds item via stash -> gets asked price + currency
---------------------------------------------------------------
RegisterNetEvent('uniq-vending:setData', function(price, currency, payload)
    local src = source
    local shopName = payload.toInventory:gsub('vending_', '')
    local itemName = payload.fromSlot.name

    if Vending[shopName] then
        if not Vending[shopName].shop then Vending[shopName].shop = {} end

        local slotId = generateSlotId()
        Vending[shopName].shop[slotId] = {
            itemName = itemName,
            count = payload.count,
            price = price,
            currency = currency or 'money',
            label = GetItemLabel(itemName),
            metadata = payload.fromSlot.metadata
        }

        RegisterVendingInventory(shopName)

        lib.notify(src,
            { description = L('notify.item_added'):format(Vending[shopName].shop[slotId].label, price),
                type = 'success' })
    end
end)

---------------------------------------------------------------
-- Non-inventory mode: owner adds stock (now with currency)
---------------------------------------------------------------
RegisterNetEvent('uniq-vending:addStockItems', function(data)
    local src = source

    if Vending[data.shop] then
        if not Vending[data.shop].shop then Vending[data.shop].shop = {} end

        local slotId = generateSlotId()
        Vending[data.shop].shop[slotId] = {
            itemName = data.itemName,
            count = data.count,
            price = data.price,
            currency = data.currency or 'money',
            label = GetItemLabel(data.itemName),
            metadata = data.metadata
        }

        RemoveItem(src, data.itemName, data.count)

        if cfg.useInventory then
            SyncShopToStash(data.shop)
            RegisterVendingInventory(data.shop)
        end
    end
end)

---------------------------------------------------------------
-- Buy item from shop
---------------------------------------------------------------
RegisterNetEvent('uniq-vending:buyItem', function(data)
    local src = source

    if Vending[data.shop] then
        local slot = Vending[data.shop].shop[data.slotId]
        if not slot then return end

        local totalCost = slot.price * data.count

        if slot.currency and slot.currency ~= 'money' then
            -- Item currency
            local playerItems = GetInvItems(src)
            local hasEnough = false

            for _, item in pairs(playerItems) do
                if item.name == slot.currency then
                    local count = item.count or item.amount or 0
                    if count >= totalCost then
                        hasEnough = true
                        break
                    end
                end
            end

            if not hasEnough then
                lib.notify(src, { description = L('notify.not_enough_money_item'), type = 'error' })
                return
            end

            RemoveItem(src, slot.currency, totalCost)
        else
            if not CanAfford(src, totalCost) then
                lib.notify(src, { description = L('notify.not_enough_money_item'), type = 'error' })
                return
            end
        end

        slot.count -= data.count

        if slot.count <= 0 then
            Vending[data.shop].shop[data.slotId] = nil
        end

        AddItem(src, slot.itemName, data.count, slot.metadata)

        if not slot.currency or slot.currency == 'money' then
            Vending[data.shop].balance += totalCost
        end

        if cfg.useInventory then
            SyncShopToStash(data.shop)
            RegisterVendingInventory(data.shop)
        end
    end
end)

---------------------------------------------------------------
-- Owner removes item
---------------------------------------------------------------
RegisterNetEvent('uniq-vending:removeShopItem', function(data)
    local src = source

    if Vending[data.shop] then
        local slot = Vending[data.shop].shop[data.slotId]
        if not slot then return end

        local isOwnerCheck = false
        if type(Vending[data.shop].owner) == 'string' then
            isOwnerCheck = Vending[data.shop].owner == GetIdentifier(src)
        elseif type(Vending[data.shop].owner) == 'table' then
            local job, grade = GetJob(src)
            isOwnerCheck = Vending[data.shop].owner[job] and grade >= Vending[data.shop].owner[job]
        end

        if not isOwnerCheck then return end

        slot.count -= data.count

        if slot.count <= 0 then
            Vending[data.shop].shop[data.slotId] = nil
        end

        AddItem(src, slot.itemName, data.count, slot.metadata)

        if cfg.useInventory then
            SyncShopToStash(data.shop)
            RegisterVendingInventory(data.shop)
        end
    end
end)

---------------------------------------------------------------
-- Owner updates price/currency
---------------------------------------------------------------
RegisterNetEvent('uniq-vending:updatePrice', function(data)
    local src = source

    if Vending[data.shop] then
        local slot = Vending[data.shop].shop[data.slotId]
        if not slot then return end

        local isOwnerCheck = false
        if type(Vending[data.shop].owner) == 'string' then
            isOwnerCheck = Vending[data.shop].owner == GetIdentifier(src)
        elseif type(Vending[data.shop].owner) == 'table' then
            local job, grade = GetJob(src)
            isOwnerCheck = Vending[data.shop].owner[job] and grade >= Vending[data.shop].owner[job]
        end

        if not isOwnerCheck then return end

        slot.price = data.price
        if data.currency then
            slot.currency = data.currency
        end

        if cfg.useInventory then
            RegisterVendingInventory(data.shop)
        end
    end
end)

---------------------------------------------------------------
-- Callbacks
---------------------------------------------------------------
lib.callback.register('uniq-vending:fetchVendings', function(source)
    return Vending
end)

lib.callback.register('uniq-vending:GetItems', function(source, name)
    if Vending[name] then
        return Vending[name].shop
    end
    return false
end)

lib.callback.register('uniq-vending:GetPlayerInv', function(source)
    local items = GetInvItems(source)
    local options = {}

    for k, v in pairs(items) do
        options[#options + 1] = { label = ('%s | Count: %s'):format(v.label, v.amount or v.count), value = v.name }
    end

    return options
end)

lib.callback.register('uniq-vending:getInventoryItems', function(source)
    return exports.ox_inventory:Items()
end)

lib.callback.register('uniq-vending:getMoneyShop', function(source, shop)
    if Vending[shop] then
        return Vending[shop].balance
    end
    return 0
end)

lib.callback.register('uniq-vending:getMax', function(source, item)
    local items = GetInvItems(source)

    for k, v in pairs(items) do
        if v.name == item then
            return v.count or v.amount
        end
    end
end)

---------------------------------------------------------------
-- Admin commands
---------------------------------------------------------------
lib.addCommand('addvending', {
    help = L('commands.addvending'),
    restricted = 'group.admin'
}, function(source, args, raw)
    if source == 0 then return end
    local options = {}

    local players = GetAllPlayers()

    if IsQBCore() then
        for k, v in pairs(players) do
            options[#options + 1] = { label = ('%s | %s'):format(v.PlayerData.name, v.PlayerData.source),
                value = v.PlayerData.citizenid, id = v.PlayerData.source }
        end
    elseif IsESX() then
        for k, v in pairs(players) do
            options[#options + 1] = { label = ('%s | %s'):format(v.getName(), v.source), value = v.identifier,
                id = v.source }
        end
    end

    TriggerClientEvent('uniq-vending:startCreating', source, options)
end)

lib.addCommand('dellvending', {
    help = L('commands.dellvending'),
    restricted = 'group.admin'
}, function(source, args, raw)
    if source == 0 then return end
    local options = {}
    local count = 0

    for k, v in pairs(Vending) do
        count += 1
    end

    if count == 0 then
        return lib.notify(source, { description = L('notify.no_vendings'), type = 'error' })
    end

    for k, v in pairs(Vending) do
        options[#options + 1] = { label = v.name, value = v.name }
    end

    TriggerClientEvent('uniq-vending:client:dellvending', source, options)
end)

lib.addCommand('findvending', {
    help = L('commands.findvending'),
    restricted = 'group.admin'
}, function(source, args, raw)
    if source == 0 then return end
    local options = {}
    local count = 0

    for k, v in pairs(Vending) do
        count += 1
    end

    if count == 0 then
        return lib.notify(source, { description = L('notify.no_vendings'), type = 'error' })
    end

    for k, v in pairs(Vending) do
        options[#options + 1] = { label = v.name, value = v.name }
    end

    local cb = lib.callback.await('uniq-vending:choseVending', source, options)

    if cb then
        if Vending[cb] then
            local coords = Vending[cb].coords
            local ped = GetPlayerPed(source)
            SetEntityCoords(ped, coords.x, coords.y + 1, coords.z, false, false, false, false)
        end
    end
end)

---------------------------------------------------------------
-- Delete/Buy/Sell vending
---------------------------------------------------------------
RegisterNetEvent('uniq-vending:server:dellvending', function(shop)
    if Vending[shop] then
        MySQL.query('DELETE FROM `uniq-vending` WHERE `name` = ?', { shop })

        if cfg.useInventory then
            exports.ox_inventory:ClearInventory('vending_' .. shop)
        end

        Vending[shop] = nil
        TriggerClientEvent('uniq-vending:sync', -1, Vending, true)
    end
end)

RegisterNetEvent('uniq-vending:buyVending', function(name)
    local src = source

    if Vending[name] then
        if CanAfford(src, Vending[name].price) then

            if Vending[name].type == 'player' then
                local identifier = GetIdentifier(src)
                Vending[name].owner = identifier
            elseif Vending[name].type == 'job' then
                local job, grade = GetJob(src)
                Vending[name].owner = { [job] = grade }
            end

            MySQL.update('UPDATE `uniq-vending` SET `data` = ? WHERE `name` = ?',
                { json.encode(Vending[name], { sort_keys = true }), name })
            TriggerClientEvent('uniq-vending:sync', -1, Vending, true)

            lib.notify(src,
                { description = L('notify.vending_bought'):format(Vending[name].name, Vending[name].price),
                    type = 'success' })
        else
            lib.notify(src, { description = L('notify.not_enough_money'):format(Vending[name].price), type = 'error' })
        end
    end
end)

RegisterNetEvent('uniq-vending:sellVending', function(name)
    local src = source

    if Vending[name] then
        local price = math.floor(Vending[name].price * cfg.SellPertencage)

        AddMoney(src, price)
        Vending[name].owner = false

        MySQL.update('UPDATE `uniq-vending` SET `data` = ? WHERE `name` = ?',
            { json.encode(Vending[name], { sort_keys = true }), name })
        TriggerClientEvent('uniq-vending:sync', -1, Vending, true)
        lib.notify(src, { description = L('notify.vending_sold'):format(Vending[name].name, price), type = 'success' })
    end
end)

RegisterNetEvent('uniq-vending:createVending', function(data)
    local src = source

    MySQL.insert('INSERT INTO `uniq-vending` (name, data, balance) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE data = VALUES(data), balance = VALUES(balance)'
        , { data.name, json.encode(data, { sort_keys = true }), 0 })

    lib.notify(src, { description = L('notify.vending_created'):format(data.name, data.price), type = 'success' })

    Vending[data.name] = data
    Vending[data.name].shop = {}
    Vending[data.name].balance = 0

    if cfg.useInventory then
        RegisterVendingInventory(data.name)
    end

    TriggerClientEvent('uniq-vending:sync', -1, Vending, false)
end)

---------------------------------------------------------------
-- Withdraw / Deposit
---------------------------------------------------------------
RegisterNetEvent('uniq-vending:withdaw', function(shop, amount)
    local src = source

    if Vending[shop] then
        local isOwnerCheck = false
        if type(Vending[shop].owner) == 'string' then
            isOwnerCheck = Vending[shop].owner == GetIdentifier(src)
        elseif type(Vending[shop].owner) == 'table' then
            local job, grade = GetJob(src)
            isOwnerCheck = Vending[shop].owner[job] and grade >= Vending[shop].owner[job]
        end

        if isOwnerCheck and Vending[shop].balance >= amount then
            Vending[shop].balance -= amount
            AddMoney(src, amount)
        end
    end
end)

RegisterNetEvent('uniq-vending:deposit', function(shop, amount)
    local src = source

    if Vending[shop] then
        local isOwnerCheck = false
        if type(Vending[shop].owner) == 'string' then
            isOwnerCheck = Vending[shop].owner == GetIdentifier(src)
        elseif type(Vending[shop].owner) == 'table' then
            local job, grade = GetJob(src)
            isOwnerCheck = Vending[shop].owner[job] and grade >= Vending[shop].owner[job]
        end

        if isOwnerCheck then
            Vending[shop].balance += amount
            RemoveMoney(src, amount)
        end
    end
end)

---------------------------------------------------------------
-- Jobs callbacks
---------------------------------------------------------------
lib.callback.register('uniq-vending:getJobs', function(source)
    local jobs = GetJobs()
    local options = {}

    if IsESX() then
        for k, v in pairs(jobs) do
            if not cfg.BlacklsitedJobs[k] then
                options[#options + 1] = { label = v.label, value = k }
            end
        end
    elseif IsQBCore() then
        for k, v in pairs(jobs) do
            if not cfg.BlacklsitedJobs[k] then
                options[#options + 1] = { label = v.label, value = k }
            end
        end
    end

    return options
end)

lib.callback.register('uniq-vending:getGrades', function(source, job)
    local jobs = GetJobs()
    local options = {}

    if IsESX() then
        for k, v in pairs(jobs[job].grades) do
            options[#options + 1] = { label = v.label, value = v.grade }
        end
    elseif IsQBCore() then
        for k, v in pairs(jobs[job].grades) do
            options[#options + 1] = { label = v.name, value = tonumber(k) }
        end
    end

    return options
end)

---------------------------------------------------------------
-- Save DB
---------------------------------------------------------------
local function saveDB()
    local insertTable = {}
    if table.type(Vending) == 'empty' then return end

    for k, v in pairs(Vending) do
        insertTable[#insertTable + 1] = { query = 'UPDATE `uniq-vending` SET `shop` = ?, `balance` = ? WHERE `name` = ?',
            values = { json.encode(v.shop, { sort_keys = true }), v.balance, v.name } }
    end

    MySQL.transaction(insertTable)
end

lib.cron.new('*/5 * * * *', function()
    saveDB()
end)

AddEventHandler('playerDropped', function()
    if GetNumPlayerIndices() == 0 then
        saveDB()
    end
end)

AddEventHandler('txAdmin:events:serverShuttingDown', function()
    saveDB()
end)

AddEventHandler('txAdmin:events:scheduledRestart', function(eventData)
    if eventData.secondsRemaining ~= 60 then return end
    saveDB()
end)

AddEventHandler('onResourceStop', function(name)
    if name == cache.resource then
        saveDB()
    end
end)

---------------------------------------------------------------
-- ox_inventory hooks: stash <-> shop sync
---------------------------------------------------------------
if cfg.useInventory then
    exports.ox_inventory:registerHook('swapItems', function(payload)
        local toInventory = payload.toInventory
        local fromInventory = payload.fromInventory

        -- Item going INTO stash -> ask price + currency
        if type(toInventory) == 'string' and string.find(toInventory, 'vending_') then
            local shopName = string.gsub(toInventory, 'vending_', '')
            if Vending[shopName] then
                local src = payload.source
                local identifier = GetIdentifier(src)
                local job, grade = GetJob(src)
                local isOwner = false

                if type(Vending[shopName].owner) == 'string' then
                    if Vending[shopName].owner == identifier then isOwner = true end
                elseif type(Vending[shopName].owner) == 'table' then
                    if Vending[shopName].owner[job] and grade >= Vending[shopName].owner[job] then isOwner = true end
                end

                if not isOwner then
                    return false
                end

                CreateThread(function()
                    Wait(200)
                    TriggerClientEvent('uniq-vending:askPriceCurrency', src, {
                        shop = shopName,
                        item = payload.fromSlot.name,
                        itemLabel = payload.fromSlot.label,
                        count = payload.count,
                        slot = payload.toSlot,
                        metadata = payload.fromSlot.metadata
                    })
                end)
            end
        end

        -- Item taken OUT of stash -> sync stash to shop
        if type(fromInventory) == 'string' and string.find(fromInventory, 'vending_') then
            local shopName = string.gsub(fromInventory, 'vending_', '')
            if Vending[shopName] then
                CreateThread(function()
                    Wait(300)
                    SyncStashToShop(shopName)
                    RegisterVendingInventory(shopName)
                end)
            end
        end

        return true
    end, {})

    -- When customer buys from ox_inventory shop -> update shop table + stash
    exports.ox_inventory:registerHook('buyItem', function(payload)
        if type(payload.shopType) ~= 'string' or not string.find(payload.shopType, 'shop_vending_') then
            return true
        end

        local shopName = string.gsub(payload.shopType, 'shop_vending_', '')
        if not Vending[shopName] or not Vending[shopName].shop then return true end

        local itemName = payload.itemName
        local count = payload.count or 1
        local metadata = payload.metadata

        -- Normalize empty metadata (ox_inventory sends [] which decodes to empty table)
        if metadata and type(metadata) == 'table' and next(metadata) == nil then
            metadata = nil
        end

        if not itemName then return true end

        -- Find matching slot
        local matchedSlotId = nil
        for slotId, slotData in pairs(Vending[shopName].shop) do
            if slotData.itemName == itemName then
                local slotMeta = slotData.metadata
                if slotMeta and type(slotMeta) == 'table' and next(slotMeta) == nil then
                    slotMeta = nil
                end

                if metadata and slotMeta then
                    if json.encode(slotMeta) == json.encode(metadata) then
                        matchedSlotId = slotId
                        break
                    end
                else
                    matchedSlotId = slotId
                    break
                end
            end
        end

        if not matchedSlotId then return true end

        local slot = Vending[shopName].shop[matchedSlotId]
        slot.count -= count

        if not slot.currency or slot.currency == 'money' then
            Vending[shopName].balance += (slot.price * count)
        end

        if slot.count <= 0 then
            Vending[shopName].shop[matchedSlotId] = nil
        end

        CreateThread(function()
            Wait(200)
            SyncShopToStash(shopName)
            RegisterVendingInventory(shopName)
        end)

        return true
    end, {})
end

lib.versionCheck('uniqscripts/uniq-vending_standalone')
