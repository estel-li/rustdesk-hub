# CE-M0-6 PeerMap GC + tcp_punch key 加固

## 1. 任务目标

为 hbbs 自托管栈消除两类隐性内存泄漏与跨连接污染:

1. `RendezvousServer.tcp_punch` 当前以 `SocketAddr`(IP+port)作为 key 缓存 sink,在 NAT 后多设备共享端口或快速重连场景下会被覆盖/错配。改为强类型 key `TcpPunchKey { ip, port, peer_id }`,并为每条 sink 记录插入时间,后台 GC 60 秒一次清理超时条目。
2. `PeerMap.map` 仅在被显式访问时才被填充,但从不缩减;运行越久内存越大。新增 60s 间隔的后台 GC,把 `last_reg_time` 超过阈值(默认 `REG_TIMEOUT * 4`,即 120s)的内存条目剔除,但保留 DB 行。

验收信号:
- `cd rustdesk-server && cargo test peer && cargo test rendezvous` 全绿,新加的 `tcp_punch_key_*`、`peer_map_gc_*` 单元测试一起跑过。
- 在本地起 hbbs,人工触发 100 次连接/断开后,通过 `metrics`(由 CE-M0-3 暴露,可选)或调试日志确认 `tcp_punch` 条目数趋稳而非线性增长。
- 同 IP 不同端口同时打洞两个不同 peer_id 不会互踩。

## 2. 上下文与依赖

- 上游依赖任务卡:
  - CE-M0-1 hbb_common fork 对齐(本任务的 type 改动会出现在 `rustdesk-server` 自身,不需要修改 hbb_common,但要求 hbb_common 已经能正常编译)。
  - CE-M0-3 metrics 端口(可选;若已落地,本任务可顺手暴露 `tcp_punch_size` / `peer_map_size` 两个 gauge)。
- 下游会用到此输出的任务卡:
  - CE-M0-7 管理 CLI 改 UDS + token —— 该卡也会在 `rendezvous_server.rs` 同名文件中插入新代码,本卡需保证只动 `tcp_punch` / `PeerMap` 相关代码,避免与 CLI socket 起冲突。
  - CE-M1 阶段的 PostgreSQL 后端切换(CE-M0-2)依赖 `PeerMap` 内存条目是有限的,GC 在 PG 模式下尤其重要。
- 关键背景事实:
  - `tcp_punch` 当前类型为 `Arc<Mutex<HashMap<SocketAddr, Sink>>>`,在 `rustdesk-server/src/rendezvous_server.rs:84` 定义,初始化于 `:131`。
  - 五处读写:`:496` 与 `:504` 插入,`:823`(`send_to_tcp`)、`:851`(`send_to_tcp_sync`)、`:1197`(连接关闭兜底)删除。所有读写都通过 `try_into_v4(addr)` 将 v6 映射 v4 后作为 key。
  - 当前 key 是 `SocketAddr`,**与 peer_id 无关**;`handle_tcp_punch_hole_request(addr, ph, ...)` 在 `:857` 拿到 `ph.id` 但没用于 key。
  - `PunchHoleRequest` 与 `RequestRelay` 都在 `:493`、`:501` 进入,key 都按 addr 写入,二者复用同一表。
  - `PeerMap.map` 为 `Arc<RwLock<HashMap<String, LockPeer>>>`,见 `rustdesk-server/src/peer.rs:64`。`get`(`:136-155`)与 `get_or`(`:158-169`)会插入但从不删除;`Peer.last_reg_time` 在 `update_pk`(`:108`)与 `update_addr`(`:578` 附近)被刷新。
  - `REG_TIMEOUT` 常量为 30_000 ms,见 `rustdesk-server/src/rendezvous_server.rs:50`。已有 1s `interval` 用法示例见 `:240` 与 `:1321`,可直接参考定时器骨架。
  - 现有 `io_loop` 已经 `select!` 多路复用,新增定时器走同一 `select!` 是最低风险路径。

## 3. 涉及文件清单

| 路径 | 动作 | 行数估计 | 说明 |
|---|---|---|---|
| `rustdesk-server/src/rendezvous_server.rs` | 修改 | +180 / -30 | 引入 `TcpPunchKey`、`TcpPunchEntry`,改 5 处插入/删除,新增 `gc_loop` 定时器分支 |
| `rustdesk-server/src/peer.rs` | 修改 | +60 / -0 | 新增 `PeerMap::gc()` 与可配置阈值常量,新增单元测试 |
| `rustdesk-server/src/lib.rs` | 修改 | +1 / -0 | 若需要 `pub(crate) mod tcp_punch_key` 单独拆模块,在此声明;否则不动 |
| `rustdesk-server/src/tcp_punch_key.rs` | 新建 | +80 | `TcpPunchKey` 结构体、`From<(SocketAddr, &str)>`、`Hash/Eq`、`Display` 实现及测试 |
| `rustdesk-server/Cargo.toml` | 修改 | +0 / -0 | 预期无新增依赖;若需要 `parking_lot` 之类标记 "建议命名,可调整" |
| `docs/ai-development-plan.md` | 修改 | +1 | 任务卡末尾追加状态行 |

未找到需新建的关键文件:无。`tcp_punch_key.rs` 是新增、其余均已存在。

## 4. 数据契约

### 4.1 Rust 结构体

新建 `rustdesk-server/src/tcp_punch_key.rs`:

```rust
use std::net::{IpAddr, SocketAddr};
use hbb_common::try_into_v4;

/// 用于 tcp_punch HashMap 的强类型 key。
/// 仅 ip+port 不足以唯一标识一条挂起的 punch hole 请求,
/// 加上 peer_id 防止 NAT 后多设备共享出口端口时互踩。
#[derive(Debug, Clone, Hash, Eq, PartialEq)]
pub(crate) struct TcpPunchKey {
    pub ip: IpAddr,
    pub port: u16,
    pub peer_id: String, // 即 PunchHoleRequest.id / RequestRelay.id
}

impl TcpPunchKey {
    pub fn new(addr: SocketAddr, peer_id: impl Into<String>) -> Self {
        let addr = try_into_v4(addr);
        Self { ip: addr.ip(), port: addr.port(), peer_id: peer_id.into() }
    }
}
```

### 4.2 sink 表条目

`rendezvous_server.rs` 内的 `tcp_punch` 类型由

```rust
Arc<Mutex<HashMap<SocketAddr, Sink>>>
```

改为

```rust
Arc<Mutex<HashMap<TcpPunchKey, TcpPunchEntry>>>

struct TcpPunchEntry {
    sink: Sink,
    inserted_at: std::time::Instant,
}
```

`TcpPunchEntry` 不需要 `Clone`,因为 `Sink` 包含 `SplitSink` 非 `Clone`。

### 4.3 常量(建议命名,可调整)

```rust
/// tcp_punch sink 在表中允许存活的最大时长。
const TCP_PUNCH_TTL_SECS: u64 = 30; // 与 REG_TIMEOUT(30s)对齐
/// 后台 GC 间隔。
const GC_INTERVAL_SECS: u64 = 60;
/// PeerMap 内存层条目最大不活跃时长(超过则从内存剔除,但保留 DB)。
const PEER_MAP_IDLE_TTL_SECS: u64 = 120;
```

### 4.4 环境变量(可选,留兜底)

| env | 默认 | 含义 |
|---|---|---|
| `TCP_PUNCH_TTL_SECS` | 30 | 同上,允许运维覆盖 |
| `PEER_MAP_IDLE_TTL_SECS` | 120 | 同上 |

建议命名,可调整。读取位置:`PeerMap::new()` 与 `RendezvousServer::start()`。

### 4.5 metrics(可选,如 CE-M0-3 已合并)

- gauge `hbbs_tcp_punch_size`
- gauge `hbbs_peer_map_size`
- counter `hbbs_tcp_punch_gc_evicted_total`
- counter `hbbs_peer_map_gc_evicted_total`

## 5. 实现步骤

1. **新建 `rustdesk-server/src/tcp_punch_key.rs`**:实现 §4.1 中的 `TcpPunchKey`,在文件末尾加 3 条单测覆盖 v4/v6 mapped/不同 peer_id。在 `rustdesk-server/src/lib.rs`(或 `main.rs` / `hbbr.rs` 引入处)加 `mod tcp_punch_key;` 与 `use tcp_punch_key::TcpPunchKey;`。
2. **修改 `rendezvous_server.rs` 头部**:在 `:51-56` 附近的 `Sink` 枚举下方追加 `struct TcpPunchEntry { sink: Sink, inserted_at: Instant }` 并将 `:84` 的字段类型改为 `Arc<Mutex<HashMap<TcpPunchKey, TcpPunchEntry>>>`,`:131` 的初始化同步改写。
3. **改 `handle_tcp` 中的两处插入**(`:496` 与 `:504`):
   - PunchHoleRequest 分支:用 `TcpPunchKey::new(addr, &ph.id)` 构造 key;
   - RequestRelay 分支:用 `TcpPunchKey::new(addr, &rf.id)` 构造 key;
   - 插入 `TcpPunchEntry { sink, inserted_at: Instant::now() }`。
4. **改 `send_to_tcp` 与 `send_to_tcp_sync`**(`:822-854`):它们当前只拿到 `addr`,没有 peer_id。新增一个等价接口 `send_to_tcp_by_key(&mut self, msg, key: TcpPunchKey)`,旧接口保留为 fallback —— 内部按 `(ip, port)` 前缀扫描表,移除并发送匹配的第一条(因为通常一个 addr 同一时刻只挂着一个请求)。说明:`addr` -> key 的反向查找会让 lookup 由 O(1) 变 O(n),但 n 是当前未完成的 punch 总数,小;且这条路径只在 RelayResponse 等少数地方走。
5. **改 `RelayResponse` 分支**(`:515-533`)与 `handle_tcp_punch_hole_request`(`:857-871`)调用 send 的地方,优先把 peer_id 传下去:
   - `handle_tcp_punch_hole_request` 已经持有 `ph`,直接调用新接口;
   - `RelayResponse` 持有 `rr.id`,同样可走新接口。
6. **改连接关闭兜底**(`:1196-1198`):由于此时不知道 peer_id,按 `(ip, port)` 扫描表删除所有匹配条目即可,保持现有语义。
7. **新增 GC 后台任务**:在 `io_loop`(`:231`)的 `select!`(`:242`)中追加一个 `interval(Duration::from_secs(GC_INTERVAL_SECS))` 分支,做两件事:
   - `tcp_punch` GC:遍历 `tcp_punch`,删除 `inserted_at.elapsed() > TCP_PUNCH_TTL_SECS` 的条目;日志 `log::debug!("tcp_punch GC evicted {n} entries")`。
   - `PeerMap` GC:调用 `self.pm.gc(PEER_MAP_IDLE_TTL_SECS).await`。
8. **在 `peer.rs` 新增 `PeerMap::gc`**:获取 `map.write()` 锁,收集 `last_reg_time.elapsed() > ttl` 的 key,逐个 `remove`,返回被剔除条数;DB 行不动。注意 `last_reg_time` 默认值为 `get_expired_time()`(`:48`),所以新插入而未注册的 placeholder 也会被回收 —— 这就是想要的。
9. **单元测试**:见 §6。
10. **CHANGELOG / 注释**:在改动点上方加 `// CE-M0-6:` 前缀注释,方便 grep 与回滚。

每一步预计 < 0.5 day;整体 1.5 天可完成。

## 6. 测试用例

| # | 测试文件 | 测试名 | 输入 | 期望 |
|---|---|---|---|---|
| 1 | `rustdesk-server/src/tcp_punch_key.rs` | `test_v6_mapped_collapses_to_v4` | v6-mapped v4 SocketAddr + peer_id "abc" | key.ip 为 v4,等于直接传 v4 时构造的 key |
| 2 | 同上 | `test_different_peer_id_distinct` | 同 addr,peer_id 分别 "a"/"b" | 两 key 不 Eq、Hash 不同 |
| 3 | 同上 | `test_eq_hash_roundtrip` | 插入 HashMap 后用克隆 key 查询 | 命中 |
| 4 | `rustdesk-server/src/peer.rs`(底部 `#[cfg(test)] mod tests`) | `test_peer_map_gc_evicts_stale` | 构造 PeerMap,插入两条 Peer,一条手动把 `last_reg_time` 改为 `Instant::now() - 600s`,调用 `gc(120)` | 返回 1,内存 map 只剩 1 条;DB 不受影响 |
| 5 | 同上 | `test_peer_map_gc_keeps_recent` | 仅插入活跃条目,`gc(120)` | 返回 0,条目仍在 |
| 6 | 同上 | `test_peer_map_gc_backward_compat_default_last_reg_time` | 默认构造的 Peer(`last_reg_time = get_expired_time()`)走 `gc(120)` | 被视为过期并剔除(向后兼容验证:不会因为没初始化而被永久驻留) |
| 7 | `rustdesk-server/src/rendezvous_server.rs`(新增 `#[cfg(test)] mod gc_tests`) | `test_tcp_punch_ttl_evicts` | 手动构造 `HashMap<TcpPunchKey, TcpPunchEntry>`,塞两条 entry,一条 `inserted_at = Instant::now() - 60s`,跑 GC 逻辑函数 | 旧条目被删,新条目保留 |
| 8 | 同上 | `test_tcp_punch_key_two_devices_same_nat` | 同 IP + 同 port + 不同 peer_id,各插一次 | 两条共存,互不覆盖(失败模式 1:旧实现会覆盖) |
| 9 | 同上 | `test_send_to_tcp_fallback_no_peer_id` | 按 addr 走 fallback 删除 | 能找到并移除第一条匹配 `(ip, port)` 的 entry(失败模式 2:返回 None 时不 panic) |

注:测试 7-9 需把 GC 与 fallback lookup 抽成纯函数(输入 `&mut HashMap`,不依赖 `RendezvousServer` 整体),才能脱离网络 IO 单测。建议把它们放进 `tcp_punch_key.rs` 的 `mod helpers` 子模块。

## 7. 验证命令

```bash
# 1. 编译 + 单测(必须)
cd /Volumes/MBA_1T/Code/远程控制/rustdesk-server
cargo build --bins
cargo test peer
cargo test rendezvous
cargo test tcp_punch_key

# 2. clippy(必须;CI 通常会跑)
cargo clippy --all-targets -- -D warnings

# 3. 本地烟测(可选,macOS dev box 可跳过 —— 仅依赖 sqlite 与端口可用)
RUST_LOG=debug ./target/debug/hbbs --key _ &
HBBS_PID=$!
sleep 2
# 反复触发 100 次 TCP 连接到 hbbs 端口 21116,看 tcp_punch 内存不增长
# (建议用一段小 Rust/Python 客户端;此处不强求)
kill $HBBS_PID

# 4. 在 Linux 上做长跑(可在 macOS 跳过):
#    Linux 容器中跑 6 小时,观察 RSS 与 hbbs_tcp_punch_size gauge(如已接入 CE-M0-3)。
#    macOS 跳过原因:hbbs 主部署目标是 Linux,长跑回归走 CI 容器更可靠。
```

## 8. 兼容性 / 安全注意事项

- **protobuf 兼容**:本卡完全不改 `.proto`,对老客户端零影响。
- **老客户端互通**:`tcp_punch` 是 hbbs 内部状态,key 变化不外泄;PunchHoleRequest/RequestRelay/RelayResponse 的网络字节流完全一致。
- **NAT 后多设备共享 IP**:这是本卡的核心修复点。务必保证 §6 测试 8 通过。
- **fallback 路径性能**:`send_to_tcp` 的反向查找在 `tcp_punch` 表超过 10k 条时可能成为热点。短期可接受;真正大流量时应在 CE-M1 重构成双索引。已在代码注释中标记 TODO。
- **DB 不写入**:GC 只动内存层,不要 `DELETE peer`。DB 仍是真相之源。
- **限流交互**:`IP_BLOCKER` / `IP_CHANGES`(`peer.rs:13-19`)已有自己的过期机制,不要复用本卡的 GC,避免行为变化。
- **敏感字段不落盘**:本卡新增的日志仅打条目数与峰值,不打 peer_id / IP。debug 级别开放,info 级别不打。
- **数据库迁移回滚**:无 schema 变化,无需迁移。
- **CE-M0-7 协调**:CE-M0-7 会在 `RendezvousServer` 上加管理 socket 字段;本卡只在 `tcp_punch` 字段附近改类型,不与之冲突。先合并谁都不影响对方,但合并顺序约定:CE-M0-6 先,CE-M0-7 后,在 CE-M0-7 的 rebase 中只需保留本卡修改即可。

## 9. 回滚方案

1. 单提交回滚:本卡所有改动应集中在 1-2 个 commit。`git revert <hash>` 即可。
2. 若已和后续 PR 交织,则按文件回滚:
   - `git checkout HEAD~ -- rustdesk-server/src/rendezvous_server.rs rustdesk-server/src/peer.rs`
   - `git rm rustdesk-server/src/tcp_punch_key.rs`
3. 无需任何 DB 迁移回滚。
4. 运行时熔断:可临时把环境变量 `PEER_MAP_IDLE_TTL_SECS=99999999` 和 `TCP_PUNCH_TTL_SECS=99999999` 设上,等同于禁用 GC,行为回到旧版(代价:重新泄漏)。
5. 若发现 `TcpPunchKey` 在某场景下错配,可以临时改回 fallback by-addr 查询占主路径:留 `feature = "tcp_punch_key_v2"` 编译开关(建议命名,可调整),关闭时走老路径。

## 10. 完成定义 (DoD)

- [ ] `rustdesk-server/src/tcp_punch_key.rs` 新建并含 ≥3 个单测,全部通过。
- [ ] `rustdesk-server/src/peer.rs` 增加 `PeerMap::gc(ttl_secs: u64) -> usize`,含 ≥3 个单测。
- [ ] `rustdesk-server/src/rendezvous_server.rs` 中 `tcp_punch` 类型替换为强类型 key,所有 5 处读写改完,新增 GC select 分支。
- [ ] `cargo build --bins` 在 `rustdesk-server` 下成功。
- [ ] `cargo test peer && cargo test rendezvous && cargo test tcp_punch_key` 全绿。
- [ ] `cargo clippy --all-targets -- -D warnings` 无新增告警。
- [ ] 新增/修改的公共注释包含 `// CE-M0-6:` 前缀,便于 grep。
- [ ] 在改动点上方写明 fallback by-(ip,port) 的 O(n) 风险与未来工单。
- [ ] 与 CE-M0-7 owner 口头确认或在 PR 描述里 cross-link,声明 rebase 顺序。
- [ ] 在 `docs/ai-development-plan.md` 的对应任务卡末尾追加 `状态: 完成 (commit <hash>)`。
