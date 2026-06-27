# RustDesk Server (hbbs + hbbr) 源码分析报告

> 分析对象：自托管的 RustDesk 远程桌面服务端（Rust 实现）。
> 项目根路径：`/Volumes/MBA_1T/Code/远程控制/rustdesk-server`
> 版本：v1.1.15

---

## 项目简介与定位

RustDesk Server 是 RustDesk 远程桌面生态的**自托管开源服务端**，使用 Rust（edition 2021）编写，开源版本采用 AGPL-3.0 协议。整套服务由两个独立但协同工作的二进制组成：

- **hbbs**（ID / Rendezvous Server）：客户端 ID 注册、设备发现、NAT 类型探测、UDP 打洞协调、跨服务器中继分配；同时维护 Peer 公钥与在线状态。
- **hbbr**（Relay Server）：当 P2P 直连失败时，作为中继代理，对两端客户端的数据流进行双向透明转发，并具备带宽限制和黑白名单能力。

此外提供 **rustdesk-utils** CLI 工具（生成/校验 Ed25519 密钥对、`doctor` 网络连通性诊断），以及一个基于 Tauri 的 **Windows 桌面 GUI**（系统托盘管理面板，非默认构建产物）。

服务端通过 **protobuf** 协议（`hbb_common::rendezvous_proto`）与 RustDesk 客户端通信，传输层覆盖 **TCP / UDP / WebSocket**；持久化使用 **SQLite**；身份信任使用 **Ed25519** 密钥对。部署方式覆盖裸机、systemd、Debian/Ubuntu 包、Docker（busybox + s6-overlay 单容器或 scratch 多容器）、Kubernetes 以及 FreeBSD rc.d。

定位上，它是一种**轻量级、单实例为主、面向中小规模自托管**的信令/中继服务，并非为大规模分布式集群设计（SQLite 单连接默认配置、内存 PeerMap、无 leader 选举等限制都印证了这一点）。

---

## 技术栈

| 类别 | 选型 |
|---|---|
| 编程语言 | Rust（edition 2021） |
| 异步运行时 | tokio（multi_thread flavor） |
| HTTP / Web | axum 0.5（内部 API，预期在 21114 端口） |
| 数据库 | sqlx 0.6 + SQLite（`db_v2.sqlite3`），deadpool 连接池 |
| 序列化 / 协议 | protobuf（`rendezvous_proto`） |
| 加密 / 签名 | sodiumoxide（Ed25519 密钥对与签名） |
| WebSocket | tokio-tungstenite |
| CLI 解析 | clap 2 |
| 带宽控制 | async-speed-limit |
| 共享基础库 | `hbb_common`（git submodule，提供 protobuf / 网络抽象 / 配置常量） |
| 桌面 GUI | Tauri 1.2 + CodeMirror（仅 Windows 完整实现） |
| Docker 进程管理 | s6-overlay（仅 `docker/` S6 镜像） |
| Linux 二进制 | musl 静态链接（x86_64 / aarch64 / armv7 / i686） |
| Windows 安装器 | NSIS + nssm（服务包装器） |
| HTTP 客户端 | reqwest（版本检查） |
| CI/CD | GitHub Actions + Docker Buildx + QEMU |

Release profile 启用 `panic=abort` 与 LTO 以最小化二进制体积。

---

## 顶层目录结构

| 目录 | 作用 |
|---|---|
| `src/` | 全部 Rust 源码：`main.rs`(hbbs)、`hbbr.rs`(relay)、`utils.rs`(CLI)、`rendezvous_server.rs`、`relay_server.rs`、`peer.rs`、`database.rs`、`common.rs` 等 |
| `libs/hbb_common/` | 共享基础库（git submodule，指向 `https://github.com/rustdesk/hbb_common`），提供 protobuf 定义、网络抽象、配置常量 |
| `docker/` | Docker S6-overlay 变体：单容器多服务镜像，含 `key-secret` / `hbbr` / `hbbs` 三个 s6-rc 服务单元 |
| `docker-classic/` | Docker classic 变体：基于 `FROM scratch` 的极简镜像（6 行 Dockerfile） |
| `systemd/` | systemd unit 文件：`rustdesk-hbbs.service`、`rustdesk-hbbr.service` |
| `rcd/` | FreeBSD rc.d 服务脚本：`rustdesk-hbbs`、`rustdesk-hbbr` |
| `debian/` | Debian 打包元数据：`control.tpl`、`rules`、`postinst`/`prerm`/`postrm` 等 |
| `kubernetes/` | K8s 参考部署：单个 `example.yaml`（Deployment + Service + PVC） |
| `ui/` | Tauri 桌面 GUI（Windows 系统托盘管理面板），非默认 cargo build 产物 |
| `.github/` | GitHub Actions CI 流水线（`build.yaml`）、Dependabot、Issue 模板 |

---

## 入口与启动流程

项目通过 `Cargo.toml` 的 `[[bin]]` 配置在同一 crate 中产出三个二进制：

| 二进制 | 入口文件 | 作用 |
|---|---|---|
| `hbbs` | `src/main.rs` | ID / Rendezvous 服务器 |
| `hbbr` | `src/hbbr.rs` | Relay 中继服务器 |
| `rustdesk-utils` | `src/utils.rs` | 运维 CLI（genkeypair / validatekeypair / doctor） |

并存在两个库 root：

- `src/lib.rs`：hbbs 侧库根，re-export `rendezvous_server` / `common` / `database` / `peer` 等。
- `src/mod.rs`：hbbr 侧库根，re-export `relay_server` / `rendezvous_server` / `sled_async`。

**hbbs 启动流程（典型）**：

1. `main.rs` 调用 `common::init_args`，解析 `.env`（INI 格式，由 `ini` crate 加载）与 CLI 参数（clap 2）。
2. `common::gen_sk(...)` 生成或读取 `id_ed25519` / `id_ed25519.pub`（首次启动会自动生成，强烈建议备份）。
3. `RendezvousServer::start(port, serial, key, rmem)` 初始化 PeerMap、SQLite 连接池（`database::Database`）、relay 健康检查器。
4. 绑定监听：UDP+TCP 主端口 `port`（默认 21116）、NAT 测试 TCP 端口 `port-1`、WebSocket `port+2`。
5. 后台任务：`check_relay_servers`（每 3s 探测 relay TCP 可达）、`check_software_update`（每 24h POST 版本检查）、Unix 信号监听（`listen_signal`）。
6. `io_loop` 通过 `tokio::select!` 聚合 UDP / TCP / WS / 内部 channel 的事件，路由到 `handle_udp` / `handle_tcp` / `handle_listener2`。

**hbbr 启动流程**：

1. `hbbr.rs` 解析 CLI（`-p`、`-k`）与环境变量（`PORT`、`KEY`、`DOWNGRADE_THRESHOLD`、`LIMIT_SPEED`、`TOTAL_BANDWIDTH`、`SINGLE_BANDWIDTH`、`DOWNGRADE_START_CHECK`）。
2. 加载 `blacklist.txt`、`blocklist.txt` 到全局 HashMap。
3. `relay_server::start(port, key)` 绑定两个 TCP 监听器：`port`（默认 21117）与 `port+2`（WebSocket，21119）。
4. `io_loop` 通过 `select!` 接受连接 → `make_pair_` 按 RequestRelay 的 `uuid` 配对 → `relay()` 进入双向 `tokio::select!` 拷贝循环（带 30s 无数据超时、每秒带宽统计、可触发降级 / 黑名单限速）。

---

## 核心模块详解

### hbbs / RendezvousServer（`src/rendezvous_server.rs`）

**职责**：作为 RustDesk 生态的 ID 注册与信令中心。

- 维护内存中的 `PeerMap`（`HashMap<String, LockPeer>`），并持久化 `pk`/`uuid` 到 SQLite。
- 接收并响应 `RegisterPeer` / `RegisterPk` / `PunchHoleRequest` / `PunchHoleSent` / `LocalAddr` / `RequestRelay` / `RelayResponse` / `TestNatRequest` / `OnlineRequest` / `ConfigureUpdate` / `SoftwareUpdate` 等 protobuf 消息。
- 跨网/同 LAN 判定：根据 `--mask` (CIDR) 与 `--local-ip` 计算 `same_intranet`，决定下发 `FetchLocalAddr`（同网内本地直连）还是 `PunchHole`（跨网 UDP 打洞）。当 `ALWAYS_USE_RELAY` 启用或双方 LAN 状态异或不一致时，会将 `nat_type` 强制改写为 `SYMMETRIC` 以触发客户端走 relay。
- Relay 分配：`check_relay_servers` 定时探测 relay TCP 可达性，`ROTATION_RELAY_SERVER` round-robin 分发可用列表（`_pa`/`_pb` 参数预留就近选择但**未实现**）。
- IP 安全：`IP_BLOCKER`（每 IP 每分钟 ≤30 次注册，每天 ≤300 个不同 ID），`IP_CHANGES` 记录 ID-IP 变更频率（窗口 `IP_CHANGE_DUR=180s`，命中阈值后封禁 `IP_BLOCK_DUR=60s`），`PUNCH_REQS` 60s 内同 `from_ip→to_id` 去重（仅检查最近 30 条）。
- Ed25519 签名：对 `id+pk` 签名以防中间人篡改。
- 配置/版本：loopback 发 `ConfigureUpdate` 可热更新 `serial` 与 `rendezvous-servers`；后台线程每 24h 拉取版本，对 `SoftwareUpdate` 请求返回下载 URL。
- 管理 CLI（仅 loopback 接入 `port-1`）：`relay-servers`、`reload-geo`、`ip-blocker`、`ip-changes`、`punch-requests`、`always-use-relay`、`test-geo`。

**关键文件**：`src/rendezvous_server.rs`、`src/peer.rs`、`src/database.rs`、`src/common.rs`、`src/main.rs`。

**对外接口（协议层面）**：
- UDP/TCP `21116` — 主信令通道。
- TCP `21115`（port-1）— NAT 类型测试 + loopback 管理命令。
- TCP `21118`（port+2）— WebSocket 信令，支持 `X-Real-IP`/`X-Forwarded-For`。

**与其他模块/外部系统交互**：
- ↔ RustDesk 客户端：基于 `RendezvousMessage` protobuf。
- ↔ SQLite：`database.rs` 通过 sqlx 操作 `peer` 表（`guid` / `id` / `uuid` / `pk` / `user` / `status` / `note` / `info`）。
- ↔ hbbr：仅通过 `check_relay_servers` 做 TCP 可达探测，不存在共享状态。
- ↔ GitHub Releases API：`reqwest` POST 检查更新。
- ↔ 其他 hbbs：通过 `--rendezvous-servers` 列表实现跨服 peer 查询（简单广播式，无一致性协议）。

**数据流 / 状态机**：

1. **注册**：客户端 `RegisterPeer` → `update_addr` 更新 `socket_addr` 与 `last_reg_time` → 返回 `RegisterPeerResponse(request_pk=...)` → 若 `request_pk=true`，客户端发 `RegisterPk` → `check_ip_blocker` → `PeerMap::update_pk`（内存 + DB）→ 返回 `RegisterPkResponse(OK / UUID_MISMATCH / TOO_FREQUENT)`。
2. **打洞**：A 发 `PunchHoleRequest` → 鉴权 + 查 PeerMap → 根据 `same_intranet` 转发 `FetchLocalAddr` 或 `PunchHole` 给 B → B 回 `PunchHoleSent`/`LocalAddr` → hbbs 通过保存的 TCP sink 转发给 A。
3. **Relay 申请**：A 发 `RequestRelay` → 查 PeerMap → 通过 UDP channel 发 `RequestRelay` 给 B → B 选定 relay 后回 `RelayResponse` → `send_to_tcp_sync` 把响应写回 A 的 TCP sink。
4. **持久化**：`PeerMap::get` 先查内存 → miss 时回查 SQLite → 命中后回填，`last_reg_time` 判定过期（3600s 阈值仅在读取时检查，**无后台 GC**）。

**风险与待改进点**：
- `mod.rs` 声明了不存在的 `sled_async` 模块；`lib.rs` 引用 `version` 模块但 `src/version.rs` 缺失（推测由 `build.rs` 生成到 `OUT_DIR`）。若 build 脚本异常，编译会失败。
- 进程重启会丢失全部 `socket_addr`（仅 `pk`/`uuid` 入库），所有客户端需重新注册。
- UDP 信令无 ACK/重传；`test_hbbs` 自检在 socket 异常时会 `exit(1)`。
- `tcp_punch` HashMap 以 `try_into_v4(addr)` 为 key — 同 IP 不同端口的连接会**互相覆盖 sink**，存在并发隐患。
- `tcp_punch` 中保存的 sink 若后续无消息触发 `send_to_tcp`，将永远驻留（**无超时淘汰**）。
- `mpsc::unbounded_channel` 无背压，高频消息可能造成内存膨胀。
- WebSocket 通道**不支持 `RegisterPeer`/`RegisterPk`**（这两条仅在 `handle_udp`/`handle_tcp` 处理，WS 路径会返回 `NOT_SUPPORT`），WS 客户端无法独立完成注册。
- 默认 `MAX_DATABASE_CONNECTIONS=1`，高并发注册场景成为瓶颈。
- `ip-blocker` / `ip-changes` 仅在内存中，重启即失。
- loopback 管理 CLI 仅以 `is_loopback()` 校验，**无任何认证**。
- `get_relay_server` 仅做 round-robin，地理就近选择仍是 TODO。
- `id_ed25519` 私钥以明文落盘，权限未强制校验。
- WebSocket 反向代理 `X-Real-IP` 头解析未做合法性验证，恶意代理可伪造 IP。

### hbbr / RelayServer（`src/relay_server.rs`）

**职责**：当 P2P 失败时，作为中继代理双向转发原始字节流。

- 监听 TCP `21117` 和 WebSocket `21119`，按 `RequestRelay(uuid, licence_key)` 配对两端连接。
- `relay()` 在 `tokio::select!` 中双向 forward；每 3 秒 tick 检查 30s 无数据则超时；每秒统计带宽至 `USAGE`。
- 限速分层：`TOTAL_BANDWIDTH`（默认 1 Gbps）、`SINGLE_BANDWIDTH`（默认 128 Mbps）、`LIMIT_SPEED`（黑名单 IP 默认 32 Mbps）。
- 降级：`DOWNGRADE_THRESHOLD`（默认 66%，达单连接阈值触发降速），`DOWNGRADE_START_CHECK` 控制起始检查时间。
- 黑/阻止名单：`blacklist.txt`（限速）与 `blocklist.txt`（拒绝连接）启动时加载到内存。
- loopback 管理 CLI（主端口本地连接）：`blacklist` / `blocklist` / `downgrade-threshold` / `downgrade-start-check` / `limit-speed` / `total-bandwidth` / `single-bandwidth` / `usage`。

**关键文件**：`src/relay_server.rs`、`src/hbbr.rs`。约 647 行。

**对外接口**：
- TCP `21117` — 主中继 + loopback 管理 CLI。
- TCP `21119`（port+2）— WebSocket 中继，识别 `X-Real-IP` / `X-Forwarded-For`。

**与其他模块/外部系统交互**：
- ↔ 客户端：仅 `RendezvousMessage::RequestRelay` 一种消息；配对后即纯字节流转发。
- ↔ hbbs：被 `check_relay_servers` 探测可达性；hbbs 通过 `RelayResponse` / `PunchHole` / `FetchLocalAddr` 中的 `relay_server` 字段将 hbbr 地址下发给客户端。
- ↔ 文件系统：`blacklist.txt` / `blocklist.txt`（**只读加载，不写回**）。

**数据流 / 状态机**：

```text
Client A ── RequestRelay(uuid, key) ──▶ hbbr
                                         │
                              [PEERS HashMap 查询同 uuid]
                                         │
                          ┌──── 已存在 ─┴── 不存在 ────┐
                          ▼                            ▼
                     取出 Stream B                插入 (uuid, A_stream)
                          │                            │
                          ▼                            ▼
            relay(A,B) 双向 select 拷贝          sleep(30s) 后移除
            + 带宽统计 / 限速 / 降级
            + 30s 无数据则关闭
```

**风险与待改进点**：
- 配对仅靠 `uuid` 字符串，无身份验证；任何拿到 `uuid` 的第三方可抢先占位、劫持中继通道。`licence_key` 仅做明文字符串比对。
- 30s 配对窗口存在竞态：插入 PEERS 后 sleep，期间多个同 uuid 连接可能造成混乱。
- WebSocket 实现中 `tungstenite::Message::Binary(bytes) → bytes[..].into()` 与 `bytes.to_vec()` 存在多次内存拷贝（源码注释明确标记 `to-do: poor performance`）。
- WebSocket `set_raw()` 为空实现 — 一端 WS、一端 TCP 时协议不匹配的风险。
- `PEERS` / `USAGE` / `BLACKLIST` / `BLOCKLIST` 全在内存，重启即失；黑名单文件不会被运行时修改写回。
- **无法水平扩展**：多实例不共享 PEERS，配对双方必须落到同一进程。
- 无 TLS 层加密，依赖客户端上层加密；无最大连接数 / 并发会话上限，存在 DoS 风险。
- `DOWNGRADE` 仅基于总流量阈值，无法区分大文件传输 vs 异常流量。
- loopback 管理 CLI 仅 `is_loopback()` 检查，**任何本机用户可改运行参数**。
- 多处 TODO/FIXME 残留，错误处理不够完善。

### 共享存储与状态（`src/peer.rs` + `src/database.rs`）

**职责**：
- `peer.rs`：定义 `Peer` 结构（`socket_addr` / `last_reg_time` / `guid` / `uuid` / `pk` / `info` / `reg_pk`），全局静态 `IP_BLOCKER` / `IP_CHANGES` / `USER_STATUS` / `PeerMap`，提供 `get` / `get_or` / `get_in_memory` / `is_in_memory` / `update_pk` 等接口。
- `database.rs`：基于 sqlx 0.6 + deadpool 的 SQLite 抽象，封装 `insert_peer` / `update_pk` / `get_peer`，`peer` 表字段：`guid (UUID)` / `id` / `uuid` / `pk` / `user` / `status` / `note` / `info`。

**与其他模块/外部系统交互**：仅供 hbbs 内部模块使用；DB 文件默认在工作目录 `db_v2.sqlite3`，可通过 `DB_URL` 环境变量或 `-c` 重定向。

**数据流**：`PeerMap::get(id)` → 内存 miss → SQLite SELECT → 命中回填内存（`is_in_memory=true`），过期判定基于 `last_reg_time` 与 3600s 阈值，**仅读取路径触发，无后台清理**。

**风险与待改进点**：
- SQLite 单连接默认；注释中预留了 PostgreSQL/MySQL 切换但未实现。
- 内存 PeerMap 无主动 GC，长时间运行可能内存膨胀。
- `IP_BLOCKER` 仅按 IP 维度，未考虑 NAT 后多设备共享 IP（企业网络误封风险）。

### 共享基础（`src/common.rs` + `libs/hbb_common`）

**职责**：
- `common.rs`：CLI 参数（`init_args` / `get_arg` / `get_arg_or`）、服务器地址校验（`test_if_valid_server` / `get_servers`）、密钥生成与持久化（`gen_sk`）、Unix 信号监听（`listen_signal`）、版本检查（`check_software_update`）。
- `libs/hbb_common`：**git submodule**（指向 `https://github.com/rustdesk/hbb_common`，pin 在 commit `83419b6`，当前工作树**未初始化**）。它为 hbbs / hbbr / rustdesk-utils 提供：
  - protobuf 协议（`rendezvous_proto`、`message_proto`）。
  - 网络抽象（`tcp::FramedStream`、`udp::FramedSocket`、`bytes_codec::BytesCodec`、`listen_any`）。
  - 地址工具（`AddrMangle`、`try_into_v4`）。
  - 异步运行时重导出（tokio / tokio_util / futures / futures_util）。
  - 配置常量（`RELAY_PORT=21117`、`RENDEZVOUS_PORT=21116`、`Config`）。
  - 版本管理：`gen_version()` 在编译期生成版本号，`version_check_request` 支持升级检查。
  - 错误/日志宏：`ResultType`、`bail!`、`allow_err!`、`log`。

**关键文件**：`src/common.rs`、`libs/hbb_common/`（空目录，未 init）。

**对外接口**：均为 Rust crate API，无网络对外接口。

**与其他模块/外部系统交互**：被 hbbs / hbbr / rustdesk-utils 全量依赖；同时与 RustDesk **客户端共享同一 crate** — 服务端协议变更必须跨项目协调。

**风险与待改进点**：
- **构建阻塞**：未执行 `git submodule update --init` 时整个项目无法编译。
- protobuf 协议定义在子模块，服务端与客户端兼容性强耦合于 submodule 版本。
- `hbb_common` 重导出 tokio / futures 等核心依赖的特定版本，上层无法独立升级这些 crate。
- 数据中提到工作树存在 `Cargo.toml` 与 `Cargo.lock` 被替换为 SQLite 数据库文件的损坏迹象，需 `git checkout HEAD -- Cargo.toml`（请实际核验，未必发生在当前文件树）。

### rustdesk-utils（`src/utils.rs`）

**职责**：独立运维工具，三个子命令：
- `genkeypair`：生成 Ed25519 密钥对。
- `validatekeypair <pub> <priv>`：校验密钥对匹配。
- `doctor`：DNS 解析 + TCP 端口连通性探测（`21114–21119`）。

**与其他模块/外部系统交互**：独立二进制，仅依赖 `hbb_common`；被 docker `key-secret` 服务、人工运维脚本调用。

**风险**：`doctor` 中反向 DNS 在 macOS 已知问题（源码内 TODO 注释）；命令行错误使用 `bail!` 直接退出。

### 桌面 GUI（`ui/`）

**职责**：基于 Tauri v1 + CodeMirror 的 Windows 系统托盘管理面板，控制 hbbs/hbbr 服务（通过 `nssm` 包装的 Windows 服务）、查看实时日志、在线编辑 `.env`（Ctrl+S 自动保存并重启）。

**架构**：MVP 风格分层 — `view`（Tauri 窗口/托盘）/ `presenter`（业务循环）/ `service`（平台适配，仅 Windows 实现）/ `watcher`（`notify` 文件系统监控），通过两个 crossbeam bounded channel 通信。

**关键文件**：`ui/src/main.rs`、`ui/src/adapter/service/windows.rs`、`ui/src/usecase/presenter.rs`、`ui/html/main.js`、`ui/setup.nsi`、`ui/tauri.conf.json`。

**对外接口**：
- 通过 `cmd.exe` 调用 `service/nssm.exe` 注册/启停/移除 Windows 服务（`hbbs` / `hbbr`）。
- 通过 `windows-service` crate 查询服务状态。
- 通过 Tauri `fs` API 读写 `bin/.env` 和 `logs/*`。
- 前端 `event.emit('__action__', ...)` ↔ 后端 `app.emit_all('__update__', ...)` 的 Tauri 事件桥。

**数据流**：状态轮询 1Hz；停止时窗口标题以 500ms 间隔闪烁；watcher 检测到 `.env` 或日志文件变化时推送增量 UI 更新。

**风险**：
- 仅 Windows 完整实现，macOS/Linux 上 `service::create()` 返回 `None`，GUI 不可用。
- 路径硬编码：`service/nssm.exe`、`service/run.cmd`；运维依赖第三方 nssm。
- `call()` 使用 `expect("cmd exec error!")`，命令执行失败直接 panic。
- 无任何访问控制 — 桌面任意用户可启停服务。
- Cargo.toml `version=0.1.2` 与 `setup.nsi` `VERSION=1.1.15` 不同步。
- 前端写入失败仅 `console.error`，UI 无错误反馈。

---

## 配置、端口与运行时

### 默认端口

| 端口 | 协议 | 进程 | 用途 |
|---|---|---|---|
| `21114` | TCP | hbbs（预期） | 内部 / Web API（axum） |
| `21115` | TCP | hbbs | NAT 类型测试 + loopback 管理 CLI（`port-1`） |
| `21116` | TCP + UDP | hbbs | 主信令通道（注册/打洞/relay 请求） |
| `21117` | TCP | hbbr | 中继 + hbbr 的 loopback 管理 CLI |
| `21118` | TCP | hbbs | WebSocket 信令（`port+2`） |
| `21119` | TCP | hbbr | WebSocket 中继（`port+2`） |

### 配置文件

- `.env`（INI 格式，启动时加载）：典型条目 `DATABASE_URL=sqlite://./db_v2.sqlite3`。
- `id_ed25519` / `id_ed25519.pub`：首次启动自动生成的 Ed25519 密钥对（**强烈建议备份**）。
- `blacklist.txt` / `blocklist.txt`（hbbr 工作目录）：IP 限速 / 拒绝清单。

### CLI 参数

**hbbs**：

```
-c, --config <PATH>           配置目录
-p, --port <PORT>             主端口（默认 21116，env RENDEZVOUS_PORT）
-s, --serial <N>              配置序列号（用于 ConfigureUpdate 比对）
-R, --rendezvous-servers      其他 hbbs 列表（跨服查询）
-u, --software-url            版本检查 / 升级下载 URL
-r, --relay-servers           hbbr 地址列表
-M, --rmem <BYTES>            UDP 接收缓冲区大小
    --mask <CIDR>             局域网网段，配合 --local-ip 判定同 LAN
-k, --key <KEY>               认证密钥（明文共享密钥 / base64 Ed25519 私钥 / `_` 表示仅加密）
```

**hbbr**：

```
-p, --port <PORT>             主端口（默认 21117，env RELAY_PORT）
-k, --key <KEY>               认证密钥
```

### 环境变量

| 变量 | 进程 | 含义 |
|---|---|---|
| `PORT` | hbbr | 中继主端口（+1 偏移） |
| `KEY` | hbbr / hbbs | 认证密钥（等价 `-k`） |
| `DOWNGRADE_THRESHOLD` | hbbr | 单连接降级阈值（默认 66%） |
| `DOWNGRADE_START_CHECK` | hbbr | 降级检查起始时间 |
| `LIMIT_SPEED` | hbbr | 黑名单 IP 限速（默认 32 Mbps） |
| `TOTAL_BANDWIDTH` | hbbr | 全局总带宽（默认 1 Gbps） |
| `SINGLE_BANDWIDTH` | hbbr | 单连接带宽（默认 128 Mbps） |
| `DB_URL` | hbbs | SQLite 路径（默认 `sqlite://./db_v2.sqlite3`） |
| `MAX_DATABASE_CONNECTIONS` | hbbs | 连接池大小（默认 1） |
| `ALWAYS_USE_RELAY` | hbbs | `Y/N`，强制所有连接走 relay |
| `TEST_HBBS` | hbbs | 自检相关开关 |
| `RELAY` | Docker | hbbr 公网地址（默认占位 `relay.example.com`） |
| `ENCRYPTED_ONLY` | Docker | `1` 时给两个服务追加 `-k _`，仅加密模式 |
| `KEY_PUB` / `KEY_PRIV` | Docker | 通过环境变量注入密钥对（不推荐用于生产） |

### 数据目录

| 部署方式 | 工作目录 |
|---|---|
| systemd | `/var/lib/rustdesk-server/` |
| Docker (S6) | `/data`（VOLUME） |
| Docker (Classic) | `/root`（容器可写层，**容器删除即丢**） |
| Debian 包 | `/var/lib/rustdesk-server/`，日志 `/var/log/rustdesk-server/` |
| 裸机 | `./`（当前目录） |
| FreeBSD rc.d | `/var/db/rustdesk-server/` |

---

## 构建、部署与运维

### 本地构建

```bash
# 必须先初始化子模块
git submodule update --init

# Release 构建（生成 hbbs / hbbr / rustdesk-utils 到 target/release/）
cargo build --release
```

`Cargo.toml` 中 `hbb_common = { path = "libs/hbb_common" }`；`build.rs` 在编译期调用 `hbb_common::gen_version()` 注入版本信息。

### Docker

- **S6 变体**（`docker/`，推荐）：基于 busybox + s6-overlay v3.2.0.0，一容器跑 `hbbr` + `hbbs`，提供 `HEALTHCHECK`（`s6-svstat`）、Docker secrets 支持、`/data` 持久卷。
- **Classic 变体**（`docker-classic/`）：`FROM scratch`，6 行 Dockerfile，仅含静态二进制，体积极小但**无 shell、无 HEALTHCHECK、无 ENTRYPOINT/CMD**，调试困难。
- `docker-compose.yml`（项目根）：示例编排，镜像 `rustdesk/rustdesk-server:latest`。

S6 启动链：`/init` → `key-secret`（oneshot，密钥准备/校验）→ `hbbr`（longrun）→ `hbbs`（longrun，`sleep 2` 等 hbbr）。密钥注入优先级：`/data/` 持久卷文件 > Docker secrets > `KEY_PUB`/`KEY_PRIV` 环境变量 > hbbs 自动生成。

### systemd

`systemd/rustdesk-hbbs.service`、`systemd/rustdesk-hbbr.service`：
- `Restart=always`、`RestartSec=10`、`LimitNOFILE=1000000`。
- stdout → `/var/log/rustdesk-server/hbbs.log`，stderr → `.error`。
- ⚠ `User=` / `Group=` 为空 — **以 root 运行**；未启用任何 sandboxing（无 `ProtectSystem`/`ReadOnlyPaths`/`NoNewPrivileges`）；日志目录需外部预创建；hbbs/hbbr 间**无 `After=`/`Requires=` 启动依赖**。

### Debian 包

三个独立包：`rustdesk-server-hbbs` / `rustdesk-server-hbbr` / `rustdesk-server-utils`。
- `debian/control.tpl` 使用 `{{ ARCH }}` 占位符，构建前需 `sed` 替换。
- `debhelper compat=10`、`source/format=3.0 (native)`。
- `postinst` 创建 `/var/log/rustdesk-server` 与 `/var/lib/rustdesk-server`，启用并启动服务；`prerm` 停止并 disable；`postrm purge` 清理日志（注意 **hbbr 包不清理 `/var/lib/rustdesk-server/`，仅 hbbs 包清理**，可能造成数据泄漏）。
- `Depends: systemd` — 与 OpenRC / runit / sysvinit 不兼容。
- 包未声明 libc / 运行时依赖（依赖静态链接的隐式约定）。

### Kubernetes

`kubernetes/example.yaml`：单文件、单副本 `Deployment`（`strategy: Recreate`）+ `Service`（LoadBalancer/NodePort 注释切换）+ PVC（`/root` 持久化）。hbbs 与 hbbr 作为同一 Pod 的两个容器，共享 localhost。

**生产化缺口**：无 Helm Chart / Kustomize / Operator；无 liveness/readiness；无 resource requests/limits；无 PodDisruptionBudget / NetworkPolicy；无 TLS / Ingress；密钥不走 Secret 直接落在 PVC；硬编码 `-k _`、`RELAY_HOST=rustdesk.yourdomain.tld`。

### FreeBSD rc.d

`rcd/rustdesk-hbbs`、`rcd/rustdesk-hbbr`：以 `rustdesk:rustdesk` 用户/组身份通过 `/usr/sbin/daemon` 启动；`rc.conf` 中 `rustdesk_hbbs_enable=YES` 控制；二进制路径硬编码 `/usr/local/sbin/hbbs`、`/usr/local/sbin/hbbr`；默认 `-k _`（不安全）；无 newsyslog 配置。

### Windows 安装

`ui/setup.nsi`（NSIS）：
- 内嵌 `nssm.exe` 作为服务包装器。
- 自动下载安装 WebView2 运行时。
- 注册 Windows 防火墙规则。
- 安装快捷方式与桌面 GUI。

### CI（`.github/workflows/build.yaml`）

- 600+ 行多阶段流水线。触发：`workflow_dispatch` + tag `vX.Y.Z` / `X.Y.Z` 等。
- `build` 矩阵：Linux × {x86_64 / aarch64 / armv7 / i686}（musl 静态），`build-win` 单独 Windows MSVC。
- `release`：聚合各平台产物，`softprops/action-gh-release` 创建 Draft Release。
- Docker：`docker`（S6，多架构含 i386）+ `docker-classic`（无 i386）；`docker-manifest` / `docker-manifest-classic` 合并多架构 manifest，推送至 Docker Hub 与 GHCR。
- Debian：`deb-package` 下载二进制 → 构造 `debian/` → `debuild` → 上传 `.deb`。
- **注意事项**：
  - Windows 代码签名 step `if: false` — 产物为 `-unsigned`。
  - `docker-manifest-classic` 的 `needs: docker`（**疑似 bug**，应为 `docker-classic`）。
  - FreeBSD target 已注释。
  - Rust toolchain 硬编码 `1.90`，Node.js 16（已 EOL）。
  - 需配置 7 个 Secrets：`DOCKER_IMAGE` / `DOCKER_IMAGE_CLASSIC` / `DOCKER_HUB_USERNAME` / `DOCKER_HUB_PASSWORD` / `WINDOWS_PFX_BASE64` / `WINDOWS_PFX_PASSWORD` / `WINDOWS_PFX_SHA1_THUMBPRINT`。
  - **无 `cargo test` 步骤**，编译通过即视为通过。
  - Dependabot 仅监控 git submodule，**未覆盖 Cargo 生态**。

---

## 外部依赖与协议

### rendezvous / relay / api 协议关系

```
              ┌─────────────────────────────────────────────┐
              │              RustDesk Client                │
              └──────┬──────────────────┬──────────────────┘
                     │ protobuf          │ protobuf
                     │ over UDP/TCP/WS   │ over TCP/WS
                     ▼                   ▼
        ┌──────────────────┐    ┌──────────────────┐
        │   hbbs           │    │   hbbr           │
        │   (Rendezvous)   │    │   (Relay)        │
        │  21115/21116/    │    │  21117/21119     │
        │  21118           │    │                  │
        └────────┬─────────┘    └──────────────────┘
                 │ check_relay_servers(每 3s TCP 探活)
                 ▼
            relay 可用列表 → 在 RelayResponse / PunchHole
                            / FetchLocalAddr 中下发给客户端
```

- **rendezvous_proto::RendezvousMessage**（来自 `hbb_common`）是 hbbs 与客户端、hbbr 与客户端通信的唯一外层消息封装；具体 oneof 分支包括 `RegisterPeer` / `RegisterPk` / `RegisterPkResponse` / `PunchHoleRequest` / `PunchHole` / `PunchHoleSent` / `PunchHoleResponse` / `LocalAddr` / `FetchLocalAddr` / `RequestRelay` / `RelayResponse` / `TestNatRequest` / `TestNatResponse` / `OnlineRequest` / `OnlineResponse` / `ConfigureUpdate` / `ConfigUpdate` / `SoftwareUpdate`。
- **message_proto::IdPk** 用于 Ed25519 签名验证。
- **hbbs 与 hbbr 之间**没有专门协议；hbbs 只是用 `FramedStream` 做 TCP 端口可达性测试。
- **跨 hbbs**：通过 `--rendezvous-servers` 列表实现简单的跨服查询，**无一致性 / 选举 / 状态同步机制**。

### 数据库

- **SQLite**（sqlx 0.6 + deadpool），唯一表 `peer`：`guid`（UUID 主键）、`id`、`uuid`（客户端 UUID）、`pk`（Ed25519 公钥）、`info`（JSON）、`user`、`status`、`note`、`created_at`。
- 代码注释中提到 PostgreSQL / MySQL 切换可能但未实装。

### 关键第三方库

| 库 | 用途 |
|---|---|
| `tokio` | 异步运行时（multi_thread） |
| `axum` 0.5 | 内部 HTTP API |
| `sqlx` 0.6 + `deadpool` | SQLite 访问 |
| `protobuf` | 消息编解码 |
| `sodiumoxide` | Ed25519 密钥/签名 |
| `tokio-tungstenite` | WebSocket |
| `async-speed-limit` | 中继限速 |
| `clap` 2 | CLI 解析 |
| `reqwest` | 版本检查 HTTP 客户端 |
| `notify` | 桌面 GUI 文件系统监控 |
| `bcrypt` + `jsonwebtoken` | 仅在 OSS 依赖中出现，主要用于 Pro 版本用户认证 |
| `Tauri` 1.2 | 桌面 GUI |
| `s6-overlay` | Docker 进程监督 |

---

## 安全与可改进点

按风险等级整理：

### 高优先级

1. **关键管理接口零认证**：hbbs 的 `port-1` loopback 管理 CLI 与 hbbr 的主端口 loopback CLI 仅以 `is_loopback()` 判断信任源，本机任何用户即可改写 `relay-servers` / `always-use-relay` / `single-bandwidth` / `blacklist` 等关键参数。建议加 Unix domain socket + 文件权限 / token。
2. **hbbr 配对无身份验证**：任何拿到 `uuid` 的攻击者都可抢先连接劫持中继通道；`licence_key` 只做明文比对。建议引入挑战-应答 / HMAC 签名 / 由 hbbs 颁发的短期 token。
3. **密钥明文落盘且权限未强制**：`id_ed25519` 私钥以普通文件保存；Docker 环境变量注入 `KEY_PRIV` 可经 `docker inspect` 或 `/proc/$pid/environ` 泄露。建议强制 `chmod 0400`、推荐 Docker secrets / K8s Secret。
4. **systemd 单元以 root 运行**：`User=`/`Group=` 为空，未启用 `ProtectSystem`/`NoNewPrivileges`/`ReadOnlyPaths` 等加固。建议建立专用 `rustdesk` 用户，并启用 systemd sandbox。
5. **WebSocket `X-Real-IP` 头未校验**：恶意反代可伪造客户端 IP，绕过 `IP_BLOCKER` / 黑名单。建议配置可信代理 CIDR 白名单。
6. **`tcp_punch` HashMap 以 IP（去除端口）为 key**：同 IP 多端口连接会互相覆盖 sink，可能造成串号 / 信令丢失。建议改用 `(ip, port, peer_id)` 复合键并补 TTL。

### 中优先级

7. SQLite 默认 `MAX_DATABASE_CONNECTIONS=1`，高并发注册瓶颈；写入序列化。建议提供 PostgreSQL 实装。
8. `PeerMap` 内存条目无后台过期清理，长期运行内存可能膨胀。
9. `IP_BLOCKER` / `IP_CHANGES` / `PUNCH_REQS` / `PEERS` / `USAGE` 全部内存态，重启丢失；黑名单文件不会被运行时变更写回。
10. UDP 信令无重传 / ACK；socket 异常重建期间服务短暂不可用。
11. WebSocket 路径不支持 `RegisterPeer`/`RegisterPk` — WS-only 客户端无法独立完成注册。
12. `mpsc::unbounded_channel` 无背压；hbbr 无最大并发会话上限 — DoS 风险。
13. Docker S6 镜像下，密钥校验失败时直接 `/run/s6/basedir/bin/halt` 整个容器，日志输出有限，排查困难。
14. Docker `RELAY=relay.example.com` 占位若未覆盖，容器虽启动但功能不可用；hbbs 用 `sleep 2` 等 hbbr 起来 — 慢机器存在竞态。

### 低优先级（代码质量 / 工程）

15. `mod.rs` 引用了**不存在的** `sled_async` 模块；`lib.rs` 引用 `version` 模块（应由 `build.rs` 生成）。
16. CI 未跑 `cargo test`；无单元/集成测试。
17. Windows 安装器代码签名 step 被禁用，产物为 `-unsigned`。
18. `docker-manifest-classic` 的 `needs: docker` 疑似笔误。
19. Cargo / npm 生态不在 Dependabot 监控中。
20. K8s 示例严重缺生产化要素（probe / resources / Secret / Ingress）。
21. `rcd/` 与 `systemd/` 两套服务定义并存，参数（如 `-k _`）默认不安全且分散，易出现配置漂移。
22. UI 仅 Windows 完整实现；Cargo / NSIS 版本号不同步。
23. `version_check` 与软件更新提示由后台同步 `thread::spawn` + tokio current_thread 混合驱动，潜在运行时混用问题。

---

## 阅读源码的建议路径

按以下顺序阅读，能在最短时间内构建起对项目的整体心智模型：

1. **`src/main.rs`** — 5 分钟。理解 hbbs 进程启动顺序：参数 → 密钥 → `RendezvousServer::start`。
2. **`src/common.rs`** — 10 分钟。掌握共享基础：`.env` 加载、CLI 解析、`gen_sk`、`get_servers`、信号处理、版本检查。
3. **`src/peer.rs`** — 15 分钟。掌握 `Peer` 数据结构与 `PeerMap` 双层（内存 + DB）模型，以及全局 `IP_BLOCKER` / `IP_CHANGES` / `USER_STATUS`。
4. **`src/database.rs`** — 10 分钟。理解 SQLite schema 与 `insert_peer` / `update_pk` / `get_peer` 三个核心接口。
5. **`src/rendezvous_server.rs`** — 60 分钟以上。最核心模块。重点：`io_loop` 的 `tokio::select!`、`handle_udp` / `handle_tcp` / `handle_listener2` 的消息分发、`handle_punch_hole_request` 的同 LAN / 跨网决策、`check_relay_servers` 与 `get_relay_server` 的 round-robin。
6. **`src/hbbr.rs`** — 5 分钟。理解 hbbr 进程入口与环境变量。
7. **`src/relay_server.rs`** — 30 分钟。重点：`make_pair_` 的 UUID 配对逻辑、`relay()` 的双向 select 拷贝、限速 / 降级 / 黑名单的实际生效路径、`check_cmd` 的管理命令。
8. **`src/utils.rs`** — 5 分钟。理解 `genkeypair` / `validatekeypair` / `doctor` 实现，便于自检远程服务器。
9. **`libs/hbb_common`**（需先 `git submodule update --init`） — 30 分钟。重点查看 `.proto` 文件、`AddrMangle`、`FramedStream`/`FramedSocket`、`Config` 常量。
10. **`docker/` 与 `systemd/`** — 10 分钟。对照运行时部署形态：S6 启动链、密钥注入优先级、systemd 重启策略，便于把代码与生产现场关联起来。

---

## 分析元信息

- **项目根路径**：`/Volumes/MBA_1T/Code/远程控制/rustdesk-server`
- **分析所覆盖的模块数量**：12 个（`src`、`src/rendezvous_server.rs`、`src/relay_server.rs`、`libs/hbb_common`、`libs`、`docker`、`docker-classic`、`systemd`、`debian`、`kubernetes`、`ui`、`rcd`、`.github`）
- **报告生成时间**：2026-06-27
- **分析对象版本**：RustDesk Server v1.1.15
- **数据来源**：项目静态结构调研 + 12 个模块的源码 / 配置文件扫描结果 + 关键路径源码核验（部分 `data_flow` 描述已根据核验结果修正，特别是 hbbs 在打洞决策中关于 `same_intranet`、`ALWAYS_USE_RELAY` 与 `nat_type` 强制 `SYMMETRIC` 的关系，已在 hbbs 模块详解中按实际代码语义重写）
