-- Main.server.luau — Pasar Brainrot (roblox-brainrot-01, Stage 1)
-- SATU-SATUNYA Script server dan SATU-SATUNYA composition root.
-- Stage 1: require Config SAJA, bangun dunia 3D saat runtime, buat semua
-- RemoteEvent, kelola lifecycle pemain (tanpa DataStore, tanpa load),
-- dan jalankan loop utama 1 detik (masih kosong).
-- Economy / DataStore baru di-require Stage 2, Steal Stage 3, Flood Stage 4.
-- Spesifikasi: DESIGN.md bagian 16, 20.3 + MAIN-SERVER-PLAN.md.

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)

local PlayersService = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")

-- ---------------------------------------------------------------------------
-- State milik Main (composition root). Tidak ada modul lain yang membuat
-- tabel-tabel ini; modul stage berikutnya hanya menerima tabel ini sebagai
-- argumen (dependency injection, DESIGN.md 16.1).
-- ---------------------------------------------------------------------------

local Players = {} -- [Player] -> PlayerState (bentuk: DESIGN.md 16.4)
local ConveyorItems = {} -- array ConveyorItem (diisi loop spawn, Stage 4+)
local Crates = {} -- [crateId] -> CrateState (diisi Flood, Stage 4)
local Remotes = {} -- [nama] -> RemoteEvent di ReplicatedStorage.GameRemotes
local World = {
	PedestalPos = {}, -- [baseIdx][slotIdx] -> Vector3 (permukaan atas pedestal)
	BaseCenter = {}, -- [baseIdx] -> Vector3 (pusat lantai base)
}

local serverStart = os.clock()
local FloodState = {
	Phase = "Idle",
	PhaseEndsAt = nil, -- nil saat Idle (KOREKSI LANJUT: number?)
	NextFloodAt = serverStart + Config.FLOOD_FIRST,
	CycleActive = false,
	DebugPending = false,
}

local conveyorDirection = 1 -- 1 = bergerak ke +Z; dibalik tiap flood (Stage 4)
local sessionId = HttpService:GenerateGUID(false) -- satu sesi server (dipakai saveData Stage 2)

-- SATU-SATUNYA generator UID di server (DESIGN.md 16.1). Disuntikkan ke
-- modul yang butuh UID baru; modul tidak boleh membuat UID sendiri.
local function newUid()
	return HttpService:GenerateGUID(false)
end

-- Visual per base yang harus diubah runtime (bukan di Players):
-- kaca lock + papan nama pemilik.
local BaseVisuals = {} -- [baseIdx] -> { GlassParts, OwnerLabel, Headshot }
local BaseOwner = {} -- [baseIdx] -> Player | nil

-- ---------------------------------------------------------------------------
-- RemoteEvents (HANYA Main yang membuat RemoteEvent)
-- ---------------------------------------------------------------------------

local REMOTE_NAMES = {
	"FloodEvent",
	"MoneyUpdate",
	"StealResult",
	"Notify",
	"StealRequest",
	"PlaceRequest",
	"SellRequest",
	"LockRequest",
	"RebirthRequest",
	"ClaimRequest",
	"DebugFlood",
}

local function createRemotes()
	local folder = Instance.new("Folder")
	folder.Name = "GameRemotes"
	folder.Parent = ReplicatedStorage
	for _, name in ipairs(REMOTE_NAMES) do
		local event = Instance.new("RemoteEvent")
		event.Name = name
		event.Parent = folder
		Remotes[name] = event
	end
	return Remotes
end

-- ---------------------------------------------------------------------------
-- Bangun dunia 3D (runtime). Urutan: lighting -> terrain -> conveyor ->
-- plaza + SpawnLocation -> bases -> gates -> city -> trees -> lamps.
-- ---------------------------------------------------------------------------

local function makePart(name, size, position, material, color)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Position = position
	part.Material = material
	part.Color = color
	part.Anchored = true
	part.CanCollide = true
	part.Parent = Workspace
	return part
end

local function setupLighting()
	Lighting.ClockTime = 20.5
	Lighting.Brightness = 2
	Lighting.Ambient = Color3.fromRGB(90, 76, 102)
	Lighting.OutdoorAmbient = Color3.fromRGB(64, 56, 77)
	Lighting.EnvironmentDiffuseScale = 0.6
end

local function buildTerrain()
	-- Lantai batu 340 x 2 x 420, permukaan atas y = 0 (pusat y = -1).
	makePart(
		"Terrain",
		Config.TERRAIN_SIZE,
		Vector3.new(0, -1, 0),
		Enum.Material.Cobblestone,
		Color3.fromRGB(112, 104, 96)
	)
end

local function buildConveyor()
	-- Sabuk berjalan 30 x 0.5 x 320, permukaan atas y = 0.55 (pusat y = 0.3).
	makePart(
		"Conveyor",
		Config.CONVEYOR_SIZE,
		Config.CONVEYOR_POS,
		Enum.Material.WoodPlanks,
		Color3.fromRGB(150, 104, 58)
	)
end

local function buildPlaza()
	-- Plaza selatan 110 x 0.6 x 55 di sekitar z = 155, permukaan atas y = 0.6.
	makePart(
		"Plaza",
		Config.PLAZA_SIZE,
		Config.PLAZA_POS,
		Enum.Material.Slate,
		Color3.fromRGB(96, 88, 110)
	)

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "SpawnLocation"
	spawn.Size = Vector3.new(16, 1, 16)
	spawn.Position = Config.SPAWN_POS
	spawn.Material = Enum.Material.SmoothPlastic
	spawn.Color = Color3.fromRGB(80, 200, 120)
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Enabled = true
	spawn.Parent = Workspace
end

local BASE_FLOOR_COLORS = {
	Color3.fromRGB(178, 132, 84),
	Color3.fromRGB(140, 150, 178),
	Color3.fromRGB(178, 110, 96),
	Color3.fromRGB(120, 160, 120),
	Color3.fromRGB(178, 150, 90),
	Color3.fromRGB(150, 120, 170),
	Color3.fromRGB(110, 150, 150),
	Color3.fromRGB(180, 140, 110),
}

local function buildOneBase(baseIdx, xCenter, zCenter)
	local floorColor = BASE_FLOOR_COLORS[((baseIdx - 1) % #BASE_FLOOR_COLORS) + 1]

	-- Lantai base 56 x 0.8 x 46, permukaan atas y = 0.8 (pusat y = 0.4).
	local floor = makePart(
		"BaseFloor" .. baseIdx,
		Vector3.new(56, 0.8, 46),
		Vector3.new(xCenter, 0.4, zCenter),
		Enum.Material.WoodPlanks,
		floorColor
	)
	floor.Name = "BaseFloor" .. baseIdx
	World.BaseCenter[baseIdx] = Vector3.new(xCenter, 0.8, zCenter)

	-- 6 pedestal silinder (2 baris x 3 kolom), permukaan atas y = 1.7.
	World.PedestalPos[baseIdx] = {}
	local slotIdx = 0
	for row = 1, 2 do
		for col = 1, 3 do
			slotIdx = slotIdx + 1
			local px = xCenter + Config.SLOT_OFFSETS_X[col]
			local pz = zCenter + Config.SLOT_OFFSETS_Z[row]
			local pedestal = Instance.new("Part")
			pedestal.Name = "Pedestal" .. baseIdx .. "_" .. slotIdx
			pedestal.Shape = Enum.PartType.Cylinder
			pedestal.Size = Vector3.new(0.9, 3, 3)
			pedestal.CFrame = CFrame.new(px, 1.25, pz) * CFrame.Angles(0, 0, math.rad(90))
			pedestal.Material = Enum.Material.Marble
			pedestal.Color = Color3.fromRGB(210, 200, 185)
			pedestal.Anchored = true
			pedestal.CanCollide = true
			pedestal.Parent = Workspace
			World.PedestalPos[baseIdx][slotIdx] = Vector3.new(px, 1.7, pz)

			local prompt = Instance.new("ProximityPrompt")
			prompt.ActionText = "Pedestal"
			prompt.ObjectText = "Base " .. baseIdx
			prompt.HoldDuration = 0
			prompt.MaxActivationDistance = 12
			prompt.Enabled = false -- Stage 1: belum ada handler; diaktifkan Stage 3
			prompt:SetAttribute("PromptKind", "Pedestal")
			prompt:SetAttribute("OwnerUserId", 0)
			prompt:SetAttribute("SlotFilled", false)
			prompt:SetAttribute("BaseIdx", baseIdx)
			prompt:SetAttribute("SlotIdx", slotIdx)
			prompt.Parent = pedestal
		end
	end

	-- Papan nama pemilik (BillboardGui, y = 20.5) + papan "make.fun".
	local boardAnchor = Instance.new("Part")
	boardAnchor.Name = "OwnerBoardAnchor" .. baseIdx
	boardAnchor.Size = Vector3.new(1, 1, 1)
	boardAnchor.Position = Vector3.new(xCenter, 20.5, zCenter)
	boardAnchor.Transparency = 1
	boardAnchor.Anchored = true
	boardAnchor.CanCollide = false
	boardAnchor.Parent = Workspace

	local board = Instance.new("BillboardGui")
	board.Name = "OwnerBoard" .. baseIdx
	board.Size = UDim2.fromOffset(320, 110)
	board.StudsOffsetWorldSpace = Vector3.new(0, 0, 0)
	board.AlwaysOnTop = false
	board.LightInfluence = 0
	board.Parent = boardAnchor

	local ownerLabel = Instance.new("TextLabel")
	ownerLabel.Name = "OwnerName"
	ownerLabel.Size = UDim2.new(1, 0, 0.55, 0)
	ownerLabel.BackgroundTransparency = 1
	ownerLabel.Text = "BASE " .. baseIdx
	ownerLabel.TextColor3 = Color3.fromRGB(255, 240, 200)
	ownerLabel.TextScaled = true
	ownerLabel.Font = Enum.Font.GothamBold
	ownerLabel.Parent = board

	local funLabel = Instance.new("TextLabel")
	funLabel.Name = "MakeFunTag"
	funLabel.Position = UDim2.new(0, 0, 0.55, 0)
	funLabel.Size = UDim2.new(1, 0, 0.45, 0)
	funLabel.BackgroundTransparency = 1
	funLabel.Text = "make.fun"
	funLabel.TextColor3 = Color3.fromRGB(140, 220, 255)
	funLabel.TextScaled = true
	funLabel.Font = Enum.Font.GothamBold
	funLabel.Parent = board

	-- Foto kepala pemilik (diisi saat base terisi; Stage 1: placeholder kosong).
	local headshot = Instance.new("ImageLabel")
	headshot.Name = "Headshot"
	headshot.Size = UDim2.fromOffset(48, 48)
	headshot.Position = UDim2.new(0, -56, 0, 0)
	headshot.BackgroundTransparency = 1
	headshot.Image = ""
	headshot.Parent = board

	-- Kaca lock: dinding sekeliling base, tersembunyi sampai terkunci
	-- (Stage 3: setLockVisual menampilkan Transparency 0.5 + CanCollide).
	local glassParts = {}
	local glassColor = Color3.fromRGB(170, 220, 255)
	local function addGlass(name, size, position)
		local glass = Instance.new("Part")
		glass.Name = name
		glass.Size = size
		glass.Position = position
		glass.Material = Enum.Material.Glass
		glass.Color = glassColor
		glass.Transparency = 1
		glass.Anchored = true
		glass.CanCollide = false
		glass.Parent = Workspace
		table.insert(glassParts, glass)
	end
	-- Dinding utara/selatan (sepanjang x) dan timur/barat (sepanjang z).
	addGlass("LockGlassN" .. baseIdx, Vector3.new(56, 6, 0.5), Vector3.new(xCenter, 3.8, zCenter - 23))
	addGlass("LockGlassS" .. baseIdx, Vector3.new(56, 6, 0.5), Vector3.new(xCenter, 3.8, zCenter + 23))
	addGlass("LockGlassW" .. baseIdx, Vector3.new(0.5, 6, 46), Vector3.new(xCenter - 28, 3.8, zCenter))
	addGlass("LockGlassE" .. baseIdx, Vector3.new(0.5, 6, 46), Vector3.new(xCenter + 28, 3.8, zCenter))

	-- Lampu base (PointLight hangat, Range 30).
	local lightAnchor = Instance.new("Part")
	lightAnchor.Name = "BaseLightAnchor" .. baseIdx
	lightAnchor.Size = Vector3.new(1, 1, 1)
	lightAnchor.Position = Vector3.new(xCenter, 10, zCenter)
	lightAnchor.Transparency = 1
	lightAnchor.Anchored = true
	lightAnchor.CanCollide = false
	lightAnchor.Parent = Workspace
	local baseLight = Instance.new("PointLight")
	baseLight.Color = Color3.fromRGB(255, 190, 120)
	baseLight.Range = 30
	baseLight.Brightness = 1
	baseLight.Parent = lightAnchor

	BaseVisuals[baseIdx] = {
		GlassParts = glassParts,
		OwnerLabel = ownerLabel,
		Headshot = headshot,
	}
	BaseOwner[baseIdx] = nil
end

local function buildBases()
	for side = 1, 2 do
		local xCenter = Config.BASE_X[side]
		for row = 1, 4 do
			local baseIdx = (side - 1) * 4 + row
			buildOneBase(baseIdx, xCenter, Config.BASE_Z[row])
		end
	end
end

local function buildGates()
	-- Gapura utara (z = -205) dan selatan (z = +205) + pagar pembatas.
	for _, gateZ in ipairs({ -205, 205 }) do
		for _, pillarX in ipairs({ -10, 10 }) do
			makePart(
				"GatePillar",
				Vector3.new(4, 12, 4),
				Vector3.new(pillarX, 6, gateZ),
				Enum.Material.Brick,
				Color3.fromRGB(150, 60, 60)
			)
		end
		makePart(
			"GateBeam",
			Vector3.new(24, 3, 4),
			Vector3.new(0, 13.5, gateZ),
			Enum.Material.Wood,
			Color3.fromRGB(120, 70, 40)
		)
	end
	-- Pagar sisi timur/barat dan ujung utara/selatan.
	makePart("FenceW", Vector3.new(0.5, 3, 400), Vector3.new(-168, 1.5, 0), Enum.Material.Wood, Color3.fromRGB(110, 80, 50))
	makePart("FenceE", Vector3.new(0.5, 3, 400), Vector3.new(168, 1.5, 0), Enum.Material.Wood, Color3.fromRGB(110, 80, 50))
	makePart("FenceN", Vector3.new(336, 3, 0.5), Vector3.new(0, 1.5, -208), Enum.Material.Wood, Color3.fromRGB(110, 80, 50))
	makePart("FenceS", Vector3.new(336, 3, 0.5), Vector3.new(0, 1.5, 208), Enum.Material.Wood, Color3.fromRGB(110, 80, 50))
end

local function buildCity()
	-- Bangunan kota di kejauhan (sekitar x = ±162, z = ±202) sebagai latar.
	-- Posisi + tinggi deterministik (aritmetika, tanpa math.random).
	local spots = {}
	for i = 1, 6 do
		table.insert(spots, { x = -162, z = -180 + (i - 1) * 72 })
		table.insert(spots, { x = 162, z = -180 + (i - 1) * 72 })
	end
	for i = 1, 5 do
		table.insert(spots, { x = -120 + (i - 1) * 60, z = -202 })
		table.insert(spots, { x = -120 + (i - 1) * 60, z = 202 })
	end
	for i, spot in ipairs(spots) do
		local height = 20 + ((i * 37) % 40)
		local width = 14 + ((i * 13) % 10)
		makePart(
			"CityBuilding",
			Vector3.new(width, height, width),
			Vector3.new(spot.x, height / 2, spot.z),
			Enum.Material.Concrete,
			Color3.fromRGB(52, 52, 68)
		)
	end
end

local function buildTrees()
	-- 48 pohon di tepi conveyor (x = ±20, 24 per sisi).
	local trunkColor = Color3.fromRGB(110, 70, 40)
	local leafColor = Color3.fromRGB(40, 120, 60)
	for side = 1, 2 do
		local treeX = (side == 1) and -20 or 20
		for i = 1, 24 do
			local treeZ = -150 + (i - 1) * 13
			local trunk = makePart(
				"TreeTrunk",
				Vector3.new(1, 4, 1),
				Vector3.new(treeX, 2, treeZ),
				Enum.Material.Wood,
				trunkColor
			)
			trunk.Name = "TreeTrunk"
			local leaves = Instance.new("Part")
			leaves.Name = "TreeLeaves"
			leaves.Shape = Enum.PartType.Ball
			leaves.Size = Vector3.new(5, 5, 5)
			leaves.Position = Vector3.new(treeX, 6, treeZ)
			leaves.Material = Enum.Material.SmoothPlastic
			leaves.Color = leafColor
			leaves.Anchored = true
			leaves.CanCollide = false
			leaves.Parent = Workspace
		end
	end
end

local function buildLamps()
	-- 14 lampu jalan (bola Neon + PointLight hangat, Range 22).
	for side = 1, 2 do
		local lampX = (side == 1) and -18 or 18
		for i = 1, 7 do
			local lampZ = -140 + (i - 1) * 46
			makePart(
				"LampPole",
				Vector3.new(0.6, 7, 0.6),
				Vector3.new(lampX, 3.5, lampZ),
				Enum.Material.Metal,
				Color3.fromRGB(40, 40, 45)
			)
			local bulb = Instance.new("Part")
			bulb.Name = "LampBulb"
			bulb.Shape = Enum.PartType.Ball
			bulb.Size = Vector3.new(1.6, 1.6, 1.6)
			bulb.Position = Vector3.new(lampX, 7.4, lampZ)
			bulb.Material = Enum.Material.Neon
			bulb.Color = Color3.fromRGB(255, 200, 100)
			bulb.Anchored = true
			bulb.CanCollide = false
			bulb.Parent = Workspace
			local light = Instance.new("PointLight")
			light.Color = Color3.fromRGB(255, 190, 110)
			light.Range = 22
			light.Brightness = 1.5
			light.Parent = bulb
		end
	end
end

local function buildWorld()
	setupLighting()
	buildTerrain()
	buildConveyor()
	buildPlaza()
	buildBases()
	buildGates()
	buildCity()
	buildTrees()
	buildLamps()
end

-- ---------------------------------------------------------------------------
-- Base: assign / release / papan nama
-- ---------------------------------------------------------------------------

local function refreshOwnerBoard(baseIdx)
	local visuals = BaseVisuals[baseIdx]
	if not visuals then
		return
	end
	local owner = BaseOwner[baseIdx]
	if owner then
		visuals.OwnerLabel.Text = owner.Name
		-- Foto kepala pemilik (async, jangan blokir lifecycle).
		task.spawn(function()
			local ok, thumb = pcall(function()
				return PlayersService:GetUserThumbnailAsync(
					owner.UserId,
					Enum.ThumbnailType.HeadShot,
					Enum.ThumbnailSize.Size100x100
				)
			end)
			if ok and BaseOwner[baseIdx] == owner then
				visuals.Headshot.Image = thumb
			end
		end)
	else
		visuals.OwnerLabel.Text = "BASE " .. baseIdx
		visuals.Headshot.Image = ""
	end
end

-- Memberi base kosong pertama kepada pemain; nil kalau penuh.
local function assignBase(player)
	local state = Players[player]
	if not state then
		return nil
	end
	for baseIdx = 1, Config.BASE_COUNT do
		if BaseOwner[baseIdx] == nil then
			BaseOwner[baseIdx] = player
			state.Base = baseIdx
			refreshOwnerBoard(baseIdx)
			return baseIdx
		end
	end
	return nil
end

-- Membersihkan base milik pemain (slot + visual dihapus, base bebas lagi).
-- Stage 1: belum ada visual slot (slot diisi Stage 2+); yang dibersihkan
-- di sini adalah kepemilikan base + papan nama.
local function releaseBase(player)
	local state = Players[player]
	if not state or not state.Base then
		return
	end
	local baseIdx = state.Base
	BaseOwner[baseIdx] = nil
	state.Base = nil
	refreshOwnerBoard(baseIdx)
end

local function getPlayerState(player)
	return Players[player]
end

-- ---------------------------------------------------------------------------
-- Lifecycle pemain — STAGE 1 (tanpa DataStore, tanpa load, tanpa save).
-- LoadStatus dibuat "ok" sejak awal; TIDAK ADA LoadToken, TIDAK ADA
-- load gating. (DESIGN.md 20.3 Stage 1 + MAIN-SERVER-PLAN langkah 4A.)
-- ---------------------------------------------------------------------------

local function onPlayerAdded(player)
	Players[player] = {
		Money = Config.START_MONEY,
		Rebirths = 0,
		IncomeMult = 1,
		Base = nil,
		Slots = {},
		Carried = nil,
		Locked = false,
		LockExpiresAt = nil,
		LastStealAt = 0,
		LastStealAttemptAt = 0,
		LoadStatus = "ok",
		LoadedDataVersion = nil,
		LoadedRevision = nil,
		LoadToken = nil,
	}
	assignBase(player)
end

local function onPlayerRemoving(player)
	releaseBase(player)
	Players[player] = nil
end

local function onBindToClose()
	-- Stage 1: tidak melakukan apa pun (tidak ada DataStore untuk disimpan).
end

-- ---------------------------------------------------------------------------
-- Start
-- ---------------------------------------------------------------------------

createRemotes()
buildWorld()

PlayersService.PlayerAdded:Connect(onPlayerAdded)
PlayersService.PlayerRemoving:Connect(onPlayerRemoving)
game:BindToClose(onBindToClose)

-- Pemain yang sudah ada sebelum script jalan (misal Play Solo di Studio).
for _, player in ipairs(PlayersService:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end

-- Loop utama 1 detik (SATU-SATUNYA loop; milik Main).
-- Stage 1: loop kosong — income (Stage 2), lock expiry (Stage 3),
-- flood + crate expiry (Stage 4) baru ditambahkan pada stage-nya.
task.spawn(function()
	while true do
		task.wait(1)
	end
end)
