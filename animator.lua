--[[
    Animation Editor V2 for Delta Executor
    Fitur: Load ID, Load File Workspace, Edit Keyframe
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
    LoadedFileName = nil,
}

-- ==== Utility ====
local function getRig()
    local char = LP.Character
    if not char then return nil end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then return nil end
    return char, hum
end

local function stopAnimations()
    local char, hum = getRig()
    if not char then return end
    for _, t in ipairs(hum:GetPlayingAnimationTracks()) do
        pcall(function() t:Stop(0) end)
    end
end

local function capturePose()
    local char = LP.Character
    if not char then return nil end
    local pose = {}
    for _, m in ipairs(char:GetDescendants()) do
        if m:IsA("Motor6D") then
            pose[m.Name] = m.Transform
        end
    end
    return pose
end

local function applyPose(pose)
    local char = LP.Character
    if not char or not pose then return end
    for _, m in ipairs(char:GetDescendants()) do
        if m:IsA("Motor6D") and pose[m.Name] then
            m.Transform = pose[m.Name]
        end
    end
end

local function resetPose()
    local char = LP.Character
    if not char then return end
    for _, m in ipairs(char:GetDescendants()) do
        if m:IsA("Motor6D") then
            m.Transform = CFrame.new()
        end
    end
end

-- ==== Fungsi Load dari ID Animasi ====
local function loadAnimationFromID(id)
    local success, objects = pcall(function()
        return game:GetObjects("rbxassetid://" .. tostring(id))
    end)
    
    if not success or not objects or #objects == 0 then
        return false, "Gagal mengambil animasi. Pastikan ID valid dan executor mendukung game:GetObjects."
    end

    local kfs = nil
    for _, obj in ipairs(objects) do
        if obj:IsA("KeyframeSequence") then
            kfs = obj
            break
        end
        -- Kadang KeyframeSequence ada di dalam Folder
        for _, child in ipairs(obj:GetDescendants()) do
            if child:IsA("KeyframeSequence") then
                kfs = child
                break
            end
        end
    end

    if not kfs then
        return false, "Asset ini bukan KeyframeSequence (mungkin ini animasi R6/R15 atau format baru)."
    end

    local newKeyframes = {}
    for _, kf in ipairs(kfs:GetChildren()) do
        if kf:IsA("Keyframe") then
            local pose = {}
            for _, p in ipairs(kf:GetChildren()) do
                if p:IsA("Pose") then
                    pose[p.Name] = p.CFrame
                end
            end
            table.insert(newKeyframes, {Pose = pose, Time = kf.Time})
        end
    end

    table.sort(newKeyframes, function(a, b) return a.Time < b.Time end)
    State.Keyframes = newKeyframes
    State.CurrentFrame = 1
    return true, "Berhasil load ID! Total frame: " .. #State.Keyframes
end

-- ==== Fungsi Load dari File Workspace Delta ====
local function getWorkspaceFiles()
    local success, files = pcall(function()
        return listfiles("")
    end)
    if not success then return {} end
    
    local validFiles = {}
    for _, f in ipairs(files) do
        if type(f) == "string" and (f:match("%.json$") or f:match("%.lua$")) then
            table.insert(validFiles, f)
        end
    end
    return validFiles
end

local function loadFromFile(filename)
    if not readfile then return false, "readfile tidak tersedia" end
    local ok, data = pcall(function()
        return HttpService:JSONDecode(readfile(filename))
    end)
    
    if not ok then
        -- Coba sebagai file Lua mentah (dari Export)
        local raw = readfile(filename)
        if raw:find("local f={") then
            -- Ekstrak manual
            local func = loadstring or load
            if func then
                local f = func(raw)
                if f then
                    local success, result = pcall(f)
                    if success and result then
                        State.Keyframes = result
                        State.CurrentFrame = 1
                        return true, "Berhasil load file Lua! Total frame: " .. #State.Keyframes
                    end
                end
            end
        end
        return false, "Gagal parse file. Pastikan format JSON atau Lua Export."
    end

    State.Keyframes = {}
    State.FPS = data.FPS or State.FPS
    for _, poseData in ipairs(data.Keyframes) do
        local pose = {}
        for name, comps in pairs(poseData) do
            pose[name] = CFrame.new(unpack(comps))
        end
        table.insert(State.Keyframes, {Pose = pose, Time = 0})
    end
    State.LoadedFileName = filename
    return true, "Loaded! Total frame: " .. #State.Keyframes
end

-- ==== GUI ====
local function createGUI()
    local ScreenGui = Instance.new("ScreenGui")
    ScreenGui.Name = "AnimEditorV2"
    ScreenGui.ResetOnSpawn = false
    ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    ScreenGui.Parent = LP:WaitForChild("PlayerGui")

    local Main = Instance.new("Frame")
    Main.Size = UDim2.new(0, 450, 0, 480)
    Main.Position = UDim2.new(0.5, -225, 0.5, -240)
    Main.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
    Main.BorderSizePixel = 0
    Main.Active = true
    Main.Draggable = true
    Main.Parent = ScreenGui

    local Corner = Instance.new("UICorner")
    Corner.CornerRadius = UDim.new(0, 8)
    Corner.Parent = Main

    -- Title
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
    TitleText.Text = "🎬 Animation Editor V2"
    TitleText.TextColor3 = Color3.fromRGB(255, 255, 255)
    TitleText.TextXAlignment = Enum.TextXAlignment.Left
    TitleText.Font = Enum.Font.GothamBold
    TitleText.TextSize = 14
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
    Close.MouseButton1Click:Connect(function() ScreenGui:Destroy() end)

    -- Status
    local Status = Instance.new("TextLabel")
    Status.Name = "Status"
    Status.Size = UDim2.new(1, -20, 0, 20)
    Status.Position = UDim2.new(0, 10, 0, 36)
    Status.BackgroundTransparency = 1
    Status.Text = "Ready | Frames: 0"
    Status.TextColor3 = Color3.fromRGB(150, 200, 255)
    Status.TextXAlignment = Enum.TextXAlignment.Left
    Status.Font = Enum.Font.Gotham
    Status.TextSize = 12
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

    -- ==== ROW 1: RECORD & EDIT ====
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

    -- FITUR BARU: Update Frame
    makeButton("💾 Update Frame", UDim2.new(0, 210, 0, 62), UDim2.new(0, 110, 0, 28), Color3.fromRGB(60, 120, 200), function()
        if #State.Keyframes == 0 or State.CurrentFrame < 1 then
            Status.Text = "⚠️ Pilih frame dulu di list!"
            return
        end
        State.Keyframes[State.CurrentFrame].Pose = capturePose()
        Status.Text = "Frame " .. State.CurrentFrame .. " berhasil diupdate!"
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
            until not State.Loop
            State.Playing = false
        end)
    end)

    makeButton("⏹", UDim2.new(0, 385, 0, 62), UDim2.new(0, 55, 0, 28), Color3.fromRGB(120, 60, 60), function()
        State.Playing = false
        stopAnimations()
    end)

    -- ==== ROW 2: LOAD DARI ID & FILE ====
    local IDBox = Instance.new("TextBox")
    IDBox.Size = UDim2.new(0, 140, 0, 28)
    IDBox.Position = UDim2.new(0, 10, 0, 98)
    IDBox.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
    IDBox.PlaceholderText = "Masukkan Animation ID..."
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
        if not id then
            Status.Text = "⚠️ ID tidak valid!"
            return
        end
        Status.Text = "⏳ Loading ID " .. id .. "..."
        task.spawn(function()
            local success, msg = loadAnimationFromID(id)
            Status.Text = msg
            if success then
                -- Refresh list
                for _, c in ipairs(Main:FindFirstChild("Scroll"):GetChildren()) do
                    if c:IsA("TextButton") then c:Destroy() end
                end
                local Scroll = Main:FindFirstChild("Scroll")
                for i, kf in ipairs(State.Keyframes) do
                    local row = Instance.new("TextButton")
                    row.Size = UDim2.new(1, -8, 0, 28)
                    row.BackgroundColor3 = i == State.CurrentFrame and Color3.fromRGB(60, 100, 160) or Color3.fromRGB(40, 40, 50)
                    row.Text = "  Frame " .. i
                    row.TextColor3 = Color3.fromRGB(255, 255, 255)
                    row.TextXAlignment = Enum.TextXAlignment.Left
                    row.Font = Enum.Font.Gotham
                    row.TextSize = 12
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
            end
        end)
    end)

    makeButton("📂 Load File", UDim2.new(0, 240, 0, 98), UDim2.new(0, 80, 0, 28), Color3.fromRGB(90, 60, 140), function()
        local files = getWorkspaceFiles()
        if #files == 0 then
            Status.Text = "⚠️ Tidak ada file .json / .lua di Delta/workspace"
            return
        end
        
        -- Buat GUI Popup untuk pilih file
        local Popup = Instance.new("Frame")
        Popup.Size = UDim2.new(0, 300, 0, 200)
        Popup.Position = UDim2.new(0.5, -150, 0.5, -100)
        Popup.BackgroundColor3 = Color3.fromRGB(35, 35, 45)
        Popup.BorderSizePixel = 0
        Popup.ZIndex = 10
        Popup.Parent = ScreenGui
        local pc = Instance.new("UICorner")
        pc.CornerRadius = UDim.new(0, 8)
        pc.Parent = Popup

        local pTitle = Instance.new("TextLabel")
        pTitle.Size = UDim2.new(1, 0, 0, 30)
        pTitle.BackgroundColor3 = Color3.fromRGB(50, 50, 65)
        pTitle.Text = "Pilih File di Delta/workspace"
        pTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
        pTitle.Font = Enum.Font.GothamBold
        pTitle.TextSize = 12
        pTitle.Parent = Popup

        local pScroll = Instance.new("ScrollingFrame")
        pScroll.Size = UDim2.new(1, -10, 1, -40)
        pScroll.Position = UDim2.new(0, 5, 0, 35)
        pScroll.BackgroundTransparency = 1
        pScroll.ScrollBarThickness = 6
        pScroll.CanvasSize = UDim2.new(0, 0, 0, #files * 30 + 10)
        pScroll.Parent = Popup

        for i, f in ipairs(files) do
            local btn = Instance.new("TextButton")
            btn.Size = UDim2.new(1, -10, 0, 28)
            btn.Position = UDim2.new(0, 5, 0, (i-1) * 30)
            btn.BackgroundColor3 = Color3.fromRGB(60, 60, 75)
            btn.Text = f
            btn.TextColor3 = Color3.fromRGB(255, 255, 255)
            btn.Font = Enum.Font.Gotham
            btn.TextSize = 11
            btn.BorderSizePixel = 0
            btn.Parent = pScroll
            local bc = Instance.new("UICorner")
            bc.CornerRadius = UDim.new(0, 4)
            bc.Parent = btn

            btn.MouseButton1Click:Connect(function()
                Popup:Destroy()
                local success, msg = loadFromFile(f)
                Status.Text = msg
                -- Refresh list di sini (sama seperti di atas)
                if success then
                    local Scroll = Main:FindFirstChild("Scroll")
                    for _, c in ipairs(Scroll:GetChildren()) do
                        if c:IsA("TextButton") then c:Destroy() end
                    end
                    for j, kf in ipairs(State.Keyframes) do
                        local row = Instance.new("TextButton")
                        row.Size = UDim2.new(1, -8, 0, 28)
                        row.BackgroundColor3 = j == State.CurrentFrame and Color3.fromRGB(60, 100, 160) or Color3.fromRGB(40, 40, 50)
                        row.Text = "  Frame " .. j
                        row.TextColor3 = Color3.fromRGB(255, 255, 255)
                        row.TextXAlignment = Enum.TextXAlignment.Left
                        row.Font = Enum.Font.Gotham
                        row.TextSize = 12
                        row.BorderSizePixel = 0
                        row.LayoutOrder = j
                        row.Parent = Scroll
                        local rc = Instance.new("UICorner")
                        rc.CornerRadius = UDim.new(0, 4)
                        rc.Parent = row
                        row.MouseButton1Click:Connect(function()
                            State.CurrentFrame = j
                            applyPose(kf.Pose)
                            for _, r in ipairs(Scroll:GetChildren()) do
                                if r:IsA("TextButton") then
                                    r.BackgroundColor3 = r.LayoutOrder == j and Color3.fromRGB(60, 100, 160) or Color3.fromRGB(40, 40, 50)
                                end
                            end
                            Status.Text = "Preview frame " .. j
                        end)
                    end
                    Scroll.CanvasSize = UDim2.new(0, 0, 0, #State.Keyframes * 32 + 8)
                end
            end)
        end
    end)

    -- ==== ROW 3: FPS, LOOP, EXPORT ====
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
            Status.Text = "FPS diubah ke " .. State.FPS
        else
            FPSBox.Text = tostring(State.FPS)
        end
    end)

    local LoopBtn = makeButton("🔁 Loop: OFF", UDim2.new(0, 65, 0, 135), UDim2.new(0, 110, 0, 28), Color3.fromRGB(70, 70, 90), function()
        State.Loop = not State.Loop
        LoopBtn.Text = "🔁 Loop: " .. (State.Loop and "ON" or "OFF")
        LoopBtn.BackgroundColor3 = State.Loop and Color3.fromRGB(60, 140, 200) or Color3.fromRGB(70, 70, 90)
    end)

    makeButton("💾 Save", UDim2.new(0, 180, 0, 135), UDim2.new(0, 80, 0, 28), Color3.fromRGB(60, 120, 60), function()
        if #State.Keyframes == 0 then Status.Text = "⚠️ Tidak ada data" return end
        local data = { FPS = State.FPS, Keyframes = {} }
        for _, kf in ipairs(State.Keyframes) do
            local poseData = {}
            for name, cf in pairs(kf.Pose) do poseData[name] = {cf:GetComponents()} end
            table.insert(data.Keyframes, poseData)
        end
        local json = HttpService:JSONEncode(data)
        if writefile then
            local fname = CONFIG.FolderName .. "_" .. LP.Name .. ".json"
            writefile(fname, json)
            Status.Text = "💾 Saved ke Delta/workspace/" .. fname
        end
    end)

    makeButton("📤 Export Lua", UDim2.new(0, 265, 0, 135), UDim2.new(0, 80, 0, 28), Color3.fromRGB(90, 60, 140), function()
        if #State.Keyframes == 0 then Status.Text = "⚠️ Tidak ada data" return end
        local lines = {}
        table.insert(lines, "return {")
        for _, kf in ipairs(State.Keyframes) do
            local parts = {}
            for name, cf in pairs(kf.Pose) do
                local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
                table.insert(parts, string.format('[%q]={%f,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f}', name, x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22))
            end
            table.insert(lines, "{" .. table.concat(parts, ",") .. "},")
        end
        table.insert(lines, "}")
        local code = table.concat(lines, "\n")
        if writefile then
            local fname = CONFIG.FolderName .. "_export_" .. LP.Name .. ".lua"
            writefile(fname, code)
            Status.Text = "📤 Exported ke Delta/workspace/" .. fname
        end
    end)

    makeButton("🗑 Clear", UDim2.new(0, 350, 0, 135), UDim2.new(0, 90, 0, 28), Color3.fromRGB(150, 50, 50), function()
        State.Keyframes = {}
        State.CurrentFrame = 1
        resetPose()
        local Scroll = Main:FindFirstChild("Scroll")
        if Scroll then for _, c in ipairs(Scroll:GetChildren()) do if c:IsA("TextButton") then c:Destroy() end end end
        Status.Text = "Cleared."
    end)

    -- ==== SCROLL LIST ====
    local Scroll = Instance.new("ScrollingFrame")
    Scroll.Name = "Scroll"
    Scroll.Size = UDim2.new(1, -20, 0, 280)
    Scroll.Position = UDim2.new(0, 10, 0, 175)
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

    return ScreenGui
end

local gui = createGUI()
print("[AnimEditor V2] Loaded. Siap digunakan!")
