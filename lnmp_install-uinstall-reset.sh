#!/bin/bash
# ============================================================
# LNMP 自动部署脚本 for openEuler 24.03 Minimal（交互版 + 卸载/重置功能）
# 作者: 老张
# 功能: 自动安装 Nginx + MariaDB + PHP8.3 + 扩展（带检测、交互、卸载）
# ============================================================

set -eo pipefail

# ---------- 彩色日志输出 ----------
log_info()  { echo -e "\033[32m[INFO] $(date '+%F %T') $1\033[0m"; }
log_warn()  { echo -e "\033[33m[WARN] $(date '+%F %T') $1\033[0m"; }
log_error() { echo -e "\033[31m[ERROR] $(date '+%F %T') $1\033[0m"; }

# ---------- 用户确认 ----------
ask_user() {
    local question="$1"
    read -p "[QUESTION] $(date '+%F %T') $question (y/N): " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]]
}

# ---------- 检查 root ----------
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用 root 用户运行此脚本。"
        exit 1
    fi
}

# ---------- 检查包是否存在 ----------
pkg_available() {
    local pkg="$1"
    dnf list --installed "$pkg" &>/dev/null || dnf list available "$pkg" &>/dev/null
}

# ---------- 安全安装 ----------
safe_install() {
    local pkg="$1"
    local desc="$2"

    if dnf list --installed "$pkg" &>/dev/null; then
        log_info "[$desc] 已安装，跳过。"
        return 0
    fi

    if pkg_available "$pkg"; then
        log_info "正在安装 [$desc]..."
        if dnf install -y "$pkg" &>/dev/null; then
            log_info "[$desc] 安装完成。"
            return 0
        else
            log_error "[$desc] 安装失败。"
            return 1
        fi
    else
        log_warn "[$desc] 在当前仓库中不可用，跳过安装。"
        return 0
    fi
}

# ---------- 更新系统 ----------
update_system() {
    log_info "更新系统仓库..."
    dnf clean all &>/dev/null
    dnf makecache &>/dev/null
    dnf update -y &>/dev/null
    log_info "系统更新完成。"
}

# ---------- 安装 Nginx ----------
install_nginx() {
    log_info "安装 Nginx..."
    safe_install "nginx" "Nginx Web 服务器"
    systemctl enable nginx --now &>/dev/null || log_warn "Nginx 启动失败，请检查 systemd。"
}

# ---------- 安装 MariaDB ----------
install_mariadb() {
    log_info "安装 MariaDB..."
    safe_install "mariadb-server" "MariaDB 数据库服务器"
    systemctl enable mariadb --now &>/dev/null || log_warn "MariaDB 启动失败，请检查 systemd。"

    if ask_user "是否运行 MariaDB 安全配置向导 (mysql_secure_installation)?"; then
        mysql_secure_installation || log_warn "MariaDB 安全配置未完成。"
    fi
}

# ---------- 安装 PHP ----------
install_php() {
    log_info "安装 PHP 及扩展..."
    safe_install "php" "PHP 核心"
    safe_install "php-fpm" "PHP-FPM"
    safe_install "php-mysqlnd" "PHP MySQL 驱动"

    local extensions=(
        "php-gd:GD 图形处理"
        "php-intl:国际化支持"
        "php-mbstring:多字节字符串"
        "php-bcmath:高精度数学"
        "php-curl:cURL 支持"
        "php-opcache:OPcache 加速"
        "php-xml:XML 解析"
        "php-pecl-zip:ZIP 压缩"
    )

    for ext in "${extensions[@]}"; do
        local pkg="${ext%%:*}"
        local desc="${ext##*:}"
        if ask_user "是否安装可选扩展 [$desc] ($pkg)?"; then
            safe_install "$pkg" "$desc"
        else
            log_info "跳过 [$desc]"
        fi
    done

    systemctl enable php-fpm --now &>/dev/null || log_warn "PHP-FPM 启动失败，请检查 systemd。"
}

# ---------- 配置 Nginx 与 PHP ----------
configure_nginx_php() {
    log_info "配置 Nginx 与 PHP..."

    mkdir -p /var/www/html
    local conf_file="/etc/nginx/conf.d/default.conf"

    if [ -f "$conf_file" ]; then
        cp "$conf_file" "${conf_file}.bak"
        log_info "已备份原配置文件为 ${conf_file}.bak"
    fi

    cat > "$conf_file" <<'EOF'
server {
    listen 80;
    server_name example.com;
    root /var/www/html;
    
    access_log /var/log/nginx/example.com.access.log;
    error_log /var/log/nginx/example.com.error.log;
    
    index index.php index.html index.htm;
    
    location / {
        try_files $uri $uri/ /index.php?$args;
    }
    
    location ~ \.php$ {
        try_files $uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php-fpm/www.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO $fastcgi_path_info;
        
        # 性能优化
        fastcgi_buffer_size 128k;
        fastcgi_buffers 4 256k;
        fastcgi_busy_buffers_size 256k;
        
        # 安全设置
        fastcgi_hide_header X-Powered-By;
    }
    
    location ~ /\.ht {
        deny all;
    }
}

EOF

    if nginx -t &>/dev/null; then
        systemctl restart nginx || true
        log_info "Nginx 已配置 PHP 支持。"
    else
        log_error "Nginx 配置语法错误，请检查。"
    fi

    echo "<?php phpinfo(); ?>" > /var/www/html/index.php
    log_info "生成测试文件 /var/www/html/index.php"
}

# ---------- 配置防火墙 ----------
configure_firewall() {
    if systemctl is-active firewalld &>/dev/null; then
        log_info "配置防火墙允许 HTTP/HTTPS..."
        firewall-cmd --permanent --add-service=http &>/dev/null || true
        firewall-cmd --permanent --add-service=https &>/dev/null || true
        firewall-cmd --reload &>/dev/null || true
    else
        log_warn "firewalld 未运行，跳过防火墙配置。"
    fi
}

# ---------- 安全配置 ----------
security_config() {
    log_info "配置 PHP-FPM 与权限..."
    if [ -f /etc/php-fpm.d/www.conf ]; then
        cp /etc/php-fpm.d/www.conf /etc/php-fpm.d/www.conf.bak
        sed -i 's/^user = .*/user = nginx/' /etc/php-fpm.d/www.conf
        sed -i 's/^group = .*/group = nginx/' /etc/php-fpm.d/www.conf
    fi

    if [ -f /etc/php.ini ]; then
        cp /etc/php.ini /etc/php.ini.bak
        sed -i 's/;cgi.fix_pathinfo=1/cgi.fix_pathinfo=0/' /etc/php.ini || true
        sed -i 's/expose_php = On/expose_php = Off/' /etc/php.ini || true
    fi

    id nginx &>/dev/null || useradd -r -s /sbin/nologin nginx
    chown -R nginx:nginx /var/www/html
    chmod -R 755 /var/www/html
}

# ---------- 显示结果 ----------
show_summary() {
    local_ip=$(hostname -I | awk '{print $1}')
    echo "=============================================="
    echo " LNMP 部署完成 "
    echo "----------------------------------------------"
    echo " Nginx:    $(nginx -v 2>&1 | head -n1)"
    echo " PHP:      $(php -v | head -n1)"
    echo " MariaDB:  $(mariadb --version 2>/dev/null || mysql -V)"
    echo "----------------------------------------------"
    echo " 网站目录: /var/www/html"
    echo " 测试页:   http://$local_ip/index.php"
    echo "=============================================="
}

# ============================================================
# 卸载与重置功能
# ============================================================
uninstall_lnmp() {
    log_warn "正在卸载 LNMP 环境..."
    systemctl stop nginx mariadb php-fpm 2>/dev/null || true
    systemctl disable nginx mariadb php-fpm 2>/dev/null || true

    log_info "卸载相关软件包..."
    dnf remove -y nginx mariadb mariadb-server php php-fpm php-mysqlnd php-* &>/dev/null || true

    log_info "清理残留文件..."
    rm -rf /var/www/html /etc/nginx/conf.d/default.conf /etc/php-fpm.d/www.conf /etc/php.ini 2>/dev/null || true

    log_info "LNMP 卸载完成。"
}

reset_lnmp() {
    log_warn "执行 LNMP 重置操作（卸载后重新安装）..."
    uninstall_lnmp
    log_info "开始重新部署..."
    main_install
}

# ============================================================
# 主安装逻辑
# ============================================================
main_install() {
    check_root
    update_system
    install_nginx
    install_mariadb
    install_php
    configure_nginx_php
    configure_firewall
    security_config
    show_summary
}

# ============================================================
# 参数解析
# ============================================================
case "$1" in
    --uninstall)
        uninstall_lnmp
        ;;
    --reset)
        reset_lnmp
        ;;
    *)
        main_install
        ;;
esac
