# OmniHub

macOS 菜单栏常驻套件：截图 / 长截图、贴图、剪贴板历史、正在播放、事项、带 SSH / SFTP 的终端、活动监视，
全部收在一个悬浮窗看板里。

- Swift + AppKit，零第三方依赖，通用二进制（arm64 + x86_64），最低 macOS 14
- 应用包约 7 MB（含启动短片和背景插图）
- 吉祥物是原创角色 **岚（Lan）** 和她的小青鸟（见「启动短片与岚」）

---

# 打包与安装

在要使用的那台 Mac 上操作，整个项目文件夹拷过去即可。角色素材已经提交在 `Resources/character/` 里，不用另外带。

## 1. 环境

| 需要 | 说明 |
|---|---|
| macOS 14 及以上 | Intel / Apple Silicon 都行，产物是通用二进制（截屏用 ScreenCaptureKit，需要 14） |
| Xcode 命令行工具 | 提供 `swiftc`、`clang`、`codesign`、`iconutil`。没装就执行 `xcode-select --install` |
| Node.js 22+、ffmpeg（可选） | 只有要重做启动短片时才需要，见「启动短片与岚」 |

不需要 Xcode 工程。

## 2. 打包并安装

```bash
cd OmniHub
./build.sh --install
```

这一条命令依次：编译 → 生成图标 → 打进启动短片、背景和头像 → 签名 → 退出正在运行的旧版 →
覆盖安装到 `/Applications/OmniHub.app` → 启动。

只想打包、不安装：

```bash
./build.sh                      # 产物在 build/OmniHub.app
open build/OmniHub.app
```

签名用 `Tools/setup-signing.sh` 生成的本地固定证书（放在 `~/Library/Application Support/OmniHub-signing/`），
应用身份固定为 `com.local.omnihub`，**以后重新打包不用再授权**。没有证书时退回 ad-hoc 签名。
钥匙串在但里面没有证书（以前导入失败过）时，脚本会重建它；打完包可用 `codesign -dvv /Applications/OmniHub.app` 确认
`Authority=OmniHub Local Signing`——显示 ad-hoc 说明没用上证书，每次重装都要重新授权辅助功能和屏幕录制。
临时打一个 ad-hoc 包做自测：`OMNIHUB_ADHOC=1 ./build.sh`。
签名时开启 Hardened Runtime（禁止往进程里注入代码），并带上 `Resources/OmniHub.entitlements` 里的日历权限声明
（开了 Hardened Runtime 不声明就读不了日历）。要在 App Store 之外正式分发，见 `docs/AppStore与安全评估.md` 第三节。

## 3. 给别人安装（不用拷整个项目）

在自己这台已经能打包的 Mac 上执行：

```bash
./Tools/package.sh              # 产物：dist/OmniHub-<版本>.dmg（约 6 MB），旁边是它的 .sha256
```

把这一个 `.dmg` 发给对方（微信、AirDrop、网盘都行）。对方：

1. 双击打开 DMG，把 OmniHub 拖到 Applications；
2. 第一次打开会提示「无法验证开发者」：点「完成」，到 系统设置 → 隐私与安全性 底部点「仍要打开」再确认；
   或者在终端执行一次 `xattr -dr com.apple.quarantine /Applications/OmniHub.app`；
3. 按下一节授权屏幕录制等权限。

DMG 里也放了一份同样内容的「安装说明.txt」。

注意：

- 出现「无法验证开发者」是因为用的是本地自签证书，没有经过 Apple 公证。要让对方双击就能开，需要加入
  Apple Developer Program 做 Developer ID 签名 + 公证，见 `docs/AppStore与安全评估.md` 第三节。
- 以后的新版本**一直在同一台 Mac 上打包**（同一张本地证书），对方覆盖安装后已给的授权仍然有效；
  换一台 Mac 打包就是另一张证书，对方要重新授权一次。

## 4. 首次运行

| 权限 | 用途 | 怎么开 |
|---|---|---|
| 屏幕录制（必需） | 截图、长截图、贴图 | 系统设置 → 隐私与安全性 → 屏幕录制 → 勾选 OmniHub，重启应用 |
| 辅助功能（可选） | 不接受外部控制的播放器（如网易云音乐）改走它自己的菜单来切播放模式、喜欢 | Settings → General → Permissions 里点 Grant Accessibility… |
| 日历（可选） | 事项页的月历显示 Mac「日历」里的安排 | 第一次打开事项页时系统会问 |
| 钥匙串 | 终端保险库、连接密码 | 用固定证书签名时不会反复询问 |

未授权的项目在设置和事项页里显示为红字。

## 5. 验证装好了

```bash
open "omnihub://diagnose"
cat ~/Library/Application\ Support/OmniHub/diagnostics.txt
```

看这几行：`screenRecordingTrusted = true`、`bootAnimation = … video=true avatar=true background=true`、
`-- hotkeys --` 下面每一项都是 `ok`。

不在屏幕上弹窗的自检：

```bash
APP=build/OmniHub.app/Contents/MacOS/OmniHub
$APP --dock-selftest          # 看板：导航顺序、宽度、贴图层级、待办滚动、双击跳转、Tab 顺序、播放控制走向、暂存（32 项）
$APP --terminal-selftest      # 终端按键映射、终端输入时快捷键让路、服务器已有转发解析
$APP --clip-selftest          # 剪贴板收藏 / 排序 / 持久化（在备份上跑，结束后还原）
$APP --ocr-selftest           # 画一行字再识别回来
$APP --askpass-selftest       # 保险库密码只交给 OmniHub 自己起的 ssh
$APP --snip-selftest          # 截图选区：默认框内拖动是移动、选了工具才画、拖边 / 拖角调整大小、工具栏层级与标记、Esc（24 项）
$APP --render /tmp/omnihub-render   # 悬浮窗各形态、各页面画成 PNG，外加 report.txt
OMNIHUB_ADHOC=1 ./build.sh && ./test-remote.sh   # SSH / SFTP / 下载 / 端口转发 / 代理 / Telnet / 凭证 端到端（55 项）
./test.sh                     # 抓屏管线 + 长截图拼接算法
```

`test-remote.sh` 会在本机临时起一个 sshd、一个网页服务、一个要密码的 HTTP 代理和一个 Telnet 登录，
跑完全部清掉，结果在 `build/remote-test/report.txt`。

## 6. 卸载

```bash
pkill -x OmniHub
rm -rf /Applications/OmniHub.app ~/Library/Application\ Support/OmniHub ~/.omnihub
defaults delete com.local.omnihub
tccutil reset ScreenCapture com.local.omnihub
tccutil reset Accessibility com.local.omnihub
tccutil reset Calendar com.local.omnihub
```

在保险库里存过密码、或用 Set Password… 给连接设过密码的话，再到「钥匙串访问」里搜 `com.local.omnihub.vault` 删掉对应条目。

---

# 功能

界面文字是精简英文，下文括号里是界面上的名字。

## 悬浮窗与看板

- **悬浮球**：一个圆形图标，可以拖到屏幕任意位置停住（按屏幕比例记住位置）。播放媒体时变成胶囊，
  可显示旋转封面 + 律动条、歌词或保持静态，样式和长度在 Settings → Dock 里选。球和胶囊之间是平滑拉伸，
  不会一下跳变；展开首页看板时（首页自带播放器）胶囊收回成球，展开其他看板或收起看板时再拉回胶囊。
- **悬停展开**：光标碰到悬浮球，首页看板从球的位置放大展开在球旁边（球在上方就向下、在左侧就向右……），
  光标离开后缩回球里。
- **导航栏**顺序：首页（Home）→ 活动（Activity）→ 事项（Agenda）→ 终端（Terminal）→ 暂存（Shelf）……… 剪贴板（Clipboard）、设置（Settings）。
  剪贴板和设置固定在最末端（横向时在最右侧，纵向时在一列的最下面）。没有关闭按钮。
  Settings → Dock → **Entry icons** 可以选显示活动 / 事项 / 终端 / 暂存 / 剪贴板中的哪几个；首页和设置始终显示，
  隐藏了入口的页面仍可用快捷键打开。
- **看板宽度**：所有页面同一个宽度，Settings → Dock → **Card width**（480–1100，默认 533，即悬浮球在屏幕上 / 下边时首页的宽度）。
  悬浮球在屏幕左 / 右边时，首页和活动保持各自的窄列布局，其余页面都用这个宽度。
- **收起**：点看板最顶部那一条空白处（页面里开着浮层时——比如终端设置或下拉面板——第一次点只关浮层）、按 Esc、
  或再按一次同一个全局快捷键。点导航图标不会误收起。
- **置前规则**：全局快捷键打开的页面一直留着，直到你关；悬停展开的在光标离开后收起；点导航图标进去的在失去键盘焦点后收起。
- **切页动画**：页面之间切换时，看板从当前大小自然伸展或收缩到新页面的大小，背景始终连贯，旧内容淡出、新内容淡入，中途不会透出桌面。
  悬停展开时看板从悬浮球处放大出来，收起时缩回悬浮球。
- 右键悬浮球或 Settings → Dock → Icon 可以把悬浮球图标换成任意图片。

## 首页（Home）

- **播放器**：封面、歌名、歌手 · 应用、当前歌词、进度条和时间；点封面或歌名跳到正在播放的应用。
  按钮从左到右：
  - **播放模式**：点一下在 顺序 → 单曲循环 → 随机 之间切换，图标随之变化；播放器没有的模式会跳过
    （网易云音乐菜单里只有「随机播放」开关，就在 顺序 ↔ 随机 之间切）；
  - 上一首 / 播放暂停 / 下一首；
  - **喜欢**：心形，已喜欢时为实心粉色，点一下喜欢或取消喜欢。

  播放模式和喜欢怎么送到播放器：
  - 播放器向系统登记了「随机 / 循环 / 喜欢」命令的（如 Apple Music），直接经 MediaRemote 发送，状态也从那里读回来；
  - 只登记了播放 / 暂停 / 上一首 / 下一首的（网易云音乐属于这种情况：其他应用发来的模式、喜欢命令它收不到），
    在授权辅助功能后改为按它自己菜单栏里的同名菜单项（单曲循环、随机播放、喜欢……）去点，并按菜单上的勾选显示状态；
    网易云的菜单不显示勾选、窗口里的按钮也读不到，播放模式图标显示的是 OmniHub 上次设置的模式——
    在网易云里自己切换过的话，图标会对不上，再点一次即可；
  - 两条路都走不通时按钮变暗，点一下会在歌手那一行提示原因（例如需要授权辅助功能）。
    汽水音乐属于这种情况：系统命令里没有喜欢，菜单栏也没有喜欢，窗口通常是关着的，喜欢只能在它自己的窗口里点。
  - 播放 / 暂停以系统报告的播放状态为准。QQ 音乐暂停后，发给系统的信息里播放速率仍是 1，
    只看速率会把暂停的歌当成在播、进度条继续走；只有系统给不出播放状态时才看速率。
  - 同时有几个播放器（例如网易云和 Chrome 里装的 YouTube 应用）时，跟随正在播放的那个：系统的「正在播放」仍指着已暂停的网易云、
    而 YouTube 在播时，卡片显示 YouTube；都暂停时停在最后跟随的那个上。
    这种情况下 YouTube 收不到其他应用发来的播放命令（macOS 只把命令交给占着「正在播放」的应用，硬发会落到网易云上），
    所以上一首 / 播放暂停 / 下一首 / 模式 / 喜欢按钮变暗，点按钮或按快捷键只在歌手那一行提示「Open YouTube to control it」，
    不会去动网易云。点封面打开 YouTube 在它窗口里控制；退出网易云后 YouTube 成为「正在播放」，按钮和快捷键恢复。
  - **点封面**打开正在播放的应用（与点标题相同）。
  - **进度条**：点一下从那个位置开始播放；按住拖动时左边的时间跟着指针走，松手才跳过去。
    指针移上去进度条变粗、出现圆点。播放器没报时长时进度条不响应；
    播放器没登记「跳到指定位置」命令（24）时，点了在歌手那一行提示不支持。
  - 网易云音乐切换随机播放（以及播放中的某些时候）会把发给系统的「正在播放」信息清空，但歌照常在放。
    这时只要它还在运行，播放器就保留上一首的信息，播放 / 暂停按系统的音频输出判断（暂停后几秒内更新）；
    它再次发出信息（换歌、暂停）时恢复正常。OmniHub 启动时它已处于这种状态的，先以「网易云音乐」为标题显示。

  `omnihub://diagnose` 的 `-- media --` 一段会列出当前播放器登记了哪些命令（21 喜欢、25 循环、26 随机）、
  两个按钮各走哪条路、以及在它菜单里找到的相关菜单项，播放器没反应时先看这里。
  切换模式时播放器若短暂报一次「没有在播」，首页会保留当前曲目 3 秒再判断，不会一闪就消失。
- **待办**：列出所有未完成的事项，看得到的行数按 Settings → Agenda → Show on Home（默认 5 行）；
  超出时右侧出现细滚动条，触控板、鼠标滚轮或拖动滚动条都能滚。
  **双击某条待办的标题**，直接切到事项页并打开这条任务的编辑。
- 右上角是距下一个法定节假日的天数。节假日是算出来的：元旦、劳动节、国庆按固定日期；春节、端午、中秋按农历换算；
  清明按节气公式。只算节日当天，不含调休。
- **播放键**：光标停在看板或悬浮球上且当前是首页时，空格 = 播放 / 暂停，`⌘←` / `⌘→` = 快退 / 快进 5 秒，
  `⇧⌘←` / `⇧⌘→` = 上一首 / 下一首。

## 活动（Activity）

CPU、GPU、内存、磁盘各有一块带动态曲线的指标卡（磁盘曲线是读写速度），本机 IP 显示为文字，公网 IP 可选（默认关）。
显示哪些项、刷新间隔在 Settings → Activity 里设。只有页面显示在屏幕上时才采样。

## 事项（Agenda）

- 左边是月历，读取 Mac「日历」的安排；点某一天，右边显示当天的日历安排和事项。
- 顶部分段切换 **Day**（所选那天的事项）/ **Done**（已完成的历史，按完成日期分组、显示完成时间；点勾选框可恢复为未完成）。
- **添加**：输入标题后按 Tab 依次走 标题 → 说明 → 日期开关 → 日期 → Add → Cancel → 回到标题；
  焦点在 Add / Cancel 上时按 Return / Enter / 空格就执行该按钮。标题里直接按回车也会添加。
- **编辑**：双击一条事项（或在首页双击），表单载入它的内容，Add 变成 **Save**，**Cancel** 单独一行出现。
- 存储在 `~/Library/Application Support/OmniHub/tasks.json`。

## 终端（Terminal）

- 真 PTY，多标签页，每个标签一个独立 shell。快捷键沿用 macOS 自带「终端」：`⌘T` / `⌘N` 新建、`⌘W` 关闭、
  `⌃⇥` / `⇧⌘]` 下一个、`⌘1–9` 切换、`⌘K` 清屏、`⌘F` 查找、`⌘+` / `⌘-` / `⌘0` 字体、`⇧⌘K` 配置和连接。
  全部写在 `~/Library/Application Support/OmniHub/terminal-keys.json`，可以直接改；常用几个也能在 Settings → Terminal 里录。
- **按键归终端**：光标在终端里输入时，Esc、`⌃C` 等都交给终端里的程序；不带 `⌘` 的全局快捷键、和终端快捷键重复的
  在输入期间暂停，离开终端自动恢复。**截图（和长截图）快捷键例外，优先级最高，任何页面、包括在终端里输入时都直接截图**
  （所以默认的 `⌘1` 不再用来切到终端第 1 个标签）。要收起看板就点顶部空白处。
- **配置和连接**按钮（Connections）：筛选已有配置，或直接输入 `ssh user@host -p 22`、`user@host:22`、`telnet host 23` 回车连接。
- **终端设置**（齿轮）：
  - 左边是列表、右边是详情，宽度按 2 : 5 分。
  - Connections：SSH / Telnet 配置，分组、新增 / 复制 / 删除、代理、私钥、Test Connection、Run after login。
    **Credential**（凭证）下拉第一项是 **Username & Password**（默认）：下面直接填用户名（可选）和密码，密码存进钥匙串、只给这个连接用，
    密码留空 = 连接时再问。其后是保险库里的各个条目：选了保险库条目就用它的 Username 登录，那个条目没填 Username 就表示
    不需要账号名（SSH 不带用户名、Telnet 只等密码提示）。
    密码可选 Ask when connecting、本连接自己的密码（**Set Password…**，存进钥匙串）或保险库条目。
  - Vault：每个条目有名称、Username（可选）和密码；密码存在 macOS 钥匙串，配置里只记条目 ID。
  - Proxies：SOCKS5 / HTTP / HTTPS，可带用户名和保险库密码。
- **Run after login**：每行一条命令，可选 `Prompt` / `Reply` / 保险库密码；等到密码提示后自动输入并回车，60 秒没等到就停止并在终端里说明。
- **远程标签的工具栏**：
  - 重新连接；
  - **SFTP**：浏览、筛选、建文件夹、上传；右键 Copy Path / Download；
  - **端口转发**：THIS CONNECTION 是本标签加的转发，可新建 `-L` / `-R` / `-D`；ON THE SERVER 只读列出服务器上已有的转发
    （服务器上运行中的 `ssh` / `autossh` 带的 `-L` `-R` `-D`、sshd 正在监听的远程转发端口、服务器 `~/.ssh/config` 里写的转发），↻ 重查。
- **下载**按钮：最近的下载和上传，带进度、可取消、可在访达中显示。
- 实现：SSH 用系统 `/usr/bin/ssh`，每个标签一条 ControlMaster，SFTP、下载、转发都复用它；代理和 Telnet 由应用自身充当辅助进程
  （`--proxy-connect`、`--telnet`）；保险库密码经 `SSH_ASKPASS` 交给 ssh，不出现在命令行。Telnet 没有 SFTP 和端口转发。
- 限制：不是完整 VT100，`vim` / `htop` / `less` 这类全屏程序不可用。

## 暂存（Shelf）

- 把文件或文件夹**拖到悬浮球上**松手，就复制一份放进暂存（悬浮球亮一圈青色边表示可以放），随后看板打开到暂存页给你看；
  也可以直接拖到暂存页里。原文件不动。
- 暂存页每行显示图标、文件名、大小 · 加入时间 · 还剩几天；双击打开，**拖出去**就是把文件复制到别处（访达、聊天窗口、上传框……），
  悬停出现「在访达中显示」和「移除」按钮，右键还有 Open / Copy。右上角 Clear All 清空。
- 到期自动清理，默认 7 天，在 Settings → Clipboard → Shelf 改（1 / 3 / 7 / 14 / 30 天）；应用运行时每小时检查一次，启动时也检查。
- 文件放在 `~/Library/Application Support/OmniHub/shelf/`。

## 剪贴板（Clipboard）

- 轮询 `NSPasteboard.changeCount` 记录所有应用的每一次复制，不需要辅助功能权限；跳过密码管理器标记的内容。
- **All** 按时间倒序；**Favourites** 只列收藏，按自定顺序，可拖拽或 `⌘↑` / `⌘↓` 排序。收藏永不被淘汰。
- `⌘P` 收藏，`⌘⌫` 删除；双击或回车把内容放回剪贴板并收起看板。
- 历史条数、是否记录图片、清空历史在 Settings → Clipboard。

## 截图与贴图

- **截图**（`⌘1`）：每块屏都有窗口自动识别和放大镜；标注有矩形、椭圆、箭头、画笔、文字；
  框选松手后默认不选工具：在框里拖动是移动整个选区（指针是手形，拖到屏幕边缘停住），拖边或八个控制点放大缩小；
  点工具栏的工具后，在框里拖才是画标注，再点一次同一个工具回到移动；
  `⌘Z` / `⇧⌘Z` 撤销 / 重做，`Enter` / `⌘C` 复制，`⌘S` 保存，`⌘T` 贴图；任何时候按 Esc（或点右键）都直接退出截图，包括已经框选、正在标注或输入文字时；工具栏不设关闭按钮。
- **长截图**：选好区域后点工具栏的长截图按钮（默认没有快捷键，可在设置里录），然后自己往下滚（不做自动滚动）；
  停下几秒自动结束，也可以按 Esc 或点 Done。相邻两帧整段重叠求位移，自动识别并剔除吸顶 / 吸底栏。
- **截屏接口**：用 ScreenCaptureKit。截图是按下快捷键时每块屏各截一张（`SCScreenshotManager`）；
  长截图开一路只取选区的画面流（`SCStream`，最多每秒 60 帧），每 50 毫秒取最新一帧拼接。
  流里的帧按原始字节读，和同一位置的截图逐字节一致。权限仍是「屏幕录制」。
- **贴图**：把图片钉在屏幕上。截图时按 `⌘T`，或 `⇧⌘2` 钉出剪贴板里的图片。拖动移动；滚轮、双指开合、`⌘+` / `⌘-` / `⌘0`
  或悬停出现的 − / ＋ 按钮缩放；双击关闭；macOS 13+ 可直接选中图上的文字复制（实况文本）。
  **贴图永远在看板之上**，只有新钉的贴图会盖住旧的；点哪张，哪张到最上层。

## 设置（Settings）

| 页签 | 内容 |
|---|---|
| General | Open at login；Startup（Startup animation、Sound、Preview）；Menu Bar Icon → Runner（跟随内存或 CPU）；Permissions（未授权红字） |
| Shortcuts | 每个动作一行：点按钮后按新组合键，⌫ 清除、Esc 取消；重复占用会拒绝；Reset All |
| Screenshot | 窗口识别、放大镜、完成提示；长截图与 Pins 说明 |
| Clipboard | 历史条数、记录图片、Clear History；Shelf（暂存保留天数） |
| Agenda | 首页显示几条、新事项默认带日期、Clear Done |
| Dock | While playing（胶囊样式、Player length、首页是否显示播放器 / 节假日倒计时）；Card（Card width、Entry icons）；Icon |
| Activity | 活动页显示哪些指标、刷新间隔、公网 IP |
| Terminal | 录制常用终端快捷键（其余在 terminal-keys.json） |

改动立即生效，存在 UserDefaults（`com.local.omnihub`）。

**菜单栏图标（Runner）**：一个带翅膀的小跑者，内存（或 CPU）占用越高，翅膀扇得越快。

## 全局快捷键（默认值）

| 快捷键 | 功能 |
|---|---|
| `⌘1` | Screenshot 截图（优先级最高，在终端里输入时也有效） |
| `⇧⌘2` | Pin Clipboard Image 钉出剪贴板图片 |
| `⇧⌘V` | Clipboard 剪贴板 |
| `` ⌃` `` | Terminal 终端 |
| `⇧⌘T` | Agenda 事项 |
| `⌃⌥A` | Activity 活动 |
| `⇧⌘O` | Show / Hide Dock 显示 / 隐藏悬浮窗 |
| `⇧⌘Space` | Play / Pause 播放 / 暂停 |
| （无） | Scrolling Screenshot 长截图 |

都可以在 Settings → Shortcuts 里改或清除。它们是全局热键，会盖掉其它应用里的同名快捷键。

## 启动短片与岚

**岚（Lan，取「山间雾气」之意）** 是 OmniHub 的吉祥物，原创角色：乌黑的长卷发，鬓边别着白色小花和两根浅色羽毛、
一支挂小铃的金簪，耳垂坠青绿流苏；穿青绿交领长袍，领口金线绣纹，腰间白色束带系一块玉佩。
身边跟着一只长尾小青鸟（同样是原创造型），羽尾末端带金色眼斑，通身金色勾线。
画风取水墨仙侠的意境：雾蓝灰的远山、飘落的白色花瓣、青绿 + 暖金 + 一点朱红。
轨道上绕着五个瓷白小图标——截图、剪贴板、事项、终端、播放，代表各个模块。

启动时屏幕中央播放 7 秒短片：金色轨道环由一点光画出 → 小青鸟从左下飞入、绕一大圈 → 岚从环中升起、眨眼、
挥袖 → 五个图标绕轨道转起来 → 镜头侧移（远山移得慢一些），出现字标 **OmniHub** 和
SNIP · CLIP · PLAN · PLAY · SHELL，岚眨一下眼 → 淡出到雾色；配三声轻铃。
短片窗口和普通应用启动时的窗口一样：出现在前面一次，之后可以被别的窗口盖住，不跟随切换桌面，也不占用 Esc；
点击跳过；Settings → General 可关闭、静音、预览。

| 文件（`Resources/character/`） | 用途 |
|---|---|
| `BootAnimation.mp4` | 启动短片（1280×720，30 fps，7 秒，带音效），清晨雾色 |
| `Background.jpg` | 看板和设置窗口的背景插图：同一场景的月夜版，深色底让看板上的浅色文字看得清 |
| `Avatar.png` | 悬浮球默认图标 |
| `AppIcon.png` | 应用图标源图 |

这些都由 `Tools/boot-film/` 生成：`character/lan.svg` 是岚的矢量原画（各部位分层，可做动画），
`character/bird.svg` 是小青鸟，`assemble.py` 把这两张图拷进短片和静帧页；
`compositions/boot.html` 是短片（HyperFrames：HTML + GSAP），`stills/` 是背景和头像，`assets/chime.wav` 是音效。
修改后重新生成（渲染短片需要 Node.js 22+ 和 ffmpeg；背景和头像只用 Chrome）：

```bash
cd Tools/boot-film
npx hyperframes preview      # 在浏览器里预览、拖时间轴
./make-assets.sh             # 渲染短片 + 截背景 / 头像 → 写回 Resources/character，并重做图标
cd ../.. && ./build.sh --install
```

## 脚本入口

运行中的实例可以用 URL 驱动（验证和自动化用）：

```bash
open "omnihub://snip"             # 截图            omnihub://longsnip   长截图
open "omnihub://open/clipboard"   # 看板打开到某页：open/activity  open/tasks  open/terminal  open/shelf  open/settings
open "omnihub://toggle/dock"      # 显示 / 隐藏悬浮窗   omnihub://playpause  播放 / 暂停
open "omnihub://pin"              # 钉出剪贴板图片   omnihub://unpin  关闭全部贴图
open "omnihub://boot"             # 重播启动短片
open "omnihub://diagnose"         # 状态写到 ~/Library/Application Support/OmniHub/diagnostics.txt
```

`omnihub://` 链接任何网页和应用都能打开，所以测试用的路由默认不生效：`debug/…`、`snapshot`（各窗口自绘成 PNG 到
`…/OmniHub/snapshots/`）、`terminal-demo`、`escape`、`expand-dock`、`collapse-dock`。要用时先打开开关，用完关掉：

```bash
defaults write com.local.omnihub debug.urls -bool true    # 打开
defaults delete com.local.omnihub debug.urls              # 关掉
```

开关打开时 `diagnose` 还会写出最近几条剪贴板和事项的内容（平时只写数量）。

长截图实拍自检（需要屏幕录制权限，并打开上面的开关）：`open "omnihub://debug/scroll-selftest/slow"`（或 `flick`、`jump`），
应用开一个 3000pt 高的测试文档自己滚动并截取，结果写到 `…/OmniHub/scroll-selftest-<mode>.txt`。

其它命令行入口：`--zoom-render <目录>`（离屏画出缩放动画的几帧）、`--parse-tunnels <文件>`（解析保存下来的服务器探测输出）。

## 数据位置

| 内容 | 位置 |
|---|---|
| 剪贴板、收藏、事项、终端配置、按键表、诊断、暂存文件（`shelf/`） | `~/Library/Application Support/OmniHub/` |
| 终端连接用的 ssh 控制套接字等 | `~/.omnihub/` |
| 设置 | UserDefaults `com.local.omnihub` |
| 密码 | 登录钥匙串，服务名 `com.local.omnihub.vault` |

## 许可

- 源代码：[MIT](LICENSE)，Copyright (c) 2026 DillonQiu。
- 美术素材（应用图标、头像、背景插图、启动短片、角色岚和小青鸟、启动音效）不在 MIT 范围内，
  保留所有权利，见 [ASSETS-LICENSE.md](ASSETS-LICENSE.md)。发布 fork 请换成自己的图标和素材。

---

# 版本记录

| 版本 | 内容 |
|---|---|
| 1.7.1 | 截图框选松手后、确认前可拖边和角继续放大缩小；截图里画了标注后工具栏不再被盖住、可以继续换工具；截图工具栏标出当前工具和颜色，指针随工具变化（文字为输入光标）；截图时 Esc 一次直接退出（工具栏去掉关闭按钮）；有多个播放器时跟随正在播放的那个（如网易云暂停时在播的 YouTube 应用）；网易云音乐切换随机播放后播放器不再消失；网易云音乐这类只有「随机播放」开关的播放器，播放模式在 顺序 ↔ 随机 之间切；签名钥匙串没有证书时自动重建（之前会悄悄退回 ad-hoc，每次重装都要重新授权）；启动短片改为普通窗口（不再强制置顶、不占用 Esc）；新吉祥物岚和小青鸟（原创），新的启动短片、背景插图、头像与图标；点播放器封面打开正在播放的应用；跟随的播放器（如网易云占着「正在播放」时的 YouTube）收不到命令，播放按钮与快捷键改为提示原因，不再误控网易云；点或拖动进度条跳到指定位置播放；QQ 音乐暂停后进度条不再继续走；长截图去掉自动滚动，只能自己往下滚；截屏改用 ScreenCaptureKit，最低系统版本提到 macOS 14；框选后默认在框里拖动是移动选区，选了工具才画标注；悬浮球与胶囊之间平滑拉伸，播放中展开首页时胶囊收回成球、展开其他看板时再拉回；音乐和视频同时播放时优先显示并控制音乐，不再随系统「正在播放」来回跳；在 OmniHub 里暂停后停留在该播放器上，播放键不再变灰 |
| 1.7.0 | 新增暂存（拖到悬浮球即存，默认 7 天自动清理）；页面切换改为看板自然伸缩、不再闪；终端设置恢复左列表右详情（2 : 5）；连接加 Credential：账号密码（默认）或保险库条目（用条目的 Username，没有就不带账号），去掉 Set Password 按钮；截图快捷键优先级最高；播放模式和喜欢按播放器实际支持的命令发送，不支持的（如网易云音乐）改走它的菜单（需辅助功能）；安全加固：askpass 只回答自己起的 ssh、调试链接默认关闭、启用 Hardened Runtime。上架与安全评估见 `docs/AppStore与安全评估.md` |
| 1.6.0 | 导航改为 首页 → 活动 → 事项 → 终端 ……… 剪贴板、设置，去掉关闭按钮，入口可配置；所有页面同宽（可配置）；点顶部不再误关；首页双击待办进入事项编辑、待办可滚动；事项加 Done 历史、编辑保存、Tab 顺序与回车执行按钮；贴图永远在看板之上、点谁谁置顶；播放器加播放模式与喜欢按钮，切随机不再消失；新的启动短片与背景插图（Lumi） |
| 1.5.0 | 切页改为缩放动画；终端输入时按键归终端；SSH 连接 Set Password…；端口转发显示服务器上已有的转发；未授权权限红字 |
| 1.4.0 | 界面改精简英文；只有快捷键呼出的页面置前；贴图文字可选取；终端设置加 Test Connection、Run after login |
| 1.3.0 | 活动、终端、剪贴板、事项、设置并入悬浮窗看板；首页节假日倒计时与播放键；事项月历；终端 SSH / SFTP / 端口转发 / 代理 / 保险库；菜单栏 Runner |
| 1.2.0 | 改名 OmniHub；启动动画、终端多标签、活动模块 |
| 1.1.0 | 经 perl 桥接在 macOS 15.4+ 读取正在播放；长截图拼接重写；设置窗口；贴图 |
| 1.0.0 | 截图、长截图、剪贴板历史、终端、悬浮窗、任务板 |
