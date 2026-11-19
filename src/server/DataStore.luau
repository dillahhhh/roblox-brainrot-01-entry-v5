-- DataStore.luau — Pasar Brainrot (roblox-brainrot-01, Stage 2)
-- Load/save DataStore "PasarNusantara_V5" dengan proteksi penuh
-- (DESIGN.md 17): retry load, validasi struktur, migrasi 0 -> 1,
-- save aman (tidak pernah menimpa data baik dengan default),
-- konflik revision + SessionId (17.6), dan LoadToken (17.7).
-- Modul hanya require Config, tidak me-fire RemoteEvent apa pun.
-- Layanan DataStore diperoleh LAZY di dalam loadData/saveData saja
-- (DESIGN.md 16.2 revisi ke-3) — tidak pernah di top-level module.

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)

local DataStore = {}

local DATA_KEY_PREFIX = "Player_"

-- ---------------------------------------------------------------------------
-- Pemetaan key roster lama -> baru (FIX ROUND 7, 20 Nov): roster jadi
-- hibrida binatang + sayuran, key berubah (AyamIkan -> AyamWortel,
-- dst). Load HARUS toleran terhadap key lama: map ke baru. Key yang
-- tidak dikenal (bukan key lama, bukan key baru) DILEWATI dengan aman
-- — slot itu jadi kosong + warn log — JANGAN sampai satu key tak
-- dikenal membuat seluruh load "corrupt" atau crash (DESIGN.md 17.3:
-- satu field rusak -> corrupt, dikecualikan di sini KHUSUS untuk
-- Kind yang tidak dikenal, karena roster berganti nama).
-- ---------------------------------------------------------------------------

local LEGACY_KIND_MAP = {
	AyamIkan = "AyamWortel",
	BabiTerbang = "BabiLabu",
	AnjingEsTeh = "AnjingBrokoli",
	KucingRendang = "KucingCabai",
	BeruangDurian = "BeruangTerong",
	HarimauApi = "HarimauTomat",
	GajahGamelan = "GajahKol",
}

-- Petakan key lama ke baru di Slots + Carried; hapus item yang
-- Kind-nya tidak dikenal (slot jadi kosong). Mengembalikan jumlah
-- item yang dihapus karena Kind tidak dikenal. Idempotent: key baru
-- tidak ada di LEGACY_KIND_MAP, jadi pemanggilan kedua tidak
-- mengubah apa pun.
local function remapKinds(data)
	local dropped = 0
	local slots = data.Slots
	if type(slots) == "table" then
		for i = 1, Config.SLOT_COUNT do
			local key = tostring(i)
			local item = slots[key]
			if type(item) == "table" and type(item.Kind) == "string" then
				local mapped = LEGACY_KIND_MAP[item.Kind]
				if mapped ~= nil then
					item.Kind = mapped
				elseif Config.Roster[item.Kind] == nil then
					warn("[DataStore] remapKinds: Kind tidak dikenal di Slots["
						.. key .. "] (" .. item.Kind .. ") — slot dikosongkan")
					slots[key] = nil
					dropped = dropped + 1
				end
			end
		end
	end
	local carried = data.Carried
	if type(carried) == "table" and type(carried.Kind) == "string" then
		local mapped = LEGACY_KIND_MAP[carried.Kind]
		if mapped ~= nil then
			carried.Kind = mapped
		elseif Config.Roster[carried.Kind] == nil then
			warn("[DataStore] remapKinds: Kind tidak dikenal di Carried ("
				.. carried.Kind .. ") — carried dikosongkan")
			data.Carried = nil
			dropped = dropped + 1
		end
	end
	return dropped
end

-- ---------------------------------------------------------------------------
-- Validasi struktur (DESIGN.md 17.3). Satu gagal -> "corrupt".
-- Field tambahan yang tidak dikenal diabaikan (forward-compatible).
-- ---------------------------------------------------------------------------

-- Normalisasi Collected (FITUR INDEX, 20 Nov): field baru; save lama
-- tidak punya field ini (nil -> {}). Entri bukan string / kind tak
-- dikenal dibuang diam-diam; key roster lama dipetakan dulu (seperti
-- remapKinds). Hasil selalu array urutan RosterOrder (deterministik)
-- tanpa duplikat. Dipanggil di migrate + loadData SEBELUM validasi.
local function normalizeCollected(data)
	local raw = data.Collected
	local seen = {}
	if type(raw) == "table" then
		for _, kind in ipairs(raw) do
			if type(kind) == "string" then
				local mapped = LEGACY_KIND_MAP[kind] or kind
				if Config.Roster[mapped] ~= nil then
					seen[mapped] = true
				end
			end
		end
	end
	local ordered = {}
	for _, kind in ipairs(Config.RosterOrder) do
		if seen[kind] then
			table.insert(ordered, kind)
		end
	end
	data.Collected = ordered
	return ordered
end

local function isValidItem(item)
	if type(item) ~= "table" then
		return false
	end
	if type(item.Uid) ~= "string" or item.Uid == "" then
		return false
	end
	if type(item.Kind) ~= "string" or Config.Roster[item.Kind] == nil then
		return false
	end
	return true
end

local function validateData(data)
	if type(data) ~= "table" then
		return false, "data bukan table"
	end
	local version = data.Version
	if type(version) ~= "number" or version ~= math.floor(version)
		or version < 0 or version > Config.DATA_VERSION then
		return false, "Version tidak valid: " .. tostring(version)
	end
	local revision = data.Revision
	if type(revision) ~= "number" or revision ~= math.floor(revision)
		or revision < 0 then
		return false, "Revision tidak valid: " .. tostring(revision)
	end
	local money = data.Money
	if type(money) ~= "number" or money ~= money
		or money == math.huge or money == -math.huge
		or money < 0 or money > Config.MAX_MONEY then
		return false, "Money tidak valid: " .. tostring(money)
	end
	local rebirths = data.Rebirths
	if type(rebirths) ~= "number" or rebirths ~= math.floor(rebirths)
		or rebirths < 0 or rebirths > Config.MAX_REBIRTHS then
		return false, "Rebirths tidak valid: " .. tostring(rebirths)
	end
	local slots = data.Slots
	if type(slots) ~= "table" then
		return false, "Slots bukan table"
	end
	local seen = {}
	for i = 1, Config.SLOT_COUNT do
		local item = slots[tostring(i)]
		if item ~= nil then
			if not isValidItem(item) then
				return false, "Slots[" .. tostring(i) .. "] tidak valid"
			end
			if seen[item.Uid] then
				return false, "UID duplikat: " .. item.Uid
			end
			seen[item.Uid] = true
		end
	end
	local carried = data.Carried
	if carried ~= nil then
		if not isValidItem(carried) then
			return false, "Carried tidak valid"
		end
		if seen[carried.Uid] then
			return false, "UID duplikat: " .. carried.Uid
		end
	end
	local collected = data.Collected
	if collected ~= nil then
		if type(collected) ~= "table" then
			return false, "Collected bukan table"
		end
		for _, kind in ipairs(collected) do
			if type(kind) ~= "string" or Config.Roster[kind] == nil then
				return false, "Collected berisi kind tidak valid: " .. tostring(kind)
			end
		end
	end
	return true
end

-- ---------------------------------------------------------------------------
-- Migrasi (DESIGN.md 17.5): fungsi murni, satu langkah 0 -> 1.
-- Hanya mengisi field yang hilang dengan default; tidak pernah
-- menghapus atau menulis ulang nilai yang sudah valid.
-- ---------------------------------------------------------------------------

function DataStore.migrate(data)
	local out = {}
	if type(data) == "table" then
		for key, value in pairs(data) do
			out[key] = value
		end
	end
	if out.Money == nil then
		out.Money = Config.START_MONEY
	end
	if out.Rebirths == nil then
		out.Rebirths = 0
	end
	if out.Slots == nil then
		out.Slots = {}
	end
	if out.Revision == nil then
		out.Revision = 0
	end
	-- FIX ROUND 7: petakan key roster lama ke baru (lihat
	-- LEGACY_KIND_MAP di atas) — data legacy Version 0 yang
	-- menyimpan key lama ikut termigrasi ke key baru.
	remapKinds(out)
	-- FITUR INDEX: save lama tanpa Collected -> array kosong.
	normalizeCollected(out)
	out.Version = Config.DATA_VERSION
	return out
end

-- ---------------------------------------------------------------------------
-- loadData(player) -> (table | nil, string)
-- Status: "new" | "ok" | "failed" | "corrupt". TIDAK PERNAH
-- mengembalikan data yang belum divalidasi (DESIGN.md 17.3).
-- ---------------------------------------------------------------------------

function DataStore.loadData(player)
	local storeOk, store = pcall(function()
		return game:GetService("DataStoreService"):GetDataStore(Config.DATASTORE_NAME)
	end)
	if not storeOk or store == nil then
		warn("[DataStore] loadData: GetDataStore gagal untuk " .. player.Name .. ": " .. tostring(store))
		return nil, "failed"
	end

	local key = DATA_KEY_PREFIX .. tostring(player.UserId)
	local data = nil
	local lastErr = nil
	for attempt = 1, Config.LOAD_MAX_ATTEMPTS do
		local ok, result = pcall(function()
			return store:GetAsync(key)
		end)
		if ok then
			data = result
			lastErr = nil
			break
		end
		lastErr = result
		warn("[DataStore] loadData: GetAsync gagal (" .. tostring(attempt) .. "/"
			.. tostring(Config.LOAD_MAX_ATTEMPTS) .. ") untuk " .. player.Name
			.. ": " .. tostring(result))
		if attempt < Config.LOAD_MAX_ATTEMPTS then
			task.wait(Config.LOAD_RETRY_DELAY)
		end
	end
	if lastErr ~= nil then
		return nil, "failed"
	end
	if data == nil then
		return nil, "new"
	end

	if type(data) ~= "table" then
		warn("[DataStore] loadData: data bukan table untuk " .. player.Name)
		return nil, "corrupt"
	end
	local version = data.Version
	if version == nil or type(version) ~= "number"
		or version > Config.DATA_VERSION or version < 0 then
		warn("[DataStore] loadData: Version tidak valid untuk " .. player.Name
			.. ": " .. tostring(version))
		return nil, "corrupt"
	end
	if version == 0 then
		-- Legacy yang sah: migrasi 0 -> 1, lalu validasi hasil migrasi.
		data = DataStore.migrate(data)
	end
	-- FIX ROUND 7: remap key roster lama -> baru + lewati Kind tak
	-- dikenal (slot dikosongkan, warn) SEBELUM validasi — supaya
	-- data Version 1 yang masih menyimpan key lama (disimpan build
	-- v5) tetap bisa di-load, dan satu Kind tak dikenal tidak
	-- membuat seluruh load "corrupt".
	remapKinds(data)
	-- FITUR INDEX: normalisasi Collected SEBELUM validasi — save
	-- lama (Version 1, sebelum Index) tanpa field ini tetap valid.
	normalizeCollected(data)
	local valid, reason = validateData(data)
	if not valid then
		warn("[DataStore] loadData: data corrupt untuk " .. player.Name .. ": " .. tostring(reason))
		return nil, "corrupt"
	end
	return data, "ok"
end

-- ---------------------------------------------------------------------------
-- saveData(player, state, sessionId) -> (boolean, string, number | nil)
-- Penjaga (DESIGN.md 17.2, revisi ke-3): LoadToken SATU-SATUNYA penjaga
-- keanggotaan pemain — saveData TIDAK menerima tabel Players dan TIDAK
-- memeriksa keanggotaan Players. Lalu LoadStatus ("ok"/"new" saja),
-- lalu konflik revision di dalam transform UpdateAsync (17.6) plus
-- verifikasi Revision + SessionId hasil UpdateAsync sebelum klaim
-- sukses. Konflik dan skip TIDAK di-retry; kegagalan sementara
-- di-retry max SAVE_MAX_ATTEMPTS kali (2 detik antar percobaan).
-- ---------------------------------------------------------------------------

local function buildPayload(state, expectedRevision, sessionId)
	local slots = {}
	for i = 1, Config.SLOT_COUNT do
		local item = state.Slots[i]
		if item ~= nil then
			slots[tostring(i)] = { Uid = item.Uid, Kind = item.Kind }
		end
	end
	local carried = nil
	if state.Carried ~= nil then
		carried = { Uid = state.Carried.Uid, Kind = state.Carried.Kind }
	end
	-- FITUR INDEX: Collected (set kind -> true) disimpan sebagai
	-- array urutan RosterOrder; save lama tidak punya field ini.
	local collected = {}
	if type(state.Collected) == "table" then
		for _, kind in ipairs(Config.RosterOrder) do
			if state.Collected[kind] == true then
				table.insert(collected, kind)
			end
		end
	end
	return {
		Version = Config.DATA_VERSION,
		Revision = expectedRevision,
		SessionId = sessionId,
		Money = state.Money,
		Rebirths = state.Rebirths,
		Slots = slots,
		Carried = carried,
		Collected = collected,
	}
end

function DataStore.saveData(player, state, sessionId)
	if state == nil then
		return false, "skipped: state tidak ada", nil
	end
	if state.LoadToken == nil then
		return false, "skipped: state sudah dibersihkan", nil
	end
	if state.LoadStatus ~= "ok" and state.LoadStatus ~= "new" then
		local reason = "skipped: LoadStatus = " .. tostring(state.LoadStatus)
		warn("[DataStore] saveData: " .. reason .. " untuk " .. player.Name)
		return false, reason, nil
	end

	local expectedRevision
	if state.LoadedRevision == nil then
		expectedRevision = 1
	else
		expectedRevision = state.LoadedRevision + 1
	end

	local key = DATA_KEY_PREFIX .. tostring(player.UserId)
	local lastErr = nil
	for attempt = 1, Config.SAVE_MAX_ATTEMPTS do
		local payload = buildPayload(state, expectedRevision, sessionId)
		-- Transform murni (tanpa yield): pemeriksaan revision di dalam
		-- transform. Kembalikan old TANPA perubahan bila konflik.
		local transform = function(old)
			if old == nil then
				-- Belum ada record (atau terhapus): tulis payload baru.
				-- Revision = LoadedRevision + 1 bila pernah load,
				-- 1 bila pemain baru — keduanya = expectedRevision.
				return payload
			end
			if state.LoadedRevision == nil then
				-- Dianggap baru padahal record sudah ada -> konflik.
				return old
			end
			if type(old) ~= "table" or old.Revision ~= state.LoadedRevision then
				-- Data sudah ditulis sesi/server lain setelah load -> konflik.
				return old
			end
			return payload
		end

		local storeOk, store = pcall(function()
			return game:GetService("DataStoreService"):GetDataStore(Config.DATASTORE_NAME)
		end)
		if not storeOk or store == nil then
			lastErr = store
			warn("[DataStore] saveData: GetDataStore gagal untuk " .. player.Name
				.. ": " .. tostring(store))
		else
			local ok, result = pcall(function()
				return store:UpdateAsync(key, transform)
			end)
			if not ok then
				lastErr = result
				warn("[DataStore] saveData: UpdateAsync gagal (" .. tostring(attempt) .. "/"
					.. tostring(Config.SAVE_MAX_ATTEMPTS) .. ") untuk " .. player.Name
					.. ": " .. tostring(result))
			elseif type(result) == "table"
				and result.Revision == expectedRevision
				and result.SessionId == sessionId then
				-- Sukses terverifikasi (pcall sukses saja TIDAK cukup).
				return true, "saved", expectedRevision
			else
				-- UpdateAsync berhasil tapi mengembalikan record LAMA
				-- (transform menolak menulis) -> KONFLIK, bukan sukses.
				local gotRevision = "?"
				local gotSession = "?"
				if type(result) == "table" then
					gotRevision = tostring(result.Revision)
					gotSession = tostring(result.SessionId)
				end
				local reason = "conflict: revision lama " .. tostring(state.LoadedRevision)
					.. ", sudah " .. gotRevision .. " oleh sesi " .. gotSession
				warn("[DataStore] saveData: " .. reason .. " untuk " .. player.Name)
				return false, reason, nil
			end
		end
		if attempt < Config.SAVE_MAX_ATTEMPTS then
			task.wait(Config.LOAD_RETRY_DELAY)
		end
	end
	warn("[DataStore] saveData: gagal setelah " .. tostring(Config.SAVE_MAX_ATTEMPTS)
		.. " percobaan untuk " .. player.Name .. ": " .. tostring(lastErr))
	return false, "failed: " .. tostring(lastErr), nil
end

return DataStore
