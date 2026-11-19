-- Config.luau — Pasar Brainrot (roblox-brainrot-01, Stage 1)
-- SATU-SATUNYA sumber kebenaran untuk roster Brainrot, konstanta
-- gameplay, layout base, dan posisi dunia. Data murni, tanpa fungsi
-- ber-state. Spesifikasi: DESIGN.md bagian 13 dan 16.3.
-- Konstanta DataStore / steal / flood dideklarasikan di sini sejak awal,
-- tetapi TIDAK dipakai di Stage 1 (baru dipakai modul stage berikutnya).

local Config = {}

-- Roster Brainrot: 7 tingkat rarity.
-- Tiap entri: DisplayName, Price (harga beli), Income (per detik),
-- Sell (50% harga beli), Color (warna rarity), SpawnMax (batas atas
-- roll 1-1000; peluang kumulatif, lihat RollMax di bawah).
Config.Roster = {
	AyamIkan = {
		DisplayName = "Ayam Ikan",
		Rarity = "Common",
		Price = 50,
		Income = 5,
		Sell = 25,
		Color = Color3.fromRGB(220, 220, 220),
		RollMax = 450,
	},
	BabiTerbang = {
		DisplayName = "Babi Terbang",
		Rarity = "Uncommon",
		Price = 150,
		Income = 15,
		Sell = 75,
		Color = Color3.fromRGB(110, 220, 110),
		RollMax = 700,
	},
	AnjingEsTeh = {
		DisplayName = "Anjing Es Teh",
		Rarity = "Rare",
		Price = 400,
		Income = 40,
		Sell = 200,
		Color = Color3.fromRGB(65, 165, 255),
		RollMax = 880,
	},
	KucingRendang = {
		DisplayName = "Kucing Rendang",
		Rarity = "Epic",
		Price = 1000,
		Income = 100,
		Sell = 500,
		Color = Color3.fromRGB(185, 85, 255),
		RollMax = 960,
	},
	BeruangDurian = {
		DisplayName = "Beruang Durian",
		Rarity = "Legendary",
		Price = 3000,
		Income = 300,
		Sell = 1500,
		Color = Color3.fromRGB(255, 140, 40),
		RollMax = 988,
	},
	HarimauApi = {
		DisplayName = "Harimau Api",
		Rarity = "Mythic",
		Price = 12000,
		Income = 1200,
		Sell = 6000,
		Color = Color3.fromRGB(255, 65, 65),
		RollMax = 998,
	},
	GajahGamelan = {
		DisplayName = "Gajah Gamelan",
		Rarity = "Ultra Rare",
		Price = 50000,
		Income = 10000,
		Sell = 25000,
		Color = Color3.fromRGB(255, 225, 0),
		RollMax = 1000,
	},
}

-- Urutan roll spawn (1-1000): entri pertama yang RollMax-nya >= roll menang.
Config.RosterOrder = {
	"AyamIkan",
	"BabiTerbang",
	"AnjingEsTeh",
	"KucingRendang",
	"BeruangDurian",
	"HarimauApi",
	"GajahGamelan",
}

-- Ekonomi + progression
Config.START_MONEY = 200
Config.SELL_RATE = 0.5
Config.REBIRTH_BASE = 100000
Config.MAX_MONEY = 1000000000000 -- 1e12, batas sanity validasi load
Config.MAX_REBIRTHS = 100

-- Conveyor + spawn
Config.SPAWN_INTERVAL = 3.5
Config.CONVEYOR_SPEED = 16
Config.CONVEYOR_END_Z = 160 -- setengah panjang conveyor (320); batas ujung spawn/gerak/hapus
Config.CONVEYOR_LANES_X = { -7.5, 7.5 }

-- Lock base
Config.LOCK_DURATION = 30

-- Flood (Pasar Tumpah)
Config.FLOOD_FIRST = 120
Config.FLOOD_INTERVAL = 180
Config.WARNING_TIME = 10
Config.SCRAMBLE_TIME = 60
Config.CRATE_LIFETIME = 60

-- DataStore
Config.DATA_VERSION = 1
Config.DATASTORE_NAME = "PasarNusantara_V5"
Config.LOAD_MAX_ATTEMPTS = 3
Config.LOAD_RETRY_DELAY = 2
Config.SAVE_MAX_ATTEMPTS = 2

-- Steal + klaim peti
Config.STEAL_COOLDOWN = 5
Config.STEAL_ATTEMPT_COOLDOWN = 1
Config.STEAL_RANGE = 12
Config.CLAIM_RANGE = 12

-- Batas aman base saat flood (setengah ukuran lantai base 56 x 46)
Config.SAFE_HALF_X = 28
Config.SAFE_HALF_Z = 23

-- Jendela bersih pohon di depan base: pohon yang z-nya masuk
-- BASE_Z[row] ± TREE_CLEAR_HALF_Z tidak dibuat (berdiri di depan
-- pintu masuk base). Lebar 40 > setengah lantai (23) + jarak pandang,
-- sehingga yang tersisa hanya z = -150, 136, 149 per sisi.
Config.TREE_CLEAR_HALF_Z = 40

-- Pencahayaan malam (FIX ROUND 3, 20 Nov): area luar base diterangkan
-- tanpa menghilangkan nuansa pasar malam — Brightness naik 2 -> 2.8,
-- Ambient + OutdoorAmbient lebih terang, lampu jalan lebih kuat.
Config.LIGHT_BRIGHTNESS = 2.8
Config.LIGHT_AMBIENT = Color3.fromRGB(130, 110, 140)
Config.LIGHT_OUTDOOR_AMBIENT = Color3.fromRGB(100, 88, 115)
Config.LAMP_BRIGHTNESS = 2
Config.LAMP_RANGE = 26

-- Papan nama base (FIX ROUND 3, 20 Nov): papan 240x80 (dulu 320x110),
-- headshot 64x64 di kiri + nama di kanan, teks tetap TextSize 26
-- (TextScaled dimatikan agar nama tidak memenuhi seluruh papan).
Config.OWNER_BOARD_WIDTH = 240
Config.OWNER_BOARD_HEIGHT = 80
Config.OWNER_HEADSHOT_SIZE = 64
Config.OWNER_NAME_TEXT_SIZE = 26

-- Layout base: 8 base, 4 kiri (x = -68) + 4 kanan (x = +68).
Config.BASE_X = { -68, 68 }
Config.BASE_Z = { 90, 25, -40, -105 }
Config.BASE_COUNT = 8
Config.SLOT_OFFSETS_X = { -14, 0, 14 }
Config.SLOT_OFFSETS_Z = { -9, 9 }
Config.SLOT_COUNT = 6

-- Posisi dunia
Config.SPAWN_POS = Vector3.new(0, 0.8, 168)
Config.CONVEYOR_POS = Vector3.new(0, 0.3, 0)
Config.CONVEYOR_SIZE = Vector3.new(30, 0.5, 320)
Config.TERRAIN_SIZE = Vector3.new(340, 2, 420)
Config.PLAZA_POS = Vector3.new(0, 0.3, 155)
Config.PLAZA_SIZE = Vector3.new(110, 0.6, 55)

return Config
