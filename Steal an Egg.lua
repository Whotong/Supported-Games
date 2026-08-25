--!strict
-- Re: Hub — Steal An Egg
-- Game-specific script: fills the standard Main/Misc pages provided by the loader.
-- Contract: function(Window, Tabs)

return function(Window: any, Tabs: any)
	local Players = game:GetService("Players")
	local LocalPlayer = Players.LocalPlayer

	local State = { _alive = true }

	local function getHumanoid(): any
		local char = LocalPlayer.Character
		return char and char:FindFirstChildOfClass("Humanoid") or nil
	end

	-- ═══════════════════════════════════════════
	-- TEARDOWN — nothing outlives Destroy UI
	-- ═══════════════════════════════════════════
	Window:OnClose(function()
		State._alive = false
		State.AutoCollect = false
		State.AutoSteal = false
		State.NoClip = false
		State.ESPEggs = false
		State.ESPPlayers = false
		local hum = getHumanoid()
		if hum then
			hum.WalkSpeed = 16
		end
	end)

	-- ═══════════════════════════════════════════
	-- MAIN PAGE
	-- ═══════════════════════════════════════════
	local Main = Tabs.Main

	-- ── Automation ──
	local Automation = Main:Section({ Title = "Automation" })

	Automation:Toggle({
		Title = "Auto Collect Eggs",
		Content = "Automatically collect nearby eggs",
		Default = false,
		Callback = function(v)
			State.AutoCollect = v
		end,
		Flag = "SAE/AutoCollect"
	})

	Automation:Toggle({
		Title = "Auto Steal",
		Content = "Steal eggs from other players",
		Default = false,
		Callback = function(v)
			State.AutoSteal = v
		end,
		Flag = "SAE/AutoSteal"
	})

	Automation:Slider({
		Title = "Collect Distance",
		Min = 10,
		Max = 100,
		Increment = 5,
		Default = 50,
		Callback = function(v)
			State.CollectDistance = v
		end
	})

	Automation:Button({
		Title = "Collect All Eggs",
		Content = "One-time collection of all visible eggs",
		Callback = function()
			-- Implementation pending
		end
	})

	-- ── Movement ──
	local Movement = Main:Section({ Title = "Movement" })

	Movement:Toggle({
		Title = "Speed Hack",
		Content = "Increase walk speed",
		Default = false,
		Callback = function(v)
			State.SpeedHack = v
			local hum = getHumanoid()
			if hum then
				hum.WalkSpeed = v and (State.WalkSpeed or 32) or 16
			end
		end,
		Flag = "SAE/SpeedHack"
	})

	Movement:Slider({
		Title = "Walk Speed",
		Min = 16,
		Max = 200,
		Increment = 4,
		Default = 32,
		Callback = function(v)
			State.WalkSpeed = v
			if State.SpeedHack then
				local hum = getHumanoid()
				if hum then
					hum.WalkSpeed = v
				end
			end
		end
	})

	Movement:Toggle({
		Title = "No Clip",
		Content = "Walk through walls",
		Default = false,
		Callback = function(v)
			State.NoClip = v
		end,
		Flag = "SAE/NoClip"
	})

	-- ═══════════════════════════════════════════
	-- MISC PAGE
	-- ═══════════════════════════════════════════
	local Misc = Tabs.Misc

	-- ── ESP ──
	local ESP = Misc:Section({ Title = "ESP" })

	ESP:Toggle({
		Title = "ESP Eggs",
		Content = "Highlight eggs through walls",
		Default = false,
		Callback = function(v)
			State.ESPEggs = v
		end,
		Flag = "SAE/ESPEggs"
	})

	ESP:Toggle({
		Title = "ESP Players",
		Content = "Show player names and distance",
		Default = false,
		Callback = function(v)
			State.ESPPlayers = v
		end,
		Flag = "SAE/ESPPlayers"
	})

	-- ── Info ──
	local Info = Misc:Section({ Title = "Info" })

	Info:Paragraph({
		Title = "Steal An Egg",
		Content = "Game loaded — " .. game.PlaceId
	})

	local statusPara = Info:Paragraph({
		Title = "Status",
		Content = "Idle"
	})

	task.spawn(function()
		while State._alive and task.wait(2) do
			local status = "Idle"
			if State.AutoCollect then status = "Collecting..." end
			if State.AutoSteal then status = "Stealing..." end
			statusPara:Set({ Title = "Status", Content = status })
		end
	end)
end
