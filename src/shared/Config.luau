-- Config.luau — Pasar Brainrot (roblox-brainrot-01, Stage 1)
-- SATU-SATUNYA sumber kebenaran untuk roster Brainrot, konstanta
-- gameplay, layout base, dan posisi dunia. Data murni, tanpa fungsi
-- ber-state. Spesifikasi: DESIGN.md bagian 13 dan 16.3.
-- Konstanta DataStore / steal / flood dideklarasikan di sini sejak awal,
-- tetapi TIDAK dipakai di Stage 1 (baru dipakai modul stage berikutnya).

local Config = {}

-- Roster Brainrot: 35 jenis — 7 tingkat rarity x 5 jenis per tier
-- (FITUR INDEX, 20 Nov, perintah bos "3 setiap rank" lalu diubah
-- "5 setiap rank"). FIX ROUND 7 (20 Nov, foto referensi): roster
-- jadi HIBRIDA BINATANG + SAYURAN — key + DisplayName berubah,
-- harga/income/rarity/warna TETAP. Key lama dipetakan ke baru saat
-- load (DataStore LEGACY_KIND_MAP), bukan dihapus diam-diam.
-- 7 kind lama TETAP (key, harga, income, rarity, warna tidak
-- berubah); 28 kind baru hibrida binatang + sayuran gaya Nusantara.
-- Harga baru diinterpolasi di dalam tier-nya (bertahap, tidak
-- tabrakan); income = harga/10 (Common–Mythic) dan harga/5
-- (Ultra Rare, mengikuti Gajah Kol); Sell = 50% harga.
-- Warna badan = warna rarity (perintah bos "warna sesuai rank
-- aja deh"): semua kind satu tier satu warna badan — rarity
-- langsung kebaca dari warna badan, bukan dari warna hewan.
-- Tiap entri: DisplayName, Price (harga beli), Income (per detik),
-- Sell (50% harga beli), Color (warna rarity), RollMax (batas atas
-- roll 1-1000; peluang kumulatif, lihat RollMax di bawah).
Config.Roster = {
	-- Common (total 30%): 5 x 6% — RollMax 60/120/180/240/300.
	BebekBayam = {
		DisplayName = "Bebek Bayam",
		Rarity = "Common",
		Price = 40,
		Income = 4,
		Sell = 20,
		Color = Color3.fromRGB(0, 200, 230),
		RollMax = 60,
	},
	AyamWortel = {
		DisplayName = "Ayam Wortel",
		Rarity = "Common",
		Price = 50,
		Income = 5,
		Sell = 25,
		Color = Color3.fromRGB(0, 200, 230),
		RollMax = 120,
	},
	KambingSawi = {
		DisplayName = "Kambing Sawi",
		Rarity = "Common",
		Price = 60,
		Income = 6,
		Sell = 30,
		Color = Color3.fromRGB(0, 200, 230),
		RollMax = 180,
	},
	KelinciSeledri = {
		DisplayName = "Kelinci Seledri",
		Rarity = "Common",
		Price = 80,
		Income = 8,
		Sell = 40,
		Color = Color3.fromRGB(0, 200, 230),
		RollMax = 240,
	},
	ItikJagung = {
		DisplayName = "Itik Jagung",
		Rarity = "Common",
		Price = 90,
		Income = 9,
		Sell = 45,
		Color = Color3.fromRGB(0, 200, 230),
		RollMax = 300,
	},
	-- Uncommon (total 25%): 5 x 5% — RollMax 350/400/450/500/550.
	MonyetPisang = {
		DisplayName = "Monyet Pisang",
		Rarity = "Uncommon",
		Price = 120,
		Income = 12,
		Sell = 60,
		Color = Color3.fromRGB(110, 220, 110),
		RollMax = 350,
	},
	BabiLabu = {
		DisplayName = "Babi Labu",
		Rarity = "Uncommon",
		Price = 150,
		Income = 15,
		Sell = 75,
		Color = Color3.fromRGB(110, 220, 110),
		RollMax = 400,
	},
	SapiJagung = {
		DisplayName = "Sapi Jagung",
		Rarity = "Uncommon",
		Price = 170,
		Income = 17,
		Sell = 85,
		Color = Color3.fromRGB(110, 220, 110),
		RollMax = 450,
	},
	KudaKentang = {
		DisplayName = "Kuda Kentang",
		Rarity = "Uncommon",
		Price = 190,
		Income = 19,
		Sell = 95,
		Color = Color3.fromRGB(110, 220, 110),
		RollMax = 500,
	},
	DombaTimun = {
		DisplayName = "Domba Timun",
		Rarity = "Uncommon",
		Price = 210,
		Income = 21,
		Sell = 105,
		Color = Color3.fromRGB(110, 220, 110),
		RollMax = 550,
	},
	-- Rare (total 20%): 5 x 4% — RollMax 590/630/670/710/750.
	TupaiKacang = {
		DisplayName = "Tupai Kacang",
		Rarity = "Rare",
		Price = 340,
		Income = 34,
		Sell = 170,
		Color = Color3.fromRGB(65, 165, 255),
		RollMax = 590,
	},
	LandakPaprika = {
		DisplayName = "Landak Paprika",
		Rarity = "Rare",
		Price = 370,
		Income = 37,
		Sell = 185,
		Color = Color3.fromRGB(65, 165, 255),
		RollMax = 630,
	},
	AnjingBrokoli = {
		DisplayName = "Anjing Brokoli",
		Rarity = "Rare",
		Price = 400,
		Income = 40,
		Sell = 200,
		Color = Color3.fromRGB(65, 165, 255),
		RollMax = 670,
	},
	RubahUbi = {
		DisplayName = "Rubah Ubi",
		Rarity = "Rare",
		Price = 430,
		Income = 43,
		Sell = 215,
		Color = Color3.fromRGB(65, 165, 255),
		RollMax = 710,
	},
	MusangSawi = {
		DisplayName = "Musang Sawi",
		Rarity = "Rare",
		Price = 470,
		Income = 47,
		Sell = 235,
		Color = Color3.fromRGB(65, 165, 255),
		RollMax = 750,
	},
	-- Epic (total 12%): 5 x 2.4% — RollMax 774/798/822/846/870.
	BurungPaprika = {
		DisplayName = "Burung Paprika",
		Rarity = "Epic",
		Price = 850,
		Income = 85,
		Sell = 425,
		Color = Color3.fromRGB(185, 85, 255),
		RollMax = 774,
	},
	PandaUbi = {
		DisplayName = "Panda Ubi",
		Rarity = "Epic",
		Price = 920,
		Income = 92,
		Sell = 460,
		Color = Color3.fromRGB(185, 85, 255),
		RollMax = 798,
	},
	KucingCabai = {
		DisplayName = "Kucing Cabai",
		Rarity = "Epic",
		Price = 1000,
		Income = 100,
		Sell = 500,
		Color = Color3.fromRGB(185, 85, 255),
		RollMax = 822,
	},
	ElangBawang = {
		DisplayName = "Elang Bawang",
		Rarity = "Epic",
		Price = 1100,
		Income = 110,
		Sell = 550,
		Color = Color3.fromRGB(185, 85, 255),
		RollMax = 846,
	},
	KoalaSingkong = {
		DisplayName = "Koala Singkong",
		Rarity = "Epic",
		Price = 1250,
		Income = 125,
		Sell = 625,
		Color = Color3.fromRGB(185, 85, 255),
		RollMax = 870,
	},
	-- Legendary (total 7%): 5 x 1.4% — RollMax 884/898/912/926/940.
	SingaJahe = {
		DisplayName = "Singa Jahe",
		Rarity = "Legendary",
		Price = 2500,
		Income = 250,
		Sell = 1250,
		Color = Color3.fromRGB(255, 140, 40),
		RollMax = 884,
	},
	BadakKunyit = {
		DisplayName = "Badak Kunyit",
		Rarity = "Legendary",
		Price = 2800,
		Income = 280,
		Sell = 1400,
		Color = Color3.fromRGB(255, 140, 40),
		RollMax = 898,
	},
	BeruangTerong = {
		DisplayName = "Beruang Terong",
		Rarity = "Legendary",
		Price = 3000,
		Income = 300,
		Sell = 1500,
		Color = Color3.fromRGB(255, 140, 40),
		RollMax = 912,
	},
	MacanSelada = {
		DisplayName = "Macan Selada",
		Rarity = "Legendary",
		Price = 3300,
		Income = 330,
		Sell = 1650,
		Color = Color3.fromRGB(255, 140, 40),
		RollMax = 926,
	},
	BantengPare = {
		DisplayName = "Banteng Pare",
		Rarity = "Legendary",
		Price = 3700,
		Income = 370,
		Sell = 1850,
		Color = Color3.fromRGB(255, 140, 40),
		RollMax = 940,
	},
	-- Mythic (total 4%): 5 x 0.8% — RollMax 948/956/964/972/980.
	NagaSelada = {
		DisplayName = "Naga Selada",
		Rarity = "Mythic",
		Price = 10000,
		Income = 1000,
		Sell = 5000,
		Color = Color3.fromRGB(255, 65, 65),
		RollMax = 948,
	},
	GarudaBawang = {
		DisplayName = "Garuda Bawang",
		Rarity = "Mythic",
		Price = 11000,
		Income = 1100,
		Sell = 5500,
		Color = Color3.fromRGB(255, 65, 65),
		RollMax = 956,
	},
	HarimauTomat = {
		DisplayName = "Harimau Tomat",
		Rarity = "Mythic",
		Price = 12000,
		Income = 1200,
		Sell = 6000,
		Color = Color3.fromRGB(255, 65, 65),
		RollMax = 964,
	},
	PhoenixKunyit = {
		DisplayName = "Phoenix Kunyit",
		Rarity = "Mythic",
		Price = 14000,
		Income = 1400,
		Sell = 7000,
		Color = Color3.fromRGB(255, 65, 65),
		RollMax = 972,
	},
	KirinDurian = {
		DisplayName = "Kirin Durian",
		Rarity = "Mythic",
		Price = 16000,
		Income = 1600,
		Sell = 8000,
		Color = Color3.fromRGB(255, 65, 65),
		RollMax = 980,
	},
	-- Ultra Rare (total 2%): 5 x 0.4% — RollMax 984/988/992/996/1000.
	KomodoSingkong = {
		DisplayName = "Komodo Singkong",
		Rarity = "Ultra Rare",
		Price = 40000,
		Income = 8000,
		Sell = 20000,
		Color = Color3.fromRGB(255, 225, 0),
		RollMax = 984,
	},
	PausUbi = {
		DisplayName = "Paus Ubi",
		Rarity = "Ultra Rare",
		Price = 45000,
		Income = 9000,
		Sell = 22500,
		Color = Color3.fromRGB(255, 225, 0),
		RollMax = 988,
	},
	GajahKol = {
		DisplayName = "Gajah Kol",
		Rarity = "Ultra Rare",
		Price = 50000,
		Income = 10000,
		Sell = 25000,
		Color = Color3.fromRGB(255, 225, 0),
		RollMax = 992,
	},
	OrangutanDurian = {
		DisplayName = "Orangutan Durian",
		Rarity = "Ultra Rare",
		Price = 65000,
		Income = 13000,
		Sell = 32500,
		Color = Color3.fromRGB(255, 225, 0),
		RollMax = 996,
	},
	CendrawasihDurian = {
		DisplayName = "Cendrawasih Durian",
		Rarity = "Ultra Rare",
		Price = 80000,
		Income = 16000,
		Sell = 40000,
		Color = Color3.fromRGB(255, 225, 0),
		RollMax = 1000,
	},
}

-- Urutan roll spawn (1-1000): entri pertama yang RollMax-nya >= roll menang.
-- FIX ROUND 7: peluang tier — Common 30%, Uncommon 25%, Rare 20%,
-- Epic 12%, Legendary 7%, Mythic 4%, Ultra Rare 2% (dulu 45/25/18/
-- 8/2.8/1/0.2 — conveyor kebanyakan Common). FITUR INDEX (20 Nov):
-- tiap tier dibagi RATA ke 5 kind-nya (Common 6% per kind, dst),
-- TOTAL tiap tier TIDAK berubah. Harga/income, interval
-- spawn 3.5 detik, kecepatan conveyor 16, dan aturan flood/peti
-- TIDAK berubah.
Config.RosterOrder = {
	"BebekBayam",
	"AyamWortel",
	"KambingSawi",
	"KelinciSeledri",
	"ItikJagung",
	"MonyetPisang",
	"BabiLabu",
	"SapiJagung",
	"KudaKentang",
	"DombaTimun",
	"TupaiKacang",
	"LandakPaprika",
	"AnjingBrokoli",
	"RubahUbi",
	"MusangSawi",
	"BurungPaprika",
	"PandaUbi",
	"KucingCabai",
	"ElangBawang",
	"KoalaSingkong",
	"SingaJahe",
	"BadakKunyit",
	"BeruangTerong",
	"MacanSelada",
	"BantengPare",
	"NagaSelada",
	"GarudaBawang",
	"HarimauTomat",
	"PhoenixKunyit",
	"KirinDurian",
	"KomodoSingkong",
	"PausUbi",
	"GajahKol",
	"OrangutanDurian",
	"CendrawasihDurian",
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
-- FIX ROUND 6 (20 Nov): CLAIM_RANGE 12 -> 20. Peti banjir susah
-- dibuka: kotaknya kecil (3x2x3) di permukaan tanah dan prompt
-- "Buka Peti" hanya muncul dalam 12 stud, jadi pemain harus
-- merapat betul-betul ke peti yang kecil itu. 20 stud = prompt
-- muncul + validasi server Flood.claimCrate lolos dari jarak
-- wajar; keduanya membaca konstanta ini, jadi prompt dan server
-- tetap konsisten. STEAL_RANGE (curi, 12) dan TAKE_RANGE (ambil
-- conveyor, 24) TIDAK berubah.
Config.CLAIM_RANGE = 20

-- Ambil Brainrot dari conveyor (FIX ROUND 5, 20 Nov): jangkauan ambil
-- khusus 24 stud (lebih jauh dari STEAL_RANGE 12) agar kedua jalur
-- conveyor (x = ±7.5) terjangkau dari kedua sisi conveyor. STEAL_RANGE
-- (curi dari pedestal) TIDAK berubah; CLAIM_RANGE naik 12 -> 20 di
-- FIX ROUND 6 (lihat di atas).
Config.TAKE_RANGE = 24

-- Dinding pembatas tepi map (FIX ROUND 6, 20 Nov): pemain bisa jalan
-- sampai ujung terrain dan jatuh. 4 dinding transparan (Transparency 1,
-- CanCollide true) di garis depan hutan — x = ±158 (garis depan hutan
-- barat/timur), z = ±196 (garis depan hutan utara/selatan) — jadi
-- pemain mentok sebelum mencapai tepi terrain (x ±170, z ±210).
-- Tinggi 20 stud: lompat pemain ~7 stud, tidak bisa dilompati.
-- Di dalam dinding: conveyor (z ±160), base (x ±96), plaza
-- (z 127.5-182.5), kios (z ±188), dan semua spawn peti — tidak ada
-- yang terhalangi. Dinding air flood bergerak di dalam area ini
-- (z -160..160) dan tidak bersentuhan dengan dinding pembatas.
Config.BOUNDARY_WALL_HALF_X = 158
Config.BOUNDARY_WALL_HALF_Z = 196
Config.BOUNDARY_WALL_HEIGHT = 20
Config.BOUNDARY_WALL_THICKNESS = 1

-- Skala visual Brainrot (FIX ROUND 5, 20 Nov): +30% dari sebelumnya
-- (conveyor/pedestal 2.0 -> 2.6, dibawa 1.4 -> 1.8, atas peti 1.6 -> 2.1).
Config.BRAINROT_SCALE_CONVEYOR = 2.6
Config.BRAINROT_SCALE_CARRIED = 1.8
Config.BRAINROT_SCALE_CRATE = 2.1

-- Label nama Brainrot (FIX ROUND 5, 20 Nov): TextScaled dimatikan,
-- TextSize tetap 16 (dulu teks memenuhi label 180x64).
Config.BRAINROT_LABEL_WIDTH = 160
Config.BRAINROT_LABEL_HEIGHT = 44
Config.BRAINROT_LABEL_TEXT_SIZE = 16

-- Batas aman base saat flood (setengah ukuran lantai base 56 x 46)
Config.SAFE_HALF_X = 28
Config.SAFE_HALF_Z = 23

-- Jendela bersih pohon di depan base: pohon yang z-nya masuk
-- BASE_Z[row] ± TREE_CLEAR_HALF_Z tidak dibuat (berdiri di depan
-- pintu masuk base). Lebar 40 > setengah lantai (23) + jarak pandang,
-- sehingga yang tersisa hanya z = -150, 136, 149 per sisi.
Config.TREE_CLEAR_HALF_Z = 40

-- Pencahayaan SENJA (FIX ROUND 8, 20 Nov): langit HARUS jingga-pink
-- beneran, bukan biru siang. Round 7 gagal: ClockTime 17.2 di Roblox
-- masih sore — langit default tetap biru. Perbaikan: ClockTime 18.1
-- (matahari di ufuk, langit default Roblox sudah jingga di horizon)
-- + Atmosphere senja (Haze + Color jingga dekat matahari, Decay pink
-- menjauhi matahari, Glare) yang mewarnai kabut langit jadi
-- jingga-pink seperti foto image-37.png. Density RENDAH (0.3, contoh
-- docs max ~0.35) supaya hutan tepi tetap siluet, bukan kabut tebal.
-- Scene TETAP TERANG: Brightness 3 + Ambient/OutdoorAmbient hangat-
-- terang dipertahankan; lampu jalan + lampion tetap nyala.
Config.LIGHT_CLOCK_TIME = 18.1
Config.LIGHT_BRIGHTNESS = 3
Config.LIGHT_AMBIENT = Color3.fromRGB(205, 165, 140)
Config.LIGHT_OUTDOOR_AMBIENT = Color3.fromRGB(215, 155, 120)
Config.LIGHT_ATMOSPHERE_DENSITY = 0.3
Config.LIGHT_ATMOSPHERE_OFFSET = 0.25
Config.LIGHT_ATMOSPHERE_COLOR = Color3.fromRGB(255, 165, 110)
Config.LIGHT_ATMOSPHERE_DECAY = Color3.fromRGB(235, 120, 140)
Config.LIGHT_ATMOSPHERE_GLARE = 0.6
Config.LIGHT_ATMOSPHERE_HAZE = 2.5
Config.LAMP_BRIGHTNESS = 2
Config.LAMP_RANGE = 26

-- Aura rarity Brainrot (FIX ROUND 7): glow lembut warna rarity
-- di createBrainrotModel (satu tempat: conveyor, pedestal,
-- dibawa, peti). Bola Neon sangat transparan + PointLight.
Config.BRAINROT_AURA_TRANSPARENCY = 0.88
Config.BRAINROT_AURA_RANGE = 8
Config.BRAINROT_AURA_BRIGHTNESS = 1

-- Gerobak jualan depan base (FIX ROUND 7, foto image-37.png):
-- 1 gerobak BESAR per base, di samping jalan masuk (z = zCenter
-- ± CART_Z_OFFSET, sisi berselang-seling ganjil/genap), x =
-- depan base + CART_X_FROM_FRONT ke arah conveyor — DI LUAR
-- jalur conveyor (x = ±7.5), DI LUAR kaca lock depan
-- (xCenter ± 28), dan TIDAK menutup pintu base (pintu di zCenter,
-- gerobak 20 stud ke samping). Tulisan bergiliran 1-2-3-1-2-3-1-2
-- untuk base 1..8. Dekorasi SAJA (tanpa interaksi/remote/ekonomi).
Config.CART_X_FROM_FRONT = 5
Config.CART_Z_OFFSET = 20
Config.CART_SIGN_TEXTS = { "JUAL CILOK", "JUAL BATAGOR", "JUAL BASO" }
Config.CART_SIGN_TEXT_SIZE = 26
-- Papan tulisan gerobak MENEMPEL (FIX ROUND 8, 20 Nov): papan fisik
-- tipis di sisi depan counter (menghadap jalan/conveyor), BUKAN
-- BillboardGui melayang di atas kanopi. Ukuran papan 0.15 (tebal) x
-- 1.6 (tinggi) x 3.2 (lebar, sepanjang counter 3.5), tengah papan
-- setinggi tengah counter (y = 1.1), menempel di muka counter
-- (offset 2.25 setengah lebar counter + 0.075 setengah tebal papan).
-- SurfaceGui PixelsPerStud 100 supaya "JUAL BATAGOR" (teks terpanjang)
-- muat di papan 3.2 stud.
Config.CART_SIGN_BOARD_THICKNESS = 0.15
Config.CART_SIGN_BOARD_HEIGHT = 1.6
Config.CART_SIGN_BOARD_WIDTH = 3.2
Config.CART_SIGN_BOARD_Y = 1.1
Config.CART_SIGN_PIXELS_PER_STUD = 100

-- Meja pameran di sebelah spawn (FIX ROUND 8, 20 Nov; FITUR INDEX
-- 20 Nov: 35 kind, RAPI + BERHIASAN — perintah bos "jangan lumpuk",
-- "kasi hiasan apa kek"): satu meja BESAR di TIMUR spawn (pusat
-- x = 32, z = 162 — 6 stud di utara spawn, masih sejajar), memajang
-- KE-35 jenis Brainrot (RosterOrder) dalam 7 baris x 5 kolom —
-- SATU TIER SATU BARIS (baris 1 = 5 Common, baris 2 = 5 Uncommon,
-- dst) dengan jarak lega (kolom 7 stud, baris 6 stud) supaya tiap
-- Brainrot kelihatan utuh dari arah spawn (barat). Dekorasi: piringan
-- warna rarity di bawah tiap model, trim emas di pinggir meja, label
-- nama tier di ujung barat tiap baris, papan "PAMERAN BRAINROT",
-- 4 tiang lampion di sudut + 2 tanaman pot di sisi barat. SEMUA
-- hiasan dekorasi saja (CanCollide false, 0 prompt). Model statis
-- (anchored, createBrainrotModel yang sama), TANPA ProximityPrompt,
-- TANPA RemoteEvent, TIDAK masuk ekonomi/conveyor/pedestal/peti.
-- Meja TIDAK menutup jalur: jalan keluar spawn ke utara (x ~0,
-- z 168 -> 127) bebas; pemain ke base jalan dulu ke utara (z < 140)
-- baru belok timur/barat, meja di z 140..184 tidak dilewati. Meja
-- 44 stud lebar (x 10..54, masih di atas plaza x ±55) dan 44 stud
-- dalam (z 140..184); ujung selatan meja (z > 182.5) melewati tepi
-- plaza ke atas terrain (y = 0) — kaki meja dibuat dari y = 0
-- (bukan dari plaza y = 0.6) supaya tetap napak. Kios selatan di
-- (35, 188) berjarak 2.5 stud dari tepi meja (z 184) — tidak
-- bersentuhan. Plaza y = 0.6; alas atas tengah y = 2.75 (tebal 0.5)
-- — permukaan pajang y = 3.0, model berdiri di atas piringan
-- (y = 3.2).
Config.EXHIBITION_TABLE_CENTER_X = 32
Config.EXHIBITION_TABLE_CENTER_Z = 162
Config.EXHIBITION_TABLE_TOP_SIZE = Vector3.new(44, 0.5, 44)
Config.EXHIBITION_TABLE_TOP_Y = 2.75
Config.EXHIBITION_TABLE_LEG_HEIGHT = 2.5
Config.EXHIBITION_MODEL_SCALE = 2.0
Config.EXHIBITION_SPACING_X = 7
Config.EXHIBITION_COLS = 5
Config.EXHIBITION_ROW_SPACING_Z = 6
Config.EXHIBITION_DISC_DIAMETER = 5
Config.EXHIBITION_DISC_HEIGHT = 0.2
Config.EXHIBITION_SIGN_TEXT = "PAMERAN BRAINROT"
Config.EXHIBITION_SIGN_TEXT_SIZE = 28

-- Kabel lampion (FIX ROUND 7, foto image-37.png): kabel tipis di
-- atas tiap rentang lampion sisi jalan (y = LANTERN_CABLE_Y,
-- sedikit di atas lampion tertinggi) + kabel melintang di atas
-- conveyor (y = CROSS_CABLE_Y, di atas Brainrot + labelnya)
-- dengan lampion gantung kecil. Deterministik (aritmetika).
Config.LANTERN_CABLE_Y = 7.35
Config.CROSS_CABLE_Y = 9.5

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
