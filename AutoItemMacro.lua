-- AutoItemMacro
-- A general-purpose consumable macro generator for WoW.
-- Users define named macro presets, each with a priority-ordered item list.
-- The addon generates valid WoW macros that automatically use the highest-priority
-- item currently in the player's bags.

local ADDON_NAME = "AutoItemMacro"

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
local UIParent         = _G.UIParent
local GameTooltip      = _G.GameTooltip
local InCombatLockdown = _G.InCombatLockdown
local GetCursorInfo    = _G.GetCursorInfo
local ClearCursor      = _G.ClearCursor
local tinsert          = _G.table.insert
local tremove          = _G.table.remove
local C_Item           = _G.C_Item
local Item             = _G.Item

-- ── Constants ─────────────────────────────────────────────────────────────────

local MAX_MACRO_LENGTH     = 255
local MAX_MACRO_NAME_LEN   = 16
local MACRO_NAME_PREFIX    = "aim_"  -- prefixes generated default names only
local DEFAULT_ICON         = 134400  -- INV_Misc_QuestionMark
-- Extension omitted on purpose: the client appends it. This is the reduced
-- mark, not Media/Avatar.png -- everything in-game draws the logo at 14-20px,
-- where the avatar's frame and wordmark turn to mush.
local LOGO_TEXTURE         = "Interface\\AddOns\\AutoItemMacro\\Media\\Logo"
-- The logo inline in a chat line, sized to sit on the text baseline.
local LOGO_INLINE          = "|T" .. LOGO_TEXTURE .. ":14:14:0:0|t "
local CHAT_PREFIX          = LOGO_INLINE .. "|cffffff00AutoItemMacro:|r "
local PRESET_ROW_HEIGHT    = 30
local ITEM_ROW_HEIGHT      = 35

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

-- ── Runtime state ─────────────────────────────────────────────────────────────

local db                   = nil   -- reference to AutoItemMacroDB
local mainFrame            = nil
local minimapButton        = nil
local selectedPresetIndex  = nil   -- 1-based index into db.presets
local presetRowPool        = {}    -- reusable Frame objects for preset list
local itemRowPool          = {}    -- reusable Frame objects for item list
local needsUpdateAfterCombat = false
local updatePending          = false

-- Forward declarations (mutual references between local functions)
local RefreshPresetList, RefreshItemList, BuildUI

-- ── Macro generation ──────────────────────────────────────────────────────────

local function IsInBags(itemID)
    return itemID and C_Item.GetItemCount(itemID, false, false, false) > 0
end

-- Builds a valid WoW macro body for a preset.
-- Strategy: stack one /use line per item that is currently in bags, in priority
-- order.  WoW executes the first /use that is off cooldown and ignores the
-- rest, so shared-cooldown consumables (potions, healthstones …) work
-- correctly.  For flasks / food only the first available item ever fires, which
-- is the intended behaviour.
--
-- Returns the macro string (may be empty if the preset has no items).
local function GetMacroBody(preset)
    if not preset or not preset.items or #preset.items == 0 then return "" end

    local firstTooltip = nil
    local useLines     = {}

    for _, item in ipairs(preset.items) do
        if IsInBags(item.id) then
            if not firstTooltip then firstTooltip = item.id end
            local mod = item.mod
            if mod and mod ~= "default" then
                tinsert(useLines, "/use [mod:" .. mod .. "] item:" .. item.id)
            else
                tinsert(useLines, "/use item:" .. item.id)
            end
        end
    end

    -- If nothing is in bags, show the first item as a placeholder tooltip
    if not firstTooltip and #preset.items > 0 then
        firstTooltip = preset.items[1].id
    end

    if not firstTooltip then return "" end

    local lines = { "#showtooltip item:" .. firstTooltip }
    for _, line in ipairs(useLines) do
        tinsert(lines, line)
    end

    -- Trim to WoW's 255-character macro limit
    local result     = {}
    local totalLen   = 0
    for _, line in ipairs(lines) do
        local needed = #line + (totalLen > 0 and 1 or 0)  -- +1 for newline
        if totalLen + needed > MAX_MACRO_LENGTH then break end
        tinsert(result, line)
        totalLen = totalLen + needed
    end

    return table.concat(result, "\n")
end

-- ── WoW macro CRUD ────────────────────────────────────────────────────────────

local function UpdateMacro(preset)
    if InCombatLockdown() then
        needsUpdateAfterCombat = true
        return
    end
    if not preset or not preset.name or preset.name == "" then return end

    local body = GetMacroBody(preset)
    local idx  = _G.GetMacroIndexByName(preset.name)

    if idx == 0 then
        -- Macro does not exist yet — create it (global slot, limit 120)
        local numGlobal = _G.GetNumMacros()
        if numGlobal < 120 then
            _G.CreateMacro(preset.name, DEFAULT_ICON, body, false)
        else
            _G.UIErrorsFrame:AddMessage(
                "|cffFF4444AutoItemMacro:|r Global macro limit reached (120). Delete unused macros to create new ones.",
                1, 0.27, 0.27, 1)
        end
    else
        _G.EditMacro(idx, preset.name, nil, body)
    end
end

local function UpdateAllMacros()
    if not db then return end
    for _, preset in ipairs(db.presets) do
        UpdateMacro(preset)
    end
end

local function DeleteWoWMacro(name)
    if not name or name == "" then return end
    local idx = _G.GetMacroIndexByName(name)
    if idx ~= 0 then _G.DeleteMacro(idx) end
end

-- ── Preset management ─────────────────────────────────────────────────────────

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

local function AddPreset()
    if InCombatLockdown() then return end
    local name = GenerateUniqueName()
    tinsert(db.presets, { name = name, items = {} })
    selectedPresetIndex = #db.presets
    RefreshPresetList()
    RefreshItemList()
    UpdateMacro(db.presets[selectedPresetIndex])
    -- Auto-focus the rename box so the user can immediately type a name
    if mainFrame and mainFrame.renameBox then
        mainFrame.renameBox:SetFocus()
        mainFrame.renameBox:HighlightText()
    end
end

local function DeletePreset(index)
    if InCombatLockdown() then return end
    if not db.presets[index] then return end
    DeleteWoWMacro(db.presets[index].name)
    tremove(db.presets, index)
    -- Adjust selection
    if selectedPresetIndex then
        if selectedPresetIndex == index then
            selectedPresetIndex = #db.presets > 0 and math.min(index, #db.presets) or nil
        elseif selectedPresetIndex > index then
            selectedPresetIndex = selectedPresetIndex - 1
        end
    end
    RefreshPresetList()
    RefreshItemList()
end

-- Returns true on success, false if the new name is already taken.
local function RenamePreset(index, newName)
    if InCombatLockdown() then return false end
    if not db.presets[index] then return false end
    newName = strtrim(newName):sub(1, MAX_MACRO_NAME_LEN)
    if newName == "" then return false end
    -- Check uniqueness
    for i, p in ipairs(db.presets) do
        if i ~= index and p.name == newName then return false end
    end
    local oldName = db.presets[index].name
    db.presets[index].name = newName
    -- Rename the in-game macro (EditMacro with nil body keeps existing body)
    local macroIdx = _G.GetMacroIndexByName(oldName)
    if macroIdx ~= 0 then
        _G.EditMacro(macroIdx, newName, nil, nil)
    else
        -- No existing macro — create it fresh
        UpdateMacro(db.presets[index])
    end
    return true
end

local function AddItemToPreset(itemID)
    if InCombatLockdown() or not selectedPresetIndex then return end
    local preset = db.presets[selectedPresetIndex]
    if not preset then return end
    -- Load item data asynchronously, then insert
    local itemObj = Item:CreateFromItemID(itemID)
    itemObj:ContinueOnItemLoad(function()
        local id = itemObj:GetItemID()
        if not id then return end
        for _, existing in ipairs(preset.items) do
            if existing.id == id then return end  -- already in list
        end
        tinsert(preset.items, { id = id })
        if mainFrame and mainFrame:IsShown() then RefreshItemList() end
        UpdateMacro(preset)
    end)
end

-- ── UI — Preset list (left panel) ─────────────────────────────────────────────

RefreshPresetList = function()
    if not mainFrame then return end
    -- Hide all pooled rows
    for _, row in ipairs(presetRowPool) do row:Hide() end
    if not db then return end

    for i, preset in ipairs(db.presets) do
        local row = presetRowPool[i]
        if not row then
            row = CreateFrame("Button", nil, mainFrame.presetContent)
            row:SetSize(172, PRESET_ROW_HEIGHT - 2)
            row:SetPoint("TOPLEFT", 2, -(i - 1) * PRESET_ROW_HEIGHT)

            row.bg = row:CreateTexture(nil, "BACKGROUND")
            row.bg:SetAllPoints()

            row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.label:SetPoint("LEFT", 6, 0)
            row.label:SetPoint("RIGHT", row, "RIGHT", -28, 0)
            row.label:SetJustifyH("LEFT")
            row.label:SetWordWrap(false)

            row.delBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            row.delBtn:SetSize(22, 18)
            row.delBtn:SetText("X")
            row.delBtn:SetPoint("RIGHT", -2, 0)
            row.delBtn:SetScript("OnClick", function()
                if row.presetIndex then DeletePreset(row.presetIndex) end
            end)

            row:SetScript("OnClick", function()
                selectedPresetIndex = row.presetIndex
                RefreshPresetList()
                RefreshItemList()
            end)

            presetRowPool[i] = row
        end

        row.presetIndex = i
        row.label:SetText(preset.name)

        local isSelected = (selectedPresetIndex == i)
        if isSelected then
            row.bg:SetColorTexture(0.25, 0.45, 0.75, 0.55)
            row.label:SetTextColor(1, 1, 1)
        else
            row.bg:SetColorTexture(0.18, 0.18, 0.18, 0.50)
            row.label:SetTextColor(0.75, 0.75, 0.75)
        end

        row:Show()
    end

    mainFrame.presetContent:SetHeight(math.max(1, #db.presets * PRESET_ROW_HEIGHT))
end

-- ── UI — Item list (right panel) ──────────────────────────────────────────────

RefreshItemList = function()
    if not mainFrame then return end
    for _, row in ipairs(itemRowPool) do row:Hide() end

    -- Update rename box
    local preset = selectedPresetIndex and db and db.presets[selectedPresetIndex]
    if preset then
        mainFrame.renameBox:SetText(preset.name)
        mainFrame.renameBox:Enable()
        mainFrame.addItemBox:Enable()
        mainFrame.addItemBtn:Enable()
    else
        mainFrame.renameBox:SetText("")
        mainFrame.renameBox:Disable()
        mainFrame.addItemBox:Disable()
        mainFrame.addItemBtn:Disable()
        mainFrame.previewText:SetText("|cff555555Select or create a macro preset on the left.|r")
        return
    end

    local items = preset.items

    for i, item in ipairs(items) do
        local row = itemRowPool[i]
        if not row then
            row = CreateFrame("Frame", nil, mainFrame.itemContent)
            row:SetSize(418, ITEM_ROW_HEIGHT - 3)
            row:SetPoint("TOPLEFT", 2, -(i - 1) * ITEM_ROW_HEIGHT)

            row.bg = row:CreateTexture(nil, "BACKGROUND")
            row.bg:SetAllPoints()
            row.bg:SetColorTexture(0.14, 0.14, 0.14, 0.55)

            -- Priority badge (1, 2, 3 …)
            row.badge = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.badge:SetPoint("LEFT", 4, 0)
            row.badge:SetWidth(18)
            row.badge:SetJustifyH("RIGHT")
            row.badge:SetTextColor(0.5, 0.5, 0.5)

            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetSize(24, 24)
            row.icon:SetPoint("LEFT", row.badge, "RIGHT", 4, 0)
            row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

            row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
            row.text:SetPoint("RIGHT", row, "RIGHT", -168, 0)
            row.text:SetJustifyH("LEFT")
            row.text:SetWordWrap(false)

            row.status = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.status:SetPoint("RIGHT", row, "RIGHT", -120, 0)
            row.status:SetWidth(46)
            row.status:SetJustifyH("CENTER")

            -- Buttons: Delete / Down / Up / Modifier
            row.delBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            row.delBtn:SetSize(22, 18)
            row.delBtn:SetText("X")
            row.delBtn:SetPoint("RIGHT", -2, 0)
            row.delBtn.action = "delete"

            row.downBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            row.downBtn:SetSize(24, 18)
            row.downBtn:SetText("v")
            row.downBtn:SetPoint("RIGHT", row.delBtn, "LEFT", -2, 0)
            row.downBtn.action = "down"

            row.upBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            row.upBtn:SetSize(24, 18)
            row.upBtn:SetText("^")
            row.upBtn:SetPoint("RIGHT", row.downBtn, "LEFT", -2, 0)
            row.upBtn.action = "up"

            -- Modifier button: cycles default → alt → ctrl → shift → nomod → default
            row.modBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            row.modBtn:SetSize(38, 18)
            row.modBtn:SetPoint("RIGHT", row.upBtn, "LEFT", -2, 0)
            row.modBtn:SetScript("OnClick", function()
                if InCombatLockdown() then return end
                local r        = row.modBtn:GetParent()
                local itemIdx  = r.itemIndex
                local presetIdx = r.presetIndex
                if not itemIdx or not presetIdx then return end
                local p  = db and db.presets[presetIdx]
                if not p then return end
                local it = p.items[itemIdx]
                local current = it.mod or "default"
                local nextMod = "default"
                for ci, v in ipairs(MOD_CYCLE) do
                    if v == current then
                        nextMod = MOD_CYCLE[(ci % #MOD_CYCLE) + 1]
                        break
                    end
                end
                it.mod = (nextMod == "default") and nil or nextMod
                RefreshItemList()
                UpdateMacro(p)
            end)
            row.modBtn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText("Modifier key\nClick to cycle:\n|cff888888---|r No modifier\n|cffff9910ALT|r  [mod:alt]\n|cff22ddffCTL|r  [mod:ctrl]\n|cff44ff66SHF|r  [mod:shift]\n|cffffee22NOM|r  [mod:nomod]", nil, nil, nil, nil, true)
                GameTooltip:Show()
            end)
            row.modBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

            local function OnItemBtnClick(btn)
                if InCombatLockdown() then return end
                local r          = btn:GetParent()
                local itemIdx    = r.itemIndex
                local presetIdx  = r.presetIndex
                if not itemIdx or not presetIdx then return end
                local p  = db and db.presets[presetIdx]
                if not p then return end
                local it = p.items[itemIdx]

                if btn.action == "delete" then
                    tremove(p.items, itemIdx)
                elseif btn.action == "up" and itemIdx > 1 then
                    tremove(p.items, itemIdx)
                    tinsert(p.items, itemIdx - 1, it)
                elseif btn.action == "down" and itemIdx < #p.items then
                    tremove(p.items, itemIdx)
                    tinsert(p.items, itemIdx + 1, it)
                else
                    return
                end
                RefreshItemList()
                UpdateMacro(p)
            end

            row.delBtn:SetScript("OnClick",  function(s) OnItemBtnClick(s) end)
            row.downBtn:SetScript("OnClick", function(s) OnItemBtnClick(s) end)
            row.upBtn:SetScript("OnClick",   function(s) OnItemBtnClick(s) end)

            row:SetScript("OnEnter", function(s)
                if s.itemID then
                    GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
                    GameTooltip:SetItemByID(s.itemID)
                    GameTooltip:Show()
                end
            end)
            row:SetScript("OnLeave", function() GameTooltip:Hide() end)

            itemRowPool[i] = row
        end

        row.itemIndex   = i
        row.presetIndex = selectedPresetIndex
        row.itemID      = item.id
        row:Show()

        row.badge:SetText(i)

        local itemName = C_Item.GetItemNameByID(item.id)
        if not itemName then
            C_Item.RequestLoadItemDataByID(item.id)
            itemName = "Loading… (" .. item.id .. ")"
        end
        local itemIcon = C_Item.GetItemIconByID(item.id) or DEFAULT_ICON
        row.icon:SetTexture(itemIcon)

        local inBags = IsInBags(item.id)
        local count  = inBags and C_Item.GetItemCount(item.id, false, false, false) or 0
        row.text:SetText(itemName .. "  |cff666666[" .. item.id .. "]|r")
        row.text:SetTextColor(inBags and 1 or 0.45, inBags and 1 or 0.45, inBags and 1 or 0.45)

        if inBags then
            row.status:SetText("|cff44ff44x" .. count .. "|r")
        else
            row.status:SetText("|cffff4444 ✗|r")
        end

        -- Modifier button label + color
        local mod      = item.mod or "default"
        local modLabel = MOD_LABEL[mod] or "---"
        local modHex   = MOD_COLOR_HEX[mod] or "888888"
        row.modBtn:SetText("|cff" .. modHex .. modLabel .. "|r")
    end

    mainFrame.itemContent:SetHeight(math.max(1, #items * ITEM_ROW_HEIGHT))

    -- Update macro body preview
    local body = GetMacroBody(preset)
    if body ~= "" then
        mainFrame.previewText:SetText("|cffaaaaaa" .. body .. "|r")
    else
        mainFrame.previewText:SetText("|cff555555(no items in bags — macro will be empty)|r")
    end
end

-- ── Opening the editor ────────────────────────────────────────────────────────

-- Shared by the slash command, the minimap button and the addon compartment.
-- Macros cannot be edited in combat, so all three refuse the same way.
local function ToggleUI()
    if InCombatLockdown() then
        _G.UIErrorsFrame:AddMessage("|cffFF4444AutoItemMacro:|r Cannot open UI during combat.", 1, 0.27, 0.27, 1)
        return
    end
    if not mainFrame then return end
    if mainFrame:IsShown() then mainFrame:Hide() else mainFrame:Show() end
end

-- Blizzard calls this by name from the addon compartment next to the minimap,
-- so it has to be a global. ## AddonCompartmentFunc in the .toc names it.
function _G.AutoItemMacro_OnCompartmentClick()
    ToggleUI()
end

-- ── Minimap button ────────────────────────────────────────────────────────────
-- Hand-rolled rather than LibDBIcon. This addon ships as a single file with no
-- libraries, and pulling in LibStub + CallbackHandler + LDB + LibDBIcon to place
-- one button would be most of the addon's weight. Borrowing another addon's copy
-- instead would make our button appear and vanish with THEIR install.

-- Gap between the minimap edge and the button's centre. LibDBIcon's own default,
-- which is what puts this button on the same ring as every other addon's.
local EDGE_GAP = 5

-- Which quadrants of a given minimap shape are round. A square minimap needs the
-- button pushed out to the diagonal instead of the circle, or it lands inside the
-- map at the corners. GetMinimapShape is a convention that addons reshaping the
-- minimap define; absent, it is round.
local MINIMAP_SHAPES = {
    ROUND = { true, true, true, true },
    SQUARE = { false, false, false, false },
    ["CORNER-TOPLEFT"] = { false, false, false, true },
    ["CORNER-TOPRIGHT"] = { false, false, true, false },
    ["CORNER-BOTTOMLEFT"] = { false, true, false, false },
    ["CORNER-BOTTOMRIGHT"] = { true, false, false, false },
    ["SIDE-LEFT"] = { false, true, false, true },
    ["SIDE-RIGHT"] = { true, false, true, false },
    ["SIDE-TOP"] = { false, false, true, true },
    ["SIDE-BOTTOM"] = { true, true, false, false },
    ["TRICORNER-TOPLEFT"] = { false, true, true, true },
    ["TRICORNER-TOPRIGHT"] = { true, false, true, true },
    ["TRICORNER-BOTTOMLEFT"] = { true, true, false, true },
    ["TRICORNER-BOTTOMRIGHT"] = { true, true, true, false },
}

-- The radius comes from the minimap's ACTUAL size rather than a fixed 80px:
-- most minimap addons resize it. Width and height are read separately so a
-- non-square minimap still works.
local function PositionMinimapButton()
    if not minimapButton or not _G.Minimap then return end
    local Minimap = _G.Minimap

    local angle = math.rad(db and db.minimapAngle or 200)
    local x, y = math.cos(angle), math.sin(angle)

    -- Quadrant, in LibDBIcon's numbering: 1 = +x+y, 2 = -x+y, 3 = +x-y, 4 = -x-y.
    local q = 1
    if x < 0 then q = q + 1 end
    if y > 0 then q = q + 2 end

    local shape = (_G.GetMinimapShape and _G.GetMinimapShape()) or "ROUND"
    local quad = MINIMAP_SHAPES[shape] or MINIMAP_SHAPES.ROUND

    local w = (Minimap:GetWidth() / 2) + EDGE_GAP
    local h = (Minimap:GetHeight() / 2) + EDGE_GAP

    if quad[q] then
        x, y = x * w, y * h
    else
        -- Square corner: project onto the diagonal, then clamp to the edges.
        local dw = math.sqrt(2 * w * w) - 10
        local dh = math.sqrt(2 * h * h) - 10
        x = math.max(-w, math.min(x * dw, w))
        y = math.max(-h, math.min(y * dh, h))
    end

    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function BuildMinimapButton()
    if minimapButton then return minimapButton end
    if not _G.Minimap then return nil end

    -- Geometry taken from LibDBIcon's retail button so this sits on the ring at
    -- the same size as everyone else's. The numbers are not arbitrary: the 50x50
    -- tracking border anchored TOPLEFT of a 31x31 button is what centres its ring.
    local b = CreateFrame("Button", "AutoItemMacroMinimapButton", _G.Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("AnyUp")
    b:RegisterForDrag("LeftButton")
    b:SetHighlightTexture(136477)  -- UI-Minimap-ZoomButton-Highlight

    local background = b:CreateTexture(nil, "BACKGROUND")
    background:SetSize(24, 24)
    background:SetTexture(136467)  -- UI-Minimap-Background
    background:SetPoint("CENTER")

    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(LOGO_TEXTURE)
    icon:SetSize(18, 18)
    icon:SetPoint("CENTER")
    -- Round mask, so this reads as a minimap button rather than a sticker on one.
    local mask = b:CreateMaskTexture()
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask",
        "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(icon)
    icon:AddMaskTexture(mask)

    local ring = b:CreateTexture(nil, "OVERLAY")
    ring:SetTexture(136430)        -- MiniMap-TrackingBorder
    ring:SetSize(50, 50)
    ring:SetPoint("TOPLEFT")

    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("AutoItemMacro", 1, 0.82, 0)
        GameTooltip:AddLine("Click to open the macro editor", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Drag to move around the minimap", 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:SetScript("OnClick", ToggleUI)

    -- Dragging follows the cursor's angle around the minimap centre rather than
    -- moving the frame freely, so the button cannot be dropped off the ring.
    -- OnUpdate is set only while a drag is in progress and cleared on release,
    -- so it costs nothing at rest.
    local function DragUpdate()
        local mx, my = _G.Minimap:GetCenter()
        local cx, cy = _G.GetCursorPosition()
        local scale = _G.Minimap:GetEffectiveScale()
        cx, cy = cx / scale, cy / scale
        if db then db.minimapAngle = math.deg(math.atan2(cy - my, cx - mx)) end
        PositionMinimapButton()
    end
    b:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", DragUpdate) end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

    minimapButton = b
    PositionMinimapButton()
    return b
end

local function ApplyMinimapButton()
    if db and db.minimap == false then
        if minimapButton then minimapButton:Hide() end
        return
    end
    if BuildMinimapButton() then
        PositionMinimapButton()
        minimapButton:Show()
    end
end

-- ── UI — Build ────────────────────────────────────────────────────────────────

BuildUI = function()
    if mainFrame then return end

    -- ── Main frame ────────────────────────────────────────────────────────────
    local f = CreateFrame("Frame", "AutoItemMacroFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(680, 540)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    f.TitleText:SetText("|cffffff00Auto|rItemMacro  |cff888888v" .. ADDON_VERSION .. "|r")

    -- Addon logo in the title bar, left of the centred title. OVERLAY so it
    -- sits above the template's own title-bar art.
    f.logo = f:CreateTexture(nil, "OVERLAY")
    f.logo:SetSize(18, 18)
    f.logo:SetPoint("TOPLEFT", 8, -4)
    f.logo:SetTexture(LOGO_TEXTURE)

    mainFrame = f
    tinsert(_G.UISpecialFrames, "AutoItemMacroFrame")

    -- ── Left panel: preset list ───────────────────────────────────────────────
    local leftHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    leftHeader:SetPoint("TOPLEFT", 14, -34)
    leftHeader:SetText("Macro Presets")
    leftHeader:SetTextColor(1, 0.82, 0.0)

    local presetScrollBg = CreateFrame("Frame", nil, f, "InsetFrameTemplate")
    presetScrollBg:SetPoint("TOPLEFT",  10, -52)
    presetScrollBg:SetSize(200, 395)

    local presetScroll = CreateFrame("ScrollFrame", "AIMPresetScroll", presetScrollBg, "UIPanelScrollFrameTemplate")
    presetScroll:SetPoint("TOPLEFT",     4, -4)
    presetScroll:SetPoint("BOTTOMRIGHT", -26, 4)

    f.presetContent = CreateFrame("Frame", nil, presetScroll)
    presetScroll:SetScrollChild(f.presetContent)
    f.presetContent:SetWidth(172)
    f.presetContent:SetHeight(1)

    -- "+ New Macro" button below the preset list
    f.addPresetBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.addPresetBtn:SetSize(194, 24)
    f.addPresetBtn:SetPoint("TOPLEFT", 10, -455)
    f.addPresetBtn:SetText("+ New Macro Preset")
    f.addPresetBtn:SetScript("OnClick", function()
        if not InCombatLockdown() then AddPreset() end
    end)

    -- ── Right panel: preset details ───────────────────────────────────────────

    -- Macro name / rename
    local renameLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    renameLabel:SetPoint("TOPLEFT", 222, -34)
    renameLabel:SetText("Macro Name:")
    renameLabel:SetTextColor(0.9, 0.9, 0.9)

    f.renameBox = CreateFrame("EditBox", "AIMRenameBox", f, "InputBoxTemplate")
    f.renameBox:SetSize(170, 22)
    f.renameBox:SetPoint("LEFT", renameLabel, "RIGHT", 6, 0)
    f.renameBox:SetAutoFocus(false)
    f.renameBox:SetMaxLetters(MAX_MACRO_NAME_LEN)
    f.renameBox:SetScript("OnEnterPressed", function(self)
        local newName = strtrim(self:GetText())
        if selectedPresetIndex and newName ~= "" then
            if RenamePreset(selectedPresetIndex, newName) then
                RefreshPresetList()
                RefreshItemList()
            else
                -- Restore existing name (conflict or empty)
                local p = db and db.presets[selectedPresetIndex]
                if p then self:SetText(p.name) end
                _G.UIErrorsFrame:AddMessage(
                    "|cffFF4444AutoItemMacro:|r That name is already in use or invalid.",
                    1, 0.27, 0.27, 1)
            end
        end
        self:ClearFocus()
    end)
    f.renameBox:SetScript("OnEscapePressed", function(self)
        local p = selectedPresetIndex and db and db.presets[selectedPresetIndex]
        if p then self:SetText(p.name) end
        self:ClearFocus()
    end)
    f.renameBox:Disable()

    local renameTip = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    renameTip:SetPoint("LEFT", f.renameBox, "RIGHT", 8, 0)
    renameTip:SetText("(max " .. MAX_MACRO_NAME_LEN .. " chars, Enter to confirm)")

    -- Item priority list scroll
    local itemScrollBg = CreateFrame("Frame", nil, f, "InsetFrameTemplate")
    itemScrollBg:SetPoint("TOPLEFT",  216, -56)
    itemScrollBg:SetPoint("TOPRIGHT", -10,   0)
    itemScrollBg:SetHeight(270)
    f.itemScrollBg = itemScrollBg

    local itemScroll = CreateFrame("ScrollFrame", "AIMItemScroll", itemScrollBg, "UIPanelScrollFrameTemplate")
    itemScroll:SetPoint("TOPLEFT",     4, -4)
    itemScroll:SetPoint("BOTTOMRIGHT", -26, 4)

    f.itemContent = CreateFrame("Frame", nil, itemScroll)
    itemScroll:SetScrollChild(f.itemContent)
    f.itemContent:SetWidth(430)
    f.itemContent:SetHeight(1)

    -- ── Add item by ID ────────────────────────────────────────────────────────
    local addItemLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    addItemLabel:SetPoint("TOPLEFT", itemScrollBg, "BOTTOMLEFT", 4, -14)
    addItemLabel:SetText("Add by Item ID:")

    f.addItemBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    f.addItemBox:SetSize(110, 22)
    f.addItemBox:SetPoint("LEFT", addItemLabel, "RIGHT", 8, 0)
    f.addItemBox:SetAutoFocus(false)
    f.addItemBox:SetNumeric(true)
    f.addItemBox:SetScript("OnEnterPressed", function(self)
        local id = tonumber(self:GetText())
        if id then AddItemToPreset(id); self:SetText("") end
        self:ClearFocus()
    end)
    f.addItemBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    f.addItemBox:Disable()

    f.addItemBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.addItemBtn:SetSize(60, 22)
    f.addItemBtn:SetText("Add")
    f.addItemBtn:SetPoint("LEFT", f.addItemBox, "RIGHT", 4, 0)
    f.addItemBtn:SetScript("OnClick", function()
        local id = tonumber(f.addItemBox:GetText())
        if id then AddItemToPreset(id); f.addItemBox:SetText("") end
    end)
    f.addItemBtn:Disable()

    -- ── Drag & drop zone ──────────────────────────────────────────────────────
    local dropLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    dropLabel:SetPoint("TOPLEFT", addItemLabel, "BOTTOMLEFT", 0, -20)
    dropLabel:SetText("Drag & Drop:")

    local dropSkin = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    dropSkin:SetSize(340, 22)
    dropSkin:SetPoint("LEFT", dropLabel, "RIGHT", 8, 0)
    dropSkin:SetEnabled(false)

    local dropZone = CreateFrame("Frame", nil, f)
    dropZone:SetAllPoints(dropSkin)
    dropZone:SetFrameLevel(dropSkin:GetFrameLevel() + 10)
    dropZone:EnableMouse(true)

    local dropText = dropZone:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    dropText:SetPoint("CENTER")
    dropText:SetText("Drag an item from your bags here")
    dropText:SetTextColor(0.6, 0.6, 0.6)

    dropZone:SetScript("OnEnter", function()
        if not selectedPresetIndex then return end
        local t, id = GetCursorInfo()
        if t == "item" and tonumber(id) then
            dropText:SetText("|cff44ff00Drop to add item to preset|r")
        end
    end)
    dropZone:SetScript("OnLeave", function()
        dropText:SetText("Drag an item from your bags here")
        dropText:SetTextColor(0.6, 0.6, 0.6)
    end)
    local function HandleDrop()
        if not selectedPresetIndex then return end
        local t, id = GetCursorInfo()
        id = tonumber(id)
        if t == "item" and id then
            AddItemToPreset(id)
            ClearCursor()
        end
        dropText:SetText("Drag an item from your bags here")
        dropText:SetTextColor(0.6, 0.6, 0.6)
    end
    dropZone:SetScript("OnReceiveDrag", HandleDrop)
    dropZone:SetScript("OnMouseDown",   HandleDrop)

    -- ── Macro body preview ────────────────────────────────────────────────────
    local previewLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    previewLabel:SetPoint("TOPLEFT", dropLabel, "BOTTOMLEFT", 0, -18)
    previewLabel:SetText("Macro Preview:")
    previewLabel:SetTextColor(0.65, 0.65, 0.65)

    f.previewText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.previewText:SetPoint("TOPLEFT",  previewLabel, "BOTTOMLEFT", 2, -4)
    f.previewText:SetPoint("TOPRIGHT", f, "TOPRIGHT", -15, 0)
    f.previewText:SetHeight(58)
    f.previewText:SetJustifyH("LEFT")

    -- ── Bottom bar ────────────────────────────────────────────────────────────
    f.autoUpdateChk = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    f.autoUpdateChk:SetSize(24, 24)
    f.autoUpdateChk:SetPoint("BOTTOMLEFT", 12, 10)
    f.autoUpdateChk.lbl = f.autoUpdateChk:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.autoUpdateChk.lbl:SetPoint("LEFT", f.autoUpdateChk, "RIGHT", 4, 0)
    f.autoUpdateChk.lbl:SetText("Auto-update macros on bag change")
    if db then f.autoUpdateChk:SetChecked(db.autoUpdate ~= false) end
    f.autoUpdateChk:SetScript("OnClick", function(self)
        if db then db.autoUpdate = self:GetChecked() end
    end)

    -- Anchored off the auto-update label rather than a fixed x, so it stays
    -- clear of it if that wording ever changes length.
    f.minimapChk = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    f.minimapChk:SetSize(24, 24)
    f.minimapChk:SetPoint("LEFT", f.autoUpdateChk.lbl, "RIGHT", 24, 0)
    f.minimapChk.lbl = f.minimapChk:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.minimapChk.lbl:SetPoint("LEFT", f.minimapChk, "RIGHT", 4, 0)
    f.minimapChk.lbl:SetText("Minimap button")
    if db then f.minimapChk:SetChecked(db.minimap ~= false) end
    f.minimapChk:SetScript("OnClick", function(self)
        if not db then return end
        db.minimap = self:GetChecked() and true or false
        ApplyMinimapButton()
    end)

    f.updateBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.updateBtn:SetSize(170, 24)
    f.updateBtn:SetText("Force Update All Macros")
    f.updateBtn:SetPoint("BOTTOMRIGHT", -10, 10)
    f.updateBtn:SetScript("OnClick", function()
        UpdateAllMacros()
        _G.print(CHAT_PREFIX .. "All macros updated.")
    end)

    f:SetScript("OnShow", function()
        RefreshPresetList()
        RefreshItemList()
    end)
end

-- ── Event handler ─────────────────────────────────────────────────────────────

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("BAG_UPDATE_DELAYED")
eventFrame:RegisterEvent("ITEM_DATA_LOAD_RESULT")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

eventFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        -- Initialise / migrate saved variables
        AutoItemMacroDB        = AutoItemMacroDB or {}
        AutoItemMacroDB.presets   = AutoItemMacroDB.presets   or {}
        AutoItemMacroDB.autoUpdate = (AutoItemMacroDB.autoUpdate ~= false)
        AutoItemMacroDB.minimap    = (AutoItemMacroDB.minimap ~= false)
        AutoItemMacroDB.minimapAngle = AutoItemMacroDB.minimapAngle or 200
        db = AutoItemMacroDB
        BuildUI()

    elseif event == "PLAYER_LOGIN" then
        -- Sync the option checkboxes, then push all macros to the game
        if mainFrame and mainFrame.autoUpdateChk and mainFrame.minimapChk then
            mainFrame.autoUpdateChk:SetChecked(db.autoUpdate)
            mainFrame.minimapChk:SetChecked(db.minimap)
        end
        -- Built at login, not at ADDON_LOADED: minimap addons resize and reshape
        -- the minimap while loading, and the button's placement reads both.
        ApplyMinimapButton()
        UpdateAllMacros()
        eventFrame:UnregisterEvent("PLAYER_LOGIN")

    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Hide UI when entering combat (cannot edit macros in combat)
        if mainFrame and mainFrame:IsShown() then mainFrame:Hide() end

    elseif event == "PLAYER_REGEN_ENABLED" then
        if needsUpdateAfterCombat then
            needsUpdateAfterCombat = false
            UpdateAllMacros()
            if mainFrame and mainFrame:IsShown() then
                RefreshPresetList()
                RefreshItemList()
            end
        end

    elseif event == "BAG_UPDATE_DELAYED" then
        if not db or not db.autoUpdate then return end
        if InCombatLockdown() then
            needsUpdateAfterCombat = true
        elseif not updatePending then
            updatePending = true
            _G.C_Timer.After(1.0, function()
                updatePending = false
                UpdateAllMacros()
                if mainFrame and mainFrame:IsShown() then RefreshItemList() end
            end)
        end

    elseif event == "ITEM_DATA_LOAD_RESULT" then
        -- Item name/icon data arrived — refresh display
        if mainFrame and mainFrame:IsShown() then RefreshItemList() end
    end
end)

-- ── Slash commands ────────────────────────────────────────────────────────────

_G.SLASH_AUTOITEMMACRO1 = "/aim"
_G.SLASH_AUTOITEMMACRO2 = "/autoitemmacro"
_G.SlashCmdList["AUTOITEMMACRO"] = function(msg)
    msg = strtrim((msg or ""):lower())

    if msg == "update" then
        if InCombatLockdown() then
            _G.UIErrorsFrame:AddMessage("|cffFF4444AutoItemMacro:|r Cannot update macros during combat.", 1, 0.27, 0.27, 1)
            return
        end
        UpdateAllMacros()
        _G.print(CHAT_PREFIX .. "All macros updated.")

    elseif msg == "help" then
        _G.print(LOGO_INLINE .. "|cffffff00AutoItemMacro|r commands:")
        _G.print("  |cffffd700/aim|r           — open / close the options window")
        _G.print("  |cffffd700/aim update|r     — force-update all macro presets")
        _G.print("  |cffffd700/aim help|r       — show this help text")

    elseif msg == "" then
        ToggleUI()

    else
        _G.print(CHAT_PREFIX .. "Unknown command. Type |cffffd700/aim help|r for a list.")
    end
end
