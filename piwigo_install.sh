#!/bin/sh

##############################################################################
#			PIWIGO JAIL INSTALL SCRIPT
#			Piwigo Jail Installer v2.0
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
JAIL_NAME="Piwigo_caddy"                 	# your jail name
RELEASE="13.5-RELEASE"                  # release to install
TIMEZONE="Europe/London"                # timezone
WEB_SERVER="caddy"                      # choose: caddy or nginx
PHP_VERSION="84"			# version of PHP you want to install
MARIADB_VERSION="1011"			# version of mariadb you want to install
#
INTERFACE="vnet0"                       # network interface
APP_NAME="Piwigo"                       # info file name
DB_TYPE="MariaDB"			# type of maria database
DB_NAME="piwigo"			# name of database used by Piwigo
DB_USER="piwigo"			# name of user for database used by Piwigo
#
AUTO_RAM="yes"                          # yes or no
SERVER_RAM="8"                          # used only if AUTO_RAM=no
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

##############################################################################
#                           VALIDATION
##############################################################################
echo "Starting installation..."
echo ""
echo "--------------------------------------------------"
echo "      Piwigo Jail Installation Settings v2.0"
echo "--------------------------------------------------"
echo "Jail Name           : ${JAIL_NAME}"
echo "Release             : ${RELEASE}"
echo "Web Server          : ${WEB_SERVER}"
echo "Timezone            : ${TIMEZONE}"
echo "PHP Version         : ${PHP_VERSION}"
echo "MariaDB Version     : ${MARIADB_VERSION}"
echo ""
echo "Interface           : ${INTERFACE}"
echo "Application         : ${APP_NAME}"
echo "Database Type       : ${DB_TYPE}"
echo "Database Name       : ${DB_NAME}"
echo "Database User       : ${DB_USER}"
echo ""
echo "Auto RAM Enabled    : ${AUTO_RAM}" 
echo "Effective RAM       : ${SERVER_RAM}GB"
echo "--------------------------------------------------"
echo ""
read -p "Do you want to proceed with installation? (y/n): " CONFIRM

case "$CONFIRM" in
    [Yy]) ;;
    *)
        echo "Installation cancelled."
        exit 1
        ;;
esac

if [ "$WEB_SERVER" != "caddy" ] && [ "$WEB_SERVER" != "nginx" ]; then
    echo "ERROR: WEB_SERVER must be 'caddy' or 'nginx'"
    exit 1
fi

if ! [ $(id -u) = 0 ]; then
   echo "This script must be run with root privileges"
   exit 1
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
    PHP_CHILDREN="15"
    PHP_START="4"
    PHP_MIN_SPARE="2"
    PHP_MAX_SPARE="6"
    OPCACHE_MEM="128"
    MAX_CONN="80"
    PHP_MEM="256M"
    UPLOAD_LIMIT="256M"
    INNODB_LOG="256M"

elif [ "$SERVER_RAM" = "8" ]; then
    INNODB_POOL="2G"
    PHP_CHILDREN="25"
    PHP_START="6"
    PHP_MIN_SPARE="4"
    PHP_MAX_SPARE="10"
    OPCACHE_MEM="192"
    MAX_CONN="120"
    PHP_MEM="384M"
    UPLOAD_LIMIT="384M"
    INNODB_LOG="384M"

else
    INNODB_POOL="4G"
    PHP_CHILDREN="40"
    PHP_START="10"
    PHP_MIN_SPARE="8"
    PHP_MAX_SPARE="20"
    OPCACHE_MEM="256"
    MAX_CONN="150"
    PHP_MEM="512M"
    UPLOAD_LIMIT="512M"
    INNODB_LOG="512M"
fi

##############################################################################
#                           JAIL CREATION
##############################################################################

echo "Creating jail ${JAIL_NAME}..."

if iocage get host_hostname "${JAIL_NAME}" >/dev/null 2>&1; then
    echo ""
    echo "ERROR: Jail ${JAIL_NAME} already exists!"
    echo "Destroy it or use different name in JAIL_NAME="${JAIL_NAME}""
    echo ""
    exit 1
fi

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
echo "Setting timezone...${TIMEZONE}"
iocage exec ${JAIL_NAME} sh -c "
if [ -e /etc/localtime ]; then
    rm -f /etc/localtime
fi
ln -s /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
"

##############################################################################
#                           PACKAGE INSTALL
##############################################################################
echo ""
echo "Bootstrapping pkg..."
echo ""
iocage exec ${JAIL_NAME} env ASSUME_ALWAYS_YES=yes pkg bootstrap -f
echo ""
echo "Updating packages..."
echo ""
iocage exec ${JAIL_NAME} pkg update
echo ""
echo "Installing packages..."
echo ""
# Base packages
iocage exec ${JAIL_NAME} pkg install -y \
    ImageMagick7-nox11 \
    p5-Image-ExifTool \
    mediainfo \
    unzip \
    bzip2 \
    ffmpeg \
    curl \
    wget \
    nano \
    sudo

# PHP
iocage exec ${JAIL_NAME} pkg install -y \
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
    php${PHP_VERSION}-opcache


#    php${PHP_VERSION}-extensions \
#    php${PHP_VERSION}-ctype \
#    php${PHP_VERSION}-dom \
#    php${PHP_VERSION}-iconv \
#    php${PHP_VERSION}-tokenizer \
iocage exec ${JAIL_NAME} sysrc php_fpm_enable="YES"

# MariaDB
iocage exec ${JAIL_NAME} pkg install -y \
    mariadb${MARIADB_VERSION}-server \
    mariadb${MARIADB_VERSION}-client

iocage exec ${JAIL_NAME} sysrc mysql_enable="YES"
iocage exec ${JAIL_NAME} mkdir -p /var/run/mysql
iocage exec ${JAIL_NAME} chown mysql:mysql /var/run/mysql

# Web server selection
if [ "$WEB_SERVER" = "caddy" ]; then
    iocage exec ${JAIL_NAME} pkg install -y caddy
    iocage exec ${JAIL_NAME} sysrc caddy_enable="YES"
elif [ "$WEB_SERVER" = "nginx" ]; then
    iocage exec ${JAIL_NAME} pkg install -y nginx
    iocage exec ${JAIL_NAME} sysrc nginx_enable="YES"
    iocage exec ${JAIL_NAME} mkdir -p /usr/local/etc/nginx/
fi

##############################################################################
#                           PHP + PHP-FPM Tuning
##############################################################################
echo ""
echo "Configuring PHP..."
echo ""
iocage exec ${JAIL_NAME} cp /usr/local/etc/php.ini-production /usr/local/etc/php.ini
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
echo "Applying MariaDB tuning..."
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

# CACHE
table_open_cache=4000
thread_cache_size=100

# UTF8
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
EOF"

##############################################################################
#                           DATABASE SETUP
##############################################################################
echo ""
echo "Starting MariaDB..."
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

##############################################################################
#                           PIWIGO INSTALL
##############################################################################
echo ""
echo "Downloading Piwigo..."
echo ""
iocage exec ${JAIL_NAME} mkdir -p /usr/local/www
iocage exec ${JAIL_NAME} fetch https://piwigo.org/download/dlcounter.php?code=latest -o /tmp/piwigo.zip
echo ""
echo "Extracting Piwigo files..."
iocage exec ${JAIL_NAME} unzip -q /tmp/piwigo.zip -d /usr/local/www/
echo ""
echo "Extraction complete."
echo ""

iocage exec ${JAIL_NAME} chown -R www:www /usr/local/www/piwigo
iocage exec ${JAIL_NAME} chmod -R 755 /usr/local/www/piwigo

##############################################################################
#                           WEB SERVER CONFIG
##############################################################################

if [ "$WEB_SERVER" = "nginx" ]; then
echo ""
echo "Configuring Nginx..."
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

iocage exec ${JAIL_NAME} sh -c 'cat > /usr/local/etc/nginx/nginx.conf <<EOF
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
    client_max_body_size ${UPLOAD_LIMIT};
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
EOF'

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

elif [ "$WEB_SERVER" = "caddy" ]; then
echo ""
echo "Configuring Caddy..."
echo ""

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
echo "DEBUG: UPLOAD_LIMIT = ${UPLOAD_LIMIT}"
iocage exec "${JAIL_NAME}" sh -c "cat > /usr/local/etc/caddy/Caddyfile <<EOF
:80 {

    root * /usr/local/www/piwigo

    # Enable compression (automatic brotli + gzip)
    encode zstd gzip

    # Large uploads (gallery needs this)
    request_body {
        max_size ${UPLOAD_LIMIT}
    }

    # Security headers
    header {
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "strict-origin-when-cross-origin"
        -Server
    }

    # Block hidden files except /.well-known
    @hidden {
        path /.*
        expression \`{path}.startsWith("/.") && !{path}.startsWith("/.well-known")\`
    }
    respond @hidden 403

    # Block sensitive file types
    @blockedFiles {
        path *.ini *.log *.conf *.sql
    }
    respond @blockedFiles 403

    # Prevent PHP execution in upload folder
    @uploadPhp {
        path_regexp uploadphp ^/upload/.*\.php$
    }
    respond @uploadPhp 403

    # Static assets cache (huge performance boost for gallery)
    @static {
        path *.jpg *.jpeg *.png *.gif *.webp *.avif *.svg *.css *.js *.ico
    }
    header @static Cache-Control "public, max-age=2592000"
    file_server @static

    # Main PHP handler
    php_fastcgi unix//var/run/php-fpm.sock {
        read_timeout 600s
        write_timeout 600s
    }

    file_server

    # Logging (optional but recommended)
    log {
        output file /var/log/caddy/piwigo.log
        format console
    }
}
EOF"

fi

##############################################################################
#                           START SERVICES
##############################################################################
echo ""
echo "Starting services..."
echo ""
iocage exec ${JAIL_NAME} service php_fpm start
iocage exec ${JAIL_NAME} service mysql-server restart

if [ "$WEB_SERVER" = "caddy" ]; then
    iocage exec ${JAIL_NAME} service caddy start
elif [ "$WEB_SERVER" = "nginx" ]; then
    iocage exec ${JAIL_NAME} service nginx start
fi
# Getting Jail IP
IP=$(iocage exec ${JAIL_NAME} ifconfig | awk '/inet / && $2 != "127.0.0.1" {print $2}')

##############################################################################
#                           Credentials - INFO FILE
##############################################################################

iocage exec ${JAIL_NAME} sh -c "cat > /root/${APP_NAME}-Info.txt <<EOF
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
echo "Installation complete."
echo ---------------------------------------
echo Piwigo Jail Information
echo ---------------------------------------
echo Jail Name: ${JAIL_NAME}
echo Web Server: ${WEB_SERVER}
echo PHP Version: ${PHP_VERSION}
echo MariaDB Version: ${MARIADB_VERSION}
echo ""
echo Database Name: ${DB_NAME}
echo Database User: ${DB_USER}
echo Database Password: ${DB_PASS}
echo ""
echo MariaDB Root Password: ${DB_ROOT_PASS}
echo ""
echo Piwigo Location: http://${IP}/
echo ""
echo ---------------------------------------
echo "Access your Piwigo instance via jail ${IP}."
echo "${APP_NAME}-Info.txt saved in /root/"
echo ---------------------------------------
