# WebStack 一键部署脚本

`webstack-deploy` 是适用于 Debian 11/12/13 的交互式一键初始化与网站部署脚本。

它会先把 VPS 初始化成可部署环境，然后安装 `deploy` 命令。以后添加网站只需要在 SSH 中运行：

```bash
deploy
```

脚本不会安装 MySQL、MariaDB 或任何数据库服务。

## 功能

- 必装：Nginx
- 必装：Certbot / Let's Encrypt 自动续签
- 可选：Fail2ban，默认启用
- 可选：Swap，按内存和磁盘自动给出建议值
- 可选：PHP 8.x，添加网站时按需启用，自动检测仓库中最新 PHP 8.x
- 后续新增网站命令：`deploy`

## 系统要求

- Debian 11、Debian 12 或 Debian 13
- root 用户执行
- 服务器 80 和 443 端口已开放
- 添加网站前，域名需要解析到 VPS

## 一键运行

```bash
wget -O webstack-deploy.sh https://raw.githubusercontent.com/ImXcopter/webstack-deploy/main/webstack-deploy.sh && chmod +x webstack-deploy.sh && bash webstack-deploy.sh
```

如果 VPS 的 CA 证书环境过旧，可以使用：

```bash
wget --no-check-certificate -O webstack-deploy.sh https://raw.githubusercontent.com/ImXcopter/webstack-deploy/main/webstack-deploy.sh && chmod +x webstack-deploy.sh && bash webstack-deploy.sh
```

## 首次初始化流程

首次运行脚本时，流程是：

```text
=== 系统初始化 ===

1. 检查 root 权限
2. 检查 Debian 版本
3. 更新系统软件包，必做，不询问
4. 检测内存、磁盘、已有 Swap
5. 根据硬件给出 Swap 建议，用户输入大小或输入 0 跳过
6. 询问是否安装并启用 Fail2ban，默认 Y
7. 输入 Let's Encrypt 邮箱，必填
8. 安装 Nginx / Certbot / Fail2ban 如果启用
9. 配置服务和开机自启动
10. 安装 deploy 命令
```

初始化完成后会询问：

```text
是否现在添加第一个网站？[Y/n]:
```

选择 `Y` 会进入添加网站流程；选择 `n` 后，以后可以手动运行 `deploy`。

## 添加网站流程

运行：

```bash
deploy
```

运行 `deploy` 后，脚本会先读取初始化配置，确认 Nginx / Certbot / Fail2ban 等基础组件，再进入站点交互。

交互内容：

```text
=== 添加网站 ===

请输入域名:
是否为这个网站启用 PHP 8.x？[y/N]:
```

脚本会自动：

- 检查 DNS 是否指向当前 VPS
- 创建网站目录
- 创建 Nginx 配置
- 申请 Let's Encrypt 证书
- 写入 HTTPS 配置
- 加入 Certbot 自动续签体系

网站目录默认是：

```text
/var/www/你的域名
```

这个域名目录就是 Nginx 的网站根目录，脚本不会再追加 `/html`。脚本不会生成自定义默认页面，目录会保持为空。你可以直接把网站文件上传到这个目录。

为了方便 WinSCP 进入网站目录，脚本会尝试创建快捷软链接：

```text
/root/www -> /var/www
```

如果 `/root/www` 已经存在普通文件或普通目录，脚本不会覆盖它，只会跳过这个快捷入口。

## Swap 策略

如果系统已经有 active swap，脚本不会修改。

如果没有 active swap，脚本会根据硬件给出建议值：

- 内存 <= 1024 MB：建议 1024 MB
- 内存 1024 MB 到 2048 MB：建议 1024 MB
- 内存 2048 MB 到 4096 MB：建议 512 MB
- 内存 > 4096 MB：默认建议 0，不创建
- 根分区可用空间 < 3072 MB：默认建议 0，并避免占用磁盘

交互示例：

```text
检测到内存：964 MB
检测到磁盘可用空间：28000 MB
检测到当前没有 active swap
建议创建 Swap：1024 MB
请输入 Swap 大小（单位：MB，直接回车使用建议值/默认值，输入 0 表示不创建）[1024]:
```

可以输入：

- `0`：不创建
- `512`：创建 512 MB
- `1024`：创建 1024 MB

方括号中的 `1024` 是脚本根据当前系统检测结果给出的建议值，也是直接回车时会使用的默认值；单位是 MB。

创建后会写入 `/etc/fstab`，重启后自动启用，并设置：

```text
vm.swappiness = 10
```

## PHP 说明

交互里会显示为“PHP 8.x”，因为这是用户真正关心的能力。

技术上，Nginx 运行 PHP 需要 PHP-FPM 服务。脚本会：

- 添加 `packages.sury.org/php` 仓库
- 自动检测最新可用的 `php8.*-fpm`
- 安装 PHP 运行环境和常用非数据库扩展
- 如果某个扩展包不存在，例如独立 `php8.5-opcache` 不存在，则跳过；OPcache 可能已随核心包提供
- 对 1024 MB 内存 VPS 应用低内存 PHP 配置

脚本仍然不会安装任何 MySQL/MariaDB 模块。

## 默认路径

网站目录：

```text
/var/www/你的域名
```

WinSCP 快捷目录：

```text
/root/www -> /var/www
```

Nginx 配置：

```text
/etc/nginx/sites-available/你的域名
/etc/nginx/sites-enabled/你的域名
```

证书路径：

```text
/etc/letsencrypt/live/你的域名/
```

初始化配置：

```text
/etc/webstack-deploy/config
```

deploy 命令：

```text
/usr/local/bin/deploy
```

## 非交互示例

初始化并立即添加一个静态网站：

```bash
DOMAIN=example.com LE_EMAIL=admin@example.com INSTALL_PHP=0 ENABLE_FAIL2BAN=1 ASSUME_YES=1 bash webstack-deploy.sh
```

初始化并立即添加一个 PHP 8.x 网站：

```bash
DOMAIN=example.com LE_EMAIL=admin@example.com INSTALL_PHP=1 ENABLE_FAIL2BAN=1 ASSUME_YES=1 bash webstack-deploy.sh
```

指定 Swap：

```bash
DOMAIN=example.com LE_EMAIL=admin@example.com INSTALL_PHP=1 SWAP_SIZE=1024 ASSUME_YES=1 bash webstack-deploy.sh
```

只初始化系统，不添加网站：

```bash
LE_EMAIL=admin@example.com ADD_FIRST_SITE=0 ASSUME_YES=1 bash webstack-deploy.sh
```

## 常用检查命令

```bash
systemctl status nginx --no-pager
systemctl status fail2ban --no-pager
systemctl status certbot.timer --no-pager
certbot certificates
swapon --show
deploy
```

如果启用了 PHP：

```bash
php -v
systemctl status php8.5-fpm --no-pager
```

实际 PHP-FPM 服务名以脚本安装的版本为准，例如 `php8.5-fpm`。
