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

-- One loud electric blue for the ring, casts and channels alike; the
-- blink carries the "in progress" signal, progress is the sweep itself.
local COLOR_RING = { 0.15, 0.75, 1 }
local COLOR_UNLOCKED = { 1, 0.8, 0.25 }
local COLOR_FAIL = { 1, 0.2, 0.2 }
local COLOR_DONE = { 1, 1, 1 }

local timerFont = CreateFont("SexyCastbarTimerFont")
timerFont:SetFont("Fonts\\ARIALN.TTF", 20, "OUTLINE")
local timerFontSmall = CreateFont("SexyCastbarTimerFontSmall")
timerFontSmall:SetFont("Fonts\\ARIALN.TTF", 14, "OUTLINE")
local nameFont = CreateFont("SexyCastbarNameFont")
nameFont:SetFont("Fonts\\ARIALN.TTF", 11, "OUTLINE")

local frame, ring, glass, icon, darkL, darkR, hand, timer, nameText, flashTex, fader
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
    -- Position, element sizes, and layout come from ApplyMode.

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

    ring = frame:CreateTexture(nil, "ARTWORK")
    ring:SetTexture(MEDIA .. "ring")
    ring:SetAllPoints()

    -- Counterclockwise sweep. The Cooldown widget only animates clockwise,
    -- and mask textures follow SetRotation (which is why the mask-based
    -- version leaked), so the consumed area is two black half-ring
    -- textures rotating inside SetClipsChildren frames: the scissor
    -- rectangle is geometric and cannot rotate with them. First half of
    -- the cast the left texture rotates, growing a wedge from 12 o'clock
    -- down the left side (the right one is parked fully outside its
    -- clip); second half the left parks fully dark and the right rotates
    -- up its own side.
    local clipL = CreateFrame("Frame", nil, frame)
    clipL:SetClipsChildren(true)
    clipL:SetFrameLevel(frame:GetFrameLevel() + 1)
    clipL:SetPoint("TOPLEFT")
    clipL:SetPoint("BOTTOMRIGHT", frame, "BOTTOM")

    local clipR = CreateFrame("Frame", nil, frame)
    clipR:SetClipsChildren(true)
    clipR:SetFrameLevel(frame:GetFrameLevel() + 1)
    clipR:SetPoint("TOPRIGHT")
    clipR:SetPoint("BOTTOMLEFT", frame, "BOTTOM")

    darkL = clipL:CreateTexture(nil, "ARTWORK")
    darkL:SetTexture(MEDIA .. "ringhalf")
    darkL:SetPoint("TOPLEFT", frame)
    darkL:SetPoint("BOTTOMRIGHT", frame)
    darkL:SetVertexColor(0, 0, 0, 0.82)

    darkR = clipR:CreateTexture(nil, "ARTWORK")
    darkR:SetTexture(MEDIA .. "ringhalf")
    darkR:SetPoint("TOPLEFT", frame)
    darkR:SetPoint("BOTTOMRIGHT", frame)
    darkR:SetVertexColor(0, 0, 0, 0.82)

    -- Everything that must draw above the darkness lives above the clip
    -- frames: the needle, the countdown badge, and the end flash.
    local top = CreateFrame("Frame", nil, frame)
    top:SetFrameLevel(frame:GetFrameLevel() + 2)
    top:SetAllPoints()

    -- The watch hand: a needle riding the sweep's leading edge.
    hand = top:CreateTexture(nil, "ARTWORK")
    hand:SetTexture(MEDIA .. "hand")
    hand:SetAllPoints()
    hand:SetVertexColor(1, 0.95, 0.8, 0.9)
    hand:Hide()

    glass = top:CreateTexture(nil, "BACKGROUND")
    glass:SetTexture(MEDIA .. "glass")
    glass:SetSize(GLASS_SIZE, GLASS_SIZE)
    glass:SetPoint("CENTER")

    timer = top:CreateFontString(nil, "OVERLAY")
    timer:SetFontObject(timerFont)
    timer:SetPoint("CENTER", glass, "CENTER")

    nameText = frame:CreateFontString(nil, "OVERLAY")
    nameText:SetFontObject(nameFont)
    nameText:SetPoint("TOP", frame, "BOTTOM", 0, -3)

    -- End-of-cast feedback: an additive copy of the ring, flashed white on
    -- success or red on interrupt while the whole face fades out.
    flashTex = top:CreateTexture(nil, "OVERLAY")
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

    frame:SetScript("OnDragStart", function(self)
        if SexyCastbarDB.mode ~= "portrait" then
            self:StartMoving()
        end
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)

    frame:SetScript("OnUpdate", function(self, elapsed)
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

        -- The sweep rotates every frame so it stays smooth; text and
        -- colors below keep the 0.05s throttle. Each dark half animates
        -- only in its own phase - left during 0-50%, right during 50-100% -
        -- and parks outside it (hidden behind its mask, or fully covering).
        local alpha = p * 360
        darkL:SetRotation(math.rad(math.min(alpha, 180) - 180))
        darkR:SetRotation(math.rad(math.max(alpha, 180) - 180))
        hand:SetRotation(math.rad(alpha))

        -- The ring blinks while casting: a hard two-state blink (bright
        -- 0.55s, dim 0.25s - the TANKING rhythm); darkness, needle, and
        -- text stay steady so progress is never obscured.
        ring:SetAlpha(GetTime() % 0.8 < 0.55 and 1 or 0.35)

        self.acc = (self.acc or 0) + elapsed
        if self.acc < 0.05 then return end
        self.acc = 0

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

-- Two layouts. Free: the face floats where the user dragged it, spell icon
-- filling the center. Portrait: the ring wraps the PlayerFrame portrait
-- like a watch bezel - the spell icon covers the character's face for the
-- duration of the cast, and the countdown shrinks into a "date window" at
-- 6 o'clock.
local function ApplyMode()
    local portraitMode = SexyCastbarDB.mode == "portrait" and PlayerPortrait
    frame:ClearAllPoints()
    icon:ClearAllPoints()
    glass:ClearAllPoints()
    if portraitMode then
        frame:SetPoint("CENTER", PlayerPortrait, "CENTER")
        -- Sized so the ring rides the portrait's inner perimeter instead
        -- of wrapping around the outside (restored from a703961).
        frame:SetSize(62, 62)
        -- Our own icon stays hidden: the spell icon is written into the
        -- PlayerPortrait texture itself for the cast (see SwapPortrait),
        -- rendering under the frame art like a native portrait.
        icon:Hide()
        icon:SetPoint("CENTER")
        glass:SetSize(26, 26)
        glass:SetPoint("CENTER", frame, "BOTTOM", 0, 4)
        timer:SetFontObject(timerFontSmall)
        nameText:Hide()
    else
        local pos = SexyCastbarDB.pos
        if pos then
            frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
        else
            frame:SetPoint("CENTER", 0, -160)
        end
        frame:SetSize(RING_SIZE, RING_SIZE)
        icon:Show()
        icon:SetSize(ICON_SIZE, ICON_SIZE)
        icon:SetPoint("CENTER")
        glass:SetSize(GLASS_SIZE, GLASS_SIZE)
        glass:SetPoint("CENTER")
        timer:SetFontObject(timerFont)
        nameText:Show()
    end
end

-- In portrait mode the spell icon replaces the portrait itself for the
-- duration of the cast; the character's face is restored when it ends.
local portraitSwapped = false

local function SwapPortrait(texture)
    if SexyCastbarDB.mode == "portrait" and PlayerPortrait then
        PlayerPortrait:SetTexture(texture or FALLBACK_ICON)
        PlayerPortrait:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        portraitSwapped = true
    end
end

local function RestorePortrait()
    if portraitSwapped then
        portraitSwapped = false
        PlayerPortrait:SetTexCoord(0, 1, 0, 1)
        SetPortraitTexture(PlayerPortrait, "player")
    end
end

local function StartDisplay(name, texture, startMS, endMS, channel, castID)
    local duration = (endMS - startMS) / 1000
    state = {
        endTime = endMS / 1000,
        duration = duration,
        channel = channel,
        castID = castID,
        texture = texture,
    }

    icon:SetTexture(texture or FALLBACK_ICON)
    SwapPortrait(texture)
    ring:SetVertexColor(COLOR_RING[1], COLOR_RING[2], COLOR_RING[3])
    nameText:SetText(name or "")
    timer:SetTextColor(1, 1, 1)
    timer:SetText("")
    darkL:SetRotation(math.rad(-180))
    darkR:SetRotation(0) -- parked behind its mask until the 50% mark
    hand:SetRotation(0)
    hand:Show()

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
    RestorePortrait()
    hand:Hide()
    ring:SetAlpha(1)
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
        darkL:SetRotation(math.rad(-180))
        darkR:SetRotation(0)
        hand:Hide()
        ring:SetAlpha(1)
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
        SexyCastbarDB.mode = SexyCastbarDB.mode or "free"
        BuildFrame()
        ApplyMode()

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
    elseif msg == "portrait" then
        if SexyCastbarDB.mode == "portrait" then
            SexyCastbarDB.mode = "free"
            Print("Detached - floating at the saved position.")
        elseif PlayerPortrait then
            SexyCastbarDB.mode = "portrait"
            Print("Wrapping the player portrait. /scb portrait detaches.")
        else
            Print("No player portrait found (unit frame addon?).")
        end
        if unlocked then
            SetUnlocked(false)
        end
        ApplyMode()
        -- Toggling mid-cast: move the icon between our texture and the
        -- portrait to match the new mode.
        if state then
            if SexyCastbarDB.mode == "portrait" then
                SwapPortrait(state.texture)
            else
                RestorePortrait()
            end
        end
    elseif SexyCastbarDB.mode == "portrait" then
        Print("Anchored to the player portrait - /scb portrait detaches, /scb test previews.")
    else
        SetUnlocked(not unlocked)
    end
end
