--[[
	Bed Teleporter v13
	-------------------------------------------------------------
	X              close
	_              minimize
	RightShift     toggle minimized
	W A S D Space  cancel travel

	Presets: Stealth / Normal / Fast
	Noclip runs on every part and drops 10 studs out, collision returns.
--]]

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace        = game:GetService("Workspace")

local player = Players.LocalPlayer
local env    = (getgenv and getgenv()) or _G

if env.BedUI and env.BedUI.Destroy then pcall(env.BedUI.Destroy) end

local getconns = getconnections or get_signal_conn or nil

--// ----------------------------------------------------------
--// config
--// ----------------------------------------------------------
local CFG = {
	SPEED       = 400,
	ACCEL       = 1400,
	TURN        = 7,
	CRUISE      = 34,
	CRUISE_MAX  = 240,
	DESCEND     = 260,
	LAND        = 45,
	STOP        = 3.5,
	SEAT        = 4,
	COLLIDE_AT  = 10,
	DT_CAP      = 1 / 20,
	MAX_STEP    = 46,
	AVOID       = true,
	PROBE_MIN   = 7,
	PROBE_MAX   = 52,
	PROBE_SCALE = 0.15,
	NOCLIP      = true,
	SOFT_LAND   = true,
	JITTER      = true,
	PATH_PLAN   = true,
	STUCK_WIN   = 10,
	STUCK_RATIO = 0.22,
	STUCK_LIMIT = 3,
	NUDGE       = 6,
	ESCAPES     = 3,
	VOID_MARGIN = 45,
	HEALTH_MIN  = 0.55,
	SAFE_SAMPLE = 0.4,
	SETTLE      = 0.14,
	MAX_TIME    = 60,
}

local PRESETS = {
	{ name = "Stealth", speed = 280, cruise = 22, noclip = false, jitter = false },
	{ name = "Normal",  speed = 400, cruise = 34, noclip = true,  jitter = true },
	{ name = "Fast",    speed = 900, cruise = 55, noclip = true,  jitter = true },
}

local activePreset = 2

--// ----------------------------------------------------------
--// state
--// ----------------------------------------------------------
local PH = {
	IDLE = "idle", PREP = "prep", ASCEND = "ascend", CRUISE = "cruise",
	DESCEND = "descend", SETTLE = "settle", RECOVER = "recover",
}

local state  = PH.IDLE
local flying = false
local token  = 0
local disabler = false

local diag = {
	speed = 0, stuck = 0, escapes = 0, peak = 0,
	dist = 0, lastSafe = Vector3.zero, cruiseY = 0,
}

local acHits, disabledConns = {}, {}
local kickHooked = false
local bedCache, searchTerm = {}, ""
local startTravel, refreshList

--// ----------------------------------------------------------
--// util
--// ----------------------------------------------------------
local function new(class, props, parent)
	local inst = Instance.new(class)
	if props then
		for k, v in next, props do
			if k ~= "Parent" then pcall(function() inst[k] = v end) end
		end
	end
	if parent then inst.Parent = parent end
	return inst
end

local function corner(o, r) new("UICorner", { CornerRadius = UDim.new(0, r or 6) }, o) end
local function stroke(o, c, t) new("UIStroke", { Color = c, Thickness = t or 1 }, o) end
local function pad(o, n)
	new("UIPadding", {
		PaddingLeft = UDim.new(0, n), PaddingRight = UDim.new(0, n),
		PaddingTop = UDim.new(0, n), PaddingBottom = UDim.new(0, n),
	}, o)
end

local function getHRP()
	local c = player.Character
	return c and c:FindFirstChild("HumanoidRootPart"), c
end

local function cfOf(i)
	if not i or not i.Parent then return nil end
	if i:IsA("CFrameValue") then return i.Value
	elseif i:IsA("BasePart") then return i.CFrame
	elseif i:IsA("Model") then
		local p = i.PrimaryPart or i:FindFirstChildWhichIsA("BasePart", true)
		return p and p.CFrame
	elseif i:IsA("Attachment") then return i.WorldCFrame end
	return nil
end

local function safeVec(v, fb)
	if typeof(v) ~= "Vector3" or v ~= v or v.Magnitude < 1e-4 then return fb end
	return v
end

local function voidY()
	local f = Workspace.FallenPartsDestroyHeight
	if f and f < 0 then return f + CFG.VOID_MARGIN end
	return -120
end

local function fmtDist(n)
	if n >= 1000 then return ("%.1fk"):format(n / 1000) end
	return ("%d"):format(math.floor(n))
end

local function awaitCharacter(timeout)
	local t0, char = os.clock(), player.Character
	while (not char or not char.Parent
		or not char:FindFirstChild("HumanoidRootPart")
		or not char:FindFirstChildOfClass("Humanoid")) do
		if os.clock() - t0 > (timeout or 6) then return nil end
		task.wait(0.05)
		char = player.Character
	end
	return char
end

--// ----------------------------------------------------------
--// theme
--// ----------------------------------------------------------
local T = {
	bg = Color3.fromRGB(19, 19, 23), bar = Color3.fromRGB(31, 31, 37),
	sunken = Color3.fromRGB(25, 25, 30), field = Color3.fromRGB(41, 41, 49),
	line = Color3.fromRGB(62, 62, 74), text = Color3.fromRGB(232, 232, 238),
	dim = Color3.fromRGB(150, 150, 162), faint = Color3.fromRGB(112, 112, 124),
	accent = Color3.fromRGB(74, 118, 205), good = Color3.fromRGB(52, 124, 82),
	warn = Color3.fromRGB(150, 108, 46), bad = Color3.fromRGB(178, 62, 62),
}

--// ----------------------------------------------------------
--// shell
--// ----------------------------------------------------------
local parentGui = (gethui and gethui())
	or player:FindFirstChildOfClass("PlayerGui")
	or game:GetService("CoreGui")

local gui = new("ScreenGui", {
	Name = "BedUI", ResetOnSpawn = false, IgnoreGuiInset = true,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 9999,
}, parentGui)
env.BedUI = gui

local panel = new("Frame", {
	Size = UDim2.fromOffset(318, 540),
	Position = UDim2.new(0, 40, 0, 64),
	BackgroundColor3 = T.bg, BorderSizePixel = 0,
}, gui)
corner(panel, 10)
stroke(panel, T.line, 1)

local titleBar = new("Frame", {
	Size = UDim2.new(1, 0, 0, 34),
	BackgroundColor3 = T.bar, BorderSizePixel = 0,
}, panel)
corner(titleBar, 10)

new("TextLabel", {
	Text = "  bed teleporter", Font = Enum.Font.GothamBold, TextSize = 13,
	TextColor3 = T.text, BackgroundTransparency = 1,
	TextXAlignment = Enum.TextXAlignment.Left,
	Size = UDim2.new(1, -96, 1, 0),
}, titleBar)

local function titleBtn(text, x, color)
	local b = new("TextButton", {
		Text = text, Font = Enum.Font.GothamBold, TextSize = 12,
		TextColor3 = T.text, BackgroundColor3 = color, BorderSizePixel = 0,
		Size = UDim2.fromOffset(22, 20), Position = UDim2.new(1, x, 0, 7),
		AutoButtonColor = true,
	}, titleBar)
	corner(b, 5)
	return b
end

local refreshBtn = titleBtn("R", -86, T.field)
local minBtn     = titleBtn("_", -60, T.field)
local closeBtn   = titleBtn("X", -32, T.bad)

local diagBar = new("Frame", {
	Size = UDim2.new(1, 0, 0, 19),
	Position = UDim2.new(0, 0, 0, 34),
	BackgroundColor3 = T.sunken, BorderSizePixel = 0,
}, panel)

local diagLabel = new("TextLabel", {
	Text = "idle", Font = Enum.Font.Code, TextSize = 11,
	TextColor3 = T.dim, BackgroundTransparency = 1,
	TextXAlignment = Enum.TextXAlignment.Left,
	Size = UDim2.new(1, -10, 1, 0), Position = UDim2.new(0, 7, 0, 0),
}, diagBar)

local toast = new("Frame", {
	Size = UDim2.new(1, -16, 0, 0), Position = UDim2.new(0, 8, 0, 58),
	BackgroundColor3 = T.bad, BorderSizePixel = 0,
	Visible = false, ClipsDescendants = true,
}, panel)
corner(toast, 6)

local toastLabel = new("TextLabel", {
	Text = "", Font = Enum.Font.Gotham, TextSize = 11, TextWrapped = true,
	TextColor3 = T.text, BackgroundTransparency = 1,
	Size = UDim2.new(1, -14, 0, 0), Position = UDim2.new(0, 7, 0, 5),
	TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
}, toast)

local toastId = 0
local function say(text, kind, hold)
	toastId += 1
	local mine = toastId
	toast.BackgroundColor3 = (kind == "good" and T.good)
		or (kind == "warn" and T.warn) or T.bad
	toastLabel.Text = text
	toast.Size = UDim2.new(1, -16, 0, 22 + 14 * math.ceil(#text / 44))
	toast.Visible = true
	task.delay(hold or 2.4, function()
		if mine == toastId then toast.Visible = false end
	end)
end

--// ----------------------------------------------------------
--// tabs
--// ----------------------------------------------------------
local rail = new("Frame", {
	Size = UDim2.new(0, 76, 1, -74),
	Position = UDim2.new(0, 0, 0, 54),
	BackgroundColor3 = T.sunken, BorderSizePixel = 0,
}, panel)
new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, rail)
pad(rail, 6)

local pages = new("Frame", {
	Size = UDim2.new(1, -76, 1, -74),
	Position = UDim2.new(0, 76, 0, 54), BackgroundTransparency = 1,
}, panel)

local tabButtons, tabFrames = {}, {}
local activeTab

local function setTab(key)
	if activeTab == key then return end
	for k, f in next, tabFrames do f.Visible = (k == key) end
	for k, b in next, tabButtons do
		b.BackgroundColor3 = (k == key) and T.accent or T.field
		b.TextColor3 = (k == key) and Color3.new(1, 1, 1) or T.dim
	end
	activeTab = key
	if key == "beds" and refreshList then refreshList() end
end

local function makeTab(key, label, order)
	local b = new("TextButton", {
		Text = label, Font = Enum.Font.GothamSemibold, TextSize = 10,
		TextColor3 = T.dim, BackgroundColor3 = T.field, BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 28), LayoutOrder = order, AutoButtonColor = true,
	}, rail)
	corner(b, 5)
	tabButtons[key] = b

	local f = new("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
		BorderSizePixel = 0, ScrollBarThickness = 3,
		ScrollBarImageColor3 = T.faint, CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y, Visible = false,
	}, pages)
	new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, f)
	pad(f, 8)
	tabFrames[key] = f

	b.MouseButton1Click:Connect(function() setTab(key) end)
	return f
end

--// ----------------------------------------------------------
--// widgets
--// ----------------------------------------------------------
local function seq()
	local n = 0
	return function()
		n += 1
		return n * 10
	end
end

local function note(parent, order, text, color)
	return new("TextLabel", {
		Text = text, Font = Enum.Font.Gotham, TextSize = 10,
		TextColor3 = color or T.faint, BackgroundTransparency = 1,
		TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top, AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0), LayoutOrder = order,
	}, parent)
end

local function button(parent, order, text, color, height)
	local b = new("TextButton", {
		Text = text, Font = Enum.Font.GothamSemibold, TextSize = 11,
		TextColor3 = T.text, BackgroundColor3 = color or T.field,
		BorderSizePixel = 0, AutoButtonColor = true,
		Size = UDim2.new(1, 0, 0, height or 26), LayoutOrder = order,
	}, parent)
	corner(b, 5)
	return b
end

local function toggle(parent, order, text, get, set, blurb)
	local b = new("TextButton", {
		Text = "", Font = Enum.Font.GothamSemibold, TextSize = 11,
		TextColor3 = T.text, BorderSizePixel = 0, AutoButtonColor = true,
		Size = UDim2.new(1, 0, 0, 26), LayoutOrder = order,
	}, parent)
	corner(b, 5)
	new("UIPadding", { PaddingLeft = UDim.new(0, 9) }, b)

	new("TextLabel", {
		Text = text, Font = Enum.Font.GothamSemibold, TextSize = 11,
		TextColor3 = T.text, BackgroundTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, -60, 1, 0),
	}, b)

	local pill = new("TextLabel", {
		Text = "", Font = Enum.Font.GothamBold, TextSize = 9,
		TextColor3 = Color3.new(1, 1, 1), BackgroundColor3 = T.good,
		BorderSizePixel = 0, Size = UDim2.fromOffset(38, 15),
		Position = UDim2.new(1, -45, 0.5, -7),
	}, b)
	corner(pill, 4)

	local function paint()
		local on = get()
		pill.Text = on and "ON" or "OFF"
		pill.BackgroundColor3 = on and T.good or T.warn
		b.BackgroundColor3 = on and Color3.fromRGB(32, 44, 36) or T.field
	end
	paint()
	b.MouseButton1Click:Connect(function()
		set(not get())
		paint()
	end)

	if blurb then note(parent, order + 1, blurb) end
	return b
end

local function numField(parent, order, label, get, set, lo, hi, unit, blurb)
	local row = new("Frame", {
		Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1, LayoutOrder = order,
	}, parent)

	new("TextLabel", {
		Text = label, Font = Enum.Font.Gotham, TextSize = 11,
		TextColor3 = T.dim, BackgroundTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(0, 92, 1, 0),
	}, row)

	local box = new("TextBox", {
		Text = tostring(get()), Font = Enum.Font.Gotham, TextSize = 11,
		TextColor3 = T.text, BackgroundColor3 = T.field, BorderSizePixel = 0,
		ClearTextOnFocus = false, Size = UDim2.new(0, 62, 1, 0),
		Position = UDim2.new(0, 94, 0, 0),
	}, row)
	corner(box, 5)

	new("TextLabel", {
		Text = unit or "", Font = Enum.Font.Gotham, TextSize = 9,
		TextColor3 = T.faint, BackgroundTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(0, 60, 1, 0), Position = UDim2.new(0, 160, 0, 0),
	}, row)

	box.FocusLost:Connect(function()
		local v = tonumber(box.Text)
		if not v then box.Text = tostring(get()) return end
		v = math.clamp(v, lo, hi)
		box.Text = tostring(v)
		set(v)
	end)

	if blurb then note(parent, order + 1, blurb) end
	return box
end

--// ----------------------------------------------------------
--// drag + pill
--// ----------------------------------------------------------
local function draggable(handle, target)
	local dragging, from, origin

	handle.InputBegan:Connect(function(i)
		if i.UserInputType ~= Enum.UserInputType.MouseButton1
			and i.UserInputType ~= Enum.UserInputType.Touch then return end
		dragging, from, origin = true, i.Position, target.Position
		i.Changed:Connect(function()
			if i.UserInputState == Enum.UserInputState.End then dragging = false end
		end)
	end)

	UserInputService.InputChanged:Connect(function(i)
		if not dragging then return end
		if i.UserInputType ~= Enum.UserInputType.MouseMovement
			and i.UserInputType ~= Enum.UserInputType.Touch then return end
		local d = i.Position - from
		local vp = Workspace.CurrentCamera and Workspace.CurrentCamera.ViewportSize
			or Vector2.new(1280, 720)
		target.Position = UDim2.new(
			0, math.clamp(origin.X.Offset + d.X, 0, math.max(vp.X - target.AbsoluteSize.X, 0)),
			0, math.clamp(origin.Y.Offset + d.Y, 0, math.max(vp.Y - target.AbsoluteSize.Y, 0)))
	end)
end

local pill = new("Frame", {
	Size = UDim2.fromOffset(104, 28), Position = panel.Position,
	BackgroundColor3 = T.bar, BorderSizePixel = 0, Visible = false,
}, gui)
corner(pill, 8)
stroke(pill, T.line, 1)

local pillLabel = new("TextButton", {
	Text = "beds", Font = Enum.Font.GothamBold, TextSize = 11,
	TextColor3 = T.text, BackgroundTransparency = 1,
	Size = UDim2.new(1, -28, 1, 0), AutoButtonColor = false,
}, pill)

local pillClose = new("TextButton", {
	Text = "X", Font = Enum.Font.GothamBold, TextSize = 11,
	TextColor3 = T.text, BackgroundColor3 = T.bad, BorderSizePixel = 0,
	Size = UDim2.fromOffset(20, 18), Position = UDim2.new(1, -24, 0, 5),
	AutoButtonColor = true,
}, pill)
corner(pillClose, 5)

draggable(titleBar, panel)
draggable(pill, pill)

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

--// ----------------------------------------------------------
--// raycast
--// ----------------------------------------------------------
local probeParams = RaycastParams.new()
probeParams.FilterType = Enum.RaycastFilterType.Exclude
probeParams.IgnoreWater = true

local floorParams = RaycastParams.new()
floorParams.FilterType = Enum.RaycastFilterType.Exclude
floorParams.IgnoreWater = true

local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Exclude

local function refreshFilters(char)
	local ignore = {}
	if char then table.insert(ignore, char) end
	if Workspace.CurrentCamera then table.insert(ignore, Workspace.CurrentCamera) end
	probeParams.FilterDescendantsInstances = ignore
	floorParams.FilterDescendantsInstances = ignore
	overlapParams.FilterDescendantsInstances = ignore
end

local function groundBelow(hrp, depth)
	return Workspace:Raycast(hrp.Position, Vector3.new(0, -(depth or 60), 0), floorParams)
end

local function insideSolid(hrp)
	local parts = Workspace:GetPartBoundsInBox(hrp.CFrame, hrp.Size * 0.85, overlapParams)
	for _, p in next, parts do
		if p.CanCollide and p.Transparency < 1
			and not p:IsDescendantOf(player.Character) then
			return true
		end
	end
	return false
end

--// ----------------------------------------------------------
--// noclip
--// ----------------------------------------------------------
local noclipConn
local noclipOn = false
local collideLocked = false
local originals = setmetatable({}, { __mode = "k" })

local function startNoclip()
	if noclipOn then return end
	noclipOn = true

	noclipConn = RunService.RenderStepped:Connect(function()
		local char = player.Character
		if not char then return end
		for _, p in ipairs(char:GetDescendants()) do
			if p:IsA("BasePart") and p.CanCollide then
				originals[p] = true
				p.CanCollide = false
			end
		end
	end)
end

local function stopNoclip()
	if not noclipOn then return end
	noclipOn = false
	if noclipConn then noclipConn:Disconnect() noclipConn = nil end

	local char = player.Character
	if char then
		for _, p in ipairs(char:GetDescendants()) do
			if p:IsA("BasePart") then
				p.CanCollide = originals[p] ~= false
			end
		end
	end
	originals = setmetatable({}, { __mode = "k" })
end

local function syncNoclip()
	local want = CFG.NOCLIP and not collideLocked
	if want == noclipOn then return end
	if want then startNoclip() else stopNoclip() end
end

--// ----------------------------------------------------------
--// teardown
--// ----------------------------------------------------------
local function clearMovers(hrp)
	if not hrp then return end
	for _, n in ipairs({ "BVB", "AOB", "ATB" }) do
		local o = hrp:FindFirstChild(n)
		if o then pcall(function() o:Destroy() end) end
	end
end

local function restoreChar(hrp, hum)
	clearMovers(hrp)
	if hrp then
		pcall(function() hrp.AssemblyLinearVelocity = Vector3.zero end)
		pcall(function() hrp.AssemblyAngularVelocity = Vector3.zero end)
	end
	if hum then
		hum.PlatformStand = false
		hum.AutoRotate = true
		hum.WalkSpeed = 16
		pcall(function() hum:ChangeState(Enum.HumanoidStateType.Running) end)
	end
	if collideLocked then
		collideLocked = false
		stopNoclip()
	else
		syncNoclip()
	end
end

local function abort(msg, kind)
	token += 1
	flying = false
	state = PH.IDLE
	local hrp, char = getHRP()
	restoreChar(hrp, char and char:FindFirstChildOfClass("Humanoid"))
	if msg then say(msg, kind) end
end

local function destroyAll()
	abort()
	stopNoclip()
	gui:Destroy()
	env.BedUI = nil
end

closeBtn.MouseButton1Click:Connect(destroyAll)
pillClose.MouseButton1Click:Connect(destroyAll)
minBtn.MouseButton1Click:Connect(minimize)
pillLabel.MouseButton1Click:Connect(restore)
refreshBtn.MouseButton1Click:Connect(function()
	if refreshList then refreshList() end
end)

--// ----------------------------------------------------------
--// TAB: beds
--// ----------------------------------------------------------
local bedsTab = makeTab("beds", "Beds", 1)
local bedsSeq = seq()

local searchBox = new("TextBox", {
	Text = "", PlaceholderText = "filter by name...",
	Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = T.text,
	PlaceholderColor3 = T.faint, BackgroundColor3 = T.field,
	BorderSizePixel = 0, ClearTextOnFocus = false,
	Size = UDim2.new(1, 0, 0, 26), LayoutOrder = bedsSeq(),
}, bedsTab)
corner(searchBox, 5)
pad(searchBox, 8)
searchBox:GetPropertyChangedSignal("Text"):Connect(function()
	searchTerm = string.lower(searchBox.Text)
	if refreshList then refreshList() end
end)

local bedCount = note(bedsTab, bedsSeq(), "scanning...")

local bedList = new("Frame", {
	Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1, LayoutOrder = bedsSeq(),
}, bedsTab)
new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, bedList)

local function folder()
	return Workspace:FindFirstChild("MapCFrames", true)
end

local function collect()
	local out, seen = {}, {}
	local function consider(i)
		if not string.find(string.lower(i.Name), "bed", 1, true) then return end
		local cf = cfOf(i)
		if not cf then return end
		local key = tostring(cf)
		if seen[key] then return end
		seen[key] = true
		out[#out + 1] = { name = i.Name, inst = i, cf = cf }
	end
	local f = folder()
	if f then
		for _, d in ipairs(f:GetDescendants()) do consider(d) end
	end
	if #out == 0 then
		for _, d in ipairs(Workspace:GetDescendants()) do
			if d:IsA("CFrameValue") then consider(d) end
		end
	end
	return out
end

refreshList = function()
	for _, c in next, bedList:GetChildren() do
		if c:IsA("Frame") then c:Destroy() end
	end

	bedCache = collect()
	local hrp = getHRP()
	local origin = hrp and hrp.Position or Vector3.zero
	for _, e in ipairs(bedCache) do
		e.dist = (e.cf.Position - origin).Magnitude
	end
	table.sort(bedCache, function(a, b) return a.dist < b.dist end)

	local shown = 0
	for _, e in ipairs(bedCache) do
		if searchTerm == "" or string.find(string.lower(e.name), searchTerm, 1, true) then
			shown += 1
			if shown <= 140 then
				local row = new("TextButton", {
					Text = "", BackgroundColor3 = T.field, BorderSizePixel = 0,
					AutoButtonColor = true, Size = UDim2.new(1, 0, 0, 42),
					LayoutOrder = shown,
				}, bedList)
				corner(row, 5)

				new("TextLabel", {
					Text = e.name, Font = Enum.Font.Gotham, TextSize = 11,
					TextColor3 = T.text, BackgroundTransparency = 1,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextTruncate = Enum.TextTruncate.AtEnd,
					Size = UDim2.new(1, -48, 0, 21), Position = UDim2.new(0, 9, 0, 3),
				}, row)

				new("TextLabel", {
					Text = ("%s studs  |  y %d"):format(fmtDist(e.dist), math.floor(e.cf.Position.Y)),
					Font = Enum.Font.Gotham, TextSize = 9, TextColor3 = T.faint,
					BackgroundTransparency = 1,
					TextXAlignment = Enum.TextXAlignment.Left,
					Size = UDim2.new(1, -48, 0, 14), Position = UDim2.new(0, 9, 0, 24),
				}, row)

				local go = new("TextButton", {
					Text = "GO", Font = Enum.Font.GothamBold, TextSize = 10,
					TextColor3 = T.text, BackgroundColor3 = T.accent,
					BorderSizePixel = 0, AutoButtonColor = true,
					Size = UDim2.fromOffset(34, 20), Position = UDim2.new(1, -41, 0, 11),
				}, row)
				corner(go, 4)

				local function fire() startTravel(e) end
				go.MouseButton1Click:Connect(fire)
				row.MouseButton1Click:Connect(fire)
			end
		end
	end

	if #bedCache == 0 then
		bedCount.Text = "no beds found - is MapCFrames loaded?"
		bedCount.TextColor3 = T.warn
	else
		bedCount.Text = ("%d bed(s), %d shown"):format(#bedCache, shown)
		bedCount.TextColor3 = T.faint
	end
end

--// ----------------------------------------------------------
--// TAB: options
--// ----------------------------------------------------------
local optTab = makeTab("options", "Options", 2)
local optSeq = seq()

local presetRow = new("Frame", {
	Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1, LayoutOrder = optSeq(),
}, optTab)
local presetBtns = {}

for i, preset in ipairs(PRESETS) do
	local b = new("TextButton", {
		Text = preset.name, Font = Enum.Font.GothamBold, TextSize = 10,
		TextColor3 = T.dim, BackgroundColor3 = T.field, BorderSizePixel = 0,
		AutoButtonColor = true,
		Size = UDim2.new(1 / #PRESETS, -4, 1, 0),
		Position = UDim2.new((i - 1) / #PRESETS, 2, 0, 0),
	}, presetRow)
	corner(b, 5)
	presetBtns[i] = b

	b.MouseButton1Click:Connect(function()
		activePreset = i
		CFG.SPEED = preset.speed
		CFG.CRUISE = preset.cruise
		CFG.NOCLIP = preset.noclip
		CFG.JITTER = preset.jitter
		for k, other in ipairs(presetBtns) do
			other.BackgroundColor3 = (k == i) and T.accent or T.field
			other.TextColor3 = (k == i) and Color3.new(1, 1, 1) or T.dim
		end
		speedBox.Text = tostring(CFG.SPEED)
		cruiseBox.Text = tostring(CFG.CRUISE)
		syncNoclip()
	end)
end

for i, b in ipairs(presetBtns) do
	b.BackgroundColor3 = (i == activePreset) and T.accent or T.field
	b.TextColor3 = (i == activePreset) and Color3.new(1, 1, 1) or T.dim
end

note(optTab, optSeq(), "Presets set speed, cruise, noclip and jitter together.", T.faint)

local speedBox = numField(optTab, optSeq(), "Speed", function() return CFG.SPEED end,
	function(v) CFG.SPEED = v end, 20, 3000, "studs/s",
	"Travel speed. 400 clears most maps; above ~900 strict checks may sample gaps.")

local cruiseBox = numField(optTab, optSeq(), "Cruise", function() return CFG.CRUISE end,
	function(v) CFG.CRUISE = v end, 5, 400, "studs",
	"Altitude held above terrain on the way. Higher clears more but is more visible.")

numField(optTab, optSeq(), "Seat", function() return CFG.SEAT end,
	function(v) CFG.SEAT = v end, 0, 14, "studs",
	"Stop height above the bed marker. Raise if you land inside the mattress.")

numField(optTab, optSeq(), "Collide at", function() return CFG.COLLIDE_AT end,
	function(v) CFG.COLLIDE_AT = v end, 2, 60, "studs",
	"Distance from the bed where noclip drops and collision returns on every part.")

note(optTab, optSeq(), "safety", T.faint)

toggle(optTab, optSeq(), "Avoidance", function() return CFG.AVOID end,
	function(v) CFG.AVOID = v end,
	"Rays ahead and steers around or over anything solid in the path.")

toggle(optTab, optSeq(), "Noclip", function() return CFG.NOCLIP end,
	function(v) CFG.NOCLIP = v syncNoclip() end,
	"Collision is dropped on every part and restored inside the collide distance.")

toggle(optTab, optSeq(), "Soft landing", function() return CFG.SOFT_LAND end,
	function(v) CFG.SOFT_LAND = v end,
	"Slows over the final stretch so impact doesn't cost health.")

toggle(optTab, optSeq(), "Jitter", function() return CFG.JITTER end,
	function(v) CFG.JITTER = v end,
	"Sub-stud wobble on the travel vector. Turn off if a check is statistical.")

local stopBtn = button(optTab, optSeq(), "Cancel travel", T.bad)
stopBtn.MouseButton1Click:Connect(function()
	if flying then abort("Cancelled", "warn") end
end)

--// ----------------------------------------------------------
--// TAB: AC
--// ----------------------------------------------------------
local acTab = makeTab("ac", "AC", 3)
local acSeq = seq()

note(acTab, acSeq(),
	"Optional. Nothing here is needed for flight - it just removes what watches you.", T.dim)

local acResult = note(acTab, acSeq(), "not scanned yet")
local scanBtn  = button(acTab, acSeq(), "Scan for AC scripts")
local killBtn  = button(acTab, acSeq(), "Destroy found", T.bad)
local disBtn   = button(acTab, acSeq(), "Disabler: OFF", T.warn)
local restBtn  = button(acTab, acSeq(), "Restore connections")
local hookBtn  = button(acTab, acSeq(), "Install Kick hook")

local PATTERNS = {
	"anticheat", "anti_cheat", "anti cheat", "anti-cheat", "ac_", "_ac",
	"acscript", "acguard", "watchdog", "sentry", "exploit", "cheat", "sanity",
}

local function isACName(name)
	local l = string.lower(name)
	if #l < 3 then return false end
	for _, p in ipairs(PATTERNS) do
		if string.find(l, p, 1, true) then return true end
	end
	return false
end

local function scanAC()
	acHits = {}
	for _, d in ipairs(game:GetDescendants()) do
		if (d:IsA("LocalScript") or d:IsA("Script") or d:IsA("ModuleScript"))
			and isACName(d.Name) then
			table.insert(acHits, d)
		end
	end
	return #acHits
end

local function scriptOf(fn)
	local src
	pcall(function()
		if getinfo then
			local info = getinfo(fn)
			src = info and info.script
		end
	end)
	return src
end

local function disableConns()
	if not getconns then return 0 end
	local n = 0
	for _, sig in ipairs({ RunService.Heartbeat, RunService.RenderStepped, RunService.Stepped }) do
		for _, c in ipairs(getconns(sig)) do
			local src = scriptOf(c.Function)
			if src and isACName(src.Name) then
				pcall(function() c:Disable() end)
				table.insert(disabledConns, c)
				n += 1
			end
		end
	end
	return n
end

local function restoreConns()
	local n = 0
	for _, c in ipairs(disabledConns) do
		pcall(function() c:Enable() end)
		n += 1
	end
	disabledConns = {}
	return n
end

local function installKickHook()
	if kickHooked or not getrawmetatable or not hookmetamethod then return false end
	local mt = getrawmetatable(game)
	local old = mt.__namecall
	setreadonly(mt, false)
	mt.__namecall = newcclosure(function(self, ...)
		if disabler and getnamecallmethod() == "Kick" and self == player then return end
		return old(self, ...)
	end)
	setreadonly(mt, true)
	kickHooked = true
	return true
end

scanBtn.MouseButton1Click:Connect(function()
	local n = scanAC()
	acResult.Text = ("%d candidate script(s)"):format(n)
	acResult.TextColor3 = n > 0 and T.warn or T.faint
end)

killBtn.MouseButton1Click:Connect(function()
	if #acHits == 0 then scanAC() end
	local n = 0
	for _, i in ipairs(acHits) do
		if i and i.Parent then
			pcall(function()
				if i:IsA("LocalScript") then i.Disabled = true end
				i:Destroy()
			end)
			n += 1
		end
	end
	acHits = {}
	acResult.Text = ("destroyed %d script(s)"):format(n)
	acResult.TextColor3 = T.good
end)

restBtn.MouseButton1Click:Connect(function()
	acResult.Text = ("restored %d connection(s)"):format(restoreConns())
	acResult.TextColor3 = T.good
end)

hookBtn.MouseButton1Click:Connect(function()
	if installKickHook() then
		hookBtn.Text = "Kick hook: installed"
		hookBtn.BackgroundColor3 = T.good
	else
		hookBtn.Text = "Kick hook: unavailable"
	end
end)

disBtn.MouseButton1Click:Connect(function()
	disabler = not disabler
	if disabler then
		disBtn.Text = "Disabler: ON"
		disBtn.BackgroundColor3 = T.good
		if setthreadidentity then pcall(setthreadidentity, 8) end
		installKickHook()
		acResult.Text = ("disabled %d connection(s)"):format(disableConns())
	else
		disBtn.Text = "Disabler: OFF"
		disBtn.BackgroundColor3 = T.warn
		restoreConns()
		acResult.Text = "connections restored"
	end
end)

--// ----------------------------------------------------------
--// TAB: help
--// ----------------------------------------------------------
local helpTab = makeTab("help", "Help", 4)
local helpSeq = seq()

local HELP = {
	{ "Presets", "Stealth is slowest and quietest. Fast is 900 and clears long gaps. Normal is the middle." },
	{ "How it moves", "Velocity only, ramped in and out. The server sees continuous motion, not a jump." },
	{ "Noclip", "Drops collision on every part, then returns it inside the collide distance so you land properly." },
	{ "If you still get caught", "Stealth preset, and run the AC scan before travelling." },
	{ "If you get stuck", "Recovery pops you up and briefly clears collision. Past 3 tries it puts you on the nearest floor." },
	{ "If you fall", "The void guard returns you to the last ground position it recorded." },
	{ "Keys", "X close, _ minimize, RightShift toggle pill, WASD or Space cancel." },
}

for _, pair in ipairs(HELP) do
	new("TextLabel", {
		Text = pair[1], Font = Enum.Font.GothamBold, TextSize = 11,
		TextColor3 = T.text, BackgroundTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, 15), LayoutOrder = helpSeq(),
	}, helpTab)
	note(helpTab, helpSeq(), pair[2], T.dim)
	new("Frame", {
		Size = UDim2.new(1, 0, 0, 2), BackgroundTransparency = 1, LayoutOrder = helpSeq(),
	}, helpTab)
end

--// ----------------------------------------------------------
--// diag pump
--// ----------------------------------------------------------
task.spawn(function()
	while gui.Parent do
		local hrp, char = getHRP()
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		diagLabel.Text = ("%s | v%d | st%d | d%s | y%d | hp%d"):format(
			state, math.floor(diag.speed), diag.stuck, fmtDist(diag.dist),
			hrp and math.floor(hrp.Position.Y) or 0,
			hum and math.floor(hum.Health) or 0)
		diagLabel.TextColor3 = flying and Color3.fromRGB(126, 208, 144) or T.dim
		task.wait(0.2)
	end
end)

--// ----------------------------------------------------------
--// path planning
--// ----------------------------------------------------------
local function cruiseYFor(from, to)
	local base = math.max(from.Y, to.Y) + CFG.CRUISE
	if not CFG.PATH_PLAN then return math.min(base, from.Y + CFG.CRUISE_MAX) end
	local highest = from.Y
	for i = 1, 28 do
		local p = from:Lerp(to, i / 28)
		local hit = Workspace:Raycast(Vector3.new(p.X, p.Y + 260, p.Z),
			Vector3.new(0, -560, 0), floorParams)
		if hit then highest = math.max(highest, hit.Position.Y) end
	end
	return math.min(highest + CFG.CRUISE, from.Y + CFG.CRUISE_MAX)
end

--// ----------------------------------------------------------
--// avoidance
--// ----------------------------------------------------------
local ANGLES = { 0, 20, -20, 42, -42, 66, -66, 88, -88 }

local function steer(hrp, dir, speed)
	if not CFG.AVOID then return dir end

	local reach = math.clamp(speed * CFG.PROBE_SCALE, CFG.PROBE_MIN, CFG.PROBE_MAX)
	local flat = Vector3.new(dir.X, 0, dir.Z)
	local floorHit = Workspace:Raycast(hrp.Position, Vector3.new(0, -18, 0), floorParams)
	local lowGround = floorHit and floorHit.Distance < 9

	local best, bestScore = nil, -math.huge
	for _, deg in ipairs(ANGLES) do
		local d = CFrame.fromAxisAngle(Vector3.yAxis, math.rad(deg)) * flat
		if d.Magnitude > 1e-3 then
			d = d.Unit
			local hit = Workspace:Raycast(hrp.Position, d * reach, probeParams)
			local blocked = hit ~= nil and hit.Distance < reach

			local score = 100 - math.abs(deg) * 0.75
			if blocked then score -= 70 + (reach - hit.Distance) * 0.5 end
			if lowGround then score -= 18 end

			if score > bestScore then bestScore, best = score, d end
		end
	end

	if not best then return dir end
	return safeVec(best * 0.8 + Vector3.yAxis * 0.4, dir)
end

local function unstick(hrp)
	for _ = 1, 40 do
		if not insideSolid(hrp) then return true end
		hrp.CFrame = hrp.CFrame + Vector3.new(0, 2.5, 0)
		task.wait()
	end
	return false
end

local function recover(hrp, reason)
	diag.escapes += 1

	if diag.escapes > CFG.ESCAPES then
		local g = groundBelow(hrp, 400)
		if g then
			hrp.CFrame = CFrame.new(g.Position + Vector3.new(0, 4, 0))
		elseif diag.lastSafe.Magnitude > 0 then
			hrp.CFrame = CFrame.new(diag.lastSafe)
		end
		abort("Gave up: " .. reason, "warn")
		return false
	end

	hrp.CFrame = hrp.CFrame + Vector3.new(0, CFG.NUDGE, 0)
	diag.stuck = 0
	say("Recovering", "warn")
	syncNoclip()
	return true
end

local function guardOK(hrp, hum)
	if not hrp or not hrp.Parent then return false, "lost root" end
	if hum.Health <= 0 then return false, "died" end
	if hum.Health / math.max(hum.MaxHealth, 1) < CFG.HEALTH_MIN then return false, "low health" end
	if hrp.Position.Y < voidY() then return false, "void" end
	return true
end

--// ----------------------------------------------------------
--// flight
--// ----------------------------------------------------------
local function beginFlight(entry, getCF)
	local myToken, conn

	local function finish(msg, kind)
		if conn then conn:Disconnect() conn = nil end
		abort(msg, kind)
	end

	task.spawn(function()
		abort()
		token += 1
		myToken = token
		flying = true
		state = PH.PREP
		collideLocked = false

		local char = awaitCharacter(6)
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not hrp or not hum then return finish("No character", "bad") end

		refreshFilters(char)

		local base = getCF()
		if not base then return finish("No marker", "bad") end
		local seat = base * CFrame.new(0, CFG.SEAT, 0)

		diag.stuck, diag.escapes, diag.peak, diag.speed = 0, 0, 0, 0
		diag.lastSafe = hrp.Position
		diag.cruiseY = cruiseYFor(hrp.Position, seat.Position)

		hum.PlatformStand = true
		hum.AutoRotate = false
		hum.WalkSpeed = 0
		pcall(function() hrp.AssemblyLinearVelocity = Vector3.zero end)
		pcall(function() hrp.AssemblyAngularVelocity = Vector3.zero end)

		local bv = new("BodyVelocity", {
			Name = "BVB", MaxForce = Vector3.new(1e5, 1e5, 1e5),
			P = 4000, Velocity = Vector3.zero,
		}, hrp)

		local att = new("Attachment", { Name = "ATB" }, hrp)
		local ao = new("AlignOrientation", {
			Name = "AOB", Attachment0 = att,
			Mode = Enum.OrientationAlignmentMode.OneAttachment,
			AlignType = Enum.AlignmentType.Parallel,
			MaxTorque = 1e5, Responsiveness = 40,
		}, hrp)

		syncNoclip()

		state = PH.ASCEND

		local dir = safeVec(seat.Position - hrp.Position, Vector3.yAxis).Unit
		local yaw = hrp.CFrame
		local lastPos = hrp.Position
		local samples, idx = {}, 0
		local lastSafeAt, settleAt = 0, 0
		local startedAt = os.clock()
		local escapeUntil, escapeDir = 0, nil

		local function faceNow(pos, d)
			local flat = Vector3.new(d.X, 0, d.Z)
			if flat.Magnitude < 0.1 then
				flat = yaw.LookVector * Vector3.new(1, 0, 1)
			end
			if flat.Magnitude < 1e-3 then return end
			local cf = CFrame.lookAt(pos, pos + flat.Unit, Vector3.yAxis)
			yaw = cf
			ao.CFrame = cf
		end

		conn = RunService.Heartbeat:Connect(function(rawDt)
			if myToken ~= token or not flying then
				if conn then conn:Disconnect() conn = nil end
				return
			end

			if not hrp.Parent or not hum.Parent then return finish("Character lost", "bad") end
			if hum.PlatformStand ~= true then hum.PlatformStand = true end

			if state == PH.SETTLE then
				bv.Velocity = Vector3.zero
				hrp.AssemblyLinearVelocity = Vector3.zero
				if os.clock() >= settleAt then
					if insideSolid(hrp) then unstick(hrp) end
					finish("Arrived: " .. entry.name, "good")
				end
				return
			end

			local now = os.clock()
			if now - startedAt > CFG.MAX_TIME then return finish("Timed out", "warn") end

			local ok, why = guardOK(hrp, hum)
			if not ok then
				if why == "void" then
					local g = groundBelow(hrp, 700)
					if g then
						hrp.CFrame = CFrame.new(g.Position + Vector3.new(0, 5, 0))
						say("Void rescued", "warn")
						return
					elseif diag.lastSafe.Magnitude > 0 then
						hrp.CFrame = CFrame.new(diag.lastSafe)
						say("Void rescued", "warn")
						return
					end
				end
				return finish("Stopped: " .. why, "bad")
			end

			local dt = math.min(rawDt, CFG.DT_CAP)

			local liveCF = getCF()
			if not liveCF then return finish("Marker lost", "bad") end
			seat = liveCF * CFrame.new(0, CFG.SEAT, 0)

			local pos = hrp.Position
			local toTarget = seat.Position - pos
			local dist = toTarget.Magnitude
			local horiz = Vector3.new(toTarget.X, 0, toTarget.Z).Magnitude
			diag.dist = dist

			-- inside the landing window: collision comes back on for good
			if noclipOn and dist <= CFG.COLLIDE_AT then
				collideLocked = true
				stopNoclip()
				if insideSolid(hrp) then unstick(hrp) end
			end

			if dist <= CFG.STOP then
				hrp.CFrame = seat
				bv.Velocity = Vector3.zero
				hrp.AssemblyLinearVelocity = Vector3.zero
				state = PH.SETTLE
				settleAt = now + CFG.SETTLE
				return
			end

			local groundHit = groundBelow(hrp, 120)
			local gap = groundHit and groundHit.Distance or math.huge

			if state == PH.ASCEND then
				if pos.Y >= diag.cruiseY - 1 or horiz < 10 then
					state = PH.CRUISE
				end
			elseif state == PH.CRUISE then
				if horiz < math.max(10, CFG.CRUISE * 0.35) and now - escapeUntil > 0.6 then
					state = PH.DESCEND
				elseif pos.Y < diag.cruiseY - 8 then
					state = PH.ASCEND
				end
			elseif state == PH.DESCEND then
				if groundHit and groundHit.Distance < 4 and dist > CFG.STOP + 2
					and groundHit.Position.Y > seat.Position.Y + 3
					and now > escapeUntil then
					local perp = Vector3.new(-toTarget.Z, 0, toTarget.X)
					if perp.Magnitude > 1e-3 then
						escapeDir = perp.Unit * (math.random() < 0.5 and 1 or -1)
						escapeUntil = now + 0.55
					end
				end
			end

			local desired
			if now < escapeUntil and escapeDir then
				desired = escapeDir
			elseif state == PH.ASCEND then
				local flat = Vector3.new(toTarget.X, 0, toTarget.Z)
				desired = flat.Magnitude > 1
					and (Vector3.yAxis * 0.72 + flat.Unit * 0.45).Unit
					or Vector3.yAxis
			elseif state == PH.CRUISE then
				desired = safeVec(Vector3.new(toTarget.X, 0, toTarget.Z), dir)
			else
				desired = safeVec(toTarget, dir)
			end
			desired = safeVec(desired, dir).Unit

			local alpha = math.clamp(CFG.TURN * dt, 0, 1)
			dir = safeVec(CFrame.lookAt(Vector3.zero, dir)
				:Lerp(CFrame.lookAt(Vector3.zero, desired), alpha).LookVector, desired).Unit

			local avoiding = state ~= PH.DESCEND or now < escapeUntil
			if avoiding then
				dir = steer(hrp, dir, diag.speed)
				if gap < 7 then dir = (dir + Vector3.yAxis * 0.5).Unit end
			end

			if CFG.JITTER then
				dir = (dir + Vector3.new(
					(math.random() - 0.5) * 0.02,
					(math.random() - 0.5) * 0.02,
					(math.random() - 0.5) * 0.02)).Unit
			end

			local cap = CFG.SPEED
			if state == PH.DESCEND and now >= escapeUntil then
				cap = CFG.DESCEND
				if CFG.SOFT_LAND and dist < 26 then cap = CFG.LAND end
			end
			if collideLocked then cap = math.min(cap, CFG.LAND) end

			diag.speed = math.min(diag.speed + CFG.ACCEL * dt, cap)
			if diag.speed > diag.peak then diag.peak = diag.speed end

			local step = math.min(diag.speed * dt, CFG.MAX_STEP, dist)
			bv.Velocity = dir * (step / math.max(dt, 1e-4))
			hrp.AssemblyAngularVelocity = Vector3.zero

			if state ~= PH.DESCEND or now < escapeUntil then
				faceNow(pos, dir)
			end

			local moved = (pos - lastPos).Magnitude
			lastPos = pos

			if now - startedAt > 0.4 then
				idx = idx % CFG.STUCK_WIN + 1
				samples[idx] = moved

				local sum, n = 0, 0
				for i = 1, CFG.STUCK_WIN do
					local v = samples[i]
					if v then sum += v n += 1 end
				end
				if n >= CFG.STUCK_WIN then
					local expected = diag.speed * dt
					if sum / n < expected * CFG.STUCK_RATIO then
						diag.stuck += 1
						if diag.stuck >= CFG.STUCK_LIMIT then
							if not recover(hrp, "stuck") then return end
							samples, idx = {}, 0
							lastPos = hrp.Position
							dir = safeVec(seat.Position - hrp.Position, dir).Unit
							if state ~= PH.ASCEND then state = PH.CRUISE end
						end
					else
						diag.stuck = 0
					end
				end
			end

			if now - lastSafeAt > CFG.SAFE_SAMPLE then
				if groundHit and groundHit.Distance < 90 then
					diag.lastSafe = pos
					lastSafeAt = now
				end
			end
		end)
	end)
end

startTravel = function(entry)
	if not entry then return end
	local getCF = function() return cfOf(entry.inst) end
	say("Flying: " .. entry.name)
	beginFlight(entry, getCF)
end

--// ----------------------------------------------------------
--// input + lifecycle
--// ----------------------------------------------------------
UserInputService.InputBegan:Connect(function(i, gp)
	if gp then return end

	if i.KeyCode == Enum.KeyCode.RightShift then
		if not gui.Parent then return end
		if panel.Visible then minimize() else restore() end
		return
	end

	if i.KeyCode == Enum.KeyCode.X and not UserInputService:GetFocusedTextBox() then
		destroyAll()
		return
	end

	if flying then
		local k = i.KeyCode
		if k == Enum.KeyCode.W or k == Enum.KeyCode.A or k == Enum.KeyCode.S
			or k == Enum.KeyCode.D or k == Enum.KeyCode.Space
			or k == Enum.KeyCode.Escape then
			abort("Cancelled", "warn")
		end
	end
end)

player.CharacterAdded:Connect(function(char)
	abort()
	char:WaitForChild("HumanoidRootPart", 10)
	refreshFilters(char)
	task.wait(0.3)
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if hrp then diag.lastSafe = hrp.Position end
	syncNoclip()
end)

--// ----------------------------------------------------------
--// init
--// ----------------------------------------------------------
local f0 = folder()
if f0 then
	f0.ChildAdded:Connect(function()
		task.wait(0.15)
		if gui.Parent and activeTab == "beds" then refreshList() end
	end)
	f0.ChildRemoved:Connect(function()
		task.wait(0.15)
		if gui.Parent and activeTab == "beds" then refreshList() end
	end)
end

local hrp0 = getHRP()
if hrp0 then
	refreshFilters(player.Character)
	diag.lastSafe = hrp0.Position
end

setTab("beds")
syncNoclip()
say("Ready - pick a bed", "good")