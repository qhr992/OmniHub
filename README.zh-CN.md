# OmniHub

[English](README.md) | **简体中文**

macOS 菜单栏工具集：截图、贴图、剪贴板历史、正在播放、事项、支持 SSH 的终端和系统监视，都集中在一个悬浮窗里。

- 原生 Swift + AppKit，无第三方依赖
- 通用二进制（Apple Silicon 与 Intel），需要 macOS 14 及以上
- 安装后约 9 MB

## 功能

**悬浮窗。** 一个可以拖到任意位置停住的小球。光标移上去，看板会从球的位置展开到旁边；光标离开后缩回球里。播放媒体时，小球拉伸成显示旋转封面和律动条的胶囊。所有页面都从这里进入：首页、活动、事项、终端、暂存、剪贴板、设置。用快捷键打开的页面会一直置前，直到你关闭；切到别的页面后，点到别处看板就会收起。看板里按 Tab / ⇧Tab 在输入框和各项设置之间切换，空格或回车操作当前选中的控件。

**截图。**
- 支持窗口识别和放大镜。
- 标注工具有加框（方框或圆框）、箭头、画笔、文字和打码画笔（大中小三档），可撤销、重做。选中工具后，它的选项（形状、颜色、画笔大小）在工具栏下方展开。
- 确认前可以移动选区或调整大小。
- 结果可以复制、保存或钉在屏幕上。保存时默认打开上次保存的文件夹。
- 长截图：你自己往下滚动页面，自动拼接成一张长图；也可以按住 ↓ 匀速慢滚，点按 ↑ / ↓ 一次滚一小段。

**贴图。**
- 把截图或剪贴板里的图片钉在所有窗口之上。
- 可滚轮或双指缩放，可以直接选中图片里的文字（实况文本）。

**剪贴板。**
- 记录所有应用的复制历史。
- 收藏的条目可以自定排序，并且永远不会被清理。
- 跳过密码管理器标记为隐藏的内容。

**暂存。**
- 把文件拖到小球上，就会复制一份暂存起来，需要时再拖出去用。
- 拖放后暂存看板会置前并保持打开，直到你关闭；可以在设置中关掉这一行为。
- 到期自动清理，保留天数可设置，默认 7 天。

**正在播放。**
- 显示封面、歌名、歌词和可拖动的进度条，带播放模式和喜欢按钮。
- 音乐和视频同时播放时，优先显示并控制音乐。
- 对不接受外部命令的播放器（如网易云音乐），OmniHub 改用它自己的菜单栏来控制，需要辅助功能权限。

**事项。** 待办事项配合月历，月历读取 macOS「日历」中的日程；已完成的事项保留历史记录。

**终端。**
- 多标签 PTY 终端，支持 SSH 和 Telnet 连接配置。
- SFTP 浏览、上传和下载。
- 本地、远程、动态端口转发，SOCKS5 和 HTTP 代理。
- 凭据保险库存放在 macOS 钥匙串中。

**活动。** CPU、GPU、内存、磁盘的实时曲线，本机 IP 地址，可选查询公网 IP。

## 安装

1. 在 [Releases](https://github.com/qhr992/OmniHub/releases) 下载 `OmniHub-<版本>.dmg`。
2. 打开 dmg，把 **OmniHub** 拖进「应用程序」。
3. 打开 OmniHub。发布版使用自签名证书、没有经过 Apple 公证，所以第一次打开会被 macOS 拦下：
   1. 在提示框里点「完成」。
   2. 打开「系统设置 → 隐私与安全性」，在 OmniHub 旁边点「仍要打开」。

   也可以在终端执行：

   ```bash
   xattr -dr com.apple.quarantine /Applications/OmniHub.app
   ```

### 权限

| 权限 | 用途 |
|---|---|
| 屏幕录制 | 截图、长截图、贴图（必需） |
| 辅助功能 | 通过播放器的菜单栏控制播放器；长截图时用 ↑ / ↓ 滚动（可选） |
| 日历 | 在事项页显示日历日程（可选） |

在「系统设置 → 隐私与安全性 → 屏幕录制」中允许 OmniHub，然后重启应用。还没授权的权限会在设置里显示为红字。

## 默认快捷键

| 快捷键 | 功能 |
|---|---|
| `⌘1` | 截图 |
| `⇧⌘2` | 钉出剪贴板图片 |
| `⇧⌘V` | 剪贴板 |
| `` ⌃` `` | 终端 |
| `⇧⌘T` | 事项 |
| `⌃⌥A` | 活动 |
| `⇧⌘O` | 显示或隐藏悬浮窗 |
| `⇧⌘Space` | 播放 / 暂停 |

长截图默认没有快捷键。所有快捷键都可以在「Settings → Shortcuts」中修改或清除。

## URL 调用

运行中的 OmniHub 可以用 `omnihub://` 链接调用，比如在脚本或启动器里使用：

| URL | 功能 |
|---|---|
| `omnihub://snip` | 截图 |
| `omnihub://longsnip` | 长截图 |
| `omnihub://open/<页面>` | 打开页面：`clipboard`、`activity`、`tasks`、`terminal`、`shelf`、`settings` |
| `omnihub://toggle/dock` | 显示或隐藏悬浮窗 |
| `omnihub://playpause` | 播放 / 暂停 |
| `omnihub://pin` | 钉出剪贴板图片（`omnihub://unpin` 关闭全部贴图） |

## 从源码构建

需要 Xcode 命令行工具（`xcode-select --install`），不需要 Xcode 工程。

```bash
./build.sh              # 构建 build/OmniHub.app
./build.sh --install    # 构建、安装到「应用程序」并启动
./test.sh               # 截屏管线、长截图拼接、播放器选择的测试
```

`Tools/setup-signing.sh` 会创建一个本地签名证书，这样重新构建后不用再次授权；没有这个证书时退回 ad-hoc 签名。

启动短片和插图由 `Tools/boot-film/` 中的源文件生成（HyperFrames；渲染需要 Node.js 22+ 和 ffmpeg）。

## 数据与隐私

| 数据 | 位置 |
|---|---|
| 剪贴板历史、事项、终端配置、暂存文件 | `~/Library/Application Support/OmniHub/` |
| 设置 | UserDefaults 域 `com.local.omnihub` |
| 密码 | 登录钥匙串，服务名 `com.local.omnihub.vault` |

OmniHub 只在两种情况下访问网络：获取歌词（`music.163.com`、`lrclib.net`），以及在你开启后查询公网 IP（`api.ipify.org`）。

## 已知限制

- 「正在播放」依赖系统私有的 MediaRemote 框架，以后的 macOS 版本可能会改变它。
- macOS 只把媒体命令交给占着「正在播放」的应用。不占「正在播放」的播放器只能通过它自己的菜单栏控制，而且菜单里要有对应的菜单项。
- 终端不是完整的 VT100 模拟器，`vim`、`htop`、`less` 这类全屏程序无法正常显示。

## 卸载

```bash
pkill -x OmniHub
rm -rf /Applications/OmniHub.app ~/Library/Application\ Support/OmniHub ~/.omnihub
defaults delete com.local.omnihub
tccutil reset All com.local.omnihub
```

如果在保险库里存过密码，再到「钥匙串访问」中删除 `com.local.omnihub.vault` 的条目。

## 许可

- 源代码：[MIT](LICENSE)，Copyright (c) 2026 DillonQiu。
- 美术素材**不在** MIT 许可范围内，保留所有权利，包括应用图标、头像、插图、启动短片、角色岚和小青鸟、启动音效，详见 [ASSETS-LICENSE.md](ASSETS-LICENSE.md)。发布的 fork 需要替换这些素材。
