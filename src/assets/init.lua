-- Assets.lua
-- References to texture Decals stored in ReplicatedStorage.Assets.
-- The user has Decal objects named "Dirt" and "Grass" in ReplicatedStorage.Assets.
-- This module provides a helper to look up the correct texture for a block face.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Assets = {}

-- Cache the Assets folder reference
local assetsFolder = ReplicatedStorage:FindFirstChild("Assets")

--[[
	Get the texture ID for a given block at (tileX, tileY).
	
	For Dirt blocks (ID 1):
	- If the tile BELOW (tileY+1) has NO foreground block (fg == 0 or nil),
	  this is the top-most exposed Dirt → use Grass texture on top face,
	  Dirt texture on sides/bottom.
	- Otherwise → use Dirt texture on all faces.
	
	For Grass blocks (ID 7):
	- Always use Grass texture.
	
	@param fgId: number — the foreground block ID
	@param tileGrid: table — the full tile grid (2D array)
	@param tileX: number — tile X coordinate
	@param tileY: number — tile Y coordinate
	@return (string?, string?) — (topFaceTextureId, sideFaceTextureId) or nil,nil if no texture
]]
function Assets.GetTexturesForBlock(fgId, tileGrid, tileX, tileY)
	if not assetsFolder then
		return nil, nil
	end
	
	if fgId == 1 then
		-- Dirt block: check the tile below
		local belowRow = tileGrid[tileY + 2]
		local belowTile = belowRow and belowRow[tileX + 1]
		local belowFg = belowTile and belowTile.fg or 0
		
		local dirtDecal = assetsFolder:FindFirstChild("Dirt")
		local grassDecal = assetsFolder:FindFirstChild("Grass")
		local dirtTex = dirtDecal and dirtDecal.Texture
		local grassTex = grassDecal and grassDecal.Texture
		
		if belowFg == 0 or belowFg == nil then
			-- Top-most exposed Dirt: Grass on top, Dirt on sides
			return grassTex, dirtTex
		else
			-- Buried Dirt: Dirt on all faces
			return dirtTex, dirtTex
		end
	elseif fgId == 7 then
		-- Grass block: always use Grass texture
		local grassDecal = assetsFolder:FindFirstChild("Grass")
		local grassTex = grassDecal and grassDecal.Texture
		return grassTex, grassTex
	end
	
	return nil, nil
end

return Assets
