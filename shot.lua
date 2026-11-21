-- shot.lua —— OBS 截图自动分类（跟 srs.lua / reco.lua 共用同一套映射表）
--
-- 工作方式：每 2 秒看一眼录像目录里有没有新的 Screenshot 文件，有就按「当时的前台应用」移进对应文件夹。
-- 所以不管你用哪个方式截图都管用：
--   · OBS 设置 → 热键 → 搜索「截图输出」→ 绑个键（推荐 Shift+S）
--   · 或者用下面那个「立即截一张」按钮
--
-- 映射表格式跟 srs.lua / reco.lua 完全一样：exe关键词 = 文件夹名

local obs = obslua   -- 必须在文件顶层拿：全局 obs 要到很后面才注入，早用会 nil
local ffi = require("ffi")

ffi.cdef [[
  void* GetForegroundWindow(void);
  unsigned int GetWindowThreadProcessId(void* hWnd, unsigned int* pid);
  void* OpenProcess(unsigned int access, int inherit, unsigned int pid);
  int QueryFullProcessImageNameA(void* proc, unsigned int flags, char* out, unsigned int* size);
  int CloseHandle(void* h);
  typedef struct {
    unsigned int dwFileAttributes;
    unsigned char ftCreation[8];
    unsigned char ftAccess[8];
    unsigned char ftWrite[8];
    unsigned int dwVolumeSerialNumber;
    unsigned int nFileSizeHigh;
    unsigned int nFileSizeLow;
    unsigned int nNumberOfLinks;
    unsigned int nFileIndexHigh;
    unsigned int nFileIndexLow;
    char cFileName[260];
    char cAlternateFileName[14];
  } WIN32_FIND_DATAA;
  void* FindFirstFileA(const char* lpFileName, void* lpFindFileData);
  int FindNextFileA(void* hFindFile, void* lpFindFileData);
  int FindClose(void* hFindFile);
]]

local K32 = ffi.load("kernel32")
local U32 = ffi.load("user32")

local function log(msg)
  local s = "[shot] " .. tostring(msg)
  pcall(function() obs.script_log(obs.LOG_INFO, s) end)
end

-- ── 配置 ───────────────────────────────────────────────
local S = {
  mapping = "",
  root = "D:/OBS666666",
}

local map_cache = {}

local function parse_map(text)
  local out = {}
  for line in tostring(text or ""):gmatch("[^\r\n]+") do
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" and not line:match("^[#;]") then
      local a, b = line:match("^(.-)%s*=%s*(.+)$")
      if a and b then
        a = a:gsub("^%s+", ""):gsub("%s+$", ""):lower()
        b = b:gsub("^%s+", ""):gsub("%s+$", "")
        if a ~= "" and b ~= "" then table.insert(out, { search = a, target = b }) end
      end
    end
  end
  return out
end

-- ── 前台进程 ───────────────────────────────────────────
local SYSTEM_OVERRIDE = {
  explorer = "Desktop", dwm = "Desktop", searchhost = "Desktop",
  shellexperiencehost = "Desktop", lockapp = "Desktop", textinputhost = "Desktop",
}

local function focused_exe()
  local ok, name = pcall(function()
    local hwnd = U32.GetForegroundWindow()
    if hwnd == nil then return nil end
    local pidbuf = ffi.new("unsigned int[1]")
    U32.GetWindowThreadProcessId(hwnd, pidbuf)
    local pid = pidbuf[0]
    if pid == 0 then return nil end
    local proc = K32.OpenProcess(0x1000, 0, pid)
    if proc == nil then return nil end
    local buf = ffi.new("char[1024]")
    local sizebuf = ffi.new("unsigned int[1]", 1024)
    local r = K32.QueryFullProcessImageNameA(proc, 0, buf, sizebuf)
    K32.CloseHandle(proc)
    if r == 0 then return nil end
    local path = ffi.string(buf, sizebuf[0])
    local n = path:match("([^\\/]+)$") or path
    n = n:gsub("%.[Ee][Xx][Ee]$", "")
    if n == "" then return nil end
    return n
  end)
  if ok then return name end
  return nil
end

local function title_case(s)
  s = s:gsub("[_%-]+", " ")
  return (s:gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b:lower() end))
end

local function final_name()
  local raw = focused_exe()
  if not raw then return "Unknown" end
  local low = raw:lower()
  local ov = SYSTEM_OVERRIDE[low]
  if ov then return ov end
  for _, e in ipairs(map_cache) do
    if low:find(e.search, 1, true) then return e.target end
  end
  return title_case(raw)
end

-- ── 扫描截图目录 ───────────────────────────────────────
local seen = {}
local primed = false
local last_root = nil

local INVALID_HANDLE = ffi.cast("void*", -1)

-- 用 Win32 原生枚举：绝不能 io.popen —— OBS 是无控制台程序，
-- 它 spawn 的 cmd.exe 会新开一个控制台窗口，每跑一次就闪一个黑框。
-- 结构体偏移在不同 Windows 版本/编译配置下会飘，所以自己找 cFileName 落在哪。
local NAME_OFFSETS = { 56, 60, 52, 48, 44, 64 }
local name_offset = nil
local dumped = false

local function dump_ids(buf)
  if dumped then return end
  dumped = true
  local vis = {}
  for i = 36, 100 do
    local c = buf[i]
    if c >= 32 and c < 127 then vis[#vis + 1] = string.char(c) else vis[#vis + 1] = "." end
  end
  log("offset dump 36..100: " .. table.concat(vis))
end

local function read_name(buf)
  if name_offset then
    local s = ffi.string(buf + name_offset)
    if s ~= "" then return s end
  end
  for _, off in ipairs(NAME_OFFSETS) do
    local s = ffi.string(buf + off)
    if s:match("^Screenshot") then
      name_offset = off
      log("锁定 cFileName 偏移 = " .. off)
      return s
    end
  end
  return nil
end

local function list_shots(dir)
  local out = {}
  pcall(function()
    local pattern = dir:gsub("/", "\\") .. "\\Screenshot*.png"
    local buf = ffi.new("char[1024]")
    local h = K32.FindFirstFileA(pattern, buf)
    if h == nil or h == INVALID_HANDLE then return end
    local guard = 0
    while true do
      guard = guard + 1
      if guard > 500 then log("枚举超过 500 条，强制退出") break end
      dump_ids(buf)
      local n = read_name(buf)
      if n and n ~= "" then table.insert(out, n) end
      if K32.FindNextFileA(h, buf) == 0 then break end
    end
    K32.FindClose(h)
  end)
  table.sort(out)
  return out
end

local function move_to(dir, name, app)
  if app == nil or app == "" then app = "Unknown" end
  app = app:gsub('[\\/:*?"<>|]', "_")
  local src = dir .. "/" .. name
  local dest_dir = dir .. "/" .. app
  local dest = dest_dir .. "/" .. name
  if src == dest then return false end
  pcall(function() obs.os_mkdirs(dest_dir) end)
  local ok, r = pcall(obs.os_rename, src:gsub("/", "\\"), dest:gsub("/", "\\"))
  if ok and r then
    log(string.format("「%s」→ %s/", name, app))
    return true
  end
  local ok2, r2 = pcall(os.rename, src, dest)
  if ok2 and r2 then
    log(string.format("「%s」→ %s/（io 兜底）", name, app))
    return true
  end
  log(string.format("移动失败：%s → %s", src, dest))
  return false
end

local function scan_once()
  local ok, err = pcall(function()
    local root = S.root
    if root == nil or root == "" then return end

    if root ~= last_root then
      seen = {}
      primed = false
      last_root = root
    end

    local files = list_shots(root)

    if not primed then
      for _, f in ipairs(files) do seen[f] = true end
      primed = true
      log(string.format("盯着 %s（已有 %d 张，不动）", root, #files))
      return
    end

    local fresh = {}
    for _, f in ipairs(files) do
      if not seen[f] then
        seen[f] = true
        table.insert(fresh, f)
      end
    end
    if #fresh == 0 then return end

    for _, f in ipairs(fresh) do
      local app = final_name()
      log(string.format("发现新截图 %s，归到 %s", f, app))
      move_to(root, f, app)
    end
  end)
  if not ok then log("扫描出错：" .. tostring(err)) end
end

-- ── 立即截图（自己调 OBS 的截图）─────────────────────
local function take_shot()
  local done = false
  local ok = pcall(function()
    if type(obs.obs_frontend_take_screenshot) == "function" then
      obs.obs_frontend_take_screenshot()
      done = true
    end
  end)
  if not (ok and done) then
    local ok2 = pcall(function()
      local fn = obs.obs_frontend_take_source_screenshot
      if type(fn) ~= "function" then return end
      local src = obs.obs_frontend_get_current_scene()
      if not src then return end
      fn(src)
      obs.obs_source_release(src)
      done = true
    end)
    if not (ok2 and done) then
      log("这个 OBS 版本没有截图 API，请用「设置 → 热键 → 截图输出」自己绑个键")
      return
    end
  end
  -- 文件落地后由 scan_once 收走
end

-- ── 界面 ───────────────────────────────────────────────
function script_description()
  return "配合 srs.lua / reco.lua 用：截图自动按前台应用分进文件夹。\n" ..
         "截图请用 OBS 自带的「截图输出」热键（设置 → 热键 里绑），或下面这个按钮。"
end

function script_properties()
  local p = obs.obs_properties_create()
  obs.obs_properties_add_text(p, "mapping", "映射表（exe关键词 = 文件夹名）", obs.OBS_TEXT_MULTILINE)
  obs.obs_properties_add_text(p, "root", "截图目录（OBS 的录像路径）", obs.OBS_TEXT_DEFAULT)
  obs.obs_properties_add_button(p, "btn_apply", "套用映射表", function()
    map_cache = parse_map(S.mapping)
    log(string.format("映射表已更新，共 %d 条", #map_cache))
    return false
  end)
  obs.obs_properties_add_button(p, "btn_shot", "立即截一张", function()
    take_shot()
    return false
  end)
  return p
end

function script_defaults(settings)
  pcall(function()
    obs.obs_data_set_default_string(settings, "mapping", "")
    obs.obs_data_set_default_string(settings, "root", "D:/OBS666666")
  end)
end

function script_update(settings)
  S.mapping = obs.obs_data_get_string(settings, "mapping")
  S.root = obs.obs_data_get_string(settings, "root")
  if S.root == nil or S.root == "" then S.root = "D:/OBS666666" end
  map_cache = parse_map(S.mapping)
  log(string.format("映射表已更新，共 %d 条", #map_cache))
end

-- ── 生命周期 ───────────────────────────────────────────
local started = false
local hotkey_id = nil

local function boot()
  if started then return end
  started = true
  pcall(function() scan_once() end)
  pcall(function()
    log(string.format("自检 cFileName 偏移=%d 结构大小=%d",
      ffi.offsetof("WIN32_FIND_DATAA", "cFileName"),
      ffi.sizeof("WIN32_FIND_DATAA")))
  end)
  local ok = pcall(function() obs.timer_add(scan_once, 2000) end)
  if ok then log("开始盯着截图目录") else log("timer 挂载失败") end
end

function script_load(settings)
  pcall(function() script_update(settings) end)

  pcall(function()
    hotkey_id = obs.obs_hotkey_register_frontend("shot_classify_take", "截图并分类", function(pressed)
      if pressed then take_shot() end
    end)
    local arr = obs.obs_data_get_array(settings, "hotkeys")
    if arr then
      obs.obs_hotkey_load(hotkey_id, arr)
      obs.obs_data_array_release(arr)
    end
  end)

  -- obs 表在 script_load 阶段不一定就绪，等加载完成事件再挂 timer
  local ok = pcall(function()
    obs.obs_frontend_add_event_callback(function(event)
      if event == obs.OBS_FRONTEND_EVENT_FINISHED_LOADING then boot() end
    end)
  end)
  if not ok then
    pcall(boot)
  end
end

function script_save(settings)
  if hotkey_id == nil then return end
  pcall(function()
    local arr = obs.obs_hotkey_save(hotkey_id)
    obs.obs_data_set_array(settings, "hotkeys", arr)
    obs.obs_data_array_release(arr)
  end)
end

function script_unload()
  if hotkey_id == nil then return end
  pcall(function() obs.obs_hotkey_unregister(hotkey_id) end)
end