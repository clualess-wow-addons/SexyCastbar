local ADDON_NAME = ...

-- SexyCastbar: replaces the default player cast bar with a "watch face" -
-- a metal ring with twelve tick marks, consumed clockwise as the cast
-- progresses (a Cooldown widget does the radial clipping natively), a
-- smoked-glass center showing the spell icon under a seconds countdown,
-- and the spell name below. Gold ring for casts, teal for channels; white
-- blip on completion, red flash on interrupt or cancel.

local RING_SIZE = 96
local ICON_SIZE = 64
local GLASS_SIZE = 42 -- a small badge behind the countdown, not an icon dimmer
local MEDIA = "Interface\\AddOns\\SexyCastbar\\media\\"
local CIRCLE_MASK = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"
local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local HEARTH_ICON = "Interface\\Icons\\INV_Misc_Rune_01"

-- The ring's color lerps across the cast: casts heat from ember red
-- through gold to green at completion; channels cool from teal to blue
-- as they drain.
local CAST_GRADIENT = { { 1, 0.35, 0.15 }, { 0.4, 1, 0.35 } }
local CHANNEL_GRADIENT = { { 0.3, 0.9, 0.8 }, { 0.25, 0.45, 1 } }
local COLOR_UNLOCKED = { 1, 0.8, 0.25 }
local COLOR_FAIL = { 1, 0.2, 0.2 }
local COLOR_DONE = { 1, 1, 1 }

local timerFont = CreateFont("SexyCastbarTimerFont")
timerFont:SetFont("Fonts\\ARIALN.TTF", 20, "OUTLINE")
local nameFont = CreateFont("SexyCastbarNameFont")
nameFont:SetFont("Fonts\\ARIALN.TTF", 11, "OUTLINE")

local frame, ring, glass, icon, cooldown, timer, nameText, flashTex, fader
local state    -- { endTime, duration, channel, castID } while a cast shows
local unlocked = false
local Finish   -- forward: the OnUpdate safety net calls it

local function Print(msg)
    print("|cffffd200SexyCastbar:|r " .. msg)
end

local function SavePosition()
    local point, _, relativePoint, x, y = frame:GetPoint()
    SexyCastbarDB.pos = { point, relativePoint, x, y }
end

local function BuildFrame()
    frame = CreateFrame("Frame", "SexyCastbarFrame", UIParent)
    frame:SetSize(RING_SIZE, RING_SIZE)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")

    local pos = SexyCastbarDB.pos
    if pos then
        frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        frame:SetPoint("CENTER", 0, -160)
    end

    -- Spell icon shown at full brightness; a small smoked-glass badge sits
    -- behind just the countdown so the icon stays clearly visible.
    icon = frame:CreateTexture(nil, "BACKGROUND", nil, -2)
    icon:SetSize(ICON_SIZE, ICON_SIZE)
    icon:SetPoint("CENTER")
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    local mask = frame:CreateMaskTexture()
    mask:SetTexture(CIRCLE_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(icon)
    icon:AddMaskTexture(mask)

    glass = frame:CreateTexture(nil, "BACKGROUND", nil, -1)
    glass:SetTexture(MEDIA .. "glass")
    glass:SetSize(GLASS_SIZE, GLASS_SIZE)
    glass:SetPoint("CENTER")

    ring = frame:CreateTexture(nil, "ARTWORK")
    ring:SetTexture(MEDIA .. "ring")
    ring:SetAllPoints()

    -- The Cooldown widget's swipe, shaped by the ring texture itself, eats
    -- the ring clockwise; SetReverse makes the dark area grow with time.
    cooldown = CreateFrame("Cooldown", nil, frame, "CooldownFrameTemplate")
    cooldown:SetAllPoints()
    cooldown.noCooldownCount = true
    if cooldown.SetHideCountdownNumbers then
        cooldown:SetHideCountdownNumbers(true)
    end
    cooldown:SetSwipeTexture(MEDIA .. "ring")
    cooldown:SetSwipeColor(0, 0, 0, 0.82)
    cooldown:SetReverse(true)
    if cooldown.SetDrawEdge then
        cooldown:SetDrawEdge(true) -- the sweep line doubles as a watch hand
    end
    if cooldown.SetEdgeTexture then
        cooldown:SetEdgeTexture("Interface\\Cooldown\\edge")
    end

    timer = cooldown:CreateFontString(nil, "OVERLAY")
    timer:SetFontObject(timerFont)
    timer:SetPoint("CENTER")

    nameText = frame:CreateFontString(nil, "OVERLAY")
    nameText:SetFontObject(nameFont)
    nameText:SetPoint("TOP", frame, "BOTTOM", 0, -3)

    -- End-of-cast feedback: an additive copy of the ring, flashed white on
    -- success or red on interrupt while the whole face fades out.
    flashTex = frame:CreateTexture(nil, "OVERLAY")
    flashTex:SetTexture(MEDIA .. "ring")
    flashTex:SetBlendMode("ADD")
    flashTex:SetAllPoints()
    flashTex:Hide()

    fader = frame:CreateAnimationGroup()
    local fade = fader:CreateAnimation("Alpha")
    fade:SetDuration(0.35)
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0)
    fader:SetScript("OnFinished", function()
        frame:Hide()
        flashTex:Hide()
    end)

    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)

    frame:SetScript("OnUpdate", function(self, elapsed)
        self.acc = (self.acc or 0) + elapsed
        if self.acc < 0.05 then return end
        self.acc = 0
        if not state then return end

        local remaining = state.endTime - GetTime()
        -- Safety net: if the stop event never arrives (test casts have
        -- none), retire the face shortly after time runs out.
        if remaining < -0.3 then
            Finish(state.castID == "test" and "success" or "quiet")
            return
        end
        if remaining < 0 then remaining = 0 end

        local p = state.duration > 0 and (1 - remaining / state.duration) or 1
        if p < 0 then p = 0 elseif p > 1 then p = 1 end
        local c0, c1 = state.gradient[1], state.gradient[2]
        ring:SetVertexColor(
            c0[1] + (c1[1] - c0[1]) * p,
            c0[2] + (c1[2] - c0[2]) * p,
            c0[3] + (c1[3] - c0[3]) * p)

        if remaining >= 10 then
            timer:SetText(string.format("%d", remaining))
        else
            timer:SetText(string.format("%.1f", remaining))
        end
        -- Final quarter of the cast: the countdown turns gold.
        if state.duration > 0 and remaining / state.duration < 0.25 then
            timer:SetTextColor(1, 0.82, 0)
        else
            timer:SetTextColor(1, 1, 1)
        end
    end)

    frame:Hide()
end

local function StartDisplay(name, texture, startMS, endMS, channel, castID)
    local start = startMS / 1000
    local duration = (endMS - startMS) / 1000
    state = {
        endTime = endMS / 1000,
        duration = duration,
        channel = channel,
        castID = castID,
        gradient = channel and CHANNEL_GRADIENT or CAST_GRADIENT,
    }

    icon:SetTexture(texture or FALLBACK_ICON)
    local c0 = state.gradient[1]
    ring:SetVertexColor(c0[1], c0[2], c0[3])
    nameText:SetText(name or "")
    timer:SetTextColor(1, 1, 1)
    timer:SetText("")
    cooldown:SetCooldown(start, duration)

    fader:Stop()
    flashTex:Hide()
    frame:SetAlpha(1)
    frame.acc = 1 -- render the first timer text immediately
    frame:Show()
end

-- kind: "success" (white blip), "fail" (red flash), "quiet" (plain fade).
function Finish(kind)
    if not state then return end
    state = nil
    cooldown:Clear()
    timer:SetText("")
    if kind ~= "quiet" then
        local color = kind == "fail" and COLOR_FAIL or COLOR_DONE
        flashTex:SetVertexColor(color[1], color[2], color[3])
        flashTex:Show()
        if kind == "fail" then
            ring:SetVertexColor(COLOR_FAIL[1], COLOR_FAIL[2], COLOR_FAIL[3])
        end
    end
    fader:Stop()
    fader:Play()
end

local function StartFromCastingInfo()
    local name, _, texture, startMS, endMS, _, castID = UnitCastingInfo("player")
    if name then
        StartDisplay(name, texture, startMS, endMS, false, castID)
        return true
    end
    return false
end

local function StartFromChannelInfo()
    local name, _, texture, startMS, endMS = UnitChannelInfo("player")
    if name then
        StartDisplay(name, texture, startMS, endMS, true, nil)
        return true
    end
    return false
end

local function SetUnlocked(on)
    unlocked = on
    frame:EnableMouse(on)
    if on then
        state = nil
        cooldown:Clear()
        icon:SetTexture(HEARTH_ICON)
        ring:SetVertexColor(COLOR_UNLOCKED[1], COLOR_UNLOCKED[2], COLOR_UNLOCKED[3])
        nameText:SetText("drag me - /scb locks")
        timer:SetText("")
        fader:Stop()
        flashTex:Hide()
        frame:SetAlpha(1)
        frame:Show()
        Print("Unlocked - drag the ring, then /scb to lock.")
    else
        if not state then frame:Hide() end
        Print("Locked.")
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, event, arg1, castGUID)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        self:UnregisterEvent("ADDON_LOADED")

        SexyCastbarDB = SexyCastbarDB or {}
        BuildFrame()

        -- The default bar only appears in response to events; without them
        -- it stays hidden for good. Recoverable by disabling the addon.
        local defaultBar = PlayerCastingBarFrame or CastingBarFrame
        if defaultBar then
            defaultBar:UnregisterAllEvents()
        end
        if OverlayPlayerCastingBarFrame then
            OverlayPlayerCastingBarFrame:UnregisterAllEvents()
        end

        for _, e in ipairs({
            "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP",
            "UNIT_SPELLCAST_DELAYED", "UNIT_SPELLCAST_INTERRUPTED",
            "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_CHANNEL_START",
            "UNIT_SPELLCAST_CHANNEL_UPDATE", "UNIT_SPELLCAST_CHANNEL_STOP",
        }) do
            self:RegisterUnitEvent(e, "player")
        end
        self:RegisterEvent("PLAYER_ENTERING_WORLD")

    elseif event == "UNIT_SPELLCAST_START" then
        StartFromCastingInfo()
    elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
        StartFromChannelInfo()

    elseif event == "UNIT_SPELLCAST_DELAYED" then
        -- Pushback: re-read the new timing.
        if state and not state.channel then
            StartFromCastingInfo()
        end
    elseif event == "UNIT_SPELLCAST_CHANNEL_UPDATE" then
        if state and state.channel then
            StartFromChannelInfo()
        end

    elseif event == "UNIT_SPELLCAST_STOP" then
        if state and not state.channel and castGUID == state.castID then
            -- STOP fires for completed AND cancelled casts; ending well
            -- before the cast time was up means it did not complete.
            local early = (state.endTime - GetTime()) > 0.2
            Finish(early and "fail" or "success")
        end
    elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        if state and state.channel then
            -- Clipping a channel early is normal play, so no red flash.
            Finish("quiet")
        end

    elseif event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_FAILED" then
        -- FAILED also fires for casts that never started (button mashing);
        -- the castGUID match keeps those from flashing the bar.
        if state and not state.channel and castGUID == state.castID then
            Finish("fail")
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Resume a cast that survived a loading screen or /reload.
        if not StartFromCastingInfo() then
            StartFromChannelInfo()
        end
    end
end)

SLASH_SEXYCASTBAR1 = "/sexycastbar"
SLASH_SEXYCASTBAR2 = "/scb"
SlashCmdList["SEXYCASTBAR"] = function(msg)
    msg = strtrim(msg or ""):lower()
    if msg == "test" then
        local now = GetTime() * 1000
        StartDisplay("SexyCastbar", HEARTH_ICON, now, now + 5000, false, "test")
    else
        SetUnlocked(not unlocked)
    end
end
