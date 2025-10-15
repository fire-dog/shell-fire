#!/bin/bash
# -------------------------------------------------------
# 自动部署 Nginx + Keepalived 高可用 + 健康检测日志 + Web监控界面
# 适用于 openEuler 24.03
# 作者：老张
# 以下五个变量可以根据情况自行设定：MASTER_IP，BACKUP_IP，VIP，PASSWORD，NET_IF
# -------------------------------------------------------

MASTER_IP="10.110.84.62"
BACKUP_IP="10.110.84.63"
VIP="10.110.84.61"
PASSWORD="111111"
NET_IF="eth0"       # 根据你的网卡名修改，例如 enp0s3, ens33 等

MASTER_HOST="nginx-master"
BACKUP_HOST="nginx-backup"

LOG_MONITOR_SCRIPT="/usr/local/bin/vip_monitor.sh"
LOG_FILE="/var/log/vip_status.log"
STATUS_PAGE="/usr/share/nginx/html/status.html"

# -------------------------------------------------------
# 检查依赖
# -------------------------------------------------------
check_sshpass() {
    if ! command -v sshpass &>/dev/null; then
        echo "[INFO] 安装 sshpass..."
        dnf install -y sshpass >/dev/null 2>&1 || { echo "[ERROR] 无法安装 sshpass"; exit 1; }
    fi
}

# -------------------------------------------------------
# 远程执行命令
# -------------------------------------------------------
run_remote() {
    local host=$1
    local cmd=$2
    echo "[EXEC] ${host}: ${cmd}"
    sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no root@$host "$cmd"
}

# -------------------------------------------------------
# 生成 Keepalived 配置文件
# -------------------------------------------------------
generate_keepalived_conf() {
    local role=$1
    local priority=$2
    local state=$3
    local router_id=$4

cat <<EOF
! Configuration File for keepalived

global_defs {
   router_id ${router_id}
   vrrp_mcast_group4 224.0.0.18
}

vrrp_script chk_nginx {
    script "/etc/keepalived/check_nginx.sh"
    interval 2
    weight -5
}

vrrp_instance VI_1 {
    state ${state}
    interface ${NET_IF}
    virtual_router_id 51
    priority ${priority}
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass 1111
    }

    virtual_ipaddress {
        ${VIP}/24 dev ${NET_IF} label ${NET_IF}:1
    }

    track_script {
        chk_nginx
    }
}
EOF
}

# -------------------------------------------------------
# 生成健康检查脚本
# -------------------------------------------------------
generate_check_script() {
cat <<'EOF'
#!/bin/bash
if ! systemctl is-active --quiet nginx; then
    systemctl restart nginx
    sleep 2
    if ! systemctl is-active --quiet nginx; then
        systemctl stop keepalived
    fi
fi
EOF
}

# -------------------------------------------------------
# 生成 VIP 监控日志脚本 + Web 状态页
# -------------------------------------------------------
generate_vip_monitor_script() {
cat <<EOF
#!/bin/bash
VIP="${VIP}"
LOG_FILE="${LOG_FILE}"
STATUS_PAGE="${STATUS_PAGE}"
HOSTNAME=\$(hostname)
DATE=\$(date '+%F %T')

if ip addr show ${NET_IF} | grep -q "\$VIP"; then
    STATUS="active"
    MSG="[\\$DATE] VIP \$VIP is active on node \$HOSTNAME"
else
    STATUS="standby"
    MSG="[\\$DATE] VIP \$VIP is NOT on node \$HOSTNAME"
fi

echo "\$MSG" >> \$LOG_FILE

# 生成 Web 状态页
cat > \$STATUS_PAGE <<HTML
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<meta http-equiv="refresh" content="5">
<title>VIP 状态监控</title>
<style>
body { font-family: Arial, sans-serif; text-align: center; margin-top: 10%; background: #f9fafb; }
h1 { color: #333; }
.status-active { color: green; font-size: 1.5em; }
.status-standby { color: gray; font-size: 1.5em; }
.container { background: #fff; border-radius: 10px; padding: 40px; box-shadow: 0 0 15px rgba(0,0,0,0.1); display: inline-block; }
</style>
</head>
<body>
<div class="container">
  <h1>Keepalived + Nginx 高可用状态</h1>
  <p>时间：<b>\$DATE</b></p>
  <p>当前节点：<b>\$HOSTNAME</b></p>
  <p>VIP 地址：<b>\$VIP</b></p>
  <p class="status-\$STATUS">状态：\$( [ "\$STATUS" = "active" ] && echo "运行中 (Master)" || echo "待命 (Backup)" )</p>
</div>
</body>
</html>
HTML
EOF
}

# -------------------------------------------------------
# 配置节点
# -------------------------------------------------------
setup_node() {
    local host=$1
    local role=$2
    local priority=$3
    local state=$4
    local router_id=$5

    echo "[INFO] === 配置 ${role} 节点 (${host}) ==="

    run_remote "$host" "
        hostnamectl set-hostname ${router_id} &&
        dnf install -y nginx keepalived cronie >/dev/null 2>&1 &&
        systemctl enable --now nginx crond &&
        systemctl stop firewalld && systemctl disable firewalld &&
        setenforce 0 && sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
    "

    # 生成临时文件
    TMP_CONF="/tmp/keepalived_${role}.conf"
    TMP_CHK="/tmp/check_nginx_${role}.sh"
    TMP_MON="/tmp/vip_monitor_${role}.sh"

    generate_keepalived_conf "$role" "$priority" "$state" "$router_id" > "$TMP_CONF"
    generate_check_script > "$TMP_CHK"
    generate_vip_monitor_script > "$TMP_MON"

    # 上传配置文件
    sshpass -p "$PASSWORD" scp -o StrictHostKeyChecking=no "$TMP_CONF" root@$host:/etc/keepalived/keepalived.conf
    sshpass -p "$PASSWORD" scp -o StrictHostKeyChecking=no "$TMP_CHK" root@$host:/etc/keepalived/check_nginx.sh
    sshpass -p "$PASSWORD" scp -o StrictHostKeyChecking=no "$TMP_MON" root@$host:$LOG_MONITOR_SCRIPT

    # 权限与定时任务
    run_remote "$host" "
        chmod +x /etc/keepalived/check_nginx.sh &&
        chmod +x $LOG_MONITOR_SCRIPT &&
        touch $LOG_FILE && chmod 644 $LOG_FILE &&
        mkdir -p \$(dirname $STATUS_PAGE) &&
        (crontab -l 2>/dev/null | grep -v '$LOG_MONITOR_SCRIPT'; echo '* * * * * for i in {1..6}; do $LOG_MONITOR_SCRIPT; sleep 10; done') | crontab - &&
        systemctl enable --now keepalived
    "
}

# -------------------------------------------------------
# 主程序执行
# -------------------------------------------------------
main() {
    echo "========== 部署 Nginx + Keepalived 高可用 + Web监控 =========="
    check_sshpass

    setup_node "$MASTER_IP" "master" 100 "MASTER" "$MASTER_HOST"
    setup_node "$BACKUP_IP" "backup" 90 "BACKUP" "$BACKUP_HOST"

    echo "========== 部署完成 =========="
    echo "[访问方式] 打开浏览器访问：http://${VIP}/status.html"
    echo "[日志文件] /var/log/vip_status.log"
    echo "[监控脚本] ${LOG_MONITOR_SCRIPT}"
    echo "[刷新间隔] 每10秒更新一次"
}

main
