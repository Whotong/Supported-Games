--!strict
-- Re: Hub — Steal An Egg
-- Game-specific tab injected by main.lua

return function(Window)
	local Tab = Window:MakeTab("Steal An Egg")

	-- ═══════════════════════════════════════════
	-- STATE
	-- ═══════════════════════════════════════════
	local State = {}

	-- ═══════════════════════════════════════════
	-- MAIN SECTION
	-- ═══════════════════════════════════════════
	local Main = Tab:Section({ Title = "Automation" })

	Main:Toggle({
		Title = "Auto Collect Eggs",
		Content = "Automatically collect nearby eggs",
		Default = false,
		Callback = function(v)
			State.AutoCollect = v
		end,
		Flag = "SAE/AutoCollect"
	})

	Main:Toggle({
		Title = "Auto Steal",
		Content = "Steal eggs from other players",
		Default = false,
		Callback = function(v)
			State.AutoSteal = v
		end,
		Flag = "SAE/AutoSteal"
	})

	Main:Slider({
		Title = "Collect Distance",
		Min = 10,
		Max = 100,
		Increment = 5,
		Default = 50,
		Callback = function(v)
			State.CollectDistance = v
		end
	})

	Main:Button({
		Title = "Collect All Eggs",
		Content = "One-time collection of all visible eggs",
		Callback = function()
			-- Implementation would go here
		end
	})

	-- ═══════════════════════════════════════════
	-- MOVEMENT SECTION
	-- ═══════════════════════════════════════════
	local Movement = Tab:Section({ Title = "Movement" })

	Movement:Toggle({
		Title = "Speed Hack",
		Content = "Increase walk speed",
		Default = false,
		Callback = function(v)
			State.SpeedHack = v
			local char = game.Players.LocalPlayer.Character
			if char and char:FindFirstChildOfClass("Humanoid") then
				char:FindFirstChildOfClass("Humanoid").WalkSpeed = v and 32 or 16
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
				local char = game.Players.LocalPlayer.Character
				if char and char:FindFirstChildOfClass("Humanoid") then
					char:FindFirstChildOfClass("Humanoid").WalkSpeed = v
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
	-- ESP SECTION
	-- ═══════════════════════════════════════════
	local ESP = Tab:Section({ Title = "ESP" })

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

	-- ═══════════════════════════════════════════
	-- INFO SECTION
	-- ═══════════════════════════════════════════
	local Info = Tab:Section({ Title = "Info" })

	Info:Paragraph({
		Title = "Steal An Egg",
		Content = "Game loaded — " .. game.PlaceId
	})

	local statusPara = Info:Paragraph({
		Title = "Status",
		Content = "Idle"
	})

	-- Status updater
	task.spawn(function()
		while task.wait(2) do
			local status = "Idle"
			if State.AutoCollect then status = "Collecting..." end
			if State.AutoSteal then status = "Stealing..." end
			statusPara:Set({ Title = "Status", Content = status })
		end
	end)
end
