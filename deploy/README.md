# RustDesk CE 自托管部署

针对 **个人 / 小团队** 的自托管栈,一键起 `hbbs + hbbr + rustdesk-api`,可选叠加 Caddy(自动 HTTPS)、PostgreSQL、Prometheus + Grafana、Client Builder。

> 镜像 = 本地 `docker buildx build`(源码就在隔壁三个子仓);不强依赖 GHCR。
> 默认数据库 = SQLite(零运维);需要切 PostgreSQL 时套 profile。
> 默认 **不** 开 TLS;公网部署套 `profiles/caddy.yml`。
> 默认 **不** 启 metrics 端口映射,需要时套 `profiles/metrics.yml`。

---

## 目录结构

```
deploy/
├── .env.example                # 可调参数模板;copy .env 后编辑
├── docker-compose.yml          # 主 compose(core profile)
├── Dockerfile.server           # 多 target:hbbs / hbbr
├── Dockerfile.api              # rustdesk-api(CGO + SQLite)
├── build.sh                    # 本地 buildx 三个镜像
├── scripts/
│   ├── gen-secrets.sh          # 生成 secrets/(admin_token / mfa_encryption_key / jwt_signing_key / postgres_password)
│   ├── init.sh                 # 一键 build + gen-secrets + 分阶段启动
│   └── show-info.sh            # 打印 Configuration String / 后台 URL
├── secrets/                    # 运行时密钥(.gitignore'd)
├── data/                       # 运行时数据(.gitignore'd)
│   ├── server/                 # hbbs/hbbr 的 id_ed25519 / id_*.json / *.db
│   └── api/                    # rustdesk-api 的 db_v2.sqlite3 / 资源
└── profiles/
    ├── caddy.yml               # 反代 + 自动 HTTPS
    ├── caddy/Caddyfile
    ├── metrics.yml             # Prometheus + Grafana
    ├── metrics/prometheus.yml
    ├── postgres.yml            # 切 PostgreSQL
    └── builder.yml             # 启用 Client Builder
```

---

## 5 分钟跑通(本机 / 内网)

```bash
cd deploy

# 一把梭:cp .env.example .env → gen-secrets → buildx 三个镜像 → 起 hbbs/hbbr → 拿公钥 → 起 api
./scripts/init.sh

# 看连接信息(粘到客户端就能用)
./scripts/show-info.sh
```

跑完 `init.sh` 之后 host 上能看到:

| 端口 | 协议 | 服务 | 用途 |
|------|------|------|------|
| 21115 | TCP | hbbs | NAT 测试 |
| 21116 | TCP+UDP | hbbs | ID/Hole punch |
| 21117 | TCP | hbbr | Relay |
| 21118 | TCP | hbbs | WebSocket(浏览器客户端) |
| 21119 | TCP | hbbr | WebSocket relay |
| 21114 | TCP | rustdesk-api | REST + 后台 |

metrics 端口(21120 hbbs / 21121 hbbr / 21115 api)**默认不映射到 host**,只在 docker 网内可达,需要 Prometheus 抓时套 `profiles/metrics.yml`。

---

## 常用命令

```bash
# 起 / 停
docker compose up -d
docker compose down
docker compose ps
docker compose logs -f hbbs

# 重建镜像(只改了 server 代码)
./build.sh hbbs hbbr
docker compose up -d hbbs hbbr

# 重新生成全部 secret(谨慎,会让既有客户端的 mfa 解不开)
./scripts/gen-secrets.sh --force

# 进 hbbs 用 admin CLI(CE-M0-7)
docker compose exec hbbs sh -c '\
  RUSTDESK_SERVER_ADMIN_TOKEN_FILE=/run/secrets/admin_token \
  hbbs --admin-cli "list-peers --limit 10"'
```

---

## 自定义连接参数

打开 `deploy/.env`:

```dotenv
SERVER_HOST=rustdesk.example.com    # 客户端要解析的地址(内网就填 IP / 127.0.0.1)
HBBS_TCP_PORT=21116
API_PORT=21114
ADMIN_USERNAME=admin
ADMIN_PASSWORD=please-change-me     # 首次启动写库,后续改要走 Web Admin
```

改完后 `docker compose up -d` 即可。`RUSTDESK_PUB_KEY` 由 `init.sh` 自动写入,**别**手改。

---

## 加 HTTPS(公网部署)

1. DNS 把 `SERVER_HOST` 指向本机。
2. `.env` 里把 `SERVER_HOST` 改成域名。
3. 可选 `ACME_EMAIL=you@example.com`(给 Let's Encrypt 用)。
4. 启:

   ```bash
   docker compose -f docker-compose.yml -f profiles/caddy.yml up -d
   ```

`profiles/caddy/Caddyfile` 已经把:

- `/api/*`、`/_admin/*`、`/swagger/*` → `rustdesk-api:21114`
- `/ws/id/*` → `hbbs:21118`(浏览器客户端)
- `/ws/relay/*` → `hbbr:21119`

接到 443。**hbbs/hbbr 的 21116/21117 是原始 TCP+UDP,不能走 HTTP CDN,继续按原端口直连。**

---

## 切 PostgreSQL

1. 备份 `./data/api/db_v2.sqlite3`(rustdesk-api 没有自动迁移,要手动导)。
2. 在 `secrets/postgres_dsn` 里写一行 DSN(参考 `profiles/postgres.yml` 末尾的注释)。
3. 启:

   ```bash
   docker compose -f docker-compose.yml -f profiles/postgres.yml up -d
   ```

---

## 加 Prometheus + Grafana

```bash
docker compose -f docker-compose.yml -f profiles/metrics.yml up -d
```

- Prometheus → `http://${SERVER_HOST}:9090`
- Grafana → `http://${SERVER_HOST}:3000`(默认 admin/admin,改密)
- Prometheus 已配好 3 个 scrape job(hbbs/hbbr/rustdesk-api)。

---

## Client Builder

```bash
# 1. 把官方安装包放到 deploy/builder/base/ 下(命名见 rustdesk-api 文档)
mkdir -p builder/base
cp ~/Downloads/rustdesk-1.4.0-x86_64.exe builder/base/

# 2. 启
docker compose -f docker-compose.yml -f profiles/builder.yml up -d
```

进 Web Admin → Client Builder 就能挑基础包、签发个性化客户端。

---

## 升级 / 回滚

```bash
# 升级:拉最新源码 → 重 build → up -d
git -C ../rustdesk-server pull --rebase
git -C ../rustdesk-api    pull --rebase
./build.sh
docker compose up -d

# 回滚:重新 build 旧 tag,或直接换镜像 tag
IMAGE_TAG=v0.1.0 ./build.sh
IMAGE_TAG=v0.1.0 docker compose up -d
```

历史镜像 tag 在 `docker images | grep rustdesk-ce` 里。

---

## 数据 / 密钥位置

| 内容 | 路径 | 备份建议 |
|------|------|----------|
| hbbs 私钥 | `data/server/id_ed25519` | **必备份**,丢了所有客户端要重配 |
| hbbs DB | `data/server/db.sqlite3` | 在线 sqlite3 .backup |
| api DB | `data/api/db_v2.sqlite3` | 同上(或 pg_dump if PG) |
| API 密钥 | `secrets/*` | **必备份**,丢了登录 ticket / MFA 解不开 |

---

## 排障速查

```bash
# 都活着吗
docker compose ps

# 日志
docker compose logs -f hbbs
docker compose logs -f rustdesk-api

# 容器内连通
docker compose exec rustdesk-api curl -fsS http://hbbs:21118/

# metrics 也能从 api 容器内拉
docker compose exec rustdesk-api curl -fsS http://hbbs:21120/metrics | head

# 重置 admin 密码(只清 rustdesk-api 的 users 表里的 admin 行,然后重启写回默认)
docker compose exec rustdesk-api /app/apimain reset-admin --user admin --password new-pass
```

---

## 安全清单(上线前 5 项)

1. **改默认 admin 密码**(`.env` 里 `ADMIN_PASSWORD=`,首次启动后立刻进后台改一次)。
2. **备份 `data/server/id_ed25519` 和 `secrets/`**(整个 `deploy/secrets/` tar 一份,异地)。
3. **公网部署套 Caddy**(`profiles/caddy.yml`),21114 不要直接暴露。
4. **MFA 默认关**;在后台按用户/全局打开后才生效(CE-M1-1)。
5. **metrics 端口不要映射到 host**(默认就没映射,加 `profiles/metrics.yml` 也是内网抓)。
