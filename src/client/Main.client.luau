-- Main.client.luau — Pasar Brainrot (roblox-brainrot-01, Stage 5)
-- SATU-SATUNYA LocalScript client. Tugas: bangun seluruh UI dari kode
-- (MoneyPanel, CarryPanel, FloodBanner, toast, tombol Lock/Rebirth,
-- tombol Debug Flood, mute BGM), dengarkan FloodEvent + MoneyUpdate +
-- StealResult + Notify, atur ProximityPrompt lewat
-- ProximityPromptService (owner: Taruh/Jual; bukan owner: Curi Brainrot;
-- peti: Buka Peti), UIScale responsif, BGM Lo-fi Chill A + watchdog.
-- Client TIDAK PERNAH mengubah uang/state — hanya menampilkan dan
-- mengirim permintaan via RemoteEvent; server yang memvalidasi semuanya.
--
-- BATAS KEJUJURAN PELACAKAN LOKAL (baca sebelum menilai panel):
-- 1. CarryPanel: server TIDAK mengirim event "carried". Client hanya
--    tahu ia membawa Brainrot dari aksi/pesan yang ia terima sendiri:
--    StealResult sukses ("Berhasil mencuri <nama>!"), Notify klaim
--    ("Kamu mendapatkan <nama>!"). Tangan dianggap kosong lagi saat
--    Notify place ("... ditaruh di slot ...") atau rebirth berhasil.
--    Nama dipetakan balik ke Roster lewat DisplayName untuk rarity.
--    Saat fase Flooding, carried server bisa tersapu tanpa pesan ke
--    client — panel lalu menampilkan "tidak diketahui (banjir)",
--    bukan mengklaim tahu.
-- 2. Biaya rebirth: client TIDAK menerima jumlah Rebirths dari server.
--    Biaya tampil = REBIRTH_BASE x 2^Rebirths dengan hitungan LOKAL
--    (mulai 0, naik 1 tiap Notify "Rebirth berhasil"). Angka itu
--    INFORMATIF; server yang memvalidasi biaya sebenarnya dan
--    menolak bila uang kurang.
-- 3. Status lock: client hanya tahu dari Notify server ("Base
--    terkunci ...", "Base dibuka", "Lock base habis"). Tombol Lock
--    tidak mengubah label secara optimistis.
-- 4. Uang awal panel ($200) adalah START_MONEY dari Config; pemain
--    lama yang kembali akan melihat angka benar setelah MoneyUpdate
--    pertama (kurang dari ~1 detik, income tick server tiap detik).
-- Spesifikasi: DESIGN.md bagian 9 dan 13.

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ProximityPromptService = game:GetService("ProximityPromptService")
local SoundService = game:GetService("SoundService")

local LocalPlayer = Players.LocalPlayer

-- ---------------------------------------------------------------------------
-- State lokal (tampilan saja, BUKAN kebenaran server)
-- ---------------------------------------------------------------------------

local money = Config.START_MONEY
local incomePerSec = 0
local carriedKind = nil -- key Roster yang sedang dibawa, atau nil
local carriedName = nil -- DisplayName yang sedang dibawa, atau nil
local carriedUnknown = false -- true bila banjir mungkin menyapu bawaan
local locked = false -- status lock dari Notify server
local localRebirths = 0 -- hitungan lokal, informatif (lihat header)
local floodPhase = "Idle"
local floodRemaining = 0 -- sisa detik fase berjalan (dari FloodEvent)
local muted = false

local alive = true
local connections = {}

local function trackConnection(conn)
	table.insert(connections, conn)
	return conn
end

-- ---------------------------------------------------------------------------
-- Util
-- ---------------------------------------------------------------------------

-- Format uang gaya Indonesia: 1234567 -> "$1.234.567".
local function formatMoney(amount)
	local n = math.floor(amount or 0)
	if n < 0 then
		n = 0
	end
	local digits = tostring(n)
	local out = ""
	while #digits > 3 do
		out = "." .. string.sub(digits, -3) .. out
		digits = string.sub(digits, 1, #digits - 3)
	end
	return "$" .. digits .. out
end

-- Biaya rebirth menurut hitungan lokal (informatif; server memvalidasi).
local function rebirthCost()
	return Config.REBIRTH_BASE * (2 ^ localRebirths)
end

-- Cari key Roster dari DisplayName (untuk rarity panel bawaan).
local function findKindByDisplayName(displayName)
	for kind, entry in pairs(Config.Roster) do
		if entry.DisplayName == displayName then
			return kind
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- RemoteEvents (menunggu GameRemotes ada; pemain yang join saat
-- Remotes belum siap tetap terlayani karena WaitForChild).
-- ---------------------------------------------------------------------------

local remotesFolder = ReplicatedStorage:WaitForChild("GameRemotes", 30)
if remotesFolder == nil then
	warn("[Client] GameRemotes tidak ditemukan setelah 30 detik; UI tidak aktif.")
	return
end

local function waitRemote(name)
	local event = remotesFolder:WaitForChild(name, 30)
	if event == nil then
		warn("[Client] RemoteEvent hilang: " .. name)
	end
	return event
end

local Remotes = {
	FloodEvent = waitRemote("FloodEvent"),
	MoneyUpdate = waitRemote("MoneyUpdate"),
	StealResult = waitRemote("StealResult"),
	Notify = waitRemote("Notify"),
	StealRequest = waitRemote("StealRequest"),
	PlaceRequest = waitRemote("PlaceRequest"),
	SellRequest = waitRemote("SellRequest"),
	LockRequest = waitRemote("LockRequest"),
	RebirthRequest = waitRemote("RebirthRequest"),
	ClaimRequest = waitRemote("ClaimRequest"),
	DebugFlood = waitRemote("DebugFlood"),
}

for name, event in pairs(Remotes) do
	if event == nil then
		warn("[Client] RemoteEvent " .. name .. " tidak tersedia; UI tidak aktif.")
		return
	end
end

-- ---------------------------------------------------------------------------
-- UI (dibangun seluruhnya dari kode, tanpa plugin/asset UI luar)
-- ---------------------------------------------------------------------------

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "PasarBrainrotGui"
screenGui.ResetOnSpawn = false
screenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

local uiScale = Instance.new("UIScale")
uiScale.Parent = screenGui

-- UIScale responsif (DESIGN.md 9): skala =
-- clamp(min(lebar/1100, tinggi/700), 0,55, 1), update saat viewport berubah.
local function updateScale()
	local size = screenGui.AbsoluteSize
	local scale = math.min(size.X / 1100, size.Y / 700)
	if scale < 0.55 then
		scale = 0.55
	elseif scale > 1 then
		scale = 1
	end
	uiScale.Scale = scale
end
trackConnection(screenGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateScale))
updateScale()

local function makeFrame(parent, name, size, position, anchorPoint, color)
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.Size = size
	frame.Position = position
	frame.AnchorPoint = anchorPoint
	frame.BackgroundColor3 = color
	frame.BackgroundTransparency = 0.2
	frame.BorderSizePixel = 0
	frame.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = frame
	return frame
end

local function makeLabel(parent, name, size, position, text, textSize, color)
	local label = Instance.new("TextLabel")
	label.Name = name
	label.Size = size
	label.Position = position
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextSize = textSize
	label.TextColor3 = color
	label.Font = Enum.Font.GothamBold
	label.TextScaled = false
	label.TextWrapped = true
	label.Parent = parent
	return label
end

local function makeButton(parent, name, size, position, text, color)
	local button = Instance.new("TextButton")
	button.Name = name
	button.Size = size
	button.Position = position
	button.BackgroundColor3 = color
	button.Text = text
	button.TextSize = 18
	button.TextColor3 = Color3.fromRGB(255, 255, 255)
	button.Font = Enum.Font.GothamBold
	button.TextWrapped = true
	button.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = button
	return button
end

-- MoneyPanel bawah-tengah: uang besar + income/detik di bawahnya.
local moneyPanel = makeFrame(screenGui, "MoneyPanel",
	UDim2.fromOffset(320, 86), UDim2.new(0.5, 0, 1, -10),
	Vector2.new(0.5, 1), Color3.fromRGB(25, 25, 35))
local moneyLabel = makeLabel(moneyPanel, "MoneyLabel",
	UDim2.new(1, -16, 0, 48), UDim2.new(0, 8, 0, 4),
	formatMoney(money), 34, Color3.fromRGB(255, 225, 90))
moneyLabel.TextXAlignment = Enum.TextXAlignment.Center
local incomeLabel = makeLabel(moneyPanel, "IncomeLabel",
	UDim2.new(1, -16, 0, 26), UDim2.new(0, 8, 0, 52),
	"+$0/dtk", 18, Color3.fromRGB(140, 230, 140))
incomeLabel.TextXAlignment = Enum.TextXAlignment.Center

-- CarryPanel: di atas MoneyPanel, info Brainrot yang sedang dibawa.
local carryPanel = makeFrame(screenGui, "CarryPanel",
	UDim2.fromOffset(320, 40), UDim2.new(0.5, 0, 1, -104),
	Vector2.new(0.5, 1), Color3.fromRGB(25, 25, 35))
local carryLabel = makeLabel(carryPanel, "CarryLabel",
	UDim2.new(1, -16, 1, 0), UDim2.new(0, 8, 0, 0),
	"Tangan: kosong", 18, Color3.fromRGB(255, 255, 255))
carryLabel.TextXAlignment = Enum.TextXAlignment.Center

local function updateMoneyPanel()
	moneyLabel.Text = formatMoney(money)
	incomeLabel.Text = "+" .. formatMoney(incomePerSec) .. "/dtk"
end

local function updateCarryPanel()
	if carriedUnknown then
		carryLabel.Text = "Tangan: tidak diketahui (banjir)"
		carryLabel.TextColor3 = Color3.fromRGB(255, 200, 90)
	elseif carriedKind ~= nil and carriedName ~= nil then
		local entry = Config.Roster[carriedKind]
		local rarity = "?"
		if entry ~= nil then
			rarity = entry.Rarity
		end
		carryLabel.Text = "Bawa: " .. carriedName .. " (" .. rarity .. ")"
		carryLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	else
		carryLabel.Text = "Tangan: kosong"
		carryLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	end
end

-- FloodBanner atas-tengah (posisi y=8, ukuran 520x44, DESIGN.md 7/9).
-- Teks HUD tidak menutupi pojok kiri atas (tombol menu Roblox).
local floodBanner = makeFrame(screenGui, "FloodBanner",
	UDim2.fromOffset(520, 44), UDim2.new(0.5, 0, 0, 8),
	Vector2.new(0.5, 0), Color3.fromRGB(30, 60, 30))
local floodLabel = makeLabel(floodBanner, "FloodLabel",
	UDim2.new(1, -16, 1, 0), UDim2.new(0, 8, 0, 0),
	"Pasar tenang", 22, Color3.fromRGB(200, 255, 200))
floodLabel.TextXAlignment = Enum.TextXAlignment.Center

local function updateFloodBanner()
	if floodPhase == "Warning" then
		floodBanner.BackgroundColor3 = Color3.fromRGB(120, 50, 20)
		floodLabel.TextColor3 = Color3.fromRGB(255, 220, 150)
		floodLabel.Text = "BANJIR DATANG! " .. tostring(math.floor(floodRemaining)) .. " dtk"
	elseif floodPhase == "Flooding" then
		floodBanner.BackgroundColor3 = Color3.fromRGB(20, 60, 140)
		floodLabel.TextColor3 = Color3.fromRGB(180, 220, 255)
		floodLabel.Text = "BANJIR! Lari ke base!"
	elseif floodPhase == "Scramble" then
		floodBanner.BackgroundColor3 = Color3.fromRGB(80, 40, 120)
		floodLabel.TextColor3 = Color3.fromRGB(240, 210, 255)
		floodLabel.Text = "Pasar Tumpah! Peti bermunculan — " .. tostring(math.floor(floodRemaining)) .. " dtk"
	else
		floodBanner.BackgroundColor3 = Color3.fromRGB(30, 60, 30)
		floodLabel.TextColor3 = Color3.fromRGB(200, 255, 200)
		floodLabel.Text = "Pasar tenang"
	end
end

-- Toast/notifikasi: di bawah banner, menumpuk maksimal 3, hilang ~4 detik.
local toastContainer = Instance.new("Frame")
toastContainer.Name = "ToastContainer"
toastContainer.Size = UDim2.fromOffset(520, 120)
toastContainer.Position = UDim2.new(0.5, 0, 0, 60)
toastContainer.AnchorPoint = Vector2.new(0.5, 0)
toastContainer.BackgroundTransparency = 1
toastContainer.Parent = screenGui
local toastLayout = Instance.new("UIListLayout")
toastLayout.SortOrder = Enum.SortOrder.LayoutOrder
toastLayout.Padding = UDim.new(0, 4)
toastLayout.Parent = toastContainer

local function showToast(text, color)
	if text == nil or text == "" then
		return
	end
	-- Batasi 3 toast: hapus yang paling lama bila penuh.
	local children = toastContainer:GetChildren()
	local labels = {}
	for _, child in ipairs(children) do
		if child:IsA("TextLabel") then
			table.insert(labels, child)
		end
	end
	if #labels >= 3 then
		labels[1]:Destroy()
	end
	local toast = Instance.new("TextLabel")
	toast.Size = UDim2.fromOffset(520, 30)
	toast.BackgroundColor3 = Color3.fromRGB(25, 25, 35)
	toast.BackgroundTransparency = 0.2
	toast.Text = text
	toast.TextSize = 16
	toast.TextColor3 = color or Color3.fromRGB(255, 255, 255)
	toast.Font = Enum.Font.GothamBold
	toast.TextWrapped = true
	toast.Parent = toastContainer
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = toast
	task.delay(4, function()
		pcall(function()
			toast:Destroy()
		end)
	end)
end

-- Tombol aksi di sisi kanan tengah: Lock, Rebirth, Debug Flood.
local actionFrame = Instance.new("Frame")
actionFrame.Name = "ActionButtons"
actionFrame.Size = UDim2.fromOffset(180, 150)
actionFrame.Position = UDim2.new(1, -12, 0.5, -75)
actionFrame.AnchorPoint = Vector2.new(1, 0)
actionFrame.BackgroundTransparency = 1
actionFrame.Parent = screenGui
local actionLayout = Instance.new("UIListLayout")
actionLayout.SortOrder = Enum.SortOrder.LayoutOrder
actionLayout.Padding = UDim.new(0, 8)
actionLayout.Parent = actionFrame

local lockButton = makeButton(actionFrame, "LockButton",
	UDim2.fromOffset(180, 44), UDim2.new(0, 0, 0, 0),
	"Kunci Base", Color3.fromRGB(40, 90, 160))
local rebirthButton = makeButton(actionFrame, "RebirthButton",
	UDim2.fromOffset(180, 44), UDim2.new(0, 0, 0, 0),
	"Rebirth ($100.000)", Color3.fromRGB(140, 60, 160))
local debugButton = makeButton(actionFrame, "DebugFloodButton",
	UDim2.fromOffset(180, 30), UDim2.new(0, 0, 0, 0),
	"Debug Flood", Color3.fromRGB(90, 90, 90))
debugButton.TextSize = 15

-- Tombol mute kecil di pojok kanan atas (menu Roblox di kiri atas aman).
local muteButton = makeButton(screenGui, "MuteButton",
	UDim2.fromOffset(120, 36), UDim2.new(1, -12, 0, 8),
	"Suara: ON", Color3.fromRGB(60, 60, 70))
muteButton.AnchorPoint = Vector2.new(1, 0)
muteButton.TextSize = 15

local function updateLockButton()
	if locked then
		lockButton.Text = "Buka Base"
	else
		lockButton.Text = "Kunci Base"
	end
end

local function updateRebirthButton()
	rebirthButton.Text = "Rebirth (" .. formatMoney(rebirthCost()) .. ")"
end

-- Konfirmasi rebirth (biaya tampil dari hitungan lokal, informatif).
local confirmFrame = makeFrame(screenGui, "RebirthConfirm",
	UDim2.fromOffset(360, 170), UDim2.new(0.5, 0, 0.5, 0),
	Vector2.new(0.5, 0.5), Color3.fromRGB(30, 20, 40))
confirmFrame.Visible = false
local confirmLabel = makeLabel(confirmFrame, "ConfirmLabel",
	UDim2.new(1, -24, 0, 90), UDim2.new(0, 12, 0, 10),
	"", 18, Color3.fromRGB(255, 255, 255))
local confirmYes = makeButton(confirmFrame, "ConfirmYes",
	UDim2.fromOffset(150, 44), UDim2.new(0, 12, 1, -56),
	"Ya, Rebirth", Color3.fromRGB(160, 40, 40))
local confirmNo = makeButton(confirmFrame, "ConfirmNo",
	UDim2.fromOffset(150, 44), UDim2.new(1, -12, 1, -56),
	"Batal", Color3.fromRGB(70, 70, 80))
confirmNo.AnchorPoint = Vector2.new(1, 0)

local function showRebirthConfirm()
	local nextMult = 1 + (localRebirths + 1) * 0.5
	confirmLabel.Text = "Rebirth seharga " .. formatMoney(rebirthCost()) .. "?\n"
		.. "Uang direset ke $100, slot + bawaan dihapus,\n"
		.. "income jadi x" .. tostring(nextMult) .. "."
	confirmFrame.Visible = true
end

updateMoneyPanel()
updateCarryPanel()
updateFloodBanner()
updateLockButton()
updateRebirthButton()

-- ---------------------------------------------------------------------------
-- BGM: Lo-fi Chill A (asset 9043887091, DESIGN.md 9), loop + watchdog.
-- Suling Sunda TIDAK dipakai (bos belum menyediakan rekaman).
-- ---------------------------------------------------------------------------

local bgm = Instance.new("Sound")
bgm.Name = "PasarBrainrotBGM"
bgm.SoundId = "rbxassetid://9043887091"
bgm.Volume = 0.5
bgm.Looped = true
bgm.Parent = SoundService

local lastPlayingAt = os.clock()
local lastReplayAt = 0

local function startBgm()
	if muted then
		return
	end
	local ok, err = pcall(function()
		bgm:Play()
	end)
	if not ok then
		warn("[Client] BGM gagal diputar: " .. tostring(err))
	else
		lastPlayingAt = os.clock()
	end
end

startBgm()

trackConnection(muteButton.MouseButton1Click:Connect(function()
	muted = not muted
	if muted then
		pcall(function()
			bgm:Stop()
		end)
		muteButton.Text = "Suara: OFF"
	else
		muteButton.Text = "Suara: ON"
		startBgm()
	end
end))

-- ---------------------------------------------------------------------------
-- Pelacakan bawaan lokal (jujur — lihat header butir 1)
-- ---------------------------------------------------------------------------

local function noteCarried(displayName)
	local kind = findKindByDisplayName(displayName)
	carriedName = displayName
	carriedKind = kind -- nil bila nama tak dikenal; panel tetap tampilkan nama
	carriedUnknown = false
	updateCarryPanel()
end

local function clearCarried()
	carriedKind = nil
	carriedName = nil
	carriedUnknown = false
	updateCarryPanel()
end

-- ---------------------------------------------------------------------------
-- Listener server -> client
-- ---------------------------------------------------------------------------

trackConnection(Remotes.MoneyUpdate.OnClientEvent:Connect(function(newMoney, newIncome)
	if type(newMoney) == "number" then
		money = newMoney
	end
	if type(newIncome) == "number" then
		incomePerSec = newIncome
	end
	updateMoneyPanel()
end))

trackConnection(Remotes.FloodEvent.OnClientEvent:Connect(function(phase, remaining)
	if type(phase) == "string" then
		local wasFlooding = (floodPhase == "Flooding")
		floodPhase = phase
		if type(remaining) == "number" then
			floodRemaining = remaining
		else
			floodRemaining = 0
		end
		-- Bawaan di luar base bisa tersapu saat Flooding tanpa pesan
		-- server ke client — tandai tidak diketahui (lihat header).
		if phase == "Flooding" and not wasFlooding and carriedKind ~= nil then
			carriedUnknown = true
			updateCarryPanel()
		end
		updateFloodBanner()
	end
end))

trackConnection(Remotes.StealResult.OnClientEvent:Connect(function(success, message)
	if type(message) == "string" and message ~= "" then
		if success then
			showToast(message, Color3.fromRGB(140, 230, 140))
			-- "Berhasil mencuri <nama>!" -> tangan kini membawa <nama>.
			local stolenName = string.match(message, "^Berhasil mencuri (.+)!$")
			if stolenName ~= nil then
				noteCarried(stolenName)
			end
		else
			showToast(message, Color3.fromRGB(255, 150, 150))
		end
	end
end))

trackConnection(Remotes.Notify.OnClientEvent:Connect(function(text)
	if type(text) ~= "string" or text == "" then
		return
	end
	showToast(text)
	-- Klaim peti sukses: "Kamu mendapatkan <nama>!" -> tangan terisi.
	local claimedName = string.match(text, "^Kamu mendapatkan (.+)!$")
	if claimedName ~= nil then
		noteCarried(claimedName)
		return
	end
	-- Taruh sukses: "... ditaruh di slot ..." -> tangan kosong.
	if string.find(text, "ditaruh di slot") ~= nil then
		clearCarried()
		return
	end
	-- Rebirth sukses: tangan + slot dihapus, hitungan lokal naik.
	if string.find(text, "Rebirth berhasil") ~= nil then
		clearCarried()
		localRebirths = localRebirths + 1
		updateRebirthButton()
		return
	end
	-- Status lock hanya dari pesan server (lihat header butir 3).
	if string.find(text, "Base terkunci") ~= nil or string.find(text, "Lock diperpanjang") ~= nil then
		locked = true
		updateLockButton()
	elseif string.find(text, "Base dibuka") ~= nil or string.find(text, "Lock base habis") ~= nil then
		locked = false
		updateLockButton()
	end
end))

-- ---------------------------------------------------------------------------
-- ProximityPrompt (client): label dinamis + kirim permintaan ke server.
-- Client HANYA membaca atribut prompt (OwnerUserId/SlotFilled/BaseIdx/
-- SlotIdx/CrateId) yang dipelihara server; server memvalidasi semuanya.
-- Client TIDAK PERNAH mengirim UID apa pun.
-- ---------------------------------------------------------------------------

-- Label prompt per pemain saat prompt muncul (PromptShown):
-- pemilik + slot terisi -> "Jual"; pemilik + slot kosong -> "Taruh";
-- bukan pemilik + slot terisi -> "Curi Brainrot"; peti -> "Buka Peti".
trackConnection(ProximityPromptService.PromptShown:Connect(function(prompt, inputType)
	local crateId = prompt:GetAttribute("CrateId")
	if type(crateId) == "string" and crateId ~= "" then
		prompt.ActionText = "Buka Peti"
		return
	end
	if prompt:GetAttribute("PromptKind") ~= "Pedestal" then
		return
	end
	local baseIdx = prompt:GetAttribute("BaseIdx")
	local slotIdx = prompt:GetAttribute("SlotIdx")
	local ownerUserId = prompt:GetAttribute("OwnerUserId") or 0
	local filled = prompt:GetAttribute("SlotFilled") == true
	if ownerUserId == LocalPlayer.UserId then
		if filled then
			prompt.ActionText = "Jual"
		else
			prompt.ActionText = "Taruh"
		end
	else
		if filled then
			prompt.ActionText = "Curi Brainrot"
		else
			prompt.ActionText = "Kosong"
		end
	end
	if type(baseIdx) == "number" and type(slotIdx) == "number" then
		prompt.ObjectText = "Base " .. tostring(baseIdx) .. " — Slot " .. tostring(slotIdx)
	end
end))

trackConnection(ProximityPromptService.PromptTriggered:Connect(function(prompt, player)
	if player ~= LocalPlayer then
		return
	end
	-- Peti: atribut CrateId -> ClaimRequest(crateId).
	local crateId = prompt:GetAttribute("CrateId")
	if type(crateId) == "string" and crateId ~= "" then
		Remotes.ClaimRequest:FireServer(crateId)
		return
	end
	if prompt:GetAttribute("PromptKind") ~= "Pedestal" then
		return
	end
	local baseIdx = prompt:GetAttribute("BaseIdx")
	local slotIdx = prompt:GetAttribute("SlotIdx")
	if type(baseIdx) ~= "number" or type(slotIdx) ~= "number" then
		warn("[Client] Prompt pedestal tanpa BaseIdx/SlotIdx; permintaan tidak dikirim.")
		return
	end
	local ownerUserId = prompt:GetAttribute("OwnerUserId") or 0
	local filled = prompt:GetAttribute("SlotFilled") == true
	if ownerUserId == LocalPlayer.UserId then
		if filled then
			Remotes.SellRequest:FireServer(slotIdx)
		elseif carriedKind ~= nil then
			Remotes.PlaceRequest:FireServer(slotIdx)
		else
			showToast("Tangan kosong — tidak ada yang bisa ditaruh.")
		end
	elseif filled then
		Remotes.StealRequest:FireServer(baseIdx, slotIdx)
	end
	-- Bukan pemilik + slot kosong: tidak ada aksi (server juga menolak).
end))

-- ---------------------------------------------------------------------------
-- Tombol aksi -> RemoteEvent (server memvalidasi semuanya)
-- ---------------------------------------------------------------------------

trackConnection(lockButton.MouseButton1Click:Connect(function()
	Remotes.LockRequest:FireServer(not locked)
	-- Label berubah hanya saat Notify server tiba (lihat header butir 3).
end))

trackConnection(rebirthButton.MouseButton1Click:Connect(function()
	showRebirthConfirm()
end))

trackConnection(confirmYes.MouseButton1Click:Connect(function()
	confirmFrame.Visible = false
	Remotes.RebirthRequest:FireServer()
end))

trackConnection(confirmNo.MouseButton1Click:Connect(function()
	confirmFrame.Visible = false
end))

-- Tombol debug kecil (uji Studio bos): server menolak bila siklus
-- flood sudah berjalan — client hanya fire DebugFlood.
trackConnection(debugButton.MouseButton1Click:Connect(function()
	Remotes.DebugFlood:FireServer()
	showToast("Debug Flood dikirim (server memutuskan).")
end))

-- ---------------------------------------------------------------------------
-- Loop 1 detik: countdown banner lokal + watchdog BGM.
-- Satu loop, berhenti saat LocalScript dimatikan (alive = false).
-- ---------------------------------------------------------------------------

task.spawn(function()
	while alive do
		task.wait(1)
		if not alive then
			break
		end
		-- Countdown banner: jalan tiap detik selama Warning/Scramble;
		-- Idle tanpa countdown (banner tenang, tidak menutupi UI lain).
		local ok, err = pcall(function()
			if (floodPhase == "Warning" or floodPhase == "Scramble") and floodRemaining > 0 then
				floodRemaining = floodRemaining - 1
				updateFloodBanner()
			end
			-- Watchdog BGM: replay kalau berhenti >3 detik saat unmuted.
			if not muted then
				if bgm.IsPlaying then
					lastPlayingAt = os.clock()
				elseif os.clock() - lastPlayingAt > 3 and os.clock() - lastReplayAt > 3 then
					lastReplayAt = os.clock()
					bgm:Play()
				end
			end
		end)
		if not ok then
			warn("[Client] tick 1 detik gagal: " .. tostring(err))
		end
	end
end)

-- Bersihkan koneksi saat LocalScript dimatikan; jangan menelan error diam-diam.
trackConnection(script.Destroying:Connect(function()
	alive = false
	for _, conn in ipairs(connections) do
		pcall(function()
			conn:Disconnect()
		end)
	end
	pcall(function()
		bgm:Stop()
	end)
end))
