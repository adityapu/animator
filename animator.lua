--[[
    Animation Editor + RBXM Parser (ZSTD Support)
    Untuk Delta Executor
    Cara pakai: loadstring(game:HttpGet("URL_RAW_KAMU"))()
]]

if not game:IsLoaded() then game.Loaded:Wait() end

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local LP = Players.LocalPlayer

local CONFIG = { DefaultFPS = 30, FolderName = "AnimEditor" }

local State = {
    Recording = false,
    Playing = false,
    Keyframes = {},
    CurrentFrame = 1,
    FPS = CONFIG.DefaultFPS,
    Loop = false,
}

-- ============================================================
-- 1. BASE64 ENCODER (untuk trik ZSTD)
-- ============================================================
local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function base64Encode(data)
    local result = {}
    local n = #data
    for i = 1, n, 3 do
        local b1 = string.byte(data, i) or 0
        local b2 = string.byte(data, i + 1) or 0
        local b3 = string.byte(data, i + 2) or 0
        local byte1 = math.floor(b1 / 4)
        local byte2 = ((b1 % 4) * 16) + math.floor(b2 / 16)
        local byte3 = ((b2 % 16) * 4) + math.floor(b3 / 64)
        local byte4 = b3 % 64
        table.insert(result, B64_CHARS:sub(byte1 + 1, byte1 + 1))
        table.insert(result, B64_CHARS:sub(byte2 + 1, byte2 + 1))
        if i + 1 <= n then
            table.insert(result, B64_CHARS:sub(byte3 + 1, byte3 + 1))
        else
            table.insert(result, "=")
        end
        if i + 2 <= n then
            table.insert(result, B64_CHARS:sub(byte4 + 1, byte4 + 1))
        else
            table.insert(result, "=")
        end
    end
    return table.concat(result)
end

-- ============================================================
-- 2. ZSTD DECOMPRESS (via Roblox native)
-- ============================================================
local function zstdDecompress(compressed)
    -- Cek magic ZSTD (opsional, untuk validasi)
    local magic = compressed:sub(1, 4)
    -- ZSTD magic: 28 B5 2F FD (big-endian) -> FD 2F B5 28 (little-endian)
    -- Tapi kita coba saja, kalau gagal berarti bukan ZSTD
    
    local b64 = base64Encode(compressed)
    local json = string.format('{"m":null,"t":"buffer","zbase64":"%s"}', b64)
    
    local ok, decoded = pcall(function()
        return HttpService:JSONDecode(json)
    end)
    
    if not ok or not decoded then
        return nil, "JSONDecode gagal"
    end
    
    if typeof(decoded) == "buffer" then
        return buffer.tostring(decoded)
    end
    return nil, "Hasil bukan buffer"
end

-- ============================================================
-- 3. LZ4 DECOMPRESS (fallback untuk file lama)
-- ============================================================
local function lz4Decompress(src, dstSize)
    local out = {}
    local i, n, written = 1, #src, 0

    while i <= n do
        local token = string.byte(src, i); i = i + 1
        local litLen = math.floor(token / 16)
        local matchLen = token % 16

        if litLen == 15 then
            local b; repeat b = string.byte(src, i); i = i + 1; litLen = litLen + b until b ~= 255
        end

        if litLen > 0 then
            if i + litLen - 1 > n then litLen = n - i + 1; if litLen <= 0 then break end end
            local lit = src:sub(i, i + litLen - 1)
            table.insert(out, lit); written = written + #lit; i = i + litLen
        end

        if i > n then break end
        if i + 1 > n then break end

        local offset = string.byte(src, i) + string.byte(src, i + 1) * 256; i = i + 2
        if offset == 0 then break end

        if matchLen == 15 then
            local b; repeat b = string.byte(src, i); i = i + 1; matchLen = matchLen + b until b ~= 255
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
                table.insert(copied, copied[srcPos - bufLen] or "")
            end
        end
        local match = table.concat(copied)
        table.insert(out, match); written = written + #match
    end

    local result = table.concat(out)
    if dstSize and written ~= dstSize then
        if written < dstSize then result = result .. string.rep("\0", dstSize - written)
        elseif written > dstSize then result = result:sub(1, dstSize) end
    end
    return result
end

-- ============================================================
-- 4. RBXM PARSER (dengan deteksi ZSTD/LZ4 otomatis)
-- ============================================================
local function readU8(d, p) return string.byte(d, p) end
local function readU32(d, p)
    local a,b,c,e = string.byte(d, p, p+3)
    return a + b*256 + c*65536 + e*16777216
end
local function readI32(d, p)
    local u = readU32(d, p); if u >= 2147483648 then u = u - 4294967296 end; return u
end
local function readF32(d, p)
    if string.unpack then local ok,v = pcall(string.unpack,"<f",d,p); if ok then return v end end
    local b1,b2,b3,b4 = string.byte(d,p,p+3)
    local sign = (b1 >= 128) and -1 or 1
    local exp = ((b1 % 128) * 2) + math.floor(b2 / 128)
    local mant = ((b2 % 128) * 65536) + (b3 * 256) + b4
    if exp == 0 then if mant == 0 then return 0 end; return sign*(mant/8388608)*(2^-126) end
    if exp == 255 then if mant == 0 then return sign*math.huge end; return 0/0 end
    return sign * (1 + mant/8388608) * (2^(exp-127))
end
local function readF64(d, p)
    if string.unpack then local ok,v = pcall(string.unpack,"<d",d,p); if ok then return v end end
    return 0
end
local function readRBString(d, p)
    local len = readU32(d, p)
    if len == 0 then return "", p + 4 end
    if len == 4294967295 then return nil, p + 4 end
    return d:sub(p+4, p+4+len-1), p + 4 + len
end

local function decompressChunk(compressed, uncompressedLen)
    -- Coba ZSTD dulu
    local magic = compressed:sub(1, 4)
    -- ZSTD magic little-endian: FD 2F B5 28
    if magic == "\253\047\181\040" then
        local result, err = zstdDecompress(compressed)
        if result then return result end
        warn("[RBXM] ZSTD gagal: " .. tostring(err))
    end
    -- Fallback LZ4
    return lz4Decompress(compressed, uncompressedLen)
end

local function parseRBXM(data)
    if not data or #data < 16 then return nil, "File terlalu kecil" end
    if data:sub(1, 8) ~= "<roblox!" then return nil, "Bukan file .rbxm valid" end

    local pos = 9
    pos = pos + 2 -- skip versi

    -- Baca class count & instance count (mungkin berbeda di versi ZSTD)
    local classCount = readU32(data, pos); pos = pos + 4
    local instCount = readU32(data, pos); pos = pos + 4

    -- Kadang ada 2 byte tambahan di versi baru
    -- Kita coba deteksi dengan mencari chunk META/SSTR/INST/PROP/PRNT
    local chunkStart = pos
    -- Cek apakah chunk name valid
    local validChunks = {META=true, SSTR=true, INST=true, PROP=true, PRNT=true, ["END\0"]=true}
    local name4 = data:sub(chunkStart, chunkStart+3)
    if not validChunks[name4] then
        -- Coba geser 2 byte
        chunkStart = chunkStart + 2
        name4 = data:sub(chunkStart, chunkStart+3)
    end
    pos = chunkStart

    local classes, sharedStrings, instances, parents = {}, {}, nil, {}

    local guard = 0
    while pos < #data do
        guard = guard + 1; if guard > 100 then return nil, "Terlalu banyak chunk" end
        if pos + 16 > #data then break end

        local chunkName = data:sub(pos, pos+3)
        local compressedLen = readU32(data, pos+4)
        local uncompressedLen = readU32(data, pos+8)
        pos = pos + 16

        local chunkEnd = pos + compressedLen
        if chunkEnd > #data then chunkEnd = #data end

        local chunkData
        if compressedLen == 0 then
            chunkData = data:sub(pos, chunkEnd-1)
        else
            local compressed = data:sub(pos, chunkEnd-1)
            local ok, result = pcall(decompressChunk, compressed, uncompressedLen)
            if not ok then return nil, "Gagal decompress " .. chunkName end
            chunkData = result
        end

        if chunkName == "SSTR" then
            local v = readU32(chunkData, 1); local p = 5
            local count = readU32(chunkData, p); p = p + 4
            for i = 1, count do
                if p >= #chunkData then break end
                local s, np = readRBString(chunkData, p); sharedStrings[i] = s or ""; p = np
            end
        elseif chunkName == "INST" then
            local v = readU32(chunkData, 1); local p = 5
            local count = readU32(chunkData, p); p = p + 4
            for i = 1, count do
                if p >= #chunkData then break end
                local s, np = readRBString(chunkData, p); classes[i] = s or "Unknown"; p = np + 4
            end
        elseif chunkName == "PROP" then
            instances = {}
            local v = readU32(chunkData, 1); local p = 5
            for i = 0, instCount-1 do instances[i] = {Class="Unknown", Props={}} end
            while p < #chunkData do
                if p + 12 > #chunkData then break end
                local instId = readU32(chunkData, p); p = p + 4
                local classIdx = readU32(chunkData, p); p = p + 4
                local propIdx = readU32(chunkData, p); p = p + 4
                local typeId = readU8(chunkData, p); p = p + 1
                if not instances[instId] then instances[instId] = {Class="Unknown", Props={}} end
                if classes[classIdx] then instances[instId].Class = classes[classIdx] end
                local propName = sharedStrings[propIdx+1] or ("Prop_"..propIdx)
                local propValue = nil
                if typeId == 1 then local s, np = readRBString(chunkData, p); propValue = s or ""; p = np
                elseif typeId == 2 then propValue = readU8(chunkData, p) ~= 0; p = p + 1
                elseif typeId == 3 then propValue = readI32(chunkData, p); p = p + 4
                elseif typeId == 4 then propValue = readF32(chunkData, p); p = p + 4
                elseif typeId == 5 then propValue = readF64(chunkData, p); p = p + 8
                elseif typeId == 14 then
                    local x,y,z = readF32(chunkData,p), readF32(chunkData,p+4), readF32(chunkData,p+8); p = p + 12
                    propValue = {X=x, Y=y, Z=z}
                elseif typeId == 15 then
                    local x,y,z = readF32(chunkData,p), readF32(chunkData,p+4), readF32(chunkData,p+8); p = p + 12
                    local r00,r01,r02 = readF32(chunkData,p), readF32(chunkData,p+4), readF32(chunkData,p+8); p = p + 12
                    local r10,r11,r12 = readF32(chunkData,p), readF32(chunkData,p+4), readF32(chunkData,p+8); p = p + 12
                    local r20,r21,r22 = readF32(chunkData,p), readF32(chunkData,p+4), readF32(chunkData,p+8); p = p + 12
                    propValue = {X=x,Y=y,Z=z,R00=r00,R01=r01,R02=r02,R10=r10,R11=r11,R12=r12,R20=r20,R21=r21,R22=r22}
                elseif typeId == 17 then propValue = readU32(chunkData, p); p = p + 4
                elseif typeId == 18 then propValue = readI32(chunkData, p); p = p + 4
                else p = p + 4 end
                if propValue ~= nil then instances[instId].Props[propName] = propValue end
            end
        elseif chunkName == "PRNT" then
            local v = readU8(chunkData, 1); local p = 2
            local count = readU32(chunkData, p); p = p + 4
            for i = 1, count do
                if p + 8 > #chunkData then break end
                local childId = readI32(chunkData, p); p = p + 4
                local parentId = readI32(chunkData, p); p = p + 4
                parents[childId] = parentId
            end
        end
        pos = chunkEnd
    end

    if not instances then return nil, "Chunk PROP tidak ditemukan" end
    for cid, pid in pairs(parents) do if instances[cid] then instances[cid].Parent = pid end end
    return instances, nil
end

local function extractAnimation(instances)
    local kfsId = nil
    for id, inst in pairs(instances) do if inst.Class == "KeyframeSequence" then kfsId = id; break end end
    if not kfsId then return nil, "Tidak ada KeyframeSequence" end
    local keyframes = {}
    for id, inst in pairs(instances) do
        if inst.Class == "Keyframe" and inst.Parent == kfsId then
            local time = inst.Props.Time or 0
            local pose = {}
            for pid, pinst in pairs(instances) do
                if pinst.Class == "Pose" and pinst.Parent == id then
                    local pn = pinst.Props.Name
                    local cf = pinst.Props.CFrame
                    if pn and cf then
                        pose[pn] = CFrame.new(cf.X,cf.Y,cf.Z,cf.R00,cf.R01,cf.R02,cf.R10,cf.R11,cf.R12,cf.R20,cf.R21,cf.R22)
                    end
                end
            end
            table.insert(keyframes, {Time=time, Pose=pose})
        end
    end
    if #keyframes == 0 then return nil, "Tidak ada Keyframe" end
    table.sort(keyframes, function(a,b) return a.Time < b.Time end)
    return keyframes, nil
end

-- ============================================================
-- 5. UTILITY ANIMASI
-- ============================================================
local function getRig()
    local char = LP.Character; if not char then return nil end
    return char, char:FindFirstChildOfClass("Humanoid")
end
local function stopAnimations()
    local char, hum = getRig(); if not hum then return end
    for _, t in ipairs(hum:GetPlayingAnimationTracks()) do pcall(function() t:Stop(0) end) end
end
local function capturePose()
    local char = LP.Character; if not char then return nil end
    local pose = {}
    for _, m in ipairs(char:GetDescendants()) do if m:IsA("Motor6D") then pose[m.Name] = m.Transform end end
    return pose
end
local function applyPose(pose)
    local char = LP.Character; if not char or not pose then return end
    for _, m in ipairs(char:GetDescendants()) do
        if m:IsA("Motor6D") and pose[m.Name] then m.Transform = pose[m.Name] end
    end
end
local function resetPose()
    local char = LP.Character; if not char then return end
    for _, m in ipairs(char:GetDescendants()) do if m:IsA("Motor6D") then m.Transform = CFrame.new() end end
end

-- ============================================================
-- 6. GUI
-- ============================================================
local refreshList -- forward declaration

local function createGUI()
    local ScreenGui = Instance.new("ScreenGui")
    ScreenGui.Name = "AnimEditorZSTD"
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
    local Corner = Instance.new("UICorner"); Corner.CornerRadius = UDim.new(0, 8); Corner.Parent = Main

    local Title = Instance.new("Frame")
    Title.Size = UDim2.new(1, 0, 0, 32)
    Title.BackgroundColor3 = Color3.fromRGB(35, 35, 45)
    Title.BorderSizePixel = 0
    Title.Parent = Main
    local TitleCorner = Instance.new("UICorner"); TitleCorner.CornerRadius = UDim.new(0, 8); TitleCorner.Parent = Title

    local TitleText = Instance.new("TextLabel")
    TitleText.Size = UDim2.new(1, -40, 1, 0)
    TitleText.Position = UDim2.new(0, 10, 0, 0)
    TitleText.BackgroundTransparency = 1
    TitleText.Text = "🎬 Animation Editor (ZSTD Support)"
    TitleText.TextColor3 = Color3.fromRGB(255, 255, 255)
    TitleText.TextXAlignment = Enum.TextXAlignment.Left
    TitleText.Font = Enum.Font.GothamBold
    TitleText.TextSize = 13
    TitleText.Parent = Title

    local Close = Instance.new("TextButton")
    Close.Size = UDim2.new(0, 28, 0, 28)
    Close.Position = UDim2.new(1, -32, 0, 2)
    Close.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
    Close.Text = "✕"; Close.TextColor3 = Color3.fromRGB(255, 255, 255)
    Close.Font = Enum.Font.GothamBold; Close.TextSize = 14; Close.BorderSizePixel = 0
    Close.Parent = Title
    local CloseCorner = Instance.new("UICorner"); CloseCorner.CornerRadius = UDim.new(0, 6); CloseCorner.Parent = Close
    Close.MouseButton1Click:Connect(function() ScreenGui:Destroy(); stopAnimations(); resetPose() end)

    local Status = Instance.new("TextLabel")
    Status.Name = "Status"
    Status.Size = UDim2.new(1, -20, 0, 20)
    Status.Position = UDim2.new(0, 10, 0, 36)
    Status.BackgroundTransparency = 1
    Status.Text = "Ready | Frames: 0"
    Status.TextColor3 = Color3.fromRGB(150, 200, 255)
    Status.TextXAlignment = Enum.TextXAlignment.Left
    Status.Font = Enum.Font.Gotham; Status.TextSize = 11
    Status.Parent = Main

    local function makeButton(text, pos, size, color, callback)
        local btn = Instance.new("TextButton")
        btn.Size = size; btn.Position = pos; btn.BackgroundColor3 = color
        btn.Text = text; btn.TextColor3 = Color3.fromRGB(255, 255, 255)
        btn.Font = Enum.Font.GothamBold; btn.TextSize = 11; btn.BorderSizePixel = 0
        btn.Parent = Main
        local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 6); c.Parent = btn
        btn.MouseButton1Click:Connect(callback)
        return btn
    end

    -- Baris 1
    makeButton("⏺ Record", UDim2.new(0, 10, 0, 62), UDim2.new(0, 95, 0, 28), Color3.fromRGB(200, 60, 60), function()
        if State.Recording then
            table.insert(State.Keyframes, {Pose = capturePose(), Time = os.clock()})
            State.CurrentFrame = #State.Keyframes
            Status.Text = "Recorded! Total: " .. #State.Keyframes
        else Status.Text = "⚠️ Tekan Start Record dulu!" end
    end)

    local RecordBtn
    RecordBtn = makeButton("▶ Start Rec", UDim2.new(0, 110, 0, 62), UDim2.new(0, 95, 0, 28), Color3.fromRGB(60, 160, 60), function()
        State.Recording = not State.Recording
        RecordBtn.Text = State.Recording and "⏹ Stop Rec" or "▶ Start Rec"
        RecordBtn.BackgroundColor3 = State.Recording and Color3.fromRGB(200, 60, 60) or Color3.fromRGB(60, 160, 60)
        Status.Text = State.Recording and "🔴 Recording..." or "Stopped"
    end)

    makeButton("💾 Update Frame", UDim2.new(0, 210, 0, 62), UDim2.new(0, 110, 0, 28), Color3.fromRGB(60, 120, 200), function()
        if #State.Keyframes == 0 or State.CurrentFrame < 1 then Status.Text = "⚠️ Pilih frame dulu!" return end
        State.Keyframes[State.CurrentFrame].Pose = capturePose()
        Status.Text = "Frame " .. State.CurrentFrame .. " diupdate!"
    end)

    makeButton("▶ Play", UDim2.new(0, 325, 0, 62), UDim2.new(0, 55, 0, 28), Color3.fromRGB(60, 120, 200), function()
        if State.Playing or #State.Keyframes == 0 then return end
        State.Playing = true; stopAnimations()
        task.spawn(function()
            repeat
                for i, kf in ipairs(State.Keyframes) do
                    if not State.Playing then break end
                    applyPose(kf.Pose); task.wait(1/State.FPS)
                end
            until not State.Loop or not State.Playing
            State.Playing = false
        end)
    end)

    makeButton("⏹", UDim2.new(0, 385, 0, 62), UDim2.new(0, 55, 0, 28), Color3.fromRGB(120, 60, 60), function()
        State.Playing = false; stopAnimations()
    end)

    -- Baris 2: Load ID, Load .rbxm, Load .json
    local IDBox = Instance.new("TextBox")
    IDBox.Size = UDim2.new(0, 140, 0, 28)
    IDBox.Position = UDim2.new(0, 10, 0, 98)
    IDBox.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
    IDBox.PlaceholderText = "Animation ID..."
    IDBox.Text = ""; IDBox.TextColor3 = Color3.fromRGB(255, 255, 255)
    IDBox.Font = Enum.Font.Gotham; IDBox.TextSize = 11; IDBox.BorderSizePixel = 0
    IDBox.Parent = Main
    local IDBoxCorner = Instance.new("UICorner"); IDBoxCorner.CornerRadius = UDim.new(0, 4); IDBoxCorner.Parent = IDBox

    makeButton("📥 Load ID", UDim2.new(0, 155, 0, 98), UDim2.new(0, 80, 0, 28), Color3.fromRGB(120, 90, 60), function()
        local id = IDBox.Text:match("%d+")
        if not id then Status.Text = "⚠️ ID tidak valid!" return end
        Status.Text = "⏳ Loading ID " .. id .. "..."
        task.spawn(function()
            local ok, objects = pcall(function() return game:GetObjects("rbxassetid://" .. id) end)
            if not ok or not objects or #objects == 0 then Status.Text = "❌ Gagal ambil asset" return end
            local kfs
            for _, obj in ipairs(objects) do
                if obj:IsA("KeyframeSequence") then kfs = obj; break end
                for _, c in ipairs(obj:GetDescendants()) do if c:IsA("KeyframeSequence") then kfs = c; break end end
            end
            if not kfs then Status.Text = "❌ Bukan KeyframeSequence" return end
            local newKFs = {}
            for _, kf in ipairs(kfs:GetChildren()) do
                if kf:IsA("Keyframe") then
                    local pose = {}
                    for _, p in ipairs(kf:GetChildren()) do if p:IsA("Pose") then pose[p.Name] = p.CFrame end end
                    table.insert(newKFs, {Pose = pose, Time = kf.Time})
                end
            end
            table.sort(newKFs, function(a, b) return a.Time < b.Time end)
            State.Keyframes = newKFs; State.CurrentFrame = 1
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
            if type(f) == "string" and f:match("%.rbxm$") then table.insert(rbxmFiles, f) end
        end
        if #rbxmFiles == 0 then Status.Text = "⚠️ Tidak ada .rbxm di workspace" return end
        local target = rbxmFiles[1]
        Status.Text = "⏳ Parsing " .. target .. "... (ZSTD, sabar ya)"
        task.spawn(function()
            local ok2, data = pcall(readfile, target)
            if not ok2 or not data then Status.Text = "❌ Gagal baca file" return end
            local instances, err = parseRBXM(data)
            if not instances then Status.Text = "❌ " .. tostring(err) return end
            local kfs, err2 = extractAnimation(instances)
            if not kfs then Status.Text = "❌ " .. tostring(err2) return end
            State.Keyframes = kfs; State.CurrentFrame = 1
            Status.Text = "✅ " .. target .. " OK! Frames: " .. #kfs
            refreshList()
        end)
    end)

    makeButton("📂 Load .json", UDim2.new(0, 335, 0, 98), UDim2.new(0, 105, 0, 28), Color3.fromRGB(90, 60, 140), function()
        if not readfile or not listfiles then Status.Text = "❌ file API tidak tersedia" return end
        local ok, files = pcall(listfiles, "")
        if not ok then return end
        local jsonFiles = {}
        for _, f in ipairs(files) do if type(f) == "string" and f:match("%.json$") then table.insert(jsonFiles, f) end end
        if #jsonFiles == 0 then Status.Text = "⚠️ Tidak ada .json" return end
        local target = jsonFiles[1]
        local ok2, data = pcall(function() return HttpService:JSONDecode(readfile(target)) end)
        if not ok2 then Status.Text = "❌ Gagal parse json" return end
        State.Keyframes = {}; State.FPS = data.FPS or State.FPS
        for _, poseData in ipairs(data.Keyframes) do
            local pose = {}
            for name, comps in pairs(poseData) do pose[name] = CFrame.new(unpack(comps)) end
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
    FPSBox.Font = Enum.Font.Gotham; FPSBox.TextSize = 11; FPSBox.BorderSizePixel = 0
    FPSBox.Parent = Main
    local FPSBoxCorner = Instance.new("UICorner"); FPSBoxCorner.CornerRadius = UDim.new(0, 4); FPSBoxCorner.Parent = FPSBox
    FPSBox.FocusLost:Connect(function()
        local n = tonumber(FPSBox.Text)
        if n and n >= 1 and n <= 120 then State.FPS = math.floor(n); Status.Text = "FPS: " .. State.FPS
        else FPSBox.Text = tostring(State.FPS) end
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
        State.Keyframes = {}; State.CurrentFrame = 1
        resetPose(); refreshList(); Status.Text = "Cleared."
    end)

    -- Scroll list
    local Scroll = Instance.new("ScrollingFrame")
    Scroll.Name = "Scroll"
    Scroll.Size = UDim2.new(1, -20, 1, -180)
    Scroll.Position = UDim2.new(0, 10, 0, 172)
    Scroll.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
    Scroll.BorderSizePixel = 0; Scroll.ScrollBarThickness = 6
    Scroll.CanvasSize = UDim2.new(0, 0, 0, 0); Scroll.Parent = Main
    local ScrollCorner = Instance.new("UICorner"); ScrollCorner.CornerRadius = UDim.new(0, 6); ScrollCorner.Parent = Scroll

    local ListLayout = Instance.new("UIListLayout")
    ListLayout.Padding = UDim.new(0, 4); ListLayout.SortOrder = Enum.SortOrder.LayoutOrder
    ListLayout.Parent = Scroll

    refreshList = function()
        for _, c in ipairs(Scroll:GetChildren()) do if c:IsA("TextButton") then c:Destroy() end end
        for i, kf in ipairs(State.Keyframes) do
            local row = Instance.new("TextButton")
            row.Size = UDim2.new(1, -8, 0, 28)
            row.BackgroundColor3 = i == State.CurrentFrame and Color3.fromRGB(60, 100, 160) or Color3.fromRGB(40, 40, 50)
            row.Text = "  Frame " .. i .. "  (t=" .. string.format("%.2f", kf.Time or 0) .. ")"
            row.TextColor3 = Color3.fromRGB(255, 255, 255)
            row.TextXAlignment = Enum.TextXAlignment.Left
            row.Font = Enum.Font.Gotham; row.TextSize = 11
            row.BorderSizePixel = 0; row.LayoutOrder = i; row.Parent = Scroll
            local rc = Instance.new("UICorner"); rc.CornerRadius = UDim.new(0, 4); rc.Parent = row
            row.MouseButton1Click:Connect(function()
                State.CurrentFrame = i; applyPose(kf.Pose)
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
-- 7. INIT
-- ============================================================
local gui = createGUI()
print("[AnimEditor ZSTD] Loaded!")
