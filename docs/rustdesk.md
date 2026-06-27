# RustDesk 客户端 深度分析报告

> 版本：1.4.8 | Rust edition 2021 (MSRV 1.75) | Dart SDK >=3.1.0
> 本报告基于源码扫描与模块级分析数据整理而成。

---

## 项目简介与定位

RustDesk 是一款开源的跨平台远程桌面应用（本报告聚焦其**客户端**部分）。其核心特性包括：

- **跨平台覆盖**：Windows / macOS / Linux / Android / iOS，并提供 Web 客户端变体。
- **端到端加密**：基于 NaCl/libsodium（Curve25519 密钥交换 + XSalsa20-Poly1305）实现 P2P 加密会话。
- **架构特点**：
  - 客户端通过 **RustDesk Rendezvous / Relay 服务器（hbbs / hbbr）** 完成设备发现与 NAT 穿透，建立 P2P 连接，必要时回落到 relay。
  - **多进程架构**：主 GUI 进程 + 后台 `--server` 进程，通过 Unix 域套接字（Linux/macOS）或命名管道（Windows）进行 IPC，并使用 UID/PID 与加密身份做认证。
- **功能矩阵**：屏幕共享、远程控制、文件传输、TCP 隧道（端口转发）、终端访问、剪贴板同步、音频转发、白板、远程打印（Windows）、虚拟显示（Windows）、隐私模式等。
- **UI 双轨制**：旧版 Sciter（HTML/CSS/TIScript，已弃用）与现行 Flutter/Dart UI（通过 `flutter` feature 切换）。

定位：面向个人与企业的开源 AnyDesk/TeamViewer 替代品，强调自托管能力（可对接私有 hbbs/hbbr）、隐私与跨平台一致体验。

---

## 技术栈

| 类别 | 技术 / 库 |
|---|---|
| 核心语言 | Rust (edition 2021，MSRV 1.75) |
| GUI 框架（现行） | Flutter / Dart (SDK >=3.1.0) |
| GUI 框架（遗留） | Sciter（HTML/CSS/TIScript，已弃用） |
| Rust ↔ Dart 桥接 | `flutter_rust_bridge` v1.80.1 |
| 异步运行时 | Tokio |
| 序列化 / RPC | Protobuf（`protobuf` crate）+ 自定义 Rendezvous 协议 |
| 加密 | NaCl / libsodium (`sodiumoxide`)：`box_`（Curve25519）、`secretbox`（XSalsa20-Poly1305）、`sign`（Ed25519） |
| 视频编解码 | libvpx (VP8/VP9)、libaom (AV1)、hwcodec/FFmpeg (H264/H265)、D3D11 VRAM 编解码 |
| 颜色空间 | libyuv |
| 音频 | CPAL（跨平台）、PulseAudio/PipeWire（Linux）、`magnum_opus`（Opus 编码） |
| 屏幕采集 | `libs/scrap`（DXGI/GDI/Quartz/X11/Wayland-PipeWire/Android-MediaCodec） |
| 输入注入 | `libs/enigo`（in-tree fork）、`rdev`、Linux `uinput`、Wayland RemoteDesktop portal |
| 剪贴板 | `libs/clipboard`（in-tree fork）、`clipboard_master` |
| 终端 | `portable_pty` |
| 网络 / TLS | `reqwest` + native-tls + rustls，自定义 `TlsType` 选择策略 |
| 数据库（UI 侧） | sqflite（Flutter 端地址簿缓存） |
| 渲染 | `texture_rgba_renderer`、`flutter_gpu_texture_renderer`、`xterm`（终端） |
| 包管理 / 构建 | Cargo、vcpkg（C/C++ 依赖）、Flutter pub |
| 打包 | Debian / RPM / PKGBUILD / AppImage / Flatpak / MSI / DMG |
| CI/CD | GitHub Actions（`flutter-build` / `flutter-ci` / `flutter-nightly` / `flutter-tag`） |

---

## 顶层目录结构

| 目录 | 作用 |
|---|---|
| `src/` | 核心 Rust 源码：main/lib、client、server、IPC、平台抽象、UI 桥、Rendezvous 中介、剪贴板、键盘、白板、隐私模式、端口转发、更新器等 |
| `src/server/` | 受控端服务：连接管理、音视频/输入/剪贴板/显示/终端/打印机服务、Wayland/uinput/RDP input 后端、Video QoS |
| `src/platform/` | 平台特定代码：Windows（含 C++/`windows.cc`）、macOS（含 Objective-C++/`macos.mm`）、Linux（X11/Wayland、桌面管理、GTK sudo） |
| `src/ui/` | 遗留 Sciter UI（HTML / TIScript），已被 Flutter 取代但仍编译 |
| `flutter/` | 现行 Flutter UI：桌面/移动页面、共享组件、Models、FFI 绑定、各平台 runner |
| `libs/hbb_common/` | 公共库（git submodule）：配置、protobuf 协议定义、网络抽象、TLS、日志、加密、文件传输 |
| `libs/scrap/` | 屏幕采集与视频编解码（DXGI/Quartz/X11/Wayland/Android） |
| `libs/enigo/` | 跨平台键盘鼠标输入模拟（in-tree fork） |
| `libs/clipboard/` | 跨平台剪贴板（多格式）|
| `libs/virtual_display/` | Windows 虚拟显示驱动（RustDesk IDD） |
| `libs/portable/` | Windows 免安装运行的便携服务 |
| `libs/remote_printer/` | Windows 远程打印机驱动 |
| `res/` | 资源与打包脚本：图标、DEB/RPM/PKGBUILD/AppImage/Flatpak、systemd unit、桌面入口、vcpkg overlay |
| `docs/` | README 翻译、CONTRIBUTING、CODE_OF_CONDUCT、SECURITY |
| `.github/workflows/` | CI/CD：Flutter 构建、桥接器代码生成、F-Droid、cliprdr 等 |

---

## 入口与启动流程

RustDesk 客户端的入口经过精心分层，根据编译特性与命令行参数路由到不同模式。

### 关键入口文件

| 文件 | 作用 |
|---|---|
| `src/main.rs` | 顶层二进制入口。根据 feature 派发到桌面 `core_main`（Flutter）、CLI 模式或移动平台入口 |
| `src/lib.rs` | 根库模块 `librustdesk`，crate 类型为 `cdylib + staticlib + rlib`，导出 platform/server/client/ipc/ui/flutter/common/clipboard/whiteboard 等模块 |
| `src/core_main.rs` | 桌面核心初始化：解析 CLI（`--connect`、`--install`、`--server`、`--tray` 等），启动服务线程，拉起 Flutter UI |
| `flutter/lib/main.dart` | Flutter UI 入口，统管多窗口（主窗口、远程桌面、文件传输、端口转发、终端、摄像头）与移动端单窗口导航 |
| `src/server.rs` | 受控端 host：监听传入连接，挂载音视频/输入/剪贴板/终端服务 |
| `src/client.rs` | 控制端 peer：通过 rendezvous/relay/direct 连接到远端并完成会话协商 |
| `src/rendezvous_mediator.rs` | 与 hbbs 交互：注册 ID、NAT 打洞、请求中继 |
| `src/flutter_ffi.rs` | Flutter-Rust FFI 桥接（基于 flutter_rust_bridge） |
| `src/ipc.rs` | 主 UI 与后台 `--server`/CM 进程之间的 IPC |
| `src/naming.rs` | 独立二进制：DNS naming 解析 |
| `src/service.rs` | 独立二进制：systemd `--service` 模式 |

### 启动序列

```
main()
 └─► common::global_init()
      └─► core_main()  // 解析 CLI 参数
           ├─► --server / --cm   ── 启动服务子进程（屏幕捕获 + 输入注入）
           ├─► --connect ID      ── 直接发起远控会话
           ├─► --install/...     ── 安装/卸载/更新服务流程
           └─► （默认）         ── 启动主 GUI 进程，spawn `--server` 子进程
                                    并通过 IPC 通信
```

后续：

1. 服务端 host：监听 TCP/UDP → 注册 Service（video/audio/clipboard/input）→ 等待 Login → 验证密码/2FA → 建立 Session → 推送视频/音频/事件流。
2. 客户端：`Client::start()` → `rendezvous_mediator` 注册 → NAT 打洞或中继协商 → 建立 TCP/WebSocket → Login/LoginResponse → 启动 `io_loop` 处理 protobuf 消息。

---

## 核心模块详解

### src/ — 客户端核心

- **职责**：实现完整的远程桌面客户端 + 服务端骨架，包括服务端模块、客户端模块、Rendezvous 中介、UI 桥、IPC、跨平台抽象、剪贴板/端口转发/白板/插件/隐私模式/自动更新/多语言/2FA 等。
- **关键文件**：`main.rs`、`lib.rs`、`core_main.rs`、`client.rs`、`server.rs`、`rendezvous_mediator.rs`、`flutter.rs`、`flutter_ffi.rs`、`ipc.rs`、`ui_interface.rs`、`ui_session_interface.rs`、`ui_cm_interface.rs`、`hbbs_http/*`、`keyboard.rs`、`clipboard.rs`、`port_forward.rs`、`privacy_mode.rs`、`updater.rs`、`tray.rs`、`auth_2fa.rs`、`cli.rs`。
- **对外接口**：
  - 对 Flutter UI：`flutter_ffi.rs` 的 FFI 函数（如 `rustdesk_core_main`、`push_global_event`）。
  - 对子进程：`ipc.rs` 的 `Data` 枚举消息（登录、配置、控制命令）。
  - 对 hbbs/hbbr：经 `rendezvous_mediator.rs` 与 `hbbs_http/*` 发送 protobuf / HTTP 请求。
- **交互**：
  - hbbs（UDP/TCP @ `RENDEZVOUS_PORT`）：`RegisterPeer` / `PunchHole` / `RequestRelay`。
  - hbbr（TCP @ `RELAY_PORT`）：P2P 失败时中继转发。
  - hbbs HTTP API：账号登录、地址簿同步、设备列表（`/api/*`）。
  - 客户端 ↔ 服务端：TCP/WebSocket + protobuf（`Message`/`VideoFrame`/`AudioFrame`/`Clipboard`）。
- **数据流 / 状态机**：
  1. 启动 → `global_init` → `core_main` → 选择 server/cm/client/main UI 模式。
  2. 服务端：监听 → 注册服务 → 等待 Login → 验证 → 建会话 → 推流。
  3. 客户端：Rendezvous 注册 → 打洞/中继 → 建连 → Login/LoginResponse → `io_loop` 收发。
  4. 视频：scrap 捕获 → 编码 → `VideoFrame` protobuf → 客户端解码 → Flutter Texture。
  5. 输入：Flutter → `InputEvent` protobuf → `input_service` 注入。
  6. IPC：主进程 ↔ CM 子进程，通过 `Data` 枚举。
- **风险与待改进**：
  - `client.rs`（~156 KB）与 `common.rs`（~99 KB）体量巨大，职责混杂。
  - 平台条件编译散布密集（`cfg_if!`/`cfg`），覆盖率难以保证。
  - Sciter UI 已弃用但仍残留代码与注释（如相对鼠标模式说明）。
  - Linux Wayland 支持不完整（登录屏幕 Wayland 明确不支持）。
  - `virtual_display_manager.rs` 仅 Windows，`printer_service.rs` 仅 Windows+Flutter，`clipboard_file.rs` 不支持 Android/iOS。
  - IPC 无版本协商机制，新旧版本进程可能通信失败。
  - 大量 `lazy_static!` 全局 `Arc<Mutex<>>` 状态，存在死锁与状态泄漏风险。
  - 插件系统仅在 `flutter+plugin_framework` feature 下可用。

### src/server/ — 受控端核心服务

- **职责**：作为被控端，提供屏幕共享、远程控制、文件传输、剪贴板/音频/终端等完整服务。基于 Service / Subscriber 发布-订阅框架协调多路服务。
- **关键文件**：`connection.rs`（~257 KB，~6000 行）、`service.rs`、`video_service.rs`、`input_service.rs`、`audio_service.rs`、`clipboard_service.rs`、`display_service.rs`、`portable_service.rs`、`terminal_service.rs`、`terminal_helper.rs`、`video_qos.rs`、`login_failure_check.rs`、`rdp_input.rs`、`wayland.rs`、`dbus.rs`、`uinput.rs`、`printer_service.rs`。
- **对外接口**：通过 protobuf 消息与客户端通信（`LoginRequest/Response`、`VideoFrame`、`AudioFrame`、`Clipboard`、`KeyEvent`、`MouseEvent`、`CursorData`、`PeerInfo`、`TerminalData`、`FileTransfer*`、`VoiceCallRequest/Response`、`TestDelay`、`SwitchDisplay`、`Resolution`、`Misc`）。
- **交互**：
  - `scrap`：`Display::all()`、`Capturer::new()`、`TraitCapturer::frame()`、`Encoder/EncoderCfg`、`HwRamEncoder`/`VRamEncoder`。
  - `enigo` / `rdev`：鼠标键盘注入；Linux `uinput`；Wayland D-Bus RemoteDesktop portal（`rdp_input`）。
  - `portable_pty`：终端 PTY。
  - `magnum_opus`：音频编码。
  - `hbb_common::config`：密码（permanent/temporary/keypair）、TrustedDevice、2FA 密钥。
  - `crate::ipc`：portable_service 在 Windows 上通过命名管道+共享内存与子进程通信。
  - `crate::auth_2fa`、`crate::privacy_mode`、`crate::virtual_display_manager`、`crate::hbbs_http::sync::signal_receiver`。
- **数据流 / 状态机**：
  1. **Connection 生命周期**：TCP 接入 → 建立 mpsc 通道 → 鉴权（密码/密钥对/2FA）→ 订阅各 Service（video/audio/clipboard/display）→ Service 通过 `ServiceTmpl<ConnInner>` 发布-订阅模式向订阅者发送 protobuf。
  2. **视频流**：`scrap` 捕获 → VPX/AOM/HW 编码 → `VideoFrame` → 通过 `tx_video` 通道发送；`VideoFrameController` 维护每显示器帧时序。
  3. **输入流**：客户端 `KeyEvent`/`MouseEvent` → `MessageInput` std_mpsc → input_service worker 翻译为 OS 事件注入。
  4. **剪贴板流**：监听 OS → `Clipboard`/`ClipboardFile` → 推送给订阅连接；反向接收后写入 OS。
  5. **音频流**：PA/CPAL/Android 捕获 → Opus 编码 → `AudioFrame` → 群发到所有订阅。
  6. **终端流**：每会话独立 `TerminalService`，PTY master/slave → 输出读取线程 → `TerminalData` → 客户端；输入写回 PTY stdin。
  7. **QoS**：客户端 `TestDelay` 响应 → `VideoQoS::update_delay()` → 调整 fps/quality → 反馈至 video_service 编码循环。
  8. **Service 状态机**：`ServiceTmpl.active` + `has_subscribes()`；订阅者存在时回调循环运行，最后一位订阅者离开时 `state.reset()`；`ServiceSwap` 模式给新订阅者发送初始快照。
- **风险与待改进**：
  - `connection.rs` 单体过大（约 6000 行），承担连接管理、鉴权、消息路由、文件传输、终端、端口转发等过多职责。
  - `Arc<RwLock<ServiceInner>>` 在视频帧分发（`send_video_frame_shared`）等高频场景下持写锁，可能成为瓶颈。
  - `video_service` 中 Capturer 创建失败缺乏优雅降级，部分平台组合可能 panic。
  - `portable_service` 使用硬编码偏移量的 Windows 共享内存 IPC，跨版本兼容性脆弱且缺少访问控制。
  - `terminal_service` Windows 实现复杂（`CreateProcessAsUserW` + 命名管道 + helper 进程），错误路径多、僵尸检查可能遗漏。
  - 隐私模式在 Windows 之外多为 stub。
  - Linux 音频依赖外部 PulseAudio helper 进程（`_pa`），崩溃恢复不完善。
  - `VideoQoS` 基于启发式阈值（如 150ms 固定值），未使用 GCC/BBR 等标准拥塞控制。
  - `login_failure_check` 使用静态全局 Mutex + 位移退避计算，存在竞用与极端溢出风险。
  - 多个 `lazy_static!` 全局可变状态（`SESSIONS`、`ALIVE_CONNS`、`AUTHED_CONNS`、`WAKELOCK_SENDER` …）使测试困难。
  - Wayland 仍在完善中：`rdp_input.rs` D-Bus portal API 仅部分实现，`cursor_embedded` 支持有限。
  - 跨平台条件编译分支极多，iOS 几乎无实际测试。

### src/platform/ — 跨平台抽象层

- **职责**：约 14,462 行代码，17 个源文件，封装 Windows/Linux/macOS 三平台的系统级操作（服务管理、权限提升、用户会话、光标/显示、输入、安装/更新、虚拟显示、桌面环境检测等）。
- **关键文件**：`mod.rs`、`windows.rs`（4698 行）、`linux.rs`（2330 行）、`macos.rs`（1230 行）、`windows.cc`、`macos.mm`、`windows/acl.rs`、`win_device.rs`、`linux_desktop_manager.rs`、`gtk_sudo.rs`、`delegate.rs`、`privileges_scripts/*.{plist,scpt}`。
- **对外接口**：被 `flutter_ffi.rs`、`core_main.rs`、`server/connection.rs`、`server/video_service.rs`、`keyboard.rs`、`virtual_display_manager.rs` 等广泛调用。Windows C++ FFI（`get_active_user`、`get_session_user_info`、`is_service_running_w`），macOS Obj-C++ FFI（`CanUseNewApiForScreenCaptureCheck`、`MacCheckAdminAuthorization`、`MacSetPrivacyMode` 等）。
- **交互**：
  - 系统服务管理器：Windows `sc.exe`、Linux `systemctl`、macOS `launchctl` + LaunchDaemon/Agent plist。
  - 安全框架：Windows ACL（`SetNamedSecurityInfoW`）、macOS TCC（`AXIsProcessTrustedWithOptions`、`CGPreflightScreenCaptureAccess`、`IOHIDCheckAccess`）、Linux polkit/sudo。
  - 注册表（Windows）、X11/Wayland（Linux）、CoreGraphics（macOS）、SetupAPI + 虚拟显示驱动（Amyuni IDD）、PAM（headless 会话）。
  - macOS 通过 `osascript` 执行 `install.scpt`/`uninstall.scpt`/`update.scpt`。
- **数据流 / 状态机**：
  1. 服务生命周期：`install_service` → 注册系统服务 → `start_os_service` 每 300 ms 轮询用户切换/桌面变更 → 重启子进程。
  2. 安装/更新：`install_me` → 复制可执行文件 → 写注册表/systemd unit/Launch plist → 启动服务；`update_me` → kill 旧进程 → 替换 → 重启。
  3. 用户态进程：服务以 root/SYSTEM 运行 → 检测活跃用户 → `run_as_user` 以用户身份 spawn `--server` 子进程。
  4. WallPaperRemover / WakeLock：以 RAII 模式在连接建立时启用、断开时 Drop 恢复。
  5. Linux 权限提升：`run_cmds_privileged` → `gtk_sudo::run()` → 重新 spawn 自身（带 `-gtk-sudo`）→ forkpty + sudo → 弹密码对话框或直 exec。
  6. Linux 桌面会话检测：通过 logind / seat0 与 `/proc/<pid>/environ` 获取 DISPLAY/WAYLAND_DISPLAY/XAUTHORITY/DBUS_SESSION_BUS_ADDRESS。
  7. Windows Session 0 隔离：服务跑在 Session 0 → `WTSQueryUserToken` + `CreateProcessAsUser` 跨会话拉起 UI 进程。
- **风险与待改进**：
  - 多处 TODO：macOS 分辨率比较待验证；Android `get_active_username` 未实现；Linux 光标数据为 0 的处理、stop server 子进程不正确；macOS 服务启停重构待统一；Windows `is_process_running_as_system` 待迁移到新 `windows` crate API。
  - Linux `block_input`/`toggle_blank_screen` 为空实现。
  - 32 位 Windows 进程在 64 位 OS 下 `sysinfo` 不返回 cmd，需要 wmic 回退。
  - X11 `BadWindow` 错误可能导致崩溃，自定义 `XSetErrorHandler` 仅缓解。
  - Ubuntu 25.10 `sudo -E` 行为差异（通过 sentinel 检测）。
  - macOS 屏幕录制权限检测分 10.14/10.15/11+ 三套 API，兼容性脆弱。
  - `install_service` / `uninstall_service` 直接 `std::process::exit(0)`，跳过 Drop 清理。
  - `/proc` 读取存在 TOCTOU 竞态。
  - `is_installed_daemon` / `update_daemon_agent` 重复代码多，注释明示合并需谨慎。
  - Windows 服务安装大量注册表与 shell 命令拼接，部分未做 `shell_quote`。
  - `WallPaperRemover` 的 Drop 在 `panic=abort` 下不会触发，壁纸无法恢复。
  - `linux_desktop_manager` 的 PAM 认证依赖标准 systemd 配置，非主流发行版可能失败。

### src/ui/ — 遗留 Sciter UI

- **职责**：提供基于 Sciter 引擎（HTML/CSS/TIScript）的桌面 GUI（主窗口、远控会话、连接管理、文件传输、消息框）。是即将被 Flutter 完全取代的旧 UI。
- **关键文件**：`remote.rs`（~935 行）、`cm.rs`（~198 行）、`remote.tis/html`、`cm.html`、`index.tis/html`、`common.tis`、`msgbox.tis`、`ab.tis`、`file_transfer.tis`、`header.tis`、`grid.tis`、`install.tis`、`port_forward.tis`、`printer.tis`。
- **对外接口**：
  - `SciterSession`（`remote.rs`）实现 `InvokeUiSession`，接受 Rust 客户端层回调（`set_cursor_data`、`set_display`、`on_rgba`、`set_peer_info`、`set_displays`、`msgbox`、`job_progress`、`update_quality_status` 等）。
  - `SciterConnectionManager`（`cm.rs`）实现 `InvokeUiCM`（`add_connection`、`remove_connection`、`new_message`、`change_theme`、`change_language`、`show_elevation`、`update_voice_call_state`）。
  - TIScript → Rust：经 `sciter::dispatch_script_call!` 暴露 60+ 个 `SciterSession` 方法、17 个 `SciterConnectionManager` 方法。
  - Rust → TIScript：通过 `Element::call_method()` 调用 `setCursorData`、`setDisplay`、`updatePi`、`updateDisplays`、`jobProgress`、`msgbox_retry` 等。
- **交互**：
  - HTTP API：通过 `sciter view.request` 直接 `POST /api/login`、`/api/logout`、`/api/currentUser`，使用 Bearer token。
  - 进程：`crate::run_me()` 为 `--file-transfer` 和 `--port-forward` 子窗口各 spawn 独立 Sciter 进程。
- **数据流**：
  1. 主窗口：`index.html` 由 Sciter 加载 → 事件分发到 `SciterConnectionManager` → 启动 IPC listener → 收到连接事件触发 `InvokeUiCM` 回调 → JS 桥更新 TIScript UI。
  2. 远控会话：UI `createNewConnect()` → `handler.new_remote()` → spawn 新进程或加载 `remote.html` → `SciterSession::on_event` 处理 `VIDEO_BIND_RQ` → `reconnect()` 启动连接。
  3. 视频/输入：`InvokeUiSession` 回调 → 调用 TIScript 方法渲染。
  4. 文件传输：UI → `dispatch_script_call!` → Session 方法 → 网络 → 回调 `update_folder_files`/`job_progress`。
  5. 状态轮询：`checkConnectStatus()` 每 1s 轮询 `service_stopped`、`key_confirmed`、`connect_status`、`system_error`。
- **风险**：
  - 整个模块标记为"遗留/弃用"。
  - 终端功能未实现（`handle_terminal_response()` 为带 TODO 的桩）。
  - `set_fingerprint()`、`switch_back()`、`portable_service_running()`、`set_platform_additions()`、`file_transfer_log()` 均为空实现。
  - 全局静态 `VIDEO`（`Arc<Mutex<Option<Video>>>`）意味着同时只能渲染一路视频，多会话冲突。
  - 黑色光标 hack：强制 `colors[3]=1` 以避免 Sciter 将全黑光标渲染为黑块。
  - TIScript 中 `password_cache` 在脚本内存中明文存放临时密码。
  - `index.tis` 1s 轮询而非事件驱动。
  - `get_key_event()` 中各平台键码用硬编码 `match` 维护成本高。
  - 自动更新逻辑部分被注释。

### flutter/ — 现行 Flutter UI

- **职责**：跨全平台（Windows/macOS/Linux/Android/iOS/Web）的现代 UI，业务逻辑全部通过 FFI 委托给 Rust。
- **关键文件**：`lib/main.dart`、`lib/common.dart`（4242 行）、`lib/consts.dart`、`lib/models/model.dart`（4223 行）、`lib/models/peer_model.dart`、`lib/models/platform_model.dart`、`lib/models/input_model.dart`、`lib/models/server_model.dart`、`lib/models/state_model.dart`、`lib/common/shared_state.dart`、`lib/utils/multi_window_manager.dart`、`lib/common/hbbs/hbbs.dart`、`lib/desktop/pages/desktop_tab_page.dart`、`lib/plugin/manager.dart`、`pubspec.yaml`。
- **对外接口**：
  - Rust 桥：`flutter_rust_bridge` 生成的 `bind`（`RustdeskImpl`）暴露 `bind.main*()`、`bind.session*()`、`bind.peer*()`、`bind.cm*()`、`bind.plugin*()` 等。
  - 子窗口 IPC：`desktop_multi_window.DesktopMultiWindow.invokeMethod()`，消息如 `kWindowConnect`、`kWindowEventNewRemoteDesktop`。
  - 原生平台：`MethodChannel('org.rustdesk.rustdesk/host')`，方法 `bumpMouse`、`setWindowTheme`、`terminate`。
- **交互**：
  - HTTP（`http` 包）→ hbbs API：`/api/ab`（地址簿 CRUD）、`/api/ab/peers`、`/api/login`、`/api/audit`，Bearer token。
  - `url_launcher`/`uni_links`：处理深度链接 `rustdesk://<peer-id>?password=xxx`。
  - `sqflite`：本地 SQLite 缓存地址簿/用户数据。
  - `window_manager`：原生窗口控制。
  - `texture_rgba_renderer` / `flutter_gpu_texture_renderer`：远程图像帧渲染。
  - `xterm`：终端模拟器。
  - `file_picker` / `desktop_drop`：文件选择与拖放。
- **数据流 / 状态机**：
  1. 应用启动：`main()` → 平台分支 → `initEnv()` → `initGlobalFFI()` → 注册事件处理 → `runApp()`。
  2. 远控发起：`connect(id)` → `bind.mainHandleRelayId()` → `rustDeskWinManager.newRemoteDesktop()` → `DesktopMultiWindow.createWindow()` → `runMultiWindow()` → `bind.sessionLogin()` → `FfiModel.startEventListener()` 接收 `peer_info`/`connection_ready`/`switch_display` 等事件。
  3. 多窗口：主窗口创建 RD/FileTransfer/ViewCamera/PortForward/Terminal 子窗口，关闭时保存位置。
  4. 图像帧：Rust → FFI `onRgba` → `ImageModel.decodeAndUpdate` → `notifyListeners` → Canvas/Texture 重绘。
  5. 输入：Flutter `PointerEvent`/`KeyEvent` → `InputModel` → `CanvasModel` 坐标换算 → `bind.sessionInputMouse/Key`。
  6. CM 服务端：`ServerModel` 管理 `connectStatus`、`verificationMethod`、`clients`，监听 `add_connection`/`on_client_remove`。
  7. 地址簿：`AbModel` ↔ hbbs HTTP API ↔ sqflite 本地缓存。
  8. 主题/语言：`MyTheme.changeDarkMode()` → `bind.mainSetLocalOption/mainChangeTheme` → 通过 `kWindowActionRebuild` 通知所有子窗口。
  9. 插件：`pluginManager` 加载描述并将 UI 注册到 toolbar/remote/settings 位置，接收 `plugin_event`/`plugin_reload`。
- **风险**：
  - `common.dart`（4242 行）与 `model.dart`（4223 行）耦合度高、职责混杂。
  - TODO/FIXME 堆积（`setViewOnly` 方法注释明确写出"current our flutter code quality is fucking shit now"，并以 try-catch 掩盖崩溃）。
  - Android `AccessibilityListener` 为绕过 Flutter pointer size=1 bug 的临时方案。
  - 移动/桌面页面（`mobile/pages/` vs `desktop/pages/`）功能重复、未抽象。
  - Web 端通过 `if dart.library.html` 条件导入，部分功能不可用。
  - 相对鼠标模式（RMM）涉及跨窗口 pointer lock、keyboard grab loop（rdev）、版本兼容、权限丢失自动释放等多层逻辑。
  - 多窗口消息通过 JSON 传递，无类型安全。
  - 窗口位置保存/恢复在不同平台特殊处理多（DPI、GTK resize、macOS titlebar），有 `kUseCompatibleUiMode` 兼容标志。
  - `flutter_rust_bridge` 锁定 1.80.1（较老），升级潜在 breaking changes。
  - `sqflite` 锁定 2.2.0，可能与新版 Flutter SDK 不兼容。
  - 主题未完全迁移至 `ColorThemeExtension`，部分组件硬编码颜色。
  - 插件 UI 通过 `HashMap<String, UiType>` 注入，缺类型安全。
  - 移动端深度链接 `rustdesk://password`/`rustdesk://config` 即便已 opt-in 也有滥用风险。

### libs/hbb_common/ — 共享基础库

- **职责**：作为整个 RustDesk 生态（客户端/服务端 hbbs/hbbr）的共享 crate（独立 git submodule），统一通信协议、网络、配置、加密、TLS、SOCKS5、文件传输、压缩、设备指纹、崩溃信号处理等基础设施。
- **关键文件**：`Cargo.toml`、`build.rs`、`src/lib.rs`、`src/config.rs`、`src/tcp.rs`、`src/udp.rs`、`src/stream.rs`、`src/socket_client.rs`、`src/proxy.rs`、`src/websocket.rs`、`src/tls.rs`、`src/compress.rs`、`src/fs.rs`、`src/bytes_codec.rs`、`src/password_security.rs`、`src/fingerprint.rs`、`src/verifier.rs`、`src/platform/mod.rs`、`src/mem.rs`、`src/keyboard.rs`、`protos/message.proto`、`protos/rendezvous.proto`。
- **对外接口**：
  - 协议：`message.proto`（93 个消息类型）、`rendezvous.proto`（26 个消息类型）。`build.rs` 调用 `protobuf_codegen` 生成 Rust 代码到 `OUT_DIR/protos/`，`lib.rs` 经 `include!` 包含。
  - 传输：`Stream` 枚举封装 TCP/WebSocket/WebRTC；`FramedStream` 端到端加密；`FramedSocket` 处理 UDP/SOCKS5 UDP。
  - 配置：`Config`、`Config2`、`PeerConfig`、`LocalConfig` 结构体，JSON 持久化 + 加密字段。
  - TLS：`verifier`（`NoVerifier` / WebPki）；`tls` 缓存 `TlsType` 与 `accept_invalid_cert`（Plain/NativeTls/Rustls）。
  - 文件：`fs::TransferJob`，分块传输、断点续传（`digest`）、目录递归、路径遍历防护。
- **交互**：
  - 被客户端 `src/client.rs`、服务端 `src/server/connection.rs`、`rendezvous_mediator.rs`、`hbbs_http/*`、`ipc.rs`、`platform/*`、`flutter_ffi.rs`、`ui_session_interface.rs` 等广泛引用。
  - 与外部 API：`version_check_request()` → `https://api.rustdesk.com/version/latest`。
  - 与 hbbs/hbbr：通过 rendezvous.proto 中 `RegisterPeer`/`RegisterPk`/`PunchHole`/`RequestRelay`/`OnlineRequest`/`HttpProxyRequest/Response`。
- **数据流 / 状态机**：
  - 加密：`FramedStream::set_key()` 设置 sodiumoxide `secretbox` Key → 收发递增 nonce。
  - 网络：`socket_client::connect_tcp()` → 视配置走 SOCKS5（`Proxy::connect`）或 WebSocket（`ws/wss`）。
  - TLS 缓存：`tls::upsert_tls_cache()` 按 `domain+port` 缓存策略；`websocket::try_connect()` 失败时递归 fallback。
  - 文件：`TransferJob::new_write/new_read` → `init_data_stream` → 块级 read/write → `confirm` → `serialize_transfer_job`。
  - 密码：`temporary_password()` 8 位随机；`encrypt_str_or_original()` / `decrypt_str_or_original()` 使用 secretbox，并兼容老格式重写。
  - 指纹：`get_fingerprinting_info()` → SHA-512 hash → 用于版本检查与身份。
  - 崩溃处理：`register_breakdown_handler()` 注册 SIGSEGV → 捕获 backtrace → 检测 GPU/硬编驱动崩溃 → 设置 fallback 选项 → `exit(0)`。
  - UDP 打洞：`FramedSocket::new_reuse()` + `socket_client::new_udp_for()`。
  - 在线状态：`Config::update_latency()` → 全局 `ONLINE: HashMap`。
  - `AddrMangle::encode/decode`：用时间戳 XOR 混淆 IPv4 地址+端口，规避路由器扫描干扰。
- **风险**：
  - 当前仓库的 `libs/hbb_common` 子模块未初始化（commit `a920d00`），本地无法直接查看源码。本节分析基于 GitHub 远程内容。
  - protos 生成依赖 `build.rs`，未执行构建时无法看到生成结构。
  - `proxy.rs` 使用 `#[async_recursion]` 递归重试，调试困难。
  - `config.rs` 极大、`keys` 模块定义大量常量；多 `lazy_static` 加 `RwLock`/`Mutex` 存在锁竞争风险。
  - 密码加密需兼容 v1 与零 nonce 遗留数据，格式演进有安全风险。
  - `fingerprint` 模块自实现 AES-128 S-box、MixColumns 与 SHA-512，存在实现正确性 / 侧信道风险。
  - `mem.rs` 中 `aligned_u8_vec` 使用 unsafe，返回的 `Vec` 不可 resize/reserve，误用会 UB。
  - WebSocket TLS 递归 fallback 理论上可能无限递归。
  - 平台条件编译分散，覆盖测试困难。
  - 依赖 `sodiumoxide`，社区已停止维护，是潜在安全维护风险。

### libs/scrap/ — 屏幕采集 + 视频编解码

- **职责**：跨平台屏幕/摄像头采集（Windows DXGI/GDI、macOS Quartz、Linux X11/Wayland-PipeWire、Android MediaCodec），视频编解码（VP8/VP9/AV1/H264/H265），颜色空间转换（libyuv），并将编码帧写入 WebM/MP4 录制文件。
- **关键文件**：`src/lib.rs`、`src/common/{mod,codec,hwcodec,convert,vpxcodec,aom,record,camera,vram,dxgi,quartz,x11,linux,wayland,mediacodec}.rs`、`src/dxgi/{mod,gdi,mag}.rs`、`src/quartz/*`、`src/x11/*`、`src/wayland/{mod,pipewire,display,capturable,remote_desktop_portal,screencast_portal}.rs`、`src/android/ffi.rs`、`build.rs`、`Cargo.toml`。
- **对外接口**：
  - `Encoder::supported_encoding()`、`Encoder::update()`、`Encoder::usable_encoding()`、`EncodingUpdate`、`Quality`、`BR_BALANCED/BEST/SPEED`、各平台 `Capturer`、`Decoder`。
  - Wayland：`pipewire::try_close_session()`；Android：`call_main_service_key_event`、`pointer_input`。
  - 协议：通过 `hbb_common::message_proto::VideoFrame`/`EncodedVideoFrames` 与对端通信。
- **交互**：
  - 上游：`src/server/connection.rs`、`server/video_qos.rs`、`server/display_service.rs`、`server/portable_service.rs`、`src/client.rs`、`src/ui_session_interface.rs`、`src/flutter_ffi.rs`、`src/hbbs_http/record_upload.rs`。
  - 底层：libyuv（颜色空间，C FFI）、libvpx（VP8/VP9）、libaom（AV1）、`hwcodec` crate（FFmpeg 封装，VAAPI/VDPAU/NVENC/QSV/VideoToolbox/MediaCodec）、`nokhwa`（摄像头）、gstreamer（Wayland PipeWire）、dbus（XDG Portal）、`webm` crate（WebM）、winapi（DXGI）。
- **数据流 / 状态机**：
  1. 采集 → 颜色空间转换（libyuv）→ 编码（VPx/AOM/HW）→ `EncodedVideoFrames` → 网络。
  2. VRAM 路径：DXGI texture → D3D11 texture sharing → GPU 编码器（H264/H265）→ 对端 GPU 解码。
  3. 录制：编码帧 → `Recorder` → WebM（VP8/VP9/AV1）或 MP4（H264/H265 via hwcodec）。
  4. 解码：`VideoFrame` → 选择 `VpxDecoder` / `AomDecoder` / `HwRamDecoder` / `VRamDecoder` / `MediaCodecDecoder` → RGB/GPU texture → Flutter 渲染。
  5. 编解码协商状态机：peer 接入 → 交换 `SupportedDecoding`/`SupportedEncoding` → `Encoder::update()` 聚合所有 peer 能力 → 选最优共有 codec → 设置全局 `ENCODE_CODEC_FORMAT` → 变更时重建编码器。
  6. HW codec 配置生命周期：`--check-hwcodec-config` 子进程探测 → JSON 序列化 → IPC → 主进程缓存（带 GPU signature）→ 编/解码失败时清空。
  7. 摄像头：`nokhwa` → 同样的编解码管线。
- **风险**：
  - 多处 TODO：非 quartz/x11/dxgi/android 平台缺少 Capturer fallback；X11 SHM 禁用/不支持未分离；X11 display 可能泄漏；Quartz 色彩空间未实现；`HwRamDecoder` 仅处理最后一帧；macOS 摄像头 PixelBuffer 无法从 bytes 创建；Android MediaCodec 编码器未实现。
  - VRAM 编解码仅 Windows 可用，依赖 D3D11 纹理共享，虚拟机/非主流 GPU 受限。
  - 32 位平台禁用 AV1（aom 在 x86 Sciter 版本太慢）。
  - Wayland PipeWire 兼容性依发行版差异大，`persist_mode` 未实现。
  - DXGI 失败回退 GDI 性能下降明显。
  - `build.rs` 编译 libyuv/libvpx/libaom 三个 C 库，构建耗时长，交叉编译复杂。
  - 大量 unsafe FFI 调用，内存安全风险高。
  - 录制 MP4 需要 `hwcodec` feature，否则 H264/H265 录制失败。
  - Linux 摄像头因 `nokhwa` issue #171 仅取首个设备。

### libs/enigo/ — 输入模拟（in-tree fork）

- **职责**：跨平台键盘/鼠标输入模拟，支持 DSL（如 `{+SHIFT}Hello{-SHIFT}`）解析。
- **关键文件**：`Cargo.toml`、`src/lib.rs`、`src/dsl.rs`、`src/macos/{mod,macos_impl,keycodes}.rs`、`src/win/{mod,win_impl,keycodes}.rs`、`src/linux/{mod,nix_impl,xdo}.rs`、`build.rs`、`examples/keyboard.rs`。
- **对外接口**：`MouseControllable` / `KeyboardControllable` trait（`mouse_move_to/button/key_click/key_down/key_up/key_sequence`），`Key` 枚举，`dsl::tokenize` / `dsl::eval`。
- **交互**：被 `src/server/input_service.rs` 与 `src/keyboard.rs` 调用；Linux 通过 `libxdo-sys` + XTEST；Windows 通过 `winapi`/`SendInput`；macOS 通过 `core-graphics`/`CGEvent`。
- **数据流 / 状态机**：
  1. 控制端输入 → hbbs/hbbr 中继 → 被控端 `connection.rs` 解析 → enigo trait 方法 → 平台原生 API → OS 事件队列。
  2. DSL：字符串 → `tokenize` 分词 → `eval` → 调 `key_click/down/up/sequence`。
  3. 按键生命周期：`key_down` → 维持状态 → 中间可插 mouse 事件 → `key_up`。
  4. Linux 构建：`build.rs` 通过 `pkg-config` 查询 16 个 X11 库（xext/gl/xcursor/xxf86vm/xft/xinerama/xi/x11/xlib_xcb/xmu/xrandr/xtst/xrender/xscrnsaver/xt） → 生成 `config.rs` → 链接。
  5. 平台路由通过 `cfg(target_os)` 条件编译：Android/iOS 上 `Enigo` 为空 struct（no-op）。
- **风险与待改进**：未在分析中覆盖详细风险（注意：分析数据在此模块处被截断；进一步细节请参见源码实际 TODO/FIXME）。

---

## 配置、端口与运行时

### 默认端口

| 端口 | 协议 | 用途 |
|---|---|---|
| 21116 | UDP/TCP | `RENDEZVOUS_PORT` — ID 注册、心跳、TCP 打洞 |
| 21117 | TCP | `RELAY_PORT` — NAT 失败回退中继 |
| 21114 | TCP (HTTP) | hbbs HTTP API（= `RENDEZVOUS_PORT - 2`） |
| 21118 / 21119 | TCP (WS/WSS) | WebSocket 支持 |
| 21119 | UDP | LAN 发现（= `RENDEZVOUS_PORT + 3`） |

> 自定义服务器可通过 UI 选项 `custom-rendezvous-server` 或 CLI `--option` 配置。

### 配置文件与配置层级

- `LocalConfig`：本地 UI 选项。
- `PeerConfig`：每个 peer 的设置（画质、剪贴板、隐私模式等）。
- `Config` / `Config2`：全局配置（含设备 ID、key_pair、salt、密码等）。
- 实际配置键名常量定义在 `libs/hbb_common/src/config.rs`（hbb_common 是 git submodule，本地未签出，commit `a920d00`）。
- 配置持久化为 JSON，敏感字段（密码）使用 `sodiumoxide secretbox` 加密。

### 环境变量

| 变量 | 作用 |
|---|---|
| `RUSTDESK_APPNAME` | 便携模式应用名 |
| `VCPKG_ROOT` | vcpkg 依赖根路径（构建必需） |
| `PULSE_LATENCY_MSEC=60` | PulseAudio 延迟（systemd 中预设） |
| `PIPEWIRE_LATENCY=1024/48000` | PipeWire 延迟（systemd 中预设） |

### 运行时其它

- **TLS**：`reqwest` 同时使用 `native-tls` 与 `rustls-tls`，`TlsType` 枚举区分 `custom`/`direct`/`system`。
- **2FA**：通过 `totp-rs` 实现 TOTP（`auth_2fa.rs`）。
- **IPC**：Linux/macOS Unix 域套接字、Windows 命名管道，做 UID/PID 鉴权。
- **隐私模式**：Windows 用 Magnification API exclusion；macOS 用 `CGPreLoginApp`；Linux 走 compositor bypass。
- **虚拟显示**：仅 Windows（`virtual_display_manager.rs` + `libs/virtual_display`，RustDesk IDD 驱动）。
- **加密**：NaCl/libsodium：`box_`（Curve25519 公钥）、`secretbox`（XSalsa20-Poly1305 对称）、`sign`（Ed25519）。
- **数据目录**：未在分析中明确覆盖，由 `directories_next` 在各平台决定（典型为 `%APPDATA%/RustDesk`、`~/Library/Preferences/com.carriez.RustDesk`、`~/.config/rustdesk`）。

---

## 构建、部署与运维

### 本地构建

```bash
# 主推构建脚本（跨平台）
python3 build.py --release

# Flutter + Sciter 混合构建
python3 build.py --flutter

# 纯 Rust 构建（触发 build.rs 编译 C/C++ 原生库）
cargo build --release

# 移动端
flutter/build_android.sh
flutter/build_ios.sh
flutter/ndk_*.sh
```

### 容器化构建

```bash
# Linux 构建环境
docker build -t rustdesk .

# entrypoint.sh: source cargo env -> 设置 VCPKG_ROOT -> cargo build
```

### Linux 分发包

- `flatpak/`：Flatpak manifest（沙盒分发）
- `appimage/AppImageBuilder-*.yml`：AppImage
- `res/DEBIAN/control`：Debian 包（含 systemd 集成）
- `res/rpm*.spec`：RPM
- `res/PKGBUILD`：Arch Linux

### systemd 服务

`res/rustdesk.service`：

```ini
ExecStart=/usr/bin/rustdesk --service
User=root
```

环境注入 `PULSE_LATENCY_MSEC=60`、`PIPEWIRE_LATENCY=1024/48000`。

### CI / CD

`.github/workflows/`：

- `flutter-build.yml`、`flutter-ci.yml`、`flutter-nightly.yml`、`flutter-tag.yml`
- F-Droid 构建、桥接器代码生成、cliprdr 测试

### 注意事项

- 构建前必须初始化 `hbb_common` 子模块，否则 `RENDEZVOUS_PORT=21116`/`RELAY_PORT=21117` 等关键常量缺失，编译会失败。
- `cargo build` 通过 `build.rs` 编译大量 C/C++ 代码（libyuv、libvpx、libaom 等），首次构建耗时较长，交叉编译复杂。
- Release profile：`LTO + 单 codegen unit + strip + panic=abort`，二进制体积小但崩溃路径会跳过 Drop（影响如 `WallPaperRemover` 恢复）。
- Windows 服务运行在 Session 0，需 `WTSQueryUserToken + CreateProcessAsUser` 跨会话拉起 UI。
- Linux 在非主流发行版上可能因 `sudoers` 配置导致 GTK sudo 对话框失败。

---

## 外部依赖与协议

### 协议

| 协议 | 端点 | 描述 |
|---|---|---|
| Rendezvous（UDP/TCP） | hbbs @ 21116 | protobuf 消息：`RegisterPeer`、`RegisterPk`、`PunchHole`、`PunchHoleRequest`、`RequestRelay`、`OnlineRequest` 等（共 26 个类型，定义于 `rendezvous.proto`） |
| Relay（TCP） | hbbr @ 21117 | P2P 失败时的数据转发 |
| HTTP API | hbbs @ 21114 | `/api/login`、`/api/logout`、`/api/currentUser`、`/api/ab`、`/api/ab/peers`、`/api/audit` 等，Bearer token 鉴权 |
| 对端会话（TCP/WebSocket） | 客户端 ↔ 服务端 | protobuf 消息：`LoginRequest/Response`、`VideoFrame`、`AudioFrame`、`Clipboard`、`KeyEvent`、`MouseEvent`、`CursorData`、`PeerInfo`、`TerminalData`、`FileTransfer*`、`VoiceCallRequest/Response`、`TestDelay`、`SwitchDisplay`、`Resolution`、`Misc`（共 93 个类型，定义于 `message.proto`） |
| 加密层 | 所有 P2P/Relay 通道 | `FramedStream` 套用 sodiumoxide `secretbox`（XSalsa20-Poly1305），密钥由 Curve25519 `box_` 交换得出 |
| 地址混淆 | Rendezvous 消息中 | `AddrMangle::encode/decode`，时间戳 XOR IPv4 地址+端口，规避路由器/防火墙扫描干扰 |

### 数据库

- **客户端无服务端式数据库依赖**。
- Flutter 端使用 `sqflite`（SQLite）缓存地址簿、用户数据。
- hbb_common 的 `Config` 系列以 JSON 持久化。

### 第三方库（节选）

- **必需服务端**：RustDesk rendezvous/relay 服务器 hbbs/hbbr。
- **vcpkg C/C++ 库**：libvpx、libyuv、opus、aom、ffmpeg（hwcodec）、libsodium（Win arm64）。
- **UI 引擎**：Sciter（`libsciter-gtk.so`，遗留），Flutter engine + Dart SDK。
- **移动**：Android NDK、vcpkg android 依赖（oboe、OpenSLES、ndk_compat）。
- **系统库**：GTK3、X11/Wayland、PulseAudio/PipeWire（Linux）；WtsApi32（Windows）；ApplicationServices/CoreGraphics/IOKit（macOS）。
- **TLS 证书**：native-tls（平台证书库）+ rustls（捆绑 webpki 根证书）。
- **CI**：GitHub Actions（多平台矩阵）。
- **可选**：Flatpak runtime（`org.freedesktop.Platform`）、AppImage builder。

---

## 安全与可改进点

### 安全亮点

1. **端到端加密**：所有 P2P/Relay 通道用 NaCl box_/secretbox（Curve25519 + XSalsa20-Poly1305），即便经过中继也无法被服务端窃听。
2. **IPC 身份认证**：主进程与服务/CM 进程之间的 Unix socket / 命名管道使用 UID/PID 验证。
3. **2FA**：基于 TOTP（`totp-rs`），与永久密码 / 临时密码 / 密钥对鉴权并存。
4. **登录失败退避**：`login_failure_check` 阻止暴力破解。
5. **路径遍历防护**：`fs::TransferJob` 内置目录递归与路径检查。
6. **地址混淆**：`AddrMangle` 防止运营商/防火墙基于明文 IP/端口的扫描干扰。

### 已识别风险与改进项

1. **依赖维护风险**：`sodiumoxide` 已停止维护；建议迁移至活跃的 `dryoc`/`crypto_box`。
2. **fingerprint 自研加密**：自实现 AES-128 与 SHA-512，存在实现正确性与侧信道风险，应切到 `RustCrypto/aes` + `sha2`。
3. **IPC 缺版本协商**：主进程与 CM 版本不匹配可能导致沟通失败或安全问题；应加入握手版本字段。
4. **Windows portable_service 共享内存**：硬编码地址偏移、无访问控制；建议用命名管道 + protobuf 或带 ACL 的 file mapping。
5. **lazy_static 全局可变状态**：多处 `Arc<Mutex<>>`/`RwLock` 存在死锁与状态泄漏隐患，测试困难；建议向依赖注入或 actor 模型重构。
6. **`connection.rs` / `client.rs` / `common.rs` / Dart `model.dart` 单体过大**：拆分按职责模块化。
7. **`panic=abort` + RAII 恢复冲突**：`WallPaperRemover`、`WakeLock` 等 Drop 不会被触发，需在崩溃路径前显式恢复。
8. **TLS fallback 递归**：`websocket::try_connect` 与 `proxy.rs` 使用 `#[async_recursion]` 递归不同 TLS 类型，最大重试次数应被显式限制。
9. **Shell 命令拼接**：Windows 服务安装中部分命令未做 `shell_quote`，含空格/特殊字符路径可能注入。
10. **Linux block_input/隐私模式不全**：在非 Windows 平台多为 stub，影响远控期间用户输入隔离与屏幕隐私。
11. **VideoQoS 启发式阈值**：未使用 GCC/BBR 等标准拥塞控制；弱网下表现欠佳。
12. **Sciter UI 残留**：建议彻底剥离，缩小攻击面与维护负担。
13. **TIScript 内存密码缓存**：临时密码以明文驻留在脚本对象中。
14. **深度链接安全**：`rustdesk://password`/`rustdesk://config` 即使 opt-in 仍可能被钓鱼利用，应加额外用户确认。
15. **Linux 进程环境读取**：`/proc/<pid>/environ` 存在 TOCTOU 竞态。
16. **macOS 屏幕录制权限检测**：多版本 API 分支兼容性脆弱，建议封装并随系统升级测试矩阵。

---

## 阅读源码的建议路径

按推荐顺序阅读，可快速建立对 RustDesk 客户端的整体认知：

1. **`src/main.rs` 与 `src/core_main.rs`** — 理解二进制入口、CLI 参数派发与启动模式选择（server / cm / client / main UI）。
2. **`src/lib.rs`** — 浏览模块树，对全局模块布局建立索引。
3. **`libs/hbb_common/protos/message.proto` 与 `protos/rendezvous.proto`** — 协议先行。理解 93 个会话消息 + 26 个 Rendezvous 消息，是后续所有网络代码的语义基础。
4. **`src/rendezvous_mediator.rs`** — 看 hbbs 注册 / 打洞 / 中继协商如何驱动整个连接建立流程。
5. **`src/client.rs` 与 `src/client/io_loop.rs`** — 控制端会话生命周期、消息分发循环、视频/音频/输入处理。
6. **`src/server/connection.rs` 与 `src/server/service.rs`** — 受控端连接管理 + Service / Subscriber 发布订阅框架，是理解 server 整体最关键的两个文件。
7. **`src/server/video_service.rs` + `libs/scrap/src/common/codec.rs`** — 屏幕采集与视频编解码协商。
8. **`src/ipc.rs` 与 `src/flutter_ffi.rs`** — IPC 协议与 Rust↔Dart 桥的实际形态。
9. **`flutter/lib/main.dart` + `flutter/lib/models/model.dart`** — UI 入口与最核心的状态模型，理解 UI 如何与 Rust 交互。
10. **`src/platform/{windows,linux,macos}.rs`** — 平台差异胶水层。读懂其中一个平台再横向对照，可看清服务安装、用户会话、权限提升与显示/光标管理的全貌。

---

## 分析元信息

- **项目根路径**：`/Volumes/MBA_1T/Code/远程控制`（仓库子项目 RustDesk 客户端）
- **分析所覆盖的模块数量**：8 个核心模块
  1. `src/`（客户端核心）
  2. `src/server/`（受控端服务）
  3. `src/platform/`（跨平台抽象）
  4. `src/ui/`（Sciter 遗留 UI）
  5. `flutter/`（Flutter 现代 UI）
  6. `libs/hbb_common/`（协议与基础库，git submodule）
  7. `libs/scrap/`（屏幕采集与视频编解码）
  8. `libs/enigo/`（输入模拟，in-tree fork）
- **版本**：RustDesk 1.4.8
- **报告生成日期**：2026-06-27
