--[[
    AI NPCs — HUD overlays

    3D2D nametag above every AI NPC, a thinking indicator, a subtitle bubble that
    shows the line while the voice is playing, and a "Press E to talk" prompt when
    you are close and looking at one.
]]

surface.CreateFont("AINPC_Name3D", { font = "Roboto", size = 64, weight = 700, outline = true })
surface.CreateFont("AINPC_Sub3D",  { font = "Roboto", size = 40, weight = 500, outline = true })
surface.CreateFont("AINPC_Bubble", { font = "Roboto", size = 32, weight = 500, outline = true })
surface.CreateFont("AINPC_Prompt", { font = "Roboto", size = 22, weight = 600 })
surface.CreateFont("AINPC_PromptSmall", { font = "Roboto", size = 16, weight = 400 })

local MAX_DRAW_DIST   = 1200
local MAX_DRAW_DISTSQ = MAX_DRAW_DIST * MAX_DRAW_DIST

-- Greedy word wrap. Character count is good enough here: the text is drawn in a
-- 3D2D space, and measuring fonts there costs more than it buys.
local function wrapText(text, maxChars)
    local lines, current = {}, ""
    for word in string.gmatch(text, "%S+") do
        if current == "" then
            current = word
        elseif #current + 1 + #word <= maxChars then
            current = current .. " " .. word
        else
            table.insert(lines, current)
            current = word
        end
    end
    if current ~= "" then table.insert(lines, current) end
    return lines
end

local function drawNameAbove(ent, name, thinking, speech)
    local top = ent:GetPos() + Vector(0, 0, ent:OBBMaxs().z + 12)
    local ang = EyeAngles()
    ang:RotateAroundAxis(ang:Forward(), 90)
    ang:RotateAroundAxis(ang:Right(),   90)

    cam.Start3D2D(top, Angle(0, ang.y, 90), 0.1)
        local nameY = 0

        -- Subtitle bubble, drawn above the nametag for as long as the voice line runs.
        if speech and #speech > 0 then
            local y = -#speech * 44 - 16
            for _, line in ipairs(speech) do
                draw.SimpleText(line, "AINPC_Bubble", 0, y, Color(255, 255, 255, 235), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                y = y + 44
            end
        end

        draw.SimpleText(name, "AINPC_Name3D", 0, nameY, Color(255, 220, 130), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        draw.SimpleText("AI NPC", "AINPC_Sub3D", 0, nameY + 40, Color(200, 200, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

        if thinking then
            -- A bubble instead of three floating dots: it reads as "this NPC is
            -- working on an answer" from across the map.
            local phase = (RealTime() * 3) % (math.pi * 2)
            local boxW, boxH = 420, 74
            local boxY = nameY + 74

            draw.RoundedBox(10, -boxW / 2, boxY, boxW, boxH, Color(18, 18, 22, 200))
            draw.SimpleText("thinking", "AINPC_Bubble", -70, boxY + boxH / 2,
                Color(255, 220, 130, 230), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

            for i = 0, 2 do
                local alpha = math.floor(((math.sin(phase + i * 0.7) + 1) / 2) * 255)
                draw.SimpleText("●", "AINPC_Sub3D", 30 + i * 34, boxY + boxH / 2,
                    Color(255, 220, 130, alpha), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            end
        end
    cam.End3D2D()
end

hook.Add("PostDrawTranslucentRenderables", "AINPC_Nametags", function(depth, sky)
    if sky then return end
    local ply = LocalPlayer()
    if not IsValid(ply) then return end

    local eye = ply:EyePos()
    local now = RealTime()

    for _, ent in ipairs(ents.GetAll()) do
        if IsValid(ent) and ent:GetNWBool("IsAINPC", false) then
            if ent:GetPos():DistToSqr(eye) <= MAX_DRAW_DISTSQ then
                local speech = nil
                local last = AINPCS.LastChat and AINPCS.LastChat[ent:EntIndex()]
                if last and last.text and not last.isError and last.spokenUntil and now < last.spokenUntil then
                    speech = wrapText(last.text, 44)
                end

                drawNameAbove(
                    ent,
                    ent:GetNWString("AINPCName", "NPC"),
                    ent:GetNWBool("AINPCThinking", false),
                    speech
                )
            end
        end
    end
end)

-- =============================================================================
-- "Press E to talk" HUD prompt
-- =============================================================================

hook.Add("HUDPaint", "AINPC_UsePrompt", function()
    local ply = LocalPlayer()
    if not IsValid(ply) or not ply:Alive() then return end

    local tr = ply:GetEyeTrace()
    local ent = tr.Entity
    if not IsValid(ent) then return end
    if not ent:GetNWBool("IsAINPC", false) then return end
    if ply:EyePos():Distance(ent:GetPos()) > 180 then return end

    local name = ent:GetNWString("AINPCName", "NPC")
    local isThinking = ent:GetNWBool("AINPCThinking", false)

    local cx, cy = ScrW() / 2, ScrH() / 2 + 80
    local w, h = 280, 56

    draw.RoundedBox(8, cx - w / 2, cy, w, h, Color(20, 20, 25, 200))
    draw.SimpleText(
        isThinking and (name .. " is thinking…") or ("Press E to talk to " .. name),
        "AINPC_Prompt",
        cx, cy + 14,
        Color(255, 220, 130),
        TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER
    )
    draw.SimpleText(
        "or just type in chat when you're nearby",
        "AINPC_PromptSmall",
        cx, cy + 38,
        Color(180, 180, 180),
        TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER
    )
end)
