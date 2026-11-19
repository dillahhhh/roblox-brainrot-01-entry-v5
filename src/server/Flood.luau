-- Flood.luau — Pasar Brainrot (roblox-brainrot-01, Stage 4)
-- Siklus flood "Pasar Tumpah" + peti (crate), server-authoritative.
-- Modul murni logika + state suntikan (DESIGN.md 16.2/16.3): hanya
-- require Config, tanpa state sendiri, tanpa Instance, tanpa loop
-- tanpa akhir, tanpa UID sendiri (newUid disuntikkan Main), tanpa
-- yield di antara validasi dan mutasi pada operasi atomik, tanpa
-- me-fire RemoteEvent, tanpa memanggil layanan penyimpanan.
-- Main pemilik TUNGGAL loop flood (DESIGN.md 19.2): loop 1 detik Main
-- memanggil Flood.tick SATU kali per detik; tick mengembalikan
-- SELURUH perubahan FloodState yang diusulkan (actions lengkap) dan
-- Main hanya menerapkan usulan itu — Flood tidak pernah mengubah
-- FloodState sendiri dan tidak pernah menghitung ulang di Main.
--
-- CATATAN KONTRAK (penting, jujur): DESIGN.md 16.4 mengikat
-- CrateState.Kind sebagai KELAS peti ("Pasar" | "Pedagang" |
-- "Tumpah"), sedangkan 19.3 menulis mutasi klaim sebagai
-- Carried = {Uid = newUid(), Kind = crate.Kind}. Kedua rumusan itu
-- tidak bisa dipenuhi sekaligus dengan satu field Kind: kelas peti
-- ("Pasar") BUKAN nama Brainrot dan TIDAK ADA di Config.Roster —
-- kalau Carried.Kind diisi "Pasar", visual carried gagal dibuat,
-- income nol, dan validasi DataStore (Kind harus ada di Roster)
-- akan menolak data pemain itu sebagai corrupt. Karena itu
-- CrateState menyimpan DUA field: Kind = kelas peti (sesuai 16.4,
-- dipakai warna kotak + label peti) dan BrainrotKind = nama
-- Brainrot di dalam peti (dari item yang tersapu, atau wakil
-- rarity untuk peti fallback). claimCrate mengisi Carried.Kind
-- dengan crate.BrainrotKind — Brainrot yang sama yang dimaksud
-- 19.3 — dengan UID BARU dari newUid(), bukan UID peti atau UID
-- item yang tersapu. Perilaku (klaim memberi satu Brainrot asli)
-- sama; hanya penamaan field yang diselaraskan agar tidak merusak
-- data pemain.

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local RunService = game:GetService("RunService")

local Flood = {}

-- Durasi fase Flooding (DESIGN.md 7/19.2: dinding air bergerak
-- utara -> selatan, ~6 detik). Tidak ada konstanta Config untuk ini;
-- nilai mengikuti spesifikasi transisi tick (now + 6).
local FLOODING_SECONDS = 6

-- ---------------------------------------------------------------------------
-- Bantuan kelas peti + posisi
-- ---------------------------------------------------------------------------

-- Kelas peti dari rarity Brainrot (DESIGN.md 7):
-- Common/Uncommon -> Pasar; Rare/Epic -> Pedagang;
-- Legendary/Mythic/Ultra Rare -> Tumpah.
local function classFromRarity(rarity)
	if rarity == "Common" or rarity == "Uncommon" then
		return "Pasar"
	elseif rarity == "Rare" or rarity == "Epic" then
		return "Pedagang"
	else
		return "Tumpah"
	end
end

-- Peluang naik SATU tingkat kelas peti (DESIGN.md 7):
-- Epic 25%, Rare 40%, Legendary 50%. Naik tingkat berarti
-- Pedagang -> Tumpah; Tumpah sudah tingkat tertinggi sehingga
-- tetap Tumpah; Pasar tidak punya peluang naik (tidak ada angka
-- di spesifikasi untuk Common/Uncommon).
local function rollUpgrade(rarity, class)
	local chance = 0
	if rarity == "Epic" then
		chance = 25
	elseif rarity == "Rare" then
		chance = 40
	elseif rarity == "Legendary" then
		chance = 50
	end
	if chance > 0 and math.random(1, 100) <= chance then
		if class == "Pedagang" then
			return "Tumpah"
		end
	end
	return class
end

-- Posisi peti dari kelasnya (DESIGN.md 7):
-- Pasar (hijau): dekat pintu base (pintu acak, sisi dalam menghadap
-- conveyor); Pedagang (kuning): tengah plaza; Tumpah (ungu):
-- utara jauh.
local function positionForClass(class)
	if class == "Pasar" then
		local baseIdx = math.random(1, Config.BASE_COUNT)
		local side = 1
		if baseIdx > 4 then
			side = 2
		end
		local xCenter = Config.BASE_X[side]
		local row = baseIdx
		if baseIdx > 4 then
			row = baseIdx - 4
		end
		local zCenter = Config.BASE_Z[row]
		-- Pintu di sisi dalam (menghadap conveyor): xCenter + 27
		-- untuk base kiri, xCenter - 27 untuk base kanan; peti
		-- diletakkan sedikit ke arah conveyor dari pintu.
		local doorX = xCenter + 27
		local towardConveyor = 3
		if xCenter > 0 then
			doorX = xCenter - 27
			towardConveyor = -3
		end
		return Vector3.new(doorX + towardConveyor, 1, zCenter + math.random(-4, 4))
	elseif class == "Pedagang" then
		return Vector3.new(math.random(-20, 20), 1, 155 + math.random(-10, 10))
	else
		return Vector3.new(math.random(-15, 15), 1, -150 + math.random(-10, 10))
	end
end

-- ---------------------------------------------------------------------------
-- isInsideOwnBase
-- ---------------------------------------------------------------------------

-- True jika position berada dalam batas aman base MILIK player
-- sendiri: |x - xCenter| <= SAFE_HALF_X (28) DAN
-- |z - zCenter| <= SAFE_HALF_Z (23). Pemain tanpa base -> false.
-- Dipakai sweep (DESIGN.md 19.2).
function Flood.isInsideOwnBase(players, player, position)
	local state = players[player]
	if state == nil or state.Base == nil then
		return false
	end
	local baseIdx = state.Base
	if type(baseIdx) ~= "number" or baseIdx < 1 or baseIdx > Config.BASE_COUNT then
		return false
	end
	local side = 1
	if baseIdx > 4 then
		side = 2
	end
	local xCenter = Config.BASE_X[side]
	local row = baseIdx
	if baseIdx > 4 then
		row = baseIdx - 4
	end
	local zCenter = Config.BASE_Z[row]
	local dx = position.X - xCenter
	if dx < 0 then
		dx = -dx
	end
	local dz = position.Z - zCenter
	if dz < 0 then
		dz = -dz
	end
	return dx <= Config.SAFE_HALF_X and dz <= Config.SAFE_HALF_Z
end

-- ---------------------------------------------------------------------------
-- sweep
-- ---------------------------------------------------------------------------

-- Menghitung item yang tersapu (DESIGN.md 19.2) dan menghapus
-- Carried yang tersapu dari state pemain (Carried = nil).
-- - Brainrot conveyor: SELALU tersapu. SEMUA entri conveyorItems
--   dikumpulkan ke washed dan DIHAPUS dari tabel conveyorItems
--   (penghapusan aman: iterasi MUNDUR, tidak pernah hapus sambil
--   iterasi maju).
-- - Brainrot di slot base: SELALU AMAN (tidak disentuh).
-- - Brainrot yang dibawa: tersapu HANYA jika HumanoidRootPart
--   pembawa berada DI LUAR batas aman base miliknya sendiri
--   (isInsideOwnBase == false). Pembawa tanpa base -> selalu
--   tersapu. Pembawa tanpa karakter/HumanoidRootPart -> posisinya
--   tidak bisa dipastikan berada di dalam base -> tersapu.
-- Mengembalikan array Item {Uid, Kind}. Murni logika + mutasi
-- tabel suntikan; tidak yield, tidak menyentuh Instance.
function Flood.sweep(players, conveyorItems, world)
	local washed = {}

	-- Conveyor: semua tersapu; iterasi mundur agar penghapusan aman.
	for i = #conveyorItems, 1, -1 do
		local entry = conveyorItems[i]
		if entry ~= nil and entry.Uid ~= nil and entry.Kind ~= nil then
			table.insert(washed, { Uid = entry.Uid, Kind = entry.Kind })
		end
		table.remove(conveyorItems, i)
	end

	-- Carried: tersapu hanya di luar base sendiri.
	for player, state in pairs(players) do
		if state ~= nil and state.Carried ~= nil then
			local inside = false
			local character = player.Character
			local hrp = nil
			if character ~= nil then
				hrp = character:FindFirstChild("HumanoidRootPart")
			end
			if hrp ~= nil then
				inside = Flood.isInsideOwnBase(players, player, hrp.Position)
			else
				-- Tanpa HumanoidRootPart tidak bisa dipastikan
				-- pembawa berada di dalam base -> tersapu.
				inside = false
			end
			if not inside then
				table.insert(washed, { Uid = state.Carried.Uid, Kind = state.Carried.Kind })
				state.Carried = nil
			end
		end
	end

	return washed
end

-- ---------------------------------------------------------------------------
-- spawnCrates
-- ---------------------------------------------------------------------------

-- Satu CrateState per item tersapu + jaminan minimal 3 peti PER
-- SIKLUS (DESIGN.md 19.4). `created` menghitung HANYA peti yang
-- BERHASIL dibuat pada pemanggilan ini; peti dari banjir
-- sebelumnya yang masih ada di tabel Crates TIDAK dihitung
-- (kondisi lama #Crates == 0 DIHAPUS dan tidak dipakai di sini).
-- Urutan fallback: 1 Pasar + 1 Pedagang + 1 Tumpah, diulang bila
-- perlu, sampai created == 3. Tiap pembuatan dibungkus pcall;
-- satu kegagalan tidak menggagalkan peti lain; kegagalan dicatat.
-- Kalau setelah semua fallback created masih < 3, warn
-- "fallback peti tidak mencapai 3" (bug, bukan diam).
-- Mengembalikan created (number). TIDAK membuat Instance peti
-- (Main yang membuatnya dari entri CrateState).
function Flood.spawnCrates(players, crates, washed, newUid)
	local created = 0

	-- Satu percobaan pembuatan peti (pcall): sukses -> created + 1.
	local function tryCreate(brainrotKind, rarity, class)
		local ok, err = pcall(function()
			local now = os.clock()
			local id = newUid()
			local crate = {
				Id = id,
				Kind = class,
				BrainrotKind = brainrotKind,
				Rarity = rarity,
				Position = positionForClass(class),
				Claimed = false,
				CreatedAt = now,
				ExpiresAt = now + Config.CRATE_LIFETIME,
			}
			crates[id] = crate
		end)
		if ok then
			created = created + 1
		else
			warn("[Flood] gagal membuat peti " .. tostring(class)
				.. " (" .. tostring(brainrotKind) .. "): " .. tostring(err))
		end
	end

	-- Satu peti per item tersapu; kelas dari rarity + peluang naik.
	for _, item in ipairs(washed) do
		local entry = Config.Roster[item.Kind]
		if entry ~= nil then
			local class = classFromRarity(entry.Rarity)
			class = rollUpgrade(entry.Rarity, class)
			tryCreate(item.Kind, entry.Rarity, class)
		else
			warn("[Flood] item tersapu dengan Kind tidak dikenal: " .. tostring(item.Kind))
		end
	end

	-- Jaminan minimal 3 peti PER SIKLUS INI (bukan dari isi Crates).
	-- Wakil Brainrot tiap kelas fallback: Pasar -> AyamWortel
	-- (Common), Pedagang -> AnjingBrokoli (Rare), Tumpah ->
	-- BeruangTerong (Legendary). FIX ROUND 7: key roster baru
	-- (dulu AyamIkan / AnjingEsTeh / BeruangDurian).
	local fallbacks = {
		{ BrainrotKind = "AyamWortel", Rarity = "Common", Class = "Pasar" },
		{ BrainrotKind = "AnjingBrokoli", Rarity = "Rare", Class = "Pedagang" },
		{ BrainrotKind = "BeruangTerong", Rarity = "Legendary", Class = "Tumpah" },
	}
	local rounds = 0
	while created < 3 and rounds < 3 do
		rounds = rounds + 1
		for _, fb in ipairs(fallbacks) do
			if created >= 3 then
				break
			end
			tryCreate(fb.BrainrotKind, fb.Rarity, fb.Class)
		end
	end

	if created < 3 then
		warn("[Flood] fallback peti tidak mencapai 3 pada siklus ini (created = " .. tostring(created) .. ")")
	end

	return created
end

-- ---------------------------------------------------------------------------
-- claimCrate
-- ---------------------------------------------------------------------------

-- Klaim peti: SATU critical section sinkron, tanpa yield
-- (DESIGN.md 19.3, seperti trySteal 18.2). FCFS: klaim valid
-- PERTAMA menang; klaim berikutnya pada peti yang sama ditolak
-- "peti sudah diklaim".
-- Urutan validasi (satu gagal = tolak, tanpa perubahan):
-- 1. crateId string tidak kosong dan Crates[crateId] ada, kalau
--    tidak -> "peti tidak ditemukan".
-- 2. State pemain ada dan LoadStatus "ok"/"new", kalau tidak ->
--    "data belum dimuat".
-- 3. Peti belum diklaim (Claimed == false), kalau tidak ->
--    "peti sudah diklaim".
-- 4. Tangan kosong (Carried == nil), kalau tidak -> "tangan penuh".
-- 5. HumanoidRootPart <= CLAIM_RANGE (20, FIX ROUND 6 — dulu 12)
--    dari posisi peti, kalau tidak / karakter tidak ada ->
--    "terlalu jauh".
-- 6. Peti belum kedaluwarsa (now <= ExpiresAt), kalau tidak ->
--    "peti sudah hilang".
-- Mutasi (satu langkah): tandai Claimed = true DULU, lalu
-- Carried = {Uid = newUid(), Kind = BrainrotKind} — UID BARU dari
-- newUid() milik Main; tidak pernah memakai ulang UID peti atau
-- UID item yang tersapu. Sukses: (true, "Kamu mendapatkan
-- <nama>!", item, crateId). Gagal: (false, alasan, nil, nil).
function Flood.claimCrate(players, crates, player, crateId, newUid)
	local function deny(reason)
		return false, reason, nil, nil
	end

	-- Langkah 1: crateId valid dan peti ada.
	if type(crateId) ~= "string" or crateId == "" then
		return deny("peti tidak ditemukan")
	end
	local crate = crates[crateId]
	if crate == nil then
		return deny("peti tidak ditemukan")
	end

	-- Langkah 2: state pemain ada dan load siap.
	-- Fallback KHUSUS Studio (sama seperti Main.isLoadReady):
	-- IsStudio() + "failed" juga siap; di live tidak terpicu.
	local state = players[player]
	if state == nil
		or (state.LoadStatus ~= "ok" and state.LoadStatus ~= "new"
			and not (RunService:IsStudio() and state.LoadStatus == "failed")) then
		return deny("data belum dimuat")
	end

	-- Langkah 3: peti belum diklaim.
	if crate.Claimed == true then
		return deny("peti sudah diklaim")
	end

	-- Langkah 4: tangan kosong.
	if state.Carried ~= nil then
		return deny("tangan penuh")
	end

	-- Langkah 5: jarak HumanoidRootPart ke peti <= CLAIM_RANGE.
	local character = player.Character
	local hrp = nil
	if character ~= nil then
		hrp = character:FindFirstChild("HumanoidRootPart")
	end
	if hrp == nil then
		return deny("terlalu jauh")
	end
	if (hrp.Position - crate.Position).Magnitude > Config.CLAIM_RANGE then
		return deny("terlalu jauh")
	end

	-- Langkah 6: peti belum kedaluwarsa.
	local now = os.clock()
	if now > crate.ExpiresAt then
		return deny("peti sudah hilang")
	end

	-- Mutasi (satu langkah, tanpa yield): tandai claimed DULU,
	-- lalu isi tangan dengan item BARU (UID baru dari newUid()).
	crate.Claimed = true
	local brainrotKind = crate.BrainrotKind or crate.Kind
	local item = { Uid = newUid(), Kind = brainrotKind }
	state.Carried = item

	local entry = Config.Roster[brainrotKind]
	local displayName = brainrotKind
	if entry ~= nil then
		displayName = entry.DisplayName
	end
	local message = "Kamu mendapatkan " .. displayName .. "!"
	return true, message, item, crateId
end

-- ---------------------------------------------------------------------------
-- tick
-- ---------------------------------------------------------------------------

-- Transisi fase flood (DESIGN.md 19.2). SATU-SATUNYA tempat yang
-- memutuskan transisi; dipanggil Main SATU kali per detik dari loop
-- utama. Membaca floodState (fase + timestamp) dan mengembalikan
-- tabel actions yang HARUS diterapkan Main:
-- {phase = string | nil, phaseEndsAt = number | nil,
--  nextFloodAt = number | nil, cycleActive = boolean | nil,
--  debugConsumed = boolean, swept = array Item,
--  cratesCreated = array CrateState, conveyorFlip = boolean}.
-- phase = fase BARU yang diusulkan (nil = tidak berubah);
-- phaseEndsAt SELALU diusulkan bersama phase (nil berarti tidak ada
-- fase berjalan, misal saat transisi ke Idle); nextFloodAt dan
-- cycleActive diterapkan bila tidak nil; debugConsumed == true
-- HANYA bila tick ini mengonsumsi DebugPending (Main lalu mematikan
-- flag DebugPending). swept + cratesCreated diisi HANYA pada
-- transisi Warning -> Flooding (sweep lalu spawnCrates DI DALAM
-- tick ini). conveyorFlip == true HANYA pada transisi
-- Flooding -> Scramble (arah conveyor dibalik sekali per flood).
-- Transisi:
-- - Idle -> Warning: now >= NextFloodAt ATAU DebugPending.
--   phaseEndsAt = now + WARNING_TIME; cycleActive = true.
-- - Warning -> Flooding: now >= PhaseEndsAt.
--   phaseEndsAt = now + 6; sweep lalu spawnCrates di dalam tick.
-- - Flooding -> Scramble: now >= PhaseEndsAt.
--   phaseEndsAt = now + SCRAMBLE_TIME; conveyorFlip = true.
-- - Scramble -> Idle: now >= PhaseEndsAt.
--   phaseEndsAt = nil (TIDAK ADA fase berjalan — butir eksplisit
--   checklist Stage 4); nextFloodAt = now + FLOOD_INTERVAL;
--   cycleActive = false.
-- Flood pertama: NextFloodAt = serverStart + FLOOD_FIRST (Main
-- menginisialisasi). tick tidak yield.
function Flood.tick(players, conveyorItems, crates, floodState, world, now, newUid)
	local actions = {
		phase = nil,
		phaseEndsAt = nil,
		nextFloodAt = nil,
		cycleActive = nil,
		debugConsumed = false,
		swept = {},
		cratesCreated = {},
		conveyorFlip = false,
	}

	local phase = floodState.Phase

	if phase == "Idle" then
		if floodState.DebugPending == true or now >= floodState.NextFloodAt then
			actions.phase = "Warning"
			actions.phaseEndsAt = now + Config.WARNING_TIME
			actions.cycleActive = true
			actions.debugConsumed = floodState.DebugPending == true
		end
	elseif phase == "Warning" then
		if floodState.PhaseEndsAt ~= nil and now >= floodState.PhaseEndsAt then
			actions.phase = "Flooding"
			actions.phaseEndsAt = now + FLOODING_SECONDS
			-- Sweep lalu spawnCrates DI DALAM tick ini.
			local washed = Flood.sweep(players, conveyorItems, world)
			actions.swept = washed
			-- Kumpulkan peti yang dibuat pada tick ini (bandingkan
			-- kunci Crates sebelum dan sesudah spawnCrates).
			local before = {}
			for id in pairs(crates) do
				before[id] = true
			end
			Flood.spawnCrates(players, crates, washed, newUid)
			for id, crate in pairs(crates) do
				if before[id] ~= true then
					table.insert(actions.cratesCreated, crate)
				end
			end
		end
	elseif phase == "Flooding" then
		if floodState.PhaseEndsAt ~= nil and now >= floodState.PhaseEndsAt then
			actions.phase = "Scramble"
			actions.phaseEndsAt = now + Config.SCRAMBLE_TIME
			actions.conveyorFlip = true
		end
	elseif phase == "Scramble" then
		if floodState.PhaseEndsAt ~= nil and now >= floodState.PhaseEndsAt then
			actions.phase = "Idle"
			-- NIL di sini disengaja dan mengikat: tidak ada fase
			-- berjalan saat Idle (DESIGN.md 16.4, KOREKSI LANJUT).
			actions.phaseEndsAt = nil
			actions.nextFloodAt = now + Config.FLOOD_INTERVAL
			actions.cycleActive = false
		end
	end

	return actions
end

return Flood
