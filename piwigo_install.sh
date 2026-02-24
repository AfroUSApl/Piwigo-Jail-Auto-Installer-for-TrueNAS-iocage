#!/bin/sh

##############################################################################
#			PIWIGO JAIL INSTALL SCRIPT
#			TrueNAS CORE 13.5-RELEASE
#	Caddy/Nginx + PHP 8.3/8.4 + MariaDB 10.11 + RAM Tuning Profiles
##############################################################################
# 
##############################################################################
# ---------------------------- USER CONFIGURATION ----------------------------
# -------------------------- run this before start: --------------------------
# ------------------------ chmod +x piwigo_install.sh ------------------------
##############################################################################
#
#
#
JAIL_NAME="Piwigo_nginx"                # your jail name
RELEASE="13.5-RELEASE"                  # release to install
TIMEZONE="Europe/London"                # timezone
WEB_SERVER="nginx"                      # choose: caddy or nginx
PHP_VERSION="84"			# version of PHP you want to install
MARIADB_VERSION="1011"			# version of mariadb you want to install
#
INTERFACE="vnet0"                       # network interface
DB_TYPE="MariaDB"			# type of maria database
DB_NAME="piwigo"			# name of database used by Piwigo
DB_USER="piwigo"			# name of user for database used by Piwigo
#
AUTO_RAM="yes"                          # yes or no
SERVER_RAM="8"                          # used only if AUTO_RAM=no
VER="2.2"				# script version
#
#
#
##############################################################################
#                           Password Auto-Generator
##############################################################################

DB_ROOT_PASS=$(openssl rand -base64 15)	# autogenerate password for database root
DB_PASS=$(openssl rand -base64 15)	# autogenerate password for database user

##############################################################################
#                           AUTO RAM DETECTION
##############################################################################

if [ "$AUTO_RAM" = "yes" ]; then
    TOTAL_RAM_BYTES=$(sysctl -n hw.physmem)
    TOTAL_RAM_GB=$((TOTAL_RAM_BYTES / 1024 / 1024 / 1024))

    echo "Detected system RAM: ${TOTAL_RAM_GB} GB"

    if [ "$TOTAL_RAM_GB" -le 4 ]; then
        SERVER_RAM="4"
    elif [ "$TOTAL_RAM_GB" -le 8 ]; then
        SERVER_RAM="8"
    else
        SERVER_RAM="16"
    fi
# Artificially capping tuning to 16GB
    echo "AUTO_RAM enabled → Using ${SERVER_RAM}GB profile"
else
    echo "AUTO_RAM disabled → Using manual ${SERVER_RAM}GB profile"
fi

# SAFETY CHECK
if [ "$SERVER_RAM" != "4" ] && \
   [ "$SERVER_RAM" != "8" ] && \
   [ "$SERVER_RAM" != "16" ]; then
    echo "ERROR: SERVER_RAM must be 4, 8, or 16"
    exit 1
fi
#RAM profile assignment block
if [ "$SERVER_RAM" = "4" ]; then
    INNODB_POOL="1G"
    INNODB_LOG="256M"
    TMP_TABLE="32M"
    PHP_CHILDREN="15"
    OPCACHE_MEM="128"
    MAX_CONN="80"
    PHP_MEM="256M"
    UPLOAD_LIMIT="256M"

elif [ "$SERVER_RAM" = "8" ]; then
    INNODB_POOL="2G"
    INNODB_LOG="384M"
    TMP_TABLE="64M"
    PHP_CHILDREN="25"
    OPCACHE_MEM="192"
    MAX_CONN="120"
    PHP_MEM="384M"
    UPLOAD_LIMIT="384M"

else
    INNODB_POOL="4G"
    INNODB_LOG="512M"
    TMP_TABLE="128M"
    PHP_CHILDREN="40"
    OPCACHE_MEM="256"
    MAX_CONN="150"
    PHP_MEM="512M"
    UPLOAD_LIMIT="512M"
fi

##############################################################################
#                           COLOR DEFINITIONS
##############################################################################
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
CYAN="\033[1;36m"
BOLD="\033[1m"
NC="\033[0m"

section() {
    echo ""
    printf "${BLUE}${BOLD}======================================================================${NC}\n"
    printf "${BLUE}${BOLD} %-20s${NC}%s\n" "" "$1"
    printf "${BLUE}${BOLD}======================================================================${NC}\n"
}

ok() {
    printf "${GREEN}[✔ OK]${NC} %s\n" "$1"
}

error_msg() {
    printf "${RED}[✘ ERROR]${NC} %s\n" "$1"
}

info() {
    printf "${CYAN}[🛈]${NC} %s\n" "$1"
}

progress() {
    printf "${YELLOW}→${NC} %s\n" "$1"
}

##############################################################################
#                           VALIDATION
##############################################################################
echo ""
section "PIWIGO JAIL INSTALLER ${VER}"
echo ""
printf "${YELLOW}${BOLD} %-22s :${NC} %s\n" "Jail Name"        "${JAIL_NAME}"
printf "${YELLOW}${BOLD} %-22s :${NC} %s\n" "Release"          "${RELEASE}"
printf "${YELLOW}${BOLD} %-22s :${NC} %s\n" "Web Server"       "${WEB_SERVER}"
printf "${YELLOW}${BOLD} %-22s :${NC} %s\n" "PHP Version"      "8.${PHP_VERSION}"
printf "${YELLOW}${BOLD} %-22s :${NC} %s\n" "MariaDB Version"  "${MARIADB_VERSION}"
printf "${YELLOW}${BOLD} %-22s :${NC} %s\n" "Timezone"         "${TIMEZONE}"
echo ""
printf "${YELLOW}${BOLD} %-22s :${NC} %s\n" "Network Interface" "${INTERFACE}"
printf "${YELLOW}${BOLD} %-22s :${NC} %s\n" "Database Type"     "${DB_TYPE}"
printf "${YELLOW}${BOLD} %-22s :${NC} %s\n" "Database Name"     "${DB_NAME}"
printf "${YELLOW}${BOLD} %-22s :${NC} %s\n" "Database User"     "${DB_USER}"
echo ""
printf "${YELLOW}${BOLD} %-22s :${NC} %s\n" "Auto RAM Detection" "${AUTO_RAM}"
printf "${YELLOW}${BOLD} %-22s :${NC} %s GB\n" "Effective RAM Class" "${SERVER_RAM}"
echo ""
printf "${BLUE}${BOLD}======================================================================${NC}\n"
echo ""

read -p "Do you want to proceed with installation? (y/n): " CONFIRM
case "$CONFIRM" in
    [Yy]) ok "User confirmed installation." ;;
    *) error_msg "Installation cancelled."; exit 1 ;;
esac

if [ "$WEB_SERVER" != "caddy" ] && [ "$WEB_SERVER" != "nginx" ]; then
    error_msg "ERROR: WEB_SERVER must be 'caddy' or 'nginx' !"
    exit 1
fi

if ! [ $(id -u) = 0 ]; then
   error_msg "This script must be run with root privileges"
   exit 1
fi


##############################################################################
#                           JAIL CREATION
##############################################################################

echo ""

progress "Checking if jail ${JAIL_NAME} exists..."
if iocage get host_hostname "${JAIL_NAME}" >/dev/null 2>&1; then
    error_msg "Jail ${JAIL_NAME} already exists!"
    echo ""
    exit 1
fi
ok "No jail ${JAIL_NAME} detected..."
echo ""
echo "→ Proceeding with installation."
#if iocage get host_hostname "${JAIL_NAME}" >/dev/null 2>&1; then
#    echo ""
#    echo "ERROR: Jail ${JAIL_NAME} already exists!"
#    echo "Destroy it or use different name in JAIL_NAME="${JAIL_NAME}""
#    echo ""
#    exit 1
#fi

iocage create -n "${JAIL_NAME}" \
  -r "${RELEASE}" \
  boot=on \
  dhcp=on \
  bpf="yes" \
  vnet=on

iocage start "${JAIL_NAME}"
    
# Fix /tmp permissions (CRITICAL for MariaDB and pkg)
iocage exec ${JAIL_NAME} chown root:wheel /tmp
iocage exec ${JAIL_NAME} chmod 1777 /tmp

iocage exec ${JAIL_NAME} mkdir -p /usr/local/www/piwigo/galleries
iocage exec ${JAIL_NAME} mkdir -p /usr/local/www/piwigo/upload
iocage exec ${JAIL_NAME} mkdir -p /usr/local/www/piwigo/local/config

# Setting timezone
echo "→ Setting timezone to ${TIMEZONE}"
iocage exec ${JAIL_NAME} sh -c "
if [ -e /etc/localtime ]; then
    rm -f /etc/localtime
fi
ln -s /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
"
ok "Done."
##############################################################################
#                           PACKAGE INSTALL
##############################################################################
echo ""
echo "→ Bootstrapping pkg..."
echo ""
iocage exec ${JAIL_NAME} env ASSUME_ALWAYS_YES=yes pkg bootstrap -f
ok "Done."
echo ""
echo "→ Updating packages..."
echo ""
iocage exec ${JAIL_NAME} pkg update -f
ok "Done."
echo ""
echo "→ Installing packages..."
echo ""
echo "→ Base packages..."
echo "ImageMagick7-nox11, p5-Image-ExifTool, mediainfo, unzip bzip2, ffmpeg, curl, wget, nano, sudo"
printf "Please wait..."

spinner() {
    pid=$1
    spin='|/-\'
    i=0
    
    tput civis 2>/dev/null

    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i+1) % 4 ))
        case $i in
            0) char='|' ;;
            1) char='/' ;;
            2) char='-' ;;
            3) char='\' ;;
        esac
        printf "\r\033[1;33m[%s] Processing...\033[0m" "$char"
        sleep 0.1
    done

    wait "$pid"
    status=$?
    tput cnorm 2>/dev/null
    
    if [ $status -eq 0 ]; then
        echo""
        printf "\r\033[1;32m[✔ OK]\033[0m Done.         \033[0m\n"
    else
        echo ""
        printf "\r\033[1;31m[✘ ] Failed.          \033[0m\n"
        exit 1
    fi
}

iocage exec ${JAIL_NAME} pkg install -y -q \
    ImageMagick7-nox11 \
    p5-Image-ExifTool \
    mediainfo \
    unzip \
    bzip2 \
    ffmpeg \
    curl \
    wget \
    nano \
    sudo &
spinner $!
echo ""
ok "Base packages installed correctly!"
ok "Done."
echo ""
section "Installing PHP${PHP_VERSION}"
iocage exec ${JAIL_NAME} pkg install -y -q \
    php${PHP_VERSION} \
    php${PHP_VERSION}-curl \
    php${PHP_VERSION}-intl \
    php${PHP_VERSION}-exif \
    php${PHP_VERSION}-filter \
    php${PHP_VERSION}-fileinfo \
    php${PHP_VERSION}-gd \
    php${PHP_VERSION}-mbstring \
    php${PHP_VERSION}-mysqli \
    php${PHP_VERSION}-pdo \
    php${PHP_VERSION}-pdo_mysql \
    php${PHP_VERSION}-session \
    php${PHP_VERSION}-simplexml \
    php${PHP_VERSION}-sodium \
    php${PHP_VERSION}-xml \
    php${PHP_VERSION}-zlib \
    php${PHP_VERSION}-zip \
    php${PHP_VERSION}-opcache &
spinner $!

iocage exec ${JAIL_NAME} sysrc php_fpm_enable="YES"

# MariaDB
echo "→ Installing mariadb ${MARIADB_VERSION} server..."
iocage exec ${JAIL_NAME} pkg install -y -q mariadb${MARIADB_VERSION}-server
ok "Done."
echo ""
echo "→ Installing mariadb${MARIADB_VERSION}-client..."
iocage exec ${JAIL_NAME} pkg install -y -q mariadb${MARIADB_VERSION}-client
ok "Done."
echo "→ Activating mariadb${MARIADB_VERSION} service..."
iocage exec ${JAIL_NAME} sysrc mysql_enable="YES"
iocage exec ${JAIL_NAME} mkdir -p /var/run/mysql
iocage exec ${JAIL_NAME} chown mysql:mysql /var/run/mysql
ok "Done."

# Web server selection
if [ "$WEB_SERVER" = "caddy" ]; then
    echo "→ Installing CADDY..."
    iocage exec ${JAIL_NAME} pkg install -y -q caddy
    iocage exec ${JAIL_NAME} sysrc caddy_enable="YES"
    ok "Done."
elif [ "$WEB_SERVER" = "nginx" ]; then
    echo "→ Installing NGINX..."
    iocage exec ${JAIL_NAME} pkg install -y -q nginx
    iocage exec ${JAIL_NAME} sysrc nginx_enable="YES"
    iocage exec ${JAIL_NAME} mkdir -p /usr/local/etc/nginx/
    ok "Done."
fi
ok "$WEB_SERVER installed correctly!"
##############################################################################
#                           PHP + PHP-FPM Tuning
##############################################################################
echo ""
section "Configuring PHP..."
echo ""
iocage exec ${JAIL_NAME} cp /usr/local/etc/php.ini-production /usr/local/etc/php.ini
ok "Done."
##############################################################################
#                           PHP-FPM Pool Tuning
##############################################################################
# PHP-FPM Pool
# Disables default www pool (prevents socket conflicts)
# Creates dedicated piwigo pool
# Uses Unix socket (faster than TCP)
# Restricts socket permissions to www
# Uses dynamic process manager
# Allows 40 concurrent PHP workers
# Starts 10 workers initially
# Keeps spare workers ready
# Recycles workers after 500 requests
# Sets request timeout to 300s
# This is tuned for:
# Burst image uploads
# Gallery browsing spikes
# Moderate concurrency
echo ""
echo "→ Applying PHP-FPM tuning..."
echo ""
printf " %-64s : %s\n" "Maximum simultaneous PHP requests the server can process at once"        "${PHP_CHILDREN}"
printf " %-64s : %s\n" "Number of PHP workers started immediately at service launch"        "${PHP_START}"
printf " %-64s : %s\n" "Minimum idle PHP workers kept ready for sudden traffic spikes"        "${PHP_MIN_SPARE}"
printf " %-64s : %s\n" "Maximum idle workers allowed before scaling down"        "${PHP_MAX_SPARE}"
echo ""
iocage exec ${JAIL_NAME} sh -c "
# Disable default www pool
mv /usr/local/etc/php-fpm.d/www.conf \
   /usr/local/etc/php-fpm.d/www.conf.disabled 2>/dev/null || true

# Create dedicated Piwigo pool
cat > /usr/local/etc/php-fpm.d/piwigo.conf <<EOF
[piwigo]
user = www
group = www

listen = /var/run/php-fpm.sock
listen.owner = www
listen.group = www
listen.mode = 0660

pm = dynamic
pm.max_children = ${PHP_CHILDREN}
pm.start_servers = ${PHP_START}
pm.min_spare_servers = ${PHP_MIN_SPARE}
pm.max_spare_servers = ${PHP_MAX_SPARE}
pm.max_requests = 500
request_terminate_timeout = 300
EOF
"
ok "Done."
##############################################################################
#                           php.ini Tuning
##############################################################################
# Sets memory_limit to 512MB (large image processing safe)
# Sets upload_max_filesize to 512MB
# Sets post_max_size to 512MB
# Increases max_execution_time to 300 seconds
# Disables cgi.fix_pathinfo (security hardening)
# Enables OPcache
# Allocates 256MB OPcache memory
# Sets 20,000 cached PHP scripts
# Optimizes interned string buffer
# Reduces OPcache revalidation frequency
# 
# Why this matters:
# OPcache dramatically reduces PHP CPU usage.
# 512MB memory prevents large RAW image failures.
echo ""
echo "→ Applying PHP core tuning (php.ini)..."
echo ""
printf " %-60s : %s\n" "Maximum memory a single PHP script may consume"        "${PHP_MEM}"
printf " %-60s : %s\n" "Maximum allowed file upload size"        "${UPLOAD_LIMIT}"
printf " %-60s : %s\n" "Maximum total POST request size [must match upload limit]"        "${UPLOAD_LIMIT}"
printf " %-60s : %s\n" "OPcache memory reserved for compiled PHP scripts"        "${OPCACHE_MEM}M"
echo ""
iocage exec ${JAIL_NAME} sh -c "
sed -i '' \
-e 's|^memory_limit = .*|memory_limit = ${PHP_MEM}|' \
-e 's|^upload_max_filesize = .*|upload_max_filesize = ${UPLOAD_LIMIT}|' \
-e 's|^post_max_size = .*|post_max_size = ${UPLOAD_LIMIT}|' \
-e 's|^max_execution_time = .*|max_execution_time = 300|' \
-e 's|^;*cgi.fix_pathinfo=.*|cgi.fix_pathinfo=0|' \
-e 's|^;*opcache.enable=.*|opcache.enable=1|' \
-e 's|^;*opcache.memory_consumption=.*|opcache.memory_consumption=${OPCACHE_MEM}|' \
-e 's|^;*opcache.interned_strings_buffer=.*|opcache.interned_strings_buffer=16|' \
-e 's|^;*opcache.max_accelerated_files=.*|opcache.max_accelerated_files=20000|' \
-e 's|^;*opcache.revalidate_freq=.*|opcache.revalidate_freq=60|' \
/usr/local/etc/php.ini
"
ok "Done."
##############################################################################
#                           MariaDB Tuning
##############################################################################
# This version MariaDB tuning:
# Binds database to localhost only (security)
# Allocates 4GB InnoDB buffer pool (primary performance boost)
# Increases InnoDB log file size (better write performance)
# Uses O_DIRECT (avoids double caching)
# Enables per-table storage (better table management)
# Allows 150 concurrent connections
# Increases table_open_cache (important for CMS)
# Increases thread_cache_size (faster connection reuse)
# Enables utf8mb4 (full Unicode support, emoji safe)
# Uses utf8mb4_unicode_ci collation
echo ""
section "Applying MariaDB tuning..."
echo ""
printf " %-50s : %s\n" "InnoDB buffer pool size [database cache in RAM]"        "${INNODB_POOL}"
printf " %-50s : %s\n" "InnoDB log file size [write performance buffer]"        "${INNODB_LOG}"
printf " %-50s : %s\n" "Maximum concurrent database connections"        "${MAX_CONN}"
echo ""
iocage exec ${JAIL_NAME} mkdir -p /usr/local/etc/mysql/conf.d
iocage exec ${JAIL_NAME} sh -c "cat > /usr/local/etc/mysql/conf.d/piwigo.cnf <<EOF
[mysqld]
bind-address=127.0.0.1

# PERFORMANCE
innodb_buffer_pool_size=${INNODB_POOL}
innodb_log_file_size=${INNODB_LOG}
innodb_flush_method=O_DIRECT
innodb_file_per_table=1

# CONNECTIONS
max_connections=${MAX_CONN}

# Temp tables
tmp_table_size = ${TMP_TABLE}
max_heap_table_size = ${TMP_TABLE}

# CACHE
table_open_cache=4000
thread_cache_size=100

# UTF8
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
EOF"
ok "Done."
##############################################################################
#                           DATABASE SETUP
##############################################################################
echo ""
section "Starting MariaDB..."
echo ""
iocage exec ${JAIL_NAME} service mysql-server start

sleep 5

iocage exec ${JAIL_NAME} mysql -u root <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';
CREATE DATABASE ${DB_NAME};
CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
ok "Done."
##############################################################################
#                           PIWIGO INSTALL
##############################################################################
echo ""
section "Installing Piwigo"
echo ""
echo "→ Downloading Piwigo..."
iocage exec ${JAIL_NAME} mkdir -p /usr/local/www
iocage exec ${JAIL_NAME} fetch https://piwigo.org/download/dlcounter.php?code=latest -o /tmp/piwigo.zip
ok "Done."
echo ""
echo "→ Extracting Piwigo files..."
iocage exec ${JAIL_NAME} unzip -q /tmp/piwigo.zip -d /usr/local/www/
ok "Extraction complete."
echo ""

echo "→ Setting up permission for /usr/local/www/piwigo"
iocage exec ${JAIL_NAME} chown -R www:www /usr/local/www/piwigo
iocage exec ${JAIL_NAME} chmod -R 755 /usr/local/www/piwigo
ok "Done."
echo ""
ok "PIWIGO Installed!"

##############################################################################
#                           WEB SERVER CONFIG
##############################################################################

if [ "$WEB_SERVER" = "nginx" ]; then
echo ""
section "Configuring Nginx..."
echo ""
##############################################################################
#                           nginx.conf (Global Tuning)
##############################################################################
# Loads mail + stream modules
# Auto-detects CPU cores
# Increases worker connections
# Enables kqueue (FreeBSD optimized)
# Enables sendfile (zero-copy file transfer)
# Enables TCP optimizations (nopush, nodelay)
# Reduces keepalive timeout to 30s
# Allows 1000 keepalive requests
# Hides nginx version (server_tokens off)
# Enables large upload buffers
# Increases header buffers
# Tunes FastCGI buffers
# Extends FastCGI timeout (300s)
# Enables gzip compression
# Optimizes gzip types
# Enables open_file_cache
# Increases file descriptor efficiency
# Loads virtual host configs from conf.d
echo ""
echo "→ Applying Nginx tuning..."
echo ""
printf " %-50s : %s\n" "Maximum allowed HTTP upload size"        "${UPLOAD_LIMIT}"
printf " %-50s : %s\n" "FastCGI buffer tuning for PHP performance"        "Enabled"
printf " %-50s : %s\n" "Static file caching enabled for faster image delivery"        "30 days"
printf " %-50s : %s\n" "Gzip compression enabled for reduced bandwidth usage"        "Yes"
echo ""

cat <<'EOF' | sed "s/__UPLOAD_LIMIT__/${UPLOAD_LIMIT}/" | \
iocage exec "${JAIL_NAME}" tee /usr/local/etc/nginx/nginx.conf > /dev/null
load_module /usr/local/libexec/nginx/ngx_mail_module.so;
load_module /usr/local/libexec/nginx/ngx_stream_module.so;

# Use all CPU cores automatically
worker_processes auto;

error_log  /var/log/nginx-error.log warn;
pid        /var/run/nginx.pid;

events {
    worker_connections  4096;
    multi_accept on;
    use kqueue;
}

http {
    include       mime.types;
    default_type  application/octet-stream;

    # Performance
    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;

    keepalive_timeout  30;
    keepalive_requests 1000;

    types_hash_max_size 2048;

    server_tokens off;
    disable_symlinks off;

    # Buffer tuning for uploads
    client_max_body_size __UPLOAD_LIMIT__;
    client_body_buffer_size 512k;
    client_header_buffer_size 8k;
    large_client_header_buffers 4 32k;

    # FastCGI tuning (important for PHP)
    fastcgi_buffers 32 16k;
    fastcgi_buffer_size 32k;
    fastcgi_read_timeout 300;

    # Gzip compression
    gzip on;
    gzip_comp_level 5;
    gzip_min_length 1024;
    gzip_proxied any;
    gzip_types
        text/plain
        text/css
        text/xml
        text/javascript
        application/javascript
        application/json
        application/xml
        application/rss+xml
        image/svg+xml;

    # Static file cache (very important for gallery performance)
    open_file_cache max=5000 inactive=30s;
    open_file_cache_valid 60s;
    open_file_cache_min_uses 2;
    open_file_cache_errors on;

    # Load site configs
    include /usr/local/etc/nginx/conf.d/*.conf;
}
EOF

iocage exec ${JAIL_NAME} mkdir -p /usr/local/etc/nginx/conf.d
iocage exec ${JAIL_NAME} sh -c 'cat > /usr/local/etc/nginx/conf.d/piwigo.conf <<EOF
upstream piwigo-handler {
    server unix:/var/run/php-fpm.sock;
}

server {
    listen 80;
    server_name piwigo.example.com;

    root /usr/local/www/piwigo;
    index index.php index.html;

    # Upload limit (can override global if needed)
    client_max_body_size 200M;

    # Timeouts for large uploads
    client_header_timeout 300s;
    client_body_timeout 300s;

    # Robots
    location = /robots.txt {
        allow all;
        log_not_found off;
        access_log off;
    }

    # Block hidden files
    location ~ /\.(?!well-known).* {
        deny all;
    }

    # Block config/log files
    location ~* \.(ini|log|conf|sql)$ {
        deny all;
    }

    # Static assets (very important for gallery)
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|webp|avif)$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
        access_log off;
        log_not_found off;
    }

    # Prevent PHP execution inside uploads
    location ~* ^/upload/.*\.php$ {
        deny all;
    }

    # Main routing
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    # PHP handler
    location ~ \.php(?:$|/) {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_index index.php;

        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;

        fastcgi_pass piwigo-handler;
        fastcgi_intercept_errors on;

        fastcgi_send_timeout 600s;
        fastcgi_read_timeout 600s;
    }
}
EOF'
ok "Nginx Setup Done."

elif [ "$WEB_SERVER" = "caddy" ]; then
echo ""
section "Configuring Caddy..."
echo ""
ok "Done."
##############################################################################
#                           Caddyfile Tuning – What This Version Does
##############################################################################
# Uses port 80
# Enables automatic HTTP compression (zstd + gzip)
# Sets large upload limit (512MB)
# Adds security headers (clickjacking, MIME sniffing, referrer policy)
# Hides server signature
# Blocks hidden files except .well-known
# Blocks sensitive file types (.ini, .log, .conf, .sql)
# Prevents PHP execution inside /upload
# Adds long-term static cache headers (30 days)
# Optimizes image delivery
# Uses Unix socket for PHP-FPM
# Extends PHP timeouts for large uploads
# Enables structured logging
# Keeps configuration clean (Caddy smart defaults)
echo ""
echo "→ Applying Caddy tuning..."
echo ""
printf " %-55s : %s\n" "Maximum allowed HTTP upload size"        "${UPLOAD_LIMIT}"
printf " %-55s : %s\n" "PHP-FPM communication via Unix socket for performance"        "/var/run/php-fpm.sock"
printf " %-55s : %s\n" "Static file caching enabled for faster image delivery"        "30 days"
echo ""
cat <<'EOF' | sed "s/__UPLOAD_LIMIT__/${UPLOAD_LIMIT}/" | \
iocage exec "${JAIL_NAME}" tee /usr/local/etc/caddy/Caddyfile > /dev/null
:80 {

    root * /usr/local/www/piwigo

    encode zstd gzip

    request_body {
        max_size __UPLOAD_LIMIT__
    }

    header {
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "strict-origin-when-cross-origin"
        -Server
    }

    @hidden {
        path /.*
        expression `{path}.startsWith("/.") && !{path}.startsWith("/.well-known")`
    }
    respond @hidden 403

    @blockedFiles {
        path *.ini *.log *.conf *.sql
    }
    respond @blockedFiles 403

    @uploadPhp {
        path_regexp uploadphp ^/upload/.*\.php$
    }
    respond @uploadPhp 403

    @static {
        path *.jpg *.jpeg *.png *.gif *.webp *.avif *.svg *.css *.js *.ico
    }
    header @static Cache-Control "public, max-age=2592000"
    file_server @static

    php_fastcgi unix//var/run/php-fpm.sock {
        read_timeout 600s
        write_timeout 600s
    }

    file_server

    log {
        output file /var/log/caddy/piwigo.log
        format console
    }
}

EOF
ok "Done."
echo""
ok "Caddy Setup Done."

fi

##############################################################################
#                           START SERVICES
##############################################################################
echo ""
section "Starting services..."
echo ""
iocage exec ${JAIL_NAME} service php_fpm start
iocage exec ${JAIL_NAME} service mysql-server restart

if [ "$WEB_SERVER" = "caddy" ]; then
    iocage exec ${JAIL_NAME} service caddy start &
spinner $!
elif [ "$WEB_SERVER" = "nginx" ]; then
    iocage exec ${JAIL_NAME} service nginx start &
spinner $!
fi
# Getting Jail IP
IP=$(iocage exec ${JAIL_NAME} ifconfig | awk '/inet / && $2 != "127.0.0.1" {print $2}')
echo ""
ok "Done"
##############################################################################
#                           Credentials - INFO FILE
##############################################################################

iocage exec ${JAIL_NAME} sh -c "cat > /root/credentials.txt <<EOF
---------------------------------------
Piwigo Jail Information
---------------------------------------
Jail Name: ${JAIL_NAME}
Web Server: ${WEB_SERVER}
PHP Version: ${PHP_VERSION}
MariaDB Version: ${MARIADB_VERSION}

Database Name: ${DB_NAME}
Database User: ${DB_USER}
Database Password: ${DB_PASS}

MariaDB Root Password: ${DB_ROOT_PASS}

Piwigo Location:
http://${IP}/

---------------------------------------
EOF"

echo ""
ok "Installation complete !"
echo ""
section "Piwigo Jail Information"
echo ""
printf "${YELLOW}${BOLD} %-22s :${NC} %s\n" "Jail Name"        "${JAIL_NAME}"
printf "${YELLOW}${BOLD} %-22s :${NC} %s\n" "Web Server"        "${WEB_SERVER}"
printf "${YELLOW}${BOLD} %-22s :${NC} %s\n" "PHP Version"        "${PHP_VERSION}"
printf "${YELLOW}${BOLD} %-22s :${NC} %s\n" "MariaDB Version"        "${MARIADB_VERSION}"
echo ""
printf "${YELLOW}${BOLD} %-22s :${NC} %s\n" "Database Name"        "${DB_NAME}"
printf "${YELLOW}${BOLD} %-22s :${NC} %s\n" "Database User"        "${DB_USER}"
printf "${YELLOW}${BOLD} %-22s :${NC} %s\n" "Database Password"        "${DB_PASS}"
echo ""
printf "${YELLOW}${BOLD} %-22s :${NC} %s\n" "MariaDB Root Password"        "${DB_ROOT_PASS}"
echo ""
printf "${YELLOW}${BOLD} %-22s :${NC} %s\n" "Piwigo Location"        "http://${IP}/"
echo ""
printf "${BLUE}${BOLD}======================================================================${NC}\n"
printf "${CYAN}${BOLD} 🛈  Access Piwigo via ${BLUE}http://${IP}. ${NC}\n"
echo ""
printf "${CYAN}${BOLD} 🛈  ${YELLOW}credentials.txt ${CYAN}saved in /root/ directory inside ${JAIL_NAME}.${NC}\n"
echo ""
printf "${CYAN}${BOLD} 🛈  Use ${YELLOW}127.0.0.1 ${CYAN}instead of ${YELLOW}localhost ${CYAN}in DB Configuration${NC}\n"
printf "${BLUE}${BOLD}======================================================================${NC}\n"
echo ""
