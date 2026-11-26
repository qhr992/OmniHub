import AppKit

/// One topic of the help: a heading and what it says.
struct HelpEntry {
    let heading: String
    let body: String
}

/// A group of help topics, badged like the settings.
struct HelpSection {
    let title: String
    let symbol: String
    let tint: NSColor
    let entries: [HelpEntry]
}

/// Everything OmniHub does, in the interface's language. The settings keep
/// only their controls; the explanations live here.
enum HelpContent {
    static var sections: [HelpSection] { AppLanguage.current == .chinese ? chinese : english }

    private typealias Tint = SettingsSection.Tint

    private static func section(_ title: String, _ symbol: String, _ tint: NSColor,
                                _ entries: [(String, String)]) -> HelpSection {
        HelpSection(title: title, symbol: symbol, tint: tint, entries: entries.map { HelpEntry(heading: $0.0, body: $0.1) })
    }

    // MARK: English

    static let english: [HelpSection] = [
        section("Getting Around", "map", Tint.blue, [
            ("Menu bar icon", "A left click drops down a panel: what is playing on top, then Display Sleep and live tiles for CPU, memory, GPU, disk, network and battery, each with its recent history. At the bottom, Open Dashboard and Settings. A right click (or Control-click) shows the menu; its first item is Open Dashboard."),
            ("Dashboard (main window)", "An ordinary window with every page down the left: Home, Activity, Agenda, Terminal, Shelf, Clipboard and Settings. It opens on the page shown last, on the screen the pointer is on. While it is open, OmniHub has a Dock icon and is in ⌘-Tab."),
            ("Dock ball and card", "A small ball that stays wherever you drag it. Rest the pointer on it and a card opens beside it with Home, Terminal, Shelf and Clipboard; move away and it folds back. A page opened with a shortcut stays until you close it. A page is shown in one place at a time: opening it in the main window takes it from the card."),
            ("Keyboard", "Tab and ⇧Tab move between fields and settings; Space or Return works the focused control. ↑ / ↓ move along lists. ⌘[ goes back in Settings and Help.")
        ]),
        section("Home", "house.fill", Tint.blue, [
            ("What it shows", "A greeting with the date and time, what is playing, the system at a glance, your next to-dos and quick actions."),
            ("Quick actions", "Six buttons: Screenshot, Pin Image (the image on the clipboard), Terminal, Clipboard, Shelf and Agenda.")
        ]),
        section("Screenshot and Pins", "camera.viewfinder", Tint.teal, [
            ("Taking a screenshot", "⌘1 (or the menu). Windows are detected as you hover, and a click takes the whole window. A magnifier helps with exact edges. Move or resize the selection before you confirm."),
            ("Marking up", "Box (square or round), arrow, pen, text and a blur pen in three sizes; undo and redo. Pick a tool and its options (shape, colour, size) open under the toolbar. Turn on Fill beside the box shapes and a box is painted solid, covering what is inside."),
            ("Copy, save, pin", "Copy the result, save it (to the folder you saved in last), or pin it on screen."),
            ("Scrolling screenshot", "Start it from the screenshot toolbar or the menu bar menu, then scroll down yourself: the pieces are stitched into one long image. Hold ↓ to scroll at an even pace, tap ↑ / ↓ for a short step. It stops a few seconds after you stop scrolling, or on Esc / Done."),
            ("Pins", "Pins float above every window. Zoom with the scroll wheel, a pinch or the − ＋ buttons shown on hover; × closes. Text in a pin can be selected and copied (Live Text). ⇧⌘2 pins the image on the clipboard.")
        ]),
        section("Clipboard", "doc.on.clipboard.fill", Tint.yellow, [
            ("History", "Everything copied in any app is kept, images too if you like (Settings › Clipboard). Double-click an item to copy it and close the card."),
            ("Starred items", "Starred items can be put in your own order and are never cleared."),
            ("Privacy", "Content that password managers mark as concealed is skipped.")
        ]),
        section("Shelf", "tray.full.fill", Tint.orange, [
            ("Keeping files", "Drop files on the dock ball to keep a copy on the Shelf; drag them out again where you need them."),
            ("After a drop", "The Shelf stays in front until you close it. Turned off in Settings, it folds away when the pointer leaves, like a card opened by hovering."),
            ("Clean-up", "Files are deleted after the number of days set in Settings (7 by default).")
        ]),
        section("Now Playing", "music.note", Tint.pink, [
            ("The player", "Cover, title, lyrics and a progress bar you can drag, with play mode and like buttons. A click on the cover opens the player."),
            ("On the dock ball", "While music plays the ball becomes a pill: a spinning cover and bars, or (Song and lyrics) the lyric being sung, held until the next one rolls up slowly from below; the song's name shows only while there is no lyric. Drag Player length all the way left for cover and bars only."),
            ("Lyrics", "Looked up on NetEase Cloud Music, then LRCLIB. A long line glides sideways."),
            ("Players that take no commands", "Music is preferred over video when both play. Players that do not accept commands from other apps (such as NetEase) are worked through their own menus, which needs Accessibility.")
        ]),
        section("Agenda", "checklist", Tint.red, [
            ("To-dos", "Add a to-do with an optional note, date and time; done ones are kept in a history."),
            ("Calendar", "The month view reads your Mac Calendar (macOS asks once). Pick a day to see its events and to-dos.")
        ]),
        section("Terminal", "terminal.fill", Tint.orange, [
            ("Tabs and connections", "A terminal with tabs; save SSH and Telnet connections and open them in a click."),
            ("Files", "Browse a server over SFTP, upload by dropping files, download with a click. The Downloads button at the top shows a transfer as it runs: the ring fills and the arrow moves, a tick when done; click it for recent transfers."),
            ("Port forwarding and proxies", "Local, remote and dynamic forwards; SOCKS5 and HTTP proxies."),
            ("Vault", "Passwords are kept in the macOS Keychain. Connections, Vault and Proxies are behind the gear at the top right of the Terminal page."),
            ("Shortcuts", "The same as macOS Terminal. Common ones can be changed in Settings › Terminal; the rest (copy, paste, font size, paging, ⌘1–9…) are in its config file."),
            ("Limits", "Not a full VT100 emulator: full-screen programs such as vim, htop or less do not display properly.")
        ]),
        section("Activity", "gauge.with.dots.needle.67percent", Tint.green, [
            ("Live charts", "CPU, GPU, memory, disk and network as figures with their recent history. Pick what is shown and how often it refreshes in Settings › Activity."),
            ("Battery", "Charge, state, health, cycle count, temperature and power."),
            ("Top apps", "The busiest apps by CPU or memory; helper processes count toward their app."),
            ("Display Sleep", "On as usual. Turn it off for 30 minutes, 1 or 2 hours, or until you turn it back on, and the display stays awake meanwhile. Also in the menu bar menu and panel. A small coffee cup on the status icon means it is off."),
            ("IP addresses", "This Mac's addresses; the public IP only if you turn it on (it asks api.ipify.org).")
        ]),
        section("Menu Bar and Status Icon", "menubar.rectangle", Tint.indigo, [
            ("Buddy", "The menu bar can show the buddy or the status icon. Buddy speed: follows memory, follows CPU, or still."),
            ("Network speed", "Optionally beside the icon: upload above, download below. Turn it on in Settings › Appearance or from the right-click menu."),
            ("Status icon", "A live round icon: an open ring, a head at the top, a glyph in the middle and dots (or an arc) at the bottom, each showing what you pick: battery, CPU, memory, disk, Wi-Fi, network or volume. It can also be on the dock ball and in the Dock."),
            ("Battery on the ring", "On battery the top shows the charge; while charging a green bolt; plugged in but not charging, a plug. On battery the ring keeps the default colour from 80 %, then shades through yellow and orange to red at 20 % or less; it is green only while charging. Turn off Figure on the ring for a plain ring."),
            ("Colours", "Themes (Automatic, Aurora, Sunset, Mint, Sakura, Violet, Paper), or a colour of your own for the ring, middle, dots and background.")
        ]),
        section("Settings", "gearshape.fill", Tint.gray, [
            ("Finding a setting", "Settings lists its topics; click one to open it and Back to return to the list. Every visit starts at the list."),
            ("Language", "English or Simplified Chinese, in Settings › General. Takes effect after OmniHub restarts."),
            ("Updates", "Checked at launch and every six hours; when a newer version is out, an Update button appears in the card, the menu bar menu and Settings › General."),
            ("Permissions", "Screen Recording is needed for screenshots and pins (restart OmniHub after granting). Accessibility lets OmniHub work players through their menus and scroll in scrolling screenshots. Calendar shows your events in Agenda. Permissions not yet granted show in red in Settings › General.")
        ]),
        section("Shortcuts", "command", Tint.indigo, [
            ("Defaults", "⌘1 screenshot · ⇧⌘2 pin clipboard image · ⇧⌘V clipboard · ⌃` terminal · ⇧⌘T agenda · ⌃⌥A activity · ⇧⌘O show or hide the dock · ⇧⌘Space play / pause."),
            ("Changing them", "Settings › Shortcuts: click a shortcut, then press the new keys. ⌫ clears, Esc cancels.")
        ]),
        section("Links and Data", "link", Tint.purple, [
            ("omnihub:// links", "omnihub://snip, omnihub://longsnip, omnihub://open/<page> (clipboard, activity, tasks, terminal, shelf, settings), omnihub://toggle/dock, omnihub://playpause, omnihub://pin and omnihub://unpin — for scripts and launchers."),
            ("Where data is kept", "Clipboard history, to-dos, terminal settings and Shelf files in ~/Library/Application Support/OmniHub; settings in the com.local.omnihub defaults; passwords in the login Keychain."),
            ("Network use", "Only for lyrics (music.163.com, lrclib.net), update checks (github.com; can be turned off) and, if turned on, the public IP (api.ipify.org).")
        ])
    ]

    // MARK: 简体中文

    static let chinese: [HelpSection] = [
        section("入门", "map", Tint.blue, [
            ("菜单栏图标", "左键点击下拉信息看板：最上面是正在播放，下面是息屏，以及 CPU、内存、GPU、磁盘、网络、电池的实时卡片，每项都带最近的变化曲线。底部有「进入 Dashboard」和「设置」。右键（或按住 Control 点击）弹出菜单，第一项是「进入 Dashboard」。"),
            ("Dashboard（主窗口）", "一个普通窗口，左侧列出全部页面：首页、活动、事项、终端、暂存、剪贴板、设置。打开时显示上次的页面，并出现在光标所在的屏幕上。窗口打开期间，OmniHub 在程序坞有图标，也能用 ⌘-Tab 切换。"),
            ("悬浮球和看板", "一个可以拖到任意位置停住的小球。光标停在上面，看板会在旁边展开，包含首页、终端、暂存、剪贴板；光标离开后缩回。用快捷键打开的页面会一直保持，直到你关闭。同一个页面同一时间只在一处显示：在主窗口打开会从看板拿过来。"),
            ("键盘操作", "Tab / ⇧Tab 在输入框和各项设置之间切换，空格或回车操作当前控件，↑ / ↓ 在列表中移动。在设置和帮助里 ⌘[ 返回。")
        ]),
        section("首页", "house.fill", Tint.blue, [
            ("显示内容", "问候语和日期时间、正在播放、系统概况、接下来的待办和快捷操作。"),
            ("快捷操作", "六个按钮：截图、贴图（钉出剪贴板里的图片）、终端、剪贴板、暂存、事项。")
        ]),
        section("截图与贴图", "camera.viewfinder", Tint.teal, [
            ("截图", "按 ⌘1（或从菜单）。光标移动时自动识别窗口，单击即截取整个窗口；放大镜帮助对准边缘。确认前可以移动选区或调整大小。"),
            ("标注", "加框（方框或圆框）、箭头、画笔、文字和三档大小的打码画笔，可撤销、重做。选中工具后，它的选项（形状、颜色、大小）在工具栏下方展开。打开加框形状旁的「填充」，框会被颜色填满，直接遮住框里的内容。"),
            ("复制、保存、钉住", "结果可以复制、保存（默认打开上次保存的文件夹）或钉在屏幕上。"),
            ("长截图", "从截图工具栏或菜单栏菜单开始，然后自己往下滚动页面，自动拼接成一张长图。按住 ↓ 匀速慢滚，点按 ↑ / ↓ 一次滚一小段。停止滚动几秒后自动结束，也可以按 Esc 或点完成。"),
            ("贴图", "贴图浮在所有窗口之上。滚轮、双指或悬停时出现的 − ＋ 按钮缩放，× 关闭；贴图里的文字可以直接选中复制（实况文本）。⇧⌘2 把剪贴板里的图片钉出来。")
        ]),
        section("剪贴板", "doc.on.clipboard.fill", Tint.yellow, [
            ("历史记录", "记录所有应用的复制内容，也可以记录图片（设置 → 剪贴板）。双击条目即复制并收起看板。"),
            ("收藏", "收藏的条目可以自定排序，并且永远不会被清理。"),
            ("隐私", "跳过密码管理器标记为隐藏的内容。")
        ]),
        section("暂存", "tray.full.fill", Tint.orange, [
            ("暂存文件", "把文件拖到悬浮球上，就会复制一份暂存起来，需要时再拖出去用。"),
            ("拖放之后", "暂存看板会置前并保持打开，直到你关闭；在设置里关掉后，光标离开就会收起，和悬停打开的看板一样。"),
            ("自动清理", "到期自动删除，保留天数在设置里调整，默认 7 天。")
        ]),
        section("正在播放", "music.note", Tint.pink, [
            ("播放器", "封面、歌名、歌词和可拖动的进度条，带播放模式和喜欢按钮。点封面打开播放器。"),
            ("悬浮球上", "播放音乐时小球拉伸成胶囊：旋转封面加律动条，或（歌曲信息与歌词）显示正在唱的那句歌词，一直停留到下一句从下往上缓慢滚入；只有没有歌词可显示时才显示歌曲信息。把「播放器长度」拖到最左只显示封面和律动条。"),
            ("歌词", "依次从网易云音乐、LRCLIB 获取；太长的一行会左右滑动显示。"),
            ("不接受命令的播放器", "音乐和视频同时播放时优先显示音乐。对不接受外部命令的播放器（如网易云音乐），OmniHub 改用它自己的菜单来控制，需要辅助功能权限。")
        ]),
        section("事项", "checklist", Tint.red, [
            ("待办", "添加待办，可以带备注、日期和时间；已完成的保留在历史记录里。"),
            ("日历", "月历读取 macOS「日历」里的日程（系统会询问一次）。点某一天查看当天的日程和待办。")
        ]),
        section("终端", "terminal.fill", Tint.orange, [
            ("标签与连接", "多标签终端；保存 SSH 和 Telnet 连接，一键打开。"),
            ("文件", "通过 SFTP 浏览服务器，拖入文件上传，点一下下载。顶部的下载按钮会实时显示传输：圆环随进度填满、箭头上下跳动，完成时显示对勾；点它查看最近的传输。"),
            ("端口转发与代理", "本地、远程、动态端口转发；SOCKS5 和 HTTP 代理。"),
            ("保险库", "密码存放在 macOS 钥匙串中。连接、保险库、代理都在终端页右上角的齿轮里。"),
            ("快捷键", "与 macOS 终端一致。常用的可以在「设置 → 终端」修改，其余（复制、粘贴、字号、翻页、⌘1–9 等）在配置文件里。"),
            ("限制", "不是完整的 VT100 模拟器，vim、htop、less 这类全屏程序无法正常显示。")
        ]),
        section("活动", "gauge.with.dots.needle.67percent", Tint.green, [
            ("实时曲线", "CPU、GPU、内存、磁盘和网络的数值及最近的变化曲线。显示哪些、多久刷新一次在「设置 → 活动」里选。"),
            ("电池", "电量、充电状态、健康度、循环次数、温度和功率。"),
            ("占用排行", "按 CPU 或内存排出最忙的应用，应用的辅助进程算在应用名下。"),
            ("息屏", "默认开启。可以关闭 30 分钟、1 小时、2 小时，或一直关闭到手动开启，期间屏幕不会熄灭。菜单栏菜单和信息看板里也能设。状态图标上的小咖啡杯表示息屏已关闭。"),
            ("IP 地址", "本机的 IP 地址；公网 IP 需要你开启后才会查询（访问 api.ipify.org）。")
        ]),
        section("菜单栏与状态图标", "menubar.rectangle", Tint.indigo, [
            ("小伙伴", "菜单栏可以显示小伙伴或状态图标。小伙伴速度：随内存、随 CPU 或静止。"),
            ("网速", "可在图标右侧显示网速：上方上传、下方下载。在「设置 → 外观」或右键菜单里打开。"),
            ("状态图标", "一个实时的圆形图标：开口的外圈、顶部的头部、中间的符号和底部的圆点（或圆弧），分别显示你选的内容：电池、CPU、内存、磁盘、Wi-Fi、网络或音量。也可以显示在悬浮球和程序坞上。"),
            ("外圈显示电池", "用电池时顶部显示电量数字，充电时显示绿色闪电，接着电源但没在充电时显示插头。用电池时电量在 80% 及以上保持默认颜色，往下逐渐变黄、变橙，20% 及以下为红色；只有充电时才是绿色。关掉「外环显示数字」只显示圆环。"),
            ("配色", "可选主题（自动、极光、日落、薄荷、樱花、紫罗兰、纸白），也可以给外圈、中间、圆点和背景分别选颜色。")
        ]),
        section("设置", "gearshape.fill", Tint.gray, [
            ("找设置", "进入设置先列出所有主题，点一个进入，左上角返回回到列表。每次进入都从列表开始。"),
            ("语言", "英文或简体中文，在「设置 → 通用」里选，重启 OmniHub 后生效。"),
            ("更新", "启动时和之后每六小时检查一次；有新版本时，看板、菜单栏菜单和「设置 → 通用」里会出现更新按钮。"),
            ("权限", "截图和贴图需要屏幕录制权限（授权后重启 OmniHub）。辅助功能让 OmniHub 能通过菜单控制播放器、在长截图时滚动。日历用于在事项页显示日程。还没授权的权限在「设置 → 通用」里显示为红字。")
        ]),
        section("快捷键", "command", Tint.indigo, [
            ("默认快捷键", "⌘1 截图 · ⇧⌘2 钉出剪贴板图片 · ⇧⌘V 剪贴板 · ⌃` 终端 · ⇧⌘T 事项 · ⌃⌥A 活动 · ⇧⌘O 显示或隐藏悬浮球 · ⇧⌘空格 播放 / 暂停。"),
            ("修改", "「设置 → 快捷键」：点一个快捷键，再按下新的组合键。⌫ 清除，Esc 取消。")
        ]),
        section("链接与数据", "link", Tint.purple, [
            ("omnihub:// 链接", "omnihub://snip、omnihub://longsnip、omnihub://open/<页面>（clipboard、activity、tasks、terminal、shelf、settings）、omnihub://toggle/dock、omnihub://playpause、omnihub://pin 和 omnihub://unpin，可以在脚本或启动器里用。"),
            ("数据存放", "剪贴板历史、事项、终端配置和暂存文件在 ~/Library/Application Support/OmniHub；设置在 com.local.omnihub 偏好域；密码在登录钥匙串。"),
            ("联网", "只用于获取歌词（music.163.com、lrclib.net）、检查更新（github.com，可以关闭），以及你开启后查询公网 IP（api.ipify.org）。")
        ])
    ]
}
