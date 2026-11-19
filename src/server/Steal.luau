-- Steal.luau — Pasar Brainrot (roblox-brainrot-01, Stage 3)
-- Mencuri Brainrot antar-pemain, server-authoritative dan atomik.
-- Modul murni logika + state suntikan (DESIGN.md 16.2/16.3): hanya
-- require Config, tanpa state sendiri, tanpa Instance, tanpa loop
-- tanpa akhir, tanpa akses layanan penyimpanan, tanpa yield di antara
-- validasi dan mutasi. Client hanya mengirim baseIdx + slotIdx;
-- UID TIDAK PERNAH dibaca dari argumen client (DESIGN.md 18.1).
-- Urutan validasi mengikat: DESIGN.md 18.3 (langkah 1-9); aturan
-- mutasi anti-spam saat gagal: DESIGN.md 18.6.

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)

local Steal = {}

-- Definisi terkunci (DESIGN.md 19.1): Locked true + LockExpiresAt ada
-- + timer belum lewat. Kalau timer sudah lewat tapi loop auto-unlock
-- Main belum jalan, isLocked tetap false (benar).
local function isLocked(state, now)
	return state.Locked == true
		and state.LockExpiresAt ~= nil
		and now < state.LockExpiresAt
end

local function fireStealResult(remotes, thief, success, message)
	local event = remotes and remotes.StealResult
	if event ~= nil and thief ~= nil then
		event:FireClient(thief, success, message)
	end
end

-- Mencuri Brainrot dari pedestal base orang lain.
-- trySteal(players, thief, baseIdx, slotIdx, remotes, world)
--   -> (boolean, string, Player | nil, Item | nil)
-- Sukses: (true, "Berhasil mencuri <nama>!", victim, item).
-- Gagal: (false, alasan, nil, nil); satu-satunya perubahan yang
-- diizinkan saat gagal adalah LastStealAttemptAt (18.6).
function Steal.trySteal(players, thief, baseIdx, slotIdx, remotes, world)
	local now = os.clock()
	local thiefName = (thief ~= nil) and thief.Name or "?"

	-- Penolakan: fire StealResult (false, alasan) lalu kembalikan
	-- (false, alasan, nil, nil) tanpa perubahan state.
	local function deny(reason)
		fireStealResult(remotes, thief, false, reason)
		return false, reason, nil, nil
	end

	-- Langkah 1: tipe + rentang argumen. Request palsu dicatat warn
	-- (18.5) dan TIDAK mengubah LastStealAttemptAt (18.6).
	if type(baseIdx) ~= "number" or type(slotIdx) ~= "number"
		or baseIdx ~= math.floor(baseIdx) or slotIdx ~= math.floor(slotIdx)
		or baseIdx < 1 or baseIdx > Config.BASE_COUNT
		or slotIdx < 1 or slotIdx > Config.SLOT_COUNT then
		warn("[Steal] request palsu dari " .. thiefName
			.. ": baseIdx=" .. tostring(baseIdx)
			.. ", slotIdx=" .. tostring(slotIdx))
		return deny("request tidak valid")
	end

	-- Langkah 2: state pencuri ada dan LoadStatus "ok"/"new".
	local thiefState = players[thief]
	if thiefState == nil
		or (thiefState.LoadStatus ~= "ok" and thiefState.LoadStatus ~= "new") then
		return deny("data belum dimuat")
	end

	-- Langkah 3a: cooldown percobaan (1 detik). Ditolak di sini TIDAK
	-- memperbarui LastStealAttemptAt (18.6).
	if now - thiefState.LastStealAttemptAt < Config.STEAL_ATTEMPT_COOLDOWN then
		return deny("terlalu cepat, tunggu sebentar")
	end

	-- Langkah 3b: cooldown sukses (5 detik). Ditolak di sini TIDAK
	-- memperbarui LastStealAttemptAt (18.6).
	if now - thiefState.LastStealAt < Config.STEAL_COOLDOWN then
		local remaining = Config.STEAL_COOLDOWN - (now - thiefState.LastStealAt)
		local waitSecs = math.ceil(remaining)
		if waitSecs < 1 then
			waitSecs = 1
		end
		return deny("cooldown mencuri: tunggu " .. tostring(waitSecs) .. " detik")
	end

	-- LOLOS 1, 2, 3a, 3b: percobaan diterima untuk validasi penuh.
	-- SATU-SATUNYA mutasi anti-spam yang diizinkan pada penolakan
	-- langkah 4-9 (18.6): LastStealAttemptAt = now.
	thiefState.LastStealAttemptAt = now

	-- Langkah 4: korban ada — pemain yang Base == baseIdx dan BUKAN
	-- pencuri. Request palsu dicatat warn (18.5).
	local victim = nil
	local victimState = nil
	for player, state in pairs(players) do
		if player ~= thief and state.Base == baseIdx then
			victim = player
			victimState = state
			break
		end
	end
	if victim == nil or victimState == nil then
		warn("[Steal] request palsu dari " .. thiefName
			.. ": baseIdx=" .. tostring(baseIdx)
			.. ", slotIdx=" .. tostring(slotIdx)
			.. " (tidak ada korban)")
		return deny("base tidak valid")
	end

	-- Langkah 5: base korban TIDAK terkunci.
	if isLocked(victimState, now) then
		return deny("base terkunci")
	end

	-- Langkah 6: slot terisi.
	local item = victimState.Slots[slotIdx]
	if item == nil then
		return deny("slot kosong")
	end

	-- Langkah 7: tangan pencuri kosong.
	if thiefState.Carried ~= nil then
		return deny("tangan penuh")
	end

	-- Langkah 8: jarak HumanoidRootPart pencuri ke pedestal <= 12 stud.
	-- Karakter tidak ada / terlalu jauh -> tolak.
	local pedestalPos = nil
	if world ~= nil and world.PedestalPos ~= nil
		and world.PedestalPos[baseIdx] ~= nil then
		pedestalPos = world.PedestalPos[baseIdx][slotIdx]
	end
	local character = (thief ~= nil) and thief.Character or nil
	local hrp = nil
	if character ~= nil then
		hrp = character:FindFirstChild("HumanoidRootPart")
	end
	if hrp == nil or pedestalPos == nil then
		return deny("terlalu jauh")
	end
	if (hrp.Position - pedestalPos).Magnitude > Config.STEAL_RANGE then
		return deny("terlalu jauh")
	end

	-- Langkah 9: baca ulang UID TEPAT sebelum mutasi — masih string
	-- tidak kosong dan masih item yang sama dengan langkah 6.
	local itemAgain = victimState.Slots[slotIdx]
	if itemAgain == nil then
		return deny("slot kosong")
	end
	if type(itemAgain.Uid) ~= "string" or itemAgain.Uid == ""
		or itemAgain.Uid ~= item.Uid then
		return deny("item sudah tidak ada")
	end

	-- Mutasi (18.4), satu langkah sinkron: slot korban kosong, item
	-- pindah ke tangan pencuri, cooldown sukses mulai.
	victimState.Slots[slotIdx] = nil
	thiefState.Carried = item
	thiefState.LastStealAt = now

	local entry = Config.Roster[item.Kind]
	local name = item.Kind
	if entry ~= nil then
		name = entry.DisplayName
	end
	local message = "Berhasil mencuri " .. name .. "!"
	-- StealResult di-fire SETELAH mutasi selesai (18.2).
	fireStealResult(remotes, thief, true, message)
	return true, message, victim, item
end

return Steal
