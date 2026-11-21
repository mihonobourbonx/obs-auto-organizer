-- autorb.lua —— OBS 启动后自动开启回放缓存（兜底方案）
-- 主方案是启动参数 --startreplaybuffer（快捷方式已经加了），本脚本只是万一从别的途径启动时的保险。
-- 注意：script_load 被调用时 obs 表不一定已注入，所以全部用 pcall 包住，拿不到就静默退出，不污染日志。

local done = false
local tries = 0
local timer_id = nil
local ready = false

local function slog(level, msg)
  pcall(function() obs.script_log(level, "[autorb] " .. msg) end)
end

local function attempt()
  if done then return true end
  tries = tries + 1

  local ok, running = pcall(function()
    local out = obs.obs_frontend_get_replay_buffer_output()
    if out == nil then return nil end
    local act = obs.obs_output_active(out)
    obs.obs_output_release(out)
    return act
  end)

  if not ok or running == nil then
    if tries >= 30 then
      slog(obs and obs.LOG_WARNING or 2, "回放缓存输出未就绪，放弃（可能回放缓存没在设置里启用）")
      done = true
      return true
    end
    return false
  end

  if running then
    slog(obs and obs.LOG_INFO or 1, "回放缓存本来就在跑，不用动")
    done = true
    return true
  end

  pcall(function() obs.obs_frontend_replay_buffer_start() end)
  slog(obs and obs.LOG_INFO or 1, "已自动开启回放缓存")
  done = true
  return true
end

function script_description()
  return "OBS 启动后自动开启回放缓存（兜底）。\n" ..
         "主方案是启动参数 --startreplaybuffer；本脚本只在参数没生效时补上。"
end

-- OBS 加载完成后才会真正把 obs 表准备好，先用事件回调等这一刻
function on_event(event)
  if event == nil then return end
  pcall(function()
    if obs.OBS_FRONTEND_EVENT_FINISHED_LOADING and event == obs.OBS_FRONTEND_EVENT_FINISHED_LOADING then
      ready = true
      if timer_id then
        pcall(function() obs.timer_remove(timer_id) end)
        timer_id = nil
      end
      attempt()
    end
  end)
end

function script_load(settings)
  done = false
  tries = 0
  ready = false

  -- 有些版本在 script_load 时 obs 还没好，先登记事件回调
  local okcb = pcall(function() obs.obs_frontend_add_event_callback(on_event) end)
  if not okcb then return end

  -- 再挂一个轻量定时器，FINISHED_LOADING 万一没触发也能自己起来
  pcall(function()
    timer_id = obs.timer_add(function()
      if done then return end
      attempt()
      if done and timer_id then
        local id = timer_id
        timer_id = nil
        pcall(function() obs.timer_remove(id) end)
      end
    end, 1500)
  end)
end

function script_unload()
  if timer_id then
    pcall(function() obs.timer_remove(timer_id) end)
    timer_id = nil
  end
  pcall(function() obs.obs_frontend_remove_event_callback(on_event) end)
  done = true
end