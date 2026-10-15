--!strict
--[[
	Leaderstats
	===========
	The leaderboard in the top-right corner of the screen shows every value
	inside a folder named "leaderstats" on each Player. We use text values, so
	big numbers can be shown nicely ("12.5K").

	Usage:
		Leaderstats.set(player, "Speed", "12.5K")
]]

local Leaderstats = {}

local function getFolder(player: Player): Folder
	local existing = player:FindFirstChild("leaderstats")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "leaderstats"
	folder.Parent = player
	return folder
end

function Leaderstats.set(player: Player, statName: string, text: string)
	local folder = getFolder(player)
	local existing = folder:FindFirstChild(statName)
	if existing and existing:IsA("StringValue") then
		existing.Value = text
		return
	end
	local value = Instance.new("StringValue")
	value.Name = statName
	value.Value = text
	value.Parent = folder
end

return Leaderstats
