# obs-auto-organizer

三个 OBS Lua 脚本，让录制、截图、回放缓存自动按「当时在用什么程序」分门别类。

OBS 自己只会在一个文件夹里堆文件，名字长这样：

```
D:\OBS\
├─ 2026-11-21 22-06-05.mkv
├─ 2026-11-21 22-15-33.mkv
├─ Replay 2026-11-21 21-55-52.mkv
├─ Screenshot 2026-11-22 06-10-05.png
└─ ...（几百个，找起来要命）
```

装上这三个脚本之后：

```
D:\OBS\
├─ Overwatch 2\
│  ├─ 2026-11-21 22-06-05.mkv
│  └─ Replay 2026-11-21 21-55-52.mkv
├─ DeepSeek Harness\
├─ Google Chrome\
└─ OBS\
   └─ Screenshot 2026-11-22 06-10-05.png
```

## 三个脚本

| 文件 | 管什么 | 触发时机 |
|---|---|---|
| `reco.lua` | 录制（含分段录制） | 录制停止后 |
| `shot.lua` | 截图 | 每 2 秒扫一次目录 |
| `autorb.lua` | 回放缓存自动开启 | OBS 启动完成 |

**回放缓存（Replay Buffer）的分类没写在这里** —— 那件事有一个成熟的现成脚本：[Simple Replay Sorter (SRS)](https://obsproject.com/forum/resources/simple-replay-sorter-srs.2705/)。本项目三个脚本沿用了它的**映射表格式**，所以可以和它共用同一份配置。

## 安装

1. 把 `reco.lua`、`shot.lua`、`autorb.lua` 放进任意目录，比如：
   ```
   <OBS安装目录>\data\obs-scripts\
   ```
2. OBS → **工具 → 脚本** → 点 `+` → 选这三个文件
3. 每个脚本的属性里都有一个 **映射表** 多行框，格式：

   ```
   exe关键词 = 文件夹名
   ```

   例如：

   ```
   overwatch = Overwatch 2
   cs2 = Counter-Strike 2
   chrome = Google Chrome
   weixin = 微信
   ```

   **长关键词放前面**（匹配是「首个命中即返回」），比如 `darkhours` 要写在 `dark` 之前。

## 映射表匹配规则

- 关键词匹配的是**前台进程的 exe 名**（不含 `.exe`），不区分大小写，子串匹配
- 桌面、任务栏、开始菜单这类系统进程会被归到 `Desktop`
- 没匹配上的用 exe 名转 Title Case 当文件夹名
- 都拿不到时归到 `Unknown`

## 各脚本细节

### reco.lua —— 录制分类

录制开始时记下当时的前台应用，停止时再取一次：

- 如果**停止时**的前台不是 `Desktop` / `Unknown`，用停止时的（多数情况更准）
- 否则用**开始时**的（解决「点了开始录制人还在桌面，切进游戏玩完才停」这种情况）

支持 OBS 的**分段录制**：录制过程中每 2 秒 query 一次 `obs_frontend_get_last_recording()`，记下所有分段路径，停止后逐段搬走。

### shot.lua —— 截图分类

每 2 秒扫一次录像目录里的 `Screenshot*.png`，发现新文件就按**截图那一刻**的前台应用移进子文件夹。

不管你是用 OBS 的「截屏输出」热键、还是脚本面板里的「立即截一张」按钮，都会被收走 —— 因为它扫的是文件夹，不关心谁截的。

> 顺便一提：OBS 自带两个截图热键。`截屏输出`（`OBSBasic.Screenshot`）截的是**节目画面**；`选中源的截屏`（`OBSBasic.SelectedSourceScreenshot`）只截**某一个源**。两个都能用，脚本一样会分类。

### autorb.lua —— 回放缓存自动开启

**主方案其实是启动参数**，不是这个脚本：

给 OBS 快捷方式（桌面 + 开始菜单 + 启动文件夹）的目标后面加一个空格和：

```
--startreplaybuffer
```

这样就够了。`autorb.lua` 是**兜底**：万一你从别的途径启动了 OBS（比如某个启动器直接拉 exe），它会等 OBS 加载完成后轮询，发现回放缓存没开就帮你开。

脚本逻辑：等 `OBS_FRONTEND_EVENT_FINISHED_LOADING` 事件 → 每 1.5 秒试一次 → 尝试 `obs_frontend_get_replay_buffer_output()` 拿不到 output 就 `StartReplayBuffer` → 最多试 20 次。

## 踩过的坑（改脚本前请先看）

写这三个脚本时踩了一堆 OBS 33 的坑，写在这免得后来人重复：

### 1. 脚本顶部必须写 `local obs = obslua`

全局 `obs` 表要到很后面才注入，在 `script_load` / `script_update` 里直接用它就是：

```
attempt to index global 'obs' (a nil value)
```

正确做法是第一行 `local obs = obslua`。`obslua` 在文件加载时就已经可用了。

### 2. `obs_data_*` 只有命名空间版，没有裸全局名

```
attempt to call global 'obs_data_set_default_string' (a nil value)
```

要用 `obs.obs_data_set_default_string`。

### 3. 别用 `io.popen` 列目录 —— 会闪黑框

OBS 是无控制台 GUI 程序，它 spawn 的 `cmd.exe` 没有窗口可依附，于是**每调用一次就弹一个控制台窗口**。定时器里这么干，就是每 2 秒闪一下黑框。

改用 Win32 原生枚举（`FindFirstFileA` / `FindNextFileA`），零窗口、也更快。

### 4. `WIN32_FIND_DATAA` 的 `cFileName` 实测偏移是 44，不是 52

MSDN 写的结构是 `dwFileAttributes(4) + 3×FILETIME(24) + 6×DWORD(24) = 52`，但实测 `FindFirstFileA` 填进来的数据里，文件名从**偏移 44** 开始。按 52 读会得到：

```
ot 2026-11-22 06-06-11.png      ← 少了 "Screensh"
```

`shot.lua` 里的做法是**不信任文档**：用 `char[1024]` 裸 buffer，然后拿一组候选偏移 `{56, 60, 52, 48, 44, 64}` 逐个试，谁读出来带 `Screenshot` 前缀就锁定谁。

### 5. 枚举循环一定要有上限

`FindNextFileA` 在某些情况下可能不返回 0，`until` 循环就卡死 —— 而且是在 timer 回调里卡死，表现是**脚本只工作一次然后彻底安静**，日志里连报错都没有。

`shot.lua` 的做法：

```lua
local guard = 0
while true do
  guard = guard + 1
  if guard > 500 then log("枚举超过 500 条，强制退出") break end
  ...
  if K32.FindNextFileA(h, buf) == 0 then break end
end
```

### 6. 整个定时回调要用 `pcall` 包住

同样的道理，任何未捕获异常都会让后续 timer 停掉。`scan_once()` 整体包一层 `pcall`，失败只打一行 `扫描出错：xxx`，脚本继续活着。

### 7. `obs.os_rename` 返回 false 不抛异常

```lua
local ok = pcall(function() obs.os_rename(a, b) end)
if ok then ... end        -- 错：这里 ok 为 true，但文件根本没动
```

要检查返回值：

```lua
local ok, r = pcall(obs.os_rename, a, b)
if ok and r then ... end
```

`shot.lua` 里 `obs.os_rename` 主路径实测会返回 false，最后靠 `os.rename` 兜底才成功 —— 所以两层都留着。

### 8. 改 `未命名.json`（或 profile 的 scenes json）必须在 OBS 关闭时

OBS 运行中改配置文件没用，退出时会把内存里的状态写回去覆盖你的修改。而正常退出也会写，所以只能：

```powershell
Get-Process obs64 | Stop-Process -Force
```

强杀**不会**写配置文件，改完再启动即可。

强杀后启动会弹「检测到 OBS Studio 崩溃」对话框 —— **必须点「以正常模式运行」**。选安全模式会禁用所有第三方插件和脚本，你的脚本全都不加载。

## 兼容性

- 在 **OBS Studio 33.0.1 / 33.0.2 + Windows 11** 上实测通过
- `reco.lua`、`shot.lua` 用到了 `ffi`（LuaJIT），OBS 自带的就是 LuaJIT，Windows 版没问题
- macOS / Linux **不可用**（里面全是 Win32 API）

## 许可

MIT