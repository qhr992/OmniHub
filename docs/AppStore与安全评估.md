# OmniHub：能否上架 Mac App Store，以及安全评估

评估日期 2026-11-14，对象是 1.7.0 的代码和本机构建产物。文中的「实测」都附了复现命令。

## 一、结论

**按现在的功能，上不了 Mac App Store（MAS）。**

MAS 有两条硬性要求：必须开 App Sandbox，必须只用公开 API。OmniHub 的几块核心功能正好依赖沙盒外的能力和私有框架。

如果要发给别人用，建议走 **Developer ID 签名 + Apple 公证（notarization）**，在 MAS 之外分发（dmg、官网或 Homebrew cask）：

- 功能可以全部保留；
- 用户首次打开不会出现「无法验证开发者」的拦截；
- 只需要 Apple 开发者账号（99 美元/年）。

## 二、上不了 MAS 的具体原因

| 功能 | 依赖的能力 | 在 MAS 的问题 | 位置 |
|---|---|---|---|
| 播放器：读取正在播放、播放控制、播放模式和喜欢 | 私有框架 MediaRemote；macOS 15.4 起还借 `/usr/bin/perl` 加载桥接 dylib，以绕过系统只允许 Apple 进程访问的限制 | 违反审核指南 2.5.1（只能用公开 API），而且属于刻意绕开系统限制，基本必拒 | `Sources/MediaObserver.swift`、`Sources/MediaBridge/` |
| 终端 | `forkpty` 起 shell | 子进程继承沙盒，shell 读不到用户文件，终端基本不可用 | `Sources/TerminalSession.swift` |
| SSH / SFTP / 下载 / 端口转发 | 执行系统的 `/usr/bin/ssh`、`/usr/bin/sftp`，读 `~/.ssh`，控制套接字放在 `~/.omnihub` | 沙盒内读不到 `~/.ssh`（密钥、known_hosts、config），`~/.omnihub` 也在容器外 | `Sources/ConnectionStore.swift` |
| 播放器菜单兜底 | 辅助功能：AX 操作别的 App 的菜单 | 沙盒应用不能用辅助功能控制其他 App | `Sources/PlayerMenu.swift` |
| 签名身份 | 本地自签证书 / ad-hoc，`com.local.omnihub`，没有 Team ID | 上架和公证都需要开发者账号签发的证书 | `build.sh`、`Tools/setup-signing.sh` |

在沙盒里可以保留的功能：

- 截图、贴图、实况文本 OCR；
- 剪贴板历史；
- 事项（EventKit，需要日历权限声明）；
- 活动监视；
- 暂存（文件放进容器）；
- Carbon 全局快捷键；
- 登录启动（SMAppService）。

**若硬要上架，只能做一个「MAS 精简版」**：去掉整个播放器、终端 / SSH / SFTP / 端口转发。去掉的部分等于一半核心功能，不建议。

截图原来用的 `CGDisplayCreateImage` 在 SDK 头文件里标为 `SCREEN_CAPTURE_OBSOLETE(10.6,14.4,15.0)`（最低版本设到 15 就编译不过）。1.7.1 起已改用 ScreenCaptureKit，最低系统版本提到 macOS 14。

## 三、Developer ID + 公证要做什么

1. 加入 Apple Developer Program，在钥匙串里装好「Developer ID Application」证书。
2. 签名：

   ```bash
   codesign --force --options runtime --timestamp \
     --entitlements Resources/OmniHub.entitlements \
     --sign "Developer ID Application: <名字> (<TEAMID>)" build/OmniHub.app
   ```

   这里的 `--options runtime`（Hardened Runtime）和日历权限声明，1.7.0 的 `build.sh` 已经带上了。

   MediaBridge.dylib 也要用同一张证书签名，并带 `--timestamp`。
3. 公证并装订：

   ```bash
   ditto -c -k --keepParent build/OmniHub.app OmniHub.zip
   xcrun notarytool submit OmniHub.zip --keychain-profile <profile> --wait
   xcrun stapler staple build/OmniHub.app
   ```

4. 公证会扫描私有 API 吗？公证查的是恶意软件和签名，不做审核指南层面的审查。所以 MediaRemote 不影响公证，但不保证以后的系统版本不再收紧。

## 四、安全评估

先说预期：**项目是开源的，安全不能靠藏代码。**

- 实测 `nm -U build/OmniHub-arm64 | wc -l` 有 8721 个符号；
- `strings` 能直接看到类名、自测入口和调试路由的名字。

所以防护重点不是混淆，而是三件事：

- 客户端里不放任何秘密；
- 用签名和 Hardened Runtime 防篡改、防注入；
- 关掉能被外部利用的入口。

现状：

- **不放秘密：已满足。** 源码里没有硬编码的密钥或口令；网络请求只有歌词（`music.163.com`、`lrclib.net`）和可选的公网 IP 查询（`api.ipify.org`），全是 HTTPS。
- **保险库密码：已满足。** 存在钥匙串里，`connections.json` 里只有条目 ID，并且是 0600 权限；`./test-remote.sh` 里有检查。

### 本轮已修复

| 级别 | 问题 | 处理 | 验证 |
|---|---|---|---|
| 高 | **askpass 泄露保险库密码**：应用本身兼作 ssh 的 `SSH_ASKPASS`。任何本机进程只要设置环境变量 `OMNIHUB_ASKPASS_SECRET=<条目ID>` 再运行 OmniHub 的可执行文件，就能拿到明文密码。钥匙串把它当成 OmniHub 本身，不弹提示；条目 ID 就在 `connections.json` 里 | 只有当父进程是 `/usr/bin/ssh` 或 `sftp`、且那个 ssh 的父进程就是正在运行的 OmniHub 时才回答，其余一律拒绝 | `OmniHub --askpass-selftest`：修复前 `FAIL … got the vault password (exit 0)`，修复后 `PASS … (exit 1)`；`./test-remote.sh` 55 项全过，经 askpass 解锁私钥的登录照常 |
| 中 | **`omnihub://` 调试路由对外开放**：任何网页或 App 都能打开 omnihub 链接，能触发的包括：往终端里输入命令（`terminal-demo`）、把剪贴板图片写到磁盘（`debug/dump-clipboard`）、跳过录屏权限检查（`debug/snip-demo`）、把各窗口画成图片存盘（`snapshot`） | `debug/*`、`terminal-demo`、`escape`、`snapshot` 等改为默认无效，要先执行 `defaults write com.local.omnihub debug.urls -bool true` 才能用；`diagnose` 默认不再写剪贴板和事项的内容，只写数量 | 实测：默认打开 `omnihub://snapshot` 不产生文件，开了开关后才产生 |
| 中 | **没开 Hardened Runtime**：可以用 `DYLD_INSERT_LIBRARIES` 往进程里注入代码 | `build.sh` 签名加 `--options runtime`，并新增 `Resources/OmniHub.entitlements`。Hardened Runtime 下读日历必须声明这一项，否则 EventKit 直接拒绝 | 实测：注入 `libz.dylib` 时，未加固的二进制加载了 96 个库，加固后的 App 是 0，说明 DYLD 变量被忽略。用探针 App 对比：缺日历声明时请求 0.02 秒就被拒，带声明时等待用户授权（弹窗）。签名后 `codesign -dvv` 显示 `flags=0x10002(adhoc,runtime)` |

### 建议后续处理（本轮未改）

| 级别 | 问题 | 建议 |
|---|---|---|
| 中 | **本地数据明文**：剪贴板历史（已跳过密码管理器标记的内容）、事项、暂存文件在 `~/Library/Application Support/OmniHub/`；除了 `connections.json` 是 0600，其余文件是 0644（实测 `stat`） | 目录和文件统一改成 0700 / 0600。剪贴板历史可选加密：用 CryptoKit AES-GCM，密钥放钥匙串 |
| 中 | **桥接 dylib 可被替换**：`/usr/bin/perl` 从 App 包里加载 `MediaBridge.dylib`。perl 是 Apple 签名的进程，不会校验这个 dylib 是谁签的。如果 App 包可写，替换 dylib 就能在 perl 里执行代码 | 启动桥接前用 `SecStaticCodeCheckValidity` 校验 dylib 的签名与主程序是同一身份，不符就不启动。用 Developer ID 签名、放在 `/Applications`，还会受系统「App 管理」保护 |
| 中 | **同用户进程可改配置**：`connections.json` 可以被同一用户下的其他进程改写，比如把主机改成攻击者的服务器，用户一连接密码就发过去了 | 这是同用户权限的固有风险。可以缓解：钥匙串条目设成「每次访问都询问」（可选开关）；对保存过的主机记住指纹，变了就拒绝 |
| 低 | **首次连接自动接受主机指纹**：用保险库密码登录时用的是 `StrictHostKeyChecking=accept-new`，因为 askpass 没法回答 yes/no。第一次连接存在被中间人攻击的窗口；指纹变化仍会拒绝 | 首次连接时在应用里显示指纹，让用户确认后再连 |
| 低 | **自测和调试代码随正式包发布**：`--remote-selftest` 会往用户的 `connections.json` 写测试条目（结束后删除），`--askpass-selftest` 会写一个临时钥匙串条目 | 正式包用编译条件剔除，比如只在 `OMNIHUB_ADHOC=1` 时加 `-D OMNIHUB_SELFTEST`，这样也少暴露一些字符串 |
| 低 | **符号可读** | 可以 `strip -x` 去掉本地符号；Swift 的类型元数据仍然读得出来，商业混淆收益有限，不建议投入 |

## 五、怎么复现本文的实测

```bash
OMNIHUB_ADHOC=1 ./build.sh
A=build/OmniHub.app/Contents/MacOS/OmniHub
$A --askpass-selftest                                   # askpass 只回答 OmniHub 自己的 ssh
codesign -dvv build/OmniHub.app 2>&1 | grep flags       # 应含 runtime
codesign -d --entitlements - build/OmniHub.app          # 应含 personal-information.calendars
DYLD_INSERT_LIBRARIES=/usr/lib/libz.dylib DYLD_PRINT_LIBRARIES=1 $A --askpass-selftest 2>&1 | grep -c loaded   # 0
./test-remote.sh                                        # 55 项
nm -U build/OmniHub-arm64 | wc -l                       # 可读符号数
```

## 六、真要上 Mac App Store：推荐做法

前面几节的结论是「现在这一版上不了」。要上，推荐**一套代码、两个版本**，而不是把现有版本砍成沙盒版：

- **完整版**：Developer ID 签名 + 公证，官网 / GitHub 下载分发，保留全部功能（第三节）。
- **App Store 版**：编译时加 `-D OMNIHUB_MAS`，开 App Sandbox，用 `#if OMNIHUB_MAS` 去掉或替换沙盒里做不了的模块。

### 各模块在沙盒版里怎么处理

| 模块 | App Store 版 | 说明 |
|---|---|---|
| 截图、贴图 | 保留（已改用 ScreenCaptureKit） | 屏幕录制权限沙盒里可以申请；窗口识别仍用 `CGWindowListCopyWindowInfo`（未被标淘汰） |
| 长截图 | 保留 | 两个版本都只有手动滚动（自动滚动已在 1.7.1 去掉） |
| 剪贴板 | 保留 | 读写剪贴板不需要额外权限 |
| 事项 | 保留 | 已经声明日历权限（`com.apple.security.personal-information.calendars`） |
| 暂存 | 保留 | 文件放进应用容器；拖进来的文件本来就是复制一份 |
| 活动监视 | 保留 | 只读本机统计 |
| 全局快捷键、登录启动 | 保留 | Carbon 热键可用；登录启动改用 `SMAppService` |
| 正在播放 | 部分保留 | 私有框架 MediaRemote 和 perl 桥都不能用；Apple Music、Spotify 改走 AppleScript，声明 `com.apple.security.scripting-targets`；**网易云音乐做不到** |
| 本地终端 | 去掉 | 沙盒里不能起 shell |
| SSH / SFTP / 端口转发 | 改写 | 不能调系统的 `/usr/bin/ssh`，要内置 SSH 库（SwiftNIO SSH 或 libssh2），声明 `com.apple.security.network.client`；私钥由用户选取后存安全书签；`~/.ssh/config` 改为在应用里导入 |
| 依赖辅助功能的功能 | 去掉 | 播放器菜单路线 |

### 上架前要准备的

- 加入 Apple Developer Program（个人或公司）。
- 证书：Apple Distribution、Mac Installer Distribution；对应的 provisioning profile。
- 换掉 `com.local.omnihub`，用自己的反向域名 bundle id。
- 上传要用 Xcode 工程（或 `xcodebuild` + `altool` / Transporter）：现在的 `build.sh` 只用于完整版。
- `PrivacyInfo.xcprivacy`：声明用到的「需说明理由的 API」（UserDefaults、文件时间戳、磁盘空间）。
- App Store Connect：截图、描述、关键词、隐私政策网址、分级。
- 审核备注：说明为什么要屏幕录制（截图）和日历（事项）权限，附操作步骤。
- 要收费的话用 StoreKit 内购，或者直接定价。

### 建议的顺序

1. 先把**完整版**做成 Developer ID + 公证，正式对外分发。
2. App Store 第一期：截图、贴图、剪贴板、事项、暂存、活动监视——都不依赖沙盒外的能力，改动最小。
3. 第二期：内置 SSH 库的终端（SSH / SFTP / 端口转发），以及 AppleScript 版的播放控制。
