-- Remotes.luau
-- Central RemoteEvent/RemoteFunction definitions
-- All client-server communication goes through here

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = {}

-- Create a RemoteEvent if it doesn't exist
local function createEvent(name: string): RemoteEvent
	local container = ReplicatedStorage:FindFirstChild("Remotes")
	if not container then
		container = Instance.new("Folder")
		container.Name = "Remotes"
		container.Parent = ReplicatedStorage
	end

	local existing = container:FindFirstChild(name)
	if existing then
		return existing :: RemoteEvent
	end

	local event = Instance.new("RemoteEvent")
	event.Name = name
	event.Parent = container
	return event
end

-- Create a RemoteFunction if it doesn't exist
local function createFunction(name: string): RemoteFunction
	local container = ReplicatedStorage:FindFirstChild("Remotes")
	if not container then
		container = Instance.new("Folder")
		container.Name = "Remotes"
		container.Parent = ReplicatedStorage
	end

	local existing = container:FindFirstChild(name)
	if existing then
		return existing :: RemoteFunction
	end

	local func = Instance.new("RemoteFunction")
	func.Name = name
	func.Parent = container
	return func
end

-- Initialize all remotes
function Remotes.Init()
	-- Events (fire-and-forget)
	Remotes.Events = {
		-- Player actions
		BreakBlock = createEvent("BreakBlock"),
		PlaceBlock = createEvent("PlaceBlock"),
		UseTool = createEvent("UseTool"),
		PlantSeed = createEvent("PlantSeed"),
		HarvestBlock = createEvent("HarvestBlock"),
		SpliceSeeds = createEvent("SpliceSeeds"),
		ChopTree = createEvent("ChopTree"),
		Notify = createEvent("Notify"),
		TreeListUpdate = createEvent("TreeListUpdate"),

		-- Inventory
		DropItem = createEvent("DropItem"),
		SwapItem = createEvent("SwapItem"),
		UseItem = createEvent("UseItem"),

		-- World updates (server -> client)
		BlockChanged = createEvent("BlockChanged"),
		ChunkData = createEvent("ChunkData"),
		InventoryUpdate = createEvent("InventoryUpdate"),
		GrowthUpdate = createEvent("GrowthUpdate"),
		SpliceResult = createEvent("SpliceResult"),
		PlayerJoined = createEvent("PlayerJoined"),
		PlayerLeft = createEvent("PlayerLeft"),

		-- Economy
		GemsUpdated = createEvent("GemsUpdated"),

		-- Effects
		PlayEffect = createEvent("PlayEffect"),
		PlaySound = createEvent("PlaySound"),
	}

	-- Functions (request-response)
	Remotes.Functions = {
		GetWorldData = createFunction("GetWorldData"),
		GetChunkData = createFunction("GetChunkData"),
		GetInventory = createFunction("GetInventory"),
		RequestCraft = createFunction("RequestCraft"),
		RequestSplice = createFunction("RequestSplice"),
		RequestTrade = createFunction("RequestTrade"),
	}
end

-- Helper: Get a reference to a remote (safe to call from both server and client)
function Remotes.GetEvent(name: string): RemoteEvent
	if not Remotes.Events then
		Remotes.Init()
	end
	return Remotes.Events[name]
end

function Remotes.GetFunction(name: string): RemoteFunction
	if not Remotes.Functions then
		Remotes.Init()
	end
	return Remotes.Functions[name]
end

-- Automatically init on require
Remotes.Init()

return Remotes
