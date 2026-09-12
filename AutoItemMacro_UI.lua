-- AutoItemMacro_UI.lua
--
-- The editor window, the minimap button, and the addon compartment entry.
-- Everything here is presentation: it owns which preset is selected and which
-- frames exist, and calls into AutoItemMacro.lua for anything that touches the
-- saved data or the game's macros.
--
-- Layout rule for this file: nothing is positioned by a hand-computed offset
-- from the window's corner. Elements anchor to their neighbours, and the two
-- scrolling lists take whatever vertical space is left between the header above
-- them and the controls below. Moving a row means moving one anchor, not
-- re-deriving a column of pixel arithmetic.

local _, ns = ...

local _G               = _G
local CreateFrame      = _G.CreateFrame
local UIParent         = _G.UIParent
local GameTooltip      = _G.GameTooltip
local InCombatLockdown = _G.InCombatLockdown
local GetCursorInfo    = _G.GetCursorInfo
local ClearCursor      = _G.ClearCursor
local tinsert          = _G.table.insert
local C_Item           = _G.C_Item

-- ── Layout ────────────────────────────────────────────────────────────────────

local FRAME_W, FRAME_H  = 680, 540
local PAD               = 10   -- window margin
local GAP               = 8    -- between stacked elements
local HEADER_Y          = -34  -- first row below the title bar
local PRESET_COL_W      = 200  -- left column
local BOTTOM_BAR_H      = 24
local PRESET_ROW_H      = 30
local ITEM_ROW_H        = 35
local ROW_BTN_H         = 18
local FIELD_H           = 22
local PREVIEW_H         = 58
local INSET             = 4    -- InsetFrameTemplate's inner edge
local SCROLLBAR_W       = 26   -- gutter UIPanelScrollFrameTemplate needs

local DROP_PROMPT = "Drag an item from your bags here"

-- ── State ─────────────────────────────────────────────────────────────────────

local mainFrame           = nil
local minimapButton       = nil
local selectedPresetIndex = nil
local presetRowPool       = {}
local itemRowPool         = {}

local RefreshPresetList, RefreshItemList

local function SelectedPreset()
    return ns.GetPreset(selectedPresetIndex)
end

local function RefreshAll()
    RefreshPresetList()
    RefreshItemList()
end

local function IsShown()
    return mainFrame and mainFrame:IsShown()
end

-- ── Shared widget helpers ─────────────────────────────────────────────────────

local function MakeLabel(parent, text, template, r, g, b)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormal")
    fs:SetText(text)
    if r then fs:SetTextColor(r, g, b) end
    return fs
end

-- The small square buttons that live on a list row. They differ only in width,
-- caption and what they do, so they are built from one place.
local function MakeRowButton(parent, width, text, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, ROW_BTN_H)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

-- An InsetFrameTemplate holding a UIPanelScrollFrameTemplate, which is the
-- combination every list in this window uses. The scroll child is kept exactly
-- as wide as the viewport, so rows can anchor to both its edges and never need
-- a hardcoded width.
local function MakeScrollList(parent)
    local inset = CreateFrame("Frame", nil, parent, "InsetFrameTemplate")

    local scroll = CreateFrame("ScrollFrame", nil, inset, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", INSET, -INSET)
    scroll:SetPoint("BOTTOMRIGHT", -SCROLLBAR_W, INSET)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(1, 1)
    scroll:SetScrollChild(content)
    scroll:SetScript("OnSizeChanged", function(_, w) content:SetWidth(w) end)

    inset.content = content
    return inset
end

-- ── Preset rows (left panel) ──────────────────────────────────────────────────

local function CreatePresetRow(index)
    local row = CreateFrame("Button", nil, mainFrame.presetContent)
    row:SetHeight(PRESET_ROW_H - 2)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * PRESET_ROW_H)
    row:SetPoint("TOPRIGHT", 0, -(index - 1) * PRESET_ROW_H)

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()

    row.delBtn = MakeRowButton(row, 22, "X", function()
        if not row.presetIndex then return end
        if not ns.DeletePreset(row.presetIndex) then return end
        -- Keep the selection pointing at something sensible: the same slot if
        -- it still exists, otherwise the new last row.
        if selectedPresetIndex == row.presetIndex then
            local n = ns.NumPresets()
            selectedPresetIndex = n > 0 and math.min(row.presetIndex, n) or nil
        elseif selectedPresetIndex and selectedPresetIndex > row.presetIndex then
            selectedPresetIndex = selectedPresetIndex - 1
        end
        RefreshAll()
    end)
    row.delBtn:SetPoint("RIGHT", -2, 0)

    row.label = MakeLabel(row, "", "GameFontNormalSmall")
    row.label:SetPoint("LEFT", 6, 0)
    row.label:SetPoint("RIGHT", row.delBtn, "LEFT", -4, 0)
    row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)

    row:SetScript("OnClick", function()
        selectedPresetIndex = row.presetIndex
        RefreshAll()
    end)

    return row
end

local function SetPresetRow(row, preset, index)
    row.presetIndex = index
    row.label:SetText(preset.name)

    if selectedPresetIndex == index then
        row.bg:SetColorTexture(0.25, 0.45, 0.75, 0.55)
        row.label:SetTextColor(1, 1, 1)
    else
        row.bg:SetColorTexture(0.18, 0.18, 0.18, 0.50)
        row.label:SetTextColor(0.75, 0.75, 0.75)
    end
    row:Show()
end

RefreshPresetList = function()
    if not mainFrame then return end
    for _, row in ipairs(presetRowPool) do row:Hide() end

    local count = ns.NumPresets()
    for i = 1, count do
        local row = presetRowPool[i]
        if not row then
            row = CreatePresetRow(i)
            presetRowPool[i] = row
        end
        SetPresetRow(row, ns.GetPreset(i), i)
    end

    mainFrame.presetContent:SetHeight(math.max(1, count * PRESET_ROW_H))
end

-- ── Item rows (right panel) ───────────────────────────────────────────────────

-- Every button on an item row needs the same three facts, and none of them are
-- known when the row is built, so they are read off the row at click time.
local function RowContext(row)
    local preset = ns.GetPreset(row.presetIndex)
    if not preset or not row.itemIndex then return nil end
    return preset, row.itemIndex
end

local function CreateItemRow(index)
    local row = CreateFrame("Frame", nil, mainFrame.itemContent)
    row:SetHeight(ITEM_ROW_H - 3)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * ITEM_ROW_H)
    row:SetPoint("TOPRIGHT", 0, -(index - 1) * ITEM_ROW_H)

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(0.14, 0.14, 0.14, 0.55)

    -- Buttons are laid out right to left, each anchored to the previous one.
    row.delBtn = MakeRowButton(row, 22, "X", function()
        local preset, i = RowContext(row)
        if preset and ns.RemoveItem(preset, i) then RefreshItemList() end
    end)
    row.delBtn:SetPoint("RIGHT", -2, 0)

    row.downBtn = MakeRowButton(row, 24, "v", function()
        local preset, i = RowContext(row)
        if preset and ns.MoveItem(preset, i, 1) then RefreshItemList() end
    end)
    row.downBtn:SetPoint("RIGHT", row.delBtn, "LEFT", -2, 0)

    row.upBtn = MakeRowButton(row, 24, "^", function()
        local preset, i = RowContext(row)
        if preset and ns.MoveItem(preset, i, -1) then RefreshItemList() end
    end)
    row.upBtn:SetPoint("RIGHT", row.downBtn, "LEFT", -2, 0)

    row.modBtn = MakeRowButton(row, 38, "", function()
        local preset, i = RowContext(row)
        if preset and ns.CycleItemMod(preset, i) then RefreshItemList() end
    end)
    row.modBtn:SetPoint("RIGHT", row.upBtn, "LEFT", -2, 0)
    row.modBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Modifier key\nClick to cycle:\n" ..
            "|cff888888---|r No modifier\n|cffff9910ALT|r  [mod:alt]\n" ..
            "|cff22ddffCTL|r  [mod:ctrl]\n|cff44ff66SHF|r  [mod:shift]\n" ..
            "|cffffee22NOM|r  [mod:nomod]", nil, nil, nil, nil, true)
        GameTooltip:Show()
    end)
    row.modBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    row.status = MakeLabel(row, "", "GameFontNormalSmall")
    row.status:SetPoint("RIGHT", row.modBtn, "LEFT", -6, 0)
    row.status:SetWidth(46)
    row.status:SetJustifyH("CENTER")

    -- Left to right: priority number, icon, name.
    row.badge = MakeLabel(row, "", "GameFontNormalSmall", 0.5, 0.5, 0.5)
    row.badge:SetPoint("LEFT", 4, 0)
    row.badge:SetWidth(18)
    row.badge:SetJustifyH("RIGHT")

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(24, 24)
    row.icon:SetPoint("LEFT", row.badge, "RIGHT", 4, 0)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    row.text = MakeLabel(row, "", "GameFontNormalSmall")
    row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.text:SetPoint("RIGHT", row.status, "LEFT", -6, 0)
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(false)

    row:SetScript("OnEnter", function(self)
        if not self.itemID then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetItemByID(self.itemID)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    return row
end

local function SetItemRow(row, item, index)
    row.itemIndex   = index
    row.presetIndex = selectedPresetIndex
    row.itemID      = item.id
    row.badge:SetText(index)

    local name = C_Item.GetItemNameByID(item.id)
    if not name then
        C_Item.RequestLoadItemDataByID(item.id)
        name = "Loading... (" .. item.id .. ")"
    end
    row.icon:SetTexture(C_Item.GetItemIconByID(item.id) or ns.DEFAULT_ICON)

    -- One count answers both questions: whether to grey the row out, and what
    -- number to show. Asking twice was two C calls per row per refresh.
    local count = ns.ItemCount(item.id)
    row.text:SetText(name .. "  |cff666666[" .. item.id .. "]|r")
    if count > 0 then
        row.text:SetTextColor(1, 1, 1)
        row.status:SetText("|cff44ff44x" .. count .. "|r")
    else
        row.text:SetTextColor(0.45, 0.45, 0.45)
        -- ASCII, deliberately. This was U+2717 BALLOT X, which renders as a
        -- hollow box on any font that lacks the glyph -- and tinted red by the
        -- colour code, so it looked like a deliberate red square rather than a
        -- missing character. Custom and non-Latin fonts frequently have no
        -- dingbats, and this addon ships to whoever installs it.
        row.status:SetText("|cffff4444--|r")
    end

    local mod = item.mod or "default"
    row.modBtn:SetText("|cff" .. (ns.MOD_COLOR_HEX[mod] or "888888") ..
                       (ns.MOD_LABEL[mod] or "---") .. "|r")
    row:Show()
end

-- Enables or disables everything that only makes sense with a preset selected.
local function SetDetailsEnabled(enabled)
    local f = mainFrame
    if enabled then
        f.renameBox:Enable()
        f.addItemBox:Enable()
        f.addItemBtn:Enable()
    else
        f.renameBox:SetText("")
        f.renameBox:Disable()
        f.addItemBox:Disable()
        f.addItemBtn:Disable()
    end
end

RefreshItemList = function()
    if not mainFrame then return end
    for _, row in ipairs(itemRowPool) do row:Hide() end

    local preset = SelectedPreset()
    if not preset then
        SetDetailsEnabled(false)
        mainFrame.itemContent:SetHeight(1)
        mainFrame.previewText:SetText("|cff555555Select or create a macro preset on the left.|r")
        return
    end

    SetDetailsEnabled(true)
    mainFrame.renameBox:SetText(preset.name)

    local items = preset.items
    for i = 1, #items do
        local row = itemRowPool[i]
        if not row then
            row = CreateItemRow(i)
            itemRowPool[i] = row
        end
        SetItemRow(row, items[i], i)
    end
    mainFrame.itemContent:SetHeight(math.max(1, #items * ITEM_ROW_H))

    local body = ns.GetMacroBody(preset)
    if body ~= "" then
        mainFrame.previewText:SetText("|cffaaaaaa" .. body .. "|r")
    else
        mainFrame.previewText:SetText("|cff555555(no items in bags - macro will be empty)|r")
    end
end

-- ── Panels ────────────────────────────────────────────────────────────────────

-- Anchored to the window's bottom edge; everything else in the window stacks
-- above it, so it is built first.
local function BuildBottomBar(f)
    local bar = CreateFrame("Frame", nil, f)
    bar:SetPoint("BOTTOMLEFT", PAD, PAD)
    bar:SetPoint("BOTTOMRIGHT", -PAD, PAD)
    bar:SetHeight(BOTTOM_BAR_H)

    f.updateBtn = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
    f.updateBtn:SetSize(170, BOTTOM_BAR_H)
    f.updateBtn:SetPoint("RIGHT")
    f.updateBtn:SetText("Force Update All Macros")
    f.updateBtn:SetScript("OnClick", function()
        -- Explicit rebuild: bypass the unchanged-body check so this also
        -- repairs a macro that was hand-edited elsewhere.
        ns.InvalidateMacroCache()
        ns.UpdateAllMacros()
        ns.Print("All macros updated.")
    end)

    f.autoUpdateChk = CreateFrame("CheckButton", nil, bar, "UICheckButtonTemplate")
    f.autoUpdateChk:SetSize(BOTTOM_BAR_H, BOTTOM_BAR_H)
    f.autoUpdateChk:SetPoint("LEFT", 2, 0)
    f.autoUpdateChk.lbl = MakeLabel(f.autoUpdateChk, "Auto-update macros on bag change")
    f.autoUpdateChk.lbl:SetPoint("LEFT", f.autoUpdateChk, "RIGHT", 4, 0)
    f.autoUpdateChk:SetScript("OnClick", function(self)
        local db = ns.GetDB()
        if db then db.autoUpdate = self:GetChecked() and true or false end
    end)

    -- Anchored off the previous label rather than a fixed x, so it stays clear
    -- of it if that wording ever changes length.
    f.minimapChk = CreateFrame("CheckButton", nil, bar, "UICheckButtonTemplate")
    f.minimapChk:SetSize(BOTTOM_BAR_H, BOTTOM_BAR_H)
    f.minimapChk:SetPoint("LEFT", f.autoUpdateChk.lbl, "RIGHT", 24, 0)
    f.minimapChk.lbl = MakeLabel(f.minimapChk, "Minimap button")
    f.minimapChk.lbl:SetPoint("LEFT", f.minimapChk, "RIGHT", 4, 0)
    f.minimapChk:SetScript("OnClick", function(self)
        local db = ns.GetDB()
        if not db then return end
        db.minimap = self:GetChecked() and true or false
        ns.ApplyMinimapButton()
    end)

    return bar
end

-- Preset list plus its "new preset" button. The list fills whatever is left
-- between the header and the button.
local function BuildPresetPanel(f, col)
    local header = MakeLabel(col, "Macro Presets", "GameFontNormal", 1, 0.82, 0)
    header:SetPoint("TOPLEFT", 4, 0)

    f.addPresetBtn = CreateFrame("Button", nil, col, "UIPanelButtonTemplate")
    f.addPresetBtn:SetHeight(BOTTOM_BAR_H)
    f.addPresetBtn:SetPoint("BOTTOMLEFT")
    f.addPresetBtn:SetPoint("BOTTOMRIGHT")
    f.addPresetBtn:SetText("+ New Macro Preset")
    f.addPresetBtn:SetScript("OnClick", function()
        local preset, index = ns.AddPreset()
        if not preset then return end
        selectedPresetIndex = index
        RefreshAll()
        -- Auto-focus the rename box so the user can immediately type a name.
        f.renameBox:SetFocus()
        f.renameBox:HighlightText()
    end)

    local list = MakeScrollList(col)
    list:SetPoint("TOPLEFT", header, "BOTTOMLEFT", -4, -GAP)
    list:SetPoint("BOTTOMRIGHT", f.addPresetBtn, "TOPRIGHT", 0, GAP)
    f.presetContent = list.content
end

-- The name field. Fills a container the caller sizes, so the label and the box
-- can centre on each other without the row's own height depending on either.
local function BuildRenameRow(f, col)
    local label = MakeLabel(col, "Macro Name:", "GameFontNormal", 0.9, 0.9, 0.9)
    label:SetPoint("LEFT", 6, 0)

    f.renameBox = CreateFrame("EditBox", nil, col, "InputBoxTemplate")
    f.renameBox:SetSize(170, FIELD_H)
    f.renameBox:SetPoint("LEFT", label, "RIGHT", 6, 0)
    f.renameBox:SetAutoFocus(false)
    f.renameBox:SetMaxLetters(ns.MAX_MACRO_NAME_LEN)
    f.renameBox:SetScript("OnEnterPressed", function(self)
        local newName = strtrim(self:GetText())
        if selectedPresetIndex and newName ~= "" then
            if ns.RenamePreset(selectedPresetIndex, newName) then
                RefreshAll()
            else
                local preset = SelectedPreset()
                if preset then self:SetText(preset.name) end
                ns.Error("That name is already in use or invalid.")
            end
        end
        self:ClearFocus()
    end)
    f.renameBox:SetScript("OnEscapePressed", function(self)
        local preset = SelectedPreset()
        if preset then self:SetText(preset.name) end
        self:ClearFocus()
    end)
    f.renameBox:Disable()

    local tip = MakeLabel(col, "(max " .. ns.MAX_MACRO_NAME_LEN ..
                             " chars, Enter to confirm)", "GameFontDisableSmall")
    tip:SetPoint("LEFT", f.renameBox, "RIGHT", 8, 0)
end

-- Everything under the item list, built bottom-up from the bottom bar so the
-- list itself can claim the remaining space.
local function BuildItemControls(f, col)
    f.previewText = MakeLabel(col, "", "GameFontHighlightSmall")
    f.previewText:SetPoint("BOTTOMLEFT", 2, 0)
    f.previewText:SetPoint("BOTTOMRIGHT", -5, 0)
    f.previewText:SetHeight(PREVIEW_H)
    f.previewText:SetJustifyH("LEFT")
    f.previewText:SetJustifyV("TOP")

    local previewLabel = MakeLabel(col, "Macro Preview:", "GameFontNormal", 0.65, 0.65, 0.65)
    previewLabel:SetPoint("BOTTOMLEFT", f.previewText, "TOPLEFT", -2, 4)

    local dropLabel = MakeLabel(col, "Drag & Drop:")
    dropLabel:SetPoint("BOTTOMLEFT", previewLabel, "TOPLEFT", 0, GAP + 6)

    -- An InputBoxTemplate used purely as a sunken frame; the EditBox itself is
    -- disabled and an ordinary Frame on top of it receives the drop.
    local dropSkin = CreateFrame("EditBox", nil, col, "InputBoxTemplate")
    dropSkin:SetSize(340, FIELD_H)
    dropSkin:SetPoint("LEFT", dropLabel, "RIGHT", 8, 0)
    dropSkin:SetEnabled(false)

    local dropZone = CreateFrame("Frame", nil, col)
    dropZone:SetAllPoints(dropSkin)
    dropZone:SetFrameLevel(dropSkin:GetFrameLevel() + 10)
    dropZone:EnableMouse(true)

    local dropText = MakeLabel(dropZone, DROP_PROMPT, "GameFontHighlightSmall", 0.6, 0.6, 0.6)
    dropText:SetPoint("CENTER")

    local function ResetPrompt()
        dropText:SetText(DROP_PROMPT)
        dropText:SetTextColor(0.6, 0.6, 0.6)
    end

    dropZone:SetScript("OnEnter", function()
        if not SelectedPreset() then return end
        local kind, id = GetCursorInfo()
        if kind == "item" and tonumber(id) then
            dropText:SetText("|cff44ff00Drop to add item to preset|r")
        end
    end)
    dropZone:SetScript("OnLeave", ResetPrompt)

    local function HandleDrop()
        local preset = SelectedPreset()
        if not preset then return end
        local kind, id = GetCursorInfo()
        id = tonumber(id)
        if kind == "item" and id then
            ns.AddItemToPreset(preset, id, RefreshItemList)
            ClearCursor()
        end
        ResetPrompt()
    end
    dropZone:SetScript("OnReceiveDrag", HandleDrop)
    dropZone:SetScript("OnMouseDown", HandleDrop)

    local addLabel = MakeLabel(col, "Add by Item ID:")
    addLabel:SetPoint("BOTTOMLEFT", dropLabel, "TOPLEFT", 0, GAP + 6)

    local function SubmitID(box)
        local preset = SelectedPreset()
        local id = tonumber(box:GetText())
        if preset and id then
            ns.AddItemToPreset(preset, id, RefreshItemList)
            box:SetText("")
        end
    end

    f.addItemBox = CreateFrame("EditBox", nil, col, "InputBoxTemplate")
    f.addItemBox:SetSize(110, FIELD_H)
    f.addItemBox:SetPoint("LEFT", addLabel, "RIGHT", 8, 0)
    f.addItemBox:SetAutoFocus(false)
    f.addItemBox:SetNumeric(true)
    f.addItemBox:SetScript("OnEnterPressed", function(self)
        SubmitID(self)
        self:ClearFocus()
    end)
    f.addItemBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    f.addItemBox:Disable()

    f.addItemBtn = CreateFrame("Button", nil, col, "UIPanelButtonTemplate")
    f.addItemBtn:SetSize(60, FIELD_H)
    f.addItemBtn:SetText("Add")
    f.addItemBtn:SetPoint("LEFT", f.addItemBox, "RIGHT", 4, 0)
    f.addItemBtn:SetScript("OnClick", function() SubmitID(f.addItemBox) end)
    f.addItemBtn:Disable()

    return addLabel
end

-- ── Window ────────────────────────────────────────────────────────────────────

function ns.BuildUI()
    if mainFrame then return end

    local f = CreateFrame("Frame", "AutoItemMacroFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(FRAME_W, FRAME_H)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    f.TitleText:SetText("|cffffff00Auto|rItemMacro  |cff888888v" .. ns.ADDON_VERSION .. "|r")

    -- Addon logo in the title bar, left of the centred title. OVERLAY so it
    -- sits above the template's own title-bar art.
    f.logo = f:CreateTexture(nil, "OVERLAY")
    f.logo:SetSize(18, 18)
    f.logo:SetPoint("TOPLEFT", 8, -4)
    f.logo:SetTexture(ns.LOGO_TEXTURE)

    mainFrame = f
    tinsert(_G.UISpecialFrames, "AutoItemMacroFrame")

    local bottomBar = BuildBottomBar(f)

    -- Two column containers spanning from the first row below the title bar
    -- down to the bottom bar. Everything else anchors inside one of them, which
    -- is what keeps the panel builders independent of the window's dimensions.
    local leftCol = CreateFrame("Frame", nil, f)
    leftCol:SetPoint("TOPLEFT", PAD, HEADER_Y)
    leftCol:SetPoint("BOTTOMLEFT", bottomBar, "TOPLEFT", 0, GAP)
    leftCol:SetWidth(PRESET_COL_W)

    local rightCol = CreateFrame("Frame", nil, f)
    rightCol:SetPoint("TOPLEFT", leftCol, "TOPRIGHT", GAP, 0)
    rightCol:SetPoint("BOTTOMRIGHT", bottomBar, "TOPRIGHT", 0, GAP)

    BuildPresetPanel(f, leftCol)

    -- The name row gets a container of its own so the list below can take both
    -- of its top anchors from the same object. Anchoring one corner to the label
    -- and the other to the column skews the frame: the label centres on the edit
    -- box, so the two corners resolve to different heights.
    local nameRow = CreateFrame("Frame", nil, rightCol)
    nameRow:SetPoint("TOPLEFT")
    nameRow:SetPoint("TOPRIGHT")
    nameRow:SetHeight(FIELD_H)
    BuildRenameRow(f, nameRow)

    local addLabel = BuildItemControls(f, rightCol)

    -- The item list is built last because it claims whatever vertical space the
    -- name row above and the controls below have not taken.
    local list = MakeScrollList(rightCol)
    list:SetPoint("TOPLEFT", nameRow, "BOTTOMLEFT", 0, -GAP)
    list:SetPoint("TOPRIGHT", nameRow, "BOTTOMRIGHT", 0, -GAP)
    list:SetPoint("BOTTOM", addLabel, "TOP", 0, GAP + 6)
    f.itemContent = list.content

    f:SetScript("OnShow", RefreshAll)
end

-- ── Opening the editor ────────────────────────────────────────────────────────

-- Shared by the slash command, the minimap button and the addon compartment.
-- Macros cannot be edited in combat, so all three refuse the same way.
function ns.ToggleUI()
    if InCombatLockdown() then
        ns.Error("Cannot open UI during combat.")
        return
    end
    if not mainFrame then return end
    if mainFrame:IsShown() then mainFrame:Hide() else mainFrame:Show() end
end

-- Blizzard calls this by name from the addon compartment next to the minimap,
-- so it has to be a global. ## AddonCompartmentFunc in the .toc names it.
function _G.AutoItemMacro_OnCompartmentClick()
    ns.ToggleUI()
end

-- ── Minimap button ────────────────────────────────────────────────────────────
-- Hand-rolled rather than LibDBIcon. This addon ships as a single library-free
-- package, and pulling in LibStub + CallbackHandler + LDB + LibDBIcon to place
-- one button would be most of its weight. Borrowing another addon's copy would
-- make our button appear and vanish with THEIR install.

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
    local Minimap = _G.Minimap
    if not minimapButton or not Minimap then return end

    local db = ns.GetDB()
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
    icon:SetTexture(ns.LOGO_TEXTURE)
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
    b:SetScript("OnClick", ns.ToggleUI)

    -- Dragging follows the cursor's angle around the minimap centre rather than
    -- moving the frame freely, so the button cannot be dropped off the ring.
    -- OnUpdate is set only while a drag is in progress and cleared on release,
    -- so it costs nothing at rest.
    local function DragUpdate()
        local mx, my = _G.Minimap:GetCenter()
        local cx, cy = _G.GetCursorPosition()
        local scale = _G.Minimap:GetEffectiveScale()
        local db = ns.GetDB()
        if db then db.minimapAngle = math.deg(math.atan2(cy / scale - my, cx / scale - mx)) end
        PositionMinimapButton()
    end
    b:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", DragUpdate) end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

    minimapButton = b
    PositionMinimapButton()
    return b
end

function ns.ApplyMinimapButton()
    local db = ns.GetDB()
    if db and db.minimap == false then
        if minimapButton then minimapButton:Hide() end
        return
    end
    if BuildMinimapButton() then
        PositionMinimapButton()
        minimapButton:Show()
    end
end

-- ── Hooks the core calls on game events ───────────────────────────────────────

ns.OnLogin = function()
    local db = ns.GetDB()
    if mainFrame then
        mainFrame.autoUpdateChk:SetChecked(db.autoUpdate)
        mainFrame.minimapChk:SetChecked(db.minimap)
    end
    -- Built at login, not at ADDON_LOADED: minimap addons resize and reshape the
    -- minimap while loading, and the button's placement reads both.
    ns.ApplyMinimapButton()
end

ns.OnCombatStart = function()
    if IsShown() then mainFrame:Hide() end
end

ns.OnMacrosUpdated = function()
    if IsShown() then RefreshItemList() end
end

-- ITEM_DATA_LOAD_RESULT fires for every item the client resolves -- bags,
-- tooltips, quest rewards, other addons' queries. Rebuilding the list for an
-- item that is not even on screen was most of the work this event caused.
ns.OnItemDataLoaded = function(itemID)
    if not IsShown() or not itemID then return end
    local preset = SelectedPreset()
    if not preset then return end
    for i = 1, #preset.items do
        if preset.items[i].id == itemID then
            RefreshItemList()
            return
        end
    end
end
