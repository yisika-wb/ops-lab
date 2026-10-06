# 仓库结构说明

本仓库是一个**个人 Linux 运维实践项目**的完整留档。所有内容均在本地 VMware 虚拟机
（Ubuntu Server 22.04.5 LTS）中实际部署并验证通过，命令与输出均为真实执行结果。

```
ops-lab/
├── README.md                     ← 项目正式文档（架构 / 部署 / 排障记录）
├── config/                       ← 各服务的配置文件（脱敏后）
│   ├── nginx-default.conf        Nginx 站点配置（静态站点 + 反向代理）
│   ├── prometheus.yml            Prometheus 主配置
│   ├── rules.yml                 告警规则
│   └── node_exporter.service     Node Exporter 的 systemd 单元
├── scripts/                      ← 定时任务脚本
│   ├── log_clean.sh              日志清理（每天 04:00）
│   ├── svc_health.sh             服务探活 + 自动重启（每 5 分钟）
│   └── disk_check.sh             磁盘巡检（每天 03:00）
└── docs/
    └── README.md                 （本文件）
```

## 使用方法

配置文件按注释中标注的路径放到对应位置，例如：

| 仓库文件 | 实际部署路径 | 生效命令 |
|---|---|---|
| `config/nginx-default.conf` | `/etc/nginx/sites-available/default` | `nginx -t && systemctl reload nginx` |
| `config/prometheus.yml` | `/etc/prometheus/prometheus.yml` | `promtool check config` → `systemctl restart prometheus` |
| `config/rules.yml` | `/etc/prometheus/rules.yml` | `promtool check rules` → `systemctl restart prometheus` |
| `config/node_exporter.service` | `/etc/systemd/system/node_exporter.service` | `daemon-reload` → `enable --now node_exporter` |
| `scripts/*.sh` | `/opt/ops-scripts/` | `chmod +x` 后先手工执行验证，再挂 crontab |

## 安全说明

- 本仓库**不包含任何真实密码**，配置示例中的口令位置均为占位符。
- 脚本中的 IP 段（`192.168.206.x`）为本地虚拟机内网地址，非生产环境。
- 把数据库 `bind-address` 设为 `0.0.0.0` 属于**学习环境的验证动作**；
  生产环境应通过内网 + 安全组白名单限制访问来源，不要直接暴露到公网。
