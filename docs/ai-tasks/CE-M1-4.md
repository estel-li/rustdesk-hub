# CE-M1-4 客户端 API MFA UI

## 1. 任务目标

让 RustDesk 桌面/移动 Flutter 客户端在登录 `rustdesk-api` 时,识别 CE-M1-3 引入的新登录响应:`{"mfa_required": true, "ticket": "<short_jwt>"}`,弹出 TOTP/恢复码输入对话框,使用 `ticket` + `code` 调用 `/api/login-mfa` 完成两步登录,得到 `access_token` 后再继续走原 `_parseAndUpdateUser`。`mfa_ticket` 全程只存在登录对话框的 Dart 局部变量中,绝不调用 `bind.mainSetLocalOption(...)` 落盘。

任务卡原文(docs/ai-development-plan.md:293-306):

> CE-M1-4 客户端 API MFA UI
> 目标:RustDesk 登录 rustdesk-api 时识别 `mfa_required`,弹出 TOTP 输入,`mfa_ticket` 只存在当前登录流程内存中。不要做:不要改已有被控端本机 `auth_2fa.rs` 语义;不要把 API MFA ticket 写入 `LocalConfig`。验收:未开启 MFA 的登录流程保持原样;开启 MFA 的账号必须输入正确 TOTP 才能拿 token。

验收信号:
- 未启用 MFA 的账号 `/api/login` 单次返回 token,行为不变。
- 启用 MFA 的账号:`/api/login` 返回 `mfa_required:true` + `ticket` → 弹出 TOTP 输入框 → 输入正确 6 位码后客户端调用 `/api/login-mfa` 得到 token 并进入主页。
- 错误码、过期 ticket、网络失败都有可见错误提示,且关闭/取消对话框不会留下任何 `access_token` 或 ticket 残留。

## 2. 上下文与依赖

- 上游依赖任务卡
  - CE-M1-1 user_mfa 表(`docs/ai-development-plan.md:241`)
  - CE-M1-2 `service/mfa.go` TOTP/恢复码核验(`docs/ai-development-plan.md:260`)
  - CE-M1-3 服务端两步登录状态机,产出 `mfa_required`/`ticket` 和 `/api/login-mfa`(`docs/ai-development-plan.md:276`)

- 下游会用到此输出的任务卡
  - CE-M1-5 后台强制 MFA(`docs/ai-development-plan.md:309`):强制策略落到登录响应里,客户端必须先支持本任务的弹窗才能进入 enroll 引导流程。
  - CE-M1-10 运维文档(`docs/ai-development-plan.md:388`)的客户端 MFA 验收章节。

- 关键背景事实(逐行引自现仓代码)
  - Flutter 唯一的 `/api/login` 调用点:`rustdesk/flutter/lib/models/user_model.dart:178-202`,目前直接把整段 JSON 喂给 `LoginResponse.fromJson`,无任何 ticket/`mfa_required` 字段。
  - 现有登录响应分支:`rustdesk/flutter/lib/common/widgets/login.dart:493-544` `handleLoginResponse` 只处理 `kAuthResTypeToken` 和 `kAuthResTypeEmailCheck`,后者通过 `tfa_type == kAuthResTypeTfaCheck` 触发 `verificationCodeDialog`。该路径走的是 **老服务端的邮件 + 一次性 TOTP 校验**(`rustdesk/flutter/lib/common/widgets/login.dart:687-796`),与新的 API 账号 MFA 不是同一个状态机,必须保留不变。
  - `LoginResponse` 当前字段(`rustdesk/flutter/lib/common/hbbs/hbbs.dart:180-197`)只有 `access_token / type / tfa_type / secret / user`,需要追加 `mfa_required / ticket / mfa_methods`。
  - `LoginRequest`(`rustdesk/flutter/lib/common/hbbs/hbbs.dart:133-178`)序列化时已经把所有非空字段写进 JSON,新增字段沿用同样的判空模式。
  - Rust 侧 `AuthBody`(`rustdesk/src/hbbs_http/account.rs:99-108`)目前用于 OIDC `/api/oidc/auth-query` 响应,字段都用 `#[serde(default)]`;OIDC 流程下 IdP 自己完成 MFA,所以 AuthBody 不需要新增 ticket 字段,但需要保证多出来的未知字段不会反序列化失败(已通过 serde 的默认行为)。
  - 客户端本机会话 TOTP 在 `rustdesk/src/auth_2fa.rs` 与 `rustdesk/src/ui_session_interface.rs:1380-1397`(`send2fa` 通过 `Auth2FA` proto 发给被控端),与本任务的 HTTP 账号 MFA 完全独立,不得修改其语义。
  - Sciter 旧 UI `/api/login` 调用点:`rustdesk/src/ui/index.tis:1541`、`1599`(已标注 deprecated,见 `rustdesk/AGENTS.md:8-9`)。最小化处理:解析 `mfa_required` 时给出明确错误提示,引导用户使用 Flutter 客户端完成。
  - `getHttpHeaders()` / `decode_http_response()` 工具:`rustdesk/flutter/lib/common.dart:2702`、`4169`,新接口 `/api/login-mfa` 复用它们,保持与 `/api/login` 一致的请求体编码与中文/UTF-8 解码。
  - 入口按钮所在的桌面主页面 `rustdesk/flutter/lib/desktop/pages/desktop_home_page.dart`(整文件 1146 行)目前仅通过 `gFFI.userModel` 触发登录,本任务无需修改该文件,只在 `login.dart`/`user_model.dart`/`hbbs.dart` 内部接入。

## 3. 涉及文件清单

| 路径 | 动作 | 行数估计 | 说明 |
|------|------|----------|------|
| `rustdesk/flutter/lib/common/hbbs/hbbs.dart` | 修改 | +25 | `HttpType` 增加 `kAuthResTypeMfaRequired`/`kAuthReqTypeMfaCode` 常量;`LoginResponse` 增加 `mfaRequired`、`mfaTicket`、`mfaMethods` 字段;`LoginRequest` 增加 `mfaTicket` 与 `mfaCode` 序列化分支。 |
| `rustdesk/flutter/lib/models/user_model.dart` | 修改 | +25 | 新增 `Future<LoginResponse> loginMfa(LoginRequest req)`,POST 到 `/api/login-mfa`,复用 `decode_http_response`,失败抛 `RequestException`。`login()` 主体保持兼容。 |
| `rustdesk/flutter/lib/common/widgets/login.dart` | 修改 | +90 | `handleLoginResponse` 增加分支:当 `resp.mfaRequired == true` 或 `resp.type == kAuthResTypeMfaRequired` 时调用新 `apiMfaDialog(ticket, methods)`;新增局部函数/顶级函数 `apiMfaDialog`(TOTP + 切换到恢复码),`mfaTicket` 仅作为闭包变量,验证成功后置空、清空 controller。 |
| `rustdesk/flutter/lib/common/widgets/dialog.dart` | 修改 | +10 | 复用 `Dialog2FaField`(`dialog.dart:469`),新增一个可选 `title` override "API 2FA code" 标签;若现有签名已支持 `title` 则零改动。 |
| `rustdesk/src/hbbs_http/account.rs` | 修改 | +10 | `AuthBody` 增加 `#[serde(default)] pub mfa_required: bool` 与 `#[serde(default)] pub mfa_ticket: Option<String>`(可选,纯防御性,确保 OIDC 与未来直接走 Rust 的登录调用方能 parse 同款 JSON;字段不写盘)。 |
| `rustdesk/src/ui/index.tis` | 修改 | +15 | 在 `:1541` 和 `:1599` 的 `/api/login` 回调里检测 `data.mfa_required`,弹出 messageBox 提示 "Please use the Flutter client for API MFA login"。Sciter 已 deprecated(`rustdesk/AGENTS.md:8`),不投入完整 UI。 |
| `rustdesk/flutter/lib/lang/template.rs` 等 lang 文件 | 修改 | +6 keys × N 语种 | 新增 key:`API MFA code`、`Use recovery code`、`MFA ticket expired, please login again`、`Invalid MFA code`、`API 2FA verification`、`API 2FA disabled, ticket dropped`。按 `rustdesk/AGENTS.md:64-86` 仅向 `template.rs` 追加;其它语种留空值。 |
| `rustdesk/flutter/test/api_mfa_test.dart` | 新建 | +120 | Dart widget/单元测试:见 §6。 |
| `rustdesk/src/hbbs_http/account.rs` 同文件附加 `#[cfg(test)]` | 修改 | +30 | Rust 单测:`AuthBody` 反序列化忽略 `mfa_required`/`mfa_ticket` 时仍 OK;新字段出现时正确读取。 |
| `docs/operations/2fa.md` | 修改(若已被 CE-M1-10 创建,否则未找到,需新建) | +30 | 在 `2fa.md` 末尾追加 "客户端验收步骤" 一节,说明 Flutter 弹窗、ticket 不落盘、Sciter UI 提示。 |
| `docs/ai-development-plan.md` | 修改 | +1 | 任务卡末尾追加 "状态: 完成 (commit <hash>)"。 |

## 4. 数据契约

### 4.1 HTTP

`POST /api/login`(由 CE-M1-3 实现,本任务消费)

成功(无 MFA,旧响应,保持向后兼容):

```json
{
  "access_token": "<jwt>",
  "type": "access_token",
  "user": { ... }
}
```

需要 MFA 时新增响应:

```json
{
  "type": "mfa_required",
  "mfa_required": true,
  "ticket": "<short_jwt>",
  "mfa_methods": ["totp", "recovery_code"]
}
```

兼容约定:

- `type` 字段同时存在 `mfa_required` 时,Flutter 以 `mfa_required==true` 为最高优先级,避免与 `email_check` 路径冲突。
- 老服务端不返回 `mfa_required`,响应 schema 不变。
- 老客户端遇到 `mfa_required` 时 `LoginResponse.fromJson` 不会抛(`mfaRequired` 走 `json[...] ?? false`),会落到 `handleLoginResponse` 的 `default` 分支报 "bad response from server",这是可接受的强制升级提示(CE-M1-3 文档须同步说明)。

`POST /api/login-mfa`(新)

请求:

```json
{
  "ticket": "<short_jwt>",
  "code": "123456",
  "method": "totp",
  "deviceInfo": { ... },
  "id": "<peer-id>",
  "uuid": "<peer-uuid>",
  "autoLogin": true
}
```

- `method` 取值:`"totp"` | `"recovery_code"`,默认 `"totp"`。
- `code` 长度:TOTP=6 位数字;`recovery_code`=按服务端 CE-M1-2 约定的格式(建议 10 位 base32-Crockford,但 Flutter 不强校验,只去掉空白)。

响应成功(沿用 `/api/login` token 形状):

```json
{
  "access_token": "<jwt>",
  "type": "access_token",
  "user": { ... }
}
```

错误码(由 CE-M1-3 决定,客户端按 `RequestException.cause` 翻译):

- `mfa_ticket_expired`(HTTP 401):提示 "MFA ticket expired, please login again",关闭对话框、回到登录窗。
- `mfa_invalid_code`(HTTP 401 / 400):停留在对话框,清空 code 输入,提示 "Invalid MFA code"。
- `mfa_rate_limited`(HTTP 429):提示 cause 文本,禁用提交按钮 N 秒(取响应 header `Retry-After`,缺省 30s)。

### 4.2 Dart 数据类

`LoginResponse`(`rustdesk/flutter/lib/common/hbbs/hbbs.dart:180`)新增字段(对外不可变):

```text
bool mfaRequired = false;
String? mfaTicket;          // 仅在调用方栈帧/对话框 closure 内传递
List<String>? mfaMethods;   // 例如 ["totp", "recovery_code"]
```

`LoginRequest`(`rustdesk/flutter/lib/common/hbbs/hbbs.dart:133`)新增:

```text
String? mfaTicket;
String? mfaCode;
String? mfaMethod;          // "totp" | "recovery_code"
```

`toJson`:仅在非空时写入,字段名分别 `"ticket"`、`"code"`、`"method"`(注意 `/api/login-mfa` 使用 `code` 而不是 `tfaCode`,避免与现有 `kAuthReqTypeTfaCode` 邮件流混淆)。

### 4.3 Rust 数据类

`AuthBody`(`rustdesk/src/hbbs_http/account.rs:99-108`)防御性追加:

```text
#[serde(default)]
pub mfa_required: bool,
#[serde(default)]
pub mfa_ticket: Option<String>,
```

`OidcSession::auth_task`(`rustdesk/src/hbbs_http/account.rs:264-289`)写入 LocalConfig 处加判断:`if auth_body.mfa_required { return error / skip persistence }`。当前 OIDC 不会产出 `mfa_required`,但兜底防止未来回归把 ticket 写盘。

### 4.4 配置项

无新增 env / yaml key。客户端不读取 MFA 相关配置,完全由服务端响应驱动。

## 5. 实现步骤

1. **扩展 hbbs.dart**(`rustdesk/flutter/lib/common/hbbs/hbbs.dart:10-197`):新增 `HttpType.kAuthResTypeMfaRequired = "mfa_required"` 与 `HttpType.kAuthReqTypeMfaCode = "mfa_code"`;在 `LoginRequest` 增 `mfaTicket/mfaCode/mfaMethod` 与对应 `toJson` 写入分支;在 `LoginResponse.fromJson` 解析 `mfa_required`、`ticket`、`mfa_methods`(`json['mfa_methods'] is List ? List<String>.from(json['mfa_methods']) : null`)。
2. **新增 `UserModel.loginMfa`**(`rustdesk/flutter/lib/models/user_model.dart:178` 之后插入):接收 `ticket/code/method/id/uuid/autoLogin`,POST 到 `$url/api/login-mfa`,行为参考 `login()`(`user_model.dart:178-202`),错误处理统一抛 `RequestException`。成功后内部调用 `getLoginResponseFromAuthBody`,完成 `_parseAndUpdateUser` 与 token 落盘。
3. **拓展 `handleLoginResponse`**(`rustdesk/flutter/lib/common/widgets/login.dart:493-544`):在 `switch (resp.type)` 上方先判 `if (resp.mfaRequired == true)`(优先于 type 判断),`final ticket = resp.mfaTicket; if (ticket == null) { passwordMsg = "Server missed mfa ticket"; return; }`,然后 `await apiMfaDialog(ticket: ticket, methods: resp.mfaMethods, username: username.text, close: close);`。保留原 `kAuthResTypeEmailCheck`/`kAuthResTypeToken` 分支不动,确保老 API 行为完全一致。
4. **实现 `apiMfaDialog`**(同文件 `login.dart`,放在 `verificationCodeDialog` 上方):
   - 仅持有 `final String _ticket = ticket;` 局部 final;不写任何 `bind.mainSetLocalOption`。
   - 使用 `Dialog2FaField`(`rustdesk/flutter/lib/common/widgets/dialog.dart:469`)作为 TOTP 输入;附加一个 `TextButton` "Use recovery code" 切换到 `DialogTextField`(单行,无数字限制)。
   - 提交时调用 `gFFI.userModel.loginMfa(LoginRequest(mfaTicket: _ticket, mfaCode: code.text.trim(), mfaMethod: method, id: ..., uuid: ..., autoLogin: true, type: HttpType.kAuthReqTypeMfaCode))`。
   - 成功 → `close(true)`;失败 `RequestException`:cause==`mfa_ticket_expired` 时 `close(false)` 并 BotToast 提示;cause==`mfa_invalid_code` 时清空 controller,显示 errorText;cause==`mfa_rate_limited` 时禁用按钮 N 秒。
   - `onCancel`:清空 `code` controller、把 `_ticket` 引用置空(Dart GC),不调用任何持久化 API。
5. **Rust `AuthBody` 字段追加**(`rustdesk/src/hbbs_http/account.rs:99-108`)与 `auth_task`(`account.rs:264-289`)防御:即使收到 `mfa_required==true` 也不把 access_token / user_info 写入 `LocalConfig`,改为 `set_state(REQUESTING_ACCOUNT_AUTH, "API MFA must be completed via Flutter UI".to_owned())`。这条路径目前仅 OIDC 走,理论上不会触发,但属于安全栅栏。
6. **Sciter 兜底**(`rustdesk/src/ui/index.tis:1541`、`:1599`):在登录回调 `function(data)` 入口加 `if (data && data.mfa_required) { view.msgbox({...}); return; }`,提示 deprecated UI 不支持 API MFA。
7. **加翻译键**:`rustdesk/src/lang/template.rs` 追加 6 条 key(按 `rustdesk/AGENTS.md:64-86` 规范),其它 lang 文件只追加空值占位。
8. **写 Dart 单测**:见 §6。使用 `flutter_test` mock `http_service.dart` 中的 `http.post`(必要时通过依赖注入或 monkey-patch 全局函数;若 `http_service.dart` 不可注入,则把 `loginMfa` 抽成接受可注入 `HttpClient` 的工厂方法,允许测试覆盖)。
9. **写 Rust 单测**:`#[cfg(test)] mod tests` 内新增 2 个用例,反序列化 JSON 含/不含 `mfa_required` 字段,断言 `AuthBody` 解析成功。
10. **跑测试**(§7),提交,更新 docs/ai-development-plan.md。

## 6. 测试用例

| # | 测试文件 | 测试名 | 输入 | 期望 |
|---|----------|--------|------|------|
| 1 | `rustdesk/flutter/test/api_mfa_test.dart` | `login response without mfa keeps old behavior` | 服务端 mock 返回 `{type:"access_token", access_token:"abc", user:{...}}` | `UserModel.login` 完成后 `userName` 非空,未弹出 MFA 对话框,`bind.mainSetLocalOption('access_token')` 被调用一次。 |
| 2 | 同上 | `login response with mfa_required triggers dialog` | mock `/api/login` → `{type:"mfa_required", mfa_required:true, ticket:"T1", mfa_methods:["totp","recovery_code"]}`;mock `/api/login-mfa` → `{type:"access_token", access_token:"abc"}` | `apiMfaDialog` 显示,输入 `123456` 后 mock 校验请求体 `{ticket:"T1", code:"123456", method:"totp"}`,成功后关闭对话框、token 写入。 |
| 3 | 同上 | `mfa ticket never persisted` | 同 #2 流程中途调用 `close(false)` 取消 | 用 spy 验证测试期间 `bind.mainSetLocalOption(key:'mfa_ticket', ...)` 从未被调用;`SharedPreferences`/LocalConfig 内不出现 `T1`。 |
| 4 | 同上 | `mfa_invalid_code shows inline error` | mock `/api/login-mfa` → HTTP 401 `{error:"mfa_invalid_code"}` | 对话框未关闭,`code` controller 被清空,`errorText` 显示翻译后的 cause。 |
| 5 | 同上 | `mfa_ticket_expired closes dialog and informs user` | mock `/api/login-mfa` → 401 `{error:"mfa_ticket_expired"}` | 对话框 `close(false)`,BotToast 出现 "MFA ticket expired, please login again",未写 `access_token`。 |
| 6 | 同上 | `recovery code switch posts method=recovery_code` | 用户点 "Use recovery code",输入 `ABCDE-12345` | POST body `{method:"recovery_code", code:"ABCDE-12345"}`。 |
| 7 | `rustdesk/src/hbbs_http/account.rs`(`#[cfg(test)] mod tests`) | `auth_body_backward_compat` | JSON 无 `mfa_required` 字段 | `serde_json::from_str::<AuthBody>` 成功,`mfa_required==false`,`mfa_ticket==None`。 |
| 8 | 同上 | `auth_body_with_mfa_required_does_not_persist` | JSON 含 `"mfa_required":true,"mfa_ticket":"T"` | 解析成功;模拟 `auth_task` 走该分支后 `LocalConfig::get_option("access_token")` 仍为空。 |
| 9(向后兼容) | `rustdesk/flutter/test/api_mfa_test.dart` | `legacy email_check path unchanged` | mock 返回 `{type:"email_check", tfa_type:"tfa_check", secret:"s", user:{email:"x"}}` | 仍调用 `verificationCodeDialog`(老路径),不进入 `apiMfaDialog`。 |

## 7. 验证命令

```bash
# 1. Dart 单测
cd rustdesk/flutter
flutter test test/api_mfa_test.dart

# 2. 整个 Flutter test 套件,确认未破坏其它登录路径
flutter test

# 3. Rust 单测(AuthBody 反序列化)
cd ../
cargo test -p rustdesk hbbs_http::account

# 4. 静态检查
cargo check
cd flutter && flutter analyze

# 5. 端到端联调(可选,在准备好 CE-M1-3 服务端的机器上)
#    a) MFA off 账号:点登录 → 直接进主页
#    b) MFA on 账号:点登录 → 弹 TOTP → 输入正确码 → 进主页
#    c) 在 b) 之间打开 ~/.config/rustdesk/RustDesk.toml 与运行内存:确认无 mfa_ticket 字段
```

可在 macOS 开发机跳过的命令:无。Dart/Rust 单测均可在 macOS 上跑。端到端步骤 5 需要 `rustdesk-api` 已合入 CE-M1-1..3,如本机未部署可跳过,在 CE-M1-10 验收时统一回归。

## 8. 兼容性 / 安全注意事项

- **Protobuf 兼容**:本任务不动 protobuf,只增加 HTTP JSON 字段,符合 §1.1 兼容性原则(`docs/ai-development-plan.md:35-40`)。
- **老客户端连新服务端**:遇到 `mfa_required` 时旧 `LoginResponse.fromJson` 不会抛(未识别字段被丢弃),仅落到 `bad response from server`,服务端必须在 CE-M1-3 文档里强调"未升级客户端必须升级才能使用 MFA",不静默回退到无 MFA 登录。
- **新客户端连老服务端**:`mfaRequired` 默认 `false`,行为与现有完全一致。
- **不要触碰 `auth_2fa.rs`**:任务明确禁止(`docs/ai-development-plan.md:301-303`),会话级 TOTP 与 API 账号 MFA 是两套独立机制,proto `Auth2FA`(`ui_session_interface.rs:1391`)走的是 RustDesk 自有协议,不经过 HTTP。
- **ticket 仅内存**:实现路径只有两处 String 引用——`apiMfaDialog` 的局部 `final String _ticket`、`LoginRequest.mfaTicket` 实例字段。绝不允许出现以下调用:`bind.mainSetLocalOption(key:'mfa_ticket', ...)`、`LocalConfig::set_option("mfa_ticket", ...)`、`SharedPreferences.setString('mfa_ticket', ...)`。测试 #3 强制校验。
- **日志卫生**:`debugPrint`/`log::info!` 输出 LoginResponse 时必须 mask 掉 `mfa_ticket`(Dart 侧 `toString()` 显式 redact;Rust 侧 `#[derive(Debug)]` 配合 `Option<String>` 至少不会自动打印未设字段,但若新增 Debug impl 要手动 `..` 跳过)。
- **限流**:依赖服务端实现(CE-M1-3 已说明)。客户端只需识别 `Retry-After` header 与 `mfa_rate_limited` cause,不要在 Flutter 端自行重试。
- **数据库迁移**:本任务不动 DB,无迁移回滚需求。
- **Sciter UI deprecated**:仅给出错误提示,确保不出现登录卡死。

## 9. 回滚方案

1. 因为不涉及 schema/proto 变更,回滚只需 `git revert` 本任务的 commit。
2. 若已发布客户端但需紧急关闭 API MFA UI:在 `login.dart` `handleLoginResponse` 入口处加 `if (kDisableApiMfa) { passwordMsg = "API MFA disabled in this build"; return; }`,通过编译期常量切回旧行为。建议预先把 `kDisableApiMfa` 常量埋在 `consts.dart`(默认 `false`)以便热修。
3. 服务端侧若 CE-M1-3 也需回退,只要不再返回 `mfa_required` 字段,客户端将自动走原路径,无需客户端配合。
4. 测试快照(若 `flutter test` 中有 golden file)删除即可,无遗留。

## 10. 完成定义 (DoD)

- [ ] `rustdesk/flutter/lib/common/hbbs/hbbs.dart` 增加 MFA 字段、常量,`LoginResponse.fromJson` 能正确解析新旧两种 JSON。
- [ ] `rustdesk/flutter/lib/models/user_model.dart` 新增 `loginMfa()`,在未启用 MFA 流程中零改动。
- [ ] `rustdesk/flutter/lib/common/widgets/login.dart` 新增 `apiMfaDialog`,`handleLoginResponse` 正确路由,`mfaTicket` 全程仅闭包持有。
- [ ] `rustdesk/src/hbbs_http/account.rs` 防御性字段与 `auth_task` 兜底处理就位,且不破坏 OIDC 兼容。
- [ ] `rustdesk/src/ui/index.tis` 两处 `/api/login` 回调对 `mfa_required` 给出明确提示。
- [ ] 翻译 key 仅在 `template.rs` 新增,其它语种留空值,符合 `rustdesk/AGENTS.md:64-86`。
- [ ] 全部 §6 测试用例落地并通过(macOS 本地)。
- [ ] `cargo check` + `flutter analyze` + 相关 cargo test / flutter test 全绿。
- [ ] grep 仓库确认无 `mfa_ticket` 字符串出现在任何 `LocalConfig` / `mainSetLocalOption` / `SharedPreferences` 调用附近。
- [ ] `docs/operations/2fa.md` 已包含客户端验收章节(若 CE-M1-10 还未起步,先把本任务相关条目暂存到本 PR 描述)。
- [ ] 提交信息以 `[CE-M1]` 开头(`docs/ai-development-plan.md:58`)。
- [ ] 在 docs/ai-development-plan.md 的对应任务卡末尾追加 "状态: 完成 (commit <hash>)".
