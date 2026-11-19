-- Main.server.luau — Pasar Brainrot (roblox-brainrot-01, Stage 3)
-- SATU-SATUNYA Script server dan SATU-SATUNYA composition root.
-- Stage 3: require Config + Economy + DataStore + Steal, bangun dunia 3D
-- saat runtime, buat semua RemoteEvent, kelola lifecycle pemain dengan
-- load gating + LoadToken + save-sebelum-cleanup, wire Place/Sell/
-- Rebirth ke Economy, StealRequest ke Steal, LockRequest + barrier +
-- auto-unlock ditangani Main sendiri, dan jalankan loop utama 1 detik
-- (income tick + lock expiry tick).
-- Flood baru di-require Stage 4.
-- Spesifikasi: DESIGN.md bagian 16, 17, 20.3 + MAIN-SERVER-PLAN.md.

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local Economy = require(script.Parent.Economy)
local DataStore = require(script.Parent.DataStore)
local Steal = require(script.Parent.Steal)

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
		SlotModels = {}, -- [slotIdx] -> Model Brainrot di pedestal | nil
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

-- Lock base (DESIGN.md 19.1, Stage 3): status + visual kaca milik Main.
-- isLocked: Locked true + LockExpiresAt ada + timer belum lewat.
local function isLocked(player, now)
	local state = Players[player]
	if state == nil then
		return false
	end
	return state.Locked == true
		and state.LockExpiresAt ~= nil
		and now < state.LockExpiresAt
end

-- Tampilkan/sembunyikan kaca lock base: terkunci -> Transparency 0.5 +
-- CanCollide true; buka -> Transparency 1 + CanCollide false.
local function setLockVisual(baseIdx, locked)
	local visuals = BaseVisuals[baseIdx]
	if not visuals or not visuals.GlassParts then
		return
	end
	for _, glass in ipairs(visuals.GlassParts) do
		if locked then
			glass.Transparency = 0.5
			glass.CanCollide = true
		else
			glass.Transparency = 1
			glass.CanCollide = false
		end
	end
end

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
-- Visual slot di pedestal dihancurkan di sini agar tidak ada model
-- Brainrot yang tertinggal setelah pemiliknya keluar.
local function releaseBase(player)
	local state = Players[player]
	if not state or not state.Base then
		return
	end
	local baseIdx = state.Base
	local visuals = BaseVisuals[baseIdx]
	if visuals and visuals.SlotModels then
		for i = 1, Config.SLOT_COUNT do
			local model = visuals.SlotModels[i]
			if model then
				model:Destroy()
				visuals.SlotModels[i] = nil
			end
		end
	end
	-- Kaca lock disembunyikan saat base dilepas (pemilik keluar).
	setLockVisual(baseIdx, false)
	BaseOwner[baseIdx] = nil
	state.Base = nil
	refreshOwnerBoard(baseIdx)
end

local function getPlayerState(player)
	return Players[player]
end

-- ---------------------------------------------------------------------------
-- Visual Brainrot + load gating + handler gameplay (STAGE 2).
-- Main pemilik visual: model Brainrot dibuat/dihancurkan di sini dari
-- state (modul tidak pernah membuat Instance, DESIGN.md 16.2).
-- ---------------------------------------------------------------------------

local CarriedModels = {} -- [Player] -> Model Brainrot yang dibawa | nil

-- Ciri khas tiap Brainrot (DESIGN.md 3): badan + kepala + mata +
-- satu ciri pembeda. Ukuran/offset dalam satuan skala 1 (dikalikan
-- scale saat dibuat: pedestal 2.0, dibawa 1.4, peti 1.6 di Stage 4).
local BRAINROT_FEATURES = {
	AyamIkan = {
		{ Name = "Beak", Size = Vector3.new(0.3, 0.25, 0.4), Offset = Vector3.new(0, 1.95, 0.75), Color = Color3.fromRGB(255, 150, 0) },
		{ Name = "Comb", Size = Vector3.new(0.5, 0.35, 0.15), Offset = Vector3.new(0, 2.75, 0), Color = Color3.fromRGB(220, 40, 40) },
	},
	BabiTerbang = {
		{ Name = "WingL", Size = Vector3.new(0.9, 0.08, 0.6), Offset = Vector3.new(-1.1, 1.1, 0), Color = Color3.fromRGB(245, 245, 245) },
		{ Name = "WingR", Size = Vector3.new(0.9, 0.08, 0.6), Offset = Vector3.new(1.1, 1.1, 0), Color = Color3.fromRGB(245, 245, 245) },
	},
	AnjingEsTeh = {
		{ Name = "EarL", Size = Vector3.new(0.3, 0.6, 0.3), Offset = Vector3.new(-0.45, 2.8, 0), Color = Color3.fromRGB(120, 70, 30) },
		{ Name = "EarR", Size = Vector3.new(0.3, 0.6, 0.3), Offset = Vector3.new(0.45, 2.8, 0), Color = Color3.fromRGB(120, 70, 30) },
		{ Name = "Snout", Size = Vector3.new(0.5, 0.4, 0.4), Offset = Vector3.new(0, 1.85, 0.65), Color = Color3.fromRGB(200, 160, 110) },
	},
	KucingRendang = {
		{ Name = "EarL", Size = Vector3.new(0.35, 0.5, 0.15), Offset = Vector3.new(-0.4, 2.8, 0), Color = Color3.fromRGB(60, 60, 60) },
		{ Name = "EarR", Size = Vector3.new(0.35, 0.5, 0.15), Offset = Vector3.new(0.4, 2.8, 0), Color = Color3.fromRGB(60, 60, 60) },
		{ Name = "Tail", Size = Vector3.new(0.25, 0.9, 0.25), Offset = Vector3.new(0, 0.9, -0.95), Color = Color3.fromRGB(60, 60, 60) },
	},
	BeruangDurian = {
		{ Name = "Spike1", Size = Vector3.new(0.3, 0.5, 0.3), Offset = Vector3.new(-0.4, 1.7, 0), Color = Color3.fromRGB(30, 100, 40) },
		{ Name = "Spike2", Size = Vector3.new(0.3, 0.5, 0.3), Offset = Vector3.new(0, 1.85, 0), Color = Color3.fromRGB(30, 100, 40) },
		{ Name = "Spike3", Size = Vector3.new(0.3, 0.5, 0.3), Offset = Vector3.new(0.4, 1.7, 0), Color = Color3.fromRGB(30, 100, 40) },
	},
	HarimauApi = {
		{ Name = "Flame", Size = Vector3.new(0.5, 0.7, 0.2), Offset = Vector3.new(0, 2.85, 0), Color = Color3.fromRGB(255, 90, 0), Material = Enum.Material.Neon },
		{ Name = "EarL", Size = Vector3.new(0.3, 0.4, 0.15), Offset = Vector3.new(-0.4, 2.75, 0), Color = Color3.fromRGB(200, 60, 20) },
		{ Name = "EarR", Size = Vector3.new(0.3, 0.4, 0.15), Offset = Vector3.new(0.4, 2.75, 0), Color = Color3.fromRGB(200, 60, 20) },
	},
	GajahGamelan = {
		{ Name = "Trunk", Size = Vector3.new(0.35, 1.0, 0.35), Offset = Vector3.new(0, 1.4, 0.7), Color = Color3.fromRGB(150, 150, 150) },
		{ Name = "TuskL", Size = Vector3.new(0.18, 0.18, 0.8), Offset = Vector3.new(-0.45, 1.7, 0.75), Color = Color3.fromRGB(245, 245, 240) },
		{ Name = "TuskR", Size = Vector3.new(0.18, 0.18, 0.8), Offset = Vector3.new(0.45, 1.7, 0.75), Color = Color3.fromRGB(245, 245, 240) },
	},
}

local function addBrainrotPart(model, name, size, offset, color, material)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = CFrame.new(offset)
	part.Material = material or Enum.Material.SmoothPlastic
	part.Color = color
	part.Anchored = true
	part.CanCollide = false
	part.Parent = model
	return part
end

-- Model Brainrot sederhana (badan + kepala + mata + ciri khas) dengan
-- label nama + rarity + income. Origin model di kaki (y = 0) sehingga
-- PivotTo(CFrame.new(posisi permukaan)) meletakkannya tepat di atas
-- permukaan. Gajah Gamelan: tubuh EMAS (Metal), gading putih, mata hitam.
local function createBrainrotModel(kind, scale)
	local entry = Config.Roster[kind]
	if entry == nil then
		return nil
	end
	local s = scale or 1
	local model = Instance.new("Model")
	model.Name = "Brainrot_" .. kind
	local bodyColor = entry.Color
	local bodyMaterial = Enum.Material.SmoothPlastic
	if kind == "GajahGamelan" then
		bodyColor = Color3.fromRGB(255, 200, 60)
		bodyMaterial = Enum.Material.Metal
	end
	local body = addBrainrotPart(model, "Body",
		Vector3.new(1.6, 1.6, 1.6) * s, Vector3.new(0, 0.8 * s, 0),
		bodyColor, bodyMaterial)
	local head = addBrainrotPart(model, "Head",
		Vector3.new(1.2, 1.2, 1.2) * s, Vector3.new(0, 2.05 * s, 0),
		Color3.fromRGB(245, 240, 230), Enum.Material.SmoothPlastic)
	addBrainrotPart(model, "EyeL",
		Vector3.new(0.22, 0.28, 0.1) * s, Vector3.new(-0.3 * s, 2.1 * s, 0.62 * s),
		Color3.fromRGB(20, 20, 20), Enum.Material.SmoothPlastic)
	addBrainrotPart(model, "EyeR",
		Vector3.new(0.22, 0.28, 0.1) * s, Vector3.new(0.3 * s, 2.1 * s, 0.62 * s),
		Color3.fromRGB(20, 20, 20), Enum.Material.SmoothPlastic)
	local features = BRAINROT_FEATURES[kind]
	if features then
		for _, spec in ipairs(features) do
			addBrainrotPart(model, spec.Name, spec.Size * s, spec.Offset * s,
				spec.Color, spec.Material)
		end
	end
	-- Label nama + rarity + income di atas model.
	local label = Instance.new("BillboardGui")
	label.Name = "BrainrotLabel"
	label.Size = UDim2.fromOffset(180, 64)
	label.StudsOffsetWorldSpace = Vector3.new(0, 1.6 * s, 0)
	label.AlwaysOnTop = false
	label.LightInfluence = 0
	label.Parent = head
	local text = Instance.new("TextLabel")
	text.Name = "Label"
	text.Size = UDim2.new(1, 0, 1, 0)
	text.BackgroundTransparency = 1
	text.Text = entry.DisplayName .. "\n" .. entry.Rarity .. " - $" .. tostring(entry.Income) .. "/dtk"
	text.TextColor3 = Color3.fromRGB(255, 255, 255)
	text.TextScaled = true
	text.Font = Enum.Font.GothamBold
	text.Parent = label
	model.PrimaryPart = body
	return model
end

-- Perbarui visual pedestal: model Brainrot skala 2.0 + label kalau slot
-- terisi, kosong kalau tidak.
local function refreshSlotVisual(baseIdx, slotIdx)
	local visuals = BaseVisuals[baseIdx]
	if not visuals then
		return
	end
	local old = visuals.SlotModels[slotIdx]
	if old then
		old:Destroy()
		visuals.SlotModels[slotIdx] = nil
	end
	local owner = BaseOwner[baseIdx]
	if not owner then
		return
	end
	local state = Players[owner]
	if not state then
		return
	end
	local item = state.Slots[slotIdx]
	if item == nil then
		return
	end
	local pedestals = World.PedestalPos[baseIdx]
	if not pedestals then
		return
	end
	local pos = pedestals[slotIdx]
	if not pos then
		return
	end
	local model = createBrainrotModel(item.Kind, 2.0)
	if not model then
		return
	end
	model.Parent = Workspace
	model:PivotTo(CFrame.new(pos))
	visuals.SlotModels[slotIdx] = model
end

local function destroyCarriedModel(player)
	local old = CarriedModels[player]
	if old then
		old:Destroy()
		CarriedModels[player] = nil
	end
end

-- Pasang/lepas model Brainrot yang dibawa pemain (skala 1.4, di atas
-- kepala, mengikuti karakter lewat Weld). Dipanggil setelah place/
-- sell/rebirth, setelah load memulihkan Carried, dan setiap kali
-- karakter (re)spawn (CharacterAdded, DESIGN.md 8).
local function refreshCarriedVisual(player)
	local state = Players[player]
	destroyCarriedModel(player)
	if not state or state.Carried == nil then
		return
	end
	local character = player.Character
	if not character then
		return
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return
	end
	local model = createBrainrotModel(state.Carried.Kind, 1.4)
	if not model then
		return
	end
	model.Parent = character
	model:PivotTo(hrp.CFrame * CFrame.new(0, 2.2, 0))
	local body = model.PrimaryPart
	-- Las tiap part ke badan, lalu badan ke HumanoidRootPart.
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant ~= body then
			local weld = Instance.new("Weld")
			weld.Part0 = body
			weld.Part1 = descendant
			weld.C0 = body.CFrame:ToObjectSpace(descendant.CFrame)
			weld.C1 = CFrame.new()
			weld.Parent = body
			descendant.Anchored = false
			descendant.CanCollide = false
			descendant.Massless = true
		end
	end
	local rootWeld = Instance.new("Weld")
	rootWeld.Part0 = hrp
	rootWeld.Part1 = body
	rootWeld.C0 = hrp.CFrame:ToObjectSpace(body.CFrame)
	rootWeld.C1 = CFrame.new()
	rootWeld.Parent = body
	body.Anchored = false
	body.CanCollide = false
	body.Massless = true
	CarriedModels[player] = model
end

-- Load gating (DESIGN.md 16.5, mulai Stage 2): true hanya bila state
-- ada dan LoadStatus "ok" atau "new". Dipakai SEMUA handler gameplay.
local function isLoadReady(player)
	local state = Players[player]
	return state ~= nil and (state.LoadStatus == "ok" or state.LoadStatus == "new")
end

local function notifyLoadNotReady(player)
	local state = Players[player]
	if state and (state.LoadStatus == "failed" or state.LoadStatus == "corrupt") then
		Remotes.Notify:FireClient(player, "Data simpanan gagal dimuat — progres sesi ini tidak akan disimpan. Coba relog nanti.")
	else
		Remotes.Notify:FireClient(player, "Data sedang dimuat, tunggu sebentar.")
	end
end

-- Handler RemoteEvent -> fungsi modul (Main hanya validasi load gating
-- + meneruskan + menerapkan hasil ke visual; tanpa logika bisnis).
local function onPlaceRequest(player, slotIdx)
	if not isLoadReady(player) then
		notifyLoadNotReady(player)
		return
	end
	local state = Players[player]
	if not state or state.Base == nil then
		Remotes.Notify:FireClient(player, "Kamu belum punya base.")
		return
	end
	local baseIdx = state.Base
	local ok, msg = Economy.placeItem(Players, player, slotIdx, Remotes)
	Remotes.Notify:FireClient(player, msg)
	if ok then
		refreshSlotVisual(baseIdx, slotIdx)
		refreshCarriedVisual(player)
	end
end

local function onSellRequest(player, slotIdx)
	if not isLoadReady(player) then
		notifyLoadNotReady(player)
		return
	end
	local state = Players[player]
	if not state or state.Base == nil then
		Remotes.Notify:FireClient(player, "Kamu belum punya base.")
		return
	end
	local baseIdx = state.Base
	local ok, msg = Economy.sellSlot(Players, player, slotIdx, Remotes)
	Remotes.Notify:FireClient(player, msg)
	if ok then
		refreshSlotVisual(baseIdx, slotIdx)
	end
end

local function onRebirthRequest(player)
	if not isLoadReady(player) then
		notifyLoadNotReady(player)
		return
	end
	local state = Players[player]
	if not state then
		return
	end
	local baseIdx = state.Base
	local ok, msg = Economy.rebirth(Players, player, Remotes)
	Remotes.Notify:FireClient(player, msg)
	if ok then
		if baseIdx then
			for i = 1, Config.SLOT_COUNT do
				refreshSlotVisual(baseIdx, i)
			end
		end
		refreshCarriedVisual(player)
	end
end

-- Handler StealRequest (Stage 3): cek isLoadReady dulu, lalu
-- Steal.trySteal(Players, thief, baseIdx, slotIdx, Remotes, World).
-- StealResult di-fire modul lewat Remotes; Main hanya memperbarui
-- visual slot korban (kosong) + visual carried pencuri bila sukses.
local function onStealRequest(player, baseIdx, slotIdx)
	if not isLoadReady(player) then
		notifyLoadNotReady(player)
		return
	end
	local ok, _msg, victim, _item = Steal.trySteal(Players, player, baseIdx, slotIdx, Remotes, World)
	if ok and victim ~= nil then
		refreshSlotVisual(baseIdx, slotIdx)
		refreshCarriedVisual(player)
	end
end

-- Handler LockRequest (Stage 3, DESIGN.md 19.1): lock = state + visual
-- milik Main. Load gating: "loading" ditolak; "failed"/"corrupt"
-- DIIZINKAN lock (lock tidak mengubah data simpanan, 16.5).
local function onLockRequest(player, locked)
	if type(locked) ~= "boolean" then
		return
	end
	local state = Players[player]
	if not state then
		return
	end
	if state.LoadStatus == "loading" then
		notifyLoadNotReady(player)
		return
	end
	if state.Base == nil then
		Remotes.Notify:FireClient(player, "Kamu belum punya base.")
		return
	end
	local baseIdx = state.Base
	local now = os.clock()
	if locked then
		if isLocked(player, now) then
			-- Sudah terkunci (belum kedaluwarsa) -> PERPANJANG timer.
			state.LockExpiresAt = now + Config.LOCK_DURATION
			Remotes.Notify:FireClient(player, "Lock diperpanjang 30 detik")
		else
			state.Locked = true
			state.LockExpiresAt = now + Config.LOCK_DURATION
			setLockVisual(baseIdx, true)
			Remotes.Notify:FireClient(player, "Base terkunci 30 detik")
		end
	else
		state.Locked = false
		state.LockExpiresAt = nil
		setLockVisual(baseIdx, false)
		Remotes.Notify:FireClient(player, "Base dibuka")
	end
end

-- Tick auto-unlock 1 detik (Stage 3): kalau Locked dan timer habis ->
-- buka kunci, sembunyikan kaca, Notify "Lock base habis".
local function lockExpiryTick()
	local now = os.clock()
	for player, state in pairs(Players) do
		if state.Locked and state.LockExpiresAt ~= nil and now >= state.LockExpiresAt then
			state.Locked = false
			state.LockExpiresAt = nil
			if state.Base ~= nil then
				setLockVisual(state.Base, false)
			end
			Remotes.Notify:FireClient(player, "Lock base habis")
		end
	end
end

-- Barrier lock (DESIGN.md 19.1, Stage 3): Touched di tiap part kaca
-- lock tiap base. Pemain BUKAN pemilik yang menyentuh saat base
-- terkunci di-teleport keluar ke (DoorX +/- 6, 4, zCenter): base kiri
-- (xCenter -68, DoorX -41) -> x = -47; base kanan (xCenter +68,
-- DoorX +41) -> x = +47. Pemilik SELALU lolos (tidak di-teleport).
-- Saat tidak terkunci barrier tidak menghalangi (CanCollide false,
-- Transparency 1); handler tetap memeriksa isLocked.
local LockTeleportAt = {} -- [Player] -> os.clock() teleport terakhir (debounce 1 detik)
local function connectLockBarriers()
	for baseIdx = 1, Config.BASE_COUNT do
		local visuals = BaseVisuals[baseIdx]
		if visuals and visuals.GlassParts then
			local xCenter = Config.BASE_X[(baseIdx <= 4) and 1 or 2]
			local row = (baseIdx <= 4) and baseIdx or (baseIdx - 4)
			local zCenter = Config.BASE_Z[row]
			local doorX = (xCenter < 0) and (xCenter + 27) or (xCenter - 27)
			local targetX = (xCenter < 0) and (doorX - 6) or (doorX + 6)
			for _, glass in ipairs(visuals.GlassParts) do
				glass.Touched:Connect(function(otherPart)
					local character = otherPart.Parent
					local toucher = nil
					if character ~= nil then
						toucher = PlayersService:GetPlayerFromCharacter(character)
					end
					if toucher == nil then
						return
					end
					-- Pemilik base SELALU lolos.
					if BaseOwner[baseIdx] == toucher then
						return
					end
					local owner = BaseOwner[baseIdx]
					if owner == nil then
						return
					end
					if not isLocked(owner, os.clock()) then
						return
					end
					local lastTeleport = LockTeleportAt[toucher]
					local now = os.clock()
					if lastTeleport ~= nil and now - lastTeleport < 1 then
						return
					end
					LockTeleportAt[toucher] = now
					local hrp = character:FindFirstChild("HumanoidRootPart")
					if hrp ~= nil then
						hrp.CFrame = CFrame.new(targetX, 4, zCenter)
					end
				end)
			end
		end
	end
end

-- Tick income 1 detik (Stage 2): Economy.addIncome(Players, Remotes).
local function incomeTick()
	Economy.addIncome(Players, Remotes)
end

-- ---------------------------------------------------------------------------
-- Lifecycle pemain — STAGE 2 (DataStore + load gating + LoadToken).
-- (DESIGN.md 17.1, 17.2, 17.7 + MAIN-SERVER-PLAN langkah 4B.)
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
		LoadStatus = "loading",
		LoadedDataVersion = nil,
		LoadedRevision = nil,
		LoadToken = newUid(),
	}
	assignBase(player)
	-- Re-attach visual carried setiap kali karakter (re)spawn (DESIGN.md 8).
	player.CharacterAdded:Connect(function()
		refreshCarriedVisual(player)
	end)
	local state = Players[player]
	local token = state.LoadToken
	-- Load dalam task.spawn terpisah: satu pemain yang load-nya lambat
	-- tidak boleh memblokir pemain lain (DESIGN.md 17.1).
	task.spawn(function()
		local data, status = DataStore.loadData(player)
		local current = Players[player]
		-- Perlindungan load terlambat (17.7): terapkan hasil HANYA bila
		-- ketiga syarat lolos; kalau tidak, buang hasil tanpa efek.
		if current == nil then
			print("[Main] load dibuang: " .. player.Name .. " sudah keluar.")
			return
		end
		if current.LoadToken == nil then
			print("[Main] load dibuang: LoadToken nil untuk " .. player.Name .. ".")
			return
		end
		if current.LoadToken ~= token then
			print("[Main] load dibuang: LoadToken tidak cocok untuk " .. player.Name .. ".")
			return
		end
		if status == "ok" and data ~= nil then
			current.Money = data.Money
			current.Rebirths = data.Rebirths
			current.IncomeMult = 1 + data.Rebirths * 0.5
			current.LoadedRevision = data.Revision
			current.LoadedDataVersion = data.Version
			current.Slots = {}
			for i = 1, Config.SLOT_COUNT do
				local item = data.Slots[tostring(i)]
				if item ~= nil then
					current.Slots[i] = { Uid = item.Uid, Kind = item.Kind }
				end
			end
			if data.Carried ~= nil then
				current.Carried = { Uid = data.Carried.Uid, Kind = data.Carried.Kind }
			end
			current.LoadStatus = "ok"
			if current.Base ~= nil then
				for i = 1, Config.SLOT_COUNT do
					refreshSlotVisual(current.Base, i)
				end
			end
			refreshCarriedVisual(player)
		elseif status == "new" then
			current.LoadStatus = "new"
		else
			-- "failed" / "corrupt": state sesi tetap default (17.4);
			-- save dilewati, aksi pengubah state ditolak.
			current.LoadStatus = status
			Remotes.Notify:FireClient(player, "Data simpanan gagal dimuat — progres sesi ini tidak akan disimpan. Coba relog nanti.")
		end
	end)
end

-- Urutan save-sebelum-cleanup (DESIGN.md 17.2): save DULU, catat hasil,
-- perbarui LoadedRevision bila sukses, lalu LoadToken = nil, BARU
-- bersihkan base + hapus entri Players. Urutan ini TIDAK BOLEH dibalik.
local function onPlayerRemoving(player)
	local state = Players[player]
	if state then
		local ok, msg, newRevision = DataStore.saveData(player, state, sessionId)
		if ok then
			state.LoadedRevision = newRevision
			print("[Main] save sukses untuk " .. player.Name .. " (revision " .. tostring(newRevision) .. ").")
		else
			warn("[Main] save gagal untuk " .. player.Name .. ": " .. tostring(msg))
			if string.sub(tostring(msg), 1, 8) == "conflict" then
				pcall(function()
					Remotes.Notify:FireClient(player, "Progres tidak tersimpan — data berubah di server lain. Relog untuk memuat data terbaru.")
				end)
			end
		end
		-- Batalkan load yang mungkin masih berjalan (DESIGN.md 17.7).
		state.LoadToken = nil
	end
	destroyCarriedModel(player)
	LockTeleportAt[player] = nil
	releaseBase(player)
	Players[player] = nil
end

local function onBindToClose()
	for player, state in pairs(Players) do
		if state.LoadStatus == "ok" or state.LoadStatus == "new" then
			local ok, msg, newRevision = DataStore.saveData(player, state, sessionId)
			if ok then
				state.LoadedRevision = newRevision
				print("[Main] BindToClose save sukses untuk " .. player.Name .. ".")
			else
				warn("[Main] BindToClose save gagal untuk " .. player.Name .. ": " .. tostring(msg))
			end
		else
			print("[Main] BindToClose lewati " .. player.Name .. " (LoadStatus = " .. tostring(state.LoadStatus) .. ").")
		end
	end
end

-- ---------------------------------------------------------------------------
-- Start
-- ---------------------------------------------------------------------------

createRemotes()
buildWorld()
connectLockBarriers()

PlayersService.PlayerAdded:Connect(onPlayerAdded)
PlayersService.PlayerRemoving:Connect(onPlayerRemoving)
game:BindToClose(onBindToClose)

-- Handler gameplay Stage 2: Place/Sell/Rebirth -> Economy.
-- Handler gameplay Stage 3: StealRequest -> Steal, LockRequest -> Main.
-- ClaimRequest / DebugFlood BELUM di-wire (Stage 4);
-- tidak ada handler yang memanggil modul yang belum ada.
Remotes.PlaceRequest.OnServerEvent:Connect(onPlaceRequest)
Remotes.SellRequest.OnServerEvent:Connect(onSellRequest)
Remotes.RebirthRequest.OnServerEvent:Connect(onRebirthRequest)
Remotes.StealRequest.OnServerEvent:Connect(onStealRequest)
Remotes.LockRequest.OnServerEvent:Connect(onLockRequest)

-- Pemain yang sudah ada sebelum script jalan (misal Play Solo di Studio).
for _, player in ipairs(PlayersService:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end

-- Loop utama 1 detik (SATU-SATUNYA loop; milik Main).
-- Stage 2: tambah incomeTick -> Economy.addIncome(Players, Remotes).
-- Stage 3: tambah lockExpiryTick (auto-unlock, DESIGN.md 19.1).
-- Flood + crate expiry (Stage 4) menyusul.
task.spawn(function()
	while true do
		task.wait(1)
		incomeTick()
		lockExpiryTick()
	end
end)
