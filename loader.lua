local EnvironmentBase = {
    Players = game:GetService("Players"),
    CoreGui = game:GetService("CoreGui"),
    UIS = game:GetService("UserInputService"),
    TweenService = game:GetService("TweenService"),
    HttpService = game:GetService("HttpService"),
    StarterGui = game:GetService("StarterGui")
}

local LocalPlayer = EnvironmentBase.Players.LocalPlayer
local BASE_URL = "https://projectcnuvem.com/data/robloxscripts"
local MODULE_ENDPOINTS = {
    ui_library = BASE_URL .. "/ui_library.lua",
    hub_shell = BASE_URL .. "/hub_shell.lua",
    main = BASE_URL .. "/main.lua"
}

local AUTH_FOLDER_NAME = "ProjectOficial"
local AUTH_FILE_NAME = AUTH_FOLDER_NAME .. "/AuthKey.json"
local FIXED_ACCESS_KEY = "UNIVERSE-TEST-KEY"
local SESSION_TTL_SECONDS = 60 * 60 * 12
local AUTH_SALT = "UniverseAuthSalt_v1_7f4a2f19"
local BOOTSTRAP_BRIDGE_KEY = "__SYSTEMSYNC_BOOTSTRAP_BRIDGE_V1"
local LOAD_REPORT_FOLDER = AUTH_FOLDER_NAME .. "/LoadReports"

if getgenv().SystemCore_Unload then
    pcall(getgenv().SystemCore_Unload)
end

getgenv().ProjectHubShell = nil
getgenv().ProjectLibrary = nil
getgenv()[BOOTSTRAP_BRIDGE_KEY] = nil

local function resolveTargetGui()
    local targetGui
    local success = pcall(function()
        targetGui = type(gethui) == "function" and gethui() or EnvironmentBase.CoreGui
        local probe = Instance.new("Folder")
        probe.Parent = targetGui
        probe:Destroy()
    end)

    if success and targetGui then
        return targetGui
    end

    return LocalPlayer and LocalPlayer:FindFirstChild("PlayerGui") or EnvironmentBase.CoreGui
end

local targetGui = resolveTargetGui()

local function notify(title, text, duration)
    pcall(function()
        EnvironmentBase.StarterGui:SetCore("SendNotification", {
            Title = title,
            Text = text,
            Duration = duration or 4
        })
    end)
end

local function trim(text)
    if type(text) ~= "string" then
        return ""
    end

    return text:match("^%s*(.-)%s*$") or ""
end

local function getUnixTime()
    local ok, now = pcall(function()
        return DateTime.now().UnixTimestamp
    end)
    if ok and type(now) == "number" then
        return now
    end
    return os.time()
end

local function hashString(text)
    local hash = 2166136261
    for i = 1, #text do
        hash = bit32.bxor(hash, string.byte(text, i))
        hash = (hash * 16777619) % 4294967296
    end
    return string.format("%08x", hash)
end

local function getExecutorName()
    if type(identifyexecutor) == "function" then
        local ok, name = pcall(identifyexecutor)
        if ok and type(name) == "string" and name ~= "" then
            return name
        end
    end
    return "unknown"
end

local function ensureReportFolder(path)
    if type(makefolder) ~= "function" or type(isfolder) ~= "function" then
        return false
    end

    local current = ""
    local normalized = tostring(path or ""):gsub("\\", "/")
    for segment in string.gmatch(normalized, "[^/]+") do
        current = current == "" and segment or (current .. "/" .. segment)
        pcall(function()
            if not isfolder(current) then
                makefolder(current)
            end
        end)
    end

    return current ~= ""
end

local function sanitizeLoadReportToken(value)
    local sanitized = tostring(value or "unknown"):gsub("[^%w%._%-]", "_")
    if sanitized == "" then
        return "unknown"
    end
    return sanitized
end

local function classifyRemoteLoadFailure(stage, detail)
    local lowered = string.lower(tostring(detail or ""))
    if stage == "fetch" then
        return "fetch"
    end

    if stage == "compile" then
        if string.find(lowered, "unexpected symbol", 1, true)
            or string.find(lowered, "expected", 1, true)
            or string.find(lowered, "syntax", 1, true)
            or string.find(lowered, "unfinished", 1, true)
            or string.find(lowered, "near", 1, true) then
            return "parse"
        end

        if string.find(lowered, "invalid", 1, true)
            or string.find(lowered, "malformed", 1, true)
            or string.find(lowered, "byte", 1, true)
            or string.find(lowered, "utf", 1, true) then
            return "corruption"
        end

        return "compile"
    end

    if stage == "execute" then
        return "execution"
    end

    return tostring(stage or "unknown")
end

local function writeLocalLoadFailureReport(target, stage, detail, sourceUrl)
    if type(writefile) ~= "function" then
        return false
    end

    ensureReportFolder(AUTH_FOLDER_NAME)
    ensureReportFolder(LOAD_REPORT_FOLDER)

    local report = {
        Version = 1,
        Scope = "host",
        Target = tostring(target or "unknown"),
        Stage = tostring(stage or "unknown"),
        Classification = classifyRemoteLoadFailure(stage, detail),
        Detail = tostring(detail or ""),
        SourceUrl = sourceUrl and tostring(sourceUrl) or nil,
        Timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        UnixTime = getUnixTime(),
        UserId = LocalPlayer and LocalPlayer.UserId or 0,
        Executor = getExecutorName()
    }

    local encoded
    local ok = pcall(function()
        encoded = EnvironmentBase.HttpService:JSONEncode(report)
    end)
    if not ok or type(encoded) ~= "string" then
        return false
    end

    local baseName = table.concat({
        sanitizeLoadReportToken(report.Target),
        sanitizeLoadReportToken(report.Stage),
        sanitizeLoadReportToken(report.Classification)
    }, "-")

    pcall(function()
        writefile(LOAD_REPORT_FOLDER .. "/" .. baseName .. "-latest.json", encoded)
    end)

    local historyPath = LOAD_REPORT_FOLDER .. "/" .. tostring(report.UnixTime) .. "-" .. baseName .. ".json"
    local wrote = pcall(function()
        writefile(historyPath, encoded)
    end)

    return wrote
end

local function warnRemoteLoadFailure(target, stage, detail, sourceUrl)
    local classification = classifyRemoteLoadFailure(stage, detail)
    writeLocalLoadFailureReport(target, stage, detail, sourceUrl)
    warn("[Host] Remote module load failed | target=" .. tostring(target) .. " | stage=" .. tostring(stage) .. " | class=" .. tostring(classification) .. " | detail=" .. tostring(detail))
end

local function getBindingHash()
    local userId = LocalPlayer and LocalPlayer.UserId or 0
    local bindingSeed = table.concat({
        tostring(userId),
        getExecutorName()
    }, "::")
    return hashString(bindingSeed)
end

local function signSession(session)
    return hashString(table.concat({
        tostring(session.Version or ""),
        tostring(session.AuthType or ""),
        tostring(session.SessionToken or ""),
        tostring(session.IssuedAt or ""),
        tostring(session.ExpiresAt or ""),
        tostring(session.BindingHash or ""),
        AUTH_SALT
    }, "::"))
end

local function signBootstrapState(state)
    return hashString(table.concat({
        tostring(state.Version or ""),
        tostring(state.SessionToken or ""),
        tostring(state.IssuedAt or ""),
        tostring(state.ExpiresAt or ""),
        tostring(state.BindingHash or ""),
        AUTH_SALT,
        "bootstrap"
    }, "::"))
end

local AuthManager = {}

function AuthManager:GetSessionPaths()
    return {AUTH_FILE_NAME}
end

function AuthManager:ClearSession()
    for _, path in ipairs(self:GetSessionPaths()) do
        if type(delfile) == "function" then
            pcall(function()
                if not isfile or isfile(path) then
                    delfile(path)
                end
            end)
        elseif type(writefile) == "function" then
            pcall(function()
                writefile(path, "")
            end)
        end
    end
end

function AuthManager:LoadSavedKey()
    if type(readfile) ~= "function" or type(isfile) ~= "function" then
        return nil
    end

    for _, path in ipairs(self:GetSessionPaths()) do
        local exists = pcall(function()
            return isfile(path)
        end)
        if exists and isfile(path) then
            local decoded
            local ok = pcall(function()
                decoded = EnvironmentBase.HttpService:JSONDecode(readfile(path))
            end)

            if ok and type(decoded) == "table" and type(decoded.Key) == "string" then
                local savedKey = trim(decoded.Key)
                if savedKey ~= "" then
                    return savedKey
                end
            end
        end
    end

    return nil
end

function AuthManager:IsSessionValid(session)
    if type(session) ~= "table" then
        return false, "missing_session"
    end

    if tonumber(session.Version) ~= 1 then
        return false, "invalid_version"
    end

    if type(session.SessionToken) ~= "string" or session.SessionToken == "" then
        return false, "missing_token"
    end

    if type(session.BindingHash) ~= "string" or session.BindingHash == "" then
        return false, "missing_binding"
    end

    local issuedAt = tonumber(session.IssuedAt)
    local expiresAt = tonumber(session.ExpiresAt)
    if not issuedAt or not expiresAt then
        return false, "invalid_time"
    end

    if expiresAt <= getUnixTime() then
        return false, "expired"
    end

    if session.BindingHash ~= getBindingHash() then
        return false, "binding_mismatch"
    end

    if session.Signature ~= signSession(session) then
        return false, "tampered"
    end

    return true
end

function AuthManager:ValidateKey(inputKey)
    local normalizedKey = trim(inputKey)
    if normalizedKey == "" then
        return nil, "empty_key"
    end

    if normalizedKey ~= FIXED_ACCESS_KEY then
        return nil, "invalid_key"
    end

    return {
        success = true,
        authType = "fixed_key",
        sessionToken = EnvironmentBase.HttpService:GenerateGUID(false),
        expiresAt = getUnixTime() + SESSION_TTL_SECONDS
    }
end

function AuthManager:CreateSession(authResult)
    local issuedAt = getUnixTime()
    local session = {
        Version = 1,
        AuthType = tostring(authResult and authResult.authType or "fixed_key"),
        SessionToken = tostring(authResult and authResult.sessionToken or EnvironmentBase.HttpService:GenerateGUID(false)),
        IssuedAt = issuedAt,
        ExpiresAt = tonumber(authResult and authResult.expiresAt) or (issuedAt + SESSION_TTL_SECONDS),
        BindingHash = getBindingHash()
    }

    session.Signature = signSession(session)
    return session
end

function AuthManager:SaveSession(session)
    if type(writefile) ~= "function" then
        return false
    end

    local encoded
    local ok = pcall(function()
        encoded = EnvironmentBase.HttpService:JSONEncode({
            Key = FIXED_ACCESS_KEY
        })
    end)
    if not ok or type(encoded) ~= "string" then
        return false
    end

    if type(makefolder) == "function" and type(isfolder) == "function" then
        pcall(function()
            if not isfolder(AUTH_FOLDER_NAME) then
                makefolder(AUTH_FOLDER_NAME)
            end
        end)
    end

    for _, path in ipairs(self:GetSessionPaths()) do
        local wrote = pcall(function()
            writefile(path, encoded)
        end)
        if wrote then
            return true
        end
    end

    return false
end

function AuthManager:PublishRuntimeBridge(session)
    local bridge = {
        Version = 1,
        SessionToken = session.SessionToken,
        IssuedAt = session.IssuedAt,
        ExpiresAt = session.ExpiresAt,
        BindingHash = session.BindingHash
    }
    bridge.Signature = signBootstrapState(bridge)
    getgenv()[BOOTSTRAP_BRIDGE_KEY] = bridge
    return bridge
end

function AuthManager:ClearRuntimeBridge()
    getgenv()[BOOTSTRAP_BRIDGE_KEY] = nil
end

local ModuleLoader = {}

function ModuleLoader:FetchModule(name, session)
    local valid, reason = AuthManager:IsSessionValid(session)
    if not valid then
        return false, "unauthorized_" .. tostring(reason)
    end

    local endpoint = MODULE_ENDPOINTS[name]
    if type(endpoint) ~= "string" then
        return false, "unknown_module"
    end

    local fetchUrl = endpoint .. "?t=" .. tostring(tick())
    local body
    local fetchSuccess = pcall(function()
        body = game:HttpGet(fetchUrl)
    end)

    if not fetchSuccess or type(body) ~= "string" or body == "" then
        return false, "fetch_failed"
    end

    return true, body
end

function ModuleLoader:ExecuteModule(name, session)
    local fetchSuccess, bodyOrErr = self:FetchModule(name, session)
    if not fetchSuccess then
        warnRemoteLoadFailure(name, "fetch", bodyOrErr, MODULE_ENDPOINTS[name])
        return false, bodyOrErr
    end

    if name == "main" then
        AuthManager:PublishRuntimeBridge(session)
    end

    local chunk, loadErr = loadstring(bodyOrErr, "=" .. tostring(name))
    if not chunk then
        if name == "main" then
            AuthManager:ClearRuntimeBridge()
        end
        warnRemoteLoadFailure(name, "compile", loadErr, MODULE_ENDPOINTS[name])
        return false, loadErr
    end

    local execSuccess, execErr = pcall(chunk)
    if not execSuccess then
        if name == "main" then
            AuthManager:ClearRuntimeBridge()
        end
        warnRemoteLoadFailure(name, "execute", execErr, MODULE_ENDPOINTS[name])
        return false, execErr
    end

    return true
end

local function buildAuthGate()
    if targetGui:FindFirstChild("SystemSyncAuthGate") then
        targetGui.SystemSyncAuthGate:Destroy()
    end

    local authGui = Instance.new("ScreenGui")
    authGui.Name = "SystemSyncAuthGate"
    authGui.IgnoreGuiInset = true
    authGui.ResetOnSpawn = false
    authGui.DisplayOrder = 2000
    authGui.ZIndexBehavior = Enum.ZIndexBehavior.Global
    authGui.Parent = targetGui

    local dimmer = Instance.new("Frame")
    dimmer.Size = UDim2.new(1, 0, 1, 0)
    dimmer.BackgroundColor3 = Color3.fromRGB(6, 6, 8)
    dimmer.BackgroundTransparency = 0.28
    dimmer.BorderSizePixel = 0
    dimmer.Parent = authGui

    local panel = Instance.new("Frame")
    panel.Name = "AuthPanel"
    panel.Size = UDim2.new(0, 420, 0, 320)
    panel.AnchorPoint = Vector2.new(0.5, 0.5)
    panel.Position = UDim2.new(0.5, 0, 0.5, 0)
    panel.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
    panel.BorderSizePixel = 0
    panel.Parent = authGui
    Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 22)

    local panelStroke = Instance.new("UIStroke")
    panelStroke.Color = Color3.fromRGB(86, 39, 255)
    panelStroke.Transparency = 0.35
    panelStroke.Thickness = 1
    panelStroke.Parent = panel

    local iconImage = Instance.new("ImageLabel")
    iconImage.Name = "AccessIconImage"
    iconImage.Size = UDim2.new(0, 220, 0, 82)
    iconImage.AnchorPoint = Vector2.new(0.5, 0)
    iconImage.Position = UDim2.new(0.5, 0, 0, 12)
    iconImage.BackgroundTransparency = 1
    iconImage.BorderSizePixel = 0
    iconImage.Image = "rbxassetid://109806584615988"
    iconImage.ScaleType = Enum.ScaleType.Fit
    iconImage.Parent = panel

    local keyBox = Instance.new("TextBox")
    keyBox.Size = UDim2.new(1, -32, 0, 48)
    keyBox.Position = UDim2.new(0, 16, 0, 110)
    keyBox.BackgroundColor3 = Color3.fromRGB(28, 28, 34)
    keyBox.BorderSizePixel = 0
    keyBox.PlaceholderText = "Enter access key"
    keyBox.PlaceholderColor3 = Color3.fromRGB(120, 120, 130)
    keyBox.Text = ""
    keyBox.ClearTextOnFocus = false
    keyBox.TextColor3 = Color3.fromRGB(255, 255, 255)
    keyBox.Font = Enum.Font.Code
    keyBox.TextSize = 18
    keyBox.Parent = panel
    Instance.new("UICorner", keyBox).CornerRadius = UDim.new(0, 14)

    local keyStroke = Instance.new("UIStroke")
    keyStroke.Color = Color3.fromRGB(255, 255, 255)
    keyStroke.Transparency = 0.82
    keyStroke.Thickness = 1
    keyStroke.Parent = keyBox

    local statusLabel = Instance.new("TextLabel")
    statusLabel.Size = UDim2.new(1, -32, 0, 20)
    statusLabel.Position = UDim2.new(0, 16, 0, 168)
    statusLabel.BackgroundTransparency = 1
    statusLabel.Text = "Session will be remembered locally for 12 hours."
    statusLabel.TextColor3 = Color3.fromRGB(160, 160, 170)
    statusLabel.Font = Enum.Font.Gotham
    statusLabel.TextSize = 12
    statusLabel.TextXAlignment = Enum.TextXAlignment.Left
    statusLabel.Parent = panel

    local submitButton = Instance.new("TextButton")
    submitButton.Size = UDim2.new(1, -32, 0, 42)
    submitButton.Position = UDim2.new(0, 16, 0, 202)
    submitButton.BackgroundColor3 = Color3.fromRGB(86, 39, 255)
    submitButton.BorderSizePixel = 0
    submitButton.Text = "Unlock Hub"
    submitButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    submitButton.Font = Enum.Font.GothamBold
    submitButton.TextSize = 14
    submitButton.AutoButtonColor = false
    submitButton.Parent = panel
    Instance.new("UICorner", submitButton).CornerRadius = UDim.new(0, 14)

    local discordButton = Instance.new("TextButton")
    discordButton.Size = UDim2.new(0.5, -20, 0, 42)
    discordButton.Position = UDim2.new(0, 16, 0, 252)
    discordButton.BackgroundColor3 = Color3.fromRGB(52, 52, 60)
    discordButton.BorderSizePixel = 0
    discordButton.Text = "Discord"
    discordButton.TextColor3 = Color3.fromRGB(240, 240, 245)
    discordButton.Font = Enum.Font.GothamBold
    discordButton.TextSize = 13
    discordButton.AutoButtonColor = false
    discordButton.Parent = panel
    Instance.new("UICorner", discordButton).CornerRadius = UDim.new(0, 14)

    local getKeyButton = Instance.new("TextButton")
    getKeyButton.Size = UDim2.new(0.5, -20, 0, 42)
    getKeyButton.Position = UDim2.new(0.5, 4, 0, 252)
    getKeyButton.BackgroundColor3 = Color3.fromRGB(52, 52, 60)
    getKeyButton.BorderSizePixel = 0
    getKeyButton.Text = "Get Key"
    getKeyButton.TextColor3 = Color3.fromRGB(240, 240, 245)
    getKeyButton.Font = Enum.Font.GothamBold
    getKeyButton.TextSize = 13
    getKeyButton.AutoButtonColor = false
    getKeyButton.Parent = panel
    Instance.new("UICorner", getKeyButton).CornerRadius = UDim.new(0, 14)

    local clearButton = Instance.new("TextButton")
    clearButton.Size = UDim2.new(1, -32, 0, 24)
    clearButton.Position = UDim2.new(0, 16, 1, -30)
    clearButton.BackgroundTransparency = 1
    clearButton.BorderSizePixel = 0
    clearButton.Text = "Reset Session"
    clearButton.TextColor3 = Color3.fromRGB(170, 170, 180)
    clearButton.Font = Enum.Font.GothamSemibold
    clearButton.TextSize = 12
    clearButton.AutoButtonColor = false
    clearButton.Parent = panel

    local authState = {
        Resolved = false,
        Session = nil
    }
    local connections = {}

    local function setStatus(text, color)
        statusLabel.Text = text
        statusLabel.TextColor3 = color or Color3.fromRGB(160, 160, 170)
    end

    local function copyExternalLink(url, label)
        local copyFn = type(setclipboard) == "function" and setclipboard or (type(toclipboard) == "function" and toclipboard or nil)
        if copyFn then
            local copied = pcall(copyFn, url)
            if copied then
                setStatus((label or "Link") .. " copied to clipboard.", Color3.fromRGB(255, 214, 120))
                notify("Universe Access", (label or "Link") .. " copied to clipboard.", 3)
                return true
            end
        end

        setStatus("Clipboard unavailable on this executor.", Color3.fromRGB(255, 116, 116))
        notify("Universe Access", "Clipboard unavailable.", 3)
        return false
    end

    local function resolve(session)
        authState.Resolved = true
        authState.Session = session
    end

    local function trySubmit()
        submitButton.Active = false
        setStatus("Validating key...", Color3.fromRGB(180, 180, 190))

        local authResult, reason = AuthManager:ValidateKey(keyBox.Text)
        if not authResult then
            submitButton.Active = true
            keyBox.Text = ""
            setStatus(reason == "empty_key" and "Enter a valid key." or "Invalid key.", Color3.fromRGB(255, 116, 116))
            notify("Universe Access", "Invalid key.", 3)
            return
        end

        local session = AuthManager:CreateSession(authResult)
        local saved = AuthManager:SaveSession(session)
        if saved then
            keyBox.Text = FIXED_ACCESS_KEY
            setStatus("Access granted. Loading hub...", Color3.fromRGB(124, 255, 151))
        else
            setStatus("Access granted, but session could not be saved.", Color3.fromRGB(255, 214, 120))
        end

        resolve(session)
    end

    connections[#connections + 1] = submitButton.MouseButton1Click:Connect(trySubmit)
    connections[#connections + 1] = clearButton.MouseButton1Click:Connect(function()
        AuthManager:ClearSession()
        keyBox.Text = ""
        setStatus("Saved key cleared.", Color3.fromRGB(255, 214, 120))
    end)
    connections[#connections + 1] = discordButton.MouseButton1Click:Connect(function()
        copyExternalLink("https://discord.gg/projectoficial", "Discord")
    end)
    connections[#connections + 1] = getKeyButton.MouseButton1Click:Connect(function()
        copyExternalLink("https://projectoficial.com", "Get Key")
    end)
    connections[#connections + 1] = keyBox.FocusLost:Connect(function(enterPressed)
        if enterPressed then
            trySubmit()
        end
    end)

    local savedKey = AuthManager:LoadSavedKey()
    if savedKey then
        keyBox.Text = savedKey
        setStatus("Saved key loaded into the input. Click Unlock Hub to continue.", Color3.fromRGB(255, 214, 120))
    else
        keyBox:CaptureFocus()
    end

    while not authState.Resolved do
        task.wait(0.1)
    end

    for _, connection in ipairs(connections) do
        pcall(function()
            connection:Disconnect()
        end)
    end

    authGui:Destroy()
    return authState.Session
end

print("==========================================")
print("Universe AUTH HOST - INITIALIZING")
print("Authenticating before loading shell and main script...")
print("==========================================")

local session = buildAuthGate()

local valid, reason = AuthManager:IsSessionValid(session)
if not valid then
    AuthManager:ClearSession()
    warn("[Host] Authentication failed: " .. tostring(reason))
    notify("Universe Access", "Authentication failed.", 4)
    return
end

if ModuleLoader:ExecuteModule("ui_library", session) then
    if getgenv().ProjectLibrary then
        local lib = getgenv().ProjectLibrary
        if type(lib.Notify) == "function" then
            pcall(function()
                lib:Notify("Universe Access", "Authenticated session loaded.", 3)
            end)
        end
    end
else
    warn("[Host] Failed to load Interface Library from host. Continuing without it...")
end

if not ModuleLoader:ExecuteModule("hub_shell", session) then
    warn("[Host] Failed to load hub shell from host. Aborting.")
    return
end

if not ModuleLoader:ExecuteModule("main", session) then
    warn("[Host] Failed to connect to main script host.")
    return
end

print("==========================================")
print("Universe AUTH HOST - LOADING COMPLETE")
print("==========================================")
