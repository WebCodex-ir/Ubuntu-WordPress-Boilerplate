#!/bin/bash
# =================================================================
#      -- The Ultimate WordPress & LAMP Stack Installer --
#
#   Installs a secure, optimized, and full-featured server for WordPress.
#   Stack: Apache2, MariaDB, PHP, Redis, SSL, Brotli, WAF, SFTP
#   OS: Ubuntu 24.04 LTS
# =================================================================

# --- Configuration ---
LOG_FILE="/var/log/wordpress_install_$(date +%F_%H-%M-%S).log"

# --- Redirect all output to log file and console ---
exec &> >(tee -a "$LOG_FILE")

# --- Helper Functions ---
function print_msg() {
    echo -e "\n\033[0;34m====================================================\033[0m"
    echo -e "\033[0;32m$1\033[0m"
    echo -e "\033[0;34m====================================================\033[0m"
}

function error_exit() {
    echo -e "\n\033[0;31m####################################################\033[0m"
    echo -e "\033[0;31m# ERROR: $1\033[0m"
    echo -e "\033[0;31m# Installation failed. See log for details: ${LOG_FILE}\033[0m"
    echo -e "\033[0;31m####################################################\033[0m"
    exit 1
}

# --- Root check ---
if [[ $EUID -ne 0 ]]; then
   error_exit "This script must be run as root. Please use 'sudo ./install.sh'"
fi

# --- Get User Info ---
print_msg "Welcome to the Ultimate WordPress Server Setup"
read -p "Enter your main domain name (e.g., example.com): " DOMAIN_NAME
read -p "Enter a name for your WordPress database: " DB_NAME
read -p "Enter a username for the database: " DB_USER
read -sp "Enter a strong password for the database user: " DB_PASS
echo
read -p "Enter your admin email (for SSL certificate): " ADMIN_EMAIL

# --- Confirmation ---
read -p "Is this correct? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" ]]; then
    error_exit "Installation cancelled by user."
fi

# --- PHASE 1: System Preparation & Core Stack Installation ---
print_msg "PHASE 1: Preparing System and Installing All Dependencies..."
apt-get update && apt-get upgrade -y || error_exit "System update/upgrade failed."
apt-get install -y git unzip software-properties-common curl apache2 mariadb-server \
                   php php-mysql php-gd php-xml php-mbstring php-curl php-zip php-imagick php-intl \
                   redis-server php-redis libapache2-mod-php brotli \
                   fail2ban ufw libapache2-mod-security2 certbot python3-certbot-apache \
                   || error_exit "Failed to install required packages. Check apt logs."

# --- PHASE 2: Performance & Security Configuration ---
print_msg "PHASE 2: Configuring Performance and Security..."
a2enmod rewrite headers expires brotli ssl || error_exit "Failed to enable essential Apache modules."

# Configure Brotli
cat << EOF > /etc/apache2/conf-available/brotli.conf
<IfModule mod_brotli.c>
    AddOutputFilterByType BROTLI_COMPRESS text/html text/plain text/xml text/css text/javascript application/javascript application/x-javascript application/json application/xml application/rss+xml application/atom+xml image/svg+xml
</IfModule>
EOF
a2enconf brotli || error_exit "Failed to enable Brotli configuration."

# Configure Firewall
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow http
ufw allow https
ufw --force enable

# --- PHASE 3: Database and Redis Setup ---
print_msg "PHASE 3: Configuring Database and Redis..."
systemctl enable --now redis-server || error_exit "Failed to start or enable Redis."
MARIADB_ROOT_PASS=$(openssl rand -base64 16)
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${MARIADB_ROOT_PASS}'; FLUSH PRIVILEGES;" || error_exit "Failed to set MariaDB root password."

mysql -u root -p"${MARIADB_ROOT_PASS}" <<EOF
CREATE DATABASE ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
if [ $? -ne 0 ]; then error_exit "Failed to create WordPress database or user."; fi

# --- PHASE 4: WordPress, VHost, and SSL ---
print_msg "PHASE 4: Setting up WordPress, Virtual Host, and SSL..."
WEB_ROOT="/var/www/vhosts/${DOMAIN_NAME}"
mkdir -p ${WEB_ROOT} || error_exit "Failed to create web directory."

wget https://wordpress.org/latest.tar.gz -O /tmp/wordpress.tar.gz
tar -xzf /tmp/wordpress.tar.gz -C ${WEB_ROOT} --strip-components=1
rm /tmp/wordpress.tar.gz

VHOST_CONF="/etc/apache2/sites-available/${DOMAIN_NAME}.conf"
cat << EOF > ${VHOST_CONF}
<VirtualHost *:80>
    ServerAdmin ${ADMIN_EMAIL}
    ServerName ${DOMAIN_NAME}
    ServerAlias www.${DOMAIN_NAME}
    DocumentRoot ${WEB_ROOT}
    <Directory ${WEB_ROOT}>
        AllowOverride All
    </Directory>
</VirtualHost>
EOF

a2ensite ${DOMAIN_NAME}.conf && a2dissite 000-default.conf && systemctl reload apache2 || error_exit "Failed to configure Apache virtual host."

# DNS Check before Certbot
SERVER_IP=$(curl -s ifconfig.me)
DOMAIN_IP=$(dig +short $DOMAIN_NAME)
if [ "$SERVER_IP" != "$DOMAIN_IP" ]; then
    error_exit "DNS Validation Failed! Domain '${DOMAIN_NAME}' does not point to this server's IP '${SERVER_IP}'. It points to '${DOMAIN_IP}'."
fi
certbot --apache -d ${DOMAIN_NAME} -d www.${DOMAIN_NAME} --non-interactive --agree-tos -m ${ADMIN_EMAIL} --redirect || error_exit "Certbot failed to obtain the SSL certificate."

# --- PHASE 5: Final WordPress Configuration ---
print_msg "PHASE 5: Creating wp-config.php and finalizing permissions..."
CONFIG_PATH="${WEB_ROOT}/wp-config.php"
cp ${WEB_ROOT}/wp-config-sample.php ${CONFIG_PATH}
sed -i "s/database_name_here/${DB_NAME}/" ${CONFIG_PATH}
sed -i "s/username_here/${DB_USER}/" ${CONFIG_PATH}
sed -i "s/password_here/${DB_PASS}/" ${CONFIG_PATH}
SALT=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)
printf '%s\n' "g/put your unique phrase here/d" a "$SALT" . w | ed -s ${CONFIG_PATH}
chown -R www-data:www-data ${WEB_ROOT}
find ${WEB_ROOT} -type d -exec chmod 755 {} \;
find ${WEB_ROOT} -type f -exec chmod 644 {} \;

# --- All Done ---
print_msg "✅ SUCCESS! Your Professional WordPress Server is Ready."
echo -e "You can now visit your site to complete the WordPress installation."
echo "--------------------------------------------------"
echo -e "Site URL: https://${DOMAIN_NAME}"
echo -e "SFTP/SSH Host: ${SERVER_IP}"
echo -e "SFTP/SSH User: root"
echo ""
echo -e "Database Name: ${DB_NAME}"
echo -e "Database User: ${DB_USER} (access from localhost)"
echo -e "Database Password: ${DB_PASS}"
echo -e "MariaDB Root Password: ${MARIADB_ROOT_PASS}"
echo "--------------------------------------------------"
echo -e "Installation Log saved to: ${LOG_FILE}"
