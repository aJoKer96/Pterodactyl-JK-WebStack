#!/bin/bash
set -Eeuo pipefail

BASE_DIR=/home/container
PUBLIC_DIR="${BASE_DIR}/public"
CONFIG_DIR="${BASE_DIR}/config"
DATABASE_DIR="${BASE_DIR}/database"
LOG_DIR="${BASE_DIR}/logs"
RUN_DIR="${BASE_DIR}/run"
TMP_DIR="${BASE_DIR}/tmp"
MARIADB_RUN_DIR="${RUN_DIR}/mariadb"
APACHE_RUN_DIR="${RUN_DIR}/apache2"
PMA_TMP_DIR="${TMP_DIR}/phpmyadmin"
DB_ENV_FILE="${CONFIG_DIR}/database.env"
PMA_SECRET_FILE="${CONFIG_DIR}/phpmyadmin.secret"
APACHE_CONFIG="${CONFIG_DIR}/apache2.generated.conf"
MARIADB_CONFIG="${CONFIG_DIR}/my.cnf"
MARIADB_SOCKET="${MARIADB_RUN_DIR}/mariadb.sock"

WEB_PORT="${SERVER_PORT:?SERVER_PORT is required}"
PMA_PORT="${PHPMYADMIN_PORT:?PHPMYADMIN_PORT is required}"
DATABASE_NAME="${DATABASE_NAME:-webapp}"
DATABASE_USER="${DATABASE_USER:-webapp}"
DATABASE_ADMIN_USER="${DATABASE_ADMIN_USER:-webadmin}"

MARIADB_PID=""
APACHE_PID=""
SHUTTING_DOWN=0

log() {
    printf '[webstack] %s\n' "$*"
}

fatal() {
    printf '[webstack] ERROR: %s\n' "$*" >&2
    exit 1
}

validate_identifier() {
    local value="$1"
    local label="$2"
    [[ "$value" =~ ^[A-Za-z0-9_]{1,64}$ ]] || fatal "${label} must match ^[A-Za-z0-9_]{1,64}$"
}

validate_port() {
    local value="$1"
    local label="$2"
    [[ "$value" =~ ^[0-9]+$ ]] || fatal "${label} must be numeric"
    (( value >= 1024 && value <= 65535 )) || fatal "${label} must be between 1024 and 65535"
}

validate_identifier "$DATABASE_NAME" "DATABASE_NAME"
validate_identifier "$DATABASE_USER" "DATABASE_USER"
validate_identifier "$DATABASE_ADMIN_USER" "DATABASE_ADMIN_USER"
validate_port "$WEB_PORT" "SERVER_PORT"
validate_port "$PMA_PORT" "PHPMYADMIN_PORT"
[[ "$WEB_PORT" != "$PMA_PORT" ]] || fatal "SERVER_PORT and PHPMYADMIN_PORT must be different"

mkdir -p \
    "$PUBLIC_DIR" \
    "$CONFIG_DIR" \
    "$DATABASE_DIR" \
    "$LOG_DIR" \
    "$MARIADB_RUN_DIR" \
    "$APACHE_RUN_DIR" \
    "$PMA_TMP_DIR"

chmod 0700 "$CONFIG_DIR"
chmod 0755 "$PUBLIC_DIR" "$LOG_DIR" "$RUN_DIR" "$TMP_DIR" "$MARIADB_RUN_DIR" "$APACHE_RUN_DIR" "$PMA_TMP_DIR"

if [[ ! -s "$PMA_SECRET_FILE" ]]; then
    umask 077
    openssl rand -hex 16 > "$PMA_SECRET_FILE"
    log "Generated persistent phpMyAdmin cookie secret."
fi
chmod 0600 "$PMA_SECRET_FILE"

export WEB_PORT PMA_PORT
envsubst '${WEB_PORT} ${PMA_PORT}' \
    < /opt/webstack/templates/apache2.conf.template \
    > "$APACHE_CONFIG"
cp /opt/webstack/templates/my.cnf "$MARIADB_CONFIG"
chmod 0600 "$APACHE_CONFIG" "$MARIADB_CONFIG"

if [[ ! -f "$PUBLIC_DIR/index.php" ]]; then
    cat > "$PUBLIC_DIR/index.php" <<'PHP'
<?php
header('Content-Type: text/plain; charset=utf-8');

if (isset($_GET['webstack_rewrite'])) {
    echo "mod_rewrite=ok\n";
    exit;
}

echo "Pterodactyl Webstack OK\n";
echo "PHP=" . PHP_VERSION . "\n";
echo "Rewrite test: /__webstack/rewrite-test\n";
PHP
fi

if [[ ! -f "$PUBLIC_DIR/.htaccess" ]]; then
    cat > "$PUBLIC_DIR/.htaccess" <<'HTACCESS'
RewriteEngine On
RewriteRule ^__webstack/rewrite-test/?$ index.php?webstack_rewrite=1 [END,QSA]
HTACCESS
fi

load_credentials() {
    [[ -s "$DB_ENV_FILE" ]] || fatal "Database credentials file is missing: ${DB_ENV_FILE}"
    # shellcheck disable=SC1090
    source "$DB_ENV_FILE"
}

write_credentials() {
    local root_password app_password admin_password
    root_password="$(openssl rand -hex 24)"
    app_password="$(openssl rand -hex 24)"
    admin_password="$(openssl rand -hex 24)"

    umask 077
    cat > "$DB_ENV_FILE" <<EOF_CREDENTIALS
DB_HOST=127.0.0.1
DB_PORT=3306
DB_NAME=${DATABASE_NAME}
DB_USER=${DATABASE_USER}
DB_PASSWORD=${app_password}
DB_ADMIN_USER=${DATABASE_ADMIN_USER}
DB_ADMIN_PASSWORD=${admin_password}
DB_ROOT_PASSWORD=${root_password}
EOF_CREDENTIALS
    chmod 0600 "$DB_ENV_FILE"
}

start_mariadb() {
    mariadbd --defaults-file="$MARIADB_CONFIG" &
    MARIADB_PID=$!
}

wait_for_mariadb_noauth() {
    local i
    for i in $(seq 1 60); do
        if mariadb-admin --protocol=socket --socket="$MARIADB_SOCKET" -u root ping --silent >/dev/null 2>&1; then
            return 0
        fi
        if ! kill -0 "$MARIADB_PID" 2>/dev/null; then
            fatal "MariaDB exited during initial startup"
        fi
        sleep 1
    done
    fatal "MariaDB did not become ready during initial startup"
}

wait_for_mariadb_auth() {
    local i
    for i in $(seq 1 60); do
        if MYSQL_PWD="$DB_ADMIN_PASSWORD" mariadb-admin \
            --protocol=tcp \
            --host=127.0.0.1 \
            --port=3306 \
            --user="$DB_ADMIN_USER" \
            ping --silent >/dev/null 2>&1; then
            return 0
        fi
        if ! kill -0 "$MARIADB_PID" 2>/dev/null; then
            fatal "MariaDB exited during startup"
        fi
        sleep 1
    done
    fatal "MariaDB did not become ready"
}

initialize_database() {
    log "Initializing MariaDB data directory..."
    mariadb-install-db \
        --defaults-file="$MARIADB_CONFIG" \
        --auth-root-authentication-method=normal \
        --skip-test-db >/dev/null

    write_credentials
    load_credentials

    start_mariadb
    wait_for_mariadb_noauth

    log "Creating database and local application/admin users..."
    mariadb --protocol=socket --socket="$MARIADB_SOCKET" -u root <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
CREATE USER IF NOT EXISTS '${DB_ADMIN_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_ADMIN_PASSWORD}';
ALTER USER '${DB_ADMIN_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_ADMIN_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO '${DB_ADMIN_USER}'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL

    MYSQL_PWD="$DB_ROOT_PASSWORD" mariadb-admin \
        --protocol=socket \
        --socket="$MARIADB_SOCKET" \
        -u root shutdown
    wait "$MARIADB_PID" || true
    MARIADB_PID=""

    log "MariaDB initialized. Credentials: config/database.env"
}

shutdown_services() {
    local exit_code="${1:-0}"

    if (( SHUTTING_DOWN == 1 )); then
        return
    fi
    SHUTTING_DOWN=1

    log "Stopping webstack..."

    if [[ -n "$APACHE_PID" ]] && kill -0 "$APACHE_PID" 2>/dev/null; then
        kill -TERM "$APACHE_PID" 2>/dev/null || true
    fi

    if [[ -n "$MARIADB_PID" ]] && kill -0 "$MARIADB_PID" 2>/dev/null; then
        if [[ -n "${DB_ADMIN_PASSWORD:-}" ]]; then
            MYSQL_PWD="$DB_ADMIN_PASSWORD" mariadb-admin \
                --protocol=tcp \
                --host=127.0.0.1 \
                --port=3306 \
                --user="$DB_ADMIN_USER" \
                shutdown >/dev/null 2>&1 || kill -TERM "$MARIADB_PID" 2>/dev/null || true
        else
            kill -TERM "$MARIADB_PID" 2>/dev/null || true
        fi
    fi

    [[ -z "$APACHE_PID" ]] || wait "$APACHE_PID" 2>/dev/null || true
    [[ -z "$MARIADB_PID" ]] || wait "$MARIADB_PID" 2>/dev/null || true

    exit "$exit_code"
}

trap 'shutdown_services 0' INT TERM

if [[ ! -d "$DATABASE_DIR/mysql" ]]; then
    initialize_database
fi

load_credentials

if [[ "$DB_NAME" != "$DATABASE_NAME" || "$DB_USER" != "$DATABASE_USER" || "$DB_ADMIN_USER" != "$DATABASE_ADMIN_USER" ]]; then
    log "WARNING: Database variables changed after first initialization."
    log "Persistent credentials in config/database.env remain authoritative."
fi

start_mariadb
wait_for_mariadb_auth

apache2 -f "$APACHE_CONFIG" -DFOREGROUND &
APACHE_PID=$!

sleep 1
if ! kill -0 "$APACHE_PID" 2>/dev/null; then
    wait "$APACHE_PID" || true
    fatal "Apache exited during startup"
fi

log "ready web=${WEB_PORT} phpmyadmin=${PMA_PORT} database=127.0.0.1:3306"

set +e
wait -n "$MARIADB_PID" "$APACHE_PID"
EXIT_CODE=$?
set -e

log "A managed service exited with status ${EXIT_CODE}; stopping the stack."
shutdown_services "$EXIT_CODE"
