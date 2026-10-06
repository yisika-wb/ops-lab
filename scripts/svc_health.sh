#!/bin/bash
# 服务探活：访问首页，非 200 就重启 nginx
# 部署位置：/opt/ops-scripts/svc_health.sh
# 执行频率：每 5 分钟（crontab）
#
# 实测记录（故障注入验证）：
#   [2026-10-07 02:57:37] 【告警】nginx 返回 000，尝试重启
#   [2026-10-07 02:57:39] 重启后状态码：200
# 说明：000 是 curl 的返回值，代表「连接都建立不起来」，即服务已停。

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
