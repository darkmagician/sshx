# sshx 服务端部署指南

本文描述如何在 Linux 服务器上编译 sshx 服务端(Rust 后端 + SvelteKit 前端),并以 systemd 服务方式运行,同时使用 Nginx 提供 HTTPS 访问。

文中的示例参数:

| 项目 | 示例值 |
|---|---|
| 源码目录 | `/root/sshx` |
| 安装目录 | `/opt/sshx` |
| 服务器内网 IP | `192.168.1.199` |
| 后端监听地址 | `192.168.1.199:8051` |
| Nginx HTTPS 端口 | `8443` |

> 请按实际环境替换 IP、端口和路径。

## 1. 环境要求

| 依赖 | 要求 | 说明 |
|---|---|---|
| Rust | stable | 用于编译服务端 |
| protoc | 3.x(建议 25.x) | `crates/sshx-core/build.rs` 编译 `.proto` 时必需 |
| Node.js | 18+ | 构建前端;仓库 CI 使用 Node 18 |
| npm | 9+ | 前端依赖安装 |
| git | 任意版本 | `vite.config.ts` 构建时执行 `git rev-parse` |
| Nginx | 任意 | HTTPS 反向代理 |
| OpenSSL | 1.1.1+ | 生成自签证书 |

本机已安装的工具链位置(脚本会自动识别):

- Rust:`/root/.cargo/bin`
- protoc:`/root/.local/protoc-25.3/bin`

若尚未安装:

```bash
# Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal

# protoc 25.3
mkdir -p /root/.local/protoc-25.3
curl -fL -o /tmp/protoc.zip \
  https://github.com/protocolbuffers/protobuf/releases/download/v25.3/protoc-25.3-linux-x86_64.zip
unzip -o /tmp/protoc.zip -d /root/.local/protoc-25.3
```

## 2. 编译

### 2.1 一键构建

```bash
cd /root/sshx
./build_server.sh
```

脚本会依次执行:

1. 构建前端:`npm ci && npm run build`
2. 构建后端:`cargo build --release --bin sshx-server`
3. 组装产物到 `dist/`

可选参数:

```bash
./build_server.sh --skip-frontend   # 只构建后端
./build_server.sh --skip-backend    # 只构建前端
./build_server.sh --help
```

### 2.2 产物结构

```
dist/
├── sshx-server    # 服务端二进制(约 11 MB,已 strip)
└── build/         # 前端静态资源(含 spa.html 与 .gz/.br 预压缩文件)
```

> **重要**:前端没有编译进二进制。`sshx-server` 在运行时从**当前工作目录**读取 `build/`(见 `crates/sshx-server/src/web.rs`)。因此必须保证 `sshx-server` 与 `build/` 位于同一工作目录,并由 systemd 的 `WorkingDirectory` 指定该目录。否则客户端仍能连接,但网页会返回 404。

## 3. 安装

```bash
sudo useradd --system --no-create-home --shell /sbin/nologin sshx 2>/dev/null || true

sudo mkdir -p /opt/sshx
sudo install -m 755 /root/sshx/dist/sshx-server /opt/sshx/sshx-server
sudo rm -rf /opt/sshx/build
sudo cp -a /root/sshx/dist/build /opt/sshx/build
sudo chown -R root:root /opt/sshx
```

最终目录:

```
/opt/sshx/
├── sshx-server
└── build/
```

## 4. 配置环境变量

至少需要固定 `SSHX_SECRET`。若未设置,服务每次启动都会随机生成密钥,导致重启后旧会话链接全部失效;多节点部署时也必须使用相同密钥。

```bash
sudo mkdir -p /etc/sshx
sudo sh -c 'echo "SSHX_SECRET=$(/usr/bin/openssl rand -hex 32)" > /etc/sshx/sshx.env'
sudo chmod 600 /etc/sshx/sshx.env
```

可选的配置项(写入同一文件):

```bash
# 日志级别
RUST_LOG=info
# 多节点时启用 Redis(单机可省略)
# SSHX_REDIS_URL=redis://127.0.0.1:6379/
```

> 不要将 `SSHX_SECRET` 提交到仓库或泄露给他人。

## 5. 安装 systemd 服务

创建 `/etc/systemd/system/sshx.service`:

```ini
[Unit]
Description=sshx server (web-based collaborative terminal)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=sshx
Group=sshx

# 关键:工作目录必须包含 build/
WorkingDirectory=/opt/sshx
ExecStart=/opt/sshx/sshx-server --listen 192.168.1.199 --port 8051

EnvironmentFile=/etc/sshx/sshx.env

Restart=on-failure
RestartSec=3
LimitNOFILE=65536

# 安全加固(服务不需要写文件系统)
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true

[Install]
WantedBy=multi-user.target
```

说明:

- `--listen 192.168.1.199`:允许其他机器上的命令行客户端直连 gRPC。若客户端只在服务器本机运行,可改为 `--listen 127.0.0.1`,并把 Nginx 的 `proxy_pass` 改为 `http://127.0.0.1:8051`(此时代理端口不再对外暴露)。
- 不要省略 `WorkingDirectory`,否则网页 404。
- 默认端口为 8051,可用 `--port` 修改。

启用并启动:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now sshx
sudo systemctl status sshx
```

查看日志:

```bash
sudo journalctl -u sshx -f
```

## 6. 配置 Nginx HTTPS 反向代理

浏览器的 WebCrypto(`crypto.subtle`)只在安全上下文中可用。通过 `http://192.168.1.199:8051` 直接访问时,`crypto.subtle` 为 `undefined`,页面会报:

```
TypeError: Cannot read properties of undefined (reading 'importKey')
```

因此网页必须通过 HTTPS 访问。服务端本身不提供 TLS,需要 Nginx 终止 TLS。

### 6.1 生成自签证书

```bash
sudo mkdir -p /etc/nginx/ssl
sudo /usr/bin/openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
  -keyout /etc/nginx/ssl/sshx.key \
  -out    /etc/nginx/ssl/sshx.crt \
  -subj   "/CN=192.168.1.199" \
  -addext "subjectAltName=IP:192.168.1.199"
sudo chmod 600 /etc/nginx/ssl/sshx.key
```

### 6.2 新建 `/etc/nginx/conf.d/sshx.conf`

```nginx
# WebSocket 升级头(CentOS 默认 conf.d 位于 http 上下文内)
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 8443 ssl;
    server_name 192.168.1.199;

    ssl_certificate     /etc/nginx/ssl/sshx.crt;
    ssl_certificate_key /etc/nginx/ssl/sshx.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    # 注意:不要在此 vhost 开启 http2,
    # nginx 1.14 的 HTTP/2 不支持 WebSocket 升级。

    location / {
        # 与 systemd 中 --listen 的地址保持一致
        proxy_pass http://192.168.1.199:8051;
        proxy_http_version 1.1;

        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # 终端 WebSocket(/api/s/<id>)
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection $connection_upgrade;

        # 终端为长连接,避免默认 60 秒断开
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering    off;
    }
}
```

### 6.3 校验并应用

```bash
sudo nginx -t
sudo systemctl enable --now nginx
sudo systemctl reload nginx
```

如果服务器启用了 SELinux(RHEL/CentOS 默认可能为 enforcing),需允许 Nginx 访问后端并修正证书上下文:

```bash
sudo setsebool -P httpd_can_network_connect 1
sudo restorecon -Rv /etc/nginx/ssl
```

如果启用了 firewalld,需放行端口:

```bash
sudo firewall-cmd --permanent --add-port=8443/tcp
sudo firewall-cmd --reload
```

## 7. 验证

### 7.1 后端直连

```bash
curl --noproxy '*' -o /dev/null -w '%{http_code}\n' http://192.168.1.199:8051/spa.html
# 期望:200
```

> `--noproxy '*'` 用于跳过系统 HTTP 代理;若当前环境未设置 `http_proxy` 可省略。

### 7.2 Nginx HTTPS 反代

```bash
curl --noproxy '*' -k -o /dev/null -w '%{http_code}\n' https://192.168.1.199:8443/
curl --noproxy '*' -k -o /dev/null -w '%{http_code}\n' https://192.168.1.199:8443/spa.html
# 均期望:200
```

`-k` 用于忽略自签证书校验,仅用于测试。

### 7.3 服务状态

```bash
systemctl is-active sshx nginx
ss -ltn | grep -E ':(8051|8443)\b'
```

## 8. 客户端连接

客户端不需要修改代码,但必须通过 `--override-origin` 让服务端生成 HTTPS 网页链接:

```bash
cd /root/sshx
./target/release/sshx \
  --server http://192.168.1.199:8051 \
  --override-origin https://192.168.1.199:8443
```

打印出的链接形如:

```
https://192.168.1.199:8443/s/<id>#<key>
```

在浏览器中打开即可。首次访问自签证书会提示不安全,选择"高级 → 继续前往"。如需消除警告,可将 `sshx.crt` 导入操作系统或浏览器的受信任根证书。

注意:

- `--server` 必须是后端根地址,用于 gRPC 连接与断线重连,不能写成 HTTPS 反代地址(自签证书会被 tonic 的 webpki 根证书校验拒绝)。
- `--override-origin` 末尾不要加斜杠。

## 9. 升级

```bash
cd /root/sshx
git pull                 # 如需更新源码
./build_server.sh

sudo systemctl stop sshx
sudo install -m 755 dist/sshx-server /opt/sshx/sshx-server
sudo rm -rf /opt/sshx/build
sudo cp -a dist/build /opt/sshx/build
sudo systemctl start sshx
```

> 单机内存模式下,重启服务会丢失所有会话,客户端需要重新运行以生成新链接。若需保留会话,请部署 Redis 并设置 `SSHX_REDIS_URL`。

## 10. 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| 客户端能连,网页 404 | `WorkingDirectory` 下缺少 `build/` | 确认 `/opt/sshx/build/spa.html` 存在,检查 unit 的 `WorkingDirectory` |
| 浏览器报 `crypto.subtle` / `importKey` 未定义 | 通过 HTTP 访问,不是安全上下文 | 使用 `https://` 访问;`http://localhost` 也可 |
| Nginx 返回 502 | Nginx 连不到后端 | 检查 `--listen` 与 `proxy_pass` 地址是否一致;`ss -ltn` 查看端口;SELinux 是否允许 `httpd_can_network_connect` |
| Nginx 返回 503 | 请求被上游代理/错误地址拦截 | 检查浏览器或 curl 是否走了系统代理 |
| 终端连接几秒后断开 | 代理超时 | 确认 `proxy_read_timeout` 已加长,且未开启 http2 |
| 重启后旧链接全部失效 | `SSHX_SECRET` 未固定,或使用内存存储 | 配置 `/etc/sshx/sshx.env`;多节点/持久化需 Redis |
| 证书警告 | 自签证书 | 浏览器手动信任,或导入证书到系统信任库 |

## 附:最终文件清单

```
/opt/sshx/
├── sshx-server
└── build/                      # 前端静态资源

/etc/sshx/sshx.env              # SSHX_SECRET 等环境变量(600)
/etc/systemd/system/sshx.service
/etc/nginx/conf.d/sshx.conf
/etc/nginx/ssl/sshx.crt
/etc/nginx/ssl/sshx.key
```
