#!/bin/bash
# =================================================================
#           -- Add New WordPress Site Script --
#
#   Automates the creation of a new WordPress site (or subdomain)
#   on the existing LAMP stack.
# =================================================================

# --- Load Helper Functions and Colors from the main installer ---
source /etc/profile # Make sure colors are loaded if any
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_BLUE='\033[0;34m'
C_YELLOW='\033[1;33m'

function print_msg() {
    echo -e "\n${C_BLUE}====================================================${C_RESET}"
    echo -e "${C_GREEN}$1${C_RESET}"
    echo -e "${C_BLUE}====================================================${C_RESET}"
}

function error_exit() {
    echo -e "\n${C_RED}####################################################${C_RESET}"
    echo -e "${C_RED}# ERROR: $1${C_RESET}"
    echo -e "${C_RED}####################################################${C_RESET}"
    exit 1
}

# --- Root check ---
if [[ $EUID -ne 0 ]]; then
   error_exit "This script must be run as root. Please use 'sudo ./add-site.sh'"
fi

# --- Get New Site Info ---
print_msg "Add a New WordPress Site or Subdomain"
read -p "Enter the new domain or subdomain (e.g., blog.example.com): " DOMAIN_NAME
read -p "Enter a new database name: " DB_NAME
read -p "Enter a new database username: " DB_USER
read -sp "Enter a strong password for the new database user: " DB_PASS
echo
read -p "Enter your admin email (for SSL certificate): " ADMIN_EMAIL

# --- Confirmation ---
# ... (Confirmation block) ...
read -p "Is this correct? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" ]]; then
    error_exit "Operation cancelled by user."
fi

# --- PHASE 1: Database Creation ---
print_msg "PHASE 1: Creating New Database and User..."
# A smart way to get the MariaDB root password from the original install log
LOG_FILE=$(ls -t /var/log/wordpress_install_*.log | head -n 1)
if [ -z "$LOG_FILE" ]; then
    error_exit "Could not find the main installation log file to retrieve the MariaDB root password."
fi
MARIADB_ROOT_PASS=$(grep "MariaDB Root Password" "$LOG_FILE" | tail -n 1 | awk '{print $NF}')
if [ -z "$MARIADB_ROOT_PASS" ]; then
    error_exit "Could not read the MariaDB root password from the log file: ${LOG_FILE}"
fi

mysql -u root -p"${MARIADB_ROOT_PASS}" <<EOF
CREATE DATABASE ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
if [ $? -ne 0 ]; then error_exit "Failed to create the new database or user."; fi

# --- PHASE 2: WordPress Files and Apache VHost ---
print_msg "PHASE 2: Setting up WordPress Files and Apache Virtual Host..."
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
    DocumentRoot ${WEB_ROOT}
    <Directory ${WEB_ROOT}>
        AllowOverride All
    </Directory>
</VirtualHost>
EOF

a2ensite ${DOMAIN_NAME}.conf && systemctl reload apache2 || error_exit "Failed to configure Apache virtual host."

# --- PHASE 3: SSL Certificate ---
print_msg "PHASE 3: Obtaining SSL Certificate..."
# DNS Check before Certbot
SERVER_IP=$(curl -s ifconfig.me)
DOMAIN_IP=$(dig +short $DOMAIN_NAME)
if [ "$SERVER_IP" != "$DOMAIN_IP" ]; then
    error_exit "DNS Validation Failed! Domain '${DOMAIN_NAME}' does not point to this server's IP '${SERVER_IP}'. Please update your DNS and wait."
fi
certbot --apache -d ${DOMAIN_NAME} --non-interactive --agree-tos -m ${ADMIN_EMAIL} --redirect || error_exit "Certbot failed to obtain the SSL certificate."

# --- PHASE 4: Final WordPress Configuration ---
print_msg "PHASE 4: Creating wp-config.php and finalizing permissions..."
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
print_msg "✅ SUCCESS! New site '${DOMAIN_NAME}' is ready."
echo -e "${C_YELLOW}You can now visit the site to complete the WordPress installation.${C_RESET}"
echo "--------------------------------------------------"
echo -e "Site URL: ${C_GREEN}https://${DOMAIN_NAME}${C_RESET}"
echo -e "Database Name: ${C_GREEN}${DB_NAME}${C_RESET}"
echo -e "Database User: ${C_GREEN}${DB_USER}${C_RESET}"
echo -e "Database Password: ${C_GREEN}${DB_PASS}${C_RESET}"
echo "--------------------------------------------------"
