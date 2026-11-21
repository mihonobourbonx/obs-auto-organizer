-- Recording Organizer（鲸鲸版）
-- 录制结束后，把成品/分段全部移进「以前台应用命名」的子文件夹。
-- 命名规则与 Simple Replay Sorter 一致，共用同一张 Search & Replace 表。
local obs = obslua
local ffi = require("ffi")

local search_replace_list = {}
local rec_app_start = nil
local segments = {}

-- ---------- Win32：拿前台进程的 exe 名 ----------
ffi.cdef[[
typedef void* HWND;
typedef unsigned long DWORD;
typedef int BOOL;
HWND GetForegroundWindow(void);
DWORD GetWindowThreadProcessId(HWND hWnd, DWORD *lpdwProcessId);
void *OpenProcess(DWORD dwDesiredAccess, BOOL bInheritHandle, DWORD dwProcessId);
BOOL QueryFullProcessImageNameA(void *hProcess, DWORD dwFlags, char *lpExeName, DWORD *lpdwSize);
BOOL CloseHandle(void *hObject);
]]
local user32 = ffi.load("user32")
local kernel32 = ffi.load("kernel32")
local PROCESS_QUERY_LIMITED_INFORMATION = 0x1000

local SYSTEM_OVERRIDE = {
    ["explorer"] = "Desktop",
    ["dwm"] = "Desktop",
    ["searchhost"] = "Desktop",
    ["shellexperiencehost"] = "Desktop",
    ["lockapp"] = "Desktop",
    ["textinputhost"] = "Desktop",
}

local function log_info(fmt, ...)
    obs.script_log(obs.LOG_INFO, string.format(fmt, ...))
end
local function log_warn(fmt, ...)
    obs.script_log(obs.LOG_WARNING, string.format(fmt, ...))
end

local function focused_exe()
    local hwnd = user32.GetForegroundWindow()
    if hwnd == nil then return "Unknown" end
    local pid = ffi.new("DWORD[1]")
    user32.GetWindowThreadProcessId(hwnd, pid)
    local h = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid[0])
    if h == nil then return "Unknown" end
    local buf = ffi.new("char[520]")
    local size = ffi.new("DWORD[1]", 520)
    local ok = kernel32.QueryFullProcessImageNameA(h, 0, buf, size)
    kernel32.CloseHandle(h)
    if ok == 0 then return "Unknown" end
    local full = ffi.string(buf, size[0])
    local exe = full:match("([^/\\]+)$") or "Unknown"
    return (exe:gsub("%.[eE][xX][eE]$", ""))
end

local function title_case(s)
    s = s:gsub("[_%-]+", " ")
    s = s:lower()
    s = s:gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end)
    return s
end

local function lookup(raw)
    local low = raw:lower()
    for _, e in ipairs(search_replace_list) do
        if low:find(e.search:lower(), 1, true) then return e.replace end
    end
    return nil
end

local function final_name()
    local raw = focused_exe()
    local sys = SYSTEM_OVERRIDE[raw:lower()]
    local usr = lookup(raw)
    local name = sys or usr or title_case(raw)
    log_info("前台进程: %s → 文件夹: %s", raw, name)
    return name
end

local function get_dir(path)
    return (path:match("(.+)[/\\][^/\\]+$")) or path
end
local function get_filename(path)
    return (path:match("([^/\\]+)$")) or path
end

local function move_one(path, app)
    if path == nil or path == "" or app == nil or app == "" then return end
    local dir = get_dir(path)
    local name = get_filename(path)
    local dest_dir = dir .. "/" .. app
    obs.os_mkdirs(dest_dir)
    local ok = obs.os_rename(path, dest_dir .. "/" .. name)
    if ok then
        log_info("已归类: %s → %s/", name, app)
    else
        log_warn("移动失败: %s → %s/", path, app)
    end
end

-- 每 2 秒问一次「最新录制文件是哪段」，把新分段记下来（分段录制靠这个不漏）
local function tick()
    local p = obs.obs_frontend_get_last_recording()
    if p == nil or p == "" then return end
    for _, s in ipairs(segments) do
        if s == p then return end
    end
    table.insert(segments, p)
    log_info("发现分段: %s", get_filename(p))
end

local function on_event(event)
    if event == obs.OBS_FRONTEND_EVENT_RECORDING_STARTING then
        segments = {}
        rec_app_start = final_name()
        obs.timer_add(tick, 2000)
        log_info("开始录制，先记下前台应用: %s", tostring(rec_app_start))
    elseif event == obs.OBS_FRONTEND_EVENT_RECORDING_STOPPED then
        obs.timer_remove(tick)
        tick()
        -- 停止这一刻的前台更接近「实际在玩什么」；如果那时已经在桌面，就回退到开始记录的
        local app_stop = final_name()
        local app = rec_app_start
        if app_stop ~= nil and app_stop ~= "Desktop" and app_stop ~= "Unknown" then
            app = app_stop
        end
        log_info("录制结束，共 %d 个分段，目标文件夹: %s", #segments, tostring(app))
        for _, p in ipairs(segments) do
            move_one(p, app)
        end
        segments = {}
        rec_app_start = nil
    end
end

-- ---------- 设置界面 ----------
function script_description()
    return "Recording Organizer（鲸鲸版）\n\n录制结束后按前台应用建子文件夹，支持分段录制。命名规则与 SRS 一致。"
end

function script_properties()
    local p = obs.obs_properties_create()
    obs.obs_properties_add_text(p, "search_replace_list",
        "Search & Replace List\n\n一行一条：exe关键词 = 文件夹名\n（和 SRS 用同一张表就好）",
        obs.OBS_TEXT_MULTILINE)
    return p
end

local function parse_list(raw)
    local out = {}
    for line in raw:gmatch("[^\r\n]+") do
        local t = line:match("^%s*(.-)%s*$")
        if t ~= "" then
            local s, r = t:match("^(.-)%s*=%s*(.-)$")
            if s and r ~= "" then
                table.insert(out, { search = s, replace = r })
            elseif s then
                table.insert(out, { search = s, replace = s })
            else
                table.insert(out, { search = t, replace = t })
            end
        end
    end
    return out
end

function script_update(settings)
    search_replace_list = parse_list(obs.obs_data_get_string(settings, "search_replace_list"))
    log_info("映射表已更新，共 %d 条", #search_replace_list)
end

function script_load(settings)
    obs.obs_frontend_add_event_callback(on_event)
    script_update(settings)
end

function script_unload()
    obs.timer_remove(tick)
    obs.script_log(obs.LOG_INFO, "Recording Organizer（鲸鲸版）已卸载")
end
