# RustDesk 自托管栈向 Pro 对齐的升级方案

> 适用范围:`rustdesk-server`(hbbs + hbbr) 为主,辅以 `rustdesk-api`(lejianwen) 与 `rustdesk` 客户端的协同改造。
> 目标:在保持 AGPL-3.0 / 第三方生态完全开源的前提下,把"OSS 三件套"升级到与 [RustDesk Server Pro](https://rustdesk.com/docs/en/self-host/rustdesk-server-pro/) 大致对齐的能力线。
> 版本基线:rustdesk v1.4.8 / rustdesk-server v1.1.15 / rustdesk-api lejianwen 主分支(`DatabaseVersion=265`)。
> 编制日期:2026-06-27
> 工作模式:**就地修改当前工作目录下三个项目**(`/Volumes/MBA_1T/Code/远程控制/{rustdesk-server,rustdesk-api,rustdesk}/`),阶段完成后由用户推送到 fork 仓库(建议命名 `*-ce`)。

---

## 0. TL;DR(本次升级的决策摘要)

| 决策项 | 取向 |
|--------|------|
| 仓库 | **就地改三个项目**,M1 完成后用户上传到自建 fork(`rustdesk-server-ce` / `rustdesk-api-ce` / `rustdesk-ce`) |
| 协议演进 | `rustdesk` / `rustdesk-server` 的 `hbb_common` 切到自管 fork 分支;新字段一律 `optional`,客户端 `capabilities[]` 协商降级 |
| 策略下发 | proto 主通道(`ConfigUpdate.policy`)+ rustdesk-api `/_api/ws/policy` 辅通道 |
| RBAC | 双层:API 隐藏 + hbbs 在 `PunchHoleRequest` 带 token 反查 `/api/access/check`(Redis 1s TTL) |
| Client Builder | Phase 1 轻量(文件名 Configuration String,Windows portable EXE)+ Phase 3 真编译并存 |
| 时间 | M0(2w)→ M1(+3w)→ M2(+4w)→ M3(+6w)→ M4(+2w),共 ~17 周 |
| 验收 | 每 Milestone 结束跑 §1 矩阵回归,把对应行改 ✅ |

---

## 1. Pro 能力对照矩阵

下表把官方 Pro 顶层能力清单及 Web Console 子能力拆成 15 项,逐条映射到当前 OSS 栈的实现位置与完成度。
完成度划分:✅ 已实现 / 🟡 部分实现(需补齐)/ ❌ 缺失。

| # | Pro 能力 | 当前实现位置 | 状态 | 备注 / 主要差距 |
|---|---------|--------------|------|----------------|
| 1 | Account(账号体系) | rustdesk-api `model/user.go` + `service/user.go` + bcrypt | ✅ | 已支持用户/角色/邀请、密码 reset CLI。差距:账号生命周期事件无 webhook。 |
| 2 | Web Console(管理后台) | rustdesk-api `/_admin` SPA(`resources/admin`,基于 `lejianwen/rustdesk-api-web`) | ✅ | 已支持用户/设备/地址簿/审计/OAuth/LDAP 管理。差距:无策略下发与设备远程命令面板。 |
| 3 | API | rustdesk-api `/api/*` + Swagger | ✅ | 已兼容官方 Pro API。差距:OpenAPI 未与官方 spec 做兼容矩阵回归。 |
| 4 | OIDC | rustdesk-api `service/oauth.go`(go-oidc/v3)+ `APP_WEB_SSO` | ✅ | 已支持 Github / Google / Linuxdo / 通用 OIDC。 |
| 5 | LDAP | rustdesk-api `service/ldap.go` + `admin-group`/`allow-group` 映射 | ✅ | 兼容 AD `userAccountControl`,差距:未支持嵌套组与 SCIM 同步。 |
| 6 | 2FA(API/Web 账号 MFA) | rustdesk-api `model/user_mfa.go` + `service/mfa.go` + `/api/login-mfa`;后台强制位 `user.mfa_required` / `group.mfa_required` | ✅ | M1 已交付 TOTP + 备份码 + 强制 MFA;运维手册见 `docs/operations/2fa.md`。与被控端本机会话级 2FA(`auth_2fa.rs`)互不影响。 |
| 7 | Address Book(地址簿) | rustdesk-api `model/addressBook.go` + `tag.go` + `group.go` | ✅ | 个人地址簿、共享地址簿、标签、设备组齐备。 |
| 8 | Log Management(连接 / 文件 / 告警) | rustdesk-api `model/audit.go`(`AuditConn` / `AuditFile` / `AuditEvent`)+ `loginLog.go` + `/api/audit/{conn,file,event}` | ✅ | M1 在保留 `AuditConn` / `AuditFile` 的前提下新增统一 `AuditEvent`(剪贴板 / 告警 / 命令 / 录屏占位),后台 list 支持按 kind / 时间过滤;运维手册见 `docs/operations/audit-events.md`。录屏审计 GA 仍排期 M3。 |
| 9 | Device Management | rustdesk-api `model/peer.go` + serverCmd(`service/serverCmd.go`)| 🟡 | 设备列表/分组/封禁已就绪。差距:① 设备策略下发(开屏 PIN、自动接受等)未集成到客户端;② 离线设备远程唤醒/解绑。 |
| 10 | Security Settings Sync | hbbs `ConfigUpdate`(由 `ConfigureUpdate`/`serial` 触发)+ rustdesk-api `serverCmd` | 🟡 | 仅能下发"客户端连到哪台 hbbs/hbbr"的引导参数,**无法集中下发"密码复杂度、剪贴板/文件传输开关、白名单"等运行时策略**。 |
| 11 | Access Control(细粒度 RBAC) | rustdesk-api `BackendUserAuth + AdminPrivilege` + 地址簿共享权限 | 🟡 | 当前具备后台 admin/user 与地址簿读写控制。Pro 的 admin role / control role / strategy / 设备组访问矩阵仍未系统化实现。 |
| 12 | Multiple Relays(就近选择) | hbbs `-r relay1,relay2,...` + `check_relay_servers` round-robin | 🟡 | 多 relay 已可配置;**GeoIP 就近选择仍是 TODO**(`rendezvous_server.rs` 中 `_pa/_pb` 预留未实现)。 |
| 13 | Custom Client Generator | — | ❌ | 无服务端生成定制安装包能力。 |
| 14 | WebSocket | hbbs `:21118` / hbbr `:21119` | ✅ | 信令与中继的 WS 通道已就绪。差距:WS 路径不支持 `RegisterPeer`/`RegisterPk`,WS-only 客户端无法独立注册。 |
| 15 | Web Client Self-host | rustdesk-api `/webclient` + `/webclient2` | ✅ | 已托管。差距:依赖 `RUSTDESK_API_RUSTDESK_WEBCLIENT_MAGIC_QUERYONLINE` 走 hbbs fork(`lejianwen/rustdesk-server`),官方上游 hbbs 不暴露该接口。 |

**总结**:15 项中 ✅ 10 项 / 🟡 4 项 / ❌ 1 项。补齐 4 个 🟡 + 1 个 ❌ 是接下来的工作重心,其余只需做细节打磨。

---

## 2. 差距归类与责任分配

按"功能改在哪一层最合适"切分:

### A. 仅改 rustdesk-api(Go)即可
- **API/Web 账号 MFA(TOTP)**:复用 `service/user.go`,加 `model/userMfa.go`(secret+recovery_codes),登录流程增加二次验证步骤。
- **权限/策略建模**:在现有 `user`/`group`/`peer`/地址簿权限之上新增 `admin_role`、`control_role`、`access_policy`、`policy_bundle` 等模型,先完成管理面 CRUD 与 OpenAPI 兼容。
- **Audit 管理面扩展**:保留现有 `audit_conn` / `audit_file` 兼容表与接口,新增剪贴板、告警等事件类型或统一 `audit_event` 视图,补筛选与导出。

### B. 改 rustdesk-server(Rust / hbbs)
- **GeoIP 就近 Relay**:`rendezvous_server.rs::get_relay_server` 引入 `maxminddb`,读取管理员通过参数指定的 GeoLite2-City/商业库文件,以客户端公网 IP 计算与每台 relay 的距离/同区域优先,补齐 `_pa/_pb` 参数。
- **Security Settings Sync 通道**:扩展 `ConfigUpdate` 协议(`hbb_common/protos/rendezvous.proto`)新增 `policy` 字段,或新增独立 `PolicyUpdate` 消息,由 hbbs 在客户端心跳响应中下发。**注意:proto 变更需要在 rustdesk / rustdesk-server 两个 Rust 仓库的 hbb_common submodule 同步;rustdesk-api 只同步协议语义和 API DTO。**
- **WS 注册补全**:`handle_listener2` 把 `RegisterPeer`/`RegisterPk` 也接入 WS 分支,使 Web Client 与浏览器嵌入场景可独立完成注册。
- **RBAC 强制拦截**:hbbs 在 `PunchHoleRequest` 路径带客户端 token 反查 rustdesk-api `/api/access/check`,把 API 侧 access policy 真正落到信令层。
- **认证与运维加固**(详见 §5 安全篇):loopback 管理 CLI 改用 UDS + 文件权限;`tcp_punch` key 改 `(ip,port,peer_id)` 并加 TTL;PeerMap GC;PostgreSQL 后端。

### C. 改 rustdesk 客户端(Rust + Flutter)
- **API/Web 账号 MFA UI**:登录 rustdesk-api 的流程加入 TOTP 输入;短期 `mfa_ticket` 只放内存状态,不写入 `LocalConfig`。
- **策略接收与落地**:接 `PolicyUpdate`/扩展后的 `ConfigUpdate`,将"是否允许文件传输、是否允许剪贴板、是否强制弹屏 PIN"等开关持久化到 `PeerConfig` 与 `Connection::on_command` 链路。
- **审计上报扩充**:复用现有 `/api/audit/{conn,file}` 能力,在文件传输、剪贴板、告警(异常时长、被拒绝、IP 异常)等路径补齐上报。

### D. 新增独立服务 / 组件
- **Custom Client Generator**:在 rustdesk-api 增加 `/_admin/api/client-builder/*` 与后台异步任务队列,模板化生成 `rustdesk` 自定义 brand 的安装包。技术上有两个路径:
  1. **轻量方案**:生成 `RustDesk-<custom>.exe` 是 RustDesk 客户端的 [Configuration String](https://rustdesk.com/docs/en/self-host/client-configuration/) 重命名机制——把 server/key/api 编码进文件名后缀(如 `RustDesk-host=id.example.com,key=<base64>,api=https://api.example.com.exe`),客户端启动时识别。**开发量低,本期建议先做 Windows portable EXE 下载页**。
  2. **完整方案**:跑 GitHub Actions 风格的远程构建管线,产出 Win / macOS / Linux / Android 全平台定制包(改 `RUSTDESK_APPNAME`、icon、默认配置)。需要独立 builder worker + 对象存储。

---

## 3. 分阶段路线图

按"风险低 → 价值高 → 改动重"的顺序排,每阶段 2–4 周可交付。

### Phase 0:基础设施补齐(1–2 周)
> 不直接对标 Pro 功能,但为后续所有阶段铺路。

| 项 | 改动点 | 验证 |
|----|--------|------|
| hbb_common submodule 治理 | `rustdesk-server` 与 `rustdesk` 都用 fork 后的 hbb_common,集中管理 proto 演进;rustdesk-api 只跟随协议语义 | `git submodule status` 两个 Rust 仓库一致,API DTO/Swagger 对齐 |
| PostgreSQL 启用 | hbbs `database.rs` 增加 `Postgres` 后端(目前注释占位);连接池阈值从 1 → 32 | 高并发注册压测 ≥ 500 QPS |
| 可观测性 | hbbs/hbbr 嵌入 `axum-prometheus`,通过显式 `--metrics-bind` 暴露独立 loopback 端口(避免占用 21114);rustdesk-api 接入 OpenTelemetry traces | Grafana 看到 in-flight peers / relay bps |
| systemd 加固 | `User=rustdesk` + `ProtectSystem=strict` + `NoNewPrivileges=true` | `systemd-analyze security` 评级 OK |

### Phase 1:Pro 等价补齐 - 容易项(3 周)
| 序号 | 目标 | 落地 |
|----|------|------|
| 1.1 | **API/Web 账号 TOTP MFA** | rustdesk-api 增 `userMfa` 表 + `pquerna/otp` 库;`/api/login` 状态机:用户名密码 → `mfa_required: true` → `/api/login-mfa`;后台支持强制 group 开启;备份码 10 个一次性 |
| 1.2 | **审计事件扩展** | 保留 `audit_conn` / `audit_file`;补剪贴板/告警事件或统一 `audit_event` 视图;客户端各事件钩子补 `audit_event!`;Admin 增加事件类型过滤 |
| 1.3 | **WS 路径补齐 Register** | `rendezvous_server.rs::handle_listener2` 中分发逻辑增加 `RegisterPeer`/`RegisterPk` 处理 |
| 1.4 | **Custom Client Generator(轻量)** | rustdesk-api 增 `client-builder`:接受参数 → 生成 `RustDesk-<hash>.exe`(复用上游 release artifact + 重命名);后台展示二维码下载 |

### Phase 2:Pro 等价补齐 - 中等项(4 周)
| 序号 | 目标 | 落地 |
|----|------|------|
| 2.1 | **细粒度访问控制(RBAC v2)** | 新增 `access_policy` 表(`subject_kind`/`subject_id`/`object_kind`/`object_id`/`actions`/`time_window`);`MUST_LOGIN=Y` 的 hbbs 带客户端 token 反查 `/api/access/check`(user + from_peer + to_peer + action);返回 deny 时 hbbs 走 `PunchHoleResponse::failure_reason=POLICY_DENY` |
| 2.2 | **Security Settings Sync** | proto 加 `PolicyUpdate { allow_file_transfer, allow_clipboard, allow_audio, force_unattended_password, min_password_len }`;hbbs 维护 per-tenant 策略缓存,从 rustdesk-api `GET /api/policy/effective?user=` 拉取;客户端落地到 `PeerConfig::policy` |
| 2.3 | **GeoIP 就近 Relay** | hbbs 启动时按 `-g /etc/rustdesk/GeoLite2-City.mmdb` 加载管理员自带 MaxMind DB;`get_relay_server(from_ip, relay_list)` 计算距离/同 country 优先;客户端 `_pa`/`_pb` 参数填客户端探测到的两次 RTT 作为辅助 |
| 2.4 | **设备策略下发面板** | rustdesk-api 后台增"策略包"(类似 group policy):勾选项 → 推送到设备组 → 客户端心跳应答带 `serial` 触发拉取 |

### Phase 3:Pro 等价补齐 - 重量项(6 周+)
| 序号 | 目标 | 落地 |
|----|------|------|
| 3.1 | **告警系统(Alarm)** | 异常登录(地理跳跃 / 短时多 IP)、暴力破解、relay 流量异常 → rustdesk-api `model/alarm.go` + 邮件 / Webhook / 飞书 / 企业微信 通知;前端"告警中心"卡片 |
| 3.2 | **Custom Client Builder 完整版** | 独立 builder 服务(可放 rustdesk-api 同进程的 goroutine 队列,或独立 Go 微服务);拉取上游 rustdesk 源码 → 注入品牌 + 默认配置 → cross-compile;产物入对象存储,后台轮询任务状态 |
| 3.3 | **多 hbbs 集群一致性** | 用 Redis 把 `PeerMap`/`IP_BLOCKER`/`PUNCH_REQS` 抽到共享层(可选 hashmap → Redis 一层适配);多 region hbbs 通过 Redis Stream 同步设备上线事件 |
| 3.4 | **录屏审计(高合规场景)** | 在客户端 `--server` 端可选开启 H.264 落盘 → 加密上传到对象存储;后台支持时间戳检索 |

---

## 4. 已确定的架构决策

以下 5 个分叉点已拍板,后续 PR 直接按此实施,不再讨论:

### A. 仓库策略:**就地修改,后续作为 fork 上传**
- 在当前工作目录 `/Volumes/MBA_1T/Code/远程控制/` 下的 `rustdesk-server/`、`rustdesk-api/`、`rustdesk/` 三个项目内**直接修改源码**。
- `rustdesk-server` 与 `rustdesk` 的 `hbb_common` 当前 pin 不同(`rustdesk-server=83419b6`,`rustdesk=a920d00`),先在自管 fork 分支(`hbb_common-ce`)对齐到同一基线,再做 proto 演进。rustdesk-api 没有 `hbb_common` submodule,只同步 API DTO / OpenAPI 语义。
- 待 M1 完成后,由用户统一把三个项目推送到指定的 fork 仓库(命名建议:`rustdesk-server-ce` / `rustdesk-api-ce` / `rustdesk-ce`)。
- 期间所有改动以 git commit 划分子任务,每个 Phase 一个 feature branch,便于后续向上游 rebase 或单独提 PR。

### B. 策略下发通道:**proto 主通道 + API WS 辅通道**
- **主通道(proto 扩展)**:在 `RegisterPeerResponse` 与 `ConfigUpdate` 中追加 `optional PolicyDigest policy = N;`,字段使用 `optional + 默认值 = 老行为`,老客户端无视新字段不会报错。客户端心跳应答即可拿到生效策略摘要,断网重连后自动同步,**零额外连接**。
- **辅通道(rustdesk-api WS)**:新增 `/_api/ws/policy` 推送完整 JSON 策略包(例:剪贴板白名单、文件传输大小上限、按时段访问规则等复杂结构),协议演进不锁 proto。若 M2 前不引入 WS,先用 long-poll/SSE 作为兼容实现。
- 客户端通过 `/api/version` 报告的 `capabilities[]` 决定降级路径——老客户端只用主通道,新客户端两条都接。

### C. RBAC 校验:**双层强制(API 隐藏 + hbbs 拦截)**
- **第一层(API 隐藏)**:客户端 `GET /api/peers` / `GET /api/ab/*` 时,API Server 按当前用户的策略过滤,**不可见的设备根本不出现在地址簿里**。
- **第二层(hbbs 强制)**:hbbs 在 `PunchHoleRequest` 路径上带客户端 token 反向调用 `POST /api/access/check {from_peer,to_peer,action}`,API 以 token 解析出的 user 为准并命中 Redis(`access:<user>:<from>:<to>:<action>` TTL 1s),拒绝时返回 `PunchHoleResponse.failure_reason = POLICY_DENY`。
- 这样既挡住"用户改本地配置绕过 UI"的场景,也把 Redis 缓存控制在亚毫秒级延迟内。Pro 的实现也是这个双层结构。

### D. Custom Client Generator:**Phase 1 走轻量,Phase 3 上真编译,两者共存**
- **Phase 1 轻量版**:基于 RustDesk 已经支持的 [Configuration String](https://rustdesk.com/docs/en/self-host/client-configuration/) 文件名约定 `RustDesk-host=<server>,key=<base64>,api=<url>.exe`,服务端把 `id-server` / `relay-server` / `key` / `api-server` 编码到文件名,客户端启动时自动识别。后台先做"Windows portable EXE 下载页 + 二维码 + 上游 artifact 校验"。
- **Phase 3 完整版**:跑独立 builder worker,源码注入 `RUSTDESK_APPNAME` / icon / 默认 PeerConfig,cross-compile 出 Win / macOS / Linux / Android 真品牌包,产物入对象存储。
- 后台 UI 让管理员在生成时选"快速链接(轻量)"或"定制安装包(完整)",二者并存。

### E. 协议兼容策略:**新字段全部 optional,客户端 capabilities 协商降级**
- `hbb_common/protos/*.proto` 内所有新增字段一律 `optional` + 老行为默认值,保证老客户端 / 老服务端解析时静默忽略不报错。
- rustdesk-api 在 `/api/version` 响应中加 `capabilities: ["mfa", "policy_v2", "rbac_v2", "geoip_relay", "client_builder"]`;客户端按命中能力做 UI 与流程降级。
- hbbs 在 `RegisterPeerResponse` 中带 `server_capabilities`;客户端据此决定走主通道还是辅通道。
- 任何破坏性 proto 变更必须 bump `hbb_common` 大版本号,并在两个 Rust 仓库的 CI 中各跑一次"老客户端 ↔ 新服务端"与"新客户端 ↔ 老服务端"的握手回归;rustdesk-api 侧跑 OpenAPI/DTO 兼容回归。

---

## 5. 安全与运维并行加固(贯穿全程)

这些项与 Pro 功能无直接对照,但 Pro 默认提供,**OSS 不补齐会显得"专业度不够"**:

| 类别 | 项 | 来源 |
|------|------|------|
| 认证 | hbbs/hbbr loopback 管理 CLI → UDS + token | `rustdesk-server.md` §安全 #1 |
| 认证 | hbbr `RequestRelay` 引入 hbbs 颁发的短期 HMAC token | 同上 #2 |
| 密钥 | `id_ed25519` 强制 `0400`;不允许通过 env 注入私钥 | 同上 #3 |
| 网络 | WS 代理可信 CIDR 白名单(`X-Real-IP` 校验) | 同上 #5 |
| 并发 | `tcp_punch` HashMap key 改 `(ip,port,peer_id)` + TTL | 同上 #6 |
| 资源 | hbbr 加 `max-concurrent-sessions` 与 `max-sessions-per-ip` | 同上 #12 |
| 数据 | PeerMap 后台 GC(60s 扫一次 `last_reg_time > 3600s`) | 同上 #8 |
| CI | 加 `cargo test` 与 fuzz target(protobuf parsing) | 同上 #16 |

---

## 6. 里程碑与交付物

| 里程碑 | 完成标志 | 预计周期(累计) | 用户验收方式 |
|--------|----------|------------------|--------------|
| **M0 基础设施** | PostgreSQL 后端、`/metrics` 端点、systemd 加固、hbb_common fork 接入两个 Rust 仓库 | T0 + 2 周 | `docker-compose up` 后 hbbs/hbbr 独立 metrics 端口有数据;`systemd-analyze security` 评级 ≥ OK |
| └─ CE-M0-1 状态 | ✅ 完成 (2026-06-29):fork `https://github.com/estel-li/hbb_common-ce` 已接入两个 Rust 仓库,统一 pin = `a920d00945e1d2441b3f77b2677054cb8c3d9dd2`(=`ce/base` HEAD = `ce-base-v0` tag);estel 的格式化补丁 `2c6c129` 保留在 fork 的 `ce/feat-rustdesk-server-fmt` 分支但**不入** `ce/base`。 | — | 见 `docs/ai-tasks/CE-M0-1.md` §11 完成记录 |
| **M1 容易项** | API/Web 账号 MFA + 审计扩展 + WS 注册补齐 + 轻量 client builder 全部 GA | T0 + 5 周 | 后台开启 MFA → 客户端/API 登录提示输入 TOTP;后台审计页能看到文件/剪贴板事件;下载页生成的链接客户端打开即配好 server |
| **M2 中等项** | RBAC v2 + Security Settings Sync + GeoIP Relay 全部 GA | T0 + 9 周 | 后台限制 userA 不能连 peerB → 客户端地址簿不可见且 punch 被拒;策略包推送后客户端的"禁止文件传输"开关立即变灰;多 relay 部署后控制端日志显示就近 relay |
| **M3 重量项** | Alarm + 完整 client builder + 多 hbbs 集群(选做) | T0 + 15 周 | 模拟暴力破解 → 后台告警卡片 + 邮件;后台生成 macOS .dmg 真品牌包;两台 hbbs 后 PeerMap 共享 |
| **M4 收口** | OpenAPI 兼容矩阵回归、`docs/upgrade-plan.md` 状态全绿、一键升级脚本 | T0 + 17 周 | 跑 `scripts/oss-to-ce-migrate.sh` 把现有部署平滑切换到 CE 版本 |

每完成一个里程碑,回到本文档 §1 矩阵把对应行从 🟡/❌ 改为 ✅,作为客观进度证据。

---

## 7. Sprint 级执行清单(M0 + M1,需立即执行)

按用户确认"就地修改,后续上传"的约定,T0 起执行以下顺序。每一项对应一个 git commit,提交信息前缀 `[CE-Mx]`。

### Sprint 0(week 1–2,M0)
- [ ] **CE-M0-1** 初始化 hbb_common fork:`rustdesk-server` 与 `rustdesk` 两个 submodule URL 切到 `hbb_common-ce`,记录当前 pin(`83419b6`/`a920d00`)并先对齐到同一 zero-change 基线。
- [ ] **CE-M0-2** rustdesk-server:`src/database.rs` 抽象 `DbBackend` trait,实装 `PostgresBackend`(sqlx::postgres),`MAX_DATABASE_CONNECTIONS` 默认提到 32。
- [ ] **CE-M0-3** rustdesk-server:`Cargo.toml` 加 `axum-prometheus = "0.4"`,hbbs/hbbr 通过 `--metrics-bind 127.0.0.1:<port>` 挂 `/metrics`;hbbr 同步增 `bytes_in/out/sessions`。
- [ ] **CE-M0-4** rustdesk-api:`config/redis.go` 增加 healthcheck 与显式启用校验,`/metrics` 用 `gin-contrib/prometheus`。
- [ ] **CE-M0-5** rustdesk-server:`systemd/rustdesk-hbbs.service` / `hbbr.service` 加 `User=rustdesk` + `ProtectSystem=strict` + `NoNewPrivileges=true` + `ReadWritePaths=/var/lib/rustdesk-server`;`postinst` 创建用户。
- [ ] **CE-M0-6** rustdesk-server:`src/peer.rs` PeerMap 后台 GC(`tokio::spawn` 每 60s 扫一遍,踢除 `last_reg_time > 3600s`),并改 `tcp_punch` HashMap key 为 `(IpAddr, u16, String)` 三元组。
- [ ] **CE-M0-7** rustdesk-server:loopback 管理 CLI 改为 UDS `/run/rustdesk/{hbbs,hbbr}.sock` + 文件权限 0660 + 启动时打印 token 到 stderr。

### Sprint 1(week 3,M1 #1.1 API/Web 账号 TOTP MFA)
- [ ] **CE-M1-1** rustdesk-api:`model/user_mfa.go`(`user_id` / `secret` / `recovery_codes` JSON / `enabled_at`);AutoMigrate bump `DatabaseVersion=266`。
- [ ] **CE-M1-2** rustdesk-api:`service/mfa.go` 引入 `github.com/pquerna/otp/totp`;接口:`Enroll(userId) → (secret, qrPNG)`、`Verify(userId, code) → bool`、`GenRecoveryCodes()`、`ConsumeRecoveryCode()`。
- [ ] **CE-M1-3** rustdesk-api:`/api/login` 状态机改为两步——首步成功后若用户启用 MFA 则返回 `{mfa_required:true, ticket:<short_jwt>}`,客户端再调 `/api/login-mfa {ticket, code}`。
- [ ] **CE-M1-4** rustdesk:API 登录页加 TOTP 输入框,`mfa_ticket` 仅放内存临时状态,不写 `LocalConfig`。
- [ ] **CE-M1-5** rustdesk-api 后台:用户管理页加"强制 MFA"勾选(组级)。

### Sprint 2(week 4,M1 #1.2 + #1.3 + #1.4)
- [ ] **CE-M1-6** rustdesk-api:保留现有 `AuditConn`/`AuditFile`;新增剪贴板/告警事件模型或统一 `AuditEvent` 视图,后端 list 接口加事件类型过滤。
- [ ] **CE-M1-7** rustdesk:`src/server/connection.rs` 各事件钩子补 `audit_event!(kind, payload)`;文件传输复用现有 `/api/audit/file`,剪贴板按新事件端点/视图上报。
- [ ] **CE-M1-8** rustdesk-server:`rendezvous_server.rs::handle_listener2` 把 WS 分支接入 `handle_msg` 的 `RegisterPeer`/`RegisterPk` 处理(目前直接 return `NOT_SUPPORT`)。
- [ ] **CE-M1-9** rustdesk-api:`http/controller/admin/client_builder.go`(轻量版):后台填写 server/key/api → 生成 `RustDesk-host=<server>,key=<base64>,api=<url>.exe` 下载链接 + 二维码 + 复制按钮。
- [x] **CE-M1-10** 文档:本文档 §1 矩阵把已完成项打勾,新增 `docs/operations/2fa.md`、`docs/operations/audit-events.md` 两份运维手册。

### Sprint 3+(M2、M3)
后续 Sprint 在 M1 收尾、用户验收通过后再细化任务卡。

---

## 8. 涉及到的文件改动一览(供 PR 拆分参考)

```
rustdesk-server/(fork)
├── libs/hbb_common/protos/rendezvous.proto       # PolicyUpdate, RequestRelay token, _pa/_pb
├── src/rendezvous_server.rs                       # WS Register、GeoIP relay、UDS 管理 CLI
├── src/relay_server.rs                            # HMAC token 校验、并发上限
├── src/database.rs                                # Postgres backend
├── src/peer.rs                                    # 后台 GC、(ip,port,peer_id) key
└── docker/, systemd/, k8s/                        # 用户隔离、健康探针

rustdesk-api/
├── model/{userMfa,accessPolicy,alarm,policyBundle,auditEvent}.go
├── service/{mfa,access,policy,alarm,clientBuilder}.go
├── http/controller/api/{loginMfa,policy}.go
├── http/controller/admin/{policy,builder,alarm}.go
└── conf/config.yaml.tpl                           # 新配置段

rustdesk/(客户端)
├── libs/hbb_common(同步 submodule)
├── src/server/connection.rs                       # audit kind 扩展、policy 落地
├── src/client.rs / src/ipc.rs                     # API MFA 字段、Configuration String 解析
└── flutter/lib/...                                # API MFA UI + 策略只读展示
```

---

## 9. 风险登记

| 风险 | 触发条件 | 缓解 |
|------|----------|------|
| proto 改动锁版本 | 两个 Rust 仓库同步不及时 | hbb_common 走 fork;rustdesk-api 以 DTO/OpenAPI 对齐语义 |
| Pro 协议兼容回退 | 上游 rustdesk-api 同名字段语义改变 | OpenAPI 对照测试集纳入 CI |
| GeoIP 库授权 | MaxMind 商业条款 | 不随项目默认分发 GeoLite2;仅提供 `-g` 自带文件路径、下载/更新/attribution 文档 |
| 多 hbbs 一致性 | Redis 主从切换抖动 | 失败时降级到本地 PeerMap,只丢就近优化能力 |
| 客户端升级滞后 | 老客户端不识别新策略 | 服务端按客户端 `version` 字段做 capability degrade |

---

> 编制说明:本方案在不引入私有协议、不破坏与官方客户端兼容性的前提下,把"OSS 三件套"逐步推进到与 Pro 大致对齐。所有改动都建议在 fork 仓库内演进,定期向上游 rebase。完成 M2 即可对外宣称"等价 Pro 主要能力";M3 收尾后,三件套已具备替代 Pro 在中型企业(<2000 设备)场景的能力。
