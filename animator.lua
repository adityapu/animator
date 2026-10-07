--[[
    Animation Editor + RBXM Parser (All-in-One)
    Untuk Delta Executor
    Fitur: Load ID, Load .rbxm, Load .json, Edit Keyframe, Playback, Export
]]

if not game:IsLoaded() then game.Loaded:Wait() end

local CONFIG = {
    DefaultFPS = 30,
    FolderName = "AnimEditor",
}

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local LP = Players.LocalPlayer

local State = {
    Recording = false,
    Playing = false,
    Keyframes = {},
    CurrentFrame = 1,
    FPS = CONFIG.DefaultFPS,
    Loop = false,
}

-- ============================================================
-- BAGIAN 1: RBXM PARSER
-- ============================================================

local function readU8(data, pos) return string.byte(data, pos) end
local function readU16(data, pos)
    local b1, b2 = string.byte(data, pos, pos + 1)
    return b1 + b2 * 256
end
local function readU32(data, pos)
    local b1, b2, b3, b4 = string.byte(data, pos, pos + 3)
    return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end
local function readI32(data, pos)
    local u = readU32(data, pos)
    if u >= 2147483648 then u = u - 4294967296 end
    return u
end
local function readF32(data, pos)
    if string.unpack then
        local ok, val = pcall(string.unpack, "<f", data, pos)
        if ok and val then return val end
    end
    local b1, b2, b3, b4 = string.byte(data, pos, pos + 3)
    local sign = (b1 >= 128) and -1 or 1
    local exp = ((b1 % 128) * 2) + math.floor(b2 / 128)
    local mant = ((b2 % 128) * 65536) + (b3 * 256) + b4
    if exp == 0 then
        if mant == 0 then return 0 end
        return sign * (mant / 8388608) * (2 ^ -126)
    elseif exp == 255 then
        if mant == 0 then return sign * math.huge end
        return 0/0
    end
    return sign * (1 + mant / 8388608) * (2 ^ (exp - 127))
end
local function readF64(data, pos)
    if string.unpack then
        local ok, val = pcall(string.unpack, "<d", data, pos)
        if ok and val then return val end
    end
    return 0
end
local function readRBString(data, pos)
    local len = readU32(data, pos)
    if len == 0 then return "", pos + 4 end
    if len == 4294967295 then return nil, pos + 4 end
    return data:sub(pos + 4, pos + 4 + len - 1), pos + 4 + len
end

-- LZ4 Block Decompression
local function lz4Decompress(src, dstSize)
    local out = {}
    local i = 1
    local n = #src
    local written = 0

    while i <= n do
        local token = string.byte(src, i); i = i + 1
        local litLen = math.floor(token / 16)
        local matchLen = token % 16

        if litLen == 15 then
            local b
            repeat
                if i > n then break end
                b = string.byte(src, i); i = i + 1
                litLen = litLen + b
            until b ~= 255
        end

        if litLen > 0 then
            if i + litLen - 1 > n then
                litLen = n - i + 1
                if litLen <= 0 then break end
            end
            local lit = src:sub(i, i + litLen - 1)
            table.insert(out, lit)
            written = written + #lit
            i = i + litLen
        end

        if i > n then break end
        if i + 1 > n then break end

        local offset = string.byte(src, i) + string.byte(src, i + 1) * 256
        i = i + 2
        if offset == 0 then break end

        if matchLen == 15 then
            local b
            repeat
                if i > n then break end
                b = string.byte(src, i); i = i + 1
                matchLen = matchLen + b
            until b ~= 255
        end
        matchLen = matchLen + 4

        local buf = table.concat(out)
        local bufLen = #buf
        local startPos = bufLen - offset + 1
        if startPos < 1 then break end

        local copied = {}
        for j = 0, matchLen - 1 do
            local srcPos = startPos + j
            if srcPos <= bufLen then
                table.insert(copied, buf:sub(srcPos, srcPos))
            else
                local overlapIdx = srcPos - bufLen
                table.insert(copied, copied[overlapIdx] or "")
            end
        end
        local match = table.concat(copied)
        table.insert(out, match)
        written = written + #match
    end

    local result = table.concat(out)
    if dstSize and written ~= dstSize then
        if written < dstSize then
            result = result .. string.rep("\0", dstSize - written)
        elseif written > dstSize then
            result = result:sub(1, dstSize)
        end
    end
    return result
end

local function parseHeader(data)
    if data:sub(1, 8) ~= "<roblox!" then
        return nil, nil, nil, "Bukan file .rbxm valid"
    end
    local pos = 9
    pos = pos + 2
    local classCount = readU32(data, pos); pos = pos + 4
    local instCount = readU32(data, pos); pos = pos + 4
    return classCount, instCount, pos
end

local function parseSSTR(data, pos, chunkEnd)
    local strings = {}
    local version = readU32(data, pos); pos = pos + 4
    local count = readU32(data, pos); pos = pos + 4
    for i = 1, count do
        if pos >= chunkEnd then break end
        local str, newPos = readRBString(data, pos)
        strings[i] = str or ""
        pos = newPos
    end
    return strings, pos
end

local function parseINST(data, pos, chunkEnd)
    local classes = {}
    local version = readU32(data, pos); pos = pos + 4
    local count = readU32(data, pos); pos = pos + 4
    for i = 1, count do
        if pos >= chunkEnd then break end
        local name, newPos = readRBString(data, pos)
        classes[i] = name or "Unknown"
        pos = newPos + 4
    end
    return classes, pos
end

local function parsePROP(data, pos, chunkEnd, classes, sharedStrings, instCount)
    local instances = {}
    local version = readU32(data, pos); pos = pos + 4
    for i = 0, instCount - 1 do
        instances[i] = {Class = "Unknown", Props = {}}
    end

    while pos < chunkEnd do
        if pos + 12 > chunkEnd then break end
        local instId = readU32(data, pos); pos = pos + 4
        local classIdx = readU32(data, pos); pos = pos + 4
        local propIdx = readU32(data, pos); pos = pos + 4
        local typeId = readU8(data, pos); pos = pos + 1

        if not instances[instId] then
            instances[instId] = {Class = "Unknown", Props = {}}
        end
        if classes[classIdx] then
            instances[instId].Class = classes[classIdx]
        end

        local propName = sharedStrings[propIdx + 1] or ("Prop_" .. propIdx)
        local propValue = nil

        if typeId == 1 then
            local str, newPos = readRBString(data, pos)
            propValue = str or ""
            pos = newPos
        elseif typeId == 2 then
            propValue = readU8(data, pos) ~= 0
            pos = pos + 1
        elseif typeId == 3 then
            propValue = readI32(data, pos); pos = pos + 4
        elseif typeId == 4 then
            propValue = readF32(data, pos); pos = pos + 4
        elseif typeId == 5 then
            propValue = readF64(data, pos); pos = pos + 8
        elseif typeId == 6 then
            local scale = readF32(data, pos); pos = pos + 4
            local offset = readI32(data, pos); pos = pos + 4
            propValue = {Scale = scale, Offset = offset}
        elseif typeId == 7 then
            local xs = readF32(data, pos); pos = pos + 4
            local xo = readI32(data, pos); pos = pos + 4
            local ys = readF32(data, pos); pos = pos + 4
            local yo = readI32(data, pos); pos = pos + 4
            propValue = {X = {Scale = xs, Offset = xo}, Y = {Scale = ys, Offset = yo}}
        elseif typeId == 12 then
            local r = readF32(data, pos); pos = pos + 4
            local g = readF32(data, pos); pos = pos + 4
            local b = readF32(data, pos); pos = pos + 4
            propValue = {R = r, G = g, B = b}
        elseif typeId == 13 then
            local x = readF32(data, pos); pos = pos + 4
            local y = readF32(data, pos); pos = pos + 4
            propValue = {X = x, Y = y}
        elseif typeId == 14 then
            local x = readF32(data, pos); pos = pos + 4
            local y = readF32(data, pos); pos = pos + 4
            local z = readF32(data, pos); pos = pos + 4
            propValue = {X = x, Y = y, Z = z}
        elseif typeId == 15 then
            local x = readF32(data, pos); pos = pos + 4
            local y = readF32(data, pos); pos = pos + 4
            local z = readF32(data, pos); pos = pos + 4
            local r00 = readF32(data, pos); pos = pos + 4
            local r01 = readF32(data, pos); pos = pos + 4
            local r02 = readF32(data, pos); pos = pos + 4
            local r10 = readF32(data, pos); pos = pos + 4
            local r11 = readF32(data, pos); pos = pos + 4
            local r12 = readF32(data, pos); pos = pos + 4
            local r20 = readF32(data, pos); pos = pos + 4
            local r21 = readF32(data, pos); pos = pos + 4
            local r22 = readF32(data, pos); pos = pos + 4
            propValue = {
                X = x, Y = y, Z = z,
                R00 = r00, R01 = r01, R02 = r02,
                R10 = r10, R11 = r11, R12 = r12,
                R20 = r20, R21 = r21, R22 = r22,
            }
        elseif typeId == 17 then
            propValue = readU32(data, pos); pos = pos + 4
        elseif typeId == 18 then
            propValue = readI32(data, pos); pos = pos + 4
        else
            pos = pos + 4
        end

        if propValue ~= nil then
            instances[instId].Props[propName] = propValue
        end
    end
    return instances, pos
end

local function parsePRNT(data, pos, chunkEnd)
    local parents = {}
    local version = readU8(data, pos); pos = pos + 1
    local count = readU32(data, pos); pos = pos + 4
    for i = 1, count do
        if pos + 8 > chunkEnd then break end
        local childId = readI32(data, pos); pos = pos + 4
        local parentId = readI32(data, pos); pos = pos + 4
        parents[childId] = parentId
    end
    return parents, pos
end

local function parseRBXM(data)
    if not data or #data < 16 then
        return nil, "File terlalu kecil"
    end
    local classCount, instCount, pos, err = parseHeader(data)
    if not classCount then return nil, err end

    local classes = {}
    local sharedStrings = {}
    local instances = nil
    local parents = {}

    local guard = 0
    while pos < #data do
        guard = guard + 1
        if guard > 100 then return nil, "Terlalu banyak chunk" end
        if pos + 16 > #data then break end

        local chunkName = data:sub(pos, pos + 3)
        local compressedLen = readU32(data, pos + 4)
        local uncompressedLen = readU32(data, pos + 8)
        pos = pos + 16

        local chunkEnd = pos + compressedLen
        if chunkEnd > #data then chunkEnd = #data end

        local chunkData
        if compressedLen == 0 then
            chunkData = data:sub(pos, chunkEnd - 1)
        else
            local compressed = data:sub(pos, chunkEnd - 1)
            local ok, result = pcall(lz4Decompress, compressed, uncompressedLen)
            if not ok then return nil, "Gagal decompress " .. chunkName end
            chunkData = result
        end

        if chunkName == "SSTR" then
            sharedStrings, _ = parseSSTR(chunkData, 1, #chunkData)
        elseif chunkName == "INST" then
            classes, _ = parseINST(chunkData, 1, #chunkData)
        elseif chunkName == "PROP" then
            instances, _ = parsePROP(chunkData, 1, #chunkData, classes, sharedStrings, instCount)
        elseif chunkName == "PRNT" then
            parents, _ = parsePRNT(chunkData, 1, #chunkData)
        end

        pos = chunkEnd
    end

    if not instances then return nil, "Chunk PROP tidak ditemukan" end
    for childId, parentId in pairs(parents) do
        if instances[childId] then instances[childId].Parent = parentId end
    end
    return instances, nil
end

local function extractAnimation(instances)
    local kfsId = nil
    for id, inst in pairs(instances) do
        if inst.Class == "KeyframeSequence" then kfsId = id; break end
    end
    if not kfsId then return nil, "Tidak ada KeyframeSequence di file" end

    local keyframes = {}
    for id, inst in pairs(instances) do
        if inst.Class == "Keyframe" and inst.Parent == kfsId then
            local time = inst.Props.Time or 0
            local pose = {}
            for pid, pinst in pairs(instances) do
                if pinst.Class == "Pose" and pinst.Parent == id then
                    local poseName = pinst.Props.Name
                    local cf = pinst.Props.CFrame
                    if poseName and cf then
                        pose[poseName] = CFrame.new(
                            cf.X, cf.Y, cf.Z,
                            cf.R00, cf.R01, cf.R02,
                            cf.R10, cf.R11, cf.R12,
                            cf.R20, cf.R21, cf.R22
                        )
                    end
                end
            end
            table.insert(keyframes, {Time = time, Pose = pose})
        end
    end
    if #keyframes == 0 then return nil, "Tidak ada Keyframe" end
    table.sort(keyframes, function(a, b) return a.Time < b.Time end)
    return keyframes, nil
end

-- ============================================================
-- BAGIAN 2: UTILITY
-- ============================================================

local function getRig()
    local char = LP.Character
    if not char then return nil end
    local hum = char:FindFirstChildOfClass("Humanoid")
    return char, hum
end

local function stopAnimations()
    local char, hum = getRig()
    if not hum then return end
    for _, t in ipairs(hum:GetPlayingAnimationTracks()) do
        pcall(function() t:Stop(0) end)
    end
end

local function capturePose()
    local char = LP.Character
    if not char then return nil end
    local pose = {}
    for _, m in ipairs(char:GetDescendants()) do
        if m:IsA("Motor6D") then pose[m.Name] = m.Transform end
    end
    return pose
end

local function applyPose(pose)
    local char = LP.Character
    if not char or not pose then return end
    for _, m in ipairs(char:GetDescendants()) do
        if m:IsA("Motor6D") and pose[m.Name] then m.Transform = pose[m.Name] end
    end
end

local function resetPose()
    local char = LP.Character
    if not char then return end
    for _, m in ipairs(char:GetDescendants()) do
        if m:IsA("Motor6D") then m.Transform = CFrame.new() end
    end
end

-- ============================================================
-- BAGIAN 3: GUI
-- ============================================================

local function createGUI()
    local ScreenGui = Instance.new("ScreenGui")
    ScreenGui.Name = "AnimEditorAllInOne"
    ScreenGui.ResetOnSpawn = false
    ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    ScreenGui.Parent = LP:WaitForChild("PlayerGui")

    local Main = Instance.new("Frame")
    Main.Size = UDim2.new(0, 450, 0, 500)
    Main.Position = UDim2.new(0.5, -225, 0.5, -250)
    Main.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
    Main.BorderSizePixel = 0
    Main.Active = true
    Main.Draggable = true
    Main.Parent = ScreenGui

    local Corner = Instance.new("UICorner")
    Corner.CornerRadius = UDim.new(0, 8)
    Corner.Parent = Main

    local Title = Instance.new("Frame")
    Title.Size = UDim2.new(1, 0, 0, 32)
    Title.BackgroundColor3 = Color3.fromRGB(35, 35, 45)
    Title.BorderSizePixel = 0
    Title.Parent = Main
    local TitleCorner = Instance.new("UICorner")
    TitleCorner.CornerRadius = UDim.new(0, 8)
    TitleCorner.Parent = Title

    local TitleText = Instance.new("TextLabel")
    TitleText.Size = UDim2.new(1, -40, 1, 0)
    TitleText.Position = UDim2.new(0, 10, 0, 0)
    TitleText.BackgroundTransparency = 1
    TitleText.Text = "🎬 Animation Editor (All-in-One)"
    TitleText.TextColor3 = Color3.fromRGB(255, 255, 255)
    TitleText.TextXAlignment = Enum.TextXAlignment.Left
    TitleText.Font = Enum.Font.GothamBold
    TitleText.TextSize = 13
    TitleText.Parent = Title

    local Close = Instance.new("TextButton")
    Close.Size = UDim2.new(0, 28, 0, 28)
    Close.Position = UDim2.new(1, -32, 0, 2)
    Close.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
    Close.Text = "✕"
    Close.TextColor3 = Color3.fromRGB(255, 255, 255)
    Close.Font = Enum.Font.GothamBold
    Close.TextSize = 14
    Close.BorderSizePixel = 0
    Close.Parent = Title
    local CloseCorner = Instance.new("UICorner")
    CloseCorner.CornerRadius = UDim.new(0, 6)
    CloseCorner.Parent = Close
    Close.MouseButton1Click:Connect(function()
        ScreenGui:Destroy()
        stopAnimations()
        resetPose()
    end)

    local Status = Instance.new("TextLabel")
    Status.Name = "Status"
    Status.Size = UDim2.new(1, -20, 0, 20)
    Status.Position = UDim2.new(0, 10, 0, 36)
    Status.BackgroundTransparency = 1
    Status.Text = "Ready | Frames: 0"
    Status.TextColor3 = Color3.fromRGB(150, 200, 255)
    Status.TextXAlignment = Enum.TextXAlignment.Left
    Status.Font = Enum.Font.Gotham
    Status.TextSize = 11
    Status.Parent = Main

    local function makeButton(text, pos, size, color, callback)
        local btn = Instance.new("TextButton")
        btn.Size = size
        btn.Position = pos
        btn.BackgroundColor3 = color
        btn.Text = text
        btn.TextColor3 = Color3.fromRGB(255, 255, 255)
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 11
        btn.BorderSizePixel = 0
        btn.Parent = Main
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, 6)
        c.Parent = btn
        btn.MouseButton1Click:Connect(callback)
        return btn
    end

    -- Baris 1: Record & Edit
    makeButton("⏺ Record", UDim2.new(0, 10, 0, 62), UDim2.new(0, 95, 0, 28), Color3.fromRGB(200, 60, 60), function()
        if State.Recording then
            table.insert(State.Keyframes, {Pose = capturePose(), Time = os.clock()})
            State.CurrentFrame = #State.Keyframes
            Status.Text = "Recorded! Total: " .. #State.Keyframes
        else
            Status.Text = "⚠️ Tekan Start Record dulu!"
        end
    end)

    local RecordBtn
    RecordBtn = makeButton("▶ Start Rec", UDim2.new(0, 110, 0, 62), UDim2.new(0, 95, 0, 28), Color3.fromRGB(60, 160, 60), function()
        State.Recording = not State.Recording
        RecordBtn.Text = State.Recording and "⏹ Stop Rec" or "▶ Start Rec"
        RecordBtn.BackgroundColor3 = State.Recording and Color3.fromRGB(200, 60, 60) or Color3.fromRGB(60, 160, 60)
        Status.Text = State.Recording and "🔴 Recording..." or "Stopped"
    end)

    makeButton("💾 Update Frame", UDim2.new(0, 210, 0, 62), UDim2.new(0, 110, 0, 28), Color3.fromRGB(60, 120, 200), function()
        if #State.Keyframes == 0 or State.CurrentFrame < 1 then
            Status.Text = "⚠️ Pilih frame dulu!"
            return
        end
        State.Keyframes[State.CurrentFrame].Pose = capturePose()
        Status.Text = "Frame " .. State.CurrentFrame .. " diupdate!"
    end)

    makeButton("▶ Play", UDim2.new(0, 325, 0, 62), UDim2.new(0, 55, 0, 28), Color3.fromRGB(60, 120, 200), function()
        if State.Playing or #State.Keyframes == 0 then return end
        State.Playing = true
        stopAnimations()
        task.spawn(function()
            repeat
                for i, kf in ipairs(State.Keyframes) do
                    if not State.Playing then break end
                    applyPose(kf.Pose)
                    task.wait(1 / State.FPS)
                end
            until not State.Loop or not State.Playing
            State.Playing = false
        end)
    end)

    makeButton("⏹", UDim2.new(0, 385, 0, 62), UDim2.new(0, 55, 0, 28), Color3.fromRGB(120, 60, 60), function()
        State.Playing = false
        stopAnimations()
    end)

    -- Baris 2: Load ID + Load .rbxm
    local IDBox = Instance.new("TextBox")
    IDBox.Size = UDim2.new(0, 140, 0, 28)
    IDBox.Position = UDim2.new(0, 10, 0, 98)
    IDBox.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
    IDBox.PlaceholderText = "Animation ID..."
    IDBox.Text = ""
    IDBox.TextColor3 = Color3.fromRGB(255, 255, 255)
    IDBox.Font = Enum.Font.Gotham
    IDBox.TextSize = 11
    IDBox.BorderSizePixel = 0
    IDBox.Parent = Main
    local IDBoxCorner = Instance.new("UICorner")
    IDBoxCorner.CornerRadius = UDim.new(0, 4)
    IDBoxCorner.Parent = IDBox

    makeButton("📥 Load ID", UDim2.new(0, 155, 0, 98), UDim2.new(0, 80, 0, 28), Color3.fromRGB(120, 90, 60), function()
        local id = IDBox.Text:match("%d+")
        if not id then Status.Text = "⚠️ ID tidak valid!" return end
        Status.Text = "⏳ Loading ID " .. id .. "..."
        task.spawn(function()
            local ok, objects = pcall(function()
                return game:GetObjects("rbxassetid://" .. id)
            end)
            if not ok or not objects or #objects == 0 then
                Status.Text = "❌ Gagal ambil asset"
                return
            end
            local kfs
            for _, obj in ipairs(objects) do
                if obj:IsA("KeyframeSequence") then kfs = obj; break end
                for _, c in ipairs(obj:GetDescendants()) do
                    if c:IsA("KeyframeSequence") then kfs = c; break end
                end
            end
            if not kfs then Status.Text = "❌ Bukan KeyframeSequence" return end
            local newKFs = {}
            for _, kf in ipairs(kfs:GetChildren()) do
                if kf:IsA("Keyframe") then
                    local pose = {}
                    for _, p in ipairs(kf:GetChildren()) do
                        if p:IsA("Pose") then pose[p.Name] = p.CFrame end
                    end
                    table.insert(newKFs, {Pose = pose, Time = kf.Time})
                end
            end
            table.sort(newKFs, function(a, b) return a.Time < b.Time end)
            State.Keyframes = newKFs
            State.CurrentFrame = 1
            Status.Text = "✅ Load ID OK! Frames: " .. #newKFs
            refreshList()
        end)
    end)

    makeButton("📦 Load .rbxm", UDim2.new(0, 240, 0, 98), UDim2.new(0, 90, 0, 28), Color3.fromRGB(140, 80, 60), function()
        if not listfiles then Status.Text = "❌ listfiles tidak tersedia" return end
        local ok, files = pcall(listfiles, "")
        if not ok then Status.Text = "❌ listfiles error" return end
        local rbxmFiles = {}
        for _, f in ipairs(files) do
            if type(f) == "string" and f:match("%.rbxm$") then
                table.insert(rbxmFiles, f)
            end
        end
        if #rbxmFiles == 0 then Status.Text = "⚠️ Tidak ada .rbxm di workspace" return end
        local target = rbxmFiles[1]
        Status.Text = "⏳ Parsing " .. target .. "..."
        task.spawn(function()
            local ok2, data = pcall(readfile, target)
            if not ok2 or not data then Status.Text = "❌ Gagal baca file" return end
            local instances, err = parseRBXM(data)
            if not instances then Status.Text = "❌ " .. tostring(err) return end
            local kfs, err2 = extractAnimation(instances)
            if not kfs then Status.Text = "❌ " .. tostring(err2) return end
            State.Keyframes = kfs
            State.CurrentFrame = 1
            Status.Text = "✅ " .. target .. " OK! Frames: " .. #kfs
            refreshList()
        end)
    end)

    makeButton("📂 Load .json", UDim2.new(0, 335, 0, 98), UDim2.new(0, 105, 0, 28), Color3.fromRGB(90, 60, 140), function()
        if not readfile or not listfiles then Status.Text = "❌ file API tidak tersedia" return end
        local ok, files = pcall(listfiles, "")
        if not ok then return end
        local jsonFiles = {}
        for _, f in ipairs(files) do
            if type(f) == "string" and f:match("%.json$") then table.insert(jsonFiles, f) end
        end
        if #jsonFiles == 0 then Status.Text = "⚠️ Tidak ada .json" return end
        local target = jsonFiles[1]
        local ok2, data = pcall(function() return HttpService:JSONDecode(readfile(target)) end)
        if not ok2 then Status.Text = "❌ Gagal parse json" return end
        State.Keyframes = {}
        State.FPS = data.FPS or State.FPS
        for _, poseData in ipairs(data.Keyframes) do
            local pose = {}
            for name, comps in pairs(poseData) do
                pose[name] = CFrame.new(unpack(comps))
            end
            table.insert(State.Keyframes, {Pose = pose, Time = 0})
        end
        Status.Text = "✅ Loaded " .. target .. "! Frames: " .. #State.Keyframes
        refreshList()
    end)

    -- Baris 3: FPS, Loop, Save, Export, Clear
    local FPSBox = Instance.new("TextBox")
    FPSBox.Size = UDim2.new(0, 50, 0, 28)
    FPSBox.Position = UDim2.new(0, 10, 0, 135)
    FPSBox.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
    FPSBox.Text = tostring(State.FPS)
    FPSBox.TextColor3 = Color3.fromRGB(255, 255, 255)
    FPSBox.Font = Enum.Font.Gotham
    FPSBox.TextSize = 11
    FPSBox.BorderSizePixel = 0
    FPSBox.Parent = Main
    local FPSBoxCorner = Instance.new("UICorner")
    FPSBoxCorner.CornerRadius = UDim.new(0, 4)
    FPSBoxCorner.Parent = FPSBox
    FPSBox.FocusLost:Connect(function()
        local n = tonumber(FPSBox.Text)
        if n and n >= 1 and n <= 120 then
            State.FPS = math.floor(n)
            Status.Text = "FPS: " .. State.FPS
        else
            FPSBox.Text = tostring(State.FPS)
        end
    end)

    local LoopBtn = makeButton("🔁 OFF", UDim2.new(0, 65, 0, 135), UDim2.new(0, 70, 0, 28), Color3.fromRGB(70, 70, 90), function()
        State.Loop = not State.Loop
        LoopBtn.Text = "🔁 " .. (State.Loop and "ON" or "OFF")
        LoopBtn.BackgroundColor3 = State.Loop and Color3.fromRGB(60, 140, 200) or Color3.fromRGB(70, 70, 90)
    end)

    makeButton("💾 Save", UDim2.new(0, 140, 0, 135), UDim2.new(0, 70, 0, 28), Color3.fromRGB(60, 120, 60), function()
        if #State.Keyframes == 0 then Status.Text = "⚠️ Tidak ada data" return end
        local data = {FPS = State.FPS, Keyframes = {}}
        for _, kf in ipairs(State.Keyframes) do
            local poseData = {}
            for name, cf in pairs(kf.Pose) do poseData[name] = {cf:GetComponents()} end
            table.insert(data.Keyframes, poseData)
        end
        if writefile then
            local fname = CONFIG.FolderName .. "_" .. LP.Name .. ".json"
            writefile(fname, HttpService:JSONEncode(data))
            Status.Text = "💾 Saved: " .. fname
        end
    end)

    makeButton("📤 Export", UDim2.new(0, 215, 0, 135), UDim2.new(0, 80, 0, 28), Color3.fromRGB(90, 60, 140), function()
        if #State.Keyframes == 0 then Status.Text = "⚠️ Tidak ada data" return end
        local lines = {"return {"}
        for _, kf in ipairs(State.Keyframes) do
            local parts = {}
            for name, cf in pairs(kf.Pose) do
                local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
                table.insert(parts, string.format('[%q]={%f,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f}',
                    name, x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22))
            end
            table.insert(lines, "{" .. table.concat(parts, ",") .. "},")
        end
        table.insert(lines, "}")
        if writefile then
            local fname = CONFIG.FolderName .. "_export_" .. LP.Name .. ".lua"
            writefile(fname, table.concat(lines, "\n"))
            Status.Text = "📤 Exported: " .. fname
        end
    end)

    makeButton("🗑 Clear", UDim2.new(0, 300, 0, 135), UDim2.new(0, 140, 0, 28), Color3.fromRGB(150, 50, 50), function()
        State.Keyframes = {}
        State.CurrentFrame = 1
        resetPose()
        refreshList()
        Status.Text = "Cleared."
    end)

    -- Scroll list
    local Scroll = Instance.new("ScrollingFrame")
    Scroll.Name = "Scroll"
    Scroll.Size = UDim2.new(1, -20, 1, -180)
    Scroll.Position = UDim2.new(0, 10, 0, 172)
    Scroll.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
    Scroll.BorderSizePixel = 0
    Scroll.ScrollBarThickness = 6
    Scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    Scroll.Parent = Main
    local ScrollCorner = Instance.new("UICorner")
    ScrollCorner.CornerRadius = UDim.new(0, 6)
    ScrollCorner.Parent = Scroll

    local ListLayout = Instance.new("UIListLayout")
    ListLayout.Padding = UDim.new(0, 4)
    ListLayout.SortOrder = Enum.SortOrder.LayoutOrder
    ListLayout.Parent = Scroll

    -- Fungsi refresh (forward declaration)
    refreshList = function()
        for _, c in ipairs(Scroll:GetChildren()) do
            if c:IsA("TextButton") then c:Destroy() end
        end
        for i, kf in ipairs(State.Keyframes) do
            local row = Instance.new("TextButton")
            row.Size = UDim2.new(1, -8, 0, 28)
            row.BackgroundColor3 = i == State.CurrentFrame and Color3.fromRGB(60, 100, 160) or Color3.fromRGB(40, 40, 50)
            row.Text = "  Frame " .. i .. "  (t=" .. string.format("%.2f", kf.Time or 0) .. ")"
            row.TextColor3 = Color3.fromRGB(255, 255, 255)
            row.TextXAlignment = Enum.TextXAlignment.Left
            row.Font = Enum.Font.Gotham
            row.TextSize = 11
            row.BorderSizePixel = 0
            row.LayoutOrder = i
            row.Parent = Scroll
            local rc = Instance.new("UICorner")
            rc.CornerRadius = UDim.new(0, 4)
            rc.Parent = row
            row.MouseButton1Click:Connect(function()
                State.CurrentFrame = i
                applyPose(kf.Pose)
                for _, r in ipairs(Scroll:GetChildren()) do
                    if r:IsA("TextButton") then
                        r.BackgroundColor3 = r.LayoutOrder == i and Color3.fromRGB(60, 100, 160) or Color3.fromRGB(40, 40, 50)
                    end
                end
                Status.Text = "Preview frame " .. i
            end)
        end
        Scroll.CanvasSize = UDim2.new(0, 0, 0, #State.Keyframes * 32 + 8)
        Status.Text = "Frames: " .. #State.Keyframes
    end

    return ScreenGui
end

-- ============================================================
-- BAGIAN 4: INIT
-- ============================================================

local refreshList  -- forward declaration global

local gui = createGUI()
print("[AnimEditor All-in-One] Loaded!")
