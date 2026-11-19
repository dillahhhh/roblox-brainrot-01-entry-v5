-- Main.server.luau — Pasar Brainrot (roblox-brainrot-01, Stage 4)
-- SATU-SATUNYA Script server dan SATU-SATUNYA composition root.
-- Stage 4: require Config + Economy + DataStore + Steal + Flood,
-- bangun dunia 3D saat runtime, buat semua RemoteEvent, kelola
-- lifecycle pemain dengan load gating + LoadToken +
-- save-sebelum-cleanup, wire Place/Sell/Rebirth ke Economy,
-- StealRequest ke Steal, LockRequest + barrier + auto-unlock
-- ditangani Main sendiri, dan jalankan loop utama 1 detik
-- (income tick + lock expiry tick + flood tick + crate expiry
-- tick) plus loop conveyor 0,1 detik (spawn tiap SPAWN_INTERVAL
-- + gerak Brainrot sepanjang conveyor).
-- Stage 5: atribut prompt pedestal dipelihara server
-- (refreshPedestalPrompt: OwnerUserId saat base di-assign/dilepas,
-- SlotFilled saat slot terisi/dikosongkan, Enabled saat base ada
-- pemilik) agar client bisa melabel Taruh/Jual/Curi dari atribut.
-- Fix pasca-uji Studio bos (20 Nov): alur ambil Brainrot dari conveyor
-- (ProximityPrompt "Ambil" + TakeRequest + onTakeRequest), rumah base
-- di buildOneBase, fallback Studio di isLoadReady (DataStore:128 di
-- file lokal belum publish), pohon di depan pintu base di-skip di
-- buildTrees, plus polish visual map (jalur pejalan kaki, medali +
-- pot plaza, spanduk gapura, variasi warna kota/pohon/lampu, tali
-- lampion, kios pasar) — tanpa mengubah layout/konstanta gameplay.
-- Flood di-require Stage 4: Main pemilik TUNGGAL loop flood —
-- floodTick() memanggil Flood.tick SATU kali per detik dan hanya
-- menerapkan actions yang dikembalikan (tidak menghitung ulang
-- transisi); Main pemilik visual peti + dinding air + sirene.
-- Spesifikasi: DESIGN.md bagian 16, 17, 19, 20.3 +
-- MAIN-SERVER-PLAN.md.

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local Economy = require(script.Parent.Economy)
local DataStore = require(script.Parent.DataStore)
local Steal = require(script.Parent.Steal)
local Flood = require(script.Parent.Flood)

local PlayersService = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
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

-- Visual flood + peti milik Main (Stage 4, DESIGN.md 19.2/19.3):
-- Flood tidak pernah membuat/menghancurkan Instance; Main yang
-- membuat model conveyor + peti dan menggerakkan dinding air.
local ConveyorModels = {} -- [Uid] -> Model Brainrot di conveyor | nil
local CrateModels = {} -- [crateId] -> Model peti | nil
local WaterWall = nil -- Part dinding air kaca biru (bergerak utara -> selatan saat Flooding)
local FloodSiren = nil -- Sound sirene banjir (berbunyi saat Warning)
local DebrisParts = {} -- 14 part debris (baju/pintu/jendela) yang beterbangan saat flood
-- Durasi fase Flooding (DESIGN.md 7/19.2: ~6 detik); dipakai
-- hitung progres dinding air. Tidak ada konstanta Config untuk ini.
local FLOODING_SECONDS = 6

-- SATU-SATUNYA generator UID di server (DESIGN.md 16.1). Disuntikkan ke
-- modul yang butuh UID baru; modul tidak boleh membuat UID sendiri.
local function newUid()
	return HttpService:GenerateGUID(false)
end

-- Visual per base yang harus diubah runtime (bukan di Players):
-- kaca lock + papan nama pemilik.
local BaseVisuals = {} -- [baseIdx] -> { GlassParts, OwnerLabel, Headshot }
local BaseOwner = {} -- [baseIdx] -> Player | nil
local PedestalPrompts = {} -- [baseIdx][slotIdx] -> ProximityPrompt pedestal

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
	"TakeRequest",
	"SellCarriedRequest",
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
-- plaza + SpawnLocation -> bases -> gates -> forest -> boundary walls ->
-- trees -> lamps -> lanterns -> stalls.
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
	-- Senja jingga-pink SETERANG foto referensi (FIX ROUND 8):
	-- ClockTime 18.1 (matahari di ufuk) + Atmosphere senja dari
	-- Config. Round 7 gagal karena ClockTime 17.2 masih sore dan
	-- tanpa Atmosphere — langit default tetap biru. Atmosphere:
	-- Haze mewarnai langit di atas horizon, Color jingga dekat
	-- matahari, Decay pink menjauhi matahari, Glare halo matahari.
	-- Density rendah (0.3) supaya hutan tepi tetap siluet.
	-- Brightness 3 + Ambient/OutdoorAmbient hangat-terang
	-- dipertahankan — scene tetap terang, lampu jalan + lampion
	-- tetap nyala sebagai aksen.
	Lighting.ClockTime = Config.LIGHT_CLOCK_TIME
	Lighting.Brightness = Config.LIGHT_BRIGHTNESS
	Lighting.Ambient = Config.LIGHT_AMBIENT
	Lighting.OutdoorAmbient = Config.LIGHT_OUTDOOR_AMBIENT
	Lighting.EnvironmentDiffuseScale = 0.6
	-- Atmosphere sudah ada di default.project.json (tampilan Edit
	-- Studio); di sini diselaraskan dari Config, atau dibuat bila
	-- belum ada (misal place dibuka tanpa project).
	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	if atmosphere == nil then
		atmosphere = Instance.new("Atmosphere")
		atmosphere.Name = "SunsetAtmosphere"
		atmosphere.Parent = Lighting
	end
	atmosphere.Density = Config.LIGHT_ATMOSPHERE_DENSITY
	atmosphere.Offset = Config.LIGHT_ATMOSPHERE_OFFSET
	atmosphere.Color = Config.LIGHT_ATMOSPHERE_COLOR
	atmosphere.Decay = Config.LIGHT_ATMOSPHERE_DECAY
	atmosphere.Glare = Config.LIGHT_ATMOSPHERE_GLARE
	atmosphere.Haze = Config.LIGHT_ATMOSPHERE_HAZE
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
	-- Jalur pejalan kaki di tepi conveyor (x = ±16.5): strip tipis
	-- warna bata hangat di atas tanah, CanCollide false (murni dekor).
	for _, sideSign in ipairs({ -1, 1 }) do
		local strip = makePart(
			"Walkway",
			Vector3.new(2, 0.1, 320),
			Vector3.new(sideSign * 16.5, 0.05, 0),
			Enum.Material.Slate,
			Color3.fromRGB(178, 128, 84)
		)
		strip.CanCollide = false
	end
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

	-- Medali bundar emas di tengah plaza (disc tipis, CanCollide
	-- false — hanya dekor lantai, tidak menghalangi jalan spawn).
	local medallion = Instance.new("Part")
	medallion.Name = "PlazaMedallion"
	medallion.Shape = Enum.PartType.Cylinder
	medallion.Size = Vector3.new(0.15, 12, 12)
	medallion.CFrame = CFrame.new(0, 0.65, 150) * CFrame.Angles(0, 0, math.rad(90))
	medallion.Material = Enum.Material.SmoothPlastic
	medallion.Color = Color3.fromRGB(220, 180, 60)
	medallion.Anchored = true
	medallion.CanCollide = false
	medallion.Parent = Workspace

	-- 4 pot tanaman di sudut plaza (jauh dari titik spawn): kotak kayu
	-- + semak hijau bulat di atasnya.
	for _, cornerX in ipairs({ -50, 50 }) do
		for _, cornerZ in ipairs({ 132, 178 }) do
			local pot = makePart(
				"PlazaPlanter",
				Vector3.new(4, 1.5, 4),
				Vector3.new(cornerX, 1.35, cornerZ),
				Enum.Material.Wood,
				Color3.fromRGB(120, 75, 45)
			)
			local bush = Instance.new("Part")
			bush.Name = "PlazaBush"
			bush.Shape = Enum.PartType.Ball
			bush.Size = Vector3.new(4, 3.5, 4)
			bush.Position = Vector3.new(cornerX, 3.5, cornerZ)
			bush.Material = Enum.Material.SmoothPlastic
			bush.Color = Color3.fromRGB(50, 140, 70)
			bush.Anchored = true
			bush.CanCollide = false
			bush.Parent = Workspace
		end
	end
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

	-- Rumah base — RUMAH ADAT NUSANTARA (gaya pasar tradisional,
	-- tema game): rumah joglo/limasan yang TINGGI. Dinding kayu hangat
	-- 12 stud (y 0.8-12.8, dulu 8) dengan bukaan jendela, atap
	-- limasan 2 bidang miring + bubungan + overhang, teras depan
	-- (kanopi + tiang), kusen pintu depan, trim warna hangat.
	-- Depan TERBUKA menghadap pusat/conveyor. ANGKA ATAP (cek nyata):
	-- dinding atas y 12.8, lis atap (eave) y 12.6, bubungan y 18.2,
	-- balok bubungan atas y 18.7, hiasan ujung bubungan atas y 19.7 —
	-- semuanya di bawah papan nama pemilik di y 20.5 (jarak 1.8 stud
	-- dari bubungan). World.BaseCenter dan World.PedestalPos TIDAK
	-- berubah; dinding 1 stud ke dalam dari kaca lock (x ±27 / z ±22
	-- terhadap kaca ±28 / ±23); footprint tetap dalam lantai 56x46.
	-- Dinding samping di z ±22 berjarak 13 stud dari pedestal z ±9,
	-- jadi prompt pedestal (jarak 12) tidak terhalang; tiang/kusen
	-- depan di tepi lantai, bukan di jalur pedestal.
	local inward = (xCenter < 0) and 1 or -1 -- arah dari base ke pusat (x=0)
	local backX = xCenter - inward * 27 -- dinding belakang (sisi luar base)
	local frontX = xCenter + inward * 27 -- tepi depan yang terbuka
	local houseColor = Color3.fromRGB(165, 110, 70) -- kayu hangat
	local trimColor = Color3.fromRGB(190, 80, 55) -- trim merah hangat
	local darkWood = Color3.fromRGB(110, 70, 40)
	local roofColor = Color3.fromRGB(150, 60, 50) -- genteng merah
	-- Pembantu dinding berjendela: pita bawah (y 0.8-3.8) + pita atas
	-- (y 9.8-12.8, warna trim) penuh, tiang di antaranya (y 3.8-9.8)
	-- sehingga jendela terbuka di antara tiang. `axis` = "x" (dinding
	-- sepanjang sumbu X, di z tetap) atau "z" (sepanjang Z, di x tetap);
	-- `centers` = posisi tengah tiang sepanjang sumbu dinding,
	-- `widths` = lebar tiap tiang.
	local function buildWindowWall(axis, fixedCoord, centers, widths)
		local function wallPart(size, position, color, material)
			return makePart("BaseHouseWall" .. baseIdx, size, position,
				material or Enum.Material.Wood, color)
		end
		if axis == "z" then
			-- Dinding belakang: sepanjang z (46), tebal 1 (x).
			wallPart(Vector3.new(1, 3, 46), Vector3.new(backX, 2.3, zCenter), houseColor, Enum.Material.Brick)
			wallPart(Vector3.new(1, 3, 46), Vector3.new(backX, 11.3, zCenter), trimColor, Enum.Material.Wood)
			for i, c in ipairs(centers) do
				wallPart(Vector3.new(1, 6, widths[i]), Vector3.new(backX, 6.8, zCenter + c), houseColor)
			end
		else
			-- Dinding samping: sepanjang x (54), tebal 1 (z).
			wallPart(Vector3.new(54, 3, 1), Vector3.new(xCenter, 2.3, fixedCoord), houseColor)
			wallPart(Vector3.new(54, 3, 1), Vector3.new(xCenter, 11.3, fixedCoord), trimColor, Enum.Material.Wood)
			for i, c in ipairs(centers) do
				wallPart(Vector3.new(widths[i], 6, 1), Vector3.new(xCenter + c, 6.8, fixedCoord), houseColor)
			end
		end
	end
	-- Dinding belakang: 3 jendela (lebar 9) di antara 4 tiang.
	buildWindowWall("z", backX, { -21.25, -7.5, 7.5, 21.25 }, { 3.5, 6, 6, 3.5 })
	-- Dinding samping: 3 jendela (lebar 10) di antara 4 tiang.
	for _, sideSign in ipairs({ -1, 1 }) do
		buildWindowWall("x", zCenter + sideSign * 22, { -25, -9, 9, 25 }, { 4, 8, 8, 4 })
	end
	-- Tiang joglo depan (2 tiang di tepi depan, menopang lis atap)
	-- + balok depan melintang di atasnya (y 11.8-12.8).
	for _, sideSign in ipairs({ -1, 1 }) do
		makePart(
			"BaseHousePillar" .. baseIdx,
			Vector3.new(1.5, 12, 1.5),
			Vector3.new(frontX, 6.8, zCenter + sideSign * 18),
			Enum.Material.Wood,
			darkWood
		)
	end
	makePart(
		"BaseHouseBeam" .. baseIdx,
		Vector3.new(1.5, 1, 40),
		Vector3.new(frontX, 12.3, zCenter),
		Enum.Material.Wood,
		trimColor
	)
	-- Kusen pintu depan (tengah bukaan, menghadap conveyor): 2 tiang
	-- + ambang atas; celah jalan 7 stud, tidak menghalangi pedestal.
	for _, sideSign in ipairs({ -1, 1 }) do
		makePart(
			"BaseHouseDoorPost" .. baseIdx,
			Vector3.new(1, 8, 1),
			Vector3.new(frontX, 4.8, zCenter + sideSign * 3.5),
			Enum.Material.Wood,
			darkWood
		)
	end
	makePart(
		"BaseHouseDoorLintel" .. baseIdx,
		Vector3.new(1, 0.8, 8),
		Vector3.new(frontX, 9.2, zCenter),
		Enum.Material.Wood,
		trimColor
	)
	-- Teras depan: lantai teras rata dengan lantai base (atas y 0.8),
	-- menjorok 6 stud ke arah conveyor; 2 tiang teras + kanopi miring
	-- di atasnya. FIX ROUND 6 (20 Nov, perintah bos "hiasan depan base
	-- ilangin aja, yang warna warni"): keset merah di depan pintu
	-- DIHAPUS — itu satu-satunya hiasan warna-warni non-struktural di
	-- depan base. Teras, tiang teras, kanopi, tiang joglo, balok, dan
	-- kusen pintu (semua balok/kayu) DIBIARKAN, sesuai "kalo yang ada
	-- baloknya diemin".
	local terrace = makePart(
		"BaseTerrace" .. baseIdx,
		Vector3.new(6, 0.8, 30),
		Vector3.new(frontX + inward * 3, 0.4, zCenter),
		Enum.Material.WoodPlanks,
		Color3.fromRGB(140, 95, 55)
	)
	terrace.CanCollide = true
	for _, sideSign in ipairs({ -1, 1 }) do
		makePart(
			"BaseTerracePillar" .. baseIdx,
			Vector3.new(1.2, 10, 1.2),
			Vector3.new(frontX + inward * 5.4, 5.8, zCenter + sideSign * 12),
			Enum.Material.Wood,
			darkWood
		)
	end
	local canopy = Instance.new("Part")
	canopy.Name = "BaseTerraceCanopy" .. baseIdx
	canopy.Size = Vector3.new(7.5, 0.4, 28)
	canopy.CFrame = CFrame.new(frontX + inward * 3, 11.2, zCenter)
		* CFrame.Angles(0, 0, -inward * math.rad(12))
	canopy.Material = Enum.Material.Wood
	canopy.Color = roofColor
	canopy.Anchored = true
	canopy.CanCollide = false
	canopy.Parent = Workspace
	-- Atap limasan: bubungan sepanjang sumbu Z di xCenter, 2 bidang
	-- miring (depan menghadap conveyor + belakang). Lis y 12.6 di
	-- xCenter ± 29 (overhang 1 stud dari lantai), bubungan y 18.2:
	-- naik 5.6 run 29, kemiringan ~11 derajat, panjang bidang
	-- sqrt(29^2 + 5.6^2) = 29.6. Bidang +x miring -11 derajat (ujung
	-- luar turun), bidang -x +11 derajat.
	local roofRun = 29
	local roofRise = 5.6 -- 18.2 - 12.6
	local roofAngle = math.atan2(roofRise, roofRun)
	local roofSlopeLen = math.sqrt(roofRun * roofRun + roofRise * roofRise)
	local roofMidY = 12.6 + roofRise / 2 -- 15.4
	for _, sideSign in ipairs({ -1, 1 }) do
		local slope = Instance.new("Part")
		slope.Name = "BaseHouseRoof" .. baseIdx
		slope.Size = Vector3.new(roofSlopeLen, 0.6, 50)
		slope.CFrame = CFrame.new(xCenter + sideSign * (roofRun / 2), roofMidY, zCenter)
			* CFrame.Angles(0, 0, -sideSign * roofAngle)
		slope.Material = Enum.Material.Brick
		slope.Color = roofColor
		slope.Anchored = true
		slope.CanCollide = true
		slope.Parent = Workspace
	end
	-- Bubungan: balok memanjang di puncak (atas y 18.7) + hiasan
	-- ujung bubungan (bola emas, atas y 19.7, di z ±24.5 jauh dari
	-- papan nama di tengah) — tetap di bawah papan nama y 20.5.
	makePart(
		"BaseHouseRidge" .. baseIdx,
		Vector3.new(1.4, 1, 51),
		Vector3.new(xCenter, 18.2, zCenter),
		Enum.Material.Wood,
		darkWood
	)
	for _, endSign in ipairs({ -1, 1 }) do
		local finial = Instance.new("Part")
		finial.Name = "BaseHouseFinial" .. baseIdx
		finial.Shape = Enum.PartType.Ball
		finial.Size = Vector3.new(1.6, 1.6, 1.6)
		finial.Position = Vector3.new(xCenter, 18.9, zCenter + endSign * 24.5)
		finial.Material = Enum.Material.Metal
		finial.Color = Color3.fromRGB(220, 180, 60)
		finial.Anchored = true
		finial.CanCollide = false
		finial.Parent = Workspace
	end
	-- Lampu dinding dalam (bola Neon hangat + PointLight) di dinding
	-- belakang bagian dalam, di atas jendela tengah (y 9.5).
	local wallLamp = Instance.new("Part")
	wallLamp.Name = "BaseWallLamp" .. baseIdx
	wallLamp.Shape = Enum.PartType.Ball
	wallLamp.Size = Vector3.new(1, 1, 1)
	wallLamp.Position = Vector3.new(backX + inward * 2, 9.5, zCenter)
	wallLamp.Material = Enum.Material.Neon
	wallLamp.Color = Color3.fromRGB(255, 200, 110)
	wallLamp.Anchored = true
	wallLamp.CanCollide = false
	wallLamp.Parent = Workspace
	local wallGlow = Instance.new("PointLight")
	wallGlow.Color = Color3.fromRGB(255, 190, 110)
	wallGlow.Range = 15
	wallGlow.Brightness = 1
	wallGlow.Parent = wallLamp

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
			prompt.Enabled = false -- belum ada pemilik; diaktifkan refreshPedestalPrompt saat base terisi (Stage 5)
			prompt:SetAttribute("PromptKind", "Pedestal")
			prompt:SetAttribute("OwnerUserId", 0)
			prompt:SetAttribute("SlotFilled", false)
			prompt:SetAttribute("BaseIdx", baseIdx)
			prompt:SetAttribute("SlotIdx", slotIdx)
			prompt.Parent = pedestal
			PedestalPrompts[baseIdx] = PedestalPrompts[baseIdx] or {}
			PedestalPrompts[baseIdx][slotIdx] = prompt
		end
	end

	-- Papan nama pemilik (BillboardGui, y = 20.5) — di atas atap
	-- (bubungan y 18.2, balok bubungan atas y 18.7).
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
	board.Size = UDim2.fromOffset(Config.OWNER_BOARD_WIDTH, Config.OWNER_BOARD_HEIGHT)
	board.StudsOffsetWorldSpace = Vector3.new(0, 0, 0)
	board.AlwaysOnTop = false
	board.LightInfluence = 0
	board.Parent = boardAnchor

	-- Layout papan (FIX ROUND 3): headshot 64x64 di kiri, nama pemilik
	-- di kanan — bukan teks memenuhi seluruh papan. Nama pakai TextSize
	-- tetap (TextScaled dimatikan) supaya terbaca dari conveyor tanpa
	-- membesar memenuhi papan.
	local ownerLabel = Instance.new("TextLabel")
	ownerLabel.Name = "OwnerName"
	ownerLabel.Position = UDim2.new(0, Config.OWNER_HEADSHOT_SIZE + 16, 0, 0)
	ownerLabel.Size = UDim2.new(1, -(Config.OWNER_HEADSHOT_SIZE + 24), 1, 0)
	ownerLabel.BackgroundTransparency = 1
	ownerLabel.Text = "BASE " .. baseIdx
	ownerLabel.TextColor3 = Color3.fromRGB(255, 240, 200)
	ownerLabel.TextScaled = false
	ownerLabel.TextSize = Config.OWNER_NAME_TEXT_SIZE
	ownerLabel.TextWrapped = true
	ownerLabel.TextXAlignment = Enum.TextXAlignment.Left
	ownerLabel.TextYAlignment = Enum.TextYAlignment.Center
	ownerLabel.Font = Enum.Font.GothamBold
	ownerLabel.Parent = board

	-- Foto kepala pemilik (diisi saat base terisi; Stage 1: placeholder kosong).
	-- FIX ROUND 3: 64x64 dan TERINTEGRASI di dalam papan (kiri, sejajar
	-- nama) — dulu 48x48 di luar papan (56px di kiri tepi) sehingga
	-- mudah terlewat/tertutup di Studio.
	local headshot = Instance.new("ImageLabel")
	headshot.Name = "Headshot"
	headshot.Size = UDim2.fromOffset(Config.OWNER_HEADSHOT_SIZE, Config.OWNER_HEADSHOT_SIZE)
	headshot.Position = UDim2.new(0, 8, 0.5, -Config.OWNER_HEADSHOT_SIZE / 2)
	headshot.BackgroundTransparency = 1
	headshot.Image = ""
	headshot.Parent = board

	-- Kaca lock: dinding sekeliling base, tersembunyi sampai terkunci
	-- (Stage 3: setLockVisual menampilkan Transparency 0.5 + CanCollide).
	local glassParts = {}
	local glassColor = Color3.fromRGB(170, 220, 255)
	-- isDoor = true untuk kaca sisi PINTU (menghadap conveyor): kaca
	-- ini tetap TIDAK solid walau terkunci (FIX ROUND 3, item 6) —
	-- pintu hanya pemicu Touched (teleport bukan pemilik), pemilik
	-- lewat bebas. 3 dinding kaca lainnya tetap solid saat terkunci.
	local function addGlass(name, size, position, isDoor)
		local glass = Instance.new("Part")
		glass.Name = name
		glass.Size = size
		glass.Position = position
		glass.Material = Enum.Material.Glass
		glass.Color = glassColor
		glass.Transparency = 1
		glass.Anchored = true
		glass.CanCollide = false
		if isDoor then
			glass:SetAttribute("IsDoor", true)
		end
		glass.Parent = Workspace
		table.insert(glassParts, glass)
	end
	-- Dinding utara/selatan (sepanjang x) dan timur/barat (sepanjang z).
	addGlass("LockGlassN" .. baseIdx, Vector3.new(56, 6, 0.5), Vector3.new(xCenter, 3.8, zCenter - 23))
	addGlass("LockGlassS" .. baseIdx, Vector3.new(56, 6, 0.5), Vector3.new(xCenter, 3.8, zCenter + 23))
	-- Pintu menghadap conveyor: base kiri (xCenter -68) -> sisi timur,
	-- base kanan (xCenter +68) -> sisi barat.
	addGlass("LockGlassW" .. baseIdx, Vector3.new(0.5, 6, 46), Vector3.new(xCenter - 28, 3.8, zCenter), xCenter > 0)
	addGlass("LockGlassE" .. baseIdx, Vector3.new(0.5, 6, 46), Vector3.new(xCenter + 28, 3.8, zCenter), xCenter < 0)

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
		-- Spanduk merah di bawah balok gapura + lampu hangatnya.
		local banner = makePart(
			"GateBanner",
			Vector3.new(20, 2.5, 0.3),
			Vector3.new(0, 11, gateZ),
			Enum.Material.SmoothPlastic,
			Color3.fromRGB(200, 60, 60)
		)
		banner.CanCollide = false
		local gateLight = Instance.new("PointLight")
		gateLight.Color = Color3.fromRGB(255, 190, 110)
		gateLight.Range = 20
		gateLight.Brightness = 1
		gateLight.Parent = banner
	end
	-- Pagar sisi timur/barat dan ujung utara/selatan.
	makePart("FenceW", Vector3.new(0.5, 3, 400), Vector3.new(-168, 1.5, 0), Enum.Material.Wood, Color3.fromRGB(110, 80, 50))
	makePart("FenceE", Vector3.new(0.5, 3, 400), Vector3.new(168, 1.5, 0), Enum.Material.Wood, Color3.fromRGB(110, 80, 50))
	makePart("FenceN", Vector3.new(336, 3, 0.5), Vector3.new(0, 1.5, -208), Enum.Material.Wood, Color3.fromRGB(110, 80, 50))
	makePart("FenceS", Vector3.new(336, 3, 0.5), Vector3.new(0, 1.5, 208), Enum.Material.Wood, Color3.fromRGB(110, 80, 50))
end

local function buildForest()
	-- Tepi hutan lebat sebagai latar (FIX ROUND 5, 20 Nov — menggantikan
	-- bangunan kota di kejauhan; perintah bos 02:33 WIB): pohon tinggi
	-- berlapis di keempat tepi map (sekitar x = ±162, z = ±202, seperti
	-- posisi kota lama), di LUAR area main — tidak menghalangi conveyor /
	-- base / plaza / jalan pemain. Lapisan depan lebih gelap, lapisan
	-- belakang lebih terang kena cahaya (seperti foto referensi); semak
	-- + rumpun rumput di kaki tiap pohon. Semua posisi + tinggi
	-- deterministik (aritmetika, tanpa math.random).
	local frontLeafColors = {
		Color3.fromRGB(28, 85, 42),
		Color3.fromRGB(35, 100, 48),
		Color3.fromRGB(24, 72, 38),
	}
	local backLeafColors = {
		Color3.fromRGB(95, 160, 70),
		Color3.fromRGB(120, 180, 90),
		Color3.fromRGB(70, 140, 60),
	}
	local trunkColor = Color3.fromRGB(90, 60, 35)
	local bushColor = Color3.fromRGB(45, 110, 55)
	local grassColor = Color3.fromRGB(190, 170, 90)

	local function makeForestTree(x, z, index, isBack)
		local height = 20 + ((index * 37) % 21) -- tinggi 20-40 stud
		local leafColors = isBack and backLeafColors or frontLeafColors
		local leafColor = leafColors[((index - 1) % #leafColors) + 1]
		local trunk = makePart("ForestTrunk",
			Vector3.new(1.4, height, 1.4),
			Vector3.new(x, height / 2, z),
			Enum.Material.Wood, trunkColor)
		trunk.CanCollide = false
		-- 3 bola daun bertumpuk (bawah besar, atas kecil): tajuk berlapis.
		local ballSizes = { 0.5, 0.4, 0.3 }
		local ballHeights = { 0.55, 0.78, 0.95 }
		for b = 1, 3 do
			local ball = Instance.new("Part")
			ball.Name = "ForestLeaves"
			ball.Shape = Enum.PartType.Ball
			local ballSize = height * ballSizes[b]
			ball.Size = Vector3.new(ballSize, ballSize, ballSize)
			ball.Position = Vector3.new(x, height * ballHeights[b], z)
			ball.Material = Enum.Material.SmoothPlastic
			ball.Color = leafColor
			ball.Anchored = true
			ball.CanCollide = false
			ball.Parent = Workspace
		end
		-- Semak di kaki pohon + rumpun rumput kering di sebelahnya.
		local bushSize = 2 + ((index * 11) % 2)
		local bush = Instance.new("Part")
		bush.Name = "ForestBush"
		bush.Shape = Enum.PartType.Ball
		bush.Size = Vector3.new(bushSize, bushSize * 0.8, bushSize)
		bush.Position = Vector3.new(x + 2.5, bushSize * 0.4, z + 1.5)
		bush.Material = Enum.Material.SmoothPlastic
		bush.Color = bushColor
		bush.Anchored = true
		bush.CanCollide = false
		bush.Parent = Workspace
		local grass = makePart("ForestGrass",
			Vector3.new(1.2, 1.6, 0.4),
			Vector3.new(x - 2.5, 0.8, z - 1.5),
			Enum.Material.Grass, grassColor)
		grass.CanCollide = false
	end

	local treeIndex = 0
	-- Sisi barat/timur: 2 lapis (depan x = ±158 gelap, belakang x = ±168
	-- terang), z berjajar selang-seling agar tajuk saling menutupi.
	for _, side in ipairs({ -1, 1 }) do
		for i = 1, 8 do
			treeIndex = treeIndex + 1
			makeForestTree(side * 158, -168 + (i - 1) * 48, treeIndex, false)
		end
		for i = 1, 7 do
			treeIndex = treeIndex + 1
			makeForestTree(side * 168, -144 + (i - 1) * 48, treeIndex, true)
		end
	end
	-- Sisi utara/selatan: 2 lapis (depan z = ±196 gelap, belakang
	-- z = ±206 terang).
	for _, side in ipairs({ -1, 1 }) do
		for i = 1, 6 do
			treeIndex = treeIndex + 1
			makeForestTree(-125 + (i - 1) * 50, side * 196, treeIndex, false)
		end
		for i = 1, 5 do
			treeIndex = treeIndex + 1
			makeForestTree(-100 + (i - 1) * 50, side * 206, treeIndex, true)
		end
	end
end

local function buildTrees()
	-- Pohon di tepi conveyor (x = ±20, 24 posisi per sisi), TAPI pohon
	-- yang z-nya masuk rentang BASE_Z[row] ± TREE_CLEAR_HALF_Z (40)
	-- TIDAK DIBUAT: pohon itu berdiri di depan pintu masuk base (sisi
	-- yang menghadap conveyor/pusat) dan menghalangi pandangan.
	-- Jendela ±40 menutupi [-145, 130] seluruhnya, sehingga tersisa
	-- hanya z = -150, 136, 149 per sisi (3 per sisi, 6 total).
	-- Pohon dilewati di loop (bukan disembunyikan / dipindah).
	local trunkColor = Color3.fromRGB(110, 70, 40)
	local leafColors = {
		Color3.fromRGB(40, 120, 60),
		Color3.fromRGB(55, 140, 65),
		Color3.fromRGB(30, 100, 55),
	}
	for side = 1, 2 do
		local treeX = (side == 1) and -20 or 20
		for i = 1, 24 do
			local treeZ = -150 + (i - 1) * 13
			local inFrontOfBase = false
			for _, baseZ in ipairs(Config.BASE_Z) do
				if treeZ >= baseZ - Config.TREE_CLEAR_HALF_Z and treeZ <= baseZ + Config.TREE_CLEAR_HALF_Z then
					inFrontOfBase = true
					break
				end
			end
			-- (Tanpa `continue`: file ini harus lolos `luac -p` Lua 5.1,
			-- jadi pembuatan pohon dibungkus `if not inFrontOfBase`.)
			if not inFrontOfBase then
				-- Variasi warna daun deterministik (3 hijau, by index).
				local thisLeafColor = leafColors[((i + side) % #leafColors) + 1]
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
				leaves.Color = thisLeafColor
				leaves.Anchored = true
				leaves.CanCollide = false
			leaves.Parent = Workspace
			end
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
			-- Variasi bola lampu: kuning hangat / oranye hangat bergantian.
			if i % 2 == 0 then
				bulb.Color = Color3.fromRGB(255, 170, 70)
			else
				bulb.Color = Color3.fromRGB(255, 200, 100)
			end
			bulb.Anchored = true
			bulb.CanCollide = false
			bulb.Parent = Workspace
			local light = Instance.new("PointLight")
			light.Color = Color3.fromRGB(255, 190, 110)
			light.Range = Config.LAMP_RANGE
			light.Brightness = Config.LAMP_BRIGHTNESS
			light.Parent = bulb
		end
	end
end

local function buildLanterns()
	-- Lampion pasar malam: tali lampion antar tiang lampu di kedua sisi
	-- conveyor (tiang di z = -140 + (i-1)*46). 5 lampion per bentang,
	-- sedikit melengkung ke bawah di tengah; warna merah/emas/hijau
	-- bergantian (Neon, CanCollide false). PointLight hangat hanya di
	-- lampion tengah tiap bentang ganjil (6 lampu) supaya map tetap
	-- terang tanpa membanjiri renderer dengan cahaya.
	local lanternColors = {
		Color3.fromRGB(255, 70, 70),
		Color3.fromRGB(255, 200, 60),
		Color3.fromRGB(90, 220, 120),
	}
	for side = 1, 2 do
		local lampX = (side == 1) and -18 or 18
		for gap = 1, 6 do
			local zA = -140 + (gap - 1) * 46
			local zB = zA + 46
			for k = 1, 5 do
				local t = k / 6
				local lanternZ = zA + (zB - zA) * t
				local lanternY = 7.2 - 0.8 * math.sin(math.pi * t)
				local lantern = Instance.new("Part")
				lantern.Name = "Lantern"
				lantern.Shape = Enum.PartType.Ball
				lantern.Size = Vector3.new(0.9, 0.9, 0.9)
				lantern.Position = Vector3.new(lampX, lanternY, lanternZ)
				lantern.Material = Enum.Material.Neon
				lantern.Color = lanternColors[((k + gap + side) % #lanternColors) + 1]
				lantern.Anchored = true
				lantern.CanCollide = false
				lantern.Parent = Workspace
				if k == 3 and gap % 2 == 1 then
					local glow = Instance.new("PointLight")
					glow.Color = Color3.fromRGB(255, 190, 110)
					glow.Range = 12
					glow.Brightness = 1
					glow.Parent = lantern
				end
			end
		end
	end
	-- Kabel lampion (FIX ROUND 7, foto image-37.png): lampion di
	-- atas digantung di KABEL, bukan melayang. (a) Kabel tipis di
	-- atas tiap rentang lampion sisi jalan (y =
	-- Config.LANTERN_CABLE_Y, sedikit di atas lampion tertinggi
	-- 7.25). (b) Kabel MELINTANG di atas conveyor antar tiang lampu
	-- (x = -18..18) di tengah tiap gap, y = Config.CROSS_CABLE_Y
	-- (9.5 — di atas Brainrot conveyor tertinggi ~7.45 + di luar
	-- jalur label), dengan tiang tinggi sendiri + 3 lampion gantung
	-- kecil bertali pendek. Deterministik (aritmetika, tanpa
	-- math.random). Lampu jalan + 60 lampion yang sudah ada tetap.
	local cableColor = Color3.fromRGB(40, 30, 25)
	for side = 1, 2 do
		local lampX = (side == 1) and -18 or 18
		for gap = 1, 6 do
			local zA = -140 + (gap - 1) * 46
			local cable = Instance.new("Part")
			cable.Name = "LanternCable"
			cable.Size = Vector3.new(0.15, 0.15, 46)
			cable.Position = Vector3.new(lampX, Config.LANTERN_CABLE_Y, zA + 23)
			cable.Material = Enum.Material.SmoothPlastic
			cable.Color = cableColor
			cable.Anchored = true
			cable.CanCollide = false
			cable.Parent = Workspace
		end
	end
	for gap = 1, 6 do
		local cableZ = -117 + (gap - 1) * 46 -- tengah tiap gap tiang lampu
		for _, side in ipairs({ -1, 1 }) do
			local post = makePart(
				"CrossCablePost",
				Vector3.new(0.5, Config.CROSS_CABLE_Y, 0.5),
				Vector3.new(side * 18, Config.CROSS_CABLE_Y / 2, cableZ),
				Enum.Material.Metal,
				Color3.fromRGB(40, 40, 45)
			)
			post.CanCollide = false
		end
		local cross = Instance.new("Part")
		cross.Name = "CrossCable"
		cross.Size = Vector3.new(36, 0.15, 0.15)
		cross.Position = Vector3.new(0, Config.CROSS_CABLE_Y, cableZ)
		cross.Material = Enum.Material.SmoothPlastic
		cross.Color = cableColor
		cross.Anchored = true
		cross.CanCollide = false
		cross.Parent = Workspace
		for k = 1, 3 do
			local hangX = -12 + (k - 1) * 12
			local cord = Instance.new("Part")
			cord.Name = "HangingLanternCord"
			cord.Size = Vector3.new(0.08, 0.7, 0.08)
			cord.Position = Vector3.new(hangX, Config.CROSS_CABLE_Y - 0.35, cableZ)
			cord.Material = Enum.Material.SmoothPlastic
			cord.Color = cableColor
			cord.Anchored = true
			cord.CanCollide = false
			cord.Parent = Workspace
			local hanging = Instance.new("Part")
			hanging.Name = "HangingLantern"
			hanging.Shape = Enum.PartType.Ball
			hanging.Size = Vector3.new(0.7, 0.7, 0.7)
			hanging.Position = Vector3.new(hangX, Config.CROSS_CABLE_Y - 0.9, cableZ)
			hanging.Material = Enum.Material.Neon
			hanging.Color = lanternColors[((k + gap) % #lanternColors) + 1]
			hanging.Anchored = true
			hanging.CanCollide = false
			hanging.Parent = Workspace
		end
	end
end

-- Kios pasar di ujung utara/selatan map (x = ±35, z = ±188): jauh dari
-- jalur spawn -> conveyor dan dari pintu base. Tiap kios: meja kayu,
-- 4 tiang, atap garis merah/krem. Murni dekor (tidak menghalangi
-- gameplay, tidak menyentuh base/conveyor/plaza).
local function buildStalls()
	local canopyColors = {
		Color3.fromRGB(200, 60, 60),
		Color3.fromRGB(240, 220, 180),
	}
	for _, stallX in ipairs({ -35, 35 }) do
		for _, stallZ in ipairs({ -188, 188 }) do
			makePart(
				"StallCounter",
				Vector3.new(6, 2, 3),
				Vector3.new(stallX, 1, stallZ),
				Enum.Material.Wood,
				Color3.fromRGB(140, 95, 55)
			)
			for _, postX in ipairs({ -2.8, 2.8 }) do
				for _, postZ in ipairs({ -1.3, 1.3 }) do
					makePart(
						"StallPost",
						Vector3.new(0.4, 3, 0.4),
						Vector3.new(stallX + postX, 3.5, stallZ + postZ),
						Enum.Material.Wood,
						Color3.fromRGB(110, 70, 40)
					)
				end
			end
			for stripe = 1, 3 do
				local stripePart = makePart(
					"StallCanopy",
					Vector3.new(6.6, 0.3, 1.2),
					Vector3.new(stallX, 5.2, stallZ - 1.2 + (stripe - 1) * 1.2),
					Enum.Material.SmoothPlastic,
					canopyColors[((stripe - 1) % #canopyColors) + 1]
				)
				stripePart.CanCollide = false
			end
		end
	end
end

-- Gerobak jualan depan base (FIX ROUND 7, 20 Nov, foto image-37.png):
-- satu gerobak BESAR di depan tiap base (8 base = 8 gerobak), di
-- samping jalan masuk, DI LUAR jalur conveyor (x = ±7.5) dan jalur
-- gerak Brainrot, TIDAK menutup pintu base dan TIDAK bersinggungan
-- dengan jalur conveyor maupun lintasan Brainrot. Verifikasi posisi
-- (contoh base kiri xCenter = -68, inward = +1, frontX = -41):
-- gerobak di x = -36 (lebar x 4.5 -> -38.25..-33.75), z = zCenter
-- ± 20 (dalam 3.5 -> 18.25..21.75 dari tengah base). Bandingkan:
-- jalur conveyor x = ±7.5 (jauh 26 stud); lintasan Brainrot x =
-- ±7.5 ± 2.1 (lebar model); pintu base di zCenter (gerobak 20 stud
-- ke samping, jalan masuk zCenter ± 3.5 bebas); teras base z ± 15
-- (gerobak mulai 18.25); kaca lock depan x = -40 (gerobak mulai
-- -38.25, di LUAR kotak kaca); pohon x = ±20, lampu x = ±18
-- (gerobak di x -38..-34, tidak bersentuhan); peti Pasar spawn di
-- pintu (x -38, z zCenter ± 4 — gerobak di z ± 18..22, tidak
-- menutupi peti). Sisi z berselang-seling (ganjil +20, genap -20).
-- Tiap gerobak: NPC PENJUAL (karakter Roblox sederhana, dekorasi)
-- + TULISAN jualan bergiliran 1-2-3-1-2-3-1-2 untuk base 1..8.
-- Gerobak + penjual + tulisan = dekorasi SAJA (tidak ada interaksi
-- jual-beli, tidak ada remote baru, tidak ada ekonomi baru).
-- DALAM base JANGAN ada jualan (base tetap hanya pajang Brainrot
-- 6 pedestal + rumah). Posisi + tulisan lewat konstanta Config.
local function buildVendorCarts()
	local signTexts = Config.CART_SIGN_TEXTS
	local goodsColors = {
		Color3.fromRGB(240, 230, 210), -- CILOK: putih kekuningan
		Color3.fromRGB(180, 120, 60), -- BATAGOR: cokelat keemasan
		Color3.fromRGB(245, 240, 225), -- BASO: putih pucat
	}
	local shirtColors = {
		Color3.fromRGB(60, 120, 200),
		Color3.fromRGB(200, 120, 60),
		Color3.fromRGB(80, 160, 80),
		Color3.fromRGB(180, 80, 140),
	}
	for baseIdx = 1, Config.BASE_COUNT do
		local side = (baseIdx <= 4) and 1 or 2
		local row = ((baseIdx - 1) % 4) + 1
		local xCenter = Config.BASE_X[side]
		local zCenter = Config.BASE_Z[row]
		local inward = (xCenter < 0) and 1 or -1 -- arah base -> conveyor
		local frontX = xCenter + inward * 27 -- tepi depan base
		local cartX = frontX + inward * Config.CART_X_FROM_FRONT
		local zSide = (baseIdx % 2 == 1) and 1 or -1
		local cartZ = zCenter + zSide * Config.CART_Z_OFFSET
		local signIndex = ((baseIdx - 1) % #signTexts) + 1
		local signText = signTexts[signIndex]
		local goodsColor = goodsColors[signIndex]

		-- Meja gerobak + alas atas (counter 4.5 x 2.2 x 3.5, alas 5 x 4).
		local counter = makePart(
			"VendorCartCounter" .. baseIdx,
			Vector3.new(4.5, 2.2, 3.5),
			Vector3.new(cartX, 1.1, cartZ),
			Enum.Material.Wood,
			Color3.fromRGB(140, 95, 55)
		)
		counter.CanCollide = true
		local counterTop = makePart(
			"VendorCartTop" .. baseIdx,
			Vector3.new(5, 0.3, 4),
			Vector3.new(cartX, 2.35, cartZ),
			Enum.Material.Wood,
			Color3.fromRGB(170, 120, 70)
		)
		counterTop.CanCollide = false
		-- Dagangan di atas meja: 4 bulatan sesuai tulisan jualan.
		for _, dz in ipairs({ -1.2, -0.4, 0.4, 1.2 }) do
			local goods = Instance.new("Part")
			goods.Name = "VendorCartGoods" .. baseIdx
			goods.Shape = Enum.PartType.Ball
			goods.Size = Vector3.new(0.6, 0.6, 0.6)
			goods.Position = Vector3.new(cartX, 2.8, cartZ + dz)
			goods.Material = Enum.Material.SmoothPlastic
			goods.Color = goodsColor
			goods.Anchored = true
			goods.CanCollide = false
			goods.Parent = Workspace
		end
		-- 4 tiang + kanopi 2 garis (merah/krem, seperti kios pasar).
		for _, postX in ipairs({ -2.2, 2.2 }) do
			for _, postZ in ipairs({ -1.6, 1.6 }) do
				local post = makePart(
					"VendorCartPost" .. baseIdx,
					Vector3.new(0.35, 2.6, 0.35),
					Vector3.new(cartX + postX, 3.8, cartZ + postZ),
					Enum.Material.Wood,
					Color3.fromRGB(110, 70, 40)
				)
				post.CanCollide = false
			end
		end
		local canopyColors = {
			Color3.fromRGB(200, 60, 60),
			Color3.fromRGB(240, 220, 180),
		}
		for stripe = 1, 2 do
			local stripePart = makePart(
				"VendorCartCanopy" .. baseIdx,
				Vector3.new(5.5, 0.25, 2.4),
				Vector3.new(cartX, 5.2, cartZ - 1.2 + (stripe - 1) * 2.4),
				Enum.Material.SmoothPlastic,
				canopyColors[stripe]
			)
			stripePart.CanCollide = false
		end
		-- 2 roda di sisi gerobak (sumbu sepanjang Z).
		for _, wheelZ in ipairs({ -1.9, 1.9 }) do
			local wheel = Instance.new("Part")
			wheel.Name = "VendorCartWheel" .. baseIdx
			wheel.Shape = Enum.PartType.Cylinder
			wheel.Size = Vector3.new(0.4, 1.4, 1.4)
			wheel.CFrame = CFrame.new(cartX, 0.7, cartZ + wheelZ)
				* CFrame.Angles(0, math.rad(90), 0)
			wheel.Material = Enum.Material.Wood
			wheel.Color = Color3.fromRGB(60, 40, 25)
			wheel.Anchored = true
			wheel.CanCollide = false
			wheel.Parent = Workspace
		end
		-- NPC PENJUAL: karakter Roblox sederhana di sisi jalan
		-- gerobak (antara gerobak dan conveyor), menghadap jalan.
		-- Dekorasi: semua part CanCollide false, tidak menghalangi.
		local vendorX = cartX + inward * 2.8
		local vendorZ = cartZ
		local shirtColor = shirtColors[((baseIdx - 1) % #shirtColors) + 1]
		local skinColor = Color3.fromRGB(240, 200, 160)
		local function vendorPart(name, size, position, color, shape, cframe)
			local part = Instance.new("Part")
			part.Name = name
			part.Size = size
			if shape ~= nil then
				part.Shape = shape
			end
			if cframe ~= nil then
				part.CFrame = cframe
			else
				part.Position = position
			end
			part.Material = Enum.Material.SmoothPlastic
			part.Color = color
			part.Anchored = true
			part.CanCollide = false
			part.Parent = Workspace
			return part
		end
		vendorPart("VendorLegL" .. baseIdx, Vector3.new(0.5, 1.0, 0.5),
			Vector3.new(vendorX, 0.5, vendorZ - 0.35), Color3.fromRGB(50, 50, 70))
		vendorPart("VendorLegR" .. baseIdx, Vector3.new(0.5, 1.0, 0.5),
			Vector3.new(vendorX, 0.5, vendorZ + 0.35), Color3.fromRGB(50, 50, 70))
		vendorPart("VendorTorso" .. baseIdx, Vector3.new(1.6, 1.8, 0.9),
			Vector3.new(vendorX, 1.9, vendorZ), shirtColor)
		vendorPart("VendorArmL" .. baseIdx, Vector3.new(0.4, 1.4, 0.4),
			Vector3.new(vendorX, 1.9, vendorZ - 0.65), skinColor)
		vendorPart("VendorArmR" .. baseIdx, Vector3.new(0.4, 1.4, 0.4),
			Vector3.new(vendorX, 1.9, vendorZ + 0.65), skinColor)
		vendorPart("VendorHead" .. baseIdx, Vector3.new(1.1, 1.1, 1.1),
			Vector3.new(vendorX, 3.35, vendorZ), skinColor, Enum.PartType.Ball)
		vendorPart("VendorCap" .. baseIdx, Vector3.new(1.3, 0.3, 1.3),
			nil, Color3.fromRGB(180, 50, 50), Enum.PartType.Cylinder,
			CFrame.new(vendorX, 3.95, vendorZ) * CFrame.Angles(0, 0, math.rad(90)))
		-- Celemek putih menghadap jalan (sisi conveyor).
		vendorPart("VendorApron" .. baseIdx, Vector3.new(0.15, 1.4, 1.2),
			Vector3.new(vendorX + inward * 0.55, 1.9, vendorZ),
			Color3.fromRGB(245, 245, 240))
		-- TULISAN jualan MENEMPEL di badan gerobak (FIX ROUND 8):
		-- papan fisik tipis di muka counter menghadap jalan
		-- (sisi conveyor, tempat NPC penjual berdiri), BUKAN
		-- BillboardGui melayang di atas kanopi. Papan menempel
		-- fisik: muka counter di cartX + inward * 2.25 (setengah
		-- lebar counter 4.5), papan 0.15 tebal -> pusat papan di
		-- +2.325 dari cartX, tanpa celah mengambang. Papan merah
		-- (warna latar tulisan lama) + SurfaceGui teks putih.
		local signBoard = makePart(
			"VendorCartSign" .. baseIdx,
			Vector3.new(
				Config.CART_SIGN_BOARD_THICKNESS,
				Config.CART_SIGN_BOARD_HEIGHT,
				Config.CART_SIGN_BOARD_WIDTH
			),
			Vector3.new(
				cartX + inward * (2.25 + Config.CART_SIGN_BOARD_THICKNESS / 2),
				Config.CART_SIGN_BOARD_Y,
				cartZ
			),
			Enum.Material.Wood,
			Color3.fromRGB(150, 30, 30)
		)
		signBoard.CanCollide = false
		local signGui = Instance.new("SurfaceGui")
		signGui.Name = "VendorCartSignGui"
		signGui.Face = (inward == 1) and Enum.NormalId.Right or Enum.NormalId.Left
		signGui.PixelsPerStud = Config.CART_SIGN_PIXELS_PER_STUD
		signGui.LightInfluence = 0
		signGui.Parent = signBoard
		local signTextLabel = Instance.new("TextLabel")
		signTextLabel.Name = "SignText"
		signTextLabel.Size = UDim2.new(1, 0, 1, 0)
		signTextLabel.BackgroundTransparency = 1
		signTextLabel.Text = signText
		signTextLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		signTextLabel.TextScaled = false
		signTextLabel.TextSize = Config.CART_SIGN_TEXT_SIZE
		signTextLabel.Font = Enum.Font.GothamBold
		signTextLabel.Parent = signGui
	end
end

-- FIX ROUND 9 (20 Nov) — FORWARD DECLARATION, jangan dihapus:
-- `buildExhibitionTable` (di bawah) memanggil `createBrainrotModel`,
-- tapi definisi fungsinya baru ada di bawah, SETELAH
-- buildExhibitionTable. Aturan lexical scoping
-- Lua: di dalam buildExhibitionTable, nama itu merujuk ke GLOBAL
-- (nil), bukan ke local yang dideklarasikan belakangan — pemanggilan
-- di buildExhibitionTable melempar "attempt to call a nil value" dan
-- mematikan buildWorld + seluruh script Main saat startup (conveyor
-- tidak pernah spawn, pameran kosong). Deklarasi di sini membuat
-- `createBrainrotModel` terlihat sebagai local SEBELUM
-- buildExhibitionTable didefinisikan; penugasan fungsinya di bawah
-- (tanpa `local` kedua) mengisi local yang sama. Isi fungsi TIDAK
-- berubah — hanya urutan deklarasi.
local createBrainrotModel

-- Meja pameran di sebelah spawn (FIX ROUND 8, 20 Nov): satu meja
-- panjang di TIMUR spawn (pusat x = 32, z = 168 — sejajar spawn,
-- 11 stud di timur tepi SpawnLocation x = 8), memajang KE-7 jenis
-- Brainrot (Config.RosterOrder) dalam 2 baris (depan 4, belakang
-- 3) di atas alas meja. Model dari createBrainrotModel yang sama
-- — bentuk + aura rarity + label nama identik dengan yang di
-- conveyor/pedestal. DEKORASI SAJA: model statis (Anchored, dari
-- createBrainrotModel), TANPA ProximityPrompt, TANPA RemoteEvent,
-- TIDAK masuk ekonomi/conveyor/pedestal/peti, tidak bisa diambil
-- atau dijual. Meja di samping spawn: jalan keluar spawn ke utara
-- (x ~0) dan ke base (belok setelah z < 161) tetap lega.
local function buildExhibitionTable()
	local centerX = Config.EXHIBITION_TABLE_CENTER_X
	local centerZ = Config.EXHIBITION_TABLE_CENTER_Z
	local topSize = Config.EXHIBITION_TABLE_TOP_SIZE
	local topY = Config.EXHIBITION_TABLE_TOP_Y
	-- Alas atas meja (permukaan pajang y = topY + 0.25 = 3.0).
	local top = makePart(
		"ExhibitionTableTop",
		topSize,
		Vector3.new(centerX, topY, centerZ),
		Enum.Material.Wood,
		Color3.fromRGB(170, 120, 70)
	)
	top.CanCollide = true
	-- 4 kaki di sudut meja (dari permukaan plaza y = 0.6 sampai
	-- bawah alas y = topY - 0.25 = 2.5).
	local legHeight = Config.EXHIBITION_TABLE_LEG_HEIGHT
	local legY = 0.6 + legHeight / 2
	for _, legX in ipairs({ -1, 1 }) do
		for _, legZ in ipairs({ -1, 1 }) do
			makePart(
				"ExhibitionTableLeg",
				Vector3.new(0.8, legHeight, 0.8),
				Vector3.new(
					centerX + legX * (topSize.X / 2 - 0.8),
					legY,
					centerZ + legZ * (topSize.Z / 2 - 0.8)
				),
				Enum.Material.Wood,
				Color3.fromRGB(110, 70, 40)
			)
		end
	end
	-- Papan nama meja di ujung BARAT (menghadap spawn): papan
	-- menempel di ujung alas, sisi atas papan rata dengan bawah
	-- alas (y = 2.5). Pemain baru spawn langsung melihat tulisan.
	local signBoard = makePart(
		"ExhibitionTableSign",
		Vector3.new(0.15, 1.4, 10),
		Vector3.new(centerX - topSize.X / 2 - 0.075, 1.8, centerZ),
		Enum.Material.Wood,
		Color3.fromRGB(150, 30, 30)
	)
	signBoard.CanCollide = false
	local signGui = Instance.new("SurfaceGui")
	signGui.Name = "ExhibitionTableSignGui"
	signGui.Face = Enum.NormalId.Left
	signGui.PixelsPerStud = 50
	signGui.LightInfluence = 0
	signGui.Parent = signBoard
	local signText = Instance.new("TextLabel")
	signText.Name = "SignText"
	signText.Size = UDim2.new(1, 0, 1, 0)
	signText.BackgroundTransparency = 1
	signText.Text = Config.EXHIBITION_SIGN_TEXT
	signText.TextColor3 = Color3.fromRGB(255, 255, 255)
	signText.TextScaled = false
	signText.TextSize = Config.EXHIBITION_SIGN_TEXT_SIZE
	signText.Font = Enum.Font.GothamBold
	signText.Parent = signGui
	-- 7 Brainrot pajangan: baris depan (z - ROW_Z) 4 jenis pertama,
	-- baris belakang (z + ROW_Z) 3 jenis terakhir. Origin model di
	-- kaki -> PivotTo di permukaan alas (y = 3.0). Model menghadap
	-- barat (-X, ke arah spawn). Tanpa prompt, tanpa remote.
	local surfaceY = topY + topSize.Y / 2
	local spacingX = Config.EXHIBITION_SPACING_X
	local rowZ = Config.EXHIBITION_ROW_Z
	local frontX = { -1.5, -0.5, 0.5, 1.5 }
	local backX = { -1, 0, 1 }
	for i, kind in ipairs(Config.RosterOrder) do
		local model = createBrainrotModel(kind, Config.EXHIBITION_MODEL_SCALE)
		if model then
			local xOffset
			local zOffset
			if i <= 4 then
				xOffset = frontX[i] * spacingX
				zOffset = -rowZ
			else
				xOffset = backX[i - 4] * spacingX
				zOffset = rowZ
			end
			model.Name = "ExhibitionBrainrot_" .. kind
			model.Parent = Workspace
			model:PivotTo(CFrame.new(centerX + xOffset, surfaceY, centerZ + zOffset)
				* CFrame.Angles(0, math.rad(-90), 0))
		end
	end
end

-- Dinding pembatas tepi map (FIX ROUND 6, 20 Nov — perintah bos
-- "bikin mentok biar ga jatoh pas ke ujung map"): 4 dinding
-- TRANSPARAN (Transparency 1, tidak mengubah visual map sama sekali),
-- CanCollide true, tinggi 20 stud (lompat pemain ~7 stud, tidak bisa
-- dilompati), di garis depan hutan (x = ±158, z = ±196 — konstanta
-- Config.BOUNDARY_WALL_*). Pemain mentok di tepi area main sebelum
-- mencapai tepi terrain (x ±170, z ±210); pagar kayu 3 stud yang lama
-- (buildGates) gampang dilompati, dinding ini yang menahan.
-- Tidak menghalangi apa pun di dalam area main: conveyor, base,
-- plaza, jalan, kios, dan semua spawn peti ada di dalam dinding.
-- Dinding air flood (WaterWall, CanCollide false, bergerak z -160..160)
-- lewat di dalam area ini tanpa bersentuhan dengan dinding pembatas.
local function buildBoundaryWalls()
	local halfX = Config.BOUNDARY_WALL_HALF_X
	local halfZ = Config.BOUNDARY_WALL_HALF_Z
	local height = Config.BOUNDARY_WALL_HEIGHT
	local thick = Config.BOUNDARY_WALL_THICKNESS
	local centerY = height / 2
	local function wall(name, size, position)
		local part = Instance.new("Part")
		part.Name = name
		part.Size = size
		part.Position = position
		part.Material = Enum.Material.SmoothPlastic
		part.Color = Color3.fromRGB(255, 255, 255)
		part.Transparency = 1
		part.Anchored = true
		part.CanCollide = true
		part.Parent = Workspace
		return part
	end
	-- Barat/timur: sepanjang z (tambah `thick` supaya sudut tertutup).
	wall("BoundaryWallW", Vector3.new(thick, height, 2 * halfZ + thick), Vector3.new(-halfX, centerY, 0))
	wall("BoundaryWallE", Vector3.new(thick, height, 2 * halfZ + thick), Vector3.new(halfX, centerY, 0))
	-- Utara/selatan: sepanjang x.
	wall("BoundaryWallN", Vector3.new(2 * halfX + thick, height, thick), Vector3.new(0, centerY, -halfZ))
	wall("BoundaryWallS", Vector3.new(2 * halfX + thick, height, thick), Vector3.new(0, centerY, halfZ))
end

local function buildWorld()
	setupLighting()
	buildTerrain()
	buildConveyor()
	buildPlaza()
	buildBases()
	buildGates()
	buildForest()
	buildBoundaryWalls()
	buildTrees()
	buildLamps()
	buildLanterns()
	buildStalls()
	buildVendorCarts()
	buildExhibitionTable()
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
-- FIX ROUND 3 (item 6): kaca sisi PINTU (atribut IsDoor) tetap
-- CanCollide false walau terkunci — pemilik masuk-keluar bebas lewat
-- pintu, bukan pemilik tetap di-teleport oleh handler Touched dan
-- ditolak Steal.trySteal saat terkunci. Transparency pintu tetap 0.5
-- saat terkunci supaya terlihat.
local function setLockVisual(baseIdx, locked)
	local visuals = BaseVisuals[baseIdx]
	if not visuals or not visuals.GlassParts then
		return
	end
	for _, glass in ipairs(visuals.GlassParts) do
		if locked then
			glass.Transparency = 0.5
			if glass:GetAttribute("IsDoor") ~= true then
				glass.CanCollide = true
			end
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

-- Pemeliharaan atribut prompt pedestal (Stage 5): client membaca
-- atribut ini untuk label Taruh/Jual/Curi — JANGAN pakai teks
-- OwnerLabel sebagai sumber kebenaran kepemilikan. Atribut ditulis
-- HANYA server, di sini: OwnerUserId saat base di-assign/dilepas,
-- SlotFilled saat slot terisi/dikosongkan, Enabled saat base sudah
-- bisa dipakai (ada pemilik). Semua validasi tetap di server.
local function refreshPedestalPrompt(baseIdx, slotIdx)
	local promptsForBase = PedestalPrompts[baseIdx]
	if not promptsForBase then
		return
	end
	local prompt = promptsForBase[slotIdx]
	if not prompt then
		return
	end
	local owner = BaseOwner[baseIdx]
	if owner then
		prompt:SetAttribute("OwnerUserId", owner.UserId)
	else
		prompt:SetAttribute("OwnerUserId", 0)
	end
	local filled = false
	if owner then
		local state = Players[owner]
		if state and state.Slots[slotIdx] ~= nil then
			filled = true
		end
	end
	prompt:SetAttribute("SlotFilled", filled)
	prompt.Enabled = owner ~= nil
end

local function refreshAllPedestalPrompts(baseIdx)
	for slotIdx = 1, Config.SLOT_COUNT do
		refreshPedestalPrompt(baseIdx, slotIdx)
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
			refreshAllPedestalPrompts(baseIdx)
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
	refreshAllPedestalPrompts(baseIdx)
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
-- scale saat dibuat: pedestal/conveyor Config.BRAINROT_SCALE_CONVEYOR
-- (2.6), dibawa Config.BRAINROT_SCALE_CARRIED (1.8), peti
-- Config.BRAINROT_SCALE_CRATE (2.1) — FIX ROUND 5, +30%.
-- FIX ROUND 7 (20 Nov, foto referensi): roster jadi HIBRIDA
-- BINATANG + SAYURAN — ciri sayur HARUS terlihat dari part-part
-- model, bukan cuma ganti nama: wortel oranye di ayam, labu oranye
-- di babi, brokoli hijau di anjing, cabai merah di kucing, terong
-- ungu di beruang, tomat merah di harimau, daun kol hijau di gajah.
-- spec.Shape opsional: Enum.PartType (Ball untuk telinga/gong/dll).
local BRAINROT_FEATURES = {
	AyamWortel = {
		{ Name = "CarrotBeak", Size = Vector3.new(0.3, 0.25, 0.5), Offset = Vector3.new(0, 1.95, 0.75), Color = Color3.fromRGB(255, 140, 0) },
		{ Name = "Comb", Size = Vector3.new(0.5, 0.35, 0.15), Offset = Vector3.new(0, 2.75, 0), Color = Color3.fromRGB(220, 40, 40) },
		{ Name = "WingL", Size = Vector3.new(0.12, 0.7, 0.8), Offset = Vector3.new(-0.85, 1.1, 0), Color = Color3.fromRGB(250, 250, 245) },
		{ Name = "WingR", Size = Vector3.new(0.12, 0.7, 0.8), Offset = Vector3.new(0.85, 1.1, 0), Color = Color3.fromRGB(250, 250, 245) },
		{ Name = "CarrotBack", Size = Vector3.new(0.4, 1.1, 0.4), Offset = Vector3.new(0, 1.2, -0.9), Color = Color3.fromRGB(255, 140, 0) },
		{ Name = "CarrotLeaves", Size = Vector3.new(0.5, 0.35, 0.5), Offset = Vector3.new(0, 1.85, -0.9), Color = Color3.fromRGB(60, 170, 70) },
		{ Name = "CarrotTopLeaves", Size = Vector3.new(0.45, 0.3, 0.45), Offset = Vector3.new(0, 2.8, 0), Color = Color3.fromRGB(60, 170, 70) },
	},
	BabiLabu = {
		{ Name = "Snout", Size = Vector3.new(0.5, 0.35, 0.3), Offset = Vector3.new(0, 1.9, 0.65), Color = Color3.fromRGB(255, 170, 190) },
		{ Name = "EarL", Size = Vector3.new(0.3, 0.5, 0.15), Offset = Vector3.new(-0.45, 2.75, 0), Color = Color3.fromRGB(250, 200, 210) },
		{ Name = "EarR", Size = Vector3.new(0.3, 0.5, 0.15), Offset = Vector3.new(0.45, 2.75, 0), Color = Color3.fromRGB(250, 200, 210) },
		{ Name = "TailCurl", Size = Vector3.new(0.3, 0.3, 0.3), Offset = Vector3.new(0, 1.0, -0.9), Color = Color3.fromRGB(250, 200, 210), Shape = Enum.PartType.Ball },
		{ Name = "PumpkinStem", Size = Vector3.new(0.25, 0.5, 0.25), Offset = Vector3.new(0, 2.8, 0), Color = Color3.fromRGB(50, 140, 60) },
		{ Name = "PumpkinRibL", Size = Vector3.new(0.08, 1.2, 1.2), Offset = Vector3.new(-0.82, 1.0, 0), Color = Color3.fromRGB(220, 100, 0) },
		{ Name = "PumpkinRibR", Size = Vector3.new(0.08, 1.2, 1.2), Offset = Vector3.new(0.82, 1.0, 0), Color = Color3.fromRGB(220, 100, 0) },
	},
	AnjingBrokoli = {
		{ Name = "EarL", Size = Vector3.new(0.3, 0.6, 0.3), Offset = Vector3.new(-0.45, 2.8, 0), Color = Color3.fromRGB(120, 70, 30) },
		{ Name = "EarR", Size = Vector3.new(0.3, 0.6, 0.3), Offset = Vector3.new(0.45, 2.8, 0), Color = Color3.fromRGB(120, 70, 30) },
		{ Name = "Snout", Size = Vector3.new(0.5, 0.4, 0.4), Offset = Vector3.new(0, 1.85, 0.65), Color = Color3.fromRGB(200, 160, 110) },
		{ Name = "Tail", Size = Vector3.new(0.25, 0.7, 0.25), Offset = Vector3.new(0, 0.9, -0.95), Color = Color3.fromRGB(120, 70, 30) },
		{ Name = "BroccoliHead", Size = Vector3.new(0.9, 0.9, 0.9), Offset = Vector3.new(0, 2.85, 0), Color = Color3.fromRGB(60, 170, 80), Shape = Enum.PartType.Ball },
		{ Name = "BroccoliHeadL", Size = Vector3.new(0.6, 0.6, 0.6), Offset = Vector3.new(-0.4, 2.6, 0.1), Color = Color3.fromRGB(60, 170, 80), Shape = Enum.PartType.Ball },
		{ Name = "BroccoliHeadR", Size = Vector3.new(0.6, 0.6, 0.6), Offset = Vector3.new(0.4, 2.6, 0.1), Color = Color3.fromRGB(60, 170, 80), Shape = Enum.PartType.Ball },
		{ Name = "BroccoliBack", Size = Vector3.new(0.8, 0.8, 0.8), Offset = Vector3.new(0, 1.6, -0.85), Color = Color3.fromRGB(60, 170, 80), Shape = Enum.PartType.Ball },
	},
	KucingCabai = {
		{ Name = "EarL", Size = Vector3.new(0.35, 0.5, 0.15), Offset = Vector3.new(-0.4, 2.8, 0), Color = Color3.fromRGB(60, 60, 60) },
		{ Name = "EarR", Size = Vector3.new(0.35, 0.5, 0.15), Offset = Vector3.new(0.4, 2.8, 0), Color = Color3.fromRGB(60, 60, 60) },
		{ Name = "Tail", Size = Vector3.new(0.25, 0.9, 0.25), Offset = Vector3.new(0, 0.9, -0.95), Color = Color3.fromRGB(60, 60, 60) },
		{ Name = "Nose", Size = Vector3.new(0.2, 0.15, 0.1), Offset = Vector3.new(0, 1.95, 0.65), Color = Color3.fromRGB(255, 120, 150) },
		{ Name = "WhiskerL", Size = Vector3.new(0.5, 0.05, 0.05), Offset = Vector3.new(-0.55, 1.95, 0.62), Color = Color3.fromRGB(240, 240, 240) },
		{ Name = "WhiskerR", Size = Vector3.new(0.5, 0.05, 0.05), Offset = Vector3.new(0.55, 1.95, 0.62), Color = Color3.fromRGB(240, 240, 240) },
		{ Name = "ChiliBack", Size = Vector3.new(0.35, 1.2, 0.35), Offset = Vector3.new(0, 1.5, -0.9), Color = Color3.fromRGB(220, 30, 30) },
		{ Name = "ChiliStem", Size = Vector3.new(0.3, 0.25, 0.3), Offset = Vector3.new(0, 2.15, -0.9), Color = Color3.fromRGB(50, 140, 60) },
		{ Name = "ChiliHead", Size = Vector3.new(0.5, 0.35, 0.5), Offset = Vector3.new(0, 2.8, 0), Color = Color3.fromRGB(220, 30, 30) },
	},
	BeruangTerong = {
		{ Name = "EarL", Size = Vector3.new(0.5, 0.5, 0.5), Offset = Vector3.new(-0.5, 2.7, 0), Color = Color3.fromRGB(110, 70, 40), Shape = Enum.PartType.Ball },
		{ Name = "EarR", Size = Vector3.new(0.5, 0.5, 0.5), Offset = Vector3.new(0.5, 2.7, 0), Color = Color3.fromRGB(110, 70, 40), Shape = Enum.PartType.Ball },
		{ Name = "Snout", Size = Vector3.new(0.6, 0.4, 0.4), Offset = Vector3.new(0, 1.85, 0.62), Color = Color3.fromRGB(190, 150, 110) },
		{ Name = "EggplantBack", Size = Vector3.new(0.7, 1.3, 0.7), Offset = Vector3.new(0, 1.3, -0.85), Color = Color3.fromRGB(120, 50, 180) },
		{ Name = "EggplantStem", Size = Vector3.new(0.3, 0.3, 0.3), Offset = Vector3.new(0, 2.0, -0.85), Color = Color3.fromRGB(50, 140, 60) },
		{ Name = "EggplantBelly", Size = Vector3.new(0.9, 1.0, 0.2), Offset = Vector3.new(0, 1.0, 0.82), Color = Color3.fromRGB(120, 50, 180) },
	},
	HarimauTomat = {
		{ Name = "EarL", Size = Vector3.new(0.3, 0.4, 0.15), Offset = Vector3.new(-0.4, 2.75, 0), Color = Color3.fromRGB(200, 60, 20) },
		{ Name = "EarR", Size = Vector3.new(0.3, 0.4, 0.15), Offset = Vector3.new(0.4, 2.75, 0), Color = Color3.fromRGB(200, 60, 20) },
		{ Name = "Tail", Size = Vector3.new(0.3, 0.9, 0.3), Offset = Vector3.new(0, 0.9, -0.95), Color = Color3.fromRGB(230, 90, 20) },
		{ Name = "StripeL", Size = Vector3.new(0.08, 1.0, 1.0), Offset = Vector3.new(-0.82, 1.0, 0), Color = Color3.fromRGB(40, 20, 10) },
		{ Name = "StripeR", Size = Vector3.new(0.08, 1.0, 1.0), Offset = Vector3.new(0.82, 1.0, 0), Color = Color3.fromRGB(40, 20, 10) },
		{ Name = "TomatoBack", Size = Vector3.new(0.9, 0.9, 0.9), Offset = Vector3.new(0, 1.5, -0.85), Color = Color3.fromRGB(220, 40, 40), Shape = Enum.PartType.Ball },
		{ Name = "TomatoLeaves", Size = Vector3.new(0.5, 0.2, 0.5), Offset = Vector3.new(0, 2.0, -0.85), Color = Color3.fromRGB(50, 140, 60) },
		{ Name = "TomatoHead", Size = Vector3.new(0.6, 0.5, 0.6), Offset = Vector3.new(0, 2.8, 0), Color = Color3.fromRGB(220, 40, 40), Shape = Enum.PartType.Ball },
	},
	GajahKol = {
		{ Name = "Trunk", Size = Vector3.new(0.35, 1.0, 0.35), Offset = Vector3.new(0, 1.4, 0.7), Color = Color3.fromRGB(150, 150, 150) },
		{ Name = "TuskL", Size = Vector3.new(0.18, 0.18, 0.8), Offset = Vector3.new(-0.45, 1.7, 0.75), Color = Color3.fromRGB(245, 245, 240) },
		{ Name = "TuskR", Size = Vector3.new(0.18, 0.18, 0.8), Offset = Vector3.new(0.45, 1.7, 0.75), Color = Color3.fromRGB(245, 245, 240) },
		{ Name = "EarL", Size = Vector3.new(0.25, 1.2, 1.0), Offset = Vector3.new(-0.75, 2.1, -0.1), Color = Color3.fromRGB(170, 170, 170), Shape = Enum.PartType.Ball },
		{ Name = "EarR", Size = Vector3.new(0.25, 1.2, 1.0), Offset = Vector3.new(0.75, 2.1, -0.1), Color = Color3.fromRGB(170, 170, 170), Shape = Enum.PartType.Ball },
		{ Name = "CabbageBack", Size = Vector3.new(1.1, 1.1, 1.1), Offset = Vector3.new(0, 1.7, -0.7), Color = Color3.fromRGB(90, 200, 110), Shape = Enum.PartType.Ball },
		{ Name = "CabbageBackL", Size = Vector3.new(0.8, 0.8, 0.8), Offset = Vector3.new(-0.5, 1.5, -0.7), Color = Color3.fromRGB(90, 200, 110), Shape = Enum.PartType.Ball },
		{ Name = "CabbageBackR", Size = Vector3.new(0.8, 0.8, 0.8), Offset = Vector3.new(0.5, 1.5, -0.7), Color = Color3.fromRGB(90, 200, 110), Shape = Enum.PartType.Ball },
		{ Name = "CabbageHead", Size = Vector3.new(0.7, 0.4, 0.7), Offset = Vector3.new(0, 2.8, 0), Color = Color3.fromRGB(90, 200, 110) },
	},
}

-- Warna badan tiap hibrida (FIX ROUND 7): badan mengikuti
-- BINATANGNYA (ayam krem, babi = labu oranye, anjing cokelat,
-- kucing abu gelap, beruang cokelat, harimau oranye, gajah abu),
-- BUKAN warna rarity — rarity tetap terbaca dari kalung warna
-- rarity + aura rarity + label. Gajah Kol abu (dulu Gajah Gamelan
-- emas — emasnya pindah ke kalung/aura kuning emas).
local BRAINROT_BODY_COLORS = {
	AyamWortel = Color3.fromRGB(245, 240, 225),
	BabiLabu = Color3.fromRGB(255, 140, 20),
	AnjingBrokoli = Color3.fromRGB(150, 100, 60),
	KucingCabai = Color3.fromRGB(70, 70, 75),
	BeruangTerong = Color3.fromRGB(110, 70, 40),
	HarimauTomat = Color3.fromRGB(230, 120, 30),
	GajahKol = Color3.fromRGB(170, 170, 170),
}

local function addBrainrotPart(model, name, size, offset, color, material, shape)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	if shape ~= nil then
		part.Shape = shape
	end
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
-- permukaan. Warna badan dari BRAINROT_BODY_COLORS (binatangnya);
-- rarity terbaca dari kalung + aura + label.
-- FIX ROUND 9: TANPA `local` — mengisi forward declaration di atas
-- buildExhibitionTable (local function kedua akan membuat local BARU
-- yang menutupi forward declaration dan bug kembali).
createBrainrotModel = function(kind, scale)
	local entry = Config.Roster[kind]
	if entry == nil then
		return nil
	end
	local s = scale or 1
	local model = Instance.new("Model")
	model.Name = "Brainrot_" .. kind
	local bodyColor = BRAINROT_BODY_COLORS[kind] or entry.Color
	local bodyMaterial = Enum.Material.SmoothPlastic
	local body = addBrainrotPart(model, "Body",
		Vector3.new(1.6, 1.6, 1.6) * s, Vector3.new(0, 0.8 * s, 0),
		bodyColor, bodyMaterial)
	local head = addBrainrotPart(model, "Head",
		Vector3.new(1.2, 1.2, 1.2) * s, Vector3.new(0, 2.05 * s, 0),
		Color3.fromRGB(245, 240, 230), Enum.Material.SmoothPlastic)
	-- Mata hitam + highlight putih (FIX ROUND 3): mata lebih hidup.
	addBrainrotPart(model, "EyeL",
		Vector3.new(0.22, 0.28, 0.1) * s, Vector3.new(-0.3 * s, 2.1 * s, 0.62 * s),
		Color3.fromRGB(20, 20, 20), Enum.Material.SmoothPlastic)
	addBrainrotPart(model, "EyeR",
		Vector3.new(0.22, 0.28, 0.1) * s, Vector3.new(0.3 * s, 2.1 * s, 0.62 * s),
		Color3.fromRGB(20, 20, 20), Enum.Material.SmoothPlastic)
	addBrainrotPart(model, "EyeHighlightL",
		Vector3.new(0.08, 0.1, 0.05) * s, Vector3.new(-0.36 * s, 2.16 * s, 0.68 * s),
		Color3.fromRGB(255, 255, 255), Enum.Material.SmoothPlastic)
	addBrainrotPart(model, "EyeHighlightR",
		Vector3.new(0.08, 0.1, 0.05) * s, Vector3.new(0.24 * s, 2.16 * s, 0.68 * s),
		Color3.fromRGB(255, 255, 255), Enum.Material.SmoothPlastic)
	-- Kaki kecil di dasar badan + kalung aksen warna rarity (FIX ROUND 3):
	-- proporsi lebih rapi, tingkat rarity langsung terbaca dari kalung.
	addBrainrotPart(model, "FootL",
		Vector3.new(0.45, 0.3, 0.6) * s, Vector3.new(-0.4 * s, 0.15 * s, 0.15 * s),
		Color3.fromRGB(60, 55, 50), Enum.Material.SmoothPlastic)
	addBrainrotPart(model, "FootR",
		Vector3.new(0.45, 0.3, 0.6) * s, Vector3.new(0.4 * s, 0.15 * s, 0.15 * s),
		Color3.fromRGB(60, 55, 50), Enum.Material.SmoothPlastic)
	addBrainrotPart(model, "RarityCollar",
		Vector3.new(1.7, 0.22, 1.7) * s, Vector3.new(0, 1.5 * s, 0),
		entry.Color, Enum.Material.SmoothPlastic)
	local features = BRAINROT_FEATURES[kind]
	if features then
		for _, spec in ipairs(features) do
			addBrainrotPart(model, spec.Name, spec.Size * s, spec.Offset * s,
				spec.Color, spec.Material, spec.Shape)
		end
	end
	-- Aura rarity (FIX ROUND 7, foto image-37.png — glow hijau/biru
	-- di hewan pajangan): bola Neon SANGAT transparan warna rarity
	-- yang membungkus model + PointLight warna rarity yang lembut.
	-- SATU tempat di sini: createBrainrotModel dipakai conveyor,
	-- pedestal, dibawa, DAN di atas peti — jadi aura terlihat di
	-- keempat tempat tanpa 4 copy. Lembut (Transparency 0.88,
	-- Brightness 1, Range 8): tidak menyilaukan, tidak menutupi
	-- model/label (label di atas kepala, di luar bola aura).
	local auraShell = addBrainrotPart(model, "AuraShell",
		Vector3.new(2.4, 2.8, 2.4) * s, Vector3.new(0, 1.4 * s, 0),
		entry.Color, Enum.Material.Neon, Enum.PartType.Ball)
	auraShell.Transparency = Config.BRAINROT_AURA_TRANSPARENCY
	local auraLight = Instance.new("PointLight")
	auraLight.Name = "AuraLight"
	auraLight.Color = entry.Color
	auraLight.Range = Config.BRAINROT_AURA_RANGE
	auraLight.Brightness = Config.BRAINROT_AURA_BRIGHTNESS
	auraLight.Parent = body
	-- Label nama + rarity + income di atas model.
	-- FIX ROUND 5: TextScaled dimatikan, TextSize tetap 16 (dulu teks
	-- memenuhi label 180x64); ukuran label dari Config (160x44).
	-- StudsOffsetWorldSpace tetap 1.6 * s agar label selalu di atas
	-- kepala model yang lebih besar.
	local label = Instance.new("BillboardGui")
	label.Name = "BrainrotLabel"
	label.Size = UDim2.fromOffset(Config.BRAINROT_LABEL_WIDTH, Config.BRAINROT_LABEL_HEIGHT)
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
	text.TextScaled = false
	text.TextSize = Config.BRAINROT_LABEL_TEXT_SIZE
	text.TextWrapped = true
	text.Font = Enum.Font.GothamBold
	text.Parent = label
	model.PrimaryPart = body
	return model
end

-- Perbarui visual pedestal: model Brainrot skala
-- Config.BRAINROT_SCALE_CONVEYOR (2.6) + label kalau slot terisi,
-- kosong kalau tidak.
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
	local model = createBrainrotModel(item.Kind, Config.BRAINROT_SCALE_CONVEYOR)
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

-- Pasang/lepas model Brainrot yang dibawa pemain (skala
-- Config.BRAINROT_SCALE_CARRIED = 1.8, di atas kepala, mengikuti
-- karakter lewat Weld). Dipanggil setelah place/sell/rebirth, setelah
-- load memulihkan Carried, dan setiap kali karakter (re)spawn
-- (CharacterAdded, DESIGN.md 8).
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
	local model = createBrainrotModel(state.Carried.Kind, Config.BRAINROT_SCALE_CARRIED)
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
-- ada dan LoadStatus "ok" atau "new" — DITAMBAH fallback KHUSUS Studio:
-- file .rbxl lokal belum di-publish sehingga GetDataStore selalu gagal
-- ("You must publish this place to the web to access DataStore",
-- DataStore:128) dan LoadStatus jadi "failed". Di Studio, sesi tetap
-- boleh bermain; di place yang sudah di-publish DataStore bekerja
-- normal sehingga fallback ini tidak terpicu. Fallback ini TIDAK
-- mengubah penjaga save: DataStore.saveData tetap menolak bila
-- LoadStatus bukan "ok"/"new" dan BindToClose tetap melewati yang
-- bukan "ok"/"new" (DESIGN.md 17.2/17.4 — jangan menimpa data
-- tersimpan dengan default).
local function isLoadReady(player)
	local state = Players[player]
	if state == nil then
		return false
	end
	if state.LoadStatus == "ok" or state.LoadStatus == "new" then
		return true
	end
	return RunService:IsStudio() and state.LoadStatus == "failed"
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
		refreshPedestalPrompt(baseIdx, slotIdx)
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
		refreshPedestalPrompt(baseIdx, slotIdx)
	end
end

-- Handler SellCarriedRequest (jual Brainrot yang dibawa): cek
-- isLoadReady dulu, lalu Economy.sellCarried. Sukses: lepas visual
-- carried; uang baru dikirim Economy lewat MoneyUpdate.
local function onSellCarriedRequest(player)
	if not isLoadReady(player) then
		notifyLoadNotReady(player)
		return
	end
	local ok, msg = Economy.sellCarried(Players, player, Remotes)
	Remotes.Notify:FireClient(player, msg)
	if ok then
		refreshCarriedVisual(player)
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
			refreshAllPedestalPrompts(baseIdx)
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
		refreshPedestalPrompt(baseIdx, slotIdx)
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
-- (xCenter -68, DoorX -41) -> x = -35; base kanan (xCenter +68,
-- DoorX +41) -> x = +35. Target di LUAR lantai base (kiri [-96,-40],
-- kanan [40,96]) ke arah conveyor. Pemilik SELALU lolos (tidak di-teleport).
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
			local targetX = (xCenter < 0) and (doorX + 6) or (doorX - 6)
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
-- Flood + peti + conveyor (STAGE 4, DESIGN.md 7, 16.3, 19.2, 19.3).
-- Main pemilik TUNGGAL loop flood dan pemilik visual peti/conveyor/
-- dinding air. Flood hanya menyediakan transisi/sweep/data peti.
-- ---------------------------------------------------------------------------

-- Roll rarity spawn conveyor (DESIGN.md 3): roll 1-1000, entri
-- pertama yang RollMax-nya >= roll menang (Config.RosterOrder).
local function rollBrainrotKind()
	local roll = math.random(1, 1000)
	for _, kind in ipairs(Config.RosterOrder) do
		local entry = Config.Roster[kind]
		if entry ~= nil and roll <= entry.RollMax then
			return kind
		end
	end
	return "GajahKol"
end

-- Model Brainrot conveyor (skala Config.BRAINROT_SCALE_CONVEYOR = 2.6
-- + label) dari entri ConveyorItems; dihancurkan saat item tersapu
-- flood (dari daftar swept hasil Flood.tick) atau mencapai ujung
-- conveyor.
local function createConveyorModel(item)
	local model = createBrainrotModel(item.Kind, Config.BRAINROT_SCALE_CONVEYOR)
	if not model then
		return nil
	end
	-- Prompt ambil: menempel pada PrimaryPart (Body) model sehingga
	-- ikut bergeser saat moveConveyorItems memindahkan model dengan
	-- PivotTo; ikut hancur bersama model saat tersapu flood atau
	-- mencapai ujung conveyor (destroyConveyorModel).
	local rosterEntry = Config.Roster[item.Kind]
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Ambil"
	prompt.ObjectText = (rosterEntry and rosterEntry.DisplayName) or item.Kind
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = Config.TAKE_RANGE -- FIX ROUND 5: 24 stud, kedua jalur terjangkau dari kedua sisi
	prompt:SetAttribute("PromptKind", "Conveyor")
	prompt:SetAttribute("Uid", item.Uid)
	prompt.Parent = model.PrimaryPart
	model.Parent = Workspace
	model:PivotTo(CFrame.new(item.Position))
	ConveyorModels[item.Uid] = model
	return model
end

local function destroyConveyorModel(uid)
	local model = ConveyorModels[uid]
	if model then
		model:Destroy()
		ConveyorModels[uid] = nil
	end
end

-- Spawn satu Brainrot baru di conveyor (MAIN-SERVER-PLAN Langkah 6):
-- roll rarity, jalur 1/2 (x = -7.5 / +7.5), UID dari newUid(),
-- entri {Uid, Kind, Lane, Position, SpawnedAt} ditambah ke
-- ConveyorItems + model visualnya dibuat. Posisi spawn mengikuti
-- arah gerak: z = -conveyorDirection * CONVEYOR_END_Z (ujung awal).
-- DIJEDA selama fase Warning (DESIGN.md 7, 19.2).
local function spawnConveyorItem()
	if FloodState.Phase == "Warning" then
		return nil
	end
	local kind = rollBrainrotKind()
	local lane = math.random(1, 2)
	local laneX = Config.CONVEYOR_LANES_X[lane]
	local spawnZ = -conveyorDirection * Config.CONVEYOR_END_Z
	local item = {
		Uid = newUid(),
		Kind = kind,
		Lane = lane,
		Position = Vector3.new(laneX, 0.55, spawnZ),
		SpawnedAt = os.clock(),
	}
	table.insert(ConveyorItems, item)
	createConveyorModel(item)
	return item
end

-- Geser tiap entri ConveyorItems sepanjang sumbu Z searah
-- conveyorDirection * CONVEYOR_SPEED (dt detik sejak tick lalu)
-- dan pindahkan model visualnya mengikuti Position. Entri yang
-- melewati ujung akhir DIHAPUS + modelnya dihancurkan — TANPA
-- peti (peti hanya berasal dari sweep saat flood, DESIGN.md 19.2):
-- hapus bila conveyorDirection == 1 dan Position.Z >=
-- CONVEYOR_END_Z, atau conveyorDirection == -1 dan Position.Z <=
-- -CONVEYOR_END_Z. TIDAK ADA angka batas hardcode — selalu
-- Config.CONVEYOR_END_Z. Iterasi mundur agar penghapusan aman.
local function moveConveyorItems(dt)
	local step = conveyorDirection * Config.CONVEYOR_SPEED * dt
	for i = #ConveyorItems, 1, -1 do
		local item = ConveyorItems[i]
		item.Position = item.Position + Vector3.new(0, 0, step)
		local model = ConveyorModels[item.Uid]
		if model ~= nil then
			model:PivotTo(CFrame.new(item.Position))
		end
		local pastEnd = false
		if conveyorDirection == 1 and item.Position.Z >= Config.CONVEYOR_END_Z then
			pastEnd = true
		elseif conveyorDirection == -1 and item.Position.Z <= -Config.CONVEYOR_END_Z then
			pastEnd = true
		end
		if pastEnd then
			destroyConveyorModel(item.Uid)
			table.remove(ConveyorItems, i)
		end
	end
end

-- Warna kotak peti per kelas (DESIGN.md 7): Pasar hijau, Pedagang
-- kuning, Tumpah ungu (+ cahaya emas).
local CRATE_BOX_COLORS = {
	Pasar = Color3.fromRGB(60, 200, 90),
	Pedagang = Color3.fromRGB(240, 200, 40),
	Tumpah = Color3.fromRGB(170, 80, 240),
}

-- Model peti (MAIN-SERVER-PLAN §3): kotak + model Brainrot di
-- atasnya (skala Config.BRAINROT_SCALE_CRATE = 2.1) + label +
-- (tahan 0.5 detik) dengan atribut CrateId. Peti Tumpah mendapat
-- cahaya emas (PointLight). Flood tidak pernah membuat Instance
-- peti — Main yang membuatnya dari entri CrateState.
local function createCrateModel(crate)
	local boxColor = CRATE_BOX_COLORS[crate.Kind] or Color3.fromRGB(150, 150, 150)
	local model = Instance.new("Model")
	model.Name = "Crate_" .. crate.Id

	-- FIX ROUND 6 (20 Nov, perintah bos "susah buka box tsunami"):
	-- kotak peti dibesarkan 3x2x3 -> 4x2.5x4 dan label diangkat,
	-- supaya peti mudah dilihat + prompt "Buka Peti" mudah ketemu
	-- dari jarak wajar. Jangkauan klaimnya sendiri naik via
	-- Config.CLAIM_RANGE 12 -> 20 (prompt di bawah + validasi
	-- server Flood.claimCrate sama-sama membaca konstanta itu).
	-- Aturan spawn peti (>= 3 per siklus), isi/hadiah, timing
	-- flood, dan validasi klaim lain TIDAK berubah.
	local box = Instance.new("Part")
	box.Name = "CrateBox"
	box.Size = Vector3.new(4, 2.5, 4)
	box.Position = crate.Position
	box.Material = Enum.Material.Wood
	box.Color = boxColor
	box.Anchored = true
	box.CanCollide = true
	box.Parent = model

	-- Brainrot di dalam peti, di atas kotak (skala
	-- Config.BRAINROT_SCALE_CRATE = 2.1). Kotak kini 2.5 tinggi
	-- (atas y = posisi + 1.25), jadi Brainrot diangkat ke +2.5.
	local brainrotKind = crate.BrainrotKind or crate.Kind
	local top = createBrainrotModel(brainrotKind, Config.BRAINROT_SCALE_CRATE)
	if top then
		top.Parent = model
		top:PivotTo(CFrame.new(crate.Position + Vector3.new(0, 2.5, 0)))
	end

	-- Label: kelas peti + nama + rarity Brainrot di dalamnya.
	local entry = Config.Roster[brainrotKind]
	local labelText = "Peti " .. crate.Kind
	if entry ~= nil then
		labelText = labelText .. "\n" .. entry.DisplayName .. " (" .. entry.Rarity .. ")"
	end
	local label = Instance.new("BillboardGui")
	label.Name = "CrateLabel"
	label.Size = UDim2.fromOffset(200, 64)
	label.StudsOffsetWorldSpace = Vector3.new(0, 4.5, 0)
	label.AlwaysOnTop = true -- FIX ROUND 6: label peti selalu terlihat
	-- (tidak tertutup model Brainrot di atas kotak) supaya peti
	-- gampang ditemukan saat Scramble.
	label.LightInfluence = 0
	label.Parent = box
	local text = Instance.new("TextLabel")
	text.Name = "Label"
	text.Size = UDim2.new(1, 0, 1, 0)
	text.BackgroundTransparency = 1
	text.Text = labelText
	text.TextColor3 = Color3.fromRGB(255, 255, 255)
	text.TextScaled = true
	text.Font = Enum.Font.GothamBold
	text.Parent = label

	-- Peti Tumpah: cahaya emas (DESIGN.md 7).
	if crate.Kind == "Tumpah" then
		local goldLight = Instance.new("PointLight")
		goldLight.Color = Color3.fromRGB(255, 200, 60)
		goldLight.Range = 12
		goldLight.Brightness = 2
		goldLight.Parent = box
	end

	-- Prompt klaim: client (Stage 5) mendengarkan Triggered lalu
	-- mengirim ClaimRequest (crateId) ke server.
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Buka Peti"
	prompt.ObjectText = "Peti " .. crate.Kind
	prompt.HoldDuration = 0.5
	prompt.MaxActivationDistance = Config.CLAIM_RANGE
	prompt:SetAttribute("CrateId", crate.Id)
	prompt.Parent = box

	model.Parent = Workspace
	CrateModels[crate.Id] = model
	return model
end

local function destroyCrateModel(crateId)
	local model = CrateModels[crateId]
	if model then
		model:Destroy()
		CrateModels[crateId] = nil
	end
end

-- Visual flood milik Main (DESIGN.md 7, 19.2): dinding air kaca
-- biru, sirene banjir, dan 14 debris (baju/pintu/jendela).
-- Dibangun sekali saat server start; dinding air digerakkan
-- per-frame oleh updateWaterWall dari RunService.Heartbeat
-- (FIX ROUND 4), sirene + debris diperbarui tiap detik oleh
-- updateFloodVisuals dari floodTick.
local function buildFloodVisuals()
	-- Dinding air: kaca biru, lebar map, tinggi 30. Parkir tak
	-- terlihat (Transparency 1) sampai fase Flooding.
	WaterWall = Instance.new("Part")
	WaterWall.Name = "WaterWall"
	WaterWall.Size = Vector3.new(340, 30, 2)
	WaterWall.Position = Vector3.new(0, 15, -200)
	WaterWall.Material = Enum.Material.Glass
	WaterWall.Color = Color3.fromRGB(60, 140, 255)
	WaterWall.Transparency = 1
	WaterWall.Anchored = true
	WaterWall.CanCollide = false
	WaterWall.Parent = Workspace

	-- Sirene banjir: "Tornado Siren", Volume 0.6, loop (saat Warning).
	FloodSiren = Instance.new("Sound")
	FloodSiren.Name = "FloodSiren"
	FloodSiren.SoundId = "rbxassetid://792323017"
	FloodSiren.Volume = 0.6
	FloodSiren.Looped = true
	FloodSiren.Parent = Workspace

	-- 14 debris: 5 baju, 5 pintu, 4 jendela (part tipis warna
	-- berbeda, posisi awal acak deterministik, tak terlihat).
	local debrisSpecs = {}
	for i = 1, 5 do
		table.insert(debrisSpecs, { Name = "DebrisClothes", Size = Vector3.new(2, 0.3, 1.5), Color = Color3.fromRGB(220, 90, 90) })
	end
	for i = 1, 5 do
		table.insert(debrisSpecs, { Name = "DebrisDoor", Size = Vector3.new(2.5, 0.3, 4), Color = Color3.fromRGB(150, 100, 50) })
	end
	for i = 1, 4 do
		table.insert(debrisSpecs, { Name = "DebrisWindow", Size = Vector3.new(2, 0.3, 2), Color = Color3.fromRGB(140, 200, 240) })
	end
	for i, spec in ipairs(debrisSpecs) do
		local part = Instance.new("Part")
		part.Name = spec.Name
		part.Size = spec.Size
		part.Position = Vector3.new(-60 + ((i * 53) % 120), 2 + ((i * 7) % 10), -150 + ((i * 41) % 300))
		part.Material = Enum.Material.SmoothPlastic
		part.Color = spec.Color
		part.Transparency = 1
		part.Anchored = true
		part.CanCollide = false
		part.Parent = Workspace
		table.insert(DebrisParts, part)
	end
end

-- Gerakkan dinding air per-frame (FIX ROUND 4 — dipanggil dari
-- RunService.Heartbeat, ~60 fps): rumus yang SAMA dengan dulu
-- (progres dari sisa waktu fase Flooding, -CONVEYOR_END_Z ->
-- +CONVEYOR_END_Z dalam FLOODING_SECONDS), hanya frekuensi
-- update-nya yang berubah dari 1x/detik menjadi tiap frame.
-- Dulu dinding menempuh 320 stud dalam ~6 detik tapi posisinya
-- di-update 1x/detik -> ~53 stud per langkah, terlihat patah /
-- melompat. Kini 320 / 6 / 60 = ~0,89 stud/frame, mulus.
-- Di luar Flooding — atau begitu 6 detik Flooding habis
-- (now >= PhaseEndsAt, sebelum floodTick sempat memindah fase) —
-- dinding disembunyikan (Transparency 1) supaya tidak tertinggal
-- di tengah map. Fungsi ini HANYA menyentuh WaterWall: sirene
-- dan debris tetap di updateFloodVisuals (1 detik), dan TIDAK
-- ada logika transisi fase di sini (Flood.tick tetap pemiliknya).
local function updateWaterWall(now)
	if WaterWall == nil then
		return
	end
	if FloodState.Phase == "Flooding" and FloodState.PhaseEndsAt ~= nil and now < FloodState.PhaseEndsAt then
		local remaining = FloodState.PhaseEndsAt - now
		if remaining > FLOODING_SECONDS then
			remaining = FLOODING_SECONDS
		end
		local progress = 1 - (remaining / FLOODING_SECONDS)
		local wallZ = -Config.CONVEYOR_END_Z + progress * (2 * Config.CONVEYOR_END_Z)
		WaterWall.Transparency = 0.4
		WaterWall.Position = Vector3.new(0, 15, wallZ)
	else
		WaterWall.Transparency = 1
	end
end

-- Perbarui visual flood tiap detik (dipanggil floodTick):
-- - Sirene: berbunyi saat Warning, berhenti di fase lain.
-- - Debris: beterbangan (posisi acak tiap detik) hanya saat
--   Flooding; di luar itu tak terlihat. Kekacauan acak tiap
--   detik ini disengaja — debris TIDAK ikut per-frame supaya
--   tidak berkedip kacau.
-- - Dinding air TIDAK di sini lagi (FIX ROUND 4): digerakkan
--   per-frame oleh updateWaterWall dari Heartbeat.
local function updateFloodVisuals(now)
	if FloodSiren ~= nil then
		if FloodState.Phase == "Warning" then
			if not FloodSiren.IsPlaying then
				FloodSiren:Play()
			end
		else
			if FloodSiren.IsPlaying then
				FloodSiren:Stop()
			end
		end
	end

	local flying = FloodState.Phase == "Flooding"
	for _, part in ipairs(DebrisParts) do
		if flying then
			part.Transparency = 0
			part.Position = Vector3.new(math.random(-60, 60), math.random(2, 12), math.random(-150, 150))
			part.CFrame = part.CFrame * CFrame.Angles(0, math.rad(math.random(0, 359)), 0)
		else
			part.Transparency = 1
		end
	end
end

-- Knockback ringan sekali saat flood masuk fase Flooding
-- (DESIGN.md 7): pemain di luar base sendiri terdorong ke selatan
-- (arah gerak banjir) + sedikit ke atas. Pemain di dalam base
-- sendiri aman (tidak didorong). Dibungkus pcall agar kegagalan
-- dorong satu pemain tidak merusak floodTick.
local function applyFloodKnockback()
	for player, state in pairs(Players) do
		if state ~= nil then
			local character = player.Character
			local hrp = nil
			if character ~= nil then
				hrp = character:FindFirstChild("HumanoidRootPart")
			end
			if hrp ~= nil and not Flood.isInsideOwnBase(Players, player, hrp.Position) then
				pcall(function()
					hrp.AssemblyLinearVelocity = hrp.AssemblyLinearVelocity + Vector3.new(0, 3, 10)
				end)
			end
		end
	end
end

-- Tick flood 1 detik (Stage 4, MAIN-SERVER-PLAN Langkah 6 —
-- REVISI KE-3, MENGIKAT): panggil Flood.tick SATU kali; terapkan
-- SELURUH actions yang dikembalikan — Main TIDAK menghitung ulang
-- transisi apa pun. Bila actions.phase ~= nil, terapkan phase DAN
-- phaseEndsAt (termasuk nil — nil berarti tidak ada fase berjalan,
-- saat transisi ke Idle); nextFloodAt dan cycleActive diterapkan
-- bila tidak nil; debugConsumed == true mematikan DebugPending.
-- Setelah menerapkan FloodState: bila fase berubah, fire FloodEvent
-- (fase baru + sisa detik); bila ada cratesCreated, buat model peti
-- tiap entri; bila ada swept, hancurkan model visual conveyor tiap
-- item tersapu (cocokkan Uid) + lepas visual carried pemain yang
-- tersapu; bila conveyorFlip, balik arah conveyor. Kirim countdown
-- FloodEvent tiap detik selama fase Warning/Scramble. TIDAK ADA
-- pemanggilan fungsi Flood lain di sini dan TIDAK ADA penghitung
-- transisi di Main.
local function floodTick()
	local now = os.clock()
	-- Jepret pemain yang sedang membawa Brainrot SEBELUM tick,
	-- supaya visual carried yang tersapu bisa dilepas sesudahnya.
	local hadCarried = {}
	for player, state in pairs(Players) do
		if state.Carried ~= nil then
			hadCarried[player] = true
		end
	end

	local actions = Flood.tick(Players, ConveyorItems, Crates, FloodState, World, now, newUid)

	local phaseChanged = false
	if actions.phase ~= nil then
		phaseChanged = (actions.phase ~= FloodState.Phase)
		FloodState.Phase = actions.phase
		-- Termasuk nil: transisi ke Idle membuat PhaseEndsAt = nil
		-- (KOREKSI LANJUT — butir verifikasi eksplisit Stage 4).
		FloodState.PhaseEndsAt = actions.phaseEndsAt
	end
	if actions.nextFloodAt ~= nil then
		FloodState.NextFloodAt = actions.nextFloodAt
	end
	if actions.cycleActive ~= nil then
		FloodState.CycleActive = actions.cycleActive
	end
	if actions.debugConsumed == true then
		FloodState.DebugPending = false
	end

	-- Item tersapu: hancurkan model conveyor (cocokkan Uid; untuk
	-- item carried tidak ada model conveyor -> no-op) + lepas
	-- visual carried pemain yang kehilangan Brainrot-nya.
	if actions.swept ~= nil then
		for _, item in ipairs(actions.swept) do
			destroyConveyorModel(item.Uid)
		end
		for player, _ in pairs(hadCarried) do
			local state = Players[player]
			if state ~= nil and state.Carried == nil then
				destroyCarriedModel(player)
			end
		end
	end

	-- Peti dibuat pada tick ini: buat modelnya (Main pemilik visual).
	if actions.cratesCreated ~= nil then
		for _, crate in ipairs(actions.cratesCreated) do
			createCrateModel(crate)
		end
	end

	-- Arah conveyor dibalik sekali per flood.
	if actions.conveyorFlip == true then
		conveyorDirection = -conveyorDirection
		print("[Main] arah conveyor dibalik: " .. tostring(conveyorDirection))
	end

	-- FloodEvent (HANYA Main yang fire): saat fase berubah (fase
	-- baru + sisa detik), plus countdown tiap detik selama
	-- Warning/Scramble.
	if phaseChanged then
		local remaining = 0
		if FloodState.PhaseEndsAt ~= nil then
			remaining = math.max(0, FloodState.PhaseEndsAt - now)
		end
		Remotes.FloodEvent:FireAllClients(FloodState.Phase, remaining)
		print("[Main] flood fase -> " .. FloodState.Phase .. " (" .. tostring(remaining) .. " detik)")
		if FloodState.Phase == "Flooding" then
			applyFloodKnockback()
		end
	elseif FloodState.Phase == "Warning" or FloodState.Phase == "Scramble" then
		local remaining = 0
		if FloodState.PhaseEndsAt ~= nil then
			remaining = math.max(0, FloodState.PhaseEndsAt - now)
		end
		Remotes.FloodEvent:FireAllClients(FloodState.Phase, remaining)
	end

	updateFloodVisuals(now)
end

-- Tick kedaluwarsa peti 1 detik (Stage 4, DESIGN.md 19.3): peti
-- yang tidak diklaim dihapus setelah CRATE_LIFETIME (60 detik):
-- hancurkan model, hapus dari Crates, catat di log. Peti yang
-- sudah diklaim tidak perlu dibersihkan (modelnya sudah
-- dihancurkan Main saat klaim).
local function crateExpiryTick()
	local now = os.clock()
	for crateId, crate in pairs(Crates) do
		if crate.Claimed == false and now > crate.ExpiresAt then
			destroyCrateModel(crateId)
			Crates[crateId] = nil
			print("[Main] peti kedaluwarsa: " .. crateId)
		end
	end
end

-- Handler DebugFlood (Stage 4, DESIGN.md 19.2): HANYA mengatur
-- flag FloodState.DebugPending = true bila tidak ada siklus
-- berjalan (CycleActive == false) DAN belum ada permintaan debug
-- yang menunggu (DebugPending == false). Bila siklus sedang
-- berjalan atau sudah dijadwalkan, DITOLAK dengan Notify.
-- Handler TIDAK memulai siklus dan TIDAK memanggil fungsi Flood —
-- Flood.tick (dipanggil loop Main) yang mengonsumsi flag itu.
local function onDebugFlood(player)
	if FloodState.CycleActive == false and FloodState.DebugPending == false then
		FloodState.DebugPending = true
		print("[Main] DebugFlood: siklus flood dijadwalkan oleh " .. player.Name)
	else
		Remotes.Notify:FireClient(player, "Siklus flood sudah berjalan / sudah dijadwalkan")
	end
end

-- Handler ClaimRequest (Stage 4): cek isLoadReady dulu, lalu
-- Flood.claimCrate(Players, Crates, player, crateId, newUid).
-- Sukses: hancurkan model peti + pasang visual carried.
local function onClaimRequest(player, crateId)
	if not isLoadReady(player) then
		notifyLoadNotReady(player)
		return
	end
	local ok, msg, _item, claimedCrateId = Flood.claimCrate(Players, Crates, player, crateId, newUid)
	Remotes.Notify:FireClient(player, msg)
	if ok and claimedCrateId ~= nil then
		destroyCrateModel(claimedCrateId)
		refreshCarriedVisual(player)
	end
end

-- Handler TakeRequest (ambil Brainrot dari conveyor): validasi
-- berurutan — (a) load siap (termasuk fallback Studio di isLoadReady),
-- (b) tangan kosong, (c) UID cocok dengan entri di ConveyorItems,
-- (d) jarak HumanoidRootPart ke posisi entri ConveyorItems saat itu
-- <= Config.TAKE_RANGE (24 stud, FIX ROUND 5 — dulu 12 via
-- STEAL_RANGE, jalur jauh tidak terjangkau dari tepi seberang).
-- Bila semua lolos, DALAM SATU LANGKAH tanpa yield: hapus entri dari
-- ConveyorItems, hancurkan model conveyor, isi Carried, pasang visual
-- carried, Notify sukses. Pesan sukses memakai
-- format "Kamu mendapatkan <nama>!" yang sama dengan klaim peti,
-- sehingga CarryPanel client ter-update lewat listener Notify yang
-- sudah ada (tanpa event baru).
local function onTakeRequest(player, uid)
	if not isLoadReady(player) then
		notifyLoadNotReady(player)
		return
	end
	local state = Players[player]
	if not state then
		return
	end
	if state.Carried ~= nil then
		Remotes.Notify:FireClient(player, "Tangan penuh — taruh atau jual dulu Brainrot yang kamu bawa.")
		return
	end
	local foundIdx = nil
	local item = nil
	for i, entry in ipairs(ConveyorItems) do
		if entry.Uid == uid then
			foundIdx = i
			item = entry
			break
		end
	end
	if item == nil then
		Remotes.Notify:FireClient(player, "Brainrot itu sudah tidak ada di conveyor.")
		return
	end
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if hrp == nil then
		Remotes.Notify:FireClient(player, "Terlalu jauh dari conveyor.")
		return
	end
	local distance = (hrp.Position - item.Position).Magnitude
	if distance > Config.TAKE_RANGE then
		Remotes.Notify:FireClient(player, "Terlalu jauh dari conveyor.")
		return
	end
	-- Sukses: satu langkah sinkron, tanpa yield di tengah.
	table.remove(ConveyorItems, foundIdx)
	destroyConveyorModel(item.Uid)
	state.Carried = { Uid = item.Uid, Kind = item.Kind }
	refreshCarriedVisual(player)
	local rosterEntry = Config.Roster[item.Kind]
	local displayName = (rosterEntry and rosterEntry.DisplayName) or item.Kind
	Remotes.Notify:FireClient(player, "Kamu mendapatkan " .. displayName .. "!")
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
				refreshAllPedestalPrompts(current.Base)
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
buildFloodVisuals()
connectLockBarriers()

PlayersService.PlayerAdded:Connect(onPlayerAdded)
PlayersService.PlayerRemoving:Connect(onPlayerRemoving)
game:BindToClose(onBindToClose)

-- Handler gameplay Stage 2: Place/Sell/Rebirth -> Economy.
-- Handler gameplay Stage 3: StealRequest -> Steal, LockRequest -> Main.
-- Handler gameplay Stage 4: ClaimRequest -> Flood.claimCrate,
-- DebugFlood -> onDebugFlood (hanya set flag DebugPending).
Remotes.PlaceRequest.OnServerEvent:Connect(onPlaceRequest)
Remotes.SellRequest.OnServerEvent:Connect(onSellRequest)
Remotes.SellCarriedRequest.OnServerEvent:Connect(onSellCarriedRequest)
Remotes.RebirthRequest.OnServerEvent:Connect(onRebirthRequest)
Remotes.StealRequest.OnServerEvent:Connect(onStealRequest)
Remotes.LockRequest.OnServerEvent:Connect(onLockRequest)
Remotes.ClaimRequest.OnServerEvent:Connect(onClaimRequest)
Remotes.TakeRequest.OnServerEvent:Connect(onTakeRequest)
Remotes.DebugFlood.OnServerEvent:Connect(onDebugFlood)

-- Pemain yang sudah ada sebelum script jalan (misal Play Solo di Studio).
for _, player in ipairs(PlayersService:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end

-- Loop utama 1 detik (SATU-SATUNYA loop; milik Main).
-- Stage 2: tambah incomeTick -> Economy.addIncome(Players, Remotes).
-- Stage 3: tambah lockExpiryTick (auto-unlock, DESIGN.md 19.1).
-- Stage 4: tambah floodTick + crateExpiryTick (DESIGN.md 19.2/19.3).
task.spawn(function()
	while true do
		task.wait(1)
		incomeTick()
		lockExpiryTick()
		floodTick()
		crateExpiryTick()
	end
end)

-- Loop conveyor (milik Main, Stage 4): spawn Brainrot tiap
-- SPAWN_INTERVAL (akumulator dt; dijeda selama fase Warning oleh
-- spawnConveyorItem sendiri) + gerak Brainrot sepanjang conveyor.
-- FIX ROUND 3: digerakkan RunService.Heartbeat dengan dt (~60 fps,
-- ~0.27 stud/frame) — dulu task.wait(0.1) + moveConveyorItems(0.1),
-- 10 langkah/detik x 1.6 stud/langkah sehingga terlihat patah-patah.
-- Kecepatan tetap 16 stud/detik (moveConveyorItems memakai dt);
-- interval spawn tetap 3.5 detik; loop 1 detik lain tidak berubah.
local conveyorSpawnAccumulator = 0
RunService.Heartbeat:Connect(function(dt)
	conveyorSpawnAccumulator = conveyorSpawnAccumulator + dt
	if conveyorSpawnAccumulator >= Config.SPAWN_INTERVAL then
		conveyorSpawnAccumulator = conveyorSpawnAccumulator - Config.SPAWN_INTERVAL
		spawnConveyorItem()
	end
	moveConveyorItems(dt)
	-- FIX ROUND 4: dinding air banjir juga digerakkan di sini,
	-- per-frame (~60 fps, ~0,89 stud/frame) — dulu di
	-- updateFloodVisuals 1x/detik (~53 stud/langkah, patah).
	-- Sirene + debris tetap di tick 1 detik (updateFloodVisuals).
	updateWaterWall(os.clock())
end)
