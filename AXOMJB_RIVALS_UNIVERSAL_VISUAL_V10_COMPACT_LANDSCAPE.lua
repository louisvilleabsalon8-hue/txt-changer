--[[
 AXOMJB RIVALS UNIVERSAL VISUAL INJECTOR V9
 V4 + V8 unified build
 Single Lua file | compact draggable GUI | JSON/TXT pack editor

 FEATURES
 - V4-compatible replacement_rules / rules / replacements parser
 - JSON pasted from TXT (BOM + Markdown fence cleanup)
 - CDN URLs and Roblox asset IDs
 - Texture, image, mesh, SurfaceAppearance and sound replacements
 - Six-face skyboxes (BK/DN/FT/LF/RT/UP or full Skybox* keys)
 - Nested groups and common ID/URL aliases
 - Local/font rules intentionally skipped
 - Cached CDN downloads
 - Config save/load/delete/list/default
 - Restore original properties
 - New-object monitoring + periodic rescan
 - Six GUI channels: HOME / TEXTURES / SKYBOX / SOUNDS / CONFIGS / SETTINGS

 NOTE:
 This is a local visual customization script. It does not grant server permissions
 or modify server-side game state. Executor file/HTTP APIs vary by environment.
]]

if not game:IsLoaded() then
    game.Loaded:Wait()
end

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")

local Player = Players.LocalPlayer
local ENV = (getgenv and getgenv()) or _G
local KEY = "__AXOMJB_VISUAL_V9"
local GUI_NAME = "AxomJB_V9_GUI"
local CONFIG_FOLDER = "AxomJB_Configs"
local DEFAULT_FILE = CONFIG_FOLDER .. "/default.txt"

-- Stop an older copy cleanly before creating this one.
local previous = ENV[KEY]
if previous and type(previous.Stop) == "function" then
    pcall(previous.Stop)
end

local State = {
    Running = true,
    Applying = false,
    Prepared = {},
    Snapshots = {},
    Connections = {},
    Sky = nil,
    OriginalSkies = {},
    Changed = 0,
    Matched = 0,
    Scanned = 0,
    Gui = nil,
    AutoReapply = true,
    PackText = "",
    ActiveChannel = "HOME",
    LastApply = 0
}
ENV[KEY] = State

local function log(message)
    print("[AxomJB V9] " .. tostring(message))
end

local function warnLog(message)
    warn("[AxomJB V9] " .. tostring(message))
end

local function api(name)
    return rawget(ENV, name) or rawget(_G, name)
end

local writefile = api("writefile")
local readfile = api("readfile")
local listfiles = api("listfiles")
local delfile = api("delfile")
local isfile = api("isfile")
local isfolder = api("isfolder")
local makefolder = api("makefolder")
local getasset = api("getcustomasset") or api("getsynasset")

local function connect(signal, callback)
    local ok, connection = pcall(function()
        return signal:Connect(callback)
    end)
    if ok and connection then
        table.insert(State.Connections, connection)
        return connection
    end
    return nil
end

local function disconnectAll()
    for _, connection in ipairs(State.Connections) do
        pcall(function() connection:Disconnect() end)
    end
    State.Connections = {}
end

-- CONFIG FILES

local function setupFolder()
    if not makefolder or not isfolder then
        return false, "Folder APIs unavailable"
    end

    local ok, exists = pcall(isfolder, CONFIG_FOLDER)
    if not ok then return false, "Cannot check config folder" end

    if not exists then
        local made, result = pcall(makefolder, CONFIG_FOLDER)
        if not made then return false, tostring(result) end
    end
    return true
end

local function safeName(name)
    local cleaned = tostring(name or ""):gsub("[^%w%-_]", "_")
    return cleaned:sub(1, 40)
end

local function configPath(name)
    return CONFIG_FOLDER .. "/" .. safeName(name) .. ".json"
end

local function saveConfig(name, contents)
    if not writefile then return false, "writefile unavailable" end
    local folderOK, folderError = setupFolder()
    if not folderOK then return false, folderError end

    name = safeName(name)
    if name == "" or tostring(contents or ""):match("^%s*$") then
        return false, "Enter a config name and pack"
    end

    local valid, parsed = pcall(function()
        return HttpService:JSONDecode(contents)
    end)
    if not valid or type(parsed) ~= "table" then
        return false, "Invalid JSON"
    end

    local ok, err = pcall(function()
        writefile(configPath(name), contents)
    end)
    return ok, ok and ("Saved: " .. name) or tostring(err)
end

local function loadConfig(name)
    if not readfile then return nil, "readfile unavailable" end
    local folderOK, folderError = setupFolder()
    if not folderOK then return nil, folderError end

    name = safeName(name)
    if name == "" then return nil, "Enter a config name" end

    local ok, result = pcall(function()
        return readfile(configPath(name))
    end)
    if not ok then return nil, "Config not found" end
    return result
end

local function deleteConfig(name)
    if not delfile or not isfile then
        return false, "Delete APIs unavailable"
    end
    local folderOK, folderError = setupFolder()
    if not folderOK then return false, folderError end

    name = safeName(name)
    if name == "" then return false, "Enter a config name" end

    local path = configPath(name)
    local ok, exists = pcall(isfile, path)
    if not ok or not exists then return false, "Config not found" end

    local deleted, err = pcall(delfile, path)
    return deleted, deleted and ("Deleted: " .. name) or tostring(err)
end

local function listConfigs()
    if not listfiles then return {} end
    local folderOK = setupFolder()
    if not folderOK then return {} end

    local ok, files = pcall(listfiles, CONFIG_FOLDER)
    if not ok or type(files) ~= "table" then return {} end

    local names = {}
    for _, path in ipairs(files) do
        local normalized = tostring(path):gsub("\\", "/")
        local name = normalized:match("([^/]+)%.json$")
        if name then table.insert(names, name) end
    end
    table.sort(names)
    return names
end

local function setDefault(name)
    if not writefile then return false, "writefile unavailable" end
    local contents, err = loadConfig(name)
    if not contents then return false, err end

    local folderOK, folderError = setupFolder()
    if not folderOK then return false, folderError end

    local ok, result = pcall(function()
        writefile(DEFAULT_FILE, safeName(name))
    end)
    return ok, ok and ("Default set: " .. safeName(name)) or tostring(result)
end

local function getDefault()
    if not readfile or not isfile then return nil end
    local ok, exists = pcall(isfile, DEFAULT_FILE)
    if not ok or not exists then return nil end
    local readOK, value = pcall(readfile, DEFAULT_FILE)
    if readOK then return safeName(value) end
    return nil
end

-- ORIGINAL PROPERTY SNAPSHOTS

local function remember(object, property)
    local saved = State.Snapshots[object]
    if not saved then
        saved = {}
        State.Snapshots[object] = saved
    end

    if saved[property] == nil then
        local ok, value = pcall(function()
            return object[property]
        end)
        if ok then saved[property] = value end
    end
end

local function setProperty(object, property, value)
    if not object then return false end
    local okParent, parent = pcall(function() return object.Parent end)
    if not okParent or parent == nil then return false end

    remember(object, property)
    local ok = pcall(function()
        object[property] = value
    end)
    if ok then
        State.Changed += 1
        return true
    end
    return false
end

local function restoreProperties()
    local restored = 0
    for object, properties in pairs(State.Snapshots) do
        local okParent, parent = pcall(function() return object.Parent end)
        if okParent and parent ~= nil then
            for property, value in pairs(properties) do
                local ok = pcall(function()
                    object[property] = value
                end)
                if ok then restored += 1 end
            end
        end
    end

    State.Snapshots = {}
    State.Changed = 0
    return restored
end

local function restoreSky()
    if State.Sky then
        pcall(function() State.Sky:Destroy() end)
    end
    State.Sky = nil

    for _, sky in ipairs(State.OriginalSkies) do
        if sky then
            pcall(function()
                if sky.Parent == nil then sky.Parent = Lighting end
            end)
        end
    end
    State.OriginalSkies = {}
end

local function restoreAll()
    local count = restoreProperties()
    restoreSky()
    log("Restored " .. count .. " properties")
    return count
end

-- ASSET CACHE / URL HANDLING

local function hashString(value)
    local hash = 0
    for index = 1, #value do
        hash = (hash * 31 + string.byte(value, index)) % 2147483647
    end
    return tostring(hash)
end

local function fileExtension(url)
    local path = tostring(url):match("^https?://[^%?]+") or tostring(url)
    local ext = path:match("%.([%w]+)$")
    ext = ext and ext:lower() or "asset"
    if #ext > 8 then ext = "asset" end
    return ext
end

local function resolveAsset(value)
    if value == nil then return nil end
    local source = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
    if source == "" then return nil end

    if source:match("^rbxassetid://") or source:match("^rbxasset://") then
        return source
    end
    if source:match("^%d+$") then
        return "rbxassetid://" .. source
    end
    if not source:match("^https?://") then
        return nil
    end

    if not (writefile and isfile and getasset) then
        warnLog("CDN URL skipped: executor needs writefile, isfile and getcustomasset/getsynasset")
        return nil
    end

    local path = "AxomJB_V9_" .. hashString(source) .. "." .. fileExtension(source)
    local ok, result = pcall(function()
        local exists = isfile(path)
        if not exists then
            local data = game:HttpGet(source)
            assert(type(data) == "string" and #data > 0, "Empty download")
            writefile(path, data)
        end
        return getasset(path)
    end)

    if ok and result then return result end
    warnLog("Asset download failed: " .. tostring(result))
    return nil
end

-- JSON/TXT PACK PARSER

local function cleanJSON(contents)
    local source = tostring(contents or "")
    source = source:gsub("^\239\187\191", "")
    source = source:gsub("^%s+", ""):gsub("%s+$", "")
    source = source:gsub("^```[Jj][Ss][Oo][Nn]%s*", "")
    source = source:gsub("^```%s*", "")
    source = source:gsub("%s*```$", "")
    return source
end

local function firstValue(...)
    for index = 1, select("#", ...) do
        local value = select(index, ...)
        if value ~= nil and value ~= "" then return value end
    end
    return nil
end

local function ruleIDs(rule)
    local ids = firstValue(
        rule.replace_ids, rule.target_ids, rule.ids, rule.replace,
        rule.from_ids, rule.from, rule.target_id, rule.replace_id
    )
    if type(ids) == "string" or type(ids) == "number" then
        ids = {ids}
    end

    local result = {}
    if type(ids) == "table" then
        for _, value in ipairs(ids) do
            local id = tostring(value):match("%d+")
            if id then table.insert(result, id) end
        end
    end
    return result
end

local function ruleReplacement(rule)
    return firstValue(
        rule.cdn_url, rule.url, rule.asset_url, rule.image_url,
        rule.sound_url, rule.asset_id, rule.replacement_id,
        rule.new_id, rule.to, rule.replacement
    )
end

local function normalizeRules(data)
    if type(data) ~= "table" then
        return nil, "Pack must be a JSON object"
    end

    local source = firstValue(data.replacement_rules, data.rules, data.replacements)
    if type(source) ~= "table" then
        if data.replace_ids or data.target_ids or data.ids or data.target_id then
            source = {data}
        else
            source = {}
        end
    end

    local flattened = {}
    local function add(rule)
        if type(rule) ~= "table" then return end
        if rule.enabled == false then return end

        if (rule.type == "group" or rule.kind == "group")
            and type(rule.children) == "table" then
            for _, child in ipairs(rule.children) do add(child) end
            return
        end

        local name = string.lower(tostring(rule.name or rule.type or ""))
        if name:find("font") then
            return
        end
        if string.lower(tostring(rule.mode or "")) == "local" then
            return
        end

        table.insert(flattened, rule)
    end

    for _, rule in ipairs(source) do add(rule) end
    return flattened
end

local function prepareRules(rules)
    State.Prepared = {}
    local skipped = 0

    for _, rule in ipairs(rules) do
        local replacementValue = ruleReplacement(rule)
        local ids = ruleIDs(rule)

        if replacementValue and #ids > 0 then
            local resolved = resolveAsset(replacementValue)
            if resolved then
                table.insert(State.Prepared, {
                    Rule = rule,
                    IDs = ids,
                    Asset = resolved
                })
            else
                skipped += 1
            end
        else
            skipped += 1
        end
    end
    return skipped
end

local function getObjectProperties(object)
    if object:IsA("Decal") or object:IsA("Texture") then
        return {"Texture"}
    elseif object:IsA("ImageLabel") or object:IsA("ImageButton") then
        return {"Image"}
    elseif object:IsA("MeshPart") then
        return {"TextureID"}
    elseif object:IsA("SpecialMesh") then
        return {"TextureId"}
    elseif object:IsA("SurfaceAppearance") then
        return {"ColorMap", "MetalnessMap", "NormalMap", "RoughnessMap"}
    elseif object:IsA("Sound") then
        return {"SoundId"}
    end
    return {}
end

local function objectMatches(object, item)
    local properties = getObjectProperties(object)
    for _, property in ipairs(properties) do
        local ok, current = pcall(function() return object[property] end)
        if ok then
            local currentID = tostring(current):match("%d+")
            if currentID then
                for _, targetID in ipairs(item.IDs) do
                    if currentID == targetID then
                        return property
                    end
                end
            end
        end
    end
    return nil
end

local function applyObject(object)
    if not State.Running or not object then return end

    for _, item in ipairs(State.Prepared) do
        local property = objectMatches(object, item)
        if property then
            if setProperty(object, property, item.Asset) then
                State.Matched += 1
            end
        end
    end
end

local function scanGame()
    if State.Applying or not State.Running then return 0 end
    State.Applying = true
    State.Matched = 0

    local count = 0
    local ok, err = pcall(function()
        for _, object in ipairs(game:GetDescendants()) do
            if not State.Running then break end
            applyObject(object)
            count += 1
            if count % 350 == 0 then task.wait() end
        end
    end)

    State.Applying = false
    State.Scanned = count
    if not ok then warnLog("Scan error: " .. tostring(err)) end
    log("Scanned " .. count .. " objects; matched " .. State.Matched)
    return count
end

-- SKYBOX SUPPORT

local SKY_FACE_KEYS = {
    BK = "SkyboxBk", DN = "SkyboxDn", FT = "SkyboxFt",
    LF = "SkyboxLf", RT = "SkyboxRt", UP = "SkyboxUp"
}

local function getSkyFaceTable(data)
    if type(data) ~= "table" then return nil end
    local faces = data.faces or data.skybox_faces or data
    if type(faces) ~= "table" then return nil end
    return faces
end

local function applySkybox(data)
    local faces = getSkyFaceTable(data)
    if not faces then return false, "Skybox data missing" end

    local sky = Instance.new("Sky")
    sky.Name = "AxomJBCustomSky"
    local count = 0

    for short, full in pairs(SKY_FACE_KEYS) do
        local value = firstValue(faces[full], faces[short], faces[string.lower(short)])
        if value then
            local resolved = resolveAsset(value)
            if resolved then
                local ok = pcall(function() sky[full] = resolved end)
                if ok then count += 1 end
            end
        end
    end

    if count ~= 6 then
        sky:Destroy()
        return false, "Skybox needs six valid faces (BK/DN/FT/LF/RT/UP)"
    end

    -- Preserve the original skies once, then replace only the active custom sky.
    if #State.OriginalSkies == 0 then
        for _, child in ipairs(Lighting:GetChildren()) do
            if child:IsA("Sky") and child ~= State.Sky then
                table.insert(State.OriginalSkies, child)
                pcall(function() child.Parent = nil end)
            end
        end
    end

    if State.Sky then pcall(function() State.Sky:Destroy() end) end
    sky.Parent = Lighting
    State.Sky = sky
    return true
end

-- PACK APPLY / RESET

local function decodePack(contents)
    local cleaned = cleanJSON(contents)
    if cleaned == "" then return nil, "Paste JSON/TXT pack contents first" end

    local ok, data = pcall(function()
        return HttpService:JSONDecode(cleaned)
    end)
    if not ok then return nil, "Invalid JSON: " .. tostring(data) end
    if type(data) ~= "table" then return nil, "Pack root must be an object" end
    return data
end

local function loadPack(contents)
    local data, decodeError = decodePack(contents)
    if not data then return false, decodeError end

    local rules, ruleError = normalizeRules(data)
    if not rules then return false, ruleError end

    restoreAll()
    State.Prepared = {}
    State.Changed = 0
    State.Matched = 0

    local skipped = prepareRules(rules)

    local skyData = data.skybox or data.sky_box or data.Skybox
    local skyMessage = ""
    if skyData then
        local skyOK, skyError = applySkybox(skyData)
        skyMessage = skyOK and " | skybox applied" or (" | skybox: " .. skyError)
    end

    scanGame()
    State.PackText = tostring(contents or "")
    State.LastApply = os.clock()

    return true, ("Loaded %d rules; %d prepared; %d skipped%s"):format(
        #rules, #State.Prepared, skipped, skyMessage
    )
end

local function resetPack()
    restoreAll()
    State.Prepared = {}
    State.PackText = ""
    State.Matched = 0
    State.Scanned = 0
end

-- GUI

local function createGUI()
    local parent
    local gethui = api("gethui")
    if gethui then
        pcall(function() parent = gethui() end)
    end
    if not parent then
        pcall(function() parent = game:GetService("CoreGui") end)
    end
    if not parent then
        parent = Player:WaitForChild("PlayerGui")
    end

    -- Remove a stale GUI left by an interrupted prior run.
    pcall(function()
        local existing = parent:FindFirstChild(GUI_NAME)
        if existing then existing:Destroy() end
    end)

    local gui = Instance.new("ScreenGui")
    gui.Name = GUI_NAME
    gui.ResetOnSpawn = false
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.Parent = parent
    State.Gui = gui

    local main = Instance.new("Frame")
    main.Name = "Main"
    main.Size = UDim2.fromOffset(700, 420)
    main.Position = UDim2.new(0.5, -297.5, 0.5, -178.5)

    local mainScale = Instance.new("UIScale")
    mainScale.Scale = 0.85
    mainScale.Parent = main

    main.BackgroundColor3 = Color3.fromRGB(17, 17, 26)
    main.BorderSizePixel = 0
    main.ClipsDescendants = true
    main.Parent = gui

    local mainCorner = Instance.new("UICorner")
    mainCorner.CornerRadius = UDim.new(0, 14)
    mainCorner.Parent = main

    local outline = Instance.new("UIStroke")
    outline.Color = Color3.fromRGB(123, 88, 225)
    outline.Thickness = 1.5
    outline.Parent = main

    local header = Instance.new("TextButton")
    header.Size = UDim2.new(1, 0, 0, 40)
    header.BackgroundColor3 = Color3.fromRGB(39, 30, 63)
    header.Text = "  AXOMJB  /  UNIVERSAL VISUAL V9"
    header.TextXAlignment = Enum.TextXAlignment.Left
    header.TextColor3 = Color3.new(1, 1, 1)
    header.Font = Enum.Font.GothamBold
    header.TextSize = 13
    header.AutoButtonColor = false
    header.Parent = main

    local dragging = false
    local dragLocked = false
    local dragStart
    local startPosition

    connect(header.InputBegan, function(input)
        if not dragLocked and (input.UserInputType == Enum.UserInputType.Touch
            or input.UserInputType == Enum.UserInputType.MouseButton1) then
            dragging = true
            dragStart = input.Position
            startPosition = main.Position
        end
    end)

    connect(UserInputService.InputChanged, function(input)
        if dragging and (
            input.UserInputType == Enum.UserInputType.Touch
            or input.UserInputType == Enum.UserInputType.MouseMovement
        ) then
            local delta = input.Position - dragStart
            main.Position = UDim2.new(
                startPosition.X.Scale, startPosition.X.Offset + delta.X,
                startPosition.Y.Scale, startPosition.Y.Offset + delta.Y
            )
        end
    end)

    connect(UserInputService.InputEnded, function(input)
        if input.UserInputType == Enum.UserInputType.Touch
            or input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = false
        end
    end)

    local sideOpen = Instance.new("TextButton")
    sideOpen.Name = "OpenVisualUI"
    sideOpen.Size = UDim2.fromOffset(42, 112)
    sideOpen.AnchorPoint = Vector2.new(1, 0.5)
    sideOpen.Position = UDim2.new(1, 0, 0.5, 0)
    sideOpen.BackgroundColor3 = Color3.fromRGB(75, 55, 145)
    sideOpen.Text = "OPEN\\nUI"
    sideOpen.TextColor3 = Color3.new(1, 1, 1)
    sideOpen.TextSize = 11
    sideOpen.Font = Enum.Font.GothamBold
    sideOpen.TextWrapped = true
    sideOpen.Visible = false
    sideOpen.Parent = gui

    local sideCorner = Instance.new("UICorner")
    sideCorner.CornerRadius = UDim.new(0, 9)
    sideCorner.Parent = sideOpen

    connect(sideOpen.Activated, function()
        main.Visible = true
        sideOpen.Visible = false
    end)

    local function makeHeaderControl(label, xOffset, callback)
        local control = Instance.new("TextButton")
        control.Size = UDim2.fromOffset(54, 26)
        control.Position = UDim2.new(1, xOffset, 0, 7)
        control.AnchorPoint = Vector2.new(1, 0)
        control.BackgroundColor3 = Color3.fromRGB(67, 55, 105)
        control.Text = label
        control.TextColor3 = Color3.new(1, 1, 1)
        control.TextSize = 9
        control.Font = Enum.Font.GothamBold
        control.AutoButtonColor = true
        control.Parent = header
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 6)
        corner.Parent = control
        connect(control.Activated, callback)
        return control
    end

    local lockHeaderButton
    local function updateLockButtons()
        local label = dragLocked and "LOCKED" or "LOCK"
        if lockHeaderButton then
            lockHeaderButton.Text = label
            lockHeaderButton.BackgroundColor3 = dragLocked
                and Color3.fromRGB(145, 75, 65)
                or Color3.fromRGB(67, 105, 85)
        end
    end

    lockHeaderButton = makeHeaderControl("LOCK", -120, function()
        dragLocked = not dragLocked
        dragging = false
        updateLockButtons()
    end)

    makeHeaderControl("HIDE", -60, function()
        main.Visible = false
        sideOpen.Visible = true
    end)

    local status = Instance.new("TextLabel")
    status.Position = UDim2.fromOffset(10, 385)
    status.Size = UDim2.new(1, -20, 0, 25)
    status.BackgroundColor3 = Color3.fromRGB(27, 27, 39)
    status.Text = "READY  |  Paste a pack to begin"
    status.TextColor3 = Color3.fromRGB(195, 195, 210)
    status.Font = Enum.Font.Gotham
    status.TextSize = 10
    status.TextTruncate = Enum.TextTruncate.AtEnd
    status.Parent = main

    local statusCorner = Instance.new("UICorner")
    statusCorner.CornerRadius = UDim.new(0, 7)
    statusCorner.Parent = status

    local function setStatus(message)
        status.Text = tostring(message)
        log(message)
    end

    local tabHolder = Instance.new("Frame")
    tabHolder.Position = UDim2.fromOffset(9, 46)
    tabHolder.Size = UDim2.new(1, -18, 0, 32)
    tabHolder.BackgroundTransparency = 1
    tabHolder.Parent = main

    local tabGrid = Instance.new("UIGridLayout")
    tabGrid.CellSize = UDim2.new(1/7, -5, 0, 28)
    tabGrid.CellPadding = UDim2.fromOffset(5, 5)
    tabGrid.SortOrder = Enum.SortOrder.LayoutOrder
    tabGrid.Parent = tabHolder

    local pageHolder = Instance.new("Frame")
    pageHolder.Position = UDim2.fromOffset(10, 84)
    pageHolder.Size = UDim2.new(1, -20, 0, 290)
    pageHolder.BackgroundTransparency = 1
    pageHolder.Parent = main

    local pages, tabs, editors = {}, {}, {}
    local nameBox, configList

    local function makeButton(parentFrame, label, position, size, callback, color)
        local button = Instance.new("TextButton")
        button.Position = position
        button.Size = size
        button.BackgroundColor3 = color or Color3.fromRGB(62, 62, 88)
        button.Text = label
        button.TextColor3 = Color3.new(1, 1, 1)
        button.Font = Enum.Font.GothamBold
        button.TextSize = 11
        button.AutoButtonColor = true
        button.Parent = parentFrame

        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 7)
        corner.Parent = button

        connect(button.Activated, callback)
        return button
    end

    local function makeLabel(parentFrame, value, position, size)
        local label = Instance.new("TextLabel")
        label.Position = position
        label.Size = size
        label.BackgroundTransparency = 1
        label.Text = value
        label.TextColor3 = Color3.fromRGB(205, 205, 220)
        label.Font = Enum.Font.Gotham
        label.TextSize = 11
        label.TextWrapped = true
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.Parent = parentFrame
        return label
    end

    local function makePage(name)
        local page = Instance.new("Frame")
        page.Name = name
        page.Size = UDim2.fromScale(1, 1)
        page.BackgroundTransparency = 1
        page.Visible = false
        page.Parent = pageHolder
        pages[name] = page
        return page
    end

    local function syncEditors(value, source)
        State.PackText = value
        for _, editor in ipairs(editors) do
            if editor ~= source and editor.Text ~= value then
                editor.Text = value
            end
        end
    end

    local function makeEditor(page, title)
        makeLabel(page, title, UDim2.fromOffset(2, 0), UDim2.new(1, -4, 0, 24))

        local box = Instance.new("TextBox")
        box.Position = UDim2.fromOffset(0, 27)
        box.Size = UDim2.new(1, 0, 1, -29)
        box.BackgroundColor3 = Color3.fromRGB(27, 27, 41)
        box.TextColor3 = Color3.new(1, 1, 1)
        box.PlaceholderColor3 = Color3.fromRGB(145, 145, 160)
        box.PlaceholderText = "Paste the complete JSON/TXT pack here..."
        box.Text = State.PackText
        box.ClearTextOnFocus = false
        box.MultiLine = true
        box.TextWrapped = false
        box.TextXAlignment = Enum.TextXAlignment.Left
        box.TextYAlignment = Enum.TextYAlignment.Top
        box.Font = Enum.Font.Code
        box.TextSize = 11
        box.Parent = page

        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 7)
        corner.Parent = box

        table.insert(editors, box)
        connect(box:GetPropertyChangedSignal("Text"), function()
            if box.Text ~= State.PackText then
                syncEditors(box.Text, box)
            end
        end)
        return box
    end

    local function switchPage(name)
        State.ActiveChannel = name
        for pageName, page in pairs(pages) do
            page.Visible = pageName == name
        end
        for tabName, tab in pairs(tabs) do
            tab.BackgroundColor3 = tabName == name
                and Color3.fromRGB(105, 78, 195)
                or Color3.fromRGB(37, 37, 53)
        end
    end

    local channels = {"HOME", "TEXTURES", "SKYBOX", "SOUNDS", "CONFIGS", "SETTINGS", "GUI"}
    for index, name in ipairs(channels) do
        local tab = Instance.new("TextButton")
        tab.Name = name .. "Tab"
        tab.BackgroundColor3 = Color3.fromRGB(37, 37, 53)
        tab.Text = name
        tab.TextColor3 = Color3.new(1, 1, 1)
        tab.Font = Enum.Font.GothamBold
        tab.TextSize = 10
        tab.LayoutOrder = index
        tab.Parent = tabHolder

        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 6)
        corner.Parent = tab

        tabs[name] = tab
        connect(tab.Activated, function() switchPage(name) end)
    end

    -- HOME
    local home = makePage("HOME")
    makeLabel(home, "UNIVERSAL VISUAL CONTROL", UDim2.fromOffset(2, 5), UDim2.new(1, -4, 0, 24))
    makeLabel(home,
        "Paste a pack in any editor tab, then apply it here. TXT is accepted when it contains JSON.",
        UDim2.fromOffset(2, 31), UDim2.new(1, -4, 0, 42))

    makeButton(home, "APPLY CURRENT PACK", UDim2.fromOffset(0, 82),
        UDim2.new(1, 0, 0, 38), function()
            local ok, message = loadPack(State.PackText)
            setStatus(ok and message or ("ERROR: " .. message))
        end, Color3.fromRGB(95, 70, 190))

    makeButton(home, "RESET ORIGINAL ASSETS", UDim2.fromOffset(0, 128),
        UDim2.new(1, 0, 0, 38), function()
            restoreAll()
            State.Prepared = {}
            setStatus("Original assets restored")
        end, Color3.fromRGB(155, 92, 48))

    makeButton(home, "RESCAN GAME", UDim2.fromOffset(0, 174),
        UDim2.new(1, 0, 0, 38), function()
            local count = scanGame()
            setStatus("Rescan finished: " .. count .. " objects")
        end, Color3.fromRGB(45, 115, 105))

    makeButton(home, "RESET PACK / CLEAR EDITORS", UDim2.fromOffset(0, 220),
        UDim2.new(1, 0, 0, 34), function()
            resetPack()
            for _, editor in ipairs(editors) do editor.Text = "" end
            setStatus("Pack cleared and original assets restored")
        end, Color3.fromRGB(95, 65, 75))

    makeLabel(home, "V9  |  V4 parser + V8 channels + local configs",
        UDim2.fromOffset(2, 260), UDim2.new(1, -4, 0, 18))

    -- EDITOR CHANNELS (shared pack text)
    local textures = makePage("TEXTURES")
    makeEditor(textures, "TEXTURE / IMAGE / MESH / SURFACE RULES")

    local skybox = makePage("SKYBOX")
    makeEditor(skybox, "FULL PACK JSON WITH A SIX-FACE SKYBOX")

    local sounds = makePage("SOUNDS")
    makeEditor(sounds, "SOUND RULES  •  FULL PACK JSON")

    -- CONFIGS
    local configs = makePage("CONFIGS")
    makeLabel(configs, "LOCAL CONFIG MANAGER", UDim2.fromOffset(2, 0),
        UDim2.new(1, -4, 0, 22))

    nameBox = Instance.new("TextBox")
    nameBox.Position = UDim2.fromOffset(0, 27)
    nameBox.Size = UDim2.new(1, 0, 0, 32)
    nameBox.BackgroundColor3 = Color3.fromRGB(29, 29, 42)
    nameBox.TextColor3 = Color3.new(1, 1, 1)
    nameBox.PlaceholderText = "Config name..."
    nameBox.Text = ""
    nameBox.ClearTextOnFocus = false
    nameBox.Font = Enum.Font.Gotham
    nameBox.TextSize = 12
    nameBox.Parent = configs

    local nameCorner = Instance.new("UICorner")
    nameCorner.CornerRadius = UDim.new(0, 6)
    nameCorner.Parent = nameBox

    makeButton(configs, "SAVE", UDim2.fromOffset(0, 68),
        UDim2.new(0.32, -3, 0, 34), function()
            local ok, message = saveConfig(nameBox.Text, State.PackText)
            setStatus(message)
        end, Color3.fromRGB(45, 115, 90))

    makeButton(configs, "LOAD", UDim2.new(0.34, 0, 0, 68),
        UDim2.new(0.32, -3, 0, 34), function()
            local contents, err = loadConfig(nameBox.Text)
            if contents then
                syncEditors(contents, nil)
                setStatus("Config loaded into editor; press APPLY on HOME")
            else
                setStatus(err)
            end
        end, Color3.fromRGB(65, 95, 160))

    makeButton(configs, "DELETE", UDim2.new(0.68, 0, 0, 68),
        UDim2.new(0.32, 0, 0, 34), function()
            local ok, message = deleteConfig(nameBox.Text)
            setStatus(message)
        end, Color3.fromRGB(145, 55, 65))

    makeButton(configs, "LIST CONFIGS", UDim2.fromOffset(0, 110),
        UDim2.new(0.49, -3, 0, 34), function()
            local names = listConfigs()
            local output = #names > 0 and table.concat(names, ", ") or "No configs found"
            if configList then configList.Text = output end
            setStatus(output)
        end, Color3.fromRGB(70, 80, 110))

    makeButton(configs, "SET DEFAULT", UDim2.new(0.51, 0, 0, 110),
        UDim2.new(0.49, 0, 0, 34), function()
            local ok, message = setDefault(nameBox.Text)
            setStatus(message)
        end, Color3.fromRGB(100, 80, 155))

    makeButton(configs, "LOAD DEFAULT + APPLY", UDim2.fromOffset(0, 152),
        UDim2.new(1, 0, 0, 34), function()
            local name = getDefault()
            if not name then
                setStatus("No default config set")
                return
            end

            local contents, err = loadConfig(name)
            if not contents then setStatus(err) return end

            nameBox.Text = name
            syncEditors(contents, nil)
            local ok, message = loadPack(contents)
            setStatus(ok and ("Default applied: " .. message) or message)
        end, Color3.fromRGB(65, 115, 135))

    configList = makeLabel(configs, "Saved config names appear here.",
        UDim2.fromOffset(2, 198), UDim2.new(1, -4, 0, 60))

    -- SETTINGS
    local settings = makePage("SETTINGS")
    makeLabel(settings, "PERFORMANCE & GUI SETTINGS", UDim2.fromOffset(2, 4),
        UDim2.new(1, -4, 0, 24))

    local autoButton
    local function updateAutoButton()
        if not autoButton then return end
        autoButton.Text = State.AutoReapply and "AUTO REAPPLY: ON" or "AUTO REAPPLY: OFF"
        autoButton.BackgroundColor3 = State.AutoReapply
            and Color3.fromRGB(45, 120, 85)
            or Color3.fromRGB(100, 65, 65)
    end

    autoButton = makeButton(settings, "AUTO REAPPLY: ON",
        UDim2.fromOffset(0, 42), UDim2.new(1, 0, 0, 38), function()
            State.AutoReapply = not State.AutoReapply
            updateAutoButton()
            setStatus(State.AutoReapply and "Auto reapply enabled" or "Auto reapply disabled")
        end)
    updateAutoButton()

    makeButton(settings, "CLEAR EDITOR ONLY", UDim2.fromOffset(0, 90),
        UDim2.new(1, 0, 0, 36), function()
            syncEditors("", nil)
            setStatus("Editor cleared; current replacements remain until reset")
        end, Color3.fromRGB(65, 65, 80))

    makeButton(settings, "REMOVE GUI + STOP", UDim2.fromOffset(0, 136),
        UDim2.new(1, 0, 0, 36), function()
            State.Stop()
        end, Color3.fromRGB(145, 55, 65))

    makeLabel(settings,
        "Auto reapply watches newly added objects and rescans periodically. CDN assets are cached locally.",
        UDim2.fromOffset(2, 188), UDim2.new(1, -4, 0, 55))

    -- GUI CHANNEL
    local guiPage = makePage("GUI")
    makeLabel(guiPage, "GUI POSITION & VISIBILITY", UDim2.fromOffset(2, 4),
        UDim2.new(1, -4, 0, 24))

    local guiLockButton
    local function updateGuiLockButton()
        if not guiLockButton then return end
        guiLockButton.Text = dragLocked and "POSITION LOCK: ON" or "POSITION LOCK: OFF"
        guiLockButton.BackgroundColor3 = dragLocked
            and Color3.fromRGB(145, 75, 65)
            or Color3.fromRGB(67, 105, 85)
        updateLockButtons()
    end

    guiLockButton = makeButton(guiPage, "POSITION LOCK: OFF",
        UDim2.fromOffset(0, 42), UDim2.new(0.48, -5, 0, 38), function()
            dragLocked = not dragLocked
            dragging = false
            updateGuiLockButton()
        end)
    updateGuiLockButton()

    makeButton(guiPage, "HIDE UI TO SIDE",
        UDim2.new(0.52, 5, 0, 42), UDim2.new(0.48, -5, 0, 38), function()
            main.Visible = false
            sideOpen.Visible = true
        end, Color3.fromRGB(85, 65, 145))

    makeButton(guiPage, "OPEN UI",
        UDim2.fromOffset(0, 90), UDim2.new(0.48, -5, 0, 38), function()
            main.Visible = true
            sideOpen.Visible = false
        end, Color3.fromRGB(45, 115, 105))

    makeButton(guiPage, "RESET POSITION",
        UDim2.new(0.52, 5, 0, 90), UDim2.new(0.48, -5, 0, 38), function()
            main.Position = UDim2.new(0.5, -297.5, 0.5, -178.5)
            setStatus("GUI position reset")
        end, Color3.fromRGB(65, 85, 125))

    makeLabel(guiPage,
        "Drag the top bar to move the panel. Lock its position to prevent accidental movement. When hidden, use the OPEN UI handle on the right edge of the screen.",
        UDim2.fromOffset(2, 145), UDim2.new(1, -4, 0, 70))

    switchPage("HOME")
end

-- AUTOMATIC REAPPLICATION

connect(game.DescendantAdded, function(object)
    task.defer(function()
        if State.Running and State.AutoReapply and #State.Prepared > 0 then
            applyObject(object)
        end
    end)
end)

-- Sky replacement may be removed/replaced by a place transition or another script.
connect(Lighting.ChildRemoved, function(child)
    if child == State.Sky then
        task.defer(function()
            if State.Running and State.AutoReapply and State.Sky then
                pcall(function()
                    if State.Sky and State.Sky.Parent == nil then
                        State.Sky.Parent = Lighting
                    end
                end)
            end
        end)
    end
end)

task.spawn(function()
    while State.Running do
        task.wait(5)
        if State.Running and State.AutoReapply then
            if #State.Prepared > 0 then
                scanGame()
            end
            -- Re-add custom sky if Lighting has been rebuilt.
            if State.Sky and State.Sky.Parent == nil then
                pcall(function() State.Sky.Parent = Lighting end)
            end
        end
    end
end)

function State.Stop()
    if not State.Running then return end
    State.Running = false
    disconnectAll()
    restoreAll()

    if State.Gui then
        pcall(function() State.Gui:Destroy() end)
    end

    ENV[KEY] = nil
    log("Stopped, restored originals and removed GUI")
end

createGUI()
log("V9 ready. Universal visual GUI loaded.")
