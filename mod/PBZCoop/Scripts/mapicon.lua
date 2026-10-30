-- Your partner on the open map (fork extra; PhantomPact.ini PartnerMapIcon).
-- Your own map icon (the map's WB_PlayerIcon) copied in cyan onto the map's canvas (WB_MapNew_C.Gadget, where the
-- map's icons live) at MapSubsystem.ProjectWorldLocationToMap x 1920 (the canvas size; checked in game against every
-- bell icon of an area), its tip turned to where the partner faces (a point 5 m ahead projected the same way; the
-- tip points up at 0 degrees and turns clockwise; checked on game screenshots). Same area only.

return function(api)
    local log, valid = api.log, api.valid
    local coop = api.coop
    local net = coop.net

    local CHECK_TICKS = 15          -- ~0.25 s while the map is open
    local MAP_CANVAS = 1920
    local COLOR = { R = 0.25, G = 0.85, B = 1.0, A = 1.0 }
    local FRESH_S = 3.0

    local mapicon = { on = true }
    local ticks = 0
    local icon, owner

    local function hide()
        if valid(icon) then
            pcall(function() icon:SetVisibility(1) end)    -- collapsed
        end
    end

    local function update()
        local map
        for _, w in ipairs(FindAllOf("WB_MapNew_C") or {}) do
            if valid(w) and w:IsVisible() then
                map = w
                break
            end
        end
        if not map then
            return                  -- closed: the icon closes with it
        end
        local t = net.target
        local ms = FindFirstOf("MapSubsystem")
        local fresh = t and net.lastRemoteAt and not net.partnerGone and os.clock() - net.lastRemoteAt <= FRESH_S
        if not (fresh and valid(ms) and t.Map == net.localMap) then
            hide()
            return
        end
        local mapId = ms:GetCurrentMapID()
        local function project(x, y, z)
            local uv = ms:ProjectWorldLocationToMap({ X = x, Y = y, Z = z }, mapId)
            if not uv or (uv.X == 0 and uv.Y == 0) then
                return nil          -- outside the painted map
            end
            return uv.X * MAP_CANVAS, uv.Y * MAP_CANVAS
        end
        local px, py = project(t.X, t.Y, t.Z)
        if not px then
            hide()
            return
        end
        if not (valid(icon) and owner == map:GetAddress()) then
            if valid(icon) then
                pcall(function() icon:RemoveFromParent() end)
            end
            local mine = map.WB_PlayerIcon
            local pc = FindFirstOf("PlayerController")
            if not (valid(mine) and valid(pc)) then
                return
            end
            icon = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, mine:GetClass(), pc)
            local slot = mine:GetParent():AddChildToCanvas(icon)
            slot:SetAutoSize(mine.Slot:GetAutoSize())
            slot:SetSize(mine.Slot:GetSize())
            slot:SetAlignment(mine.Slot:GetAlignment())
            icon:SetColorAndOpacity(COLOR)
            owner = map:GetAddress()
        end
        icon.Slot:SetPosition({ X = px, Y = py })
        local yaw = math.rad(t.Yaw or 0)
        local fx, fy = project(t.X + math.cos(yaw) * 500, t.Y + math.sin(yaw) * 500, t.Z)
        if fx and (fx ~= px or fy ~= py) then
            icon:SetRenderTransformAngle(math.deg(math.atan(fx - px, py - fy)))
        end
        pcall(function() icon:SetVisibility(3) end)
    end

    coop.extraTicks.mapicon = function()
        ticks = ticks + 1
        if mapicon.on and net.enabled and ticks % CHECK_TICKS == 0 then
            local ok, err = pcall(update)
            if not ok and err ~= mapicon.lastError then
                mapicon.lastError = err
                log("mapicon: " .. tostring(err))
            end
        elseif not mapicon.on then
            hide()
        end
    end

    return mapicon
end
