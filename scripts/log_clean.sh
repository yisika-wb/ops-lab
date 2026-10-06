#!/bin/bash
# 日志清理：删除 7 天前的 Nginx 日志归档文件
# 部署位置：/opt/ops-scripts/log_clean.sh
# 执行频率：每天 04:00（crontab）

LOG_DIR=/var/log/nginx
KEEP_DAYS=7

find "$LOG_DIR" -name "*.log.1" -mtime +$KEEP_DAYS -delete

echo "[$(date '+%F %T')] 日志清理完成" >> /var/log/ops_scripts.log
