--[[
    Simple Animation Editor for Delta Executor
    Fitur: Capture pose, edit keyframe, playback, save/load, export
    Cara pakai: loadstring(game:HttpGet("URL_SCRIPT_KAMU"))()
]]

if not game:IsLoaded() then game.Loaded:Wait() end

-- ==== Konfigurasi ====
local CONFIG = {
    FolderName = "AnimEditorData",
    DefaultFPS = 30,
    MaxKeyframes = 200,
}

-- ==== Services ====
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")

local LP = Players.LocalPlayer
local Mouse = LP:GetMouse()

-- ==== State ====
local State = {
    Recording = false,
    Playing = false,
    Keyframes = {},        -- { [1] = { Pose = { [MotorName] = CFrame }, Time = 0 } }
    CurrentFrame = 1,
    SelectedRig = nil,
    FPS = CONFIG.DefaultFPS,
    Length = 5,
    Loop = false,
}

-- ==== Utility ====
local function getRig()
    local char = LP.Character
    if not char then return nil end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then return nil end
    local animator = hum:FindFirstChildOfClass("Animator")
    if not animator then
        animator = Instance.new("Animator")
        animator.Parent = hum
    end
    return char, hum, animator
end

local function stopAnimations()
    local char, hum = getRig()
    if not char then return end
    for _, t in ipairs(char:GetDescendants()) do
        if t:IsA("AnimationTrack") then
            pcall(function() t:Stop(0) end)
        end
    end
    for _, t in ipairs(hum:GetPlayingAnimationTracks()) do
        pcall(function() t:Stop(0) end)
    end
end

-- Ambil semua Motor6D dan simpan pose-nya
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

-- Apply pose ke Motor6D (untuk preview / playback)
local function applyPose(pose)
    local char = LP.Character
    if not char or not pose then return end
    for _, m in ipairs(char:GetDescendants()) do
        if m:IsA("Motor6D") and pose[m.Name] then
            m.Transform = pose[m.Name]
        end
    end
end

-- Reset pose ke default (T-pose)
local function resetPose()
    local char = LP.Character
    if not char then return end
    for _, m in ipairs(char:GetDescendants()) do
        if m:IsA("Motor6D") then
            m.Transform = CFrame.new()
        end
    end
end

-- ==== GUI ====
local function createGUI()
    local ScreenGui = Instance.new("ScreenGui")
    ScreenGui.Name = "AnimEditor"
    ScreenGui.ResetOnSpawn = false
    ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    ScreenGui.Parent = LP:WaitForChild("PlayerGui")

    -- Main Frame
    local Main = Instance.new("Frame")
    Main.Name = "Main"
    Main.Size = UDim2.new(0, 420, 0, 320)
    Main.Position = UDim2.new(0.5, -210, 0.5, -160)
    Main.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
    Main.BorderSizePixel = 0
    Main.Active = true
    Main.Draggable = true
    Main.Parent = ScreenGui

    local Corner = Instance.new("UICorner")
    Corner.CornerRadius = UDim.new(0, 8)
    Corner.Parent = Main

    -- Title Bar
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
    TitleText.Text = "🎬 Animation Editor"
    TitleText.TextColor3 = Color3.fromRGB(255, 255, 255)
    TitleText.TextXAlignment = Enum.TextXAlignment.Left
    TitleText.Font = Enum.Font.GothamBold
    TitleText.TextSize = 14
    TitleText.Parent = Title

    -- Close Button
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

    -- Status Label
    local Status = Instance.new("TextLabel")
    Status.Name = "Status"
    Status.Size = UDim2.new(1, -20, 0, 20)
    Status.Position = UDim2.new(0, 10, 0, 38)
    Status.BackgroundTransparency = 1
    Status.Text = "Ready | Frames: 0 | FPS: " .. State.FPS
    Status.TextColor3 = Color3.fromRGB(150, 200, 255)
    Status.TextXAlignment = Enum.TextXAlignment.Left
    Status.Font = Enum.Font.Gotham
    Status.TextSize = 12
    Status.Parent = Main

    -- ==== Helper bikin tombol ====
    local function makeButton(text, pos, size, color, callback)
        local btn = Instance.new("TextButton")
        btn.Size = size
        btn.Position = pos
        btn.BackgroundColor3 = color
        btn.Text = text
        btn.TextColor3 = Color3.fromRGB(255, 255, 255)
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 12
        btn.BorderSizePixel = 0
        btn.Parent = Main

        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, 6)
        c.Parent = btn

        btn.MouseButton1Click:Connect(callback)
        return btn
    end

    -- ==== Record / Capture Pose ====
    makeButton("⏺ Record Pose", UDim2.new(0, 10, 0, 65), UDim2.new(0, 130, 0, 30), Color3.fromRGB(200, 60, 60), function()
        local pose = capturePose()
        if not pose then return end
        if State.Recording then
            table.insert(State.Keyframes, {
                Pose = pose,
                Time = os.clock(),
            })
            State.CurrentFrame = #State.Keyframes
            Status.Text = "Recorded! Total frames: " .. #State.Keyframes
        else
            Status.Text = "⚠️ Tekan 'Start Record' dulu!"
        end
    end)

    -- ==== Start / Stop Record ====
    local RecordBtn
    RecordBtn = makeButton("▶ Start Record", UDim2.new(0, 150, 0, 65), UDim2.new(0, 130, 0, 30), Color3.fromRGB(60, 160, 60), function()
        State.Recording = not State.Recording
        RecordBtn.Text = State.Recording and "⏹ Stop Record" or "▶ Start Record"
        RecordBtn.BackgroundColor3 = State.Recording and Color3.fromRGB(200, 60, 60) or Color3.fromRGB(60, 160, 60)
        Status.Text = State.Recording and "🔴 Recording..." or "Stopped"
    end)

    -- ==== Playback ====
    makeButton("▶ Play", UDim2.new(0, 290, 0, 65), UDim2.new(0, 60, 0, 30), Color3.fromRGB(60, 120, 200), function()
        if State.Playing then return end
        if #State.Keyframes == 0 then
            Status.Text = "⚠️ Belum ada keyframe!"
            return
        end
        State.Playing = true
        stopAnimations()

        task.spawn(function()
            local loopCount = 0
            repeat
                for i, kf in ipairs(State.Keyframes) do
                    if not State.Playing then break end
                    applyPose(kf.Pose)
                    task.wait(1 / State.FPS)
                end
                loopCount = loopCount + 1
            until not State.Loop or loopCount > 100
            State.Playing = false
            Status.Text = "Playback selesai"
        end)
    end)

    makeButton("⏹ Stop", UDim2.new(0, 355, 0, 65), UDim2.new(0, 55, 0, 30), Color3.fromRGB(120, 60, 60), function()
        State.Playing = false
        stopAnimations()
        Status.Text = "Stopped"
    end)

    -- ==== Clear / Reset / Save / Load ====
    makeButton("🗑 Clear", UDim2.new(0, 10, 0, 105), UDim2.new(0, 90, 0, 28), Color3.fromRGB(150, 50, 50), function()
        State.Keyframes = {}
        State.CurrentFrame = 1
        resetPose()
        Status.Text = "Cleared. Total frames: 0"
    end)

    makeButton("↺ Reset Pose", UDim2.new(0, 105, 0, 105), UDim2.new(0, 110, 0, 28), Color3.fromRGB(90, 90, 120), function()
        resetPose()
        Status.Text = "Pose direset ke default"
    end)

    makeButton("💾 Save", UDim2.new(0, 220, 0, 105), UDim2.new(0, 90, 0, 28), Color3.fromRGB(60, 120, 60), function()
        if #State.Keyframes == 0 then
            Status.Text = "⚠️ Tidak ada data untuk disimpan"
            return
        end
        local data = {
            FPS = State.FPS,
            Keyframes = {},
        }
        for i, kf in ipairs(State.Keyframes) do
            local poseData = {}
            for name, cf in pairs(kf.Pose) do
                poseData[name] = {cf:GetComponents()}
            end
            table.insert(data.Keyframes, poseData)
        end
        local json = HttpService:JSONEncode(data)
        if writefile then
            writefile(CONFIG.FolderName .. "_" .. LP.Name .. ".json", json)
            Status.Text = "💾 Saved ke workspace/" .. CONFIG.FolderName .. "_" .. LP.Name .. ".json"
        else
            Status.Text = "⚠️ writefile tidak tersedia di executor ini"
        end
    end)

    makeButton("📂 Load", UDim2.new(0, 315, 0, 105), UDim2.new(0, 95, 0, 28), Color3.fromRGB(120, 90, 60), function()
        if not readfile then
            Status.Text = "⚠️ readfile tidak tersedia"
            return
        end
        local path = CONFIG.FolderName .. "_" .. LP.Name .. ".json"
        if not isfile(path) then
            Status.Text = "⚠️ File tidak ditemukan: " .. path
            return
        end
        local ok, data = pcall(function()
            return HttpService:JSONDecode(readfile(path))
        end)
        if not ok then
            Status.Text = "⚠️ Gagal baca file"
            return
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
        Status.Text = "📂 Loaded! Total frames: " .. #State.Keyframes
    end)

    -- ==== FPS Slider ====
    local FPSLabel = Instance.new("TextLabel")
    FPSLabel.Size = UDim2.new(0, 60, 0, 20)
    FPSLabel.Position = UDim2.new(0, 10, 0, 145)
    FPSLabel.BackgroundTransparency = 1
    FPSLabel.Text = "FPS: " .. State.FPS
    FPSLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
    FPSLabel.TextXAlignment = Enum.TextXAlignment.Left
    FPSLabel.Font = Enum.Font.Gotham
    FPSLabel.TextSize = 12
    FPSLabel.Parent = Main

    local FPSBox = Instance.new("TextBox")
    FPSBox.Size = UDim2.new(0, 60, 0, 24)
    FPSBox.Position = UDim2.new(0, 75, 0, 143)
    FPSBox.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
    FPSBox.Text = tostring(State.FPS)
    FPSBox.TextColor3 = Color3.fromRGB(255, 255, 255)
    FPSBox.Font = Enum.Font.Gotham
    FPSBox.TextSize = 12
    FPSBox.BorderSizePixel = 0
    FPSBox.Parent = Main

    local FPSBoxCorner = Instance.new("UICorner")
    FPSBoxCorner.CornerRadius = UDim.new(0, 4)
    FPSBoxCorner.Parent = FPSBox

    FPSBox.FocusLost:Connect(function()
        local n = tonumber(FPSBox.Text)
        if n and n >= 1 and n <= 120 then
            State.FPS = math.floor(n)
            FPSLabel.Text = "FPS: " .. State.FPS
            Status.Text = "FPS diubah ke " .. State.FPS
        else
            FPSBox.Text = tostring(State.FPS)
        end
    end)

    -- ==== Loop Toggle ====
    local LoopBtn = makeButton("🔁 Loop: OFF", UDim2.new(0, 150, 0, 143), UDim2.new(0, 120, 0, 24), Color3.fromRGB(70, 70, 90), function()
        State.Loop = not State.Loop
        LoopBtn.Text = "🔁 Loop: " .. (State.Loop and "ON" or "OFF")
        LoopBtn.BackgroundColor3 = State.Loop and Color3.fromRGB(60, 140, 200) or Color3.fromRGB(70, 70, 90)
    end)

    -- ==== Keyframe List (Scroll) ====
    local Scroll = Instance.new("ScrollingFrame")
    Scroll.Size = UDim2.new(1, -20, 0, 90)
    Scroll.Position = UDim2.new(0, 10, 0, 180)
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

    local function refreshList()
        for _, c in ipairs(Scroll:GetChildren()) do
            if c:IsA("TextButton") then c:Destroy() end
        end
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

            local c = Instance.new("UICorner")
            c.CornerRadius = UDim.new(0, 4)
            c.Parent = row

            row.MouseButton1Click:Connect(function()
                State.CurrentFrame = i
                applyPose(kf.Pose)
                refreshList()
                Status.Text = "Preview frame " .. i
            end)
        end
        Scroll.CanvasSize = UDim2.new(0, 0, 0, #State.Keyframes * 32 + 8)
        Status.Text = "Frames: " .. #State.Keyframes
    end

    -- Update list saat keyframe berubah
    local originalInsert = table.insert
    -- (simpler: refresh tiap 1 detik)
    task.spawn(function()
        while ScreenGui.Parent do
            refreshList()
            task.wait(1)
        end
    end)

    -- ==== Export ke Loadstring ====
    makeButton("📤 Export", UDim2.new(0, 280, 0, 143), UDim2.new(0, 130, 0, 24), Color3.fromRGB(90, 60, 140), function()
        if #State.Keyframes == 0 then
            Status.Text = "⚠️ Tidak ada data"
            return
        end
        local lines = {}
        table.insert(lines, "local f={")
        for _, kf in ipairs(State.Keyframes) do
            local poseParts = {}
            for name, cf in pairs(kf.Pose) do
                local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
                table.insert(poseParts, string.format(
                    '[%q]={%f,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f}',
                    name, x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22
                ))
            end
            table.insert(lines, "{" .. table.concat(poseParts, ",") .. "},")
        end
        table.insert(lines, "}")
        local code = table.concat(lines, "\n")

        if writefile then
            writefile("anim_export_" .. LP.Name .. ".lua", code)
            Status.Text = "📤 Exported: anim_export_" .. LP.Name .. ".lua"
        else
            Status.Text = "⚠️ writefile tidak tersedia"
        end
    end)

    return ScreenGui
end

-- ==== Init ====
local gui = createGUI()
print("[AnimEditor] Loaded. Selamat mencoba!")
