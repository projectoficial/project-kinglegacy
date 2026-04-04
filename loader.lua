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
        warn("[Host] Failed to load " .. tostring(name) .. ": " .. tostring(bodyOrErr))
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
        warn("[Host] Error compiling " .. tostring(name) .. ": " .. tostring(loadErr))
        return false, loadErr
    end

    local execSuccess, execErr = pcall(chunk)
    if not execSuccess then
        if name == "main" then
            AuthManager:ClearRuntimeBridge()
        end
        warn("[Host] Error executing " .. tostring(name) .. ": " .. tostring(execErr))
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
    panel.Size = UDim2.new(0, 420, 0, 270)
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

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -32, 0, 32)
    title.Position = UDim2.new(0, 16, 0, 18)
    title.BackgroundTransparency = 1
    title.Text = "Universe Access"
    title.TextColor3 = Color3.fromRGB(255, 255, 255)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 24
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = panel

    local subtitle = Instance.new("TextLabel")
    subtitle.Size = UDim2.new(1, -32, 0, 38)
    subtitle.Position = UDim2.new(0, 16, 0, 54)
    subtitle.BackgroundTransparency = 1
    subtitle.Text = "Enter your access key before loading the hub shell and game menu."
    subtitle.TextColor3 = Color3.fromRGB(180, 180, 190)
    subtitle.Font = Enum.Font.Gotham
    subtitle.TextSize = 13
    subtitle.TextWrapped = true
    subtitle.TextXAlignment = Enum.TextXAlignment.Left
    subtitle.TextYAlignment = Enum.TextYAlignment.Top
    subtitle.Parent = panel

    local keyBox = Instance.new("TextBox")
    keyBox.Size = UDim2.new(1, -32, 0, 48)
    keyBox.Position = UDim2.new(0, 16, 0, 116)
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
    statusLabel.Position = UDim2.new(0, 16, 0, 174)
    statusLabel.BackgroundTransparency = 1
    statusLabel.Text = "Session will be remembered locally for 12 hours."
    statusLabel.TextColor3 = Color3.fromRGB(160, 160, 170)
    statusLabel.Font = Enum.Font.Gotham
    statusLabel.TextSize = 12
    statusLabel.TextXAlignment = Enum.TextXAlignment.Left
    statusLabel.Parent = panel

    local submitButton = Instance.new("TextButton")
    submitButton.Size = UDim2.new(0.58, -18, 0, 42)
    submitButton.Position = UDim2.new(0, 16, 1, -58)
    submitButton.BackgroundColor3 = Color3.fromRGB(86, 39, 255)
    submitButton.BorderSizePixel = 0
    submitButton.Text = "Unlock Hub"
    submitButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    submitButton.Font = Enum.Font.GothamBold
    submitButton.TextSize = 14
    submitButton.AutoButtonColor = false
    submitButton.Parent = panel
    Instance.new("UICorner", submitButton).CornerRadius = UDim.new(0, 14)

    local clearButton = Instance.new("TextButton")
    clearButton.Size = UDim2.new(0.42, -14, 0, 42)
    clearButton.Position = UDim2.new(0.58, 2, 1, -58)
    clearButton.BackgroundColor3 = Color3.fromRGB(34, 34, 40)
    clearButton.BorderSizePixel = 0
    clearButton.Text = "Reset Session"
    clearButton.TextColor3 = Color3.fromRGB(220, 220, 230)
    clearButton.Font = Enum.Font.GothamBold
    clearButton.TextSize = 13
    clearButton.AutoButtonColor = false
    clearButton.Parent = panel
    Instance.new("UICorner", clearButton).CornerRadius = UDim.new(0, 14)

    local authState = {
        Resolved = false,
        Session = nil
    }
    local connections = {}

    local function setStatus(text, color)
        statusLabel.Text = text
        statusLabel.TextColor3 = color or Color3.fromRGB(160, 160, 170)
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
