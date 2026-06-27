# CE-M0-1 hbb_common fork 对齐

## 1. 任务目标

把 `rustdesk-server` 与 `rustdesk` 两个 Rust 仓库的 `libs/hbb_common` submodule 从官方 `https://github.com/rustdesk/hbb_common` 切到自管 fork `hbb_common-ce`,并在 fork 内建立一条同时兼容两端当前 pin(`rustdesk-server=83419b6` 与 `rustdesk=a920d00`)的零改动基线分支 `ce/base`。本任务**不引入任何 proto 字段变更**,仅完成 URL 切换、pin 重新指向、`.gitmodules` 修改与回归构建。验收信号:两个仓库执行 `git submodule update --init --recursive` 后均能 `cargo check` 通过,且 `git -C <repo>/libs/hbb_common rev-parse HEAD` 指向 `ce/base` 上由本任务记录的同一个 commit;`rustdesk-api` 仍无 `hbb_common` submodule(`git -C rustdesk-api submodule status` 输出为空)。

引用 `docs/ai-development-plan.md:101-121` 中的任务卡原文:
> CE-M0-1 hbb_common fork 对齐 …… `rustdesk-server=83419b6`,`rustdesk=a920d00` …… 建议先做 zero-change fork 对齐,不要同时改协议。

## 2. 上下文与依赖

### 上游依赖任务卡
- 无。本任务是 M0 入口,所有后续 CE 任务(尤其 M2 阶段 `PolicyUpdate` / `PolicyDigest` proto 演进)依赖本任务完成的 fork。

### 下游会用到此输出的任务卡
- CE-M0-2 hbbs PostgreSQL 后端(需要稳定可构建的 `hbb_common`)。
- CE-M0-3 metrics 端口(同上)。
- CE-M0-6 PeerMap / tcp_punch(同上)。
- CE-M1-8 WS Register 补齐(可能微调 `rendezvous.proto` 注释)。
- CE-M2 全部 proto 演进(`PolicyUpdate` / `PolicyDigest` / `_pa`/`_pb` / RBAC token)必须在 `ce/base` 之后的分支推进。

### 关键背景事实(file:line 引用)
- `rustdesk-server/.gitmodules:1-4` 当前指向 `https://github.com/rustdesk/hbb_common`,path 为 `libs/hbb_common`。
- `rustdesk/.gitmodules:1-4` 内容与上面完全相同(URL/路径一致)。
- `rustdesk-server/Cargo.toml:20` 与 `:64`(build-deps)以及 `:67`(workspace members `libs/hbb_common`)将 `hbb_common` 作为本地路径依赖与 workspace 成员引入。
- `rustdesk/Cargo.toml:50`、`:207`(workspace `libs/hbb_common`)、`:227`(build-deps)同样以本地路径方式引用,因此切 fork 后只需保证 submodule 内文件结构一致即可,无需改 `Cargo.toml`。
- `git -C rustdesk-server submodule status` 返回 `-83419b6549636ee39dacef7776c473f5802e08d6 libs/hbb_common`(前缀 `-` 表示未初始化)。
- `git -C rustdesk submodule status` 返回 `-a920d00945e1d2441b3f77b2677054cb8c3d9dd2 libs/hbb_common`(同上)。
- `git -C rustdesk-api submodule status` 输出为空,与 `docs/ai-development-plan.md:39-40`、`:524` "不要把 rustdesk-api 当成有 hbb_common submodule 的 Rust 项目" 一致。
- `docs/upgrade-plan.md:62-66`、`:126-127`、`:145-149` 明确:fork 在 `hbb_common-ce`,后续新字段一律 `optional`,proto 改动必须两个 Rust 仓库同步,rustdesk-api 仅同步 DTO/OpenAPI 语义。

### 不对称协议片段说明
- `rustdesk` 客户端的 pin(`a920d00`)比 `rustdesk-server` 的 pin(`83419b6`)新,客户端侧 `hbb_common` 自 `83419b6..a920d00` 多出若干字段(例如终端、KCP、新增审计字段、客户端用户归属等;参考 `rustdesk/libs/hbb_common` 本地 history `989bf80fe Support controller user attribution in audit logs`)。这些新增字段在官方上游均为 `optional`,服务端不识别即静默忽略——这是当前线上两端能够共存的原因。
- 因此 fork 基线必须以**客户端 pin `a920d00` 为下限**,以使 server 编译时也能感知到这些 optional 字段(序列化路径上仅 server 端会读到部分新字段,如 `audit` 链路上控制端用户名)。否则若服务器侧停留在 `83419b6`,后续在 server 引入新 proto(如 `PolicyUpdate`)时会缺少客户端已有的字段定义、导致 future merge 冲突。

## 3. 涉及文件清单

| 路径 | 动作 | 行数估计 | 说明 |
|------|------|----------|------|
| `rustdesk-server/.gitmodules` | 修改 | 1 行 | `url` 改为 `https://github.com/<org>/hbb_common-ce`(建议命名,可调整) |
| `rustdesk-server/libs/hbb_common`(submodule 指针) | 修改 | git index 1 项 | 重新指向 fork 上 `ce/base` 的合并 commit |
| `rustdesk/.gitmodules` | 修改 | 1 行 | 同上,URL 改为同一 fork |
| `rustdesk/libs/hbb_common`(submodule 指针) | 修改 | git index 1 项 | 同上,指向 `ce/base` 同一 commit |
| `hbb_common-ce`(fork 仓库,外部) | 新建 | N/A | 在 GitHub 上新建 fork;创建 `ce/base` 分支(由 `a920d00` 出发)与 `upstream/master` tracking 配置 |
| `docs/upgrade-plan.md` | 修改 | +5/-0 | 在 §6 M0 行补 "hbb_common-ce@<sha> 已接入两个 Rust 仓库" 状态 |
| `docs/ai-development-plan.md` | 修改 | +1 | 任务卡末尾追加 "状态: 完成 (commit <hash>)" |
| `docs/operations/hbb_common-ce.md` | 新建 | ~80 行 | 运维手册:fork 维护流程、如何 cherry-pick 上游、如何同步两个 Rust 仓库 pin。未找到现有同名文件,需新建 |
| `rustdesk-server/.git/config`、`rustdesk/.git/config` | 不提交 | N/A | 本地 submodule URL 由 `.gitmodules` 同步,提交后 `git submodule sync` 即可 |

`rustdesk-api/` 全程不在本任务清单内(无 submodule);仅在文档中显式记录"预期为空"。

## 4. 数据契约

本任务**不**改 protobuf / Rust struct / Go struct / SQL / HTTP / 配置项。仅有的契约性产物是 fork 仓库自身的元信息。

### Fork 仓库命名约定(建议命名,可调整)
- GitHub org:沿用用户后续推送 fork 时的 `*-ce` 命名,例如 `https://github.com/<your-org>/hbb_common-ce`。
- 默认分支:`ce/base` —— 由官方 `a920d00945e1d2441b3f77b2677054cb8c3d9dd2` 出发,零改动 fast-forward。
- 备用分支:`upstream/master` —— 镜像官方 `rustdesk/hbb_common@master`,便于后续 cherry-pick。
- 标签:打 `ce-base-v0` 标签固定本次合并基线,后续 M0/M1/M2 protocol 改动各开 `ce/feat-*` 分支并向 `ce/base` 提交 PR。

### 本任务输出的 pin
- 两个 Rust 仓库 `libs/hbb_common` submodule 提交指针均改为 `ce/base` HEAD,记录为 `<CE_BASE_SHA>`(在第 5 节步骤中产生)。

### `.gitmodules` 字段(修改两行,两仓库各一份)
```ini
[submodule "libs/hbb_common"]
    path = libs/hbb_common
    url = https://github.com/<your-org>/hbb_common-ce
    branch = ce/base    # 新增,便于 CI 跑 `git submodule update --remote` 自检
```
> `branch = ce/base` 行是新增项。官方原始 `.gitmodules` 没有该行(参见 `rustdesk-server/.gitmodules:1-4`)。可选追加,主用途是后续 CI lint 校验 submodule 指针在 `ce/base` 上。

## 5. 实现步骤

> 工作目录约定:repo root = `/Volumes/MBA_1T/Code/远程控制`。

1. **核对当前 pin**(防御性):依次执行 `git -C rustdesk-server submodule status`、`git -C rustdesk submodule status`、`git -C rustdesk-api submodule status`,确认输出与 §2 三条 SHA / 一条空一致。如不一致,中止并 escalate。
2. **拉起 fork 仓库**:在用户指定 GitHub org 下新建空仓 `hbb_common-ce`(此步可由人工完成;AI agent 把准备好的 push 指令写到 `docs/operations/hbb_common-ce.md` 并标 "需要人工执行")。
3. **本地准备 fork 源**:在 repo root 之外的 scratch 目录:
   - `git clone https://github.com/rustdesk/hbb_common hbb_common-ce-src`
   - `git -C hbb_common-ce-src checkout -b upstream/master master`
   - `git -C hbb_common-ce-src checkout -b ce/base a920d00945e1d2441b3f77b2677054cb8c3d9dd2`(选 `a920d00`,理由见 §2 不对称片段说明)
   - `git -C hbb_common-ce-src tag ce-base-v0`
   - `git -C hbb_common-ce-src remote add ce git@github.com:<your-org>/hbb_common-ce.git`
   - `git -C hbb_common-ce-src push ce upstream/master ce/base ce-base-v0`
   - 记录 `CE_BASE_SHA = a920d00945e1d2441b3f77b2677054cb8c3d9dd2`(等价于 `ce/base` HEAD)。
4. **切换 `rustdesk-server` 的 submodule URL 与 pin**:
   - 修改 `rustdesk-server/.gitmodules:3` 把 `url` 改为 fork URL,可选追加 `branch = ce/base`(参考 §4)。
   - `git -C rustdesk-server submodule sync libs/hbb_common`
   - `git -C rustdesk-server submodule update --init --recursive libs/hbb_common`(此时仍是旧 pin `83419b6`)
   - 进入 submodule:`git -C rustdesk-server/libs/hbb_common fetch ce` 然后 `git -C rustdesk-server/libs/hbb_common checkout ce/base`(指针变为 `CE_BASE_SHA`)
   - 回到外层:`git -C rustdesk-server add .gitmodules libs/hbb_common`,提交 `[CE-M0-1] hbb_common: pin to ce/base @ <CE_BASE_SHA>`。
5. **切换 `rustdesk` 的 submodule URL 与 pin**:
   - 同步骤 4 操作 `rustdesk/.gitmodules:3`。
   - 注意 `rustdesk` 本地 history 已显示 `989bf80fe Support controller user attribution in audit logs`(参见 `git -C rustdesk log libs/hbb_common`);这说明 `rustdesk` 工作树里已经 checkout 过比 `a920d00` 更新的 commit。要谨慎:在执行 `git submodule update` 前先确认 working tree 干净(`git -C rustdesk diff --quiet libs/hbb_common`)。
   - 因为 `a920d00` 就是 `rustdesk` 的 pin,checkout 到 `ce/base` 不会损失客户端协议字段。
6. **回归编译**:
   - `cd rustdesk-server && cargo check`(必要时先 `cargo update -p hbb_common` 让 workspace 重新感知;`hbb_common` 通过 `path = "libs/hbb_common"` 引用,见 `rustdesk-server/Cargo.toml:20`)
   - `cd rustdesk && cargo check --no-default-features --features inline`(全功能编译在 macOS 上对 X11/Wayland 依赖不友好;最小集足够验证 proto 解析)
7. **写运维手册** `docs/operations/hbb_common-ce.md`,记录:
   - fork URL、分支约定、`ce-base-v0` tag。
   - "如何把两个 Rust 仓库 pin 推进到 fork 的新 commit"的标准流程(即 §7 的命令序列)。
   - "如何 cherry-pick 官方 `rustdesk/hbb_common` master 新提交到 `upstream/master` 再合并入 `ce/base`"。
   - 与 `rustdesk-api` 的关系声明:无 submodule,proto 变更通过 OpenAPI/DTO 对齐,引用 `docs/ai-development-plan.md:39-40`。
8. **更新规划文档**:
   - `docs/upgrade-plan.md` §6 M0 行追加 "hbb_common-ce@`<CE_BASE_SHA>` 已接入两个 Rust 仓库"。
   - `docs/ai-development-plan.md` 第 101 行任务卡末尾补 "状态: 完成 (commit `<hash>`)"。

每步对应一次 git commit,提交信息前缀 `[CE-M0-1]`。

## 6. 测试用例

| # | 测试文件路径 / 验证位置 | 测试名 | 输入 | 期望 |
|---|--------------------------|--------|------|------|
| 1 | shell(手工 happy path) | submodule URL 切换生效 | 在两个 Rust 仓库执行 `git config -f .gitmodules submodule.libs/hbb_common.url` | 输出为 fork URL,且 `git -C libs/hbb_common remote -v` 含 fork |
| 2 | shell(手工 happy path) | submodule pin 已对齐 | `git -C rustdesk-server submodule status libs/hbb_common` 与 `git -C rustdesk submodule status libs/hbb_common` | 两条输出的 commit SHA 相同,且等于 `CE_BASE_SHA`,前缀不再是 `-` |
| 3 | `rustdesk-server` | `cargo check` | 干净 worktree | 成功;若失败必须不是 `hbb_common` 缺字段导致 |
| 4 | `rustdesk` | `cargo check --no-default-features --features inline` | 干净 worktree | 成功;同样应排除 `hbb_common` proto 缺失类错误 |
| 5 | shell(回归/兼容用例) | rustdesk-api 无 submodule(向后兼容) | `git -C rustdesk-api submodule status` | 输出为空字符串。失败说明 §3 清单或文档漏配 |
| 6 | shell(失败模式 1) | 旧 pin 误回滚 | 故意把 `rustdesk-server/libs/hbb_common` checkout 回 `83419b6` 后 `cargo check` | 通过(向后兼容)。若失败说明 server 代码已经依赖了 `a920d00` 才有的字段——本任务必须在 PR 中标红 |
| 7 | shell(失败模式 2) | URL 拼写错误 | 故意把 `.gitmodules` URL 改成不存在的 fork 名,执行 `git submodule sync && git submodule update` | 命令应失败并清晰提示 401/404,而不是 silently 留下旧 URL。验证 `git submodule sync` 已经把新 URL 写到 `.git/config` |
| 8 | shell(失败模式 3) | fork 缺 `ce/base` 分支 | 临时删除 fork 上 `ce/base` 后 `git -C libs/hbb_common fetch ce ce/base` | 失败信息明确;运维文档 §"故障恢复" 必须覆盖这种情况 |

> 注:本任务无单元测试代码改动。所有用例以 shell + cargo 形式落地,记入运维手册的"验收脚本"章节。

## 7. 验证命令

依次在 `/Volumes/MBA_1T/Code/远程控制` 下执行(注释里标了 macOS 跳过条件):

```bash
# 1. 状态核查
git -C rustdesk-server submodule status libs/hbb_common
git -C rustdesk submodule status libs/hbb_common
git -C rustdesk-api submodule status   # 必须为空

# 2. URL 校验
git -C rustdesk-server config -f .gitmodules submodule.libs/hbb_common.url
git -C rustdesk config -f .gitmodules submodule.libs/hbb_common.url

# 3. submodule 同步与拉取
git -C rustdesk-server submodule sync libs/hbb_common
git -C rustdesk-server submodule update --init --recursive libs/hbb_common
git -C rustdesk submodule sync libs/hbb_common
git -C rustdesk submodule update --init --recursive libs/hbb_common

# 4. 两个 pin 必须相等
SS=$(git -C rustdesk-server submodule status libs/hbb_common | awk '{print $1}' | tr -d '+-')
SC=$(git -C rustdesk submodule status libs/hbb_common | awk '{print $1}' | tr -d '+-')
test "$SS" = "$SC" && echo "PINS ALIGNED: $SS" || (echo "MISMATCH: $SS vs $SC"; exit 1)

# 5. 服务端编译
cd rustdesk-server && cargo check
cd -

# 6. 客户端编译(macOS dev box 可降级到最小 feature 集)
# 可跳过:全功能 `cargo check` 在 macOS 上会拉 X11/Wayland 系链路且很慢;
# 在 CI Linux runner 上才跑 `cargo check --all-features`。
cd rustdesk && cargo check --no-default-features --features inline
cd -
```

可在 macOS dev box 跳过的:
- `cd rustdesk && cargo check --all-features` —— 依赖 Linux only crate(`libxdo-sys`、`gtk` 等,见 `rustdesk/Cargo.toml:178-196`),macOS 无法编出。仅最小 feature 集足够验证 hbb_common 接入。
- `systemd-analyze` 类命令 —— 不属于本任务范围(归 CE-M0-5)。

## 8. 兼容性 / 安全注意事项

- **protobuf 兼容**:本任务**不改任何 proto 字段**。所有现有 message / field number 保持原状;后续 proto 演进在独立 CE 任务里推进时,严格遵守 `docs/ai-development-plan.md:36-39` 的"`optional` + 不重排 field number"。
- **老客户端 ↔ 新服务端 / 新客户端 ↔ 老服务端**:fork `ce/base` 选 `a920d00`(=客户端当前 pin),服务端从 `83419b6` 升到 `a920d00` 只是引入 optional 新字段,server 解析时若不读取这些字段语义无变化;反向(老客户端 pin `83419b6` 发包,新服务端 pin `a920d00`)仍由 protobuf optional 缺省值兜底。回归矩阵覆盖见 §6 #6。
- **数据库迁移**:无,本任务不触及 `rustdesk-server/src/database.rs` 与 `rustdesk-api/model/*`。
- **敏感字段不落盘**:无新增字段,无相关风险。
- **限流 / 鉴权**:无影响。
- **submodule URL 安全**:fork URL 切换后,任何后续 `git submodule update --remote` 都会从 fork 拉取代码;必须确认 fork 仓库的 push 权限受 GitHub org branch protection 保护,严禁外部贡献者直接推 `ce/base`。
- **凭据**:fork 私有/公开两种模式都要在运维手册写清楚;若设为私有仓库,CI 与开发者必须配置 HTTPS PAT 或 SSH key,否则 `git submodule update` 会以 403 失败。
- **AGPL 合规**:fork `hbb_common-ce` 必须保留官方 LICENSE 文件,与上游同步时不删 license header。

## 9. 回滚方案

本任务无 DB migration,无 feature flag,完全靠 git revert 即可:

1. 在 `rustdesk-server` 与 `rustdesk` 两个仓库 `git revert <commit-of-this-task>`,把 `.gitmodules` 与 submodule 指针回到 `https://github.com/rustdesk/hbb_common` + 各自原 pin(`83419b6` / `a920d00`)。
2. `git submodule sync && git submodule update --init` 重新拉官方仓库即可。
3. 不需要操作 `hbb_common-ce` fork 本身;保留它便于下次重试。
4. `docs/ai-development-plan.md` 与 `docs/upgrade-plan.md` 中的状态行同步回滚。
5. 因为没有数据/配置层改动,回滚后不需要重启线上服务,也不需要对客户端做任何动作。

## 10. 完成定义 (DoD)

- [ ] `hbb_common-ce` fork 仓库存在,含 `upstream/master`、`ce/base` 两条分支与 `ce-base-v0` tag。
- [ ] `rustdesk-server/.gitmodules` URL 切到 fork,`libs/hbb_common` pin 指向 `ce/base` HEAD。
- [ ] `rustdesk/.gitmodules` URL 切到 fork,`libs/hbb_common` pin 指向 `ce/base` HEAD 且与 server 端 SHA 相同。
- [ ] `git -C rustdesk-api submodule status` 输出仍为空(文档显式声明这是预期)。
- [ ] §7 命令 1–5 全部通过;命令 6 在 macOS 上以最小 feature 集通过,在 Linux CI 上以 `--all-features` 通过(后者可作为后续 CI 步骤记录,不阻塞本任务合并)。
- [ ] 新增 `docs/operations/hbb_common-ce.md`,内容覆盖:fork 维护流程、`ce/base` 分支保护策略、上游 cherry-pick SOP、两个 Rust 仓库 pin 同步 SOP、故障恢复(URL 拼写错、`ce/base` 被误删)、与 rustdesk-api 的关系声明。
- [ ] `docs/upgrade-plan.md` §6 "M0 基础设施" 行追加 "hbb_common-ce@`<CE_BASE_SHA>` 已接入"。
- [ ] 所有提交信息以 `[CE-M0-1]` 前缀。
- [ ] 在 `docs/ai-development-plan.md` 的 CE-M0-1 任务卡末尾追加 "状态: 完成 (commit `<hash>`)"。
