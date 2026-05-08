-- init.client.luau
-- Client boot sequence - initializes all client systems

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

print("=== GrowRoblox Client Starting ===")

-- Create a temporary invisible floor so the character has something
-- to stand on while the world tiles are being generated and rendered.
-- Surface is at tile Y=5. Tile center = (200, -20, 0). Tile top = (200, -18, 0).
-- The floor's top surface should be at Y=-18 so the character stands on it.
-- Floor center at Y=-18.5 with height 1 means top at Y=-18, bottom at Y=-19.
local tempFloor = Instance.new("Part")
tempFloor.Name = "TempFloor"
tempFloor.Size = Vector3.new(1000, 1, 1000)
tempFloor.Position = Vector3.new(200, -18.5, 0)  -- top at Y=-18 (surface level)
tempFloor.Anchored = true
tempFloor.CanCollide = true
tempFloor.Transparency = 1
tempFloor.Parent = Workspace

-- Freeze the player's character until the world fully renders.
-- This prevents the player from falling into the void while tiles load.
-- Uses HumanoidRootPart.Anchored = true for reliable freezing (no Enum.PlatformState issues).
local localPlayer = Players.LocalPlayer
local frozenRootPart = nil  -- track which root part we anchored

-- Shared spawn position buffer — set by PlayerSpawned listener (set up early),
-- read by InputController later. This ensures we never lose the spawn position
-- even if the event fires before InputController.Init() runs.
local pendingSpawnPos: Vector3? = nil
local lastSpawnPos: Vector3? = nil

-- Track whether the world has finished rendering (WorldLoaded fired)
local worldReady = false

local function freezeCharacter()
	local char = localPlayer.Character
	if not char then return end
	local hrp = char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Torso") or char:FindFirstChild("UpperTorso")
	if hrp then
		hrp.Anchored = true
		frozenRootPart = hrp
		print("[Boot] Character frozen (anchored) — waiting for world to render")
	end
end

local function unfreezeCharacter()
	if frozenRootPart and frozenRootPart.Parent then
		frozenRootPart.Anchored = false
		frozenRootPart = nil
		print("[Boot] Character unfrozen (unanchored) — world is ready")
	end
end

-- Apply a spawn position to the character's HumanoidRootPart.
-- Called from both the PlayerSpawned listener and CharacterAdded.
local function applySpawnPosition(pos: Vector3)
	local char = localPlayer.Character
	if not char then return false end
	local hrp = char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Torso") or char:FindFirstChild("UpperTorso")
	if hrp then
		hrp.CFrame = CFrame.new(pos)
		frozenRootPart = hrp  -- ensure we track this root part for unfreezing
		print(`[Boot] Applied spawn position {pos}`)
		return true
	end
	return false
end

-- Freeze as soon as character loads
localPlayer.CharacterAdded:Connect(function()
	freezeCharacter()
	-- If we have a pending spawn position, apply it now
	if pendingSpawnPos then
		applySpawnPosition(pendingSpawnPos)
	end
end)

-- If character already exists, freeze immediately
if localPlayer.Character then
	freezeCharacter()
end

-- Set up PlayerSpawned listener EARLY (before WorldRenderer, before InputController)
-- so we never miss the event even if the server fires before InputController.Init().
local RemoteEvents = require(ReplicatedStorage.Shared.RemoteEvents)
local TILE_SIZE = 4
local WORLD_WIDTH = 100
local WORLD_HEIGHT = 60

RemoteEvents.PlayerSpawned.OnClientEvent:Connect(function(tileX: number, tileY: number, worldName: string)
	print(`[Boot] PlayerSpawned at tile ({tileX}, {tileY}) in "{worldName}"`)

	-- Absolute spawn math:
	-- Tile (tileX, tileY) center = (tileX * TILE_SIZE, -tileY * TILE_SIZE, 0)
	-- For surface tile (50, 5): center = (200, -20, 0)
	-- Top of tile = center.Y + TILE_SIZE/2 = -20 + 2 = -18
	-- HumanoidRootPart should be ~2 studs above tile top = -18 + 2 = -16
	-- Formula: -tileY * TILE_SIZE + TILE_SIZE = -20 + 4 = -16 ✓
	local spawnPos = Vector3.new(tileX * TILE_SIZE, -tileY * TILE_SIZE + TILE_SIZE, 0)

	-- Store for later use (InputController also reads these)
	pendingSpawnPos = spawnPos
	lastSpawnPos = spawnPos

	-- Apply immediately if character exists
	applySpawnPosition(spawnPos)
end)

-- 1. WorldRenderer (Parts-based world builder)
-- MUST be initialized before InputController and CameraController
-- Also MUST be required before the RenderStepped safety net below (auto-respawn detection uses it)
local WorldRenderer = require(script.WorldRenderer)
WorldRenderer.Init()

-- Safety net: poll every frame for pending spawn position
-- (handles edge case where character loads after PlayerSpawned but before CharacterAdded)
RunService.RenderStepped:Connect(function()
	if pendingSpawnPos then
		if applySpawnPosition(pendingSpawnPos) then
			pendingSpawnPos = nil  -- clear after successful application
		end
	end

	-- Auto-respawn detection: if the player is stuck inside a solid block,
	-- force respawn them using absolute math.
	-- A player is "stuck" if their HumanoidRootPart position is inside a tile
	-- that has a solid foreground block.
	if worldReady and localPlayer.Character then
		local hrp = localPlayer.Character:FindFirstChild("HumanoidRootPart")
		if hrp then
			-- Convert world position to tile coordinates
			local px = hrp.Position.X
			local py = hrp.Position.Y
			local tileX = math.floor(px / TILE_SIZE + 0.5)
			local tileY = math.floor(-py / TILE_SIZE + 0.5)

			-- Check if the tile coordinates are valid and the tile has a solid foreground
			if tileX >= 0 and tileX < WORLD_WIDTH and tileY >= 0 and tileY < WORLD_HEIGHT then
				local tile = WorldRenderer.GetTileAt(tileX, tileY)
				if tile and tile.fg and tile.fg > 0 then
					-- Player is inside a solid block — force respawn
					print(`[Boot] Player stuck inside solid block at tile ({tileX}, {tileY}) — force respawning`)
					if lastSpawnPos then
						hrp.CFrame = CFrame.new(lastSpawnPos)
						hrp.Anchored = true
						task.delay(0.5, function()
							if hrp and hrp.Parent then
								hrp.Anchored = false
							end
						end)
					end
				end
			end
		end
	end
end)

-- Remove temp floor after world loads (give time for parts to render)
-- Note: RemoteEvents was already required above for PlayerSpawned
RemoteEvents.WorldLoaded.OnClientEvent:Connect(function()
	task.wait(2)  -- wait for parts to render
	if tempFloor and tempFloor.Parent then
		tempFloor:Destroy()
		print("[Boot] TempFloor destroyed — world tiles are now visible")
	end
	-- Unfreeze the character now that the world is rendered
	unfreezeCharacter()
	worldReady = true
end)

-- 2. CameraController (side-scrolling fixed-angle camera)
-- Follows character position, sets CameraType to Scriptable
local CameraController = require(script.CameraController)
CameraController.Init()

-- 3. InputController (raycast-based input: break/place clicks, tile highlight)
local InputController = require(script.InputController)
InputController.Init()

-- 4. Effects (particles, sounds)
local Effects = require(script.Effects)
Effects.Init()

-- Initialize UI systems
local Hotbar = require(script.UI.Hotbar)
local HUD = require(script.UI.HUD)
local WorldList = require(script.UI.WorldList)
local CraftingUI = require(script.UI.CraftingUI)
local StoreUI = require(script.UI.StoreUI)
local WrenchUI = require(script.UI.WrenchUI)

-- 5. Hotbar (32-slot expandable inventory — replaces old InventoryGUI)
Hotbar.Init()

-- 6. HUD (gems, info, chat, notifications)
HUD.Init()

-- 8. World List (world selection)
WorldList.Init()

-- 9. Crafting UI
CraftingUI.Init()

-- 10. Store UI (B key toggle, gem purchases)
StoreUI.Init()

-- 11. Wrench UI (tile info, door/admin management)
WrenchUI.Init()

-- 12. Admin UI (; key toggles admin panel)
local AdminUI = require(script.UI.AdminUI)
AdminUI.Init()

-- Initial hotbar selection (slot 1 selected by default)
Hotbar.SetSelectedSlot(1)

-- Hide Roblox's default backpack (we use our own hotbar)
StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)

print("=== GrowRoblox Client Ready! ===")
