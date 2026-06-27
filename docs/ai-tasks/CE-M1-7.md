# CE-M1-7 客户端审计上报

## 1. 任务目标

在 `rustdesk` 被控端补齐审计事件上报：复用现有 `/api/audit/conn` 与 `/api/audit/file`，新增剪贴板事件、连接被策略拒绝、异常断开、长时间 relay 三类告警，并把所有上报统一收口为「fire-and-forget + 有界队列 + 有限重试」管道。验收信号：会话期间所有 audit 事件按预期发出；当 API 不可达或 5xx 时不阻塞远控会话；队列堆积超 1000 条时丢弃最旧条目并打日志；剪贴板文本仅以 hash + length 形式上报，不出现明文。原始任务卡逐字摘录:

> 文件传输复用 `/api/audit/file`。剪贴板/告警走新事件端点或统一视图。上报失败不能阻塞远控会话。上报点:文件发送/接收开始、成功、失败;文本剪贴板同步;文件剪贴板同步;连接被策略拒绝、异常断开、长时间 relay。

## 2. 上下文与依赖

- **上游依赖任务卡**
  - CE-M1-6「审计事件扩展」必须先在 `rustdesk-api` 落地 `POST /api/audit/clipboard`（或统一 `POST /api/audit/event`）端点与 `audit_event` 表。客户端只面向已存在的 endpoint 编码。
  - CE-M0-1 hbb_common fork 对齐：本任务不修改 protobuf，但要求 `hbb_common` 基线稳定。
- **下游会用到此输出的任务卡**
  - CE-M1-10 运维文档「audit-events.md」需要把本任务新增的事件 schema、env 开关、回滚开关写进文档。
  - 未来 M2 RBAC 拒绝事件（`access_policy` deny）需要复用本任务建立的 alarm 通道。
- **关键背景事实（来自源码）**
  - 现有 `post_conn_audit` 使用顺序 mpsc 管道 `tx_post_seq`（`rustdesk/src/server/connection.rs:347` 字段定义、`:446` 创建 `unbounded_channel`、`:1212` `post_seq_loop` 消费、`:1389` 入队），是「无界 mpsc」——后端慢会导致内存膨胀。
  - 现有 `post_file_audit`（`rustdesk/src/server/connection.rs:1408-1442`）和 `post_alarm_audit`（`:1444-1467`）用 `tokio::spawn` 直接发，**无重试也无背压**，失败仅 `allow_err!`。
  - 上报最终调用 `post_audit_async`（`:1470`） → `crate::post_request`（`rustdesk/src/common.rs:1399`），后者已带 TCP-proxy fallback 与超时。
  - 审计 URL 由 `crate::get_audit_server(api, custom, typ)` 生成，模板 `{url}/api/audit/{typ}`（`rustdesk/src/common.rs:1119-1124`）。当前 typ ∈ {`conn`,`file`,`alarm`}。
  - 现有文件审计触发点：`:786`（Cliprdr 文件剪贴板 RemoteSend）、`:2962`（Cliprdr.Files RemoteReceive）、`:3016`（`FileAction::Send` RemoteSend）、`:3203`（`FileAction::Receive` RemoteReceive）、`:4738`（`handle_read_dir` 完成）、`:4868`（`process_new_read_job`）。文件传输的 **开始** 事件已经存在，**成功/失败** 事件目前缺失。
  - 现有 alarm 触发点：`:1317`（IpWhitelist）、`:3701`（TerminalOsLoginConcurrency）、`:3889`（ExceedIPv6PrefixAttempts）、`:3934`（OS credential policy decision）、`:3971`（ExceedThirtyAttempts）、`:3982`（SixAttemptsWithinOneMinute）。**「策略拒绝」与「长时间 relay」目前没有任何事件发出**。
  - 文本/HTML/图片剪贴板进入处于 `Some(message::Union::Clipboard(cb))`（约 `rustdesk/src/server/connection.rs:2920` 区域）与 `Some(message::Union::MultiClipboards(_mcb))`（`:2951`）两个分支，**当前没有任何 audit 上报**。
  - `AlarmAuditType` 与 `FileAuditType` 枚举在 `rustdesk/src/server/connection.rs:5523-5539`，以 `as i8` 编码到 JSON `typ` 字段——服务端只看数字，**新增枚举值向后兼容**。
  - 连接关闭点：`:1094` 上报 `{"action":"close"}`，没有携带原因/异常标记。
  - 录屏上传 `rustdesk/src/hbbs_http/record_upload.rs` 是参考实现（独立线程 + Receiver）但属于 record 通道，不复用其管道。
  - 客户端 `rustdesk/src/client.rs` 不参与被控端审计上报（grep `audit` 在 client.rs 无命中），本任务**只改被控端 server 侧**。

## 3. 涉及文件清单

| 路径 | 动作 | 行数估计 | 说明 |
|------|------|---------|------|
| `rustdesk/src/hbbs_http/audit.rs` | 新建 | ~220 | 新增统一审计上报管道：有界队列、丢最旧、有限重试 worker、`enqueue(url, payload)` API、`hash_clipboard_text` 工具 |
| `rustdesk/src/hbbs_http.rs`（或 `mod.rs`） | 修改 | +1 | `pub mod audit;` |
| `rustdesk/src/server/connection.rs` | 修改 | ~+180 / 改 ~30 | (a) 移除 `tx_post_seq`/`post_seq_loop`，改走 `audit::enqueue`；(b) `post_file_audit` / `post_alarm_audit` 改走 `audit::enqueue`；(c) 在 `message::Union::Clipboard` / `MultiClipboards` 处新增 `post_clipboard_audit`；(d) `on_close` 区分 `abnormal_close`；(e) `AlarmAuditType` 新增 `ConnectionDenied = 9`、`LongRelay = 10`；(f) 文件传输完成/失败处补 `post_file_audit_result` |
| `rustdesk/src/common.rs` | 修改 | +6 | `get_audit_server` 增加 `clipboard` typ 支持（typ 字段直接透传即可，无需修改函数本身，但需要 helper 常量 `pub const AUDIT_TYP_CLIPBOARD: &str = "clipboard";` 等，**建议命名,可调整**） |
| `rustdesk/src/server/clipboard_service.rs` | 修改 | ~+15 | 在产生 outbound clipboard message 处补上 audit 钩子（仅元信息），或者集中在 `connection.rs` 入口；二选一，**建议在 connection.rs 侧统一以减小耦合面** |
| `rustdesk/Cargo.toml` | 修改 | +1 | 引入 `sha2 = "0.10"`（若未声明）用于剪贴板内容 hash；若已经间接依赖则跳过 |
| `rustdesk/src/hbbs_http/tests/audit_tests.rs` | 新建 | ~120 | 单元/集成测试：队列丢最旧、重试上限、剪贴板 hash 截断、URL 为空不入队 |
| `docs/operations/audit-events.md` | 修改（CE-M1-10 范围内追加） | ~+30 | 列出 typ 数值表、字段定义、回滚开关。**本任务卡只占位提醒，正文由 CE-M1-10 完成** |

> 备注：未找到 client.rs 中需要修改的点；剪贴板审计完全在被控端发出。`rustdesk-api` 端新增端点不在本卡范围内（CE-M1-6 负责）。

## 4. 数据契约

### 4.1 队列与重试配置常量（`hbbs_http/audit.rs`）

```rust
// 建议命名,可调整
pub const AUDIT_QUEUE_CAPACITY: usize = 1000;
pub const AUDIT_RETRY_MAX: u32 = 3;
pub const AUDIT_RETRY_BACKOFF_MS: [u64; 3] = [500, 2000, 5000]; // total <= 8s
pub const CLIPBOARD_TEXT_PREVIEW_BYTES: usize = 64;  // 截断长度
```

### 4.2 HTTP 上报形状

复用现有 `POST /api/audit/{typ}` 端点，body 为 `application/json`。新增 typ：

| typ | 端点 | 触发场景 |
|-----|------|---------|
| `conn` | `/api/audit/conn` | 现有，复用 |
| `file` | `/api/audit/file` | 现有，复用；新增 outcome 字段 |
| `alarm` | `/api/audit/alarm` | 现有，复用；新增 `ConnectionDenied` / `LongRelay` |
| `clipboard` | `/api/audit/clipboard` | **新增**，依赖 CE-M1-6 服务端落地 |

剪贴板事件 payload（client → api）：

```json
{
  "id": "<peer_id of host>",
  "uuid": "<base64 uuid>",
  "conn_id": 123,
  "peer_id": "<controller my_id>",
  "from_name": "<controller name>",
  "ip": "1.2.3.4",
  "direction": "rx" | "tx",
  "format": "text" | "html" | "rtf" | "image" | "file",
  "length": 12345,
  "sha256": "<hex prefix 32 chars>",
  "preview": "<utf8 truncated <=64B, only when format=text>",
  "ts": 1719500000
}
```

文件审计 payload 扩展（兼容追加字段）：

```json
{
  "id": "...", "uuid": "...", "peer_id": "...", "conn_id": 1,
  "type": 0,
  "path": "...",
  "is_file": true,
  "info": "...",
  "outcome": "start" | "success" | "fail",
  "error": "<reason on fail>"
}
```

`outcome`/`error` 是**新增可选字段**；老 API 忽略即可。

### 4.3 AlarmAuditType 扩展

```rust
// rustdesk/src/server/connection.rs:5523
pub enum AlarmAuditType {
    IpWhitelist = 0,
    ExceedThirtyAttempts = 1,
    SixAttemptsWithinOneMinute = 2,
    ExceedIPv6PrefixAttempts = 6,
    TerminalOsLoginBackoff = 7,
    TerminalOsLoginConcurrency = 8,
    ConnectionDenied = 9,   // 新增：策略/whitelist 之外的连接拒绝
    LongRelay = 10,         // 新增：会话超过阈值仍走 relay
}
```

不复用 3/4/5（已注释保留位）。新增值取递增整数确保兼容。

### 4.4 配置项

| Key | 默认 | 作用域 | 说明 |
|-----|------|--------|------|
| `audit-disable` | `""` | `Config::get_option` | 设为 `Y` 则完全停发审计（保险开关） |
| `audit-long-relay-secs` | `300` | 同上 | 长时间 relay 阈值（秒），超时触发一次 `LongRelay` |
| `audit-clipboard-disable` | `""` | 同上 | 设为 `Y` 则停发剪贴板审计 |

> 命名约定参考 `rustdesk/src/common.rs:1119` 的 `api-server`/`custom-rendezvous-server` 风格，**建议命名,可调整**。

## 5. 实现步骤

1. **新建 `rustdesk/src/hbbs_http/audit.rs`**：定义 `AuditJob { url, body, attempts }`、`enqueue(url, body) -> Result<(), DropReason>`、全局 `OnceCell<UnboundedSender<AuditJob>>`。worker 端用 `tokio::sync::mpsc::channel(AUDIT_QUEUE_CAPACITY)`；`enqueue` 在 `try_send` 失败时调用 `try_recv` 丢最旧再 `try_send`，并 `log::warn!` 计数。worker 收到 job 后顺序执行 `crate::post_request(url, body.to_string(), "")`（参考 `rustdesk/src/common.rs:1399`），失败按 `AUDIT_RETRY_BACKOFF_MS` 重试，超过 `AUDIT_RETRY_MAX` 丢弃。
2. **在 `rustdesk/src/hbbs_http.rs` 注册新模块**：追加 `pub mod audit;`。worker 在首次 `enqueue` 时由 `OnceCell::get_or_init` lazy 启动 `tokio::spawn(audit_worker(rx))`。
3. **删除/改写 `post_seq_loop` 与 `tx_post_seq`**：`rustdesk/src/server/connection.rs:347, 446, 538, 1212, 1389` 相关代码删除；`post_conn_audit`（`:1379`）改为 `crate::hbbs_http::audit::enqueue(url, v)`。保留 URL 留空跳过的语义（`:1380`）。
4. **`post_file_audit` 改造**（`:1408-1442`）：去掉内联 `tokio::spawn`，统一走 `audit::enqueue`。新增可选 `outcome` 参数（默认 `start`）。
5. **`post_alarm_audit` 改造**（`:1444-1467`）：同上走 `audit::enqueue`。
6. **添加 `post_clipboard_audit` 方法**：实现新私有方法 `fn post_clipboard_audit(&self, direction: &str, format: &str, content: &[u8])`，内部用 `sha2::Sha256` 计算前 16 字节 → hex；只有 text 格式才填 `preview`（UTF-8 安全截断，使用 `floor_char_boundary`-类逻辑，避免劈半字符）。在 `rustdesk/src/server/connection.rs:2920` 附近 `Clipboard(cb)` 分支与 `:2951` `MultiClipboards(_mcb)` 分支调用。注意：cb 内容若 `compressed` 需要先 `hbb_common::compress::decompress` 取得明文长度，但**不要把明文写日志**。
7. **文件传输 outcome 事件**：在 `handle_file_read_done`（`:4782`，成功）和 `handle_file_read_error`（`:4805`，失败）分别补一次 `post_file_audit(...; outcome="success" | "fail")`。需要保留首份 `start` 事件不变。
8. **异常断开**：在 `Connection::start` 末尾 `:1094` 之前判断 `conn.on_close` 是否携带非 `"End"`/非用户主动关闭原因，区分 `"action":"close"` 与 `"action":"abnormal_close","reason":<str>`。改造点不要触及现有 `on_close("End", true)` 的语义。
9. **策略拒绝事件**：暂时只接 `check_whitelist` 已有的 `IpWhitelist`；预留一个 `post_alarm_audit(AlarmAuditType::ConnectionDenied, info)` helper，供 M2 RBAC 直接调用。本卡只补一个调用点：`send_login_error` 在 access policy 拒绝场景（如果当前没有 policy 拒绝路径，则只放枚举不放调用，并在 commit message 中注明）。
10. **长时间 relay 检测**：在主循环（`rustdesk/src/server/connection.rs:Connection::start` 内的 tokio::select tick 路径）增加 `last_relay_alarm_at: Option<Instant>` 字段；当 `self.lr.is_relay` 或本会话经过中继且累计时长 > `audit-long-relay-secs` 时，每会话只发一次 `LongRelay`。若 `is_relay` 信息不在结构体上，从 `controlled_context` 推断；找不到则采取保守策略：用 `session_start` 时间 + relay flag（如果都没有，则把该上报放在 `post_conn_audit("action":"close")` 时附加 `duration` 字段并由服务端判断；**实现时按当前可用信号选定方案并在 PR 描述中说明**）。
11. **加 Cargo 依赖**：若 `sha2` 在 `rustdesk/Cargo.toml` 未声明，新增 `sha2 = "0.10"`。先 `cargo tree -p rustdesk | grep sha2` 确认。
12. **测试**：见 §6。
13. **运行 cargo check / cargo test 验证**。

## 6. 测试用例

| # | 测试文件路径 | 测试名 | 输入 | 期望 |
|---|--------------|--------|------|------|
| 1 | `rustdesk/src/hbbs_http/tests/audit_tests.rs` | `enqueue_returns_ok_when_queue_has_space` | 入队 1 条，url 非空 | `Ok(())`，worker 收到 1 个 job |
| 2 | 同上 | `enqueue_drops_oldest_when_queue_full` | 启动一个永不消费的 mock worker，入队 1001 条 | 第 1001 条入队成功，第 1 条被丢弃，`log::warn!` 计数 +1 |
| 3 | 同上 | `worker_retries_then_gives_up` | url 指向 mock server，前 3 次 503，第 4 次 200 | 共发出 3 次请求（attempts = 3），最终放弃，不 panic，不阻塞下一条 |
| 4 | 同上 | `enqueue_noop_when_url_empty` | `enqueue("", payload)` | 不入队、返回 Ok |
| 5 | 同上 | `clipboard_text_is_hashed_and_truncated` | content = 5 KB 全 `'a'` | payload `length=5120`，`sha256` = `sha256("a"*5120)` 的 hex 前 32 字符，`preview` 长度 ≤ 64 且为有效 UTF-8 |
| 6 | 同上 | `clipboard_audit_does_not_send_image_content` | format = "image"，content = 1 MB | payload 不含 `preview`，body 字节数 < 512 |
| 7 | `rustdesk/src/server/connection.rs`（`#[cfg(test)]` 模块内） | `alarm_audit_type_numeric_compat` | 反序列化老枚举值 0/1/2/6/7/8 | 数字与枚举一一对应，新增 9/10 不冲突 |
| 8 | 同上 | `file_audit_outcome_field_is_optional` | 旧 server 解析未带 outcome 的 payload | 解析成功（兼容性回归用 serde_json::from_str 校验） |

happy path 由 #1、#5 覆盖；失败模式由 #2、#3 覆盖；向后兼容由 #7、#8 覆盖。

## 7. 验证命令

```bash
# 在 rustdesk 目录下
cd /Volumes/MBA_1T/Code/远程控制/rustdesk

# 1. 编译检查（macOS dev box 可跑）
cargo check --no-default-features

# 2. 跑单元测试（仅 hbbs_http 子集，避开平台依赖）
cargo test -p rustdesk hbbs_http::audit --no-default-features

# 3. 跑 connection 相关测试
cargo test -p rustdesk server::connection --no-default-features

# 4. （可选, 需要构建产物）端到端：起一个本地 rustdesk-api，配置 api-server 指向它，发起一次会话并复制文本，
#    然后 curl http://<api>/api/audit/clipboard/list 验证收到 hash-only 事件
#    -> macOS dev box 可跳过，理由：依赖 rustdesk-api 实例与剪贴板权限授予。

# 5. Flutter 主流程 smoke（可跳过）
#   ./flutter/build_runner.sh -> macOS dev box 可跳过，理由：本任务不改 Flutter 层。
```

> macOS 上可能因 Windows-only 代码段（`#[cfg(target_os = "windows")]` 围绕 `ipc::Data::ClipboardFile`，见 `:776`）而 cargo check 命中条件编译跳过，仍需在 PR 中说明已在 Windows CI 验证或手动 cross-compile。

## 8. 兼容性 / 安全注意事项

- **protobuf**：本任务不改 .proto；新增字段只在 HTTP JSON 层，老服务端 `rustdesk-api` 默认 `RestAPI` 解析会忽略未知字段，无破坏。
- **老客户端 → 新服务端**：老客户端不会发 clipboard / outcome / abnormal_close 事件，新 API 端点不应强制必填字段（CE-M1-6 注意）。
- **新客户端 → 老服务端**：老 `rustdesk-api` 没有 `/api/audit/clipboard` → 客户端会收到 404，会经历 `AUDIT_RETRY_MAX` 后丢弃；不要在客户端硬失败。检测一次 404 后建议本会话内静默该 endpoint（实现时给 worker 加 in-memory `dead_endpoints` set）。
- **数据库迁移**：本卡不涉及；服务端 schema 在 CE-M1-6。回滚由 CE-M1-6 负责。
- **敏感字段**：
  - 剪贴板 **明文 absolutely never** 写入 payload；仅 SHA-256 前 16 字节 hex + 长度 + UTF-8 前 64 字节 preview。
  - 文件路径 path 已经在现有 audit 里上报（`:1435`），保持现状不收紧。
  - 不要把 `lr.password`、token、2FA secret 写入 payload。
- **限流**：worker 顺序消费，不并发；后端 5xx 时退避 `[0.5s, 2s, 5s]`，单条最长占用 ~8s，1000 条最坏阻塞 ~2.2 小时——这是合理上限，因为期间持续 try_send 会触发 drop-oldest 自我保护。
- **不要阻塞会话**：`audit::enqueue` 必须是同步、非阻塞（`try_send` 而非 `send().await`）。所有调用点不得 `.await` 上报结果。
- **GDPR/隐私**：剪贴板内容 hash 化保证在合规审计需求与隐私之间取得平衡；preview 长度策略需在运维文档中明确说明。

## 9. 回滚方案

- 完全回滚：`Config::set_option("audit-disable", "Y")` 在被控端立即停发所有审计（`audit::enqueue` 在函数开头先判断该开关）；不需要重启。
- 只回滚剪贴板：`Config::set_option("audit-clipboard-disable", "Y")`。
- 代码回滚：本任务以单一 commit 引入，`git revert <hash>` 即可。
- 服务端无需迁移回滚（端点是 additive；旧 `/api/audit/file` 路径未改动）。
- 若新加的 `AlarmAuditType::ConnectionDenied = 9 / LongRelay = 10` 与服务端 CE-M1-6 表枚举冲突，仅需在 commit 中把数值改大并 cherry-pick；客户端不持久化这些数值。

## 10. 完成定义 (DoD)

- [ ] `rustdesk/src/hbbs_http/audit.rs` 新建并通过单测。
- [ ] `rustdesk/src/server/connection.rs` 所有 `tokio::spawn(post_audit_async)` 与 `tx_post_seq` 调用替换为 `audit::enqueue`。
- [ ] `AlarmAuditType::ConnectionDenied / LongRelay` 已添加，且未占用旧值。
- [ ] 剪贴板上报点 (`message::Union::Clipboard`、`MultiClipboards`) 完成接入，且 payload 不含明文。
- [ ] 文件传输 outcome（success/fail）事件在 `handle_file_read_done` / `handle_file_read_error` 触发。
- [ ] 异常断开在 `Connection::start` 末尾发出 `"action":"abnormal_close"`。
- [ ] 长时间 relay 阈值检测每会话最多发一次。
- [ ] 配置开关 `audit-disable` / `audit-clipboard-disable` / `audit-long-relay-secs` 可热生效。
- [ ] 队列容量 1000、drop-oldest、最多重试 3 次的行为有单测覆盖。
- [ ] `cargo check` 与 `cargo test -p rustdesk hbbs_http::audit` 通过。
- [ ] 在 PR 描述里附 mock server 抓包样例（含一次剪贴板 hash payload）。
- [ ] 在 docs/ai-development-plan.md 的对应任务卡末尾追加 "状态: 完成 (commit <hash>)".
