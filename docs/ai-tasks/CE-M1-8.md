# CE-M1-8 WS Register 补齐 (RegisterPeer / RegisterPk)

## 1. 任务目标

让 WebSocket(ws_port = port+2)接入的 RustDesk 客户端能够独立完成 `RegisterPeer` 心跳与 `RegisterPk`(首次注册或 IP 变化时刷新公钥/UUID)流程,且复用与 UDP/TCP 完全相同的 IP blocker、UUID 校验、`PeerMap::update_pk` 与 IP 变更追踪逻辑——不能复制一份并行实现。

验收信号:
- 仅通过 ws (`tokio_tungstenite`) 连接发送 `RegisterPk` 二进制帧的客户端,在 `hbbs` 内存与 `db_v2.sqlite3` 中可见,后续 TCP/UDP 走 `handle_punch_hole_request` 时可拿到该 peer 的 pk。
- 原有 TCP `RegisterPk` 返回 `NOT_SUPPORT` 的回退路径被替换为真实处理(对照任务卡 "WS-only 客户端能独立注册;旧 TCP/UDP 注册流程不变")。
- IP blocker / uuid mismatch / too frequent 三类失败仍按原 UDP 路径的语义返回 `RegisterPkResponse`。

## 2. 上下文与依赖

上游依赖任务卡:
- CE-M1-1 ~ CE-M1-7(`hbbs` 通用 WS 兼容、ws_port 监听、Sink::Ws 已经存在,见 `rustdesk-server/src/rendezvous_server.rs:52-56`、`rustdesk-server/src/rendezvous_server.rs:288-298`、`rustdesk-server/src/rendezvous_server.rs:1160-1186`)。

下游会用到此输出的任务卡:
- CE-M1-9 轻量 Client Builder(自定义 client 需要 WS-only 模式可用)。
- 后续 M2 阶段所有依赖 PeerMap 中存在 ws-only peer 的能力(在线状态查询、punch hole、relay)。

关键背景事实(file:line):
- WS 端口监听在 `rustdesk-server/src/rendezvous_server.rs:105` 创建,在 `:152` 绑定,在 `:288-298` accept 后调用 `handle_listener(..., ws=true)`。
- `handle_listener_inner` 在 ws=true 时进入 `tokio_tungstenite` 握手,仅处理 `tungstenite::Message::Binary`,并把字节交给 `handle_tcp`(`rustdesk-server/src/rendezvous_server.rs:1180-1186`)。
- 当前 `handle_tcp` 处理 `RegisterPk` 直接返回 `NOT_SUPPORT`(`rustdesk-server/src/rendezvous_server.rs:556-564`),没有 `RegisterPeer` 分支。
- UDP 的 `RegisterPeer` 处理与 `update_addr` 的写回耦合在 `&mut FramedSocket`(`rustdesk-server/src/rendezvous_server.rs:326-340`、`:572-613`),需要拆出"计算逻辑"和"发送逻辑"。
- UDP 的 `RegisterPk` 完整流程(uuid 校验、IP blocker、reg_pk 限流、IP_CHANGES 更新、`pm.update_pk` 调用)在 `rustdesk-server/src/rendezvous_server.rs:342-426`。
- `send_to_sink` 已经能向 `Sink::TcpStream` 与 `Sink::Ws` 写 `RendezvousMessage`(`rustdesk-server/src/rendezvous_server.rs:829-843`),是 WS 回写的统一入口。
- `PeerMap::update_pk`(`rustdesk-server/src/peer.rs:92-133`)只依赖 `&mut self` 与传入 ip/uuid/pk,与传输无关,可被 TCP/WS 路径复用。
- 任务卡原文位于 `docs/ai-development-plan.md:357-369`。

## 3. 涉及文件清单

| 路径 | 动作 | 行数估计 | 说明 |
|---|---|---|---|
| `rustdesk-server/src/rendezvous_server.rs` | 修改 | +120 / -35 | 抽出 `process_register_peer` / `process_register_pk` 共享 helper;在 `handle_tcp` 增加 `RegisterPeer` 分支并替换 `RegisterPk` 的 `NOT_SUPPORT` 占位;`handle_udp` 改为调用 helper。 |
| `rustdesk-server/tests/ws_register.rs` | 新建 | ~180 | 新增集成测试:启动 `RendezvousServer`,以 tokio-tungstenite 客户端发送 `RegisterPk` / `RegisterPeer` 二进制帧并断言响应、`PeerMap`/DB 状态。未找到现有 tests 目录,需新建。 |
| `docs/ai-development-plan.md` | 修改 | +1 | 在 CE-M1-8 任务卡末尾追加状态行(DoD 最后一项)。 |

注:`rustdesk-server/tests/` 目录目前不存在,需新建。如果项目已选用 `criterion`/`#[tokio::test]` 之外的测试约定,可将位置改为 `rustdesk-server/src/rendezvous_server.rs` 内 `#[cfg(test)] mod tests`,但优先选 integration test 以便启动真实监听。

## 4. 数据契约

无新增 protobuf 字段。沿用 `hbb_common::rendezvous_proto` 已有消息:

- 请求(client → hbbs,WS Binary frame,内容为 `RendezvousMessage` 序列化字节):
  - `RegisterPeer { id: string, serial: i32 }`
  - `RegisterPk { id: string, uuid: bytes, pk: bytes }`
- 响应(hbbs → client,WS Binary frame):
  - `RegisterPeerResponse { request_pk: bool }`(可选 `ConfigUpdate`,与 UDP 一致)
  - `RegisterPkResponse { result: register_pk_response::Result }`,取值集合保持与 UDP 完全一致:`OK / UUID_MISMATCH / TOO_FREQUENT / SERVER_ERROR`。WS 路径不再返回 `NOT_SUPPORT`。

新增内部 helper 签名(建议命名,可调整):

```rust
// 返回应当回写给客户端的 RendezvousMessage;调用方决定通过 FramedSocket 还是 Sink 发送。
async fn process_register_peer(
    &mut self,
    rp: RegisterPeer,
    addr: SocketAddr,
) -> Option<RendezvousMessage>;

// 同上;封装 IP blocker / uuid check / reg_pk 限流 / IP_CHANGES / pm.update_pk。
async fn process_register_pk(
    &mut self,
    rk: RegisterPk,
    addr: SocketAddr,
) -> RendezvousMessage; // 必返回一个 RegisterPkResponse
```

无新增 SQL DDL / 配置项 / GORM 结构体。

## 5. 实现步骤

1. **拆 `update_addr`**:把 `rendezvous_server.rs:572-613` 中的"计算 request_pk / ip_change"部分抽到一个新私有方法 `compute_register_peer_response(&mut self, id: String, socket_addr: SocketAddr) -> RegisterPeerResponse`。保留原 `update_addr` 作为 UDP 包装:内部调 `compute_*` 然后用 `socket.send(&msg_out, socket_addr)` 写回。这样 helper 不再持有 `&mut FramedSocket`。
2. **新增 `process_register_peer`**:在 `rendezvous_server.rs` 的 `impl RendezvousServer` 内,基于 `compute_register_peer_response` 实现。逻辑对应 `:326-340`——若 `rp.id.is_empty()` 返回 `None`;否则构造 `RegisterPeerResponse`,并在 `self.inner.serial > rp.serial` 时改为返回 `ConfigUpdate`(对应 `:331-339`)。注意:UDP 路径会同时发送 `RegisterPeerResponse` *和* `ConfigUpdate` 两条消息,而 WS 单连接每帧只能携带一个 `RendezvousMessage`——helper 改为返回 `Vec<RendezvousMessage>`(或 `(primary, Option<extra>)`),由调用方决定发几次。
3. **新增 `process_register_pk`**:整体平移 `rendezvous_server.rs:342-426` 的逻辑,把所有 `send_rk_res(socket, addr, X).await` 改为 `return Self::make_rk_res(X)`(其中 `make_rk_res` 构造一个 `RendezvousMessage`)。保留 `id.len() < 6` → `UUID_MISMATCH`、`!check_ip_blocker` → `TOO_FREQUENT`、uuid mismatch → `UUID_MISMATCH`、`req_pk.0 > 2` → `TOO_FREQUENT`、`pm.update_pk` 调用与 `IP_CHANGES` 写入。pm.update_pk 内部可能返回 `SERVER_ERROR`,需要透传(目前 UDP 路径丢弃了这个返回值,本任务保持现状以避免行为变化)。
4. **修改 `handle_udp`**:把 `:326-340` 与 `:342-426` 两个分支替换成对 helper 的调用 + `socket.send(&msg_out, addr).await`。保留对 `RegisterPk` 路径的 `?` 错误传播,确保旧 UDP 行为不变。
5. **修改 `handle_tcp`**:
   - 删除 `:556-564` 的 `NOT_SUPPORT` 占位。
   - 新增 `Some(rendezvous_message::Union::RegisterPeer(rp)) => { ... }`:调 `process_register_peer`,对每条结果 `Self::send_to_sink(sink, msg).await`。
   - 新增 `Some(rendezvous_message::Union::RegisterPk(rk)) => { ... }`:调 `process_register_pk`,`send_to_sink`。
   - 两条新分支均 `return true` 以维持长连接读取循环(参考 `:498-499` 模式)。
6. **IP 来源**:`handle_listener_inner` 已在 ws 握手 callback 中根据 `X-Real-IP` / `X-Forwarded-For` 改写 `addr`(`:1162-1175`),所以 `process_register_pk` 内 `addr.ip().to_string()` 直接拿到的就是反代后真实 IP,无需新增逻辑;在测试中需要验证这一点。
7. **日志**:在 `handle_tcp` 的 RegisterPeer/RegisterPk 分支前各加 `log::trace!("WS register_peer ...")`,字段对齐 UDP 的 `log::trace!`(`:329`)。
8. **集成测试**:在 `rustdesk-server/tests/ws_register.rs` 中:
   - `tokio::spawn` 启动 `RendezvousServer::start` 绑定动态端口(可借助 `TEST_HBBS=no` 跳过 hbbs 自检,或直接 `std::env::set_var("TEST_HBBS","no")`)。
   - 用 `tokio_tungstenite::connect_async("ws://127.0.0.1:<ws_port>")` 建立连接,发 `RegisterPk` 二进制帧。
   - 断言收到的 `RegisterPkResponse.result == OK`。
   - 第二次连接发同 id、不同 uuid,断言返回 `UUID_MISMATCH`。
   - 高频(>2 次/6 秒)发 `RegisterPk` 断言返回 `TOO_FREQUENT`。
9. **运行 `cargo fmt` / `cargo clippy --all-targets -- -D warnings`**,修正 lint。

## 6. 测试用例

| # | 测试文件 | 测试名 | 输入 | 期望 |
|---|---|---|---|---|
| 1 | `rustdesk-server/tests/ws_register.rs` | `ws_register_pk_happy_path` | 新 id `"123456"`,首次发 `RegisterPk{uuid=u1,pk=pk1}` | 返回 `RegisterPkResponse{result=OK}`;`PeerMap::get("123456")` 命中且 `pk==pk1`;`db_v2.sqlite3` 内 peer 已 insert(可通过 `pm.db.get_peer` 间接验证)。 |
| 2 | `rustdesk-server/tests/ws_register.rs` | `ws_register_pk_uuid_mismatch` | 先 `RegisterPk{uuid=u1}` 成功,再以同 id 发 `RegisterPk{uuid=u2,pk=pk1}`(同 ip 同 pk) | 第二次返回 `UUID_MISMATCH`,DB 中 uuid 仍是 u1。 |
| 3 | `rustdesk-server/tests/ws_register.rs` | `ws_register_pk_rate_limited` | 同一 peer 在 6 秒内发 4 次 `RegisterPk` | 第 4 次返回 `TOO_FREQUENT`(对应 `:392-393` 的 `req_pk.0 > 2`)。 |
| 4 | `rustdesk-server/tests/ws_register.rs` | `ws_register_peer_returns_request_pk_when_new` | id 未注册时发 `RegisterPeer{id="abcdef",serial=0}` | 返回 `RegisterPeerResponse{request_pk: true}`;`PeerMap::get_in_memory` 在 update_pk 完成前仍可能为空(若 RegisterPeer 不触发 db lookup),需对照 `update_addr` 的 `pm.get_in_memory` 调用语义。 |
| 5 | `rustdesk-server/tests/ws_register.rs` | `ws_register_peer_serial_triggers_config_update` | 服务端 `inner.serial=2`,客户端发 `RegisterPeer{serial=1}` | 客户端连续收到两个 `RendezvousMessage`,其中一个是 `ConfigUpdate{serial=2}`(对应 `:331-338`)。 |
| 6 | `rustdesk-server/tests/ws_register.rs` | `tcp_register_pk_still_works_backward_compat` | 通过普通 TCP(端口 = port,非 ws_port)走 framed 协议发 `RegisterPk` | 返回 `RegisterPkResponse{result=OK}`(确认抽 helper 后 TCP 也获得了真实处理,而非旧的 `NOT_SUPPORT`)。注:本用例同时是兼容性测试——若产品需要保留 "TCP 不允许 RegisterPk" 行为,则改为期望 `NOT_SUPPORT` 并仅在 ws=true 分支启用真实处理,需在评审时确认。**建议命名,可调整**:默认实现为 TCP 也走真实处理,以使 helper 真正共享。 |
| 7 | `rustdesk-server/tests/ws_register.rs` | `ws_register_ip_blocker_too_frequent` | 模拟同一 ip 在 60 秒内被 >30 次 RegisterPk 触发 IP_BLOCKER | 返回 `TOO_FREQUENT`(对应 `check_ip_blocker` `:891-919` 的 `counter.0 > 30`)。 |

注:用例 6 的兼容语义需要在 PR 描述中明确决议。

## 7. 验证命令

按顺序在 `/Volumes/MBA_1T/Code/远程控制/rustdesk-server` 下执行:

```sh
cd /Volumes/MBA_1T/Code/远程控制/rustdesk-server
cargo fmt --all -- --check
cargo clippy --all-targets -- -D warnings
cargo test --test ws_register -- --nocapture
cargo build --release   # 可在 macOS dev 上跳过,理由:macOS 上 release 全量编译耗时长且与 Linux 部署目标 ABI 不同,CI 会覆盖
# 端到端 smoke(可选,需要本地 1.4 客户端):
TEST_HBBS=no RUST_LOG=trace cargo run --bin hbbs -- -k _
```

可在 macOS dev box 跳过:
- `cargo build --release`——原因如上,由 CI 跨平台构建覆盖。
- 端到端 smoke——需要真实 RustDesk 客户端二进制。

## 8. 兼容性 / 安全注意事项

- **Protobuf 兼容**:不新增字段,仅消费现有 `RegisterPeer` / `RegisterPk` / `RegisterPkResponse`。老客户端、老服务端语义不受影响。
- **老 TCP 客户端**:替换 `NOT_SUPPORT` 为真实处理后,理论上 1.x TCP-only 客户端如果曾经依赖 `NOT_SUPPORT` 错误降级行为(实际中 RustDesk 自 1.1 起 RegisterPk 走 UDP,TCP 路径仅作为兜底),需在 PR 描述与 docs 中显式声明改动。如果不想动 TCP,可在 `handle_tcp` 的 RegisterPk 分支用 `if ws { real } else { NOT_SUPPORT }` 控制,但仍共享 helper。
- **IP blocker / reg_pk 限流**:helper 必须沿用 `check_ip_blocker` 与 `peer.reg_pk` 节流,WS 连接不绕过。WS 反代后 ip 取自 `addr`(已在握手 callback 改写),需在测试中 mock `X-Real-IP` header 以验证。
- **数据库迁移**:无 schema 变更。
- **敏感字段**:`pk` / `uuid` 已经走 `PeerMap::update_pk` 落 sqlite,本任务不引入新落盘字段;`log::warn!("Peer {} ip/pk mismatch: ...")` 已经会打印 pk 摘要,保持原行为即可,不扩大日志面。
- **WS 帧大小**:`tungstenite` 默认 64 MiB,`RegisterPk` 帧远小于此,无需调整。
- **回压**:helper 不持锁跨越 await(确认 `peer.write().await.reg_pk = req_pk;` 后 lock 立即 drop,与原 UDP 一致)。

## 9. 回滚方案

- 单 commit revert 即可(本任务全部修改集中在一个 Rust 文件 + 一个新增测试文件),无 schema 迁移、无配置开关。
- 若需要"代码留在仓但运行时停用 WS 注册",可通过环境变量 `WS_REGISTER_DISABLE=Y` 实现(**建议命名,可调整**):在 `handle_tcp` 的两个新分支起始处 `if ws && std::env::var("WS_REGISTER_DISABLE").as_deref() == Ok("Y") { return true; }`。是否引入该开关在 PR review 时决定;若引入,需在 `docs/upgrade-plan.md` 同步记一行。
- 数据回滚:若已写入异常 peer 记录,直接 `delete from peer where guid=...` 即可,DB 结构未改。

## 10. 完成定义 (DoD)

- [ ] `rendezvous_server.rs` 内拆出 `process_register_peer` / `process_register_pk`(或同名 helper),UDP 与 WS/TCP 两条路径都通过它写回响应。
- [ ] `handle_tcp` 不再返回 `NOT_SUPPORT`,新增 `RegisterPeer` 分支。
- [ ] `IP blocker` / uuid 校验 / `reg_pk` 限流 / `pm.update_pk` / `IP_CHANGES` 五点逻辑在 helper 内被调用且被测试覆盖。
- [ ] `rustdesk-server/tests/ws_register.rs` 新增并全部通过(至少覆盖 §6 中 1/2/3/4/5/7,用例 6 视评审决议)。
- [ ] `cargo fmt` / `cargo clippy --all-targets -- -D warnings` 干净。
- [ ] `cargo test -p rustdesk-server` 全绿。
- [ ] PR 描述列出对老 TCP RegisterPk 语义的处理决议(保留 NOT_SUPPORT 还是统一真实处理)。
- [ ] 在 `docs/ai-development-plan.md` 的 CE-M1-8 任务卡(`docs/ai-development-plan.md:357-369`)末尾追加 "状态: 完成 (commit <hash>)"。
