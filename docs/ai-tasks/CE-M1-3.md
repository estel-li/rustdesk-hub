# CE-M1-3 两步登录状态机

## 1. 任务目标

为 `rustdesk-api` 的 `/api/login` 引入两步登录:首步只校验账号密码,若该用户已启用 MFA(由 CE-M1-1 / CE-M1-2 提供的 `user_mfa` 表与 `MfaService.Verify` 决定),响应中追加 `mfa_required:true` 与一次性短期 `ticket`(短 JWT,3~5 分钟 TTL);新增 `/api/login-mfa` 路由校验 `ticket + code`(TOTP 或一次性 recovery code)后再下发 `access_token`。原有的 limiter / captcha / ban 流程必须复用,不重复实现;ticket 必须有抗重放能力(jti 入内存 nonce 存储,消费后失效)。

验收信号:
1. 未启用 MFA 用户 POST `/api/login` 的响应字段、HTTP 状态、token 形态与 `rustdesk-api/http/controller/api/login.go:87-91` 现状完全一致(旧客户端解析不破坏)。
2. 启用 MFA 用户走两步流程后才能拿到 `access_token`,任何一步失败都计入 `global.LoginLimiter`。
3. 单元/集成测试覆盖:ticket 过期、ticket 重放、错误 TOTP、错误 recovery code、ticket 绑定 IP 不匹配、未启用 MFA 兼容。

## 2. 上下文与依赖

上游依赖任务卡:
- CE-M1-1 数据模型 `user_mfa`(`docs/ai-development-plan.md:241-258`),提供查询用户是否启用 MFA 所需表与字段。
- CE-M1-2 MFA service(`docs/ai-development-plan.md:260-274`),提供 `Verify(userId, code)` 与 `ConsumeRecoveryCode(userId, code)`。本任务**只调用,不实现** MFA 业务逻辑。

下游会用到此输出的任务卡:
- CE-M1-4 客户端 API MFA UI(`docs/ai-development-plan.md:293-306`),依赖本任务的 `mfa_required`/`ticket` 字段与 `/api/login-mfa` 接口。
- CE-M1-5 后台强制 MFA(`docs/ai-development-plan.md:308-316`),当用户被强制开启 MFA 但尚未 enroll 时,登录响应可能需要再扩字段(本任务预留 `tfa_type` 字段位置)。

关键背景事实(file:line):
- 当前 `/api/login` 处理函数:`rustdesk-api/http/controller/api/login.go:29-92`,响应直接构造 `apiResp.LoginRes{AccessToken, Type:"access_token", User:...}` 并 `c.JSON(http.StatusOK, ...)`。
- 已有响应结构 `LoginRes`:`rustdesk-api/http/response/api/user.go:52-58`,已包含 `Secret`、`TfaType` 两个 `omitempty` 字段;但未包含 `MfaRequired` / `Ticket`。
- 路由注册:`rustdesk-api/http/router/api.go:34-40`,`/api/login` 在公开组(未走 `RustAuth`);`frg.Use(middleware.RustAuth())` 在 `:76` 之后才生效。`/api/login-mfa` 必须注册在 `:76` 之前,即与 `/api/login` 同组。
- 全局 limiter:`rustdesk-api/global/global.go:39` `LoginLimiter *utils.LoginLimiter`;在 `/api/login` 中已通过 `loginLimiter.RecordFailedAttempt(clientIp)`(`login.go:43,51,60`)使用,middleware `Limiter()`(`rustdesk-api/http/middleware/limiter.go:10-22`)已经被全局挂载于 `http/http.go:36`(被 banned 时直接 403,无需重复处理)。
- 全局 Jwt 实例:`rustdesk-api/global/global.go:36` `Jwt *jwt.Jwt`,在 `cmd/apimain.go:199` 初始化;`lib/jwt/jwt.go:14-17` 的 `UserClaims` 只包含 `UserId` 与 `RegisteredClaims`,**不足以承载 ticket 所需 ip/device/jti**,需要自定义 ticket claims。
- 全局缓存:`rustdesk-api/global/global.go:27` `Cache cache.Handler`,接口在 `rustdesk-api/lib/cache/cache.go:7-11` 声明,只提供 `Get/Set/Gc`,**没有 Delete**——本任务需通过"读到 nonce 仍存在即视为未消费,消费时用占位值覆盖并保持 TTL"的方式实现抗重放,无需扩接口。
- 现有 admin 登录展示了完整 limiter+captcha 流程:`rustdesk-api/http/controller/admin/login.go:38-100`,本任务的 `/api/login-mfa` 应复用同样的 ban/captcha 思路,但 `/api/login` 仍保持现状(API 端历来不要求 captcha,见 `controller/api/login.go` 未调用 `VerifyCaptcha`)。
- `UserService.Login`:`rustdesk-api/service/user.go:97-113`,负责生成 token、写 `UserToken`、写 `LoginLog`、绑定 uuid——MFA 二次校验通过后才能调用这个方法。
- `MfaService` 由 CE-M1-2 提供,本任务以 `service.AllService.MfaService` 形式调用;若该字段还未挂载,需要在 `service/service.go` 中预占位(建议命名,可调整)。

## 3. 涉及文件清单

| 路径 | 动作 | 行数估计 | 说明 |
|---|---|---|---|
| `rustdesk-api/http/controller/api/login.go` | 修改 | +80/-15 | 重写 `Login` 函数:首步成功后判断 MFA;新增 `LoginMfa` 方法 |
| `rustdesk-api/http/request/api/user.go` | 修改 | +8 | 新增 `LoginMfaForm` 结构体 |
| `rustdesk-api/http/response/api/user.go` | 修改 | +6 | `LoginRes` 增 `MfaRequired *bool` 与 `Ticket string` 两个 `omitempty` 字段 |
| `rustdesk-api/http/router/api.go` | 修改 | +1 | 在公开路由组注册 `POST /api/login-mfa` |
| `rustdesk-api/service/mfa_ticket.go` | 新建 | ~150 | ticket 签发/校验/消费;包装 cache nonce 操作;独立于 CE-M1-2 的 TOTP 校验 |
| `rustdesk-api/service/mfa_ticket_test.go` | 新建 | ~150 | 单元测试:签发→校验→重放→过期→IP 不匹配 |
| `rustdesk-api/service/service.go` | 修改 | +3 | 注册 `MfaTicketService` 到 `AllService`(若 `service.go` 结构与现有一致) |
| `rustdesk-api/conf/config.go` | 修改 | +4 | 新增 `Mfa.TicketTTL`、`Mfa.TicketBindIP`、`Mfa.LoginMfaMaxAttempts` 配置项(若 `Mfa` 子结构由 CE-M1-1/2 创建,则只 append 字段) |
| `rustdesk-api/resources/lang/*.yaml` | 修改 | +6 each | 增 `MfaTicketInvalid`、`MfaCodeError`、`MfaRequired` 翻译 key(建议命名,可调整) |
| `rustdesk-api/http/controller/api/login_test.go` | 新建 | ~250 | gin httptest 集成测试 |
| `docs/api/` swagger 注释 | 修改 | 注释内 | controller 上的 swag 注释自动同步,无需手改 docs |

未找到,需新建:`rustdesk-api/service/mfa_ticket.go`、对应测试文件、`controller/api/login_test.go`(目前 `controller/api/` 下无测试文件)。

## 4. 数据契约

### 4.1 HTTP 请求/响应 JSON

**`POST /api/login` 请求**:保持现状,字段定义见 `http/request/api/user.go:31-39`,不修改。

**`POST /api/login` 响应——未启用 MFA(向后兼容,与现状一致)**:
```json
{
  "type": "access_token",
  "access_token": "<token>",
  "user": { "name": "...", "email": "...", "is_admin": false, "status": 1, "info": {} }
}
```

**`POST /api/login` 响应——启用 MFA**:
```json
{
  "type": "tfa_check",
  "mfa_required": true,
  "ticket": "<short_jwt>",
  "tfa_type": "totp"
}
```
- `type` 使用现有约定 `kAuthResTypeTfaCheck`(`response/api/user.go:49`),不发明新值。
- `mfa_required` 与 `ticket` 字段加 `omitempty`,旧客户端若未识别字段会保留 `type=="access_token"` 判断为成功——但因 `access_token` 缺失旧客户端会自然降级为登录失败,这是预期(旧客户端无法完成 MFA)。

**`POST /api/login-mfa` 请求**:
```json
{
  "ticket": "<short_jwt>",
  "code":   "123456",
  "type":   "totp"          // totp | recovery
}
```

**`POST /api/login-mfa` 响应(成功)**:与原 `LoginRes`(`access_token` 形态)完全一致。

**`POST /api/login-mfa` 响应(失败)**:沿用 `response.Error(c, msg)`(参见 `controller/api/login.go:45`),HTTP 200 + `{"error":"..."}`,与 `/api/login` 现行错误格式一致。

### 4.2 Go 结构体

```go
// http/request/api/user.go,新增
type LoginMfaForm struct {
    Ticket string `json:"ticket" validate:"required,gte=10,lte=512" label:"ticket"`
    Code   string `json:"code"   validate:"required,gte=6,lte=16"   label:"code"`
    Type   string `json:"type"   validate:"omitempty,oneof=totp recovery" label:"type"`
}

// http/response/api/user.go,扩展 LoginRes
type LoginRes struct {
    Type         string      `json:"type"`
    AccessToken  string      `json:"access_token,omitempty"`     // 建议从 ""+TfaType 模式改为 omitempty
    User         UserPayload `json:"user,omitempty"`
    Secret       string      `json:"secret,omitempty"`
    TfaType      string      `json:"tfa_type,omitempty"`
    MfaRequired  bool        `json:"mfa_required,omitempty"`     // 新增
    Ticket       string      `json:"ticket,omitempty"`           // 新增
}
```

注意:`AccessToken` 与 `User` 加 `omitempty` 是为了 MFA 中间响应不出现空字段;若考虑 swagger/前端契约稳定性,可改为始终输出空值,**两种皆可,建议命名,可调整**。

### 4.3 Ticket Claims(短 JWT)

```go
// service/mfa_ticket.go,新建
type MfaTicketClaims struct {
    UID    uint   `json:"uid"`
    IP     string `json:"ip"`
    Device string `json:"dev"`   // 来源 LoginForm.Id;为空允许
    JTI    string `json:"jti"`   // uuid v4
    jwt.RegisteredClaims          // ExpiresAt, IssuedAt, Issuer="rustdesk-api/mfa"
}
```

签名密钥:复用 `global.Jwt.Key`(`global/global.go:36`),不引入新密钥。
TTL:从 `Config.Mfa.TicketTTL` 读,默认 `3 * time.Minute`,最大 `5 * time.Minute`(在 `service.IssueTicket` 中 clamp)。

### 4.4 缓存 Nonce 键

Key 格式:`mfa:ticket:nonce:<jti>`
Value:JSON `{"consumed":false,"uid":<uid>,"exp":<unix>}`,消费后 `consumed:true`。
TTL:同 ticket TTL(默认 300s)。
通过 `global.Cache.Set(key, val, ttlSeconds)` / `global.Cache.Get(key, &val)`(接口见 `lib/cache/cache.go:7-11`)。

### 4.5 配置项

```yaml
# rustdesk-api/conf/config-template.yaml,若 Mfa 段已由 CE-M1-1/2 建立则 append
mfa:
  ticket_ttl: 180s              # ticket 有效期,3-5 分钟,默认 180s
  ticket_bind_ip: true          # 是否将 ticket 与 client IP 绑定
  login_mfa_max_attempts: 5     # 单 ticket 最大错误次数,超过即作废 nonce
```

环境变量(若沿用项目已有 viper key 大写规则):`MFA_TICKET_TTL`、`MFA_TICKET_BIND_IP`、`MFA_LOGIN_MFA_MAX_ATTEMPTS`。

## 5. 实现步骤

1. **扩展 `LoginRes` 与新增 `LoginMfaForm`**:修改 `rustdesk-api/http/response/api/user.go:52-58` 添加 `MfaRequired`、`Ticket` 字段(omitempty);修改 `rustdesk-api/http/request/api/user.go:31-39` 同文件追加 `LoginMfaForm`。

2. **新建 `service/mfa_ticket.go`**:
   - `Issue(uid uint, ip, device string) (token string, jti string, err error)`:生成 jti(`uuid.NewString()`)、构造 `MfaTicketClaims`、用 `global.Jwt.Key` 以 HS256 签名;同时调用 `global.Cache.Set("mfa:ticket:nonce:"+jti, nonce{Consumed:false,...}, ttlSeconds)`。
   - `Verify(token, ip string) (*MfaTicketClaims, error)`:`jwt.ParseWithClaims` → 校验 exp → 若 `Config.Mfa.TicketBindIP` 则比对 `claims.IP == ip` → `global.Cache.Get("mfa:ticket:nonce:"+jti, &nonce)` 不存在/已过期返回错误,`nonce.Consumed==true` 视作 replay 返回错误。
   - `Consume(jti string, uid uint)`:`global.Cache.Set` 同 key,但 value 设为 `{Consumed:true,...}`,TTL 保持原 ticket 剩余时间(可用 `time.Until(claims.ExpiresAt)` 计算)。因 `cache.Handler` 无 Delete,这是消费后失效的等价手段。
   - `IncAttempt(jti string) (current int, exceed bool)`:可选,用 `mfa:ticket:fail:<jti>` 计数,超 `Config.Mfa.LoginMfaMaxAttempts` 立即 `Consume`。

3. **在 `service/service.go` 注册**:把 `MfaTicketService` 加入 `AllService`(参照 `service/user.go` 注入习惯,但具体结构以仓库现有 `service.go` 为准——若 `MfaService` 在 CE-M1-2 已注册一并扩 `MfaTicketService`)。

4. **改写 `controller/api/login.go` 的 `Login`**:在 `login.go:77` 调用 `UserService.Login` 之前插入:
   - `enabled := service.AllService.MfaService.IsEnabled(u.Id)`(CE-M1-2 接口,若未提供则建议命名 `MfaService.IsEnabled(uid)` 由本任务约定 stub)。
   - 若 `enabled`:`loginLimiter.RemoveAttempts(clientIp)`(密码已正确,先清失败次数,同 admin 行为 `admin/login.go:99`);`ticket, _, err := service.AllService.MfaTicketService.Issue(u.Id, c.ClientIP(), f.Id)`;返回 `LoginRes{Type:"tfa_check", MfaRequired:true, Ticket:ticket, TfaType:"totp"}` 并 `return`。
   - 未启用走原逻辑:`UserService.Login(...)` + 现有响应(`login.go:87-91`)。

5. **新增 `LoginMfa` handler**(`controller/api/login.go`):
   - 解析 `LoginMfaForm`(走 `global.Validator.ValidStruct`)。
   - 调用 `MfaTicketService.Verify(form.Ticket, c.ClientIP())`;失败 → `loginLimiter.RecordFailedAttempt(clientIp)` + `response.Error(c, TranslateMsg(c,"MfaTicketInvalid"))`。
   - 根据 `form.Type` 调用 `MfaService.Verify(claims.UID, form.Code)` 或 `MfaService.ConsumeRecoveryCode(claims.UID, form.Code)`;失败 → `loginLimiter.RecordFailedAttempt(clientIp)`;调用 `MfaTicketService.IncAttempt(claims.JTI)`,超阈值则消费 ticket;`response.Error(c, TranslateMsg(c,"MfaCodeError"))`。
   - 成功 → `MfaTicketService.Consume(claims.JTI, claims.UID)`;`u := UserService.InfoById(claims.UID)`;复用 `UserService.Login(u, &model.LoginLog{...Type: model.LoginLogTypeAccount, Client: ...})`,Client/Device 字段从 form 没有,可在 ticket claims 里加 `client_type` 或从 referer 推断(与 `login.go:71-75` 同逻辑);返回与现有完全一致的 `LoginRes`。
   - `loginLimiter.RemoveAttempts(clientIp)`(参考 `admin/login.go:99`)。

6. **路由注册**:在 `rustdesk-api/http/router/api.go:39` 之后添加 `frg.POST("/login-mfa", l.LoginMfa)`,确保在 `frg.Use(middleware.RustAuth())`(`:76`)之前。

7. **配置项**:在 `conf/config.go`(若已存在 `Mfa` 段)追加 `TicketTTL time.Duration`、`TicketBindIP bool`、`LoginMfaMaxAttempts int`;在 `conf/config-template.yaml` 写默认值。

8. **i18n 文案**:在 `rustdesk-api/resources/lang/*.yaml` 各语言文件追加 `MfaTicketInvalid`、`MfaCodeError`、`MfaRequired`、`MfaTicketExpired`(建议命名,可调整)。

9. **swag 注释**:在 `Login` 与新 `LoginMfa` 上写完整 `@Tags 登录` 等注释(参照 `login.go:19-28` 风格)。

10. **测试**:写 `service/mfa_ticket_test.go` 与 `controller/api/login_test.go`(httptest + sqlite 内存 DB),用例见 §6。

## 6. 测试用例

| # | 测试文件 | 测试名 | 输入 | 期望 |
|---|---|---|---|---|
| 1 | `service/mfa_ticket_test.go` | `TestIssueAndVerify_OK` | uid=42, ip="1.2.3.4" | Issue 成功后 Verify 返回 claims.UID==42 |
| 2 | `service/mfa_ticket_test.go` | `TestVerify_Replay` | Issue → Verify → Consume → 再 Verify 同 token | 第二次返回 `ErrTicketConsumed` |
| 3 | `service/mfa_ticket_test.go` | `TestVerify_Expired` | TTL=1s,Sleep 2s 后 Verify | 返回 jwt 过期错误 |
| 4 | `service/mfa_ticket_test.go` | `TestVerify_IPMismatch` | Issue ip="1.1.1.1",Verify ip="2.2.2.2" | 返回 `ErrTicketIPMismatch` |
| 5 | `service/mfa_ticket_test.go` | `TestVerify_IPMismatch_DisabledByConfig` | 同上但 `Config.Mfa.TicketBindIP=false` | Verify 成功 |
| 6 | `controller/api/login_test.go` | `TestLogin_NoMfa_BackwardCompat` | 密码正确,MFA 未启用 | 200,字段含 `access_token`,**不含** `mfa_required`/`ticket` 键 |
| 7 | `controller/api/login_test.go` | `TestLogin_MfaRequired` | 密码正确,MFA 已启用 | 200,字段 `type=="tfa_check"`、`mfa_required:true`、`ticket` 非空,**无** `access_token` |
| 8 | `controller/api/login_test.go` | `TestLoginMfa_OK_TOTP` | 上一步 ticket + 正确 TOTP | 200,响应等价于原 `/api/login` 成功响应(含 `access_token`) |
| 9 | `controller/api/login_test.go` | `TestLoginMfa_WrongCode_LimiterIncrement` | ticket + 错 code | error 响应,`LoginLimiter` 失败计数 +1 |
| 10 | `controller/api/login_test.go` | `TestLoginMfa_TicketReplay` | 同一 ticket 成功消费后再次提交 | error `MfaTicketInvalid` |
| 11 | `controller/api/login_test.go` | `TestLoginMfa_TicketExpired` | TTL=1s → 等待 2s → 提交 | error `MfaTicketInvalid` |
| 12 | `controller/api/login_test.go` | `TestLoginMfa_RecoveryCode_OneTime` | ticket + recovery code 两次 | 首次 200,第二次因 recovery 已消费返回 error(由 `MfaService.ConsumeRecoveryCode` 保证) |
| 13 | `controller/api/login_test.go` | `TestLogin_WrongPassword_StillLimited` | 错密码,与现状一致 | `RecordFailedAttempt` 被调用,响应与 `login.go:60-63` 一致 |

## 7. 验证命令

```bash
# 1. 编译
cd /Volumes/MBA_1T/Code/远程控制/rustdesk-api && go build ./...

# 2. 单测
cd /Volumes/MBA_1T/Code/远程控制/rustdesk-api && go test ./service/... ./http/...

# 3. 静态检查(若 CI 配置了 golangci-lint)
cd /Volumes/MBA_1T/Code/远程控制/rustdesk-api && golangci-lint run ./...    # 可在 macOS 跳过若未安装

# 4. 本地手工冒烟(macOS dev box 可跳过,需 sqlite 与端口 21114):
cd /Volumes/MBA_1T/Code/远程控制/rustdesk-api && go run cmd/apimain.go &
curl -X POST http://127.0.0.1:21114/api/login -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"admin"}'
# 拿到 ticket 后:
curl -X POST http://127.0.0.1:21114/api/login-mfa -H 'Content-Type: application/json' \
  -d '{"ticket":"<copy>", "code":"123456", "type":"totp"}'

# 5. swag 重新生成(如果项目 CI 校验 docs/api 文档同步)
cd /Volumes/MBA_1T/Code/远程控制/rustdesk-api && swag init -g cmd/apimain.go -o docs/api    # macOS 可跳过,如果 swag CLI 未装
```

可在 macOS dev box 跳过的命令:#3(取决于是否安装 `golangci-lint`)、#4(需 sqlite + 端口)、#5(需 `swag` CLI);CI 阶段必须全部跑通。

## 8. 兼容性 / 安全注意事项

- **响应兼容**:`LoginRes` 仅追加 `omitempty` 字段。未启用 MFA 用户的响应 JSON 与现有 `login.go:87-91` 字段集合相同,旧客户端(包括未识别 `mfa_required` 的 RustDesk 老版本)解析不受影响。
- **旧客户端不可恢复地无法完成 MFA 登录**:这是符合规划("启用 MFA 后未升级客户端无法登录")的安全权衡;在 `mfa_required:true` 响应里同时给出 `type:"tfa_check"`,前端有兜底文案。
- **ticket 不持久化**:仅放 `global.Cache`(默认 `cache.TypeMem`,见 `lib/cache/cache.go:22-34`)。即使 cache 切到 Redis,也仅短期保存 JTI 元数据,**不存 secret、不存密码、不存 TOTP 明文**。
- **Ticket 抗重放**:基于 jti 入 cache 的 `Consumed` 标记。注意 cache.Handler 无 Delete,所以 Consume 用 Set 覆盖 + 保持 TTL,过期后自然 GC。
- **IP 绑定**:`Config.Mfa.TicketBindIP=true` 默认开启;反向代理场景需保证 `c.ClientIP()` 正确(项目应已配置 `trusted_proxies`,与 `login.go:37`/`admin/login.go:39` 取 IP 方式保持一致)。允许 ops 关闭以适配 NAT 切换。
- **限流**:密码错沿用 `LoginLimiter.RecordFailedAttempt`(`login.go:60`);MFA 错也调 `RecordFailedAttempt`(与计划要求一致 `ai-development-plan.md:287`);同时单 ticket 内 `IncAttempt` 加二级保护,防止单 IP 多用户横扫。
- **数据库迁移**:本任务**不引入新表**,不写迁移;`DatabaseVersion` 由 CE-M1-1 推到 266。
- **敏感字段落盘**:不写日志(`global.Logger.Warn` 仅记录 IP/失败原因,不打印 ticket 与 code,参考 `login.go:44` 风格)。
- **CSRF**:`/api/login-mfa` 与 `/api/login` 一样是无状态 JSON 接口,沿用现有跨域策略(`middleware.Cors`),无需额外 CSRF token。

## 9. 回滚方案

- 本任务无 schema 变更,无需 migration down。
- 回滚步骤:
  1. `git revert` 本任务 commit。
  2. 由于 `/api/login-mfa` 路由在 revert 后被移除,旧客户端继续走 `/api/login` 一次通过——不影响线上未启用 MFA 的用户。
  3. 已启用 MFA 的用户会瞬时无法登录(因 `/api/login` 又变成一次通过但 `MfaService.IsEnabled` 不再被检查);建议在 ops 文档中提示:**回滚前先用 admin 后台批量关闭 user_mfa.enabled_at**。
- Feature flag(可选,**建议命名,可调整**):新增 `Config.Mfa.LoginGateEnabled bool`,默认 true;关闭后 `/api/login` 不再读 MFA 状态、直接发 token——给 ops 一个不需要 revert 的应急开关。
- `/api/login-mfa` 路由本身被禁用时返回 404 或 503,由 `Config.Mfa.LoginGateEnabled` 控制注册。

## 10. 完成定义 (DoD)

- [ ] `LoginRes` 增 `MfaRequired`、`Ticket` 两个 `omitempty` 字段,旧字段不变。
- [ ] `LoginMfaForm` 在 `request/api/user.go` 定义并通过 `global.Validator.ValidStruct` 校验。
- [ ] `service/mfa_ticket.go` 提供 `Issue / Verify / Consume / IncAttempt`,使用 `global.Jwt.Key` 签名,jti 入 `global.Cache`。
- [ ] `controller/api/login.go` `Login` 在 MFA 启用时返回 ticket 响应,不发 access_token。
- [ ] `controller/api/login.go` 新增 `LoginMfa` handler,失败计入 `LoginLimiter.RecordFailedAttempt`,成功复用 `UserService.Login` 写 `UserToken` + `LoginLog`。
- [ ] `router/api.go` 在公开组注册 `POST /api/login-mfa`。
- [ ] `Config.Mfa.TicketTTL/TicketBindIP/LoginMfaMaxAttempts` 三个配置项落到 `conf/config.go` 与 `conf/config-template.yaml`,默认 `180s / true / 5`。
- [ ] i18n 文案 `MfaTicketInvalid`、`MfaCodeError`、`MfaRequired`、`MfaTicketExpired` 入各语言 yaml。
- [ ] §6 列出的 13 个测试全部通过 `go test ./...`。
- [ ] §7 命令在 CI 模式下全部 0 退出。
- [ ] 未启用 MFA 的回归测试 `TestLogin_NoMfa_BackwardCompat` 在响应 JSON 中确认无 `mfa_required`、`ticket` 两个键(向后兼容守门)。
- [ ] swag 注释完整且 `docs/api/` 不出现未提交差异(若 CI 校验)。
- [ ] 在 `docs/ai-development-plan.md` 的对应任务卡末尾追加 "状态: 完成 (commit &lt;hash&gt;)"。
