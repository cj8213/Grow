-- Effects.luau
-- Client-side visual effects and sounds

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Shared = require(ReplicatedStorage.Shared)
local Remotes = Shared.Remotes

local Effects = {}

--[[
	Initialize Effects system
]]
function Effects.Init()
	-- Listen for effect events from server
	Remotes.Events.PlayEffect.OnClientEvent:Connect(function(effectType: string, x: number, y: number, z: number, blockId: number)
		Effects.PlayEffect(effectType, x, y, z, blockId)
	end)

	-- Listen for sound events
	Remotes.Events.PlaySound.OnClientEvent:Connect(function(soundName: string, x: number, y: number, z: number)
		Effects.PlaySound(soundName, x, y, z)
	end)

	print("[Effects] Initialized")
end

--[[
	Play a visual effect at a position
	
	Effect types:
	- "break": Block breaking particles
	- "place": Block placing particles
	- "splice": Seed splicing sparkle
	- "harvest": Gentle harvest
	- "wrench": Wrench modify effect
]]
function Effects.PlayEffect(effectType: string, x: number, y: number, z: number, blockId: number)
	local BLOCK_SIZE = 3
	local position = Vector3.new(
		x * BLOCK_SIZE + BLOCK_SIZE / 2,
		y * BLOCK_SIZE + BLOCK_SIZE / 2,
		z * BLOCK_SIZE + BLOCK_SIZE / 2
	)

	if effectType == "break" then
		Effects._createBreakEffect(position, blockId)
	elseif effectType == "place" then
		Effects._createPlaceEffect(position, blockId)
	elseif effectType == "splice" then
		Effects._createSpliceEffect(position)
	elseif effectType == "harvest" then
		Effects._createHarvestEffect(position)
	elseif effectType == "wrench" then
		Effects._createWrenchEffect(position)
	end
end

--[[
	Create break particles
]]
function Effects._createBreakEffect(position: Vector3, blockId: number)
	local particleEmitter = Instance.new("ParticleEmitter")
	particleEmitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	particleEmitter.Rate = 50
	particleEmitter.Lifetime = NumberRange.new(0.5, 1)
	particleEmitter.Speed = NumberRange.new(5, 15)
	particleEmitter.VelocityInheritance = 0
	particleEmitter.Enabled = true

	local attachment = Instance.new("Attachment")
	attachment.WorldPosition = position

	particleEmitter.Parent = attachment
	attachment.Parent = Workspace.Terrain

	-- Clean up after animation
	task.delay(1, function()
		particleEmitter.Enabled = false
		task.delay(2, function()
			attachment:Destroy()
		end)
	end)
end

--[[
	Create place effect
]]
function Effects._createPlaceEffect(position: Vector3, blockId: number)
	-- Similar to break but with a puff
	local particleEmitter = Instance.new("ParticleEmitter")
	particleEmitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	particleEmitter.Rate = 30
	particleEmitter.Lifetime = NumberRange.new(0.3, 0.6)
	particleEmitter.Speed = NumberRange.new(3, 8)
	particleEmitter.VelocityInheritance = 0
	particleEmitter.Enabled = true

	local attachment = Instance.new("Attachment")
	attachment.WorldPosition = position

	particleEmitter.Parent = attachment
	attachment.Parent = Workspace.Terrain

	task.delay(0.5, function()
		particleEmitter.Enabled = false
		task.delay(1, function()
			attachment:Destroy()
		end)
	end)
end

--[[
	Create splice sparkle effect
]]
function Effects._createSpliceEffect(position: Vector3)
	local particleEmitter = Instance.new("ParticleEmitter")
	particleEmitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	particleEmitter.Rate = 100
	particleEmitter.Lifetime = NumberRange.new(0.8, 1.5)
	particleEmitter.Speed = NumberRange.new(10, 25)
	particleEmitter.VelocityInheritance = 0
	particleEmitter.Acceleration = Vector3.new(0, 20, 0)
	particleEmitter.SpreadAngle = NumberRange.new(0, 360)
	particleEmitter.Enabled = true

	local attachment = Instance.new("Attachment")
	attachment.WorldPosition = position

	particleEmitter.Parent = attachment
	attachment.Parent = Workspace.Terrain

	task.delay(1.5, function()
		particleEmitter.Enabled = false
		task.delay(2, function()
			attachment:Destroy()
		end)
	end)
end

--[[
	Create harvest effect
]]
function Effects._createHarvestEffect(position: Vector3)
	local particleEmitter = Instance.new("ParticleEmitter")
	particleEmitter.Texture = "rbxasset://textures/particles/leaf_particle.dds"
	particleEmitter.Rate = 40
	particleEmitter.Lifetime = NumberRange.new(0.5, 1.2)
	particleEmitter.Speed = NumberRange.new(2, 8)
	particleEmitter.VelocityInheritance = 0
	particleEmitter.Enabled = true

	local attachment = Instance.new("Attachment")
	attachment.WorldPosition = position

	particleEmitter.Parent = attachment
	attachment.Parent = Workspace.Terrain

	task.delay(1, function()
		particleEmitter.Enabled = false
		task.delay(2, function()
			attachment:Destroy()
		end)
	end)
end

--[[
	Create wrench effect
]]
function Effects._createWrenchEffect(position: Vector3)
	local particleEmitter = Instance.new("ParticleEmitter")
	particleEmitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	particleEmitter.Rate = 20
	particleEmitter.Lifetime = NumberRange.new(0.3, 0.6)
	particleEmitter.Speed = NumberRange.new(3, 6)
	particleEmitter.VelocityInheritance = 0
	particleEmitter.Enabled = true

	local attachment = Instance.new("Attachment")
	attachment.WorldPosition = position

	particleEmitter.Parent = attachment
	attachment.Parent = Workspace.Terrain

	task.delay(0.5, function()
		particleEmitter.Enabled = false
		task.delay(1, function()
			attachment:Destroy()
		end)
	end)
end

--[[
	Play a sound at a position
]]
function Effects.PlaySound(soundName: string, x: number, y: number, z: number)
	local BLOCK_SIZE = 3
	local position = Vector3.new(
		x * BLOCK_SIZE + BLOCK_SIZE / 2,
		y * BLOCK_SIZE + BLOCK_SIZE / 2,
		z * BLOCK_SIZE + BLOCK_SIZE / 2
	)

	local sound = Instance.new("Sound")
	sound.Name = soundName
	sound.SoundId = "rbxasset://sounds/" .. soundName .. ".wav"
	sound.Position = position
	sound.Volume = 0.5
	sound.Parent = Workspace.Terrain

	sound:Play()

	-- Clean up
	sound.Ended:Connect(function()
		sound:Destroy()
	end)
	task.delay(5, function()
		if sound then
			sound:Destroy()
		end
	end)
end

return Effects
