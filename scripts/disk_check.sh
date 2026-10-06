#!/bin/bash
# 磁盘巡检：根分区使用率超过 85% 就写告警日志
# 部署位置：/opt/ops-scripts/disk_check.sh
# 执行频率：每天 03:00（crontab）
#
# 注意：df 输出的使用率带 % 号，不能直接做数字比较，
#      所以先用 tr -d '%' 洗成纯数字，再交给 [ ] 判断。

THRESHOLD=85
LOG=/var/log/ops_scripts.log

use=$(df / | awk 'NR==2 {print $5}' | tr -d '%')

if [ "$use" -gt "$THRESHOLD" ]; then
    echo "[$(date '+%F %T')] 【告警】根分区使用率 ${use}%，超过 ${THRESHOLD}%" >> "$LOG"
else
    echo "[$(date '+%F %T')] 磁盘正常（${use}%）" >> "$LOG"
fi
