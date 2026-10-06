# 个人 Linux 服务运维与监控实践

> **项目周期**：2026.09.30 – 2026.10.07
> **项目性质**：个人学习实践项目（自建虚拟机环境，**非企业生产环境**）
> **作者**：高文博 ｜ 联系：a19902313867@163.com
> **环境**：VMware Workstation Pro + Ubuntu Server 22.04.5 LTS

---

## 一、项目背景与目标

本人为 2027 届专科在读学生，意向岗位为 IT 运维 / 桌面运维 / 系统运维方向。因缺少企业实习经历，为验证并展示实际动手能力，在本地虚拟机上自建本项目。

**目标**：在独立 Linux 环境中完整走通四条主线——
**服务部署 → 数据库与权限 → 监控告警 → 自动化运维**，并把全过程的问题定位过程留档。

**技术栈**：Ubuntu Server 22.04.5 LTS ｜ Nginx 1.18 ｜ MySQL 8.0 ｜ Node Exporter ｜ Prometheus 2.31 ｜ Grafana 13.2 ｜ Bash + crontab

---

## 二、环境与架构

### 环境清单（实测）

| 项 | 配置 |
|---|---|
| 宿主环境 | Windows 10 Pro / AMD R5 5600 / 16GB 内存 |
| 虚拟化 | VMware Workstation **Pro** 26H1（NAT 模式） |
| 客户机系统 | Ubuntu Server **22.04.5 LTS**，内核 `5.15.0-198-generic` |
| 客户机配置 | 2 核 / 4GB 内存 / 40GB 磁盘 |
| 主机名 / 账号 | `ysklab` / `ysk` |
| 网络 | NAT，静态 IP **192.168.206.10/24**，网关 `192.168.206.2`，DNS `223.5.5.5` |
| 时区 | `Asia/Shanghai`（CST） |

### 架构图

```
            [ Windows 宿主机 / 浏览器 ]
                        │
                        │  http://192.168.206.10
                        ▼
   ┌──────────────────────────────────────────┐
   │      Ubuntu Server  (ysklab)             │
   │      192.168.206.10                      │
   │                                          │
   │  ┌─ Nginx :80 ─────────────────────────┐ │
   │  │   /        → /var/www/html          │ │  静态站点
   │  │   /app/    → 127.0.0.1:8080         │ │  反向代理
   │  └─────────────────────────────────────┘ │
   │                                          │
   │  ┌─ MySQL :3306 ───────────────────────┐ │
   │  │   库 ops_lab                        │ │
   │  │   表 devices / faults               │ │
   │  │   账号 ops_app(读写)  ops_ro(只读)  │ │
   │  └─────────────────────────────────────┘ │
   │                                          │
   │  ┌─ 监控 ──────────────────────────────┐ │
   │  │   node_exporter :9100   （采集）    │ │
   │  │          ↓ scrape                   │ │
   │  │   Prometheus    :9090   （存储+规则）│ │
   │  │          ↓ datasource               │ │
   │  │   Grafana       :3000   （展示）    │ │
   │  └─────────────────────────────────────┘ │
   │                                          │
   │  ┌─ 自动化 ────────────────────────────┐ │
   │  │   crontab → /opt/ops-scripts/*.sh   │ │
   │  │   日志清理 / 服务探活 / 磁盘巡检    │ │
   │  └─────────────────────────────────────┘ │
   └──────────────────────────────────────────┘
```

**架构说明**
- 除 Nginx 的 80 端口对外，其余服务只监听本机或内网，减少暴露面。
- 服务统一用 systemd 管理，配 `Restart` 实现故障自动拉起。
- 监控采用 Prometheus 的 pull 模式，目标不可达会直接体现在 `up` 指标上。

---

## 三、服务部署

### 3.1 系统初始化

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y curl wget git unzip htop lsof net-tools
sudo timedatectl set-timezone Asia/Shanghai
date   # 确认显示 CST
```

**静态 IP**（netplan，实际文件名 `50-cloud-init.yaml`）：

```yaml
# /etc/netplan/50-cloud-init.yaml
network:
  version: 2
  ethernets:
    ens33:
      dhcp4: false
      addresses: [192.168.206.10/24]
      routes:
        - to: default
          via: 192.168.206.2
      nameservers:
        addresses: [223.5.5.5, 119.29.29.29]
```

```bash
sudo netplan apply
ip a   # 复核地址
```

> **踩坑记录**：装系统时选了自动 DHCP，网络由 **cloud-init** 接管，因此 netplan 文件名是 `50-cloud-init.yaml` 而非通用的 `00-installer-config.yaml`；且必须**额外**写 `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg` 禁止 cloud-init 覆盖，否则重启后配置失效。

### 3.2 Nginx 部署

```bash
sudo apt install -y nginx
sudo systemctl enable --now nginx
```

站点配置 `/etc/nginx/sites-available/default`：

```nginx
server {
    listen 80 default_server;
    root /var/www/html;
    index index.html index.htm;

    server_name _;

    location / {
        try_files $uri $uri/ =404;
    }

    location /app/ {
        proxy_pass http://127.0.0.1:8080/;
    }
}
```

```bash
sudo nginx -t && sudo systemctl reload nginx
curl -I http://127.0.0.1/
```

**`sites-available` / `sites-enabled` 的设计**：前者是"草稿柜"，后者是"生效目录"。`sites-enabled` 里放的是**软链接**，指向 `sites-available` 中的文件。启停一个站点只需增删链接，不用动配置内容本身。

### 3.3 第二个后端服务 + 反向代理

写一个极简 Python HTTP 服务，**只监听 `127.0.0.1:8080`**：

```python
# /opt/webapp.py
from http.server import BaseHTTPRequestHandler, HTTPServer

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()
        self.wfile.write('<h1>我是第二个服务</h1><p>你通过 nginx 转到了这里</p>'.encode('utf-8'))

    def log_message(self, *args):
        pass

HTTPServer(('127.0.0.1', 8080), Handler).serve_forever()
```

用 systemd 托管（**不手动 `&` 后台跑**）：

```ini
# /etc/systemd/system/webapp.service
[Unit]
Description=my second web app
After=network.target

[Service]
ExecStart=/usr/bin/python3 /opt/webapp.py
Restart=always
User=root

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now webapp
sudo systemctl status webapp
```

**验证链路**：

| 测试 | 结果 | 说明 |
|---|---|---|
| 服务器内 `curl 127.0.0.1:8080` | ✅ 有内容 | 服务本身正常 |
| Windows `curl 192.168.206.10:8080` | ❌ 连不上 | **预期**——只监听 `127.0.0.1` |
| 浏览器访问 `http://192.168.206.10/app/` | ✅ 显示「我是第二个服务」 | 反向代理生效 |

> **设计说明**：后端服务只监听本机，对外统一由 Nginx 的 80 端口收敛入口。这样后端端口不暴露在网络上，后续要加 HTTPS、限流、访问日志都只需在 Nginx 一层处理。

### 3.4 MySQL 部署与权限体系

```bash
sudo apt install -y mysql-server
sudo mysql   # Ubuntu 22.04 的 root 走 auth_socket，免密码
```

```sql
CREATE DATABASE ops_lab DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
USE ops_lab;

-- 设备台账
CREATE TABLE devices (
  id          INT AUTO_INCREMENT PRIMARY KEY,
  hostname    VARCHAR(64) NOT NULL,
  ip          VARCHAR(32),
  os_version  VARCHAR(64),
  owner       VARCHAR(32),
  status      ENUM('在用','维修','报废') DEFAULT '在用',
  created_at  DATETIME DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

-- 故障记录
CREATE TABLE faults (
  id          INT AUTO_INCREMENT PRIMARY KEY,
  device_id   INT,
  symptom     VARCHAR(255) NOT NULL,
  root_cause  VARCHAR(255),
  action      VARCHAR(255),
  handled_at  DATETIME DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (device_id) REFERENCES devices(id)
) ENGINE=InnoDB;

-- 双账号：最小权限
CREATE USER 'ops_app'@'192.168.206.%' IDENTIFIED BY '******';
GRANT SELECT, INSERT, UPDATE ON ops_lab.* TO 'ops_app'@'192.168.206.%';

CREATE USER 'ops_ro'@'192.168.206.%' IDENTIFIED BY '******';
GRANT SELECT ON ops_lab.* TO 'ops_ro'@'192.168.206.%';

FLUSH PRIVILEGES;
SHOW GRANTS FOR 'ops_ro'@'192.168.206.%';
```

**权限设计说明**
- **按最小权限原则划分两个角色**：业务账号 `ops_app` 只给 DML（增删改查中的 S/I/U，**不含 DELETE**）；报表账号 `ops_ro` 只给 `SELECT`。
- **账号来源限定 `192.168.206.%` 内网段**，而非 `%` 全网段，减少被外部直连的可能。
- root 不对外开放，仅本地 socket 登录。

**权限验证（实测）**：

```bash
# 从 Windows 用只读账号连接
mysql -u ops_ro -p -h 192.168.206.10
```

```sql
SELECT hostname, owner FROM ops_lab.devices;   -- ✅ 3 rows
DELETE FROM ops_lab.devices WHERE id = 1;      -- ❌ ERROR 1142 (42000)
```

报错原文：

```
ERROR 1142 (42000): DELETE command denied to user 'ops_ro'@'192.168.206.1' for table 'devices'
```

> **结论**：最小权限不是配置出来就算数的，**要真的去试一次越权操作，看它是否被拒**。`1142` 就是 MySQL 给出的确定性证据。报错里的 `@'192.168.206.1'` 同时暴露了访问来源 IP，这也是数据库审计能力的雏形。

---

## 四、监控与告警

### 4.1 Node Exporter + Prometheus

```bash
# Node Exporter（手工安装，建专用低权限用户）
sudo useradd --no-create-home --shell /usr/sbin/nologin node_exporter
# 下载解压后
sudo cp node_exporter /usr/local/bin/
sudo chown node_exporter:node_exporter /usr/local/bin/node_exporter

sudo apt install -y prometheus        # Ubuntu 官方源，版本 2.31.2
sudo systemctl enable --now node_exporter prometheus

curl -s http://127.0.0.1:9100/metrics | head
curl -s http://127.0.0.1:9090/-/healthy
```

Node Exporter 的 systemd 单元：

```ini
# /etc/systemd/system/node_exporter.service
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=node_exporter
Group=node_exporter
ExecStart=/usr/local/bin/node_exporter --collector.systemd --web.listen-address=:9100
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

采集配置 `/etc/prometheus/prometheus.yml`：

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - "/etc/prometheus/rules.yml"

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'node'
    static_configs:
      - targets: ['localhost:9100']
```

```bash
sudo promtool check config /etc/prometheus/prometheus.yml
sudo systemctl restart prometheus
```

**结果**：`Status → Targets` 页面两个目标均为绿色 **UP**。

### 4.2 Grafana 面板

Grafana **不在 Ubuntu 官方源**，需加官方源 + GPG 验签钥匙：

```bash
sudo mkdir -p /etc/apt/keyrings
sudo wget -q -O /etc/apt/keyrings/grafana.asc https://apt.grafana.com/gpg.key
sudo chmod 644 /etc/apt/keyrings/grafana.asc
sudo bash -c 'echo "deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list'
sudo apt update && sudo apt install -y grafana
sudo systemctl enable --now grafana-server
```

- 数据源：`Connections → Data sources → Prometheus`，URL 填 `http://localhost:9090`
- 验证：点击 `Save & test` → 返回 `Successfully queried the Prometheus API`

### 4.3 告警规则

```yaml
# /etc/prometheus/rules.yml
groups:
  - name: disk_alerts
    rules:
      - alert: DiskSpaceLow
        expr: (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) * 100 < 15
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "根分区可用空间低于 15%"
          description: "根分区剩余空间 {{ $value }}%"
```

```bash
sudo promtool check rules /etc/prometheus/rules.yml   # SUCCESS: 1 rules found
sudo systemctl restart prometheus
```

**告警有效性验证（关键步骤，不能只配不验）**：

```bash
df -h /                                      # 基线：可用 7.0G / 61%
sudo fallocate -l 6G /bigfile                # 制造磁盘压力
df -h /                                      # 变化：可用 993M / 95%（可用率约 5%）

# 观察 /classic/alerts
# 02:41:30  → Pending（黄）
# 02:46:30  → Firing （红）

sudo rm -f /bigfile                          # 清理
df -h /                                      # 空间恢复
# 再次刷新 → Inactive（绿）
```

**验证结论**：告警在故障注入后 **0 秒进入 Pending**，满 `for: 5m` 后准时 **Firing**，清理文件后自动恢复 **Inactive**。**三态转换完整观测到。**

> **设计说明**：`Pending` 状态是告警系统的精华——条件满足时并不立即报警，而是先进入观察期，避免瞬时抖动引发误报。这是"告警"与"噪音"的分界线。

---

## 五、自动化脚本

脚本统一存放 `/opt/ops-scripts/`，运行日志在 `/var/log/ops_scripts.log`。

| 脚本 | 用途 | 执行频率 |
|---|---|---|
| `log_clean.sh` | 清理 7 天前的 Nginx 日志归档文件 | 每天 04:00 |
| `svc_health.sh` | HTTP 探活，状态码非 200 自动重启服务 | 每 5 分钟 |
| `disk_check.sh` | 磁盘巡检，使用率超 85% 写告警日志 | 每天 03:00 |

`crontab -l` 输出：

```cron
*/5 * * * * /opt/ops-scripts/svc_health.sh
0 3 * * * /opt/ops-scripts/disk_check.sh
0 4 * * * /opt/ops-scripts/log_clean.sh
```

### 脚本 1：日志清理

```bash
#!/bin/bash
# 日志清理：删除 7 天前的 Nginx 日志归档文件

LOG_DIR=/var/log/nginx
KEEP_DAYS=7

find "$LOG_DIR" -name "*.log.1" -mtime +$KEEP_DAYS -delete

echo "[$(date '+%F %T')] 日志清理完成" >> /var/log/ops_scripts.log
```

### 脚本 2：服务探活 + 自动重启

```bash
#!/bin/bash
# 服务探活：访问首页，非 200 就重启 nginx

URL="http://127.0.0.1/"
SVC="nginx"
LOG=/var/log/ops_scripts.log

code=$(curl -s -o /dev/null -w "%{http_code}" "$URL")

if [ "$code" != "200" ]; then
    echo "[$(date '+%F %T')] 【告警】$SVC 返回 $code，尝试重启" >> "$LOG"
    systemctl restart "$SVC"
    sleep 2
    code2=$(curl -s -o /dev/null -w "%{http_code}" "$URL")
    echo "[$(date '+%F %T')] 重启后状态码：$code2" >> "$LOG"
else
    echo "[$(date '+%F %T')] $SVC 正常（$code）" >> "$LOG"
fi
```

### 脚本 3：磁盘巡检

```bash
#!/bin/bash
# 磁盘巡检：根分区使用率超过 85% 就告警

THRESHOLD=85
LOG=/var/log/ops_scripts.log

use=$(df / | awk 'NR==2 {print $5}' | tr -d '%')

if [ "$use" -gt "$THRESHOLD" ]; then
    echo "[$(date '+%F %T')] 【告警】根分区使用率 ${use}%，超过 ${THRESHOLD}%" >> "$LOG"
else
    echo "[$(date '+%F %T')] 磁盘正常（${use}%）" >> "$LOG"
fi
```

### 自动化验证（故障注入实测）

```bash
sudo systemctl stop nginx
sudo /opt/ops-scripts/svc_health.sh
cat /var/log/ops_scripts.log
```

日志输出：

```
[2026-10-07 02:57:37] 【告警】nginx 返回 000，尝试重启
[2026-10-07 02:57:39] 重启后状态码：200
```

> **结论**：手工停服后，脚本在**同一分钟内**检测到异常（`000` = 连不上）、自动重启、并复验恢复为 `200`。**全程无人干预。**

**脚本设计要点**
- 所有脚本**先用绝对路径手工执行验证通过**，再挂 crontab ——避免"定时任务跑不通但不知道为什么"。
- 探活脚本**先重启、再复验**，把"重启是否真的生效"也记进日志，而不是重启完就宣称成功。
- 磁盘阈值写成变量 `THRESHOLD` 放在脚本头部，改阈值不用翻代码。
- `df` 的输出直接给 `[ 61 -gt 85 ]` 会因带 `%` 号报错，所以先 `tr -d '%'` 洗成纯数字。

---

## 六、遇到的问题与解决（⭐ 本文档最重要的一节）

### 问题 1：Nginx 页面中文乱码

| 项 | 内容 |
|---|---|
| **现象** | 浏览器打开自建页面，中文显示为 `娆四…` 一类乱码 |
| **定位过程** | 确认文件内容本身是正确的（`cat` 出来中文正常）→ 排除文件损坏 → 怀疑编码声明缺失 |
| **根源** | HTML 文件只写了两行纯文本，**没有声明字符编码**，浏览器只能按默认编码猜测，猜错即乱码 |
| **解决** | 补上完整 HTML 骨架，在 `<head>` 内声明 `<meta charset="UTF-8">` |
| **复盘** | **电脑只存数字**，汉字要先按某张对照表（字符编码）转成数字存起来。一方用 A 表存、另一方用 B 表读，必然乱码。编码声明就是"留张字条告诉对方用哪张表"。 |

### 问题 2：页面多出一行不该显示的文字

| 项 | 内容 |
|---|---|
| **现象** | 页面底部出现一行 `← 注释` 之类的说明文字 |
| **定位过程** | 对照源码，发现该文字是写在代码行尾的注释说明 |
| **根源** | 复制时把行尾注释一起带进来了。**HTML 里没被标签包住的文字，浏览器一律当正文渲染** |
| **解决** | 删掉注释重新保存 |
| **复盘** | HTML 的尖括号本质是**给文字贴"身份标签"**——纯文本无法表达"这段是标题还是正文"，所以要用标签标注角色；**没标签 = 默认当正文**。 |

### 问题 3：Windows 无法连接服务器的 8080 端口

| 项 | 内容 |
|---|---|
| **现象** | Windows 上 `curl 192.168.206.10:8080` 连不上；但服务器内部 `curl 127.0.0.1:8080` 正常 |
| **定位过程** | 服务进程在跑、内容能取到 → 排除服务本身故障 → 检查监听地址 |
| **根源** | 程序绑定的是 `127.0.0.1`，**只接受本机连接**，外部请求根本不进入监听队列 |
| **解决** | 这不是 bug，是**刻意的设计**——保留该绑定，改由 Nginx 反向代理统一对外 |
| **复盘** | **"服务连不上"永远要查两层**：① 服务自己绑在哪（`ss -tlnp`）② 中间有没有防火墙（`ufw status`）。`127.0.0.1` = 只有自己，`0.0.0.0` = 任何人都可能连上。 |

### 问题 4：Windows 无法连接 MySQL 3306

| 项 | 内容 |
|---|---|
| **现象** | `Test-NetConnection 192.168.206.10 -Port 3306` → `PingSucceeded: True` 但 `TcpTestSucceeded: False` |
| **定位过程** | **能 ping 通说明网络层没问题** → 问题在端口层 → `sudo ss -tlnp \| grep 3306` → 看到 **`127.0.0.1:3306`** |
| **根源** | MySQL 默认只监听本机回环地址，不接受外部连接 |
| **解决** | 修改 `/etc/mysql/mysql.conf.d/mysqld.cnf` 中 `bind-address = 0.0.0.0`，`systemctl restart mysql`，`ss` 复查变为 `0.0.0.0:3306`，Windows 复验 `True` |
| **复盘** | **ping 通 ≠ 端口通**。ping 走的是 ICMP，端口能否连是另一回事。这是排障时最容易混淆的一步。另外要明确：`bind-address` 开成 `0.0.0.0` 是**学习动作**，生产环境应走内网 + 安全组白名单，绝不能把数据库直接暴露到公网。 |

### 问题 5：安装 Grafana 报 `Unable to locate package`

| 项 | 内容 |
|---|---|
| **现象** | `sudo apt install -y grafana` → `E: Unable to locate package grafana` |
| **定位过程** | `apt` 是"照着源清单找包"，找不到只能是清单里没有 → 检查 Grafana 是否在 Ubuntu 官方源 |
| **根源** | Grafana 是**第三方软件**，不在 Ubuntu 官方软件源中 |
| **解决** | 添加 Grafana 官方源：下载 GPG 验签公钥到 `/etc/apt/keyrings/grafana.asc`，写入 `/etc/apt/sources.list.d/grafana.list`，`apt update` 后安装成功 |
| **复盘** | 第三方软件的标准安装动作是**「加官方源 + 导入 GPG 验签钥匙」**。GPG 钥匙的作用是验证软件包确实来自官方、没被篡改。另外：**装完不等于启动**，Grafana 会明确提示 `NOT starting on installation`，必须再 `systemctl enable --now`。 |

### 问题 6：告警规则写好但不生效

| 项 | 内容 |
|---|---|
| **现象** | `/etc/prometheus/rules.yml` 写好了，重启后 `/classic/alerts` 页面看不到规则 |
| **定位过程** | `promtool check rules` 显示规则文件本身语法 `SUCCESS` → 说明文件没问题，是**没被加载** → 回头检查 `prometheus.yml` 的 `rule_files:` 段 |
| **根源** | `rule_files:` 那行的开头**还留着一个 `#`**，在 YAML 里 `#` 是注释符，等于这行根本没生效 |
| **解决** | 删掉 `#`，`promtool check config` 通过，重启后规则出现 |
| **复盘** | **配置类问题优先怀疑"改的地方是不是真的生效了"**。注释符吃掉整行是极常见的坑，同时要用工具自带的校验命令（`promtool check`）而不是靠肉眼。 |

---

## 七、结果与数据

| 指标 | 实测结果 |
|---|---|
| 服务可用性 | Nginx 承载静态站点 + 反向代理，`curl` 探测返回 200 |
| 反向代理 | 后端服务收敛到 80 端口对外，`/app/` 路径访问成功 |
| 数据库权限 | `SHOW GRANTS` 仅 `SELECT`；越权 `DELETE` 返回 `ERROR 1142` 被拒 |
| 远程连接 | Microsoft 主机 → `192.168.206.10:3306` 连接成功，可查询数据 |
| 监控采集 | Prometheus Targets 两个目标 `UP`，`up` 指标 = 1 |
| 指标可视化 | Grafana 折线图呈现内存变化，装监控后可用内存从 2.9G 降至 2.1G |
| 告警验证 | 故障注入后 **0 秒 Pending**，**5 分钟 Firing**，清理后自动回 `Inactive` |
| 故障自动恢复 | 手工停服后**同一分钟内**自动重启恢复为 200 |
| 定时任务 | crontab 3 条规则上线，探活任务每 5 分钟稳定产出日志 |

---

## 八、后续优化方向

1. **备份自动化**：目前数据库备份仍是手工 `mysqldump`，计划写成脚本 + crontab，并定期做**恢复演练**（没验证过能恢复的备份等于没有备份）。
2. **告警通道**：目前只写日志和 Grafana 界面，计划接入 Alertmanager + Webhook，推送到企业微信/钉钉。
3. **日志集中化**：目前日志散落在各文件，计划引入 Loki 做集中检索。
4. **容器化**：目前服务直接装在主机上，计划用 Docker 重做一遍，便于版本管理和迁移。
5. **配置管理**：目前全手工配置，节点多了效率低，计划学习 Ansible 做批量部署。
6. **多节点**：目前单机，无高可用，计划扩展为多节点 + 负载均衡。

---

## 附：项目命令速查

| 命令 | 用途 |
|---|---|
| `systemctl status <服务>` | 看服务状态 |
| `systemctl enable --now <服务>` | 开机自启 + 立即启动 |
| `ss -tlnp` | 看所有监听端口及对应进程 |
| `nginx -t` | 校验 Nginx 配置语法（改配置后必做） |
| `systemctl reload nginx` | 不中断连接地重载配置 |
| `promtool check rules <文件>` | 校验 Prometheus 告警规则语法 |
| `df -h` | 查看磁盘使用率 |
| `journalctl -u <服务> -n 50` | 查看服务最近 50 行日志 |
| `crontab -e` / `crontab -l` | 编辑 / 查看定时任务 |
