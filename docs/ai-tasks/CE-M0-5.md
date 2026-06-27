# CE-M0-5 systemd 加固 + 专用用户

## 1. 任务目标

让 `hbbs` / `hbbr` 不再以 root 运行,而是以专用系统用户 `rustdesk` 运行,并通过 systemd 沙箱选项 (`ProtectSystem=strict`、`NoNewPrivileges=true`、`ReadWritePaths=...`) 收敛文件系统写入权限;deb 包 `postinst` 在 `configure` 阶段保证 `rustdesk` 用户与运行目录 (`/var/lib/rustdesk-server/`、`/var/log/rustdesk-server/`) 存在且具备正确属主权限。验收信号:

```
systemd-analyze security rustdesk-hbbs.service   # Exposure 显著下降(目标 < 5.0 OK,至少远低于改造前的 9.x)
systemd-analyze security rustdesk-hbbr.service
ps -o user= -p $(pidof hbbs)                     # 输出 rustdesk
ls -ld /var/lib/rustdesk-server /var/log/rustdesk-server  # owner: rustdesk:rustdesk
```

任务卡原文(`docs/ai-development-plan.md:184-200`):hbbs/hbbr 以专用 `rustdesk` 用户运行;加入 `ProtectSystem=strict`、`NoNewPrivileges=true`、`ReadWritePaths=/var/lib/rustdesk-server`;`postinst` 创建用户与目录权限;不要破坏 FreeBSD rc.d / Docker 现有路径。

## 2. 上下文与依赖

- 上游依赖任务卡:无强依赖;与 CE-M0-1 (proto 字段裁剪)、CE-M0-2 (TLS)、CE-M0-3 (metrics)、CE-M0-4 (api healthcheck) 并行可做。建议先于 CE-M0-7 (管理 CLI 改 UDS + token) 落地,因为 CE-M0-7 的 socket 与 token 文件权限假设服务以 `rustdesk` 用户运行。
- 下游会用到此输出的任务卡:
  - CE-M0-7:UDS 文件 owner/group 设为 `rustdesk:rustdesk`,权限 `0660`。
  - 后续 M1+ 任何写入数据/日志/密钥的功能(签名密钥落盘、SQLite 文件等),都要在 `ReadWritePaths` 白名单或显式扩展。
- 关键背景事实:
  - 当前 systemd unit 把 `User=` / `Group=` 显式留空(`rustdesk-server/systemd/rustdesk-hbbs.service:10-11` 与 `rustdesk-server/systemd/rustdesk-hbbr.service:10-11`),systemd 默认以 root 启动进程。
  - 当前 unit 已有 `WorkingDirectory=/var/lib/rustdesk-server/`(`rustdesk-hbbs.service:9`),日志走 `StandardOutput=append:/var/log/rustdesk-server/hbbs.log`、`StandardError=append:/var/log/rustdesk-server/hbbs.error`(`rustdesk-hbbs.service:13-14`)。这两条决定了 `ReadWritePaths` 必须覆盖 `/var/lib/rustdesk-server` 与 `/var/log/rustdesk-server`。
  - `postinst` 仅 `mkdir -p` 这两个目录,未创建用户、也未 `chown`(`rustdesk-server-hbbs.postinst:7,12`、`rustdesk-server-hbbr.postinst:7,12`)。
  - `install` 清单只投递二进制 + service,不投递任何 sysusers/tmpfiles 文件(`rustdesk-server-hbbs.install:1-2`、`rustdesk-server-hbbr.install:1-2`)。
  - `debian/rules` 是最小化 dh 模板(`rustdesk-server/debian/rules:1-7`),无需修改即可承载新增脚本。
  - `prerm` / `postrm` 已在 stop/disable/purge 流程(`rustdesk-server-hbbs.prerm:7-10`、`rustdesk-server-hbbs.postrm:8-12`);purge 时清掉 `/var/lib/rustdesk-server/`。本任务**不**删除 `rustdesk` 系统用户(由系统管理员决定)。
  - FreeBSD rc.d 与 Docker entrypoint 不在 `debian/` 与 `systemd/` 目录路径内,本任务**显式不修改**。

## 3. 涉及文件清单

| 路径 | 动作 | 行数估计 | 说明 |
| --- | --- | --- | --- |
| `rustdesk-server/systemd/rustdesk-hbbs.service` | 修改 | +10 / -2 | 填 `User=rustdesk` / `Group=rustdesk`,新增沙箱与日志写入白名单 |
| `rustdesk-server/systemd/rustdesk-hbbr.service` | 修改 | +10 / -2 | 同上 |
| `rustdesk-server/debian/rustdesk-server-hbbs.postinst` | 修改 | +20 / -0 | 在 `configure` 分支创建 `rustdesk` 系统用户、`chown` 运行/日志目录 |
| `rustdesk-server/debian/rustdesk-server-hbbr.postinst` | 修改 | +20 / -0 | 同上(避免与 hbbs 重复 adduser,需 `getent` 守卫) |
| `rustdesk-server/debian/rustdesk-server-hbbs.install` | 不修改 | 0 | 现有 systemd unit 投递路径不变 |
| `rustdesk-server/debian/rustdesk-server-hbbr.install` | 不修改 | 0 | 同上 |
| `rustdesk-server/debian/rules` | 不修改 | 0 | dh 默认流程已能识别新增的 postinst 修改 |
| `rustdesk-server/debian/rustdesk-server-hbbs.postrm` | 不修改 | 0 | 不删除 `rustdesk` 用户;只清空 `/var/lib/rustdesk-server/`(已存在) |
| `rustdesk-server/debian/rustdesk-server-hbbr.postrm` | 不修改 | 0 | 同上 |
| `rustdesk-server/systemd/freebsd/*` | 未找到,无需新建 | - | 任务卡明确**不**修改 FreeBSD rc.d |
| `rustdesk-server/Dockerfile` / docker entrypoint | 未找到,本任务**不**修改 | - | 任务卡明确不破坏 Docker 路径;Docker 镜像不走 systemd,沙箱配置不影响 |
| `docs/ai-development-plan.md` | 修改(收尾) | +1 | 任务卡末尾追加 `状态: 完成 (commit <hash>)` |

## 4. 数据契约

### 4.1 systemd unit 字段约定

修改后的 `rustdesk-server/systemd/rustdesk-hbbs.service`(关键字段,逐项落到 `[Service]` 段):

```
User=rustdesk
Group=rustdesk
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictRealtime=true
SystemCallArchitectures=native
ReadWritePaths=/var/lib/rustdesk-server /var/log/rustdesk-server
```

`hbbr` 的 unit 字段集合与上完全一致(只是 ExecStart 不同)。

> 备注:`AmbientCapabilities` / `CapabilityBoundingSet` 暂不强制设置(目标 = 空),因为 hbbs/hbbr 现在不绑定 < 1024 端口,默认 21115-21119 不需要 `CAP_NET_BIND_SERVICE`。若后续要监听低端口,在该任务卡范围**外**再开 capability。

### 4.2 系统用户 / 目录契约

- 用户名:`rustdesk`(建议命名,既是默认 Linux 安装的惯用 system user,也与现有目录前缀一致;**可调整**,若调整需同步 unit `User=` / `Group=`)。
- 用户类型:`--system --no-create-home --shell /usr/sbin/nologin`。
- 主组:`rustdesk`(与用户同名,`--group`)。
- 运行目录:`/var/lib/rustdesk-server`,owner `rustdesk:rustdesk`,mode `0750`。
- 日志目录:`/var/log/rustdesk-server`,owner `rustdesk:rustdesk`,mode `0750`。
- 现存历史文件(老版本以 root 创建的 SQLite/key)在升级时需 `chown -R rustdesk:rustdesk /var/lib/rustdesk-server /var/log/rustdesk-server`,以保证沙箱启用后仍可读写。

### 4.3 postinst 脚本契约(shell 片段,采用幂等写法)

`rustdesk-server-hbbs.postinst` 与 `rustdesk-server-hbbr.postinst` 都需要插入下面这段,放在 `if [ "$1" = "configure" ]; then` 块内,`mkdir -p` 之前:

```sh
# 创建专用系统用户(幂等)
if ! getent passwd rustdesk >/dev/null; then
    adduser --system --group --no-create-home \
            --home /var/lib/rustdesk-server \
            --shell /usr/sbin/nologin \
            rustdesk
fi
```

在 `mkdir -p` 之后追加:

```sh
chown -R rustdesk:rustdesk /var/lib/rustdesk-server /var/log/rustdesk-server || true
chmod 0750 /var/lib/rustdesk-server /var/log/rustdesk-server || true
```

注:两个包都执行同一 `getent passwd rustdesk` 守卫,因此并不互相强依赖装包顺序;同包重复 `configure` 也安全。

## 5. 实现步骤

1. **修改 `rustdesk-server/systemd/rustdesk-hbbs.service`**:把 `User=` / `Group=`(`rustdesk-hbbs.service:10-11`)改为 `User=rustdesk` / `Group=rustdesk`;在 `Restart=always`(`:12`)之前或之后插入 §4.1 中列出的全部沙箱字段。保留现有 `WorkingDirectory`(`:9`)与 `StandardOutput`/`StandardError`(`:13-14`)不变。
2. **修改 `rustdesk-server/systemd/rustdesk-hbbr.service`**:对应位置(`:10-11`、`:12-14`)做同样修改;`ExecStart=/usr/bin/hbbr`(`:8`)保持不变。
3. **修改 `rustdesk-server/debian/rustdesk-server-hbbs.postinst`**:在第 6 行的 `if [ "$1" = "configure" ]; then` 块开头插入 §4.3 的 `getent passwd rustdesk` adduser 片段;在第 12 行 `mkdir -p /var/lib/rustdesk-server/` 之后,以及现有第 7 行的 `/var/log/rustdesk-server` 创建之后,追加 §4.3 的 `chown` 与 `chmod`(为简洁可把两条 mkdir 合并到一个分支,确保 chown 紧跟在两个 mkdir 之后)。
4. **修改 `rustdesk-server/debian/rustdesk-server-hbbr.postinst`**:与步骤 3 对称改造(同样使用 `getent passwd rustdesk` 守卫,保证两个包先后安装都不会重复创建用户)。
5. **本地验证 unit 文件**:在干净的 Linux 容器/虚机里 `cp` unit 到 `/etc/systemd/system/`,`systemctl daemon-reload`,`systemctl start rustdesk-hbbs`,`systemd-analyze security rustdesk-hbbs.service`,确认 Exposure 较改造前明显下降(< 6.0 视为达标)。本步骤在 macOS 上**跳过**(macOS 无 systemd)。
6. **本地验证 deb 安装流程**:在 Debian/Ubuntu 容器里 `dpkg -i` 构建产物,确认 `id rustdesk` 输出有效系统用户、`ls -ld /var/lib/rustdesk-server /var/log/rustdesk-server` 属主为 `rustdesk:rustdesk`、`ps -o user= -p $(pidof hbbs)` 返回 `rustdesk`。
7. **回归检查 docker-compose / Dockerfile**:`grep -R "rustdesk-hbbs.service\|rustdesk-hbbr.service" rustdesk-server/` 确认无 Dockerfile 引用这两个 unit;FreeBSD rc.d 不存在(`ls rustdesk-server/` 无 `freebsd/` 子目录),无需改动。
8. **任务卡收尾**:在 `docs/ai-development-plan.md:184-200` 末尾追加 `状态: 完成 (commit <hash>)`。

## 6. 测试用例

| # | 测试文件路径 | 测试名 | 输入 | 期望 |
| --- | --- | --- | --- | --- |
| 1 | `rustdesk-server/tests/packaging/test_postinst.sh`(未找到,需新建) | `test_postinst_creates_rustdesk_user` | 在干净 Debian 容器 `dpkg -i rustdesk-server-hbbs_*.deb` | `getent passwd rustdesk` 返回非空;`stat -c '%U:%G' /var/lib/rustdesk-server` = `rustdesk:rustdesk`;`systemctl is-active rustdesk-hbbs` = `active` |
| 2 | 同上 | `test_postinst_idempotent_on_reinstall` | 第二次 `dpkg -i` 同一 deb,且先手动 `userdel -r rustdesk || true` 不要执行(模拟普通升级) | postinst 不报错;`getent passwd rustdesk` 仍存在;目录属主仍为 `rustdesk:rustdesk` |
| 3 | 同上 | `test_postinst_both_packages_share_user` | 先装 hbbs deb 后装 hbbr deb | hbbr 安装日志中无 `adduser` 错误;`id rustdesk` 仍为同一 UID;`/var/log/rustdesk-server` 由两服务共享写入 |
| 4 | `rustdesk-server/tests/packaging/test_systemd_security.sh`(未找到,需新建) | `test_hbbs_runs_as_rustdesk` | 启动 `rustdesk-hbbs.service` | `ps -o user= -p $(systemctl show -p MainPID --value rustdesk-hbbs)` 输出 `rustdesk`;`systemd-analyze security rustdesk-hbbs.service` 的 Exposure 较 baseline 下降 ≥ 3.0 |
| 5 | 同上 | `test_hbbs_cannot_write_outside_readwritepaths` (失败模式) | 让 hbbs 进程通过自定义二进制尝试 `touch /etc/hbbs-leak` | 写入失败 (`EROFS` / `EPERM`);进程仍正常运行 |
| 6 | 同上 | `test_hbbs_can_write_log_and_db` (向后兼容 happy path) | 启动 hbbs,等待 30 秒 | `/var/log/rustdesk-server/hbbs.log` 与 `hbbs.error` 文件存在且 owner = `rustdesk:rustdesk`;`/var/lib/rustdesk-server/` 下生成的 sqlite/key 文件 owner = `rustdesk:rustdesk` |
| 7 | 同上 | `test_upgrade_from_root_owned_state` (向后兼容) | 模拟老部署:`chown -R root:root /var/lib/rustdesk-server`,放置一个旧 `id_ed25519` 私钥,然后再次 `dpkg -i` 新版本 | postinst 完成后该私钥 owner = `rustdesk:rustdesk`,hbbs 重启后能读取并继续使用同一 key(`hbbs.log` 中无 permission denied) |
| 8 | 同上 | `test_purge_does_not_remove_user` | `apt-get purge rustdesk-server-hbbs rustdesk-server-hbbr` | `getent passwd rustdesk` 仍返回非空(由系统管理员决定何时删除) |

> 备注:这些都是 shell 集成测试,需要 systemd + dpkg 环境;在 CI 中可用 Docker `systemd:latest` 镜像或 vagrant 节点执行。无单元测试可加。

## 7. 验证命令

按顺序执行(在 Debian/Ubuntu 测试节点;macOS 开发盒标注 SKIP):

```bash
# 1) 构建 deb(macOS 可 SKIP:dpkg-buildpackage 不在 mac 工具链中)
cd rustdesk-server
dpkg-buildpackage -b -us -uc

# 2) 安装新包(macOS SKIP:无 dpkg/systemd)
sudo dpkg -i ../rustdesk-server-hbbs_*.deb ../rustdesk-server-hbbr_*.deb

# 3) 检查系统用户与目录属主(macOS SKIP)
getent passwd rustdesk
ls -ld /var/lib/rustdesk-server /var/log/rustdesk-server

# 4) 检查进程 user(macOS SKIP)
ps -o user= -p "$(systemctl show -p MainPID --value rustdesk-hbbs)"
ps -o user= -p "$(systemctl show -p MainPID --value rustdesk-hbbr)"

# 5) systemd 安全打分(macOS SKIP:无 systemd-analyze)
systemd-analyze security rustdesk-hbbs.service
systemd-analyze security rustdesk-hbbr.service

# 6) 静态校验 unit(macOS SKIP)
systemd-analyze verify rustdesk-server/systemd/rustdesk-hbbs.service
systemd-analyze verify rustdesk-server/systemd/rustdesk-hbbr.service

# 7) 语法校验 shell(macOS 可执行,推荐)
shellcheck rustdesk-server/debian/rustdesk-server-hbbs.postinst
shellcheck rustdesk-server/debian/rustdesk-server-hbbr.postinst

# 8) 旧 root 拥有状态的兼容性(macOS SKIP)
sudo chown -R root:root /var/lib/rustdesk-server
sudo dpkg-reconfigure rustdesk-server-hbbs
sudo dpkg-reconfigure rustdesk-server-hbbr
ls -ld /var/lib/rustdesk-server   # 应回到 rustdesk:rustdesk
```

macOS 跳过原因:macOS 无 systemd 守护进程,也无 dpkg 工具链;`shellcheck` 在 macOS 上可通过 brew 安装并执行,作为基本静态校验。

## 8. 兼容性 / 安全注意事项

- **Protobuf 兼容**:本任务不涉及任何 protobuf 字段;hbbs/hbbr 进程内行为与外部协议无变更。
- **老客户端 / 老服务端互通**:外部网络协议(NAT 打洞、relay)与端口号都未变化,老客户端无感知;集群中混跑老 hbbs 与新 hbbs 不受影响。
- **旧部署升级**:
  - 历史以 root 创建的 `/var/lib/rustdesk-server/` 下文件(SQLite、`id_ed25519`、`id_ed25519.pub` 等)必须在 postinst 末尾 `chown -R rustdesk:rustdesk`,否则启用 `ProtectSystem=strict` + `User=rustdesk` 后服务无法写入 SQLite 或读取私钥。
  - `ReadWritePaths` 必须包含 `/var/lib/rustdesk-server` 与 `/var/log/rustdesk-server`(`rustdesk-hbbs.service:9,13-14` 双重依赖)。`/var/log/rustdesk-server` 不能漏,否则 `StandardOutput=append:` 会因 `ProtectSystem=strict` 写失败。
- **数据库迁移回滚**:无数据库 schema 变更,因此无 migration。回滚仅靠 unit / postinst 文件还原(见 §9)。
- **敏感字段不落盘**:密钥仍位于 `/var/lib/rustdesk-server/`,目录权限 `0750` + owner `rustdesk:rustdesk` 已足够;`PrivateTmp=true` 阻断 `/tmp` 泄露;`ProtectHome=true` 阻断访问 `/home`、`/root`、`/run/user`;`NoNewPrivileges=true` 阻断 setuid 提权。
- **限流**:无新增 RPC 入口,无需限流。
- **FreeBSD / Docker 不动**:`debian/` 与 `systemd/` 目录范围之外的文件本任务**不修改**。Docker 镜像内进程通常 PID 1 即 hbbs,不走 systemd,不受这些选项影响。FreeBSD rc.d 脚本不存在于本仓库,无需考虑。
- **能力下放注意**:若以后要监听 < 1024 端口,需在 unit 中显式 `AmbientCapabilities=CAP_NET_BIND_SERVICE` 并相应放宽 `CapabilityBoundingSet`;本任务暂不开口。
- **purge 行为**:`postrm purge` 会删除 `/var/lib/rustdesk-server/`(`rustdesk-server-hbbs.postrm:9`),但**不**删除 `rustdesk` 用户。这是有意的,避免在多 deb 共用同一用户时出错;清理用户由运维显式 `userdel` 处理。

## 9. 回滚方案

1. **代码层回滚**:`git revert <commit>`,只需还原 unit 文件与两个 postinst 即可,无 migration、无 feature flag。
2. **运行时回滚**(已在生产升级到加固版本后想回退):
   - `apt-get install --reinstall rustdesk-server-hbbs=<old-version>`,旧 unit 把 `User=` / `Group=` 留空 → 服务退回 root 运行。
   - 因目录在加固版本中变为 `rustdesk:rustdesk`,root 仍能访问,不影响读写。
   - `rustdesk` 系统用户保留即可,无副作用。
3. **配置开关回滚**(不需要重新打包):在 `/etc/systemd/system/rustdesk-hbbs.service.d/override.conf` 写入:

   ```
   [Service]
   User=
   Group=
   ProtectSystem=
   ReadWritePaths=
   NoNewPrivileges=false
   ```

   然后 `systemctl daemon-reload && systemctl restart rustdesk-hbbs`,即可单机临时关闭加固而不动包。

## 10. 完成定义 (DoD)

- [ ] `rustdesk-server/systemd/rustdesk-hbbs.service` 已设置 `User=rustdesk` / `Group=rustdesk` 与 §4.1 沙箱字段全集,`systemd-analyze verify` 无报错。
- [ ] `rustdesk-server/systemd/rustdesk-hbbr.service` 同上。
- [ ] 两个 `postinst` 已加 `getent passwd rustdesk || adduser --system --group --no-create-home --shell /usr/sbin/nologin --home /var/lib/rustdesk-server rustdesk` 守卫,并在 `mkdir -p` 之后 `chown -R rustdesk:rustdesk` 两个目录。
- [ ] `shellcheck` 通过两个 postinst。
- [ ] 在 Debian/Ubuntu 节点上执行 §7 命令 1-6,`systemd-analyze security` 报告 Exposure 较 baseline 下降 ≥ 3.0,且服务可正常启动并接受连接。
- [ ] §6 测试 #1 / #2 / #4 / #6 / #7 在 CI 或本地容器内通过(失败模式 #5、purge 行为 #8 至少手验一次)。
- [ ] Docker / FreeBSD 相关文件未被改动:`git diff --name-only` 输出只在 `rustdesk-server/systemd/` 与 `rustdesk-server/debian/` 路径下。
- [ ] 在 `docs/ai-development-plan.md` 的 `### CE-M0-5 systemd 加固` 任务卡(`docs/ai-development-plan.md:184-200`)末尾追加 `状态: 完成 (commit <hash>)`。
