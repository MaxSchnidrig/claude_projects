--!strict
-- The enchantment shimmer (Phase 10b, our own look): a soft violet band of light that sweeps
-- diagonally across enchanted items, over and over. On icons it's a gradient overlay; on 3D
-- items (held, dropped) a pulsing violet Highlight.

local RunService = game:GetService("RunService")

local Glint = {}

local overlays: { [Frame]: UIGradient } = {}
local highlights: { [Highlight]: boolean } = {}

-- A glint overlay covering `parent` (hidden until Glint.set).
function Glint.attach(parent: GuiObject, zIndex: number?): Frame
	local f = Instance.new("Frame")
	f.Name = "Glint"
	f.BorderSizePixel = 0
	f.BackgroundColor3 = Color3.fromRGB(190, 120, 255)
	f.BackgroundTransparency = 0.35
	f.Size = UDim2.fromScale(1, 1)
	f.ZIndex = zIndex or 2
	f.Visible = false
	f.Active = false
	local g = Instance.new("UIGradient")
	g.Rotation = 35
	g.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.4, 1),
		NumberSequenceKeypoint.new(0.5, 0.25),
		NumberSequenceKeypoint.new(0.6, 1),
		NumberSequenceKeypoint.new(1, 1),
	})
	g.Parent = f
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = f
	f.Parent = parent
	overlays[f] = g
	f.Destroying:Connect(function()
		overlays[f] = nil
	end)
	return f
end

function Glint.set(f: Frame?, on: boolean)
	if f then
		f.Visible = on
	end
end

-- A pulsing violet highlight on a 3D model; returns it (destroy it to remove).
function Glint.highlight(adornee: Instance): Highlight
	local h = Instance.new("Highlight")
	h.Name = "Glint"
	h.FillColor = Color3.fromRGB(170, 100, 255)
	h.OutlineTransparency = 1
	h.FillTransparency = 0.7
	h.DepthMode = Enum.HighlightDepthMode.Occluded
	h.Adornee = adornee
	h.Parent = adornee
	highlights[h] = true
	h.Destroying:Connect(function()
		highlights[h] = nil
	end)
	return h
end

-- Make sure `adornee` has (or hasn't) the shimmer highlight.
function Glint.sync(adornee: Instance?, on: boolean)
	if not adornee then
		return
	end
	local h = adornee:FindFirstChild("Glint")
	if on and not (h and h:IsA("Highlight")) then
		Glint.highlight(adornee)
	elseif not on and h then
		h:Destroy()
	end
end

RunService.RenderStepped:Connect(function()
	local t = os.clock()
	-- the band crosses in 1.6 s, then a short pause
	local phase = (t % 2.2) / 1.6
	local offset = Vector2.new(-1 + phase * 2, 0)
	for f, g in overlays do
		if f.Visible then
			g.Offset = offset
		end
	end
	local pulse = 0.62 + math.sin(t * 4) * 0.12
	for h in highlights do
		h.FillTransparency = pulse
	end
end)

return Glint
