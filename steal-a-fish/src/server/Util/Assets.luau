--!strict
-- The Assets helper now lives in ReplicatedStorage.Shared.Assets (the client
-- builds fish pictures with it too). This file just points there, so older
-- server code can keep using script.Parent.Parent.Util.Assets.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

return require(ReplicatedStorage.Shared.Assets)
