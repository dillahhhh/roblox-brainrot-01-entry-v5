-- Economy.luau — Pasar Brainrot (roblox-brainrot-01, Stage 2)
-- Logika ekonomi server-authoritative: income per detik, taruh/jual
-- Brainrot, dan rebirth. Modul murni logika + state suntikan
-- (DESIGN.md 16.2/16.3): hanya require Config, tanpa state sendiri,
-- tanpa Instance, tanpa loop, tanpa akses layanan DataStore, tanpa yield
-- di dalam operasi atomik.

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)

local Economy = {}

-- Load gating (DESIGN.md 16.5): hanya "ok"/"new" boleh aksi gameplay.
local function isLoadReady(state)
	return state ~= nil and (state.LoadStatus == "ok" or state.LoadStatus == "new")
end

-- Total income/detik pemain: jumlah income semua slot terisi x IncomeMult.
local function incomePerSec(state)
	local total = 0
	for i = 1, Config.SLOT_COUNT do
		local item = state.Slots[i]
		if item ~= nil then
			local entry = Config.Roster[item.Kind]
			if entry ~= nil then
				total = total + entry.Income
			end
		end
	end
	return total * state.IncomeMult
end

local function fireMoneyUpdate(remotes, player, state)
	local event = remotes and remotes.MoneyUpdate
	if event ~= nil then
		event:FireClient(player, state.Money, incomePerSec(state))
	end
end

-- Tambah income tiap pemain yang LoadStatus-nya "ok"/"new"; pemain
-- "loading"/"failed"/"corrupt" dilewati. Kirim MoneyUpdate tiap tick.
function Economy.addIncome(players, remotes)
	for player, state in pairs(players) do
		if isLoadReady(state) then
			local income = incomePerSec(state)
			if income > 0 then
				state.Money = state.Money + income
			end
			fireMoneyUpdate(remotes, player, state)
		end
	end
end

-- Pindahkan Carried pemain ke Slots[slotIdx] miliknya.
function Economy.placeItem(players, player, slotIdx, remotes)
	local state = players[player]
	if not isLoadReady(state) then
		return false, "Data sedang dimuat, tunggu sebentar."
	end
	if state.Base == nil then
		return false, "Kamu belum punya base."
	end
	if type(slotIdx) ~= "number" or slotIdx ~= math.floor(slotIdx)
		or slotIdx < 1 or slotIdx > Config.SLOT_COUNT then
		return false, "Slot tidak valid."
	end
	if state.Slots[slotIdx] ~= nil then
		return false, "Slot sudah terisi."
	end
	if state.Carried == nil then
		return false, "Kamu tidak sedang membawa Brainrot."
	end
	local item = state.Carried
	state.Carried = nil
	state.Slots[slotIdx] = item
	local entry = Config.Roster[item.Kind]
	local name = item.Kind
	if entry ~= nil then
		name = entry.DisplayName
	end
	return true, "Brainrot " .. name .. " ditaruh di slot " .. tostring(slotIdx) .. "."
end

-- Jual isi slot: 50% harga beli roster (SELL_RATE).
function Economy.sellSlot(players, player, slotIdx, remotes)
	local state = players[player]
	if not isLoadReady(state) then
		return false, "Data sedang dimuat, tunggu sebentar."
	end
	if state.Base == nil then
		return false, "Kamu belum punya base."
	end
	if type(slotIdx) ~= "number" or slotIdx ~= math.floor(slotIdx)
		or slotIdx < 1 or slotIdx > Config.SLOT_COUNT then
		return false, "Slot tidak valid."
	end
	local item = state.Slots[slotIdx]
	if item == nil then
		return false, "Slot kosong."
	end
	local entry = Config.Roster[item.Kind]
	if entry == nil then
		return false, "Brainrot tidak dikenal."
	end
	local price = entry.Price * Config.SELL_RATE
	state.Slots[slotIdx] = nil
	state.Money = state.Money + price
	fireMoneyUpdate(remotes, player, state)
	return true, "Terjual " .. entry.DisplayName .. " seharga $" .. tostring(price) .. "."
end

-- Rebirth: biaya 100000 x 2^Rebirths. Sukses: uang direset ke $100,
-- semua slot + Carried dihapus, Rebirths + 1,
-- IncomeMult = 1 + Rebirths x 0,5.
function Economy.rebirth(players, player, remotes)
	local state = players[player]
	if not isLoadReady(state) then
		return false, "Data sedang dimuat, tunggu sebentar."
	end
	local cost = Config.REBIRTH_BASE * (2 ^ state.Rebirths)
	if state.Money < cost then
		return false, "Rebirth butuh $" .. tostring(cost) .. "."
	end
	state.Money = 100
	for i = 1, Config.SLOT_COUNT do
		state.Slots[i] = nil
	end
	state.Carried = nil
	state.Rebirths = state.Rebirths + 1
	state.IncomeMult = 1 + state.Rebirths * 0.5
	fireMoneyUpdate(remotes, player, state)
	return true, "Rebirth berhasil! Income sekarang x" .. tostring(state.IncomeMult) .. "."
end

return Economy
