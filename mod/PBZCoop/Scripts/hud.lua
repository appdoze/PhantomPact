-- Your partner on screen, in the game's own ink-bar text (WB_TipsText, as status.lua's tips):
--   a line at the top: "Partner 82% · 35 m" (or down / in a cutscene / in another area / connecting)
--   a "Partner" label that follows their ghost, placed every tick from its position projected to the screen
--   (PlayerController.ProjectWorldLocationToScreen, SetPositionInViewport; checked in game), hidden when the ghost
--   is off screen or hidden.
--   on the open map: your own map icon (WB_PlayerIcon) in cyan at their position, its tip turned to where they
--   face, on the map's own canvas (WB_MapNew_C.Gadget, where the map's icons live) at
--   MapSubsystem.ProjectWorldLocationToMap x 1920, the map's canvas size (checked in game against every bell icon
--   of an area, and on screen)
-- PhantomPact.ini PartnerHud = On|Off, PartnerMarker = On|Off (the label and the map icon).

return function(api)
    local log, valid = api.log, api.valid
    local coop = api.coop
    local net = coop.net

    local TEXT_TICKS = 30           -- ~0.5 s between text updates
    local LINE_Y = -900             -- the line's offset from the tip area (bottom) to the top of the screen
    local HEAD_CM = 110             -- the label sits this far above the ghost's position
    local FRESH_S = 3.0
    local LINE_Z, MARKER_Z = 399, 398

    local hud = { line = true, marker = true }
    local ticks = 0
    local lineWidget, markerWidget, mapWidget, mapOwner
    local lastLine, lastMarker
    local MAP_CANVAS = 1920         -- the map canvas: map coordinates (0..1) x this
    local PARTNER_COLOR = { R = 0.25, G = 0.85, B = 1.0, A = 1.0 }  -- your map icon, in cyan

    local function create(z)
        local sample = FindFirstOf("WB_TipsText_C")
        local pc = FindFirstOf("PlayerController")
        if not (valid(sample) and valid(pc)) then
            return nil
        end
        local w = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, sample:GetClass(), pc)
        w:AddToViewport(z)
        w:SetVisibility(3)                  -- HitTestInvisible
        return w
    end

    local function show(w, on)
        if valid(w) then
            pcall(function() w:SetVisibility(on and 3 or 1) end)      -- collapsed when off
        end
    end

    local function remove()
        for _, w in ipairs({ lineWidget, markerWidget, mapWidget }) do
            if valid(w) then
                pcall(function() w:RemoveFromParent() end)
            end
        end
        lineWidget, markerWidget, mapWidget, mapOwner, lastLine, lastMarker = nil, nil, nil, nil, nil, nil
    end

    local function fresh()
        return net.enabled and net.target ~= nil and net.targetAt ~= nil and os.clock() - net.targetAt <= FRESH_S
    end

    -- "Partner 82% · 35 m", or what keeps them away.
    function hud.lineText()
        if not fresh() then
            return "Partner: connecting..."
        end
        local t = net.target
        local pct = (t.MaxHp and t.MaxHp > 0 and t.Hp) and math.floor(t.Hp / t.MaxHp * 100 + 0.5) or nil
        if pct and pct <= 0 then
            return "Partner: down"
        end
        local health = pct and (" " .. pct .. "%") or ""
        if t.Cine then
            return "Partner" .. health .. " · in a cutscene"
        end
        if t.Map and net.localMap and t.Map ~= "?" and t.Map ~= net.localMap then
            return "Partner" .. health .. " · in another area"
        end
        local _, pawn = api.getPlayer1()
        if valid(pawn) then
            local l = pawn:K2_GetActorLocation()
            local d = math.sqrt((l.X - t.X) ^ 2 + (l.Y - t.Y) ^ 2 + (l.Z - t.Z) ^ 2) / 100
            return string.format("Partner%s · %d m", health, math.floor(d + 0.5))
        end
        return "Partner" .. health
    end

    local function updateLine()
        if not valid(lineWidget) then
            lineWidget = create(LINE_Z)
            if not lineWidget then
                return
            end
            pcall(function() lineWidget:SetRenderTranslation({ X = 0.0, Y = LINE_Y }) end)
            lastLine = nil
        end
        local text = hud.lineText()
        if text ~= lastLine then
            lineWidget:SetText(FText(text))
            lastLine = text
        end
        show(lineWidget, true)
    end

    -- The label over the ghost, every tick.
    local function updateMarker()
        local ghost = net.ghost
        if not (valid(ghost) and not net.ghostHidden and fresh()) then
            show(markerWidget, false)
            return
        end
        local pc = FindFirstOf("PlayerController")
        if not valid(pc) then
            return
        end
        local g = ghost:K2_GetActorLocation()
        local screen = {}
        local onScreen = pc:ProjectWorldLocationToScreen({ X = g.X, Y = g.Y, Z = g.Z + HEAD_CM }, screen, false)
        if not onScreen or not screen.X then
            show(markerWidget, false)
            return
        end
        if not valid(markerWidget) then
            markerWidget = create(MARKER_Z)
            if not markerWidget then
                return
            end
            pcall(function() markerWidget:SetAlignmentInViewport({ X = 0.5, Y = 1.0 }) end)
            lastMarker = nil
        end
        if lastMarker ~= "Partner" then
            markerWidget:SetText(FText("Partner"))
            lastMarker = "Partner"
        end
        markerWidget:SetPositionInViewport({ X = screen.X, Y = screen.Y }, true)
        show(markerWidget, true)
    end

    -- The partner on the open map (same area, inside the painted map).
    local function updateMap()
        local map
        for _, w in ipairs(FindAllOf("WB_MapNew_C") or {}) do
            if valid(w) and w:IsVisible() then
                map = w
                break
            end
        end
        if not map then
            return                          -- closed: the label closes with it
        end
        local t = net.target
        local ms = FindFirstOf("MapSubsystem")
        if not (fresh() and valid(ms) and t.Map == net.localMap) then
            show(mapWidget, false)
            return
        end
        local mapId = ms:GetCurrentMapID()
        local function project(x, y, z)
            local uv = ms:ProjectWorldLocationToMap({ X = x, Y = y, Z = z }, mapId)
            if not uv or (uv.X == 0 and uv.Y == 0) then
                return nil                  -- outside the painted map
            end
            return uv.X * MAP_CANVAS, uv.Y * MAP_CANVAS
        end
        local px, py = project(t.X, t.Y, t.Z)
        if not px then
            show(mapWidget, false)
            return
        end
        -- Your own map icon, tinted, on the same canvas.
        if not (valid(mapWidget) and mapOwner == map:GetAddress()) then
            if valid(mapWidget) then
                pcall(function() mapWidget:RemoveFromParent() end)
            end
            local mine = map.WB_PlayerIcon
            local pc = FindFirstOf("PlayerController")
            if not (valid(mine) and valid(pc)) then
                return
            end
            mapWidget = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, mine:GetClass(), pc)
            local slot = mine:GetParent():AddChildToCanvas(mapWidget)
            slot:SetAutoSize(mine.Slot:GetAutoSize())
            slot:SetSize(mine.Slot:GetSize())
            slot:SetAlignment(mine.Slot:GetAlignment())
            mapWidget:SetColorAndOpacity(PARTNER_COLOR)
            mapOwner = map:GetAddress()
        end
        mapWidget.Slot:SetPosition({ X = px, Y = py })
        -- Facing: project a point 5 m ahead and turn the icon's tip to it (the tip points up at 0° and turns
        -- clockwise with the angle; checked in game).
        local yaw = math.rad(t.Yaw or 0)
        local fx, fy = project(t.X + math.cos(yaw) * 500, t.Y + math.sin(yaw) * 500, t.Z)
        if fx and (fx ~= px or fy ~= py) then
            mapWidget:SetRenderTransformAngle(math.deg(math.atan(fx - px, py - fy)))
        end
        show(mapWidget, true)
    end

    coop.extraTicks.hud = function()
        if not net.enabled then
            if lineWidget or markerWidget then
                remove()
            end
            return
        end
        ticks = ticks + 1
        local ok, err = pcall(function()
            if hud.marker then
                updateMarker()
            else
                show(markerWidget, false)
            end
            if hud.marker and ticks % 15 == 0 then
                updateMap()
            end
            if ticks % TEXT_TICKS == 0 then
                if hud.line then
                    updateLine()
                else
                    show(lineWidget, false)
                end
            end
        end)
        if not ok and err ~= hud.lastError then
            hud.lastError = err
            log("hud: " .. tostring(err))
        end
    end

    -- coop.lua stops calling extraTicks once sync is off, so the widgets are cleared from a loop of their own.
    if type(LoopAsync) == "function" then
        LoopAsync(1000, function()
            if not net.enabled and (lineWidget or markerWidget) then
                ExecuteInGameThread(function()
                    if not net.enabled then
                        remove()
                    end
                end)
            end
            return false
        end)
    end

    function hud.set(line, marker)
        hud.line, hud.marker = line, marker
    end

    function hud.command(args)
        local a = (args or ""):lower()
        if a == "off" then
            hud.set(false, false)
        elseif a == "on" then
            hud.set(true, true)
        end
        log("Partner HUD: line " .. tostring(hud.line) .. ", marker " .. tostring(hud.marker))
    end

    return hud
end
