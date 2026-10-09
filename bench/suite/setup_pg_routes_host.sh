#!/usr/bin/env bash
# Prepare a dedicated Ubuntu 24.04 x86-64 host for the targeted PG route run.
# Run once on the new VPS: sudo bench/suite/setup_pg_routes_host.sh
#
# This installs only the Slang/Go/PostgreSQL toolchain, tunes and restarts the
# local PostgreSQL 16 instance, and pins PostgreSQL to three of four CPUs.
# Use it only on the dedicated benchmark machine; it resets the local bench
# role password and restarts PostgreSQL. It does not seed or drop benchmark
# tables.
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
. /etc/os-release
[ "$ID" = ubuntu ] || { echo "requires Ubuntu; found $PRETTY_NAME" >&2; exit 1; }
[ "$(uname -m)" = x86_64 ] || { echo "requires x86_64; found $(uname -m)" >&2; exit 1; }

GO_VERSION=1.24.1
# SHA-256 published for this archive on https://go.dev/dl/.
GO_SHA256=cb2396bae64183cdccf81a9a6df0aea3bce9511fc21469fb89a0c00470088073
GO_ARCHIVE="go${GO_VERSION}.linux-amd64.tar.gz"

read -r -a AVAILABLE_CPUS <<<"$(python3 -c 'import os; print(" ".join(map(str, sorted(os.sched_getaffinity(0)))))')"
[ "${#AVAILABLE_CPUS[@]}" -eq 4 ] || {
    echo "requires exactly four available CPUs; found ${#AVAILABLE_CPUS[@]} (${AVAILABLE_CPUS[*]})" >&2
    exit 1
}
SERVER_CPUS="${AVAILABLE_CPUS[0]},${AVAILABLE_CPUS[1]},${AVAILABLE_CPUS[2]}"
SERVER_CPUS_SYSTEMD="${AVAILABLE_CPUS[0]} ${AVAILABLE_CPUS[1]} ${AVAILABLE_CPUS[2]}"
LOADGEN_CPU=${AVAILABLE_CPUS[3]}

export DEBIAN_FRONTEND=noninteractive
echo "== install benchmark dependencies"
apt-get update -qq
apt-get install -y -qq \
    build-essential pkg-config git curl ca-certificates \
    libssl-dev libsqlite3-dev zlib1g-dev python3 \
    postgresql-16 postgresql-client-16 postgresql-contrib-16 >/dev/null

echo "== install Go $GO_VERSION"
if ! /usr/local/go/bin/go version 2>/dev/null | grep -q "go${GO_VERSION} "; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    curl -fsSLo "$tmp/$GO_ARCHIVE" -L "https://go.dev/dl/$GO_ARCHIVE"
    printf '%s  %s\n' "$GO_SHA256" "$tmp/$GO_ARCHIVE" | sha256sum -c -
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "$tmp/$GO_ARCHIVE"
    rm -rf "$tmp"
    trap - EXIT
fi
ln -sfn /usr/local/go/bin/go /usr/local/bin/go

echo "== configure PostgreSQL 16"
CONF_DIR=/etc/postgresql/16/main/conf.d
mkdir -p "$CONF_DIR"
cat >"$CONF_DIR/99-slang-pg-routes.conf" <<'EOF'
# Dedicated Slang/Go route benchmark. See bench/PG-TARGETED-BENCHMARK-PRD.md.
listen_addresses = 'localhost'
shared_preload_libraries = 'pg_stat_statements'
max_connections = 200
shared_buffers = 4GB
effective_cache_size = 10GB
work_mem = 8MB
maintenance_work_mem = 1GB
synchronous_commit = off
wal_level = minimal
max_wal_senders = 0
checkpoint_timeout = 15min
max_wal_size = 8GB
random_page_cost = 1.1
jit = off
EOF

mkdir -p /etc/systemd/system/postgresql@16-main.service.d
cat >/etc/systemd/system/postgresql@16-main.service.d/pg-routes-cpus.conf <<EOF
[Service]
CPUAffinity=$SERVER_CPUS_SYSTEMD
EOF
systemctl daemon-reload
systemctl restart postgresql@16-main

sudo -u postgres psql -X -v ON_ERROR_STOP=1 -q <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'bench') THEN
    CREATE ROLE bench LOGIN PASSWORD 'bench';
  ELSE
    ALTER ROLE bench WITH LOGIN PASSWORD 'bench';
  END IF;
END
$$;
SQL
if ! sudo -u postgres psql -X -Atq -c "SELECT 1 FROM pg_database WHERE datname = 'bench'" | grep -q '^1$'; then
    sudo -u postgres createdb -O bench bench
else
    sudo -u postgres psql -X -v ON_ERROR_STOP=1 -q -c 'ALTER DATABASE bench OWNER TO bench'
fi
sudo -u postgres psql -X -v ON_ERROR_STOP=1 -q <<'SQL'
GRANT pg_read_all_settings, pg_read_all_stats TO bench;
SQL
sudo -u postgres psql -X -d bench -v ON_ERROR_STOP=1 -q <<'SQL'
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
GRANT EXECUTE ON FUNCTION pg_stat_statements_reset(oid, oid, bigint) TO bench;
SQL

cat >/etc/security/limits.d/99-slang-pg-routes.conf <<'EOF'
* soft nofile 65535
* hard nofile 65535
EOF

echo "== versions and CPU layout"
go version
psql --version
sudo -u postgres psql -X -At -c 'SELECT version()'
echo "PostgreSQL CPUs: $SERVER_CPUS; load generator CPU: $LOADGEN_CPU"
echo "Host prepared. Log in again for the file-descriptor limit, then run:"
echo "  bench/suite/run_pg_routes.sh --plan"
echo "  bench/suite/run_pg_routes.sh"
