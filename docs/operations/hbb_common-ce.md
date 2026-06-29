# hbb_common-ce Fork 维护手册

> 配套任务卡:`docs/ai-tasks/CE-M0-1.md`。本手册聚焦运维流程,不再重复任务卡的背景与决策。

## 1. Fork 元信息

| 项目 | 取值 |
|------|------|
| Fork 仓库(建议命名) | `https://github.com/estel-li/hbb_common-ce` |
| 上游 | `https://github.com/rustdesk/hbb_common` |
| 默认分支 | `ce/base`,由官方 `a920d00945e1d2441b3f77b2677054cb8c3d9dd2` 出发,零改动 fast-forward |
| 上游镜像分支 | `upstream/main`,镜像官方 `rustdesk/hbb_common@main`(官方默认分支已从 `master` 迁至 `main`) |
| 拓展分支 | `ce/feat-rustdesk-server-fmt`,保留 estel 在 2026-06-29 提交的 `2c6c129`(纯格式化,基于 `83419b6`);不入 `ce/base`,后续如需可 cherry-pick |
| 基线 tag | `ce-base-v0`,固定本次合并基线 |
| Branch protection | `ce/base` 必须开启 require PR + require 1 review;严禁外部贡献者直接 push |
| 可见性 | 默认 Public(同上游 AGPL);如设为 Private,需在 CI/开发者机器配置 HTTPS PAT 或 SSH key,否则 `git submodule update` 会以 403 失败 |

`CE_BASE_SHA = a920d00945e1d2441b3f77b2677054cb8c3d9dd2`(等同于 `ce/base` HEAD 与 `ce-base-v0` tag)。

## 2. 与三仓库的关系

- `rustdesk-server/libs/hbb_common`:submodule,`.gitmodules` URL 必须指向 fork,pin 在 `ce/base` HEAD。
- `rustdesk/libs/hbb_common`:submodule,`.gitmodules` URL 必须指向 fork,pin 与 server 端 SHA 一致。
- `rustdesk-api`:**没有 hbb_common submodule**。`git -C rustdesk-api submodule status` 必须输出空字符串。proto 变更通过 OpenAPI/DTO 对齐(参考 `docs/ai-development-plan.md:39-40`、`docs/upgrade-plan.md:126-127`)。

## 3. 首次初始化(需人工执行,AI agent 无法代办)

```bash
# 3.1 在 GitHub 上新建空仓 estel-li/hbb_common-ce(Public,AGPL 协议)
#     - 关闭 GitHub Actions 默认权限直至运维明确开启
#     - 开启 branch protection: ce/base 与 upstream/main

# 3.2 本地准备源(在 repo root 之外的 scratch 目录)
cd /tmp
git clone https://github.com/rustdesk/hbb_common hbb_common-ce-src
cd hbb_common-ce-src

# 3.3 建立两条分支(注意:官方默认分支是 main,不是 master)
git checkout -b upstream/main main
git checkout -b ce/base a920d00945e1d2441b3f77b2677054cb8c3d9dd2

# 3.4 打基线 tag
git tag ce-base-v0

# 3.5 推送到 fork
git remote add ce https://github.com/estel-li/hbb_common-ce
git push ce upstream/main ce/base ce-base-v0
```

完成后向 PR 评论里贴出 `CE_BASE_SHA` 与 fork URL,作为 CE-M0-1 验收凭据。

## 4. 切换两个 Rust 仓库的 submodule URL 与 pin

> 完成 §3 后再做。两个仓库都跑一遍以下序列。

```bash
REPO=rustdesk-server   # 第二次跑时换成 rustdesk
ORG=estel-li

# 4.1 修改 .gitmodules
git -C $REPO config -f .gitmodules submodule.libs/hbb_common.url \
    "https://github.com/$ORG/hbb_common-ce"
# 可选:同步加 branch 字段,便于 CI lint
git -C $REPO config -f .gitmodules submodule.libs/hbb_common.branch ce/base

# 4.2 同步 .git/config(关键:不做这一步 url 改动不会生效)
git -C $REPO submodule sync libs/hbb_common

# 4.3 拉取 submodule(此时仍是旧 pin)
git -C $REPO submodule update --init --recursive libs/hbb_common

# 4.4 进 submodule 切到 ce/base
git -C $REPO/libs/hbb_common fetch origin ce/base
git -C $REPO/libs/hbb_common checkout ce/base
git -C $REPO/libs/hbb_common rev-parse HEAD   # 应输出 CE_BASE_SHA

# 4.5 把指针 + .gitmodules 改动一起提交
git -C $REPO add .gitmodules libs/hbb_common
git -C $REPO commit -m "[CE-M0-1] hbb_common: pin to ce/base @ $CE_BASE_SHA"
```

> `rustdesk` 仓库本地 history 可能含有比 `a920d00` 更新的 hbb_common commit(例如 `989bf80fe Support controller user attribution in audit logs`);在 4.3 之前必须保证 `git -C rustdesk diff --quiet libs/hbb_common`,否则会丢失未提交的 working-tree 改动。

## 5. 推进 fork pin 的 SOP

当 fork 新增 commit 后,需要把两个 Rust 仓库的 pin 一起推进,避免 server 与 client 协议字段漂移。

```bash
NEW_SHA=<fork-new-head-sha>

for REPO in rustdesk-server rustdesk; do
  git -C $REPO/libs/hbb_common fetch origin
  git -C $REPO/libs/hbb_common checkout $NEW_SHA
  (cd $REPO && cargo check) || { echo "[$REPO] cargo check failed"; exit 1; }
  git -C $REPO add libs/hbb_common
  git -C $REPO commit -m "[CE-Mx] hbb_common: bump to $NEW_SHA"
done

# 校验:两端 pin 必须相同
SS=$(git -C rustdesk-server submodule status libs/hbb_common | awk '{print $1}' | tr -d '+-')
SC=$(git -C rustdesk submodule status libs/hbb_common | awk '{print $1}' | tr -d '+-')
test "$SS" = "$SC" && echo "PINS ALIGNED: $SS" || { echo "MISMATCH: $SS vs $SC"; exit 1; }
```

## 6. 上游 cherry-pick SOP

```bash
cd /tmp/hbb_common-ce-src
git fetch origin                                 # 拉 fork
git fetch https://github.com/rustdesk/hbb_common main:upstream/main-new

# 6.1 更新镜像分支(纯 fast-forward)
git checkout upstream/main
git merge --ff-only upstream/main-new
git push origin upstream/main

# 6.2 把 upstream main 上的具体 commit 拣到 ce/base
git checkout ce/base
git cherry-pick <upstream-sha>
# 解决冲突后 git cherry-pick --continue;不要 squash,保留作者信息

# 6.3 推回 fork(通过 PR,触发 branch protection 审核)
git push origin HEAD:refs/heads/ce/feat-<topic>
# 在 GitHub UI 上对 ce/base 开 PR,合并后跑 §5 推进两个 Rust 仓库 pin
```

## 7. 故障恢复

### 7.1 `.gitmodules` URL 拼写错(§6 失败模式 7)

症状:`git submodule update` 出现 401/404。

```bash
git -C $REPO config -f .gitmodules submodule.libs/hbb_common.url \
    https://github.com/estel-li/hbb_common-ce
git -C $REPO submodule sync libs/hbb_common
grep -A2 hbb_common $REPO/.git/config   # 确认 url 已被 sync 进来
git -C $REPO submodule update --init --recursive libs/hbb_common
```

### 7.2 fork 上 `ce/base` 分支被误删(§6 失败模式 8)

```bash
# 7.2.1 在任意已 checkout 过 ce/base 的本地仓库恢复
cd /Volumes/MBA_1T/Code/远程控制/rustdesk-server/libs/hbb_common
git push origin HEAD:refs/heads/ce/base       # 用本地指针强推回 fork

# 7.2.2 如果所有本地副本都被清掉,但 ce-base-v0 tag 还在
cd /tmp/hbb_common-ce-src
git fetch origin --tags
git push origin refs/tags/ce-base-v0:refs/heads/ce/base
```

恢复后必须重新打开 ce/base branch protection,并在 PR 中走 §6 流程重新审核。

### 7.3 服务端不小心被 rollback 到 `83419b6`

任务卡 §6 #6 把这条标记为"必须通过":如果在 server 端代码引入 `a920d00` 才有的字段读取后再 rollback 会失败,需在 PR 中标红。临时恢复:

```bash
git -C rustdesk-server/libs/hbb_common checkout ce/base
git -C rustdesk-server add libs/hbb_common
git -C rustdesk-server commit -m "[hotfix] restore hbb_common to ce/base"
```

## 8. 验收脚本(对应任务卡 §7)

```bash
set -euo pipefail
cd /Volumes/MBA_1T/Code/远程控制

# 1. 状态核查
git -C rustdesk-server submodule status libs/hbb_common
git -C rustdesk submodule status libs/hbb_common
test -z "$(git -C rustdesk-api submodule status)" || { echo "rustdesk-api should have no submodule"; exit 1; }

# 2. URL 校验
git -C rustdesk-server config -f .gitmodules submodule.libs/hbb_common.url | grep -q hbb_common-ce
git -C rustdesk config -f .gitmodules submodule.libs/hbb_common.url | grep -q hbb_common-ce

# 3. submodule 同步与拉取
git -C rustdesk-server submodule sync libs/hbb_common
git -C rustdesk-server submodule update --init --recursive libs/hbb_common
git -C rustdesk submodule sync libs/hbb_common
git -C rustdesk submodule update --init --recursive libs/hbb_common

# 4. 两个 pin 必须相等
SS=$(git -C rustdesk-server submodule status libs/hbb_common | awk '{print $1}' | tr -d '+-')
SC=$(git -C rustdesk submodule status libs/hbb_common | awk '{print $1}' | tr -d '+-')
test "$SS" = "$SC" && echo "PINS ALIGNED: $SS" || { echo "MISMATCH: $SS vs $SC"; exit 1; }

# 5. 服务端编译
(cd rustdesk-server && cargo check)

# 6. 客户端编译(macOS 用最小 feature 集;Linux CI 跑 --all-features)
(cd rustdesk && cargo check --no-default-features --features inline)
```

## 9. AGPL 合规与凭据

- fork 仓库必须保留官方 `LICENSE`、`COPYRIGHT` 等所有 license 文件,与上游同步时不删 license header。
- 若 fork 设为 Private,CI 与开发者必须配置 HTTPS PAT 或 SSH key,否则 `git submodule update` 会以 403 失败。
- `ce/base` 严禁外部贡献者直接 push;只能通过 PR + branch protection 合入。

## 10. 当前状态

- ✅ 完成 (2026-06-29):
  - fork `https://github.com/estel-li/hbb_common-ce` 已建好,含 `ce/base`、`upstream/main`、`ce-base-v0` tag(均指向 `a920d00`)。
  - 同时保留了 `ce/feat-rustdesk-server-fmt` 分支(`2c6c129`,estel 本人提交的格式化补丁,基于 `83419b6`,**不在 ce/base 链上**;后续如需可 cherry-pick)。
  - `rustdesk` 与 `rustdesk-server` 两仓的 `.gitmodules` URL 已切到 fork,`branch = ce/base` 字段已加,submodule pin 统一为 `a920d00` = `CE_BASE_SHA`。
  - 任务卡 §7 验证命令 1–4 与 §8 验收脚本 1–4 通过。
- ⏳ 待办:
  - GitHub UI 上把 `hbb_common-ce` 的默认分支显式设为 `ce/base`(目前 HEAD 已经自动落在 ce/base,但 branch protection 仍需手动开)。
  - `cargo check`(§7 命令 5–6)在 macOS dev 机上需要本地有 protoc 与 X11/Wayland headers,首次跑会慢;CI Linux runner 上跑 `--all-features` 才是最终验收。
