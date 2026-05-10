-- init.server.luau
-- Server boot sequence — initializes all server systems
--
-- Boot order (must match PlayerManager → NetworkHandler → WirePlayerEvents
-- for correct data loading before isNewPlayer checks):
--   1. WorldService.Init()         — generates START world
--   2. LockService, BlockService, DropService — core gameplay systems
--   3. Inventory, Gem, Data        — persistence & economy layer
--   4. StoreService.Init()         — in-game catalog
--   5. SpliceService, SeedService  — growth & splice systems
--   6. DataService.WirePlayerEvents() — loads data on join (BEFORE PlayerManager)
--   7. PlayerManager.Init()        — wires PlayerAdded/PlayerRemoving
--   8. NetworkHandler.Init()      — wires all client→server events
--   9. WorldRegistry.Init()        — cross-server world tracking & heartbeat
--  10. SeedService.StartGrowthLoop() — background growth (every 10s)
--  11. DataService.StartAutoSave()    — background auto-save (every 60s)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local Workspace = game:GetService("Workspace")

-- 2D tile-based Growtopia-style services
local WorldService = require(script.WorldService)
local LockService = require(script.LockService)
local BlockService = require(script.BlockService)
local SpliceService = require(script.SpliceService)
local SeedService = require(script.SeedService)
local InventoryService = require(script.InventoryService)
local GemService = require(script.GemService)
local DataService = require(script.DataService)
local DropService = require(script.DropService)
local ProfileStore = require(script.ProfileStore)
local PlayerManager = require(script.PlayerManager)
local NetworkHandler = require(script.NetworkHandler)
local StoreService = require(script.StoreService)
local DevTools = require(script.DevTools)
local WorldRegistry = require(script.WorldRegistry)

print("=== GrowRoblox Server Starting ===")

-- Set respawn time to 1 second (default is 5)
Players.RespawnTime = 1

-- ============================================================
-- COLLISION GROUPS: Players vs Drops
-- Register collision groups so drops pass through players
-- while still colliding with the ground/world barriers.
-- ============================================================
PhysicsService:RegisterCollisionGroup("Players")
PhysicsService:RegisterCollisionGroup("Drops")
PhysicsService:CollisionGroupSetCollidable("Players", "Drops", false)
-- Drops still collide with everything else (ground, barriers, tiles)
-- Players still collide with everything else (ground, barriers, tiles, each other)
print("[Boot] Collision groups registered: Players ↔ Drops = no collide")

-- Disable all SpawnLocations — we control spawn position via PlayerSpawned RemoteEvent
for _, v in ipairs(Workspace:GetDescendants()) do
	if v:IsA("SpawnLocation") then
		v.Enabled = false
		v.Duration = 0
		print(`[Boot] Disabled SpawnLocation "{v.Name}"`)
	end
end

-- ============================================================
-- STEP 1: World service — generates START world on boot
-- ============================================================
WorldService.Init()

-- ============================================================
-- STEP 2: Core gameplay systems
-- ============================================================
LockService.Init()
BlockService.Init()
DropService.Init()

-- ============================================================
-- STEP 3: Persistence & economy layer
-- ============================================================
InventoryService.Init()
GemService.Init()
DataService.Init()

-- ============================================================
-- STEP 4: In-game store catalog
-- ============================================================
StoreService.Init()

-- ============================================================
-- STEP 5: Growth & splice systems
-- ============================================================
SpliceService.Init()
SeedService.Init()

-- ============================================================
-- STEP 6: Player data wiring (BEFORE PlayerManager)
-- DataService.WirePlayerEvents() loads saved inventory/gems
-- on PlayerAdded. It MUST execute before PlayerManager.Init()
-- so that isNewPlayer() can read loaded data when
-- onPlayerAdded fires for new joiners.
-- ============================================================
DataService.WirePlayerEvents()

-- ============================================================
-- STEP 7: Player join/leave handling
-- PlayerManager.Init() wires onPlayerAdded/onPlayerRemoving,
-- handles existing players on boot, and fires PlayerSpawned.
-- ============================================================
PlayerManager.Init()

-- ============================================================
-- STEP 8: Network handler — wires all client→server
-- RemoteEvent handlers (RequestBreakBlock, etc.)
-- Must come AFTER PlayerManager so BroadcastToWorld is ready.
-- ============================================================
NetworkHandler.Init()

-- ============================================================
-- STEP 8b: DevTools — Studio-only smoke test utilities
-- Runs LockService.CanModify unit test on boot.
-- Integrates /godmode, /printworld, /tp commands via NetworkHandler.
-- ============================================================
DevTools.Init()

-- ============================================================
-- STEP 9: WorldRegistry — cross-server world tracking
-- Starts heartbeat loop and binds shutdown cleanup.
-- ============================================================
WorldRegistry.Init()

-- ============================================================
-- STEP 10: Background growth loop (every 10 seconds)
-- ============================================================
SeedService.StartGrowthLoop()

-- ============================================================
-- STEP 11: Background auto-save (every 60 seconds)
-- ============================================================
DataService.StartAutoSave()

-- ============================================================
-- THROTTLE CLEANUP
-- ============================================================
local RemoteEvents = require(ReplicatedStorage.Shared.RemoteEvents)
Players.PlayerRemoving:Connect(function(player)
	RemoteEvents.ClearThrottleForPlayer(player)
end)

-- ============================================================
-- SHUTDOWN HANDLER
-- ============================================================
game:BindToClose(function()
	print("=== Shutting down GrowRoblox server ===")
	WorldRegistry.CleanupServer()
	WorldService.SaveAll()
	ProfileStore.SaveAllWorlds()
	for _, player in ipairs(Players:GetPlayers()) do
		local currentWorld = PlayerManager.GetPlayerWorld(player)
		ProfileStore.SavePlayerProfile(
			player.UserId,
			GemService.GetGems(player),
			InventoryService.GetInventory(player),
			currentWorld or "START"
		)
	end
end)

print("=== GrowRoblox Server Ready! ===")
