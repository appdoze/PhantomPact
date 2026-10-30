-- Your partner on a compass at the top of the screen: a thin line, and a round partner icon that sits where
-- they are relative to where your camera faces. Straight ahead is the middle; further than COMPASS_HALF_DEG
-- to a side, the icon waits at that end, dimmed (turn that way). Red while they're down; hidden while they're
-- in another area or gone.
-- PhantomPact.ini PartnerCompass = On|Off. Art (painted in Lumina, in the game's ink-wash style): art/compass_line.png
-- (a dry-brush silver stroke) and art/partner_dot.png (a silver seal with 伴, "companion"), shown in the game's own
-- one-image widget (W_PaintSize). (Idea from appdoze's PR #5 partner HUD; a compass instead of big labels.)

return function(api)
    local log, valid = api.log, api.valid
    local coop = api.coop
    local net = coop.net

    local WIDGET_CLASS = "W_PaintSize_C"
    local COMPASS_HALF_DEG = 100    -- this far to either side maps to the line's ends
    local LINE_WIDTH_FRAC = 0.42    -- of the screen width
    local LINE_Y_FRAC = 0.055       -- from the top
    local LINE_ASPECT = 39 / 1024   -- compass_line.png's height / width
    local DOT_SIZE = 40
    local FRESH_S = 3.0
    local Z = 398
    local DOWN_TINT = { R = 1.0, G = 0.35, B = 0.3, A = 1.0 }
    local NORMAL_TINT = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }

    local hud = { on = true }
    local lineWidget, dotWidget
    local textures = {}

    local function texture(name)
        if valid(textures[name]) then
            return textures[name]
        end
        local pc = api.getPlayer1()
        local ok, tex = pcall(function()
            return StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary"):ImportFileAsTexture2D(pc,
                api.modRoot() .. "art/" .. name)
        end)
        textures[name] = (ok and valid(tex)) and tex or nil
        return textures[name]
    end

    local function newImage(texName, w, h)
        local cls = FindObject("WidgetBlueprintGeneratedClass", WIDGET_CLASS)
        local pc = api.getPlayer1()
        local tex = texture(texName)
        if not (valid(cls) and valid(pc) and tex) then
            return nil
        end
        local widget = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, cls, pc)
        if not valid(widget) then
            return nil
        end
        widget:AddToViewport(Z)
        widget:SetVisibility(3)                     -- HitTestInvisible: seen, never clicked
        pcall(function() widget:SetAlignmentInViewport({ X = 0.5, Y = 0.5 }) end)
        pcall(function() widget:SetDesiredSizeInViewport({ X = w, Y = h }) end)
        pcall(function()
            local img = widget.Circle
            img:SetBrushFromTexture(tex, false)
            local b = img.Brush
            b.ImageSize = { X = w, Y = h }
            img:SetBrush(b)
        end)
        return widget
    end

    -- W_PaintSize keeps its own layout size whatever size is asked for (the first try drew a 400 px medallion), so
    -- once laid out it's scaled to the wanted size with a render scale (about its centre, so positions hold).
    local function fit(w, wantW, wantH)
        local ok, size = pcall(function() return w:GetDesiredSize() end)
        if ok and size and size.X and size.X > 1 and size.Y > 1 then
            pcall(function() w:SetRenderScale({ X = wantW / size.X, Y = wantH / size.Y }) end)
        end
    end

    local function show(w, on)
        if valid(w) then
            pcall(function() w:SetVisibility(on and 3 or 1) end)      -- collapsed when off
        end
    end

    local function remove()
        for _, w in ipairs({ lineWidget, dotWidget }) do
            if valid(w) then
                pcall(function() w:RemoveFromParent() end)
            end
        end
        lineWidget, dotWidget = nil, nil
    end

    local function onScreen(w)
        return api.status and api.status.onScreen and api.status.onScreen(w)
    end

    local function fresh()
        return net.enabled and not net.partnerGone and net.target ~= nil and net.lastRemoteAt ~= nil
            and os.clock() - net.lastRemoteAt <= FRESH_S
    end

    -- Degrees from where the camera faces to the partner, -180..180 (negative = to the left).
    local function bearing(pc, from, to)
        local camYaw = pc.PlayerCameraManager:GetCameraRotation().Yaw
        local angle = math.deg(math.atan(to.Y - from.Y, to.X - from.X))
        return (angle - camYaw + 540) % 360 - 180
    end

    local function update()
        local t = net.target
        local otherMap = t and t.Map and net.localMap and t.Map ~= "?" and t.Map ~= net.localMap
        if not (hud.on and fresh()) or otherMap then
            show(lineWidget, false)
            show(dotWidget, false)
            return
        end
        local pc, pawn = api.getPlayer1()
        if not (valid(pc) and valid(pawn)) then
            return
        end
        if not onScreen(lineWidget) then
            lineWidget = nil
        end
        if not onScreen(dotWidget) then
            dotWidget = nil
        end
        local size = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary"):GetViewportSize(pc)
        local scale = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary"):GetViewportScale(pc)
        if not (size and size.X and size.X > 0 and scale and scale > 0) then
            return
        end
        -- Viewport positions are in DPI-scaled units.
        local vw, vh = size.X / scale, size.Y / scale
        local width = vw * LINE_WIDTH_FRAC
        local cx, cy = vw / 2, vh * LINE_Y_FRAC
        lineWidget = lineWidget or newImage("compass_line.png", width, width * LINE_ASPECT)
        dotWidget = dotWidget or newImage("partner_dot.png", DOT_SIZE, DOT_SIZE)
        if not (lineWidget and dotWidget) then
            return
        end
        local from = pawn:K2_GetActorLocation()
        local to = (valid(net.ghost) and not net.ghostHidden) and net.ghost:K2_GetActorLocation() or t
        local deg = bearing(pc, from, to)
        local behind = math.abs(deg) > COMPASS_HALF_DEG
        local x = cx + math.max(-1, math.min(1, deg / COMPASS_HALF_DEG)) * width / 2
        lineWidget:SetPositionInViewport({ X = cx, Y = cy }, false)
        dotWidget:SetPositionInViewport({ X = x, Y = cy }, false)
        fit(lineWidget, width, width * LINE_ASPECT)
        fit(dotWidget, DOT_SIZE, DOT_SIZE)
        local down = t.MaxHp and t.MaxHp > 0 and t.Hp and t.Hp <= 0
        pcall(function()
            dotWidget.Circle:SetColorAndOpacity(down and DOWN_TINT or NORMAL_TINT)
            dotWidget:SetRenderOpacity(behind and 0.55 or 1.0)
        end)
        show(lineWidget, true)
        show(dotWidget, true)
    end

    coop.extraTicks.hud = function()
        local ok, err = pcall(update)
        if not ok and err ~= hud.lastError then
            hud.lastError = err
            log("compass: " .. tostring(err))
        end
    end

    -- Sync off (netoff): coop.lua stops calling extraTicks, so the widgets are cleared from a loop of their own.
    if type(LoopAsync) == "function" then
        LoopAsync(1000, function()
            if not net.enabled and (lineWidget or dotWidget) then
                ExecuteInGameThread(function()
                    if not net.enabled then
                        remove()
                    end
                end)
            end
            return false
        end)
    end

    function hud.set(on)
        hud.on = on
    end

    -- hud on|off
    function hud.command(args)
        local a = (args or ""):lower()
        if a == "off" or a == "on" then
            hud.set(a == "on")
        end
        log("Partner compass: " .. (hud.on and "on" or "off"))
    end

    return hud
end
