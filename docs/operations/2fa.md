# API/Web 账号 MFA 运维手册 (CE-M1-10)

> 任务卡:CE-M1-10(`../ai-tasks/CE-M1-10.md`),依赖 CE-M1-1..5 的实现。
> 适用范围:`rustdesk-api`(本仓库 `rustdesk-api/` 子目录)签发的账号登录态,即
> "API + Web 后台 + Flutter 客户端 API 登录" 这一通道。
> 默认:**关闭**(`mfa.enabled=false`)。仅当管理员显式打开后,新登录请求才进入两步流程。

本手册与 `./audit-events.md` 共同构成 M1 阶段"安全闭环"——MFA 关心"谁能登录",
审计事件关心"登录后做了什么"。

## 1. 概述

CE-M1 阶段为 rustdesk-api 增加了**账号级 MFA**:

- 基于 TOTP(RFC 6238)+ 一次性恢复码,落库表 `user_mfa`(CE-M1-1)。
- 登录流程从一步改为两步:`/api/login` 拿短期 ticket,`/api/login-mfa` 拿真正的 `access_token`(CE-M1-3)。
- Flutter 客户端的 API 登录对话框新增 TOTP 输入页;`mfa_ticket` 仅在内存(CE-M1-4)。
- 后台增加"强制 MFA"开关(用户级 / 组级,二者 OR;CE-M1-5)。

**与客户端会话级 2FA 完全无关**:被控端会话级 TOTP 实现位于客户端 `auth_2fa` 模块(本文档刻意
不写出该文件全名,以免误导运维去改客户端 Rust 代码);本手册涉及的 MFA 只走 HTTP API,
不会影响被控端会话握手。

### 兼容性铁律(与 `../ai-development-plan.md` §1.1 一致)

1. **proto 不破坏向后兼容**:`/api/login` 新增的 `mfa_required` / `ticket` 字段均为 optional,
   旧客户端解析失败时按"未启用 MFA"处理,登录被拒只会出现在"用户已强制 MFA 但客户端未升级"场景。
2. **数据库迁移单向递增**:CE-M1-1 把 `DatabaseVersion` 从 265 抬到 266;CE-M1-5 进一步到 267(用户/组级强制位)。
   **不要手动改 `DatabaseVersion`**,除非按 §回滚 走灾难恢复流程。
3. **新增端点不删旧端点**:`/api/login` 在 MFA 关闭时保持原响应形状;`/api/login-mfa` 是新增端点。

## 2. 前置阅读

撰写本手册前必须串读以下任务卡 / 代码入口,运维同学若打算改任何字段命名也请按这个顺序核对:

- 任务卡
  - `../ai-development-plan.md#ce-m1-1-数据模型user_mfa` — `user_mfa` 表结构、字段语义。
  - `../ai-development-plan.md#ce-m1-2-mfa-service` — TOTP/恢复码生成、消费、限流接口。
  - `../ai-development-plan.md#ce-m1-3-两步登录状态机` — `/api/login` → `/api/login-mfa` 状态流转。
  - `../ai-development-plan.md#ce-m1-4-客户端-api-mfa-ui` — 客户端登录对话框、`mfa_ticket` 不落盘。
  - `../ai-development-plan.md#ce-m1-5-后台强制-mfa` — 用户级 / 组级强制位 + enroll-then-verify。
- 上游文档
  - `../architecture.md#23-鉴权链路` — token / API 鉴权全链路。
  - `../rustdesk-api.md` 鉴权章节 — API token / JWT / OIDC / LDAP 现状。
- 源码入口(实现以代码为准,若字段名与本文档不一致,**改本文档**而不是改代码)
  - `rustdesk-api/model/user_mfa.go`
  - `rustdesk-api/service/mfa.go`、`service/mfa_ticket.go`
  - `rustdesk-api/http/controller/api/login.go`
  - `rustdesk-api/http/controller/admin/user.go`(强制位 toggle)

衔接:本手册"启用流程"步骤 7 提到的"审计页",对应配置与查询入口见 `./audit-events.md`。

## 3. 配置项

> 以下 yaml key 沿用 `RUSTDESK_API_<段>_<键>` 命名模式(`../rustdesk-api.md` §配置文件)。
> 一旦 CE-M1-3 / M1-5 的实现在合并时调整了 key 名,以代码为准并回填本表。**建议命名,可调整**。

| yaml key | env var | 默认值 | 说明 |
|----------|---------|--------|------|
| `mfa.enabled` | `RUSTDESK_API_MFA_ENABLED` | `false` | 全局开关。关闭时 `/api/login-mfa` 直接返回 503(配置项关闭),前端仍可走旧 `/api/login` |
| `mfa.issuer` | `RUSTDESK_API_MFA_ISSUER` | `RustDesk` | TOTP `otpauth://` URI 中的 issuer 字段,显示在 Google Authenticator / 1Password 等 app 内 |
| `mfa.ticket-ttl` | `RUSTDESK_API_MFA_TICKET_TTL` | `5m` | `/api/login` 返回的短期 ticket 有效期。范围 3–5 分钟(`../ai-development-plan.md` §CE-M1-3) |
| `mfa.recovery-code-count` | `RUSTDESK_API_MFA_RECOVERY_CODE_COUNT` | `10` | 用户首次 enroll 时一次性签发的备份码数量 |
| `mfa.force-group` | `RUSTDESK_API_MFA_FORCE_GROUP` | `""` | 强制启用 MFA 的组名;留空表示不强制(也可在后台逐组勾选 `group.mfa_required`) |
| `mfa.force-enroll-on-required` | `RUSTDESK_API_MFA_FORCE_ENROLL_ON_REQUIRED` | `true` | `true`:命中强制但未 enroll 时下发 enroll-purpose ticket,允许当场扫码;`false`:直接拒绝登录 |
| `mfa.login-mfa-max-attempts` | `RUSTDESK_API_MFA_LOGIN_MFA_MAX_ATTEMPTS` | `5` | 同一 ticket 上 `/api/login-mfa` 失败上限;到顶立即作废 ticket,要求重发 `/api/login` |
| `app.captcha-threshold` | `RUSTDESK_API_APP_CAPTCHA_THRESHOLD` | `3` | 已存在限流。MFA 错误**复用**该计数:连续错误 N 次后触发验证码 |
| `app.ban-threshold` | `RUSTDESK_API_APP_BAN_THRESHOLD` | `0`(关闭) | 触顶后封禁源 IP;同样适用于 MFA 错误,与密码错误共享计数 |

`config.yaml` 片段示例:

```yaml
mfa:
  enabled: true
  issuer: "RustDesk-CE"
  ticket-ttl: "5m"
  recovery-code-count: 10
  force-group: ""
  force-enroll-on-required: true
  login-mfa-max-attempts: 5
app:
  captcha-threshold: 3
  ban-threshold: 10
```

**安全约束**:

- `mfa_ticket` **仅放内存**(签名 + TTL),不得写入 `LocalConfig` / `SharedPreferences` /
  `RustDesk.toml` 任何持久化载体。
- 恢复码只存 hash(bcrypt);**手册严禁出现真实 secret / recovery code 示例**,所有示例
  均用 `<base32-secret>` / `<recovery-code>` 占位。
- TOTP secret 在 enroll 响应中**只返回一次**,后续仅返回二维码占位或 `null`。

## 4. 启用流程

> 适用前提:`rustdesk-api` 已升级到含 CE-M1-1..5 的版本,数据库已自动迁移到 `DatabaseVersion=267`。

1. **管理员后台开启全局 `mfa.enabled`**

   编辑 `conf/config.yaml`(或注入对应 env var)后重启 `apimain`:

   ```bash
   # docker-compose 场景示例
   echo 'RUSTDESK_API_MFA_ENABLED=true' >> .env
   docker compose restart rustdesk-api
   ```

   启动日志应出现 `mfa: enabled, issuer=RustDesk-CE`。

2. **用户进入"账号设置 → MFA",扫码绑定**

   - 浏览器登录 `_admin` 后台,进入 "My Account → MFA"。
   - 后端调用 `POST /api/mfa/enroll` 返回 `{secret, qr_png_base64, otpauth_url}`,前端渲染二维码。
   - 用户用任意 TOTP 客户端(Google Authenticator / 1Password / Authy / Bitwarden)扫码。

3. **系统下发恢复码(只下发一次)**

   `POST /api/mfa/verify` 通过后,响应里附带 `recovery_codes: [...]`,**仅本次返回**。
   提示用户离线保存(打印或保存到密码管理器);后端只存 bcrypt 哈希。

4. **用户下次登录拿到 `mfa_required`**

   下次 `POST /api/login` 用户名 / 密码正确后,响应不再直接返回 `access_token`,而是返回:

   ```json
   {
     "type": "tfa_check",
     "mfa_required": true,
     "ticket": "<short_jwt>",
     "mfa_methods": ["totp", "recovery_code"]
   }
   ```

5. **客户端 `/api/login-mfa` 提交 TOTP 拿 token**

   - 客户端 Dart `LoginRequest` 持有 `ticket` 于内存,提交 `{ticket, code}`。
   - 失败:`401 mfa_invalid_code` → 客户端清空输入框,提示重试,**不要**重新 `/api/login`。
   - 成功:返回与旧 `/api/login` 完全相同形状的 `{access_token, user}`。

6. **(可选)组管理员配置 `force-group` / 用户级强制位**

   - 修改 yaml `mfa.force-group: "secops"`,或在后台用户/组列表勾选 `mfa_required`。
   - 命中强制但未 enroll 的用户在第 4 步会拿到 `enroll_required: true` + enroll-purpose ticket,
     再调 `POST /api/mfa/enroll-then-verify` 当场扫码 + 校验。

7. **审计页确认事件已写入**

   登录页 `_admin → 审计 → 登录日志` 应出现 `mfa.enable` / `mfa.consume_recovery` / `mfa_enroll_forced`
   等条目;事件 schema 见 `./audit-events.md` §事件类型与契约。

## 5. API 示例

> 端口默认 `21114`,默认监听 `0.0.0.0:21114`(`../rustdesk-api.md` §配置文件 `gin.api-addr`)。
> 所有示例均省略 `-H 'Accept: application/json'`;Bearer 鉴权使用占位符。

### 5.1 enroll(首次绑定,登录态)

```bash
curl -s -X POST http://127.0.0.1:21114/api/mfa/enroll \
  -H 'Authorization: Bearer <access_token>'
```

预期响应(示例 secret / qr 均为占位符,**不要**抄入文档或测试夹具):

```json
{
  "secret": "<base32-secret>",
  "qr_png_base64": "<base64>",
  "otpauth_url": "otpauth://totp/RustDesk-CE:alice?secret=<base32-secret>&issuer=RustDesk-CE"
}
```

### 5.2 verify(完成 enroll)

```bash
curl -s -X POST http://127.0.0.1:21114/api/mfa/verify \
  -H 'Authorization: Bearer <access_token>' \
  -H 'Content-Type: application/json' \
  -d '{"code": "<6-digit-totp>"}'
```

预期:`{"ok": true, "recovery_codes": ["<recovery-code>", ...]}`。
**只本次返回**,前端必须强提示用户保存。

### 5.3 login(MFA 关闭用户,行为不变)

```bash
curl -s -X POST http://127.0.0.1:21114/api/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"alice","password":"<password>"}'
```

```json
{ "type": "access_token", "access_token": "<jwt>", "user": { "id": 1, "name": "alice" } }
```

### 5.4 login + login-mfa(MFA 已启用)

```bash
# 第一步:用户名 / 密码
curl -s -X POST http://127.0.0.1:21114/api/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"alice","password":"<password>"}'
# 响应:
# { "type":"tfa_check", "mfa_required":true,
#   "ticket":"<short_jwt>", "mfa_methods":["totp","recovery_code"] }

# 第二步:提交 TOTP
curl -s -X POST http://127.0.0.1:21114/api/login-mfa \
  -H 'Content-Type: application/json' \
  -d '{"ticket":"<short_jwt>","code":"<6-digit-totp>","method":"totp"}'
# 响应:
# { "type":"access_token", "access_token":"<jwt>", "user":{...} }
```

### 5.5 使用恢复码登录

```bash
curl -s -X POST http://127.0.0.1:21114/api/login-mfa \
  -H 'Content-Type: application/json' \
  -d '{"ticket":"<short_jwt>","code":"<recovery-code>","method":"recovery_code"}'
```

成功后服务端把该 hash 标记为已消费(`user_mfa.recovery_codes` JSON 数组里对应项落 `used_at`),
**不会**重新签发新恢复码。备份码用尽需要管理员或用户自助 regenerate(见故障 §6 备份码用尽)。

## 6. 常见故障

| # | 现象 | 排查 | 修复 |
|---|------|------|------|
| 1 | 客户端报 `Ticket expired` | `/api/login-mfa` 在 `ticket-ttl` 之后才发出,或客户端等用户输入过久 | 重新发起 `/api/login`,在 ≤5 分钟内完成 TOTP 输入 |
| 2 | TOTP 反复 invalid,但 secret 已正确扫码 | 服务端 / 客户端时钟漂移超过 ±30s | NTP 同步 `apimain` 与 TOTP app 设备;`mfa.go` 默认允许 ±1 窗口 = 60s |
| 3 | 备份码用尽 | `user_mfa.recovery_codes` 全部 `used_at != NULL` | 用户登录后调 `POST /api/mfa/recovery-code/regenerate`(或后台代签);旧码全部失效 |
| 4 | 升级后旧客户端登录失败 | 老客户端不识别 `mfa_required` 字段,把 `tfa_check` 响应当作 `access_token` 解析 | 用户先在后台关闭自己的 MFA → 升级客户端 → 重新 enroll;**不要**绕过两步流程 |
| 5 | 强制 MFA 用户未 enroll 被拒 (`MfaEnrollRequired`) | `mfa.force-enroll-on-required=false` 且用户没绑定 | 管理员临时把开关切回 `true`,引导用户当场 enroll;或调用 `POST /api/admin/user/mfa/disable` 解除该用户强制位(审计留痕) |
| 6 | `/api/login-mfa` 返回 `mfa_rate_limited` | `app.captcha-threshold` / `login-mfa-max-attempts` 触顶 | 等到 captcha 窗口 / 解 ban;运维查 `login_logs.type='mfa_invalid_code'` 看是否被打 |
| 7 | Web 后台显示 "MFA 未启用",但 `mfa.enabled=true` | env 写入了 `false` 字符串或没重启 | `docker compose exec rustdesk-api env | grep MFA`,确认全局开关;重启服务 |
| 8 | OIDC / LDAP 用户绕过了 MFA | 设计上 OIDC / LDAP 走外部 IdP 的 MFA;**本特性仅覆盖本地账号** | 文档/培训说明清楚;若 IdP 自身不具备 MFA,关闭对应 provider |

排查命令清单:

```bash
# 查询某账号的 MFA 绑定状态
docker compose exec rustdesk-api sqlite3 /data/rustdesk.db \
  "SELECT user_id, enabled_at FROM user_mfa WHERE user_id = (SELECT id FROM users WHERE name='alice');"

# 查询某账号最近的 MFA 相关审计
docker compose exec rustdesk-api sqlite3 /data/rustdesk.db \
  "SELECT created_at, type, client FROM login_logs WHERE user_id=<id> ORDER BY id DESC LIMIT 20;"
```

## 7. 回滚

### 7.1 软回滚(推荐)

- **临时关 MFA**:`mfa.enabled=false` 重启服务,新登录请求即回到一步流程。已 enroll 的 `user_mfa`
  行保留,后续重新开启即可继续生效。**对老客户端透明**。
- **解除单个用户强制**:
  ```bash
  curl -s -X POST http://127.0.0.1:21114/api/admin/user/mfa/disable \
    -H 'Authorization: Bearer <admin_token>' \
    -H 'Content-Type: application/json' \
    -d '{"user_id":42,"reason":"emergency rollback"}'
  ```
  该调用必留 `mfa_disabled_by_admin` 审计;**禁止 admin 关闭自己**。
- **批量取消组强制位**:后台用户管理页或 `POST /api/admin/group/mfa/required` 批量关闭。

### 7.2 硬回滚(仅灾难恢复)

仅当需要回滚到 CE-M1-1 之前的二进制版本时执行,**不要**在 prod 例行操作:

1. 暂停 `apimain` 进程。
2. 备份当前数据库(`rustdesk.db` 或对应 MySQL / PostgreSQL dump)。
3. 用上一版本二进制启动;新版本写入的 `user_mfa` / `mfa_required` 列对旧二进制无影响(GORM 忽略多余列)。
4. **仅在 dev / staging**:手动 `DROP TABLE user_mfa;` 并把 `cmd/apimain.go:DatabaseVersion` 改回 265,
   PostgreSQL 还需 `ALTER TABLE users DROP COLUMN mfa_required;` 等。生产环境**禁止**手动改 `DatabaseVersion`。

### 7.3 特性开关纪要

- `mfa.enabled=false` 是 MFA 通道的总开关,可灰度。
- `mfa.force-group=""` + 所有用户 `user_mfa.enabled_at IS NULL` 等价于"功能存在但无人启用"。
- `mfa.force-enroll-on-required=false` 可作为"出问题先冻结新 enroll"的快速止血开关。

### 7.4 CLI 兜底(建议,可调整)

`apimain` 建议导出 `apimain disable-mfa <user_id_or_name>` 子命令,用于网络故障 / 后台不可用时
直接操作 SQLite / MySQL。CE-M1-2 若未实现,**仅作为 TODO** 列出,不要私下写 SQL。

## 8. 验收

> 直接对应 `../upgrade-plan.md` L175 用户验收剧本:
> "后台开启 MFA → 客户端 / API 登录提示输入 TOTP;后台审计页能看到 MFA 事件"。

按顺序执行,任一步失败即视为不通过:

```bash
# 准备:rustdesk-api 已起,admin token 已签发,测试账号 alice 已建并已绑定 MFA
API="http://127.0.0.1:21114"
ADMIN_TOKEN="<admin_jwt>"

# 1) 打开 MFA 全局开关(已在 config.yaml 配置过则跳过)
curl -s -X POST "$API/api/admin/config/reload" -H "Authorization: Bearer $ADMIN_TOKEN"

# 2) MFA 未启用账号登录 → 一步拿 access_token
curl -s -X POST "$API/api/login" -H 'Content-Type: application/json' \
  -d '{"username":"bob","password":"<bob-password>"}' | jq '.type'
# 期望: "access_token"

# 3) MFA 已启用账号登录 → 拿 ticket
TICKET=$(curl -s -X POST "$API/api/login" -H 'Content-Type: application/json' \
  -d '{"username":"alice","password":"<alice-password>"}' | jq -r '.ticket')
test -n "$TICKET" && test "$TICKET" != "null"

# 4) 用 TOTP 完成二步
curl -s -X POST "$API/api/login-mfa" -H 'Content-Type: application/json' \
  -d "{\"ticket\":\"$TICKET\",\"code\":\"<6-digit-totp>\",\"method\":\"totp\"}" | jq '.type'
# 期望: "access_token"

# 5) ticket 不落盘(客户端侧,运行客户端登录后)
grep -r "mfa_ticket" "$HOME/.config/rustdesk/RustDesk.toml" 2>/dev/null && echo FAIL || echo OK

# 6) 审计页能看到 mfa.enable / mfa.consume_recovery 事件
curl -s "$API/api/admin/login_logs/list?type=mfa.enable&page=1&page_size=5" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | jq '.data.total'
# 期望: ≥ 1
```

**人工核对项**:

- [ ] Flutter 客户端 API 登录对话框:正确码进主页 ≤ 200ms;错码停留对话框并清空输入。
- [ ] 用户用恢复码登录一次后,该恢复码不可重复使用。
- [ ] 老客户端(未升级)连新服务端:用户未启用 MFA 则登录正常;启用 MFA 则在登录页明确报错而非死循环。
- [ ] 强制 MFA 用户未 enroll,`mfa.force-enroll-on-required=true` 时能完成扫码 + 校验。

补充端到端步骤(已部署 docker-compose 才能跑通)写在 `../upgrade-plan.md` Sprint 2 收尾验收里;
本仓库不强求 CI 覆盖,该项标注 `skipped (env-bound)` 即可。
