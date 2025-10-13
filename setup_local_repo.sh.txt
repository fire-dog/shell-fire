#!/bin/bash

# CentOS Stream 9 本地 YUM 仓库同步脚本，同步的是https://mirrors.aliyun.com/centos-vault/7.9.2009，存储位置在/yum目录下。
#使用时根据实际情况修改以下3个变量：MIRROR_URL，LOCAL_REPO_DIR，REPO_FILE

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请使用 root 用户运行此脚本！"
    exit 1
fi

# 定义变量
MIRROR_URL="https://mirrors.aliyun.com/centos-vault/7.9.2009"
LOCAL_REPO_DIR="/yum/centos7.9"
REPO_FILE="/etc/yum.repos.d/local-centos7.repo"

# 安装依赖
echo "安装必要工具..."
dnf install -y dnf-utils createrepo_c httpd

# 创建目录
mkdir -p $LOCAL_REPO_DIR/{os,updates,extras}

# 配置临时仓库
cat <<EOF | tee /etc/yum.repos.d/centos7-aliyun.repo
[centos7-os]
name=CentOS 7.9 - OS
baseurl=$MIRROR_URL/os/x86_64/
gpgcheck=1
gpgkey=$MIRROR_URL/os/x86_64/RPM-GPG-KEY-CentOS-7
enabled=1

[centos7-updates]
name=CentOS 7.9 - Updates
baseurl=$MIRROR_URL/updates/x86_64/
gpgcheck=1
gpgkey=$MIRROR_URL/os/x86_64/RPM-GPG-KEY-CentOS-7
enabled=1

[centos7-extras]
name=CentOS 7.9 - Extras
baseurl=$MIRROR_URL/extras/x86_64/
gpgcheck=1
gpgkey=$MIRROR_URL/os/x86_64/RPM-GPG-KEY-CentOS-7
enabled=1
EOF

# 同步仓库
echo "开始同步仓库..."
dnf reposync --download-metadata --delete --download-path=$LOCAL_REPO_DIR/os/ --repoid=centos7-os
dnf reposync --download-metadata --delete --download-path=$LOCAL_REPO_DIR/updates/ --repoid=centos7-updates
dnf reposync --download-metadata --delete --download-path=$LOCAL_REPO_DIR/extras/ --repoid=centos7-extras

# 生成元数据
echo "生成仓库元数据..."
createrepo_c --update $LOCAL_REPO_DIR/os/
createrepo_c --update $LOCAL_REPO_DIR/updates/
createrepo_c --update $LOCAL_REPO_DIR/extras/


# 配置Apache服务
echo "配置Apache服务..."
systemctl enable --now httpd
firewall-cmd --permanent --add-service=http
firewall-cmd --reload

# 创建符号链接到Apache目录
ln -s ${LOCAL_REPO_DIR} /var/www/html/centos7.9



# 配置本地仓库
cat <<EOF | tee $REPO_FILE
[local-centos7-os]
name=Local CentOS 7.9 OS
baseurl=file://$LOCAL_REPO_DIR/os/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1

[local-centos7-updates]
name=Local CentOS 7.9 Updates
baseurl=file://$LOCAL_REPO_DIR/updates/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1

[local-centos7-extras]
name=Local CentOS 7.9 Extras
baseurl=file://$LOCAL_REPO_DIR/extras/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1
EOF

# 清理缓存
dnf clean all

# 显示完成信息
echo -e "\n本地YUM源仓库搭建完成！"
echo -e "同步完成！本地仓库路径: ${LOCAL_REPO_DIR}"
echo -e "可以通过以下URL访问: http://$(hostname -I | awk '{print $1}')/centos7.9"
echo -e "本地仓库配置文件: ${REPO_FILE}"




