--// Bed TP (executor)
--// EDGEV4 — made by edgemaster
--// X = close. _ = minimize. RightShift = toggle. WASD/STOP cancels.
--// Noclip and Avoid are mutually exclusive.
--// Clicking a bed resets you, then flies once you respawn.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Teams = game:GetService("Teams")
local PhysicsService = game:GetService("PhysicsService")

local player = Players.LocalPlayer
local env = getgenv and getgenv() or _G

if env.BedUI and env.BedUI.Destroy then
    pcall(env.BedUI.Destroy)
end

----------------------------------------------------------------
-- theme
----------------------------------------------------------------
local T = {
    bg        = Color3.fromRGB(13, 11, 19),
    bgTop     = Color3.fromRGB(26, 20, 40),
    raised    = Color3.fromRGB(23, 20, 32),
    hover     = Color3.fromRGB(35, 30, 48),
    border    = Color3.fromRGB(62, 52, 92),
    magenta   = Color3.fromRGB(255, 55, 145),
    cyan      = Color3.fromRGB(60, 225, 255),
    ice       = Color3.fromRGB(165, 246, 255),
    violet    = Color3.fromRGB(155, 95, 255),
    text      = Color3.fromRGB(236, 234, 246),
    muted     = Color3.fromRGB(148, 143, 172),
    onBg      = Color3.fromRGB(20, 88, 100),
    onText    = Color3.fromRGB(120, 240, 255),
    offBg     = Color3.fromRGB(50, 33, 45),
    offText   = Color3.fromRGB(214, 140, 160),
    danger    = Color3.fromRGB(220, 45, 90),
    ink       = Color3.fromRGB(18, 8, 26),
}

----------------------------------------------------------------
-- config
----------------------------------------------------------------
local CFG = {
    SPEED        = 800,
    STOP_RADIUS  = 2.5,
    SEAT         = 4,
    DT_CAP       = 1 / 20,
    AVOID        = false,
    DODGE_HOLD   = 0.3,
    NOCLIP       = true,
    BALLOONS     = true,
    TPDOWN       = true,
    AIR_LIMIT    = 2,
    TP_FREEZE    = 0.11,
    VOID_MARGIN  = 40,
    HEALTH_DROP  = 0.55,
    COLOR_DEPTH  = 30,
    COLOR_RADIUS = 18,
    COLOR_TTL    = 20,
    DUP_RADIUS   = 6,
    NOCLIP_TICK  = 0.25,
    RESPAWN_WAIT = 15,
}

local DODGE_ANGLES = { -90, -70, -50, -30, -15, 15, 30, 50, 70, 90 }

local FALLBACK_COLORS = {
    Color3.fromRGB(200, 60, 60),
    Color3.fromRGB(60, 120, 210),
    Color3.fromRGB(210, 180, 60),
    Color3.fromRGB(70, 180, 90),
    Color3.fromRGB(160, 90, 200),
    Color3.fromRGB(60, 190, 190),
    Color3.fromRGB(220, 130, 60),
    Color3.fromRGB(210, 90, 160),
    Color3.fromRGB(140, 140, 150),
    Color3.fromRGB(90, 200, 130),
}

local flying = false
local token = 0
local savedCollide = {}
local waitingRespawn = false

local diag = {
    stuck = 0,
    escapes = 0,
    air = 0,
    lastSafe = Vector3.zero,
}

----------------------------------------------------------------
-- util
----------------------------------------------------------------
local function new(class, props, parent)
    local inst = Instance.new(class)
    for k, v in pairs(props) do
        if k ~= "Parent" then
            inst[k] = v
        end
    end
    inst.Parent = parent
    return inst
end

local function corner(obj, radius)
    new("UICorner", { CornerRadius = UDim.new(0, radius or 6) }, obj)
end

local function stroke(obj, color, thickness, transparency)
    new("UIStroke", {
        Color = color,
        Thickness = thickness or 1,
        Transparency = transparency or 0,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    }, obj)
end

local function textStroke(label, color, thickness, transparency)
    new("UIStroke", {
        Color = color,
        Thickness = thickness or 1,
        Transparency = transparency or 0,
    }, label)
end

local function gradient(obj, from, to, rotation)
    new("UIGradient", {
        Color = ColorSequence.new(from, to),
        Rotation = rotation or 0,
    }, obj)
end

local function hoverable(btn, base, hot)
    btn.MouseEnter:Connect(function()
        btn.BackgroundColor3 = hot
    end)
    btn.MouseLeave:Connect(function()
        btn.BackgroundColor3 = base
    end)
end

local function getHRP()
    local char = player.Character
    if not char then
        return nil, nil
    end
    return char:FindFirstChild("HumanoidRootPart"), char
end

local function cfOf(inst)
    if inst:IsA("CFrameValue") then
        return inst.Value
    end
    if inst:IsA("BasePart") then
        return inst.CFrame
    end
    if inst:IsA("Model") then
        local p = inst.PrimaryPart
        if not p then
            p = inst:FindFirstChildWhichIsA("BasePart", true)
        end
        if p then
            return p.CFrame
        end
        return nil
    end
    if inst:IsA("Attachment") then
        return inst.WorldCFrame
    end
    return nil
end

local function vec(v, fallback)
    if typeof(v) ~= "Vector3" then
        return fallback
    end
    if v ~= v then
        return fallback
    end
    if v.Magnitude < 0.0001 then
        return fallback
    end
    return v
end

local function ownerOK(hrp)
    local ok, owner = pcall(function()
        return hrp:GetNetworkOwner()
    end)
    if not ok then
        return true
    end
    return owner == player
end

----------------------------------------------------------------
-- noclip (collision group + CanCollide)
----------------------------------------------------------------
local NOCLIP_GROUP = "BedTpNoClip"
local groupReady = false

local function groupNameOf(g)
    if typeof(g) == "string" then
        return g
    end
    local n = nil
    pcall(function()
        n = g.name or g.Name
    end)
    return n
end

local function ensureGroup()
    if groupReady then
        return true
    end

    local registered = false
    pcall(function()
        PhysicsService:RegisterCollisionGroup(NOCLIP_GROUP)
        registered = true
    end)

    if not registered then
        local exists = false
        pcall(function()
            for _, g in ipairs(PhysicsService:GetCollisionGroups()) do
                if groupNameOf(g) == NOCLIP_GROUP then
                    exists = true
                end
            end
        end)
        if not exists then
            return false
        end
    end

    pcall(function()
        for _, g in ipairs(PhysicsService:GetCollisionGroups()) do
            local name = groupNameOf(g)
            if name and name ~= NOCLIP_GROUP then
                PhysicsService:CollisionGroupSetCollidable(NOCLIP_GROUP, name, false)
            end
        end
    end)

    groupReady = true
    return true
end

local function noclipOn(char)
    if not CFG.NOCLIP then
        return
    end
    if not char then
        return
    end

    local hasGroup = ensureGroup()

    for _, d in ipairs(char:GetDescendants()) do
        if d:IsA("BasePart") then
            if not savedCollide[d] then
                savedCollide[d] = {
                    collide = d.CanCollide,
                    group = d.CollisionGroup,
                }
            end
            if d.CanCollide then
                pcall(function()
                    d.CanCollide = false
                end)
            end
            if hasGroup and d.CollisionGroup ~= NOCLIP_GROUP then
                pcall(function()
                    d.CollisionGroup = NOCLIP_GROUP
                end)
            end
        end
    end
end

local function noclipOff()
    for part, info in pairs(savedCollide) do
        if part and part.Parent then
            pcall(function()
                part.CanCollide = info.collide
                part.CollisionGroup = info.group
            end)
        end
    end
    savedCollide = {}
end

----------------------------------------------------------------
-- colour resolution
----------------------------------------------------------------
local colorCache = setmetatable({}, { __mode = "k" })

local partRay = RaycastParams.new()
partRay.FilterType = Enum.RaycastFilterType.Exclude
partRay.RespectCanCollide = false
partRay.IgnoreWater = true

local function colorFromValue(v)
    if typeof(v) == "Color3" then
        return v
    end
    if typeof(v) == "BrickColor" then
        return v.Color
    end
    if typeof(v) == "string" then
        local team = Teams:FindFirstChild(v)
        if team then
            return team.TeamColor.Color
        end
    end
    return nil
end

local function saturated(col)
    local r, g, b = col.R, col.G, col.B
    local mx = math.max(r, g, b)
    local mn = math.min(r, g, b)
    if mx <= 0.22 then
        return false
    end
    return (mx - mn) / mx > 0.3
end

local function attrColor(inst)
    local node = inst
    local depth = 0
    while node and depth < 3 do
        for _, key in ipairs({ "TeamColor", "BedColor", "Color", "Team" }) do
            local ok, v = pcall(function()
                return node:GetAttribute(key)
            end)
            if ok and v ~= nil then
                local col = colorFromValue(v)
                if col then
                    return col
                end
            end
        end
        node = node.Parent
        depth = depth + 1
    end
    return nil
end

local function siblingColor(inst)
    local num = string.match(inst.Name, "^(%d+)")
    if not num then
        return nil
    end
    local parent = inst.Parent
    if not parent then
        return nil
    end

    for _, sib in ipairs(parent:GetChildren()) do
        if sib ~= inst and sib:IsA("ValueBase") then
            if string.match(sib.Name, "^" .. num) then
                local ok, v = pcall(function()
                    return sib.Value
                end)
                if ok then
                    local col = colorFromValue(v)
                    if col then
                        return col
                    end
                end
            end
        end
    end
    return nil
end

local function rayColor(pos)
    local offsets = {
        Vector3.new(0, 0, 0),
        Vector3.new(0.35, 0, 0),
        Vector3.new(-0.35, 0, 0),
        Vector3.new(0, 0, 0.35),
        Vector3.new(0, 0, -0.35),
    }

    for _, off in ipairs(offsets) do
        local origin = pos + off * 3
        local hit = Workspace:Raycast(origin, Vector3.new(0, -CFG.COLOR_DEPTH, 0), partRay)
        if hit then
            local inst = hit.Instance
            if inst and saturated(inst.Color) then
                return inst.Color
            end
        end
    end
    return nil
end

local function nearestColor(pos)
    local ok, parts = pcall(function()
        return Workspace:GetPartBoundsInRadius(pos, CFG.COLOR_RADIUS)
    end)
    if not ok or not parts then
        return nil
    end

    local best = nil
    local bestDist = math.huge

    for _, part in ipairs(parts) do
        if part:IsA("BasePart") and saturated(part.Color) then
            local size = part.Size
            if size.X * size.Y * size.Z < 80000 then
                local d = (part.Position - pos).Magnitude
                if d < bestDist then
                    bestDist = d
                    best = part.Color
                end
            end
        end
    end

    return best
end

local function resolveColor(inst, index)
    local cached = colorCache[inst]
    if cached and (os.clock() - cached.at) < CFG.COLOR_TTL then
        return cached.color
    end

    local col = attrColor(inst)
    if not col then
        col = siblingColor(inst)
    end

    local cf = cfOf(inst)
    if not col and cf then
        col = rayColor(cf.Position)
    end
    if not col and cf then
        col = nearestColor(cf.Position)
    end
    if not col then
        col = FALLBACK_COLORS[((index - 1) % #FALLBACK_COLORS) + 1]
    end

    colorCache[inst] = { color = col, at = os.clock() }
    return col
end

----------------------------------------------------------------
-- gui
----------------------------------------------------------------
local pGui = nil
if gethui then
    pGui = gethui()
end
if not pGui then
    pGui = player:FindFirstChildOfClass("PlayerGui")
end
if not pGui then
    pGui = game:GetService("CoreGui")
end

local gui = new("ScreenGui", {
    Name = "BedUI",
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, pGui)

env.BedUI = gui

local panel = new("Frame", {
    Size = UDim2.fromOffset(250, 544),
    Position = UDim2.new(0, 36, 0, 70),
    BackgroundColor3 = T.bg,
    BorderSizePixel = 0,
}, gui)
corner(panel, 12)
gradient(panel, T.bgTop, T.bg, 90)

local panelStroke = new("UIStroke", {
    Color = T.violet,
    Thickness = 1,
    Transparency = 0.35,
    ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
}, panel)

local titleBar = new("Frame", {
    Size = UDim2.new(1, 0, 0, 48),
    BackgroundColor3 = T.raised,
    BorderSizePixel = 0,
}, panel)
corner(titleBar, 12)
gradient(titleBar, T.violet, T.magenta, 0)

-- EDGEV4 logo badge
local logo = new("Frame", {
    Size = UDim2.fromOffset(58, 21),
    Position = UDim2.new(0, 10, 0, 6),
    BackgroundColor3 = T.magenta,
    BorderSizePixel = 0,
    ZIndex = 2,
}, titleBar)
corner(logo, 5)
gradient(logo, T.cyan, T.magenta, 0)
stroke(logo, Color3.fromRGB(255, 255, 255), 1, 0.3)

local logoText = new("TextLabel", {
    Text = "EDGEV4",
    Font = Enum.Font.GothamBlack,
    TextSize = 11,
    TextColor3 = Color3.fromRGB(255, 255, 255),
    BackgroundTransparency = 1,
    Size = UDim2.new(1, 0, 1, 0),
    ZIndex = 2,
}, logo)
textStroke(logoText, T.ink, 1, 0.35)

local titleText = new("TextLabel", {
    Text = "BED TP",
    Font = Enum.Font.GothamBlack,
    TextSize = 15,
    TextColor3 = Color3.fromRGB(255, 255, 255),
    TextXAlignment = Enum.TextXAlignment.Left,
    BackgroundTransparency = 1,
    Size = UDim2.new(1, -180, 0, 18),
    Position = UDim2.new(0, 76, 0, 6),
    ZIndex = 2,
}, titleBar)
textStroke(titleText, T.ink, 1, 0.4)

local creditLabel = new("TextLabel", {
    Text = "made by edgemaster",
    Font = Enum.Font.GothamBold,
    TextSize = 12,
    TextColor3 = T.ice,
    TextXAlignment = Enum.TextXAlignment.Left,
    BackgroundTransparency = 1,
    Size = UDim2.new(1, -170, 0, 16),
    Position = UDim2.new(0, 76, 0, 24),
    ZIndex = 2,
}, titleBar)
textStroke(creditLabel, T.ink, 1, 0.25)

local function titleButton(text, xOffset, color)
    local btn = new("TextButton", {
        Text = text,
        Font = Enum.Font.GothamBold,
        TextSize = 12,
        TextColor3 = T.text,
        BackgroundColor3 = color,
        BorderSizePixel = 0,
        BackgroundTransparency = 0.35,
        Size = UDim2.fromOffset(22, 20),
        Position = UDim2.new(1, xOffset, 0, 14),
        AutoButtonColor = true,
        ZIndex = 3,
    }, titleBar)
    corner(btn, 6)
    return btn
end

local refreshBtn = titleButton("R", -80, Color3.fromRGB(40, 34, 58))
local minBtn = titleButton("_", -54, Color3.fromRGB(40, 34, 58))
local closeBtn = titleButton("X", -27, T.danger)

local diagBar = new("Frame", {
    Size = UDim2.new(1, 0, 0, 18),
    Position = UDim2.new(0, 0, 0, 48),
    BackgroundColor3 = Color3.fromRGB(9, 8, 14),
    BorderSizePixel = 0,
}, panel)
gradient(diagBar, Color3.fromRGB(14, 12, 22), Color3.fromRGB(9, 8, 14), 0)

local diagLabel = new("TextLabel", {
    Text = "idle",
    Font = Enum.Font.Code,
    TextSize = 11,
    TextColor3 = T.cyan,
    BackgroundTransparency = 1,
    TextXAlignment = Enum.TextXAlignment.Left,
    Size = UDim2.new(1, -8, 1, 0),
    Position = UDim2.new(0, 10, 0, 0),
}, diagBar)

local list = new("ScrollingFrame", {
    Size = UDim2.new(1, -18, 1, -282),
    Position = UDim2.new(0, 9, 0, 72),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ScrollBarThickness = 4,
    ScrollBarImageColor3 = T.violet,
    CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, panel)

new("UIListLayout", {
    Padding = UDim.new(0, 5),
    SortOrder = Enum.SortOrder.LayoutOrder,
}, list)

local bottom = new("Frame", {
    Size = UDim2.new(1, -18, 0, 204),
    Position = UDim2.new(0, 9, 1, -210),
    BackgroundTransparency = 1,
}, panel)

local function row(yOffset)
    return new("Frame", {
        Size = UDim2.new(1, 0, 0, 22),
        Position = UDim2.new(0, 0, 0, yOffset),
        BackgroundTransparency = 1,
    }, bottom)
end

local stopBtn = new("TextButton", {
    Text = "STOP",
    Font = Enum.Font.GothamBold,
    TextSize = 11,
    TextColor3 = Color3.fromRGB(255, 255, 255),
    BackgroundColor3 = T.danger,
    BorderSizePixel = 0,
    Size = UDim2.new(1, 0, 0, 26),
    AutoButtonColor = true,
}, bottom)
corner(stopBtn, 7)
gradient(stopBtn, T.magenta, T.danger, 0)
stroke(stopBtn, T.magenta, 1, 0.5)

local speedRow = row(34)
new("TextLabel", {
    Text = "Speed",
    Font = Enum.Font.Gotham,
    TextSize = 11,
    TextColor3 = T.muted,
    BackgroundTransparency = 1,
    TextXAlignment = Enum.TextXAlignment.Left,
    Size = UDim2.new(0, 48, 1, 0),
}, speedRow)

local speedBox = new("TextBox", {
    Text = tostring(CFG.SPEED),
    Font = Enum.Font.Code,
    TextSize = 12,
    TextColor3 = T.cyan,
    BackgroundColor3 = Color3.fromRGB(15, 14, 24),
    BorderSizePixel = 0,
    ClearTextOnFocus = false,
    Size = UDim2.new(0, 66, 1, 0),
    Position = UDim2.new(0, 50, 0, 0),
}, speedRow)
corner(speedBox, 6)
stroke(speedBox, T.cyan, 1, 0.6)

new("TextLabel", {
    Text = "studs/s",
    Font = Enum.Font.Gotham,
    TextSize = 10,
    TextColor3 = T.muted,
    BackgroundTransparency = 1,
    TextXAlignment = Enum.TextXAlignment.Left,
    Size = UDim2.new(0, 60, 1, 0),
    Position = UDim2.new(0, 122, 0, 0),
}, speedRow)

local function toggle(yOffset, text, on)
    local btn = new("TextButton", {
        Text = text,
        Font = Enum.Font.GothamSemibold,
        TextSize = 11,
        TextColor3 = on and T.onText or T.offText,
        BackgroundColor3 = on and T.onBg or T.offBg,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 21),
        Position = UDim2.new(0, 0, 0, yOffset),
        AutoButtonColor = true,
    }, bottom)
    corner(btn, 6)
    stroke(btn, on and T.cyan or Color3.fromRGB(120, 70, 95), 1, 0.55)
    return btn
end

local avoidBtn = toggle(62, "Avoid: OFF", false)
local noclipBtn = toggle(85, "Noclip: ON", true)
local ballBtn = toggle(108, "Balloons: ON", true)
local tpBtn = toggle(131, "TP Down: ON", true)

local footCredit = new("TextLabel", {
    Text = "EDGEV4  ·  made by edgemaster",
    Font = Enum.Font.GothamBold,
    TextSize = 11,
    TextColor3 = T.ice,
    BackgroundTransparency = 1,
    TextXAlignment = Enum.TextXAlignment.Left,
    Size = UDim2.new(1, 0, 0, 16),
    Position = UDim2.new(0, 0, 0, 156),
}, bottom)
textStroke(footCredit, T.ink, 1, 0.3)

local status = new("TextLabel", {
    Text = "",
    Font = Enum.Font.Gotham,
    TextSize = 10,
    TextColor3 = T.muted,
    BackgroundTransparency = 1,
    TextWrapped = true,
    TextXAlignment = Enum.TextXAlignment.Left,
    Size = UDim2.new(1, 0, 0, 38),
    Position = UDim2.new(0, 0, 0, 172),
}, bottom)

local function say(text)
    if status and status.Parent then
        status.Text = text
    end
end

----------------------------------------------------------------
-- pill
----------------------------------------------------------------
local pill = new("Frame", {
    Size = UDim2.fromOffset(146, 28),
    Position = UDim2.new(0, 36, 0, 70),
    BackgroundColor3 = T.raised,
    BorderSizePixel = 0,
    Visible = false,
}, gui)
corner(pill, 9)
gradient(pill, T.violet, T.magenta, 0)
stroke(pill, T.magenta, 1, 0.4)

local pillLabel = new("TextButton", {
    Text = "EDGEV4 · bed tp",
    Font = Enum.Font.GothamBold,
    TextSize = 10,
    TextColor3 = Color3.fromRGB(255, 255, 255),
    BackgroundTransparency = 1,
    Size = UDim2.new(1, -30, 1, 0),
    AutoButtonColor = false,
}, pill)

local pillClose = new("TextButton", {
    Text = "X",
    Font = Enum.Font.GothamBold,
    TextSize = 11,
    TextColor3 = Color3.fromRGB(255, 255, 255),
    BackgroundColor3 = T.danger,
    BorderSizePixel = 0,
    Size = UDim2.fromOffset(20, 18),
    Position = UDim2.new(1, -23, 0, 5),
    AutoButtonColor = true,
}, pill)
corner(pillClose, 6)

----------------------------------------------------------------
-- dragging
----------------------------------------------------------------
local function makeDraggable(handle, target)
    local dragging = false
    local dragStart = nil
    local startPos = nil

    handle.InputBegan:Connect(function(input)
        local isMouse = input.UserInputType == Enum.UserInputType.MouseButton1
        local isTouch = input.UserInputType == Enum.UserInputType.Touch
        if not (isMouse or isTouch) then
            return
        end
        dragging = true
        dragStart = input.Position
        startPos = target.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
            end
        end)
    end)

    UserInputService.InputChanged:Connect(function(input)
        if not dragging then
            return
        end
        local isMouse = input.UserInputType == Enum.UserInputType.MouseMovement
        local isTouch = input.UserInputType == Enum.UserInputType.Touch
        if not (isMouse or isTouch) then
            return
        end

        local delta = input.Position - dragStart
        local cam = Workspace.CurrentCamera
        local vp = Vector2.new(1280, 720)
        if cam then
            vp = cam.ViewportSize
        end

        local maxX = math.max(vp.X - target.AbsoluteSize.X, 0)
        local maxY = math.max(vp.Y - target.AbsoluteSize.Y, 0)
        local nx = math.clamp(startPos.X.Offset + delta.X, 0, maxX)
        local ny = math.clamp(startPos.Y.Offset + delta.Y, 0, maxY)

        target.Position = UDim2.new(0, nx, 0, ny)
    end)
end

makeDraggable(titleBar, panel)
makeDraggable(pill, pill)

local function minimize()
    pill.Position = panel.Position
    panel.Visible = false
    pill.Visible = true
end

local function restore()
    panel.Position = pill.Position
    pill.Visible = false
    panel.Visible = true
end

----------------------------------------------------------------
-- flight rays
----------------------------------------------------------------
local rayParams = RaycastParams.new()
rayParams.RespectCanCollide = true
rayParams.IgnoreWater = true
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local function baseFilter(char)
    local filters = { char }
    local cam = Workspace.CurrentCamera
    if cam then
        table.insert(filters, cam)
    end
    rayParams.FilterDescendantsInstances = filters
    partRay.FilterDescendantsInstances = filters
end

local function groundHit(hrp, depth)
    local dir = Vector3.new(0, -(depth or 80), 0)
    return Workspace:Raycast(hrp.Position, dir, rayParams)
end

local function clearDistance(origin, dir, maxDist)
    local hit = Workspace:Raycast(origin, dir * maxDist, rayParams)
    if not hit then
        return maxDist
    end
    return hit.Distance
end

----------------------------------------------------------------
-- balloons
----------------------------------------------------------------
local function findBalloon()
    for _, d in ipairs(game:GetDescendants()) do
        if d:IsA("ModuleScript") and d.Name == "BalloonController" then
            local ok, mod = pcall(require, d)
            if ok and type(mod) == "table" then
                return mod
            end
        end
    end
    return nil
end

local function hookBalloons()
    if env.__BalloonHooked then
        return
    end
    if not CFG.BALLOONS then
        return
    end

    local bc = findBalloon()
    if not bc then
        return
    end

    env.__OldDeflate = bc.deflateBalloon
    pcall(function()
        bc.deflateBalloon = function() end
    end)
    env.__BalloonHooked = true

    local char = player.Character
    if char and (char:GetAttribute("InflatedBalloons") or 0) == 0 then
        pcall(function()
            bc:inflateBalloon()
        end)
    end

    if char then
        env.__BalloonAttr = char:GetAttributeChangedSignal("InflatedBalloons"):Connect(function()
            local c = player.Character
            if c and (c:GetAttribute("InflatedBalloons") or 0) == 0 then
                pcall(function()
                    bc:inflateBalloon()
                end)
            end
        end)
    end
end

local function unhookBalloons()
    if not env.__BalloonHooked then
        return
    end
    local bc = findBalloon()
    if bc and env.__OldDeflate then
        pcall(function()
            bc.deflateBalloon = env.__OldDeflate
        end)
    end
    if env.__BalloonAttr then
        pcall(function()
            env.__BalloonAttr:Disconnect()
        end)
        env.__BalloonAttr = nil
    end
    env.__BalloonHooked = false
end

local function flyAllowed()
    local char = player.Character
    if not char then
        return false
    end
    return (char:GetAttribute("InflatedBalloons") or 0) > 0
end

----------------------------------------------------------------
-- tp down
----------------------------------------------------------------
local function tpDown(hrp, hum)
    if not CFG.TPDOWN then
        return false
    end

    local ray = groundHit(hrp, 1000)
    if not ray then
        return false
    end

    local oldY = hrp.Position.Y
    local hip = hum.HipHeight or 2
    local groundY = ray.Position.Y + hip
    local look = hrp.CFrame.LookVector
    local x = hrp.Position.X
    local z = hrp.Position.Z

    hrp.CFrame = CFrame.lookAlong(Vector3.new(x, groundY, z), look)

    task.delay(CFG.TP_FREEZE, function()
        if not hrp or not hrp.Parent then
            return
        end
        hrp.CFrame = CFrame.lookAlong(Vector3.new(x, oldY, z), look)
    end)

    diag.air = 0
    return true
end

----------------------------------------------------------------
-- teardown
----------------------------------------------------------------
local function abort(message)
    token = token + 1
    flying = false
    waitingRespawn = false

    local hrp, char = getHRP()
    if hrp then
        pcall(function()
            hrp.AssemblyLinearVelocity = Vector3.zero
        end)
    end

    if char then
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then
            pcall(function()
                hum:ChangeState(Enum.HumanoidStateType.Running)
            end)
        end
    end

    noclipOff()
    unhookBalloons()

    if message then
        say(message)
    end
end

local function destroyAll()
    abort()
    gui:Destroy()
    env.BedUI = nil
end

closeBtn.MouseButton1Click:Connect(destroyAll)
pillClose.MouseButton1Click:Connect(destroyAll)
minBtn.MouseButton1Click:Connect(minimize)
pillLabel.MouseButton1Click:Connect(restore)

stopBtn.MouseButton1Click:Connect(function()
    if flying or waitingRespawn then
        abort("Cancelled")
    end
end)

----------------------------------------------------------------
-- toggles
----------------------------------------------------------------
local function setVisual(button, on, onText, offText)
    if on then
        button.Text = onText
        button.TextColor3 = T.onText
        button.BackgroundColor3 = T.onBg
        local s = button:FindFirstChildOfClass("UIStroke")
        if s then
            s.Color = T.cyan
        end
    else
        button.Text = offText
        button.TextColor3 = T.offText
        button.BackgroundColor3 = T.offBg
        local s = button:FindFirstChildOfClass("UIStroke")
        if s then
            s.Color = Color3.fromRGB(120, 70, 95)
        end
    end
end

local function bindToggle(button, key, onText, offText)
    button.MouseButton1Click:Connect(function()
        CFG[key] = not CFG[key]
        setVisual(button, CFG[key], onText, offText)
    end)
end

bindToggle(avoidBtn, "AVOID", "Avoid: ON", "Avoid: OFF")
bindToggle(noclipBtn, "NOCLIP", "Noclip: ON", "Noclip: OFF")
bindToggle(ballBtn, "BALLOONS", "Balloons: ON", "Balloons: OFF")
bindToggle(tpBtn, "TPDOWN", "TP Down: ON", "TP Down: OFF")

-- noclip and avoid are mutually exclusive
avoidBtn.MouseButton1Click:Connect(function()
    if not CFG.AVOID then
        return
    end
    if CFG.NOCLIP then
        CFG.NOCLIP = false
        setVisual(noclipBtn, false, "Noclip: ON", "Noclip: OFF")
        if flying then
            noclipOff()
        end
    end
end)

noclipBtn.MouseButton1Click:Connect(function()
    if CFG.NOCLIP then
        if CFG.AVOID then
            CFG.AVOID = false
            setVisual(avoidBtn, false, "Avoid: ON", "Avoid: OFF")
        end
        if flying then
            noclipOn(player.Character)
        end
    elseif flying then
        noclipOff()
    end
end)

UserInputService.InputBegan:Connect(function(input, processed)
    if processed then
        return
    end

    if input.KeyCode == Enum.KeyCode.RightShift then
        if not gui.Parent then
            return
        end
        if panel.Visible then
            minimize()
        else
            restore()
        end
        return
    end

    if not (flying or waitingRespawn) then
        return
    end

    local k = input.KeyCode
    local cancel = k == Enum.KeyCode.W
        or k == Enum.KeyCode.A
        or k == Enum.KeyCode.S
        or k == Enum.KeyCode.D
        or k == Enum.KeyCode.Space

    if cancel then
        abort("Cancelled")
    end
end)

----------------------------------------------------------------
-- diagnostics
----------------------------------------------------------------
task.spawn(function()
    while gui.Parent do
        local hrp = getHRP()
        local y = 0
        if hrp then
            y = math.floor(hrp.Position.Y)
        end
        local stateText = "idle"
        if flying then
            stateText = "FLY"
        elseif waitingRespawn then
            stateText = "RESPAWN"
        end
        local air = string.format("%.1f", diag.air)
        diagLabel.Text = stateText .. " | air" .. air .. " | st" .. tostring(diag.stuck) .. " | y" .. tostring(y)
        if flying then
            diagLabel.TextColor3 = T.cyan
        elseif waitingRespawn then
            diagLabel.TextColor3 = T.magenta
        else
            diagLabel.TextColor3 = T.muted
        end
        task.wait(0.2)
    end
end)

-- idle breathing glow on the panel border
task.spawn(function()
    while gui.Parent do
        for i = 0, 20 do
            if not gui.Parent then
                break
            end
            panelStroke.Transparency = 0.35 + math.sin(i / 20 * math.pi) * 0.3
            task.wait(0.05)
        end
        panelStroke.Transparency = 0.35
        task.wait(1.4)
    end
end)

-- logo shimmer
task.spawn(function()
    local g = logo:FindFirstChildOfClass("UIGradient")
    while gui.Parent do
        if g then
            for i = 0, 24 do
                if not gui.Parent then
                    break
                end
                g.Rotation = (i / 24) * 360
                task.wait(0.06)
            end
            task.wait(2.2)
        else
            task.wait(0.5)
        end
    end
end)

----------------------------------------------------------------
-- flight
----------------------------------------------------------------
local function fly(name, getCF, getInst, speed)
    local hrp, char = getHRP()
    if not hrp then
        say("No character")
        return
    end

    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then
        say("No humanoid")
        return
    end

    if hum.Health <= 0 then
        say("Dead")
        return
    end

    local base = getCF()
    if not base then
        say("Bad CFrame for " .. name)
        return
    end

    abort()
    token = token + 1
    local myToken = token
    flying = true

    baseFilter(char)
    noclipOn(char)

    local targetInst = nil
    if getInst then
        targetInst = getInst()
    end

    if targetInst and targetInst.Parent then
        local filters = rayParams.FilterDescendantsInstances
        table.insert(filters, targetInst)
        table.insert(filters, targetInst.Parent)
        rayParams.FilterDescendantsInstances = filters
    end

    diag.stuck = 0
    diag.escapes = 0
    diag.air = 0
    diag.lastSafe = hrp.Position

    hookBalloons()

    local lastSafeAt = 0
    local lastNoclipAt = 0
    local conn = nil
    local dodgeDir = nil
    local dodgeSide = 0
    local dodgeUntil = 0

    local function finish(message, placeCF)
        if conn then
            conn:Disconnect()
            conn = nil
        end
        if hrp then
            pcall(function()
                hrp.AssemblyLinearVelocity = Vector3.zero
            end)
        end
        if placeCF then
            pcall(function()
                hrp.CFrame = placeCF
            end)
        end
        abort(message)
    end

    conn = RunService.PreSimulation:Connect(function(rawDt)
        if myToken ~= token then
            conn:Disconnect()
            return
        end

        if not flying then
            conn:Disconnect()
            return
        end

        if not hrp.Parent then
            conn:Disconnect()
            return
        end

        if not ownerOK(hrp) then
            return
        end

        local dt = math.min(rawDt, CFG.DT_CAP)

        if hum.Health <= 0 then
            finish("Aborted: died")
            return
        end

        local maxHp = hum.MaxHealth
        if maxHp <= 0 then
            maxHp = 100
        end

        if hum.Health / maxHp < CFG.HEALTH_DROP then
            finish("Aborted: low health")
            return
        end

        local floorY = Workspace.FallenPartsDestroyHeight or -120
        local voidY = floorY + CFG.VOID_MARGIN

        if hrp.Position.Y < voidY then
            local g = groundHit(hrp, 400)
            if g then
                hrp.CFrame = CFrame.new(g.Position + Vector3.new(0, 4, 0))
                say("Void rescued")
            elseif diag.lastSafe.Magnitude > 0 then
                hrp.CFrame = CFrame.new(diag.lastSafe)
                say("Void rescued")
            else
                finish("Aborted: void")
            end
            return
        end

        if hum.FloorMaterial == Enum.Material.Air then
            diag.air = diag.air + dt
        else
            diag.air = 0
        end

        local liveCF = getCF()
        if not liveCF then
            finish("Target lost")
            return
        end

        local pos = hrp.Position
        local targetPos = liveCF.Position
        local toTarget = targetPos - pos
        local dist = toTarget.Magnitude

        if dist <= CFG.STOP_RADIUS then
            finish("Arrived", CFrame.lookAlong(targetPos, hrp.CFrame.LookVector))
            return
        end

        local budget = math.min(speed * dt, dist)
        if budget <= 0.02 then
            finish("Arrived", CFrame.lookAlong(targetPos, hrp.CFrame.LookVector))
            return
        end

        local direct = vec(toTarget, hrp.CFrame.LookVector)
        direct = direct.Unit

        local look = math.clamp(budget * 6 + 12, 16, 45)
        local now = os.clock()
        local heading = direct

        -- avoid never runs while noclip is active
        if CFG.AVOID and not CFG.NOCLIP then
            local forwardClear = clearDistance(pos, direct, look)

            if forwardClear < look then
                if now > dodgeUntil then
                    local bestScore = -1
                    local bestDir = nil
                    local bestSide = 0

                    for _, ang in ipairs(DODGE_ANGLES) do
                        local cand = CFrame.Angles(0, math.rad(ang), 0) * direct
                        local score = clearDistance(pos, cand, look)

                        local raised = (cand + Vector3.yAxis * 0.55).Unit
                        local raisedScore = clearDistance(pos, raised, look)
                        if raisedScore > score then
                            score = raisedScore
                            cand = raised
                        end

                        if dodgeSide ~= 0 then
                            if ang * dodgeSide > 0 then
                                score = score * 1.25
                            end
                        end

                        if score > bestScore then
                            bestScore = score
                            bestDir = cand
                            if ang > 0 then
                                bestSide = 1
                            else
                                bestSide = -1
                            end
                        end
                    end

                    if bestDir then
                        dodgeDir = bestDir
                        dodgeSide = bestSide
                        dodgeUntil = now + CFG.DODGE_HOLD
                    end
                end

                if dodgeDir and now < dodgeUntil then
                    heading = dodgeDir
                end
            else
                dodgeDir = nil
                dodgeSide = 0
            end
        end

        local walkSpeed = hum.WalkSpeed
        if walkSpeed < 1 then
            walkSpeed = 1
        end

        local cfPart = math.max(budget - walkSpeed * dt, 0)
        local vPart = math.min(walkSpeed, budget / math.max(dt, 0.0001))
        local destination = heading * cfPart

        if cfPart > 0 then
            local hit = Workspace:Raycast(pos, heading * (cfPart + 1), rayParams)
            if hit and hit.Distance <= cfPart + 1 then
                local stopAt = (hit.Position + hit.Normal) - pos
                if stopAt.Magnitude < cfPart then
                    destination = stopAt
                end
            end
        end

        local allowed = flyAllowed()
        local bob = 1
        if tick() % 0.4 < 0.2 then
            bob = -1
        end

        local mass = 1.5
        if allowed then
            mass = mass + 6 * bob
        end

        if not allowed and diag.air > CFG.AIR_LIMIT then
            if tpDown(hrp, hum) then
                mass = 0
            end
        end

        if destination.Magnitude > 0.0001 then
            local faceDir = heading
            if dist < 6 then
                faceDir = hrp.CFrame.LookVector
            end
            hrp.CFrame = CFrame.lookAlong(pos + destination, faceDir)
        end

        hrp.AssemblyLinearVelocity = heading * vPart + Vector3.new(0, mass, 0)

        local clockNow = os.clock()
        if clockNow - lastSafeAt > 0.4 then
            local g = groundHit(hrp, 90)
            if g and g.Distance < 80 then
                diag.lastSafe = hrp.Position
                lastSafeAt = clockNow
            end
        end

        -- keep collision off for parts added mid-flight
        if clockNow - lastNoclipAt > CFG.NOCLIP_TICK then
            lastNoclipAt = clockNow
            noclipOn(char)
        end

        if cfPart > 0 and cfPart < (speed * dt) * 0.22 then
            diag.stuck = diag.stuck + 1
            if diag.stuck > 8 then
                diag.stuck = 0
                diag.escapes = diag.escapes + 1
                hrp.CFrame = hrp.CFrame + Vector3.new(0, 5, 0)
                dodgeUntil = 0
                if diag.escapes > 4 then
                    finish("Aborted: stuck")
                end
            end
        end
    end)
end

----------------------------------------------------------------
-- reset then fly
----------------------------------------------------------------
local function resetThenGo(name, getCF, getInst, speed)
    if waitingRespawn then
        say("Already respawning")
        return
    end

    local hrp, char = getHRP()
    if not char then
        say("No character")
        return
    end

    local base = getCF()
    if not base then
        say("Bad CFrame for " .. name)
        return
    end

    if flying then
        abort()
    end

    local hum = char:FindFirstChildOfClass("Humanoid")

    local finished = false
    local conn = nil
    local fallbackUsed = false

    local function cleanup()
        if conn then
            conn:Disconnect()
            conn = nil
        end
    end

    local function launch(newChar)
        if finished then
            return
        end
        finished = true
        cleanup()
        waitingRespawn = false

        local hrpNew = newChar:WaitForChild("HumanoidRootPart", 10)
        local humNew = newChar:WaitForChild("Humanoid", 10)
        if not hrpNew or not humNew then
            say("Respawn failed")
            return
        end

        local waited = 0
        while humNew.Health <= 0 and waited < 2 do
            task.wait(0.1)
            waited = waited + 0.1
        end

        task.wait(0.15)
        say("Flying: " .. name)
        fly(name, getCF, getInst, speed)
    end

    conn = player.CharacterAdded:Connect(function(newChar)
        launch(newChar)
    end)

    waitingRespawn = true

    if not hum or hum.Health <= 0 then
        say("Waiting for respawn...")
    else
        say("Respawning...")
        pcall(function()
            hum.Health = 0
        end)
        pcall(function()
            char:BreakJoints()
        end)
    end

    -- nudge the game along if it uses a custom reset
    task.delay(1.5, function()
        if finished or fallbackUsed then
            return
        end
        if player.Character and player.Character:FindFirstChildOfClass("Humanoid") then
            local h = player.Character:FindFirstChildOfClass("Humanoid")
            if h and h.Health > 0 then
                fallbackUsed = true
                pcall(function()
                    player:LoadCharacter()
                end)
            end
        end
    end)

    task.delay(CFG.RESPAWN_WAIT, function()
        if finished then
            return
        end
        finished = true
        cleanup()
        waitingRespawn = false
        local live = player.Character
        if live and live:FindFirstChild("HumanoidRootPart") then
            say("Respawn timeout, flying anyway")
            fly(name, getCF, getInst, speed)
        else
            say("Respawn timeout")
        end
    end)
end

----------------------------------------------------------------
-- go
----------------------------------------------------------------
local function goTo(name, getCF, getInst)
    local hrp = getHRP()
    if not hrp then
        say("No character")
        return
    end

    local base = getCF()
    if not base then
        say("Bad CFrame for " .. name)
        return
    end

    local rawSpeed = tonumber(speedBox.Text) or CFG.SPEED
    local speed = math.clamp(rawSpeed, 20, 3000)

    local getter = function()
        local live = getCF()
        if not live then
            return nil
        end
        return live * CFrame.new(0, CFG.SEAT, 0)
    end

    resetThenGo(name, getter, getInst, speed)
end

----------------------------------------------------------------
-- bed discovery
----------------------------------------------------------------
local watched = {}

local function isBedName(text)
    local lower = string.lower(text)
    return string.find(lower, "bed", 1, true) ~= nil
end

local function findContainers()
    local out = {}
    local seen = {}

    local function add(inst)
        if seen[inst] then
            return
        end
        seen[inst] = true
        table.insert(out, inst)
    end

    local direct = Workspace:FindFirstChild("MapCFrames", true)
    if direct then
        add(direct)
    end

    for _, d in ipairs(Workspace:GetDescendants()) do
        if d:IsA("Folder") or d:IsA("Model") then
            if isBedName(d.Name) then
                add(d)
            end
        end
    end

    return out
end

local function collectBeds()
    local raw = {}
    local seen = {}

    local function consider(inst)
        if seen[inst] then
            return
        end

        local nameMatch = isBedName(inst.Name)
        local parentMatch = false
        if inst.Parent then
            parentMatch = isBedName(inst.Parent.Name)
        end

        if not (nameMatch or parentMatch) then
            return
        end

        local cf = cfOf(inst)
        if not cf then
            return
        end

        seen[inst] = true
        table.insert(raw, { name = inst.Name, inst = inst, pos = cf.Position })
    end

    for _, container in ipairs(findContainers()) do
        for _, d in ipairs(container:GetDescendants()) do
            consider(d)
        end
    end

    if #raw == 0 then
        for _, d in ipairs(Workspace:GetDescendants()) do
            if d:IsA("CFrameValue") then
                consider(d)
            end
        end
    end

    local merged = {}

    for _, entry in ipairs(raw) do
        local matched = false

        for _, kept in ipairs(merged) do
            if (kept.pos - entry.pos).Magnitude <= CFG.DUP_RADIUS then
                matched = true
                local keptNumbered = string.match(kept.name, "^%d") ~= nil
                local entryNumbered = string.match(entry.name, "^%d") ~= nil
                if entryNumbered and not keptNumbered then
                    kept.name = entry.name
                    kept.inst = entry.inst
                    kept.pos = entry.pos
                end
                break
            end
        end

        if not matched then
            table.insert(merged, entry)
        end
    end

    table.sort(merged, function(a, b)
        local na = tonumber(string.match(a.name, "^(%d+)")) or 999
        local nb = tonumber(string.match(b.name, "^(%d+)")) or 999
        if na ~= nb then
            return na < nb
        end
        return a.name < b.name
    end)

    return merged
end

local function refresh()
    for _, child in ipairs(list:GetChildren()) do
        if child:IsA("TextButton") then
            child:Destroy()
        end
    end

    local found = collectBeds()

    for index, entry in ipairs(found) do
        local color = resolveColor(entry.inst, index)

        local btn = new("TextButton", {
            Text = "",
            Font = Enum.Font.Gotham,
            TextSize = 12,
            TextColor3 = T.text,
            BackgroundColor3 = T.raised,
            BorderSizePixel = 0,
            Size = UDim2.new(1, 0, 0, 27),
            AutoButtonColor = true,
            LayoutOrder = index,
        }, list)
        corner(btn, 6)
        stroke(btn, color:Lerp(Color3.new(0, 0, 0), 0.25), 1, 0.25)
        hoverable(btn, T.raised, T.hover)

        local swatch = new("Frame", {
            Size = UDim2.fromOffset(4, 27),
            BackgroundColor3 = color,
            BorderSizePixel = 0,
            ZIndex = 2,
        }, btn)
        corner(swatch, 3)
        stroke(swatch, color, 1, 0.55)

        new("TextLabel", {
            Text = entry.name,
            Font = Enum.Font.GothamMedium,
            TextSize = 12,
            TextColor3 = T.text,
            BackgroundTransparency = 1,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            Size = UDim2.new(1, -18, 1, 0),
            Position = UDim2.new(0, 12, 0, 0),
            ZIndex = 2,
        }, btn)

        btn.MouseButton1Click:Connect(function()
            local cfGetter = function()
                return cfOf(entry.inst)
            end
            local instGetter = function()
                return entry.inst
            end
            goTo(entry.name, cfGetter, instGetter)
        end)
    end

    if #found == 0 then
        say("No beds found")
    else
        say(tostring(#found) .. " beds")
    end
end

local function watchContainers()
    for _, container in ipairs(findContainers()) do
        if not watched[container] then
            watched[container] = true
            container.ChildAdded:Connect(function()
                task.wait(0.15)
                if gui.Parent then
                    refresh()
                end
            end)
            container.ChildRemoved:Connect(function()
                task.wait(0.15)
                if gui.Parent then
                    refresh()
                end
            end)
        end
    end
end

refreshBtn.MouseButton1Click:Connect(function()
    watchContainers()
    refresh()
end)

----------------------------------------------------------------
-- init
----------------------------------------------------------------
ensureGroup()

player.CharacterAdded:Connect(function(char)
    abort()
    char:WaitForChild("HumanoidRootPart", 10)
    baseFilter(char)
    task.wait(0.3)
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if hrp then
        diag.lastSafe = hrp.Position
    else
        diag.lastSafe = Vector3.zero
    end
end)

local hrp0 = getHRP()
if hrp0 then
    baseFilter(player.Character)
    diag.lastSafe = hrp0.Position
end

watchContainers()
refresh()

task.spawn(function()
    while gui.Parent do
        task.wait(4)
        watchContainers()
    end
end)