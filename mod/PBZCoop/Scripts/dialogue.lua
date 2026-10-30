-- Your partner's dialogue lines as tips (fork extra; PhantomPact.ini ShareDialogue).
-- The line in a visible PBZEventPipelineDialogWidget (DialogueData.Text) is sent once ("T <text>"); the partner sees
-- it as a tip. Choices stay each player's own. Not yet seen in game: no conversation was open while testing.

return function(api)
    local log, valid = api.log, api.valid
    local coop = api.coop
    local net = coop.net

    local CHECK_TICKS = 15          -- ~0.25 s
    local MAX_CHARS = 200

    local dialogue = { on = true, last = nil }
    local ticks = 0

    local function watch()
        local line
        for _, w in ipairs(FindAllOf("PBZEventPipelineDialogWidget") or {}) do
            if valid(w) and w:IsVisible() then
                local ok, text = pcall(function() return w.DialogueData.Text:ToString() end)
                if ok and text and text:match("%S") then
                    line = text
                    break
                end
            end
        end
        if line and line ~= dialogue.last then
            coop.sendEvent("T", (line:gsub("[%c]+", " ")):sub(1, MAX_CHARS))
        end
        dialogue.last = line
    end

    coop.handlers.T = function(text)
        if dialogue.on and text and text:match("%S") and api.status and api.status.notify then
            api.status.notify("dialogue", "(partner's dialogue) " .. text:gsub("[%c]+", " "):sub(1, MAX_CHARS))
        end
    end

    coop.extraTicks.dialogue = function()
        ticks = ticks + 1
        if dialogue.on and net.enabled and ticks % CHECK_TICKS == 0 then
            local ok, err = pcall(watch)
            if not ok and err ~= dialogue.lastError then
                dialogue.lastError = err
                log("dialogue: " .. tostring(err))
            end
        end
    end

    return dialogue
end
