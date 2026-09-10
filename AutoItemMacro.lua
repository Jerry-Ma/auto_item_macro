-- AutoItemMacro
-- A general-purpose consumable macro generator for WoW.
-- Users define named macro presets, each with a priority-ordered item list.
-- The addon generates valid WoW macros that automatically use the highest-priority
-- item currently in the player's bags.
--
-- This file is the data and macro layer: presets, macro body generation, the
-- game's macro CRUD, and the event/slash plumbing. It creates no frames and
-- knows nothing about the editor window. AutoItemMacro_UI.lua is the other half.
--
-- The two share the private namespace WoW passes to every file of an addon --
-- not a global, so nothing here can collide with another addon.

local ADDON_NAME, ns = ...

-- The .toc is the only place a version is written, and even there it is the
-- packager's project-version token, filled in from the git tag at release
-- time. Nothing to bump by hand.
--
-- Unpackaged checkouts still hold the raw token, which is what the "@" test
-- catches -- a released version never contains one. Note that the token is
-- matched by character and never spelled out anywhere in this file, comments
-- included: the packager substitutes inside .lua as well as .toc, so a literal
-- copy of it would come back as the version string and turn this check into
-- "if 1.0.0 then call it dev".
local ADDON_VERSION = C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")
if ADDON_VERSION:find("@", 1, true) then ADDON_VERSION = "dev" end

-- Cache frequently used globals
local _G               = _G
local CreateFrame      = _G.CreateFrame
local InCombatLockdown = _G.InCombatLockdown
local tinsert          = _G.table.insert
local tremove          = _G.table.remove
local tconcat          = _G.table.concat
local wipe             = _G.wipe
local C_Item           = _G.C_Item
local Item             = _G.Item

-- ── Constants ─────────────────────────────────────────────────────────────────

local MAX_MACRO_LENGTH   = 255
local MAX_MACRO_NAME_LEN = 16
local MACRO_NAME_PREFIX  = "aim_"  -- prefixes generated default names only
local MAX_GLOBAL_MACROS  = 120
local DEFAULT_ICON       = 134400  -- INV_Misc_QuestionMark

-- Extension omitted on purpose: the client appends it. This is the reduced
-- mark, not Media/Avatar.png -- everything in-game draws the logo at 14-20px,
-- where the avatar's frame and wordmark turn to mush.
local LOGO_TEXTURE = "Interface\\AddOns\\AutoItemMacro\\Media\\Logo"
-- The logo inline in a chat line, sized to sit on the text baseline.
local LOGO_INLINE  = "|T" .. LOGO_TEXTURE .. ":14:14:0:0|t "
local CHAT_PREFIX  = LOGO_INLINE .. "|cffffff00AutoItemMacro:|r "

-- Modifier key cycle for each item entry.
-- "default" = no conditional (plain /use), others map to [mod:X] in the macro.
local MOD_CYCLE = { "default", "alt", "ctrl", "shift", "nomod" }

local MOD_LABEL = {
    default = "---",
    alt     = "ALT",
    ctrl    = "CTL",
    shift   = "SHF",
    nomod   = "NOM",
}

-- Hex color codes used in SetText escape sequences
local MOD_COLOR_HEX = {
    default = "888888",
    alt     = "ff9910",
    ctrl    = "22ddff",
    shift   = "44ff66",
    nomod   = "ffee22",
}

ns.ADDON_VERSION      = ADDON_VERSION
ns.MAX_MACRO_NAME_LEN = MAX_MACRO_NAME_LEN
ns.DEFAULT_ICON       = DEFAULT_ICON
ns.LOGO_TEXTURE       = LOGO_TEXTURE
ns.MOD_LABEL          = MOD_LABEL
ns.MOD_COLOR_HEX      = MOD_COLOR_HEX

-- ── Runtime state ─────────────────────────────────────────────────────────────

local db                     = nil   -- reference to AutoItemMacroDB
local needsUpdateAfterCombat = false
local updatePending          = false

-- Hooks the UI file fills in. Core calls these when a GAME EVENT changes state
-- behind the user's back; anything the user did through the UI is refreshed by
-- the UI itself, so it does not need a hook. Core never reaches into the UI
-- directly, which is what lets this file stand on its own.
ns.OnMacrosUpdated  = nil  -- bags changed and the macros were rebuilt
ns.OnItemDataLoaded = nil  -- (itemID) item name/icon finished loading
ns.OnCombatStart    = nil
ns.OnLogin          = nil

-- ── Output ────────────────────────────────────────────────────────────────────

function ns.Print(msg)
    _G.print(CHAT_PREFIX .. msg)
end

function ns.PrintRaw(msg)
    _G.print(msg)
end

-- Red text in the middle of the screen, for things the user just tried to do
-- and cannot -- which is almost always "not in combat".
function ns.Error(msg)
    _G.UIErrorsFrame:AddMessage("|cffFF4444AutoItemMacro:|r " .. msg, 1, 0.27, 0.27, 1)
end

-- ── Items ─────────────────────────────────────────────────────────────────────

-- Bags and equipped only: no bank, no reagent bank. A macro cannot use an item
-- that is not on the player.
function ns.ItemCount(itemID)
    if not itemID then return 0 end
    return C_Item.GetItemCount(itemID, false, false, false)
end
local ItemCount = ns.ItemCount

-- ── Macro generation ──────────────────────────────────────────────────────────

-- Scratch buffers, reused across calls. GetMacroBody runs once per preset on
-- every bag update and again on every UI refresh, so allocating three tables per
-- call was pure churn for the garbage collector.
local useScratch  = {}
local lineScratch = {}

-- Builds a valid WoW macro body for a preset.
--
-- Strategy: stack one /use line per item that is currently in bags, in priority
-- order. WoW executes the first /use that is valid and ignores the rest, so
-- shared-cooldown consumables (potions, healthstones, ...) resolve correctly,
-- while single-use items like flasks or food just fire the first one found.
--
-- Returns the macro string, which may be empty if the preset has no items.
function ns.GetMacroBody(preset)
    local items = preset and preset.items
    if not items or #items == 0 then return "" end

    wipe(useScratch)

    -- The tooltip anchor is the highest-priority item actually in bags, so the
    -- action button shows what would fire right now.
    local tooltipID
    for i = 1, #items do
        local item = items[i]
        if ItemCount(item.id) > 0 then
            if not tooltipID then tooltipID = item.id end
            local mod = item.mod
            if mod and mod ~= "default" then
                useScratch[#useScratch + 1] = "/use [mod:" .. mod .. "] item:" .. item.id
            else
                useScratch[#useScratch + 1] = "/use item:" .. item.id
            end
        end
    end

    -- Nothing in bags: keep the first item as a placeholder so the button still
    -- shows an icon rather than a blank slot.
    if not tooltipID then tooltipID = items[1].id end
    if not tooltipID then return "" end

    wipe(lineScratch)
    lineScratch[1] = "#showtooltip item:" .. tooltipID
    local total = #lineScratch[1]

    -- Trim to WoW's 255-character macro limit, dropping whole lines from the
    -- bottom: a truncated /use line would be a syntax error.
    for i = 1, #useScratch do
        local line   = useScratch[i]
        local needed = #line + 1  -- +1 for the newline
        if total + needed > MAX_MACRO_LENGTH then break end
        lineScratch[#lineScratch + 1] = line
        total = total + needed
    end

    return tconcat(lineScratch, "\n")
end
local GetMacroBody = ns.GetMacroBody

-- ── WoW macro CRUD ────────────────────────────────────────────────────────────

-- The last body written for each preset, so an unchanged macro is not rewritten.
--
-- EditMacro is not free: it rewrites the macro and invalidates every action
-- button holding it. BAG_UPDATE_DELAYED fires continuously while looting or
-- vendoring, and the overwhelming majority of those updates do not change
-- whether a given consumable is in your bags -- so without this, most of that
-- work produced a byte-identical string.
--
-- Keyed by the preset table rather than its name so a rename does not orphan
-- the entry, and weak so a deleted preset's entry goes with it.
local lastBody = setmetatable({}, { __mode = "k" })

-- Forces the next update to write every macro even if the body matches. Used
-- wherever the user has explicitly asked for a rebuild, which is also the
-- escape hatch if they hand-edited one of our macros in Blizzard's macro UI and
-- want it put back.
function ns.InvalidateMacroCache()
    wipe(lastBody)
end

function ns.UpdateMacro(preset)
    if InCombatLockdown() then
        needsUpdateAfterCombat = true
        return
    end
    if not preset or not preset.name or preset.name == "" then return end

    local body = GetMacroBody(preset)
    local idx  = _G.GetMacroIndexByName(preset.name)

    if idx == 0 then
        if _G.GetNumMacros() >= MAX_GLOBAL_MACROS then
            ns.Error("Global macro limit reached (" .. MAX_GLOBAL_MACROS ..
                     "). Delete unused macros to create new ones.")
            return
        end
        _G.CreateMacro(preset.name, DEFAULT_ICON, body, false)
    elseif lastBody[preset] ~= body then
        _G.EditMacro(idx, preset.name, nil, body)
    else
        return  -- identical to what is already in the slot
    end

    lastBody[preset] = body
end
local UpdateMacro = ns.UpdateMacro

function ns.UpdateAllMacros()
    if not db then return end
    for i = 1, #db.presets do
        UpdateMacro(db.presets[i])
    end
end
local UpdateAllMacros = ns.UpdateAllMacros

local function DeleteWoWMacro(name)
    if not name or name == "" then return end
    local idx = _G.GetMacroIndexByName(name)
    if idx ~= 0 then _G.DeleteMacro(idx) end
end

-- ── Presets ───────────────────────────────────────────────────────────────────
--
-- Everything below operates on the saved data and nothing else. Selection is
-- the UI's business, so these take an explicit preset or index and return what
-- happened; the caller decides what to re-render.

function ns.GetDB()
    return db
end

function ns.GetPreset(index)
    return db and index and db.presets[index]
end

function ns.NumPresets()
    return db and #db.presets or 0
end

-- Generated names carry MACRO_NAME_PREFIX so the macros this addon creates are
-- recognisable in the game's macro list. Names the user types are left alone.
local function GenerateUniqueName()
    local i = 1
    while true do
        local candidate = MACRO_NAME_PREFIX .. ("macro%d"):format(i)
        if #candidate > MAX_MACRO_NAME_LEN then
            candidate = candidate:sub(1, MAX_MACRO_NAME_LEN)
        end
        local taken = false
        for _, p in ipairs(db.presets) do
            if p.name == candidate then taken = true; break end
        end
        if not taken then return candidate end
        i = i + 1
    end
end

-- Returns the new preset and its index, or nil in combat.
function ns.AddPreset()
    if InCombatLockdown() then return nil end
    local preset = { name = GenerateUniqueName(), items = {} }
    tinsert(db.presets, preset)
    UpdateMacro(preset)
    return preset, #db.presets
end

-- Returns true if a preset was removed.
function ns.DeletePreset(index)
    if InCombatLockdown() then return false end
    local preset = db.presets[index]
    if not preset then return false end
    DeleteWoWMacro(preset.name)
    tremove(db.presets, index)
    return true
end

-- Returns true on success, false if the new name is empty or already taken.
function ns.RenamePreset(index, newName)
    if InCombatLockdown() then return false end
    local preset = db.presets[index]
    if not preset then return false end

    newName = strtrim(newName):sub(1, MAX_MACRO_NAME_LEN)
    if newName == "" then return false end
    for i, p in ipairs(db.presets) do
        if i ~= index and p.name == newName then return false end
    end

    local oldName = preset.name
    preset.name = newName

    -- EditMacro with a nil body keeps the existing one.
    local macroIdx = _G.GetMacroIndexByName(oldName)
    if macroIdx ~= 0 then
        _G.EditMacro(macroIdx, newName, nil, nil)
    else
        UpdateMacro(preset)
    end
    return true
end

-- Item data may not be loaded yet, so this completes asynchronously. onAdded is
-- called only if an item was actually appended -- not for a duplicate.
function ns.AddItemToPreset(preset, itemID, onAdded)
    if InCombatLockdown() or not preset then return end

    local itemObj = Item:CreateFromItemID(itemID)
    itemObj:ContinueOnItemLoad(function()
        local id = itemObj:GetItemID()
        if not id then return end
        for _, existing in ipairs(preset.items) do
            if existing.id == id then return end
        end
        tinsert(preset.items, { id = id })
        UpdateMacro(preset)
        if onAdded then onAdded() end
    end)
end

function ns.RemoveItem(preset, itemIndex)
    if InCombatLockdown() or not preset or not preset.items[itemIndex] then return false end
    tremove(preset.items, itemIndex)
    UpdateMacro(preset)
    return true
end

-- delta is -1 to raise priority, +1 to lower it. Returns the new index, or nil
-- if the item is already at that end of the list.
function ns.MoveItem(preset, itemIndex, delta)
    if InCombatLockdown() or not preset then return nil end
    local items  = preset.items
    local target = itemIndex + delta
    if not items[itemIndex] or target < 1 or target > #items then return nil end
    local item = tremove(items, itemIndex)
    tinsert(items, target, item)
    UpdateMacro(preset)
    return target
end

-- Advances an item to the next modifier in MOD_CYCLE. "default" is stored as
-- nil so an untouched item costs nothing in saved variables.
function ns.CycleItemMod(preset, itemIndex)
    if InCombatLockdown() or not preset then return false end
    local item = preset.items[itemIndex]
    if not item then return false end

    local current = item.mod or "default"
    local nextMod = "default"
    for i, v in ipairs(MOD_CYCLE) do
        if v == current then
            nextMod = MOD_CYCLE[(i % #MOD_CYCLE) + 1]
            break
        end
    end
    item.mod = (nextMod ~= "default") and nextMod or nil
    UpdateMacro(preset)
    return true
end

-- ── Events ────────────────────────────────────────────────────────────────────

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("BAG_UPDATE_DELAYED")
eventFrame:RegisterEvent("ITEM_DATA_LOAD_RESULT")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

eventFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        AutoItemMacroDB              = AutoItemMacroDB or {}
        AutoItemMacroDB.presets      = AutoItemMacroDB.presets or {}
        AutoItemMacroDB.autoUpdate   = (AutoItemMacroDB.autoUpdate ~= false)
        AutoItemMacroDB.minimap      = (AutoItemMacroDB.minimap ~= false)
        AutoItemMacroDB.minimapAngle = AutoItemMacroDB.minimapAngle or 200
        db = AutoItemMacroDB
        ns.BuildUI()

    elseif event == "PLAYER_LOGIN" then
        -- Bags may have changed while logged out, and a macro may have been
        -- hand-edited, so the first pass writes unconditionally.
        ns.InvalidateMacroCache()
        UpdateAllMacros()
        if ns.OnLogin then ns.OnLogin() end
        eventFrame:UnregisterEvent("PLAYER_LOGIN")

    elseif event == "PLAYER_REGEN_DISABLED" then
        if ns.OnCombatStart then ns.OnCombatStart() end

    elseif event == "PLAYER_REGEN_ENABLED" then
        if needsUpdateAfterCombat then
            needsUpdateAfterCombat = false
            UpdateAllMacros()
            if ns.OnMacrosUpdated then ns.OnMacrosUpdated() end
        end

    elseif event == "BAG_UPDATE_DELAYED" then
        if not db or not db.autoUpdate then return end
        if InCombatLockdown() then
            needsUpdateAfterCombat = true
        elseif not updatePending then
            -- Debounced: a single loot or vendor action can fire this event
            -- many times in a row.
            updatePending = true
            _G.C_Timer.After(1.0, function()
                updatePending = false
                UpdateAllMacros()
                if ns.OnMacrosUpdated then ns.OnMacrosUpdated() end
            end)
        end

    elseif event == "ITEM_DATA_LOAD_RESULT" then
        -- Fires for every item the client resolves, most of which have nothing
        -- to do with this addon, so the id is passed along and the UI decides
        -- whether it is showing that item at all.
        if ns.OnItemDataLoaded then ns.OnItemDataLoaded(arg1) end
    end
end)

-- ── Slash commands ────────────────────────────────────────────────────────────

_G.SLASH_AUTOITEMMACRO1 = "/aim"
_G.SLASH_AUTOITEMMACRO2 = "/autoitemmacro"
_G.SlashCmdList["AUTOITEMMACRO"] = function(msg)
    msg = strtrim((msg or ""):lower())

    if msg == "update" then
        if InCombatLockdown() then
            ns.Error("Cannot update macros during combat.")
            return
        end
        ns.InvalidateMacroCache()
        UpdateAllMacros()
        ns.Print("All macros updated.")

    elseif msg == "help" then
        ns.PrintRaw(LOGO_INLINE .. "|cffffff00AutoItemMacro|r commands:")
        ns.PrintRaw("  |cffffd700/aim|r           — open / close the options window")
        ns.PrintRaw("  |cffffd700/aim update|r     — force-update all macro presets")
        ns.PrintRaw("  |cffffd700/aim help|r       — show this help text")

    elseif msg == "" then
        ns.ToggleUI()

    else
        ns.Print("Unknown command. Type |cffffd700/aim help|r for a list.")
    end
end
