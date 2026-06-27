# AI 任务规格索引 (CE-M0 / CE-M1)

> 上游规划:`docs/upgrade-plan.md`
> 任务卡来源:`docs/ai-development-plan.md` §4 / §5
> 编制日期:2026-06-27
> 适用范围:`rustdesk-server` / `rustdesk-api` / `rustdesk` 三个仓库的就地修改

---

## 1. 索引用途

本目录(`docs/ai-tasks/`)是 CE-M0 与 CE-M1 阶段所有任务卡的"实施级"规格集合,面向后续直接动手开发的 AI agent。每接一个 CE 任务时,先在本索引第 2 节定位到对应规格文件,读完该文件的"先读 / 实现 / 验证 / 兼容性"四段,再去对应仓库改代码。完成后必须按第 6 节流程同步状态。本索引不重写规格内容,只做导航、依赖、横切约定与状态追踪。

---

## 2. 任务清单

> 状态字段含义:`未开始` / `进行中` / `完成 (commit <hash>)`。
> 链接为相对路径,点击即可在仓库内跳转。

| ID | 标题 | 仓库 | 阶段 | 依赖 | 规格文件 | 状态 |
|----|------|------|------|------|----------|------|
| CE-M0-1 | hbb_common fork 对齐 | 跨仓(rustdesk-server + rustdesk) | M0 | — | [./CE-M0-1.md](./CE-M0-1.md) | 未开始 |
| CE-M0-2 | hbbs PostgreSQL 后端 | rustdesk-server | M0 | CE-M0-1 | [./CE-M0-2.md](./CE-M0-2.md) | 未开始 |
| CE-M0-3 | hbbs/hbbr Prometheus metrics 独立端口 | rustdesk-server | M0 | CE-M0-1 | [./CE-M0-3.md](./CE-M0-3.md) | 未开始 |
| CE-M0-4 | rustdesk-api Redis / metrics healthcheck | rustdesk-api | M0 | — | [./CE-M0-4.md](./CE-M0-4.md) | 未开始 |
| CE-M0-5 | systemd 加固 + 专用用户 | rustdesk-server | M0 | CE-M0-1 | [./CE-M0-5.md](./CE-M0-5.md) | 未开始 |
| CE-M0-6 | PeerMap GC + tcp_punch key 加固 | rustdesk-server | M0 | CE-M0-2 | [./CE-M0-6.md](./CE-M0-6.md) | 未开始 |
| CE-M0-7 | 管理 CLI 改 UDS + token | rustdesk-server | M0 | CE-M0-1 | [./CE-M0-7.md](./CE-M0-7.md) | 未开始 |
| CE-M1-1 | 数据模型 user_mfa | rustdesk-api | M1 | CE-M0(全部) | [./CE-M1-1.md](./CE-M1-1.md) | 未开始 |
| CE-M1-2 | MFA service (TOTP enroll/verify/recovery) | rustdesk-api | M1 | CE-M1-1 | [./CE-M1-2.md](./CE-M1-2.md) | 未开始 |
| CE-M1-3 | 两步登录状态机 | rustdesk-api | M1 | CE-M1-2 | [./CE-M1-3.md](./CE-M1-3.md) | 未开始 |
| CE-M1-4 | 客户端 API MFA UI | rustdesk | M1 | CE-M1-3 | [./CE-M1-4.md](./CE-M1-4.md) | 未开始 |
| CE-M1-5 | 后台强制 MFA (user + group level) | rustdesk-api | M1 | CE-M1-3 | [./CE-M1-5.md](./CE-M1-5.md) | 未开始 |
| CE-M1-6 | 审计事件扩展 (clipboard/alarm/cmd/record) | rustdesk-api | M1 | CE-M1-1..5 | [./CE-M1-6.md](./CE-M1-6.md) | 未开始 |
| CE-M1-7 | 客户端审计上报 | rustdesk | M1 | CE-M1-6 | [./CE-M1-7.md](./CE-M1-7.md) | 未开始 |
| CE-M1-8 | WS Register 补齐 (RegisterPeer / RegisterPk) | rustdesk-server | M1 | CE-M0(全部) | [./CE-M1-8.md](./CE-M1-8.md) | 未开始 |
| CE-M1-9 | 轻量 Client Builder | rustdesk-api | M1 | CE-M1-1..5 | [./CE-M1-9.md](./CE-M1-9.md) | 未开始 |
| CE-M1-10 | 运维文档 docs/operations/{2fa,audit-events}.md | 跨仓(docs) | M1 | CE-M1-3, CE-M1-6 | [./CE-M1-10.md](./CE-M1-10.md) | 未开始 |

---

## 3. 推荐执行顺序

> 来源:`docs/ai-development-plan.md` §3 的 Mermaid DAG,此处文字化并对每个节点点名。
> 同层节点彼此独立,可并行;跨层必须等上层全部完成。

**Step 0:Preflight**
执行 `docs/ai-development-plan.md` §0 的所有 `git status` / `submodule status` 命令,核实工作树,然后再启动 Step 1。

**Step 1:M0 基线对齐**
执行 [./CE-M0-1.md](./CE-M0-1.md)(hbb_common fork 对齐)。
说明:CE-M0-1 是后续所有 Rust 侧改动的前提,不完成不要开 CE-M0-2/3/5/6/7。
注:CE-M0-4 只动 rustdesk-api,可与 CE-M0-1 并行。

**Step 2:M0 横向铺开(CE-M0-1 完成后并行)**
- 执行 [./CE-M0-2.md](./CE-M0-2.md)(hbbs PostgreSQL 后端)
- 执行 [./CE-M0-3.md](./CE-M0-3.md)(metrics 独立端口)
- 执行 [./CE-M0-5.md](./CE-M0-5.md)(systemd 加固)
- 执行 [./CE-M0-4.md](./CE-M0-4.md)(rustdesk-api Redis healthcheck,独立赛道)
- 执行 [./CE-M0-7.md](./CE-M0-7.md)(管理 CLI 改 UDS + token,与 §3 DAG 等同 Step 2 节点)

**Step 3:M0 收口(依赖 Step 2)**
执行 [./CE-M0-6.md](./CE-M0-6.md)(PeerMap GC + tcp_punch key 加固)。
依赖 CE-M0-2,因为 PeerMap 后台 GC 会涉及数据库后端抽象上的事件。

**Step 4:M0 验证 gate**
在进入 M1 前,跑一遍 `docs/ai-development-plan.md` §7 验证矩阵,确认 CE-M0-1..7 全部通过。本步骤是 hard gate。

**Step 5:M1 主干(M0 全部完成后并行启动两条赛道)**
- 赛道 A(API/Web MFA,串行):
  - 执行 [./CE-M1-1.md](./CE-M1-1.md) → [./CE-M1-2.md](./CE-M1-2.md) → [./CE-M1-3.md](./CE-M1-3.md)
  - 之后并行执行 [./CE-M1-4.md](./CE-M1-4.md) 与 [./CE-M1-5.md](./CE-M1-5.md)
- 赛道 B(WS Register,独立):
  - 执行 [./CE-M1-8.md](./CE-M1-8.md)

**Step 6:M1 扩展(赛道 A 完成后并行)**
- 执行 [./CE-M1-6.md](./CE-M1-6.md)(审计事件扩展)
- 之后执行 [./CE-M1-7.md](./CE-M1-7.md)(客户端审计上报)
- 并行执行 [./CE-M1-9.md](./CE-M1-9.md)(轻量 Client Builder)

**Step 7:M1 收口**
- 执行 [./CE-M1-10.md](./CE-M1-10.md)(运维文档,依赖 CE-M1-3 与 CE-M1-6 的最终配置项稳定)
- 跑一遍 `docs/ai-development-plan.md` §7 验证矩阵收尾。

---

## 4. 跨任务一致性约定

所有 17 个规格文件必须在以下决策上保持一致;如果某个规格里出现不一致,**以本节为准**。

### 4.1 命名

- **环境变量前缀**
  - rustdesk-api(Go,Viper):`RUSTDESK_API_*`(沿用 lejianwen 现有约定),新增项不得使用 `API_*` / `RDAPI_*` / 裸名。
  - rustdesk-server(Rust,hbbs/hbbr):`RUSTDESK_SERVER_*`,管理 CLI token 文件路径用 `RUSTDESK_SERVER_ADMIN_TOKEN_FILE`;metrics 端口用 `RUSTDESK_SERVER_METRICS_BIND`。
  - 客户端(rustdesk):沿用上游 `RUSTDESK_*`,不新增 CE 私有前缀。
- **Prometheus metric 前缀**
  - hbbs:`rustdesk_hbbs_*`(例:`rustdesk_hbbs_peers_online`、`rustdesk_hbbs_register_total`)。
  - hbbr:`rustdesk_hbbr_*`(例:`rustdesk_hbbr_sessions`、`rustdesk_hbbr_bytes_in_total`)。
  - rustdesk-api:`rustdesk_api_*`(例:`rustdesk_api_login_total`、`rustdesk_api_mfa_verify_duration_seconds`)。
- **数据库表前缀**
  - rustdesk-api 新表沿用现有不加项目前缀的风格:`user_mfa`、`audit_event`。**不要**加 `rd_` / `ce_` 前缀。
  - 列名一律 `snake_case`,主键统一 `id`,时间列 `created_at` / `updated_at` / `deleted_at`(GORM 软删)。

### 4.2 错误码

API 统一返回形态(适用于 `/api/*` 与 `/_admin/api/*`,沿用 rustdesk-api 现有结构):

```json
{
  "code": 0,
  "msg": "ok",
  "data": { ... }
}
```

- `code = 0` 表示成功,非零表示失败。
- HTTP 状态码语义化(401 未登录、403 无权限、422 参数错误、500 内部错误),但 body 必须保持 `{code, msg, data}` 结构,**不要**裸 JSON。
- 新增错误码集中在 `http/response/errcode.go`(或同名文件),不要分散到各 controller。
- MFA 相关错误码占段位 `1100-1199`,审计扩展占 `1200-1299`,Client Builder 占 `1300-1399`,后续 RBAC 占 `1400-1499`。

### 4.3 配置文件

- yaml key 一律 `snake_case`(`mfa_required`、`metrics_bind`、`audit_event_kinds`),禁止 camelCase 与连字符。
- 新增配置项必须有默认值,**默认值必须能让旧部署零改动启动**(MFA 强制 = off、metrics_bind 空 = 不启动 endpoint)。
- rustdesk-api 主配置文件 `conf/config.yaml`,新增段落必须同步更新 `conf/config.yaml.tpl` 与 `docs/operations/*.md`。
- rustdesk-server CLI flag 与环境变量保持 1:1 映射(短横线 ↔ 下划线),CLI flag 优先级最高。

### 4.4 日志

- rustdesk-server / rustdesk(Rust 侧):统一使用 `tracing` crate(沿用上游;不要混入 `log!` 宏新写法)。结构化字段命名:
  - 用户/会话:`user_id`、`peer_id`、`session_id`、`from_peer`、`to_peer`。
  - 网络:`remote_addr`、`relay`、`conn_type`(udp/tcp/ws)。
  - 错误:`error.kind`、`error.message`。
  - **不要**在 info 级别打印 token / secret / recovery code。
- rustdesk-api(Go 侧):沿用现有 `lejianwen/rustdesk-api` 选用的 zap(`global.Logger`)。**不要**引入 logrus 或 zerolog,**不要**裸 `fmt.Println`。
  - 字段命名与 Rust 侧对齐:`user_id`、`peer_id`、`request_id`、`ip`。
  - request_id 由 gin 中间件统一注入,所有 service 层 log 必须带 `request_id`。
- 日志级别约定:启动配置 = info;每个 HTTP 请求一行 access log = info;业务异常 = warn;系统级失败 = error;高频路径(register、heartbeat、metrics scrape)= debug。

---

## 5. 验证矩阵汇总

> 来源:`docs/ai-development-plan.md` §7。每个 CE 任务的"验收"段是其本地命令出处,本表为跨任务最小回归集。

| 场景 | 命令 / 方式 | 通过标准 | 对应 CE 验收出处 |
|------|------------|----------|------------------|
| rustdesk-api 单测 | `cd rustdesk-api && go test ./...` | 全绿或记录已知失败 | [CE-M0-4 §验收](./CE-M0-4.md) / [CE-M1-1 §验收](./CE-M1-1.md) / [CE-M1-2 §验收](./CE-M1-2.md) |
| rustdesk-server 编译 | `cd rustdesk-server && cargo check` | 无编译错误 | [CE-M0-2 §验收](./CE-M0-2.md) / [CE-M0-6 §验收](./CE-M0-6.md) |
| rustdesk-server 单测 | `cd rustdesk-server && cargo test` | 全绿或记录已知失败 | [CE-M0-2 §验收](./CE-M0-2.md) / [CE-M0-6 §验收](./CE-M0-6.md) / [CE-M1-8 §验收](./CE-M1-8.md) |
| rustdesk 客户端编译 | `cd rustdesk && cargo check` 或既有构建脚本 | 无协议/类型错误 | [CE-M0-1 §验收](./CE-M0-1.md) / [CE-M1-4 §验收](./CE-M1-4.md) / [CE-M1-7 §验收](./CE-M1-7.md) |
| API 登录兼容(MFA off) | curl `/api/login`(无 MFA 账号) | 响应与旧流程兼容,旧客户端可解析 | [CE-M1-3 §验收](./CE-M1-3.md) |
| API MFA(MFA on) | curl `/api/login` → `/api/login-mfa` | 必须二次校验通过才返回 token | [CE-M1-2 §验收](./CE-M1-2.md) / [CE-M1-3 §验收](./CE-M1-3.md) / [CE-M1-5 §验收](./CE-M1-5.md) |
| WS Register | WS-only 客户端发 `RegisterPeer` | hbbs PeerMap 中可见 | [CE-M1-8 §验收](./CE-M1-8.md) |
| Audit file 兼容 | `/api/audit/file` 写入与查询 | 旧接口语义不变 | [CE-M1-6 §验收](./CE-M1-6.md) / [CE-M1-7 §验收](./CE-M1-7.md) |
| Client Builder | 下载文件名解析 | 客户端启动后 server/key/api 正确 | [CE-M1-9 §验收](./CE-M1-9.md) |
| Metrics | `curl http://127.0.0.1:<port>/metrics` | 指标非空且不占 21114 | [CE-M0-3 §验收](./CE-M0-3.md) / [CE-M0-4 §验收](./CE-M0-4.md) |
| systemd 加固 | `systemd-analyze security rustdesk-hbbs.service` | 评级 ≥ OK | [CE-M0-5 §验收](./CE-M0-5.md) |
| 管理 CLI 隔离 | 本机普通用户调用管理命令 | 拒绝;rustdesk 用户/root 可调用 | [CE-M0-7 §验收](./CE-M0-7.md) |

如果因为平台依赖(macOS 无 systemd、CI 无 Postgres 实例等)无法运行某项,执行 agent 必须在 PR / 完成说明中注明未运行原因与替代检查。

---

## 6. 状态追踪

- 当前所有 CE 状态默认 = **未开始**(见第 2 节表格"状态"列)。
- 完成任务后,执行 agent 必须按顺序完成以下三步,否则该任务视为未完成:

  **(a) 更新对应规格文件 frontmatter**
  在 `docs/ai-tasks/CE-Mx-y.md` 文件顶部添加 / 修改 YAML frontmatter:

  ```yaml
  ---
  status: done
  commit: <commit-hash>
  ---
  ```

  如文件原本没有 frontmatter,在第一行 `# 标题` 之前插入。

  **(b) 更新 `docs/ai-development-plan.md` 对应任务卡**
  在 §4(M0)或 §5(M1)对应任务卡末尾追加一行:

  ```
  状态: 完成 (commit <hash>)
  ```

  位置在当前任务卡的"验收"段之后、下一个 `### CE-Mx-y` 之前。

  **(c) 更新本索引第 2 节表格的"状态"列**
  把 `未开始` 改为 `完成 (commit <hash>)`,hash 取 7 位短哈希。如该任务跨多个 commit,填最终落库的 merge / squash commit。

- 三处状态必须一致;如果不一致,以本索引第 2 节为权威来源,review 时优先修正其他两处。
- 部分完成 / 进行中状态写 `进行中 (commit <hash>, 待 <剩余项>)`,不要使用任何其他自定义状态值。
