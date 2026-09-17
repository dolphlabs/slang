#!/usr/bin/env bash
# Prepare a dedicated Ubuntu 24.04 host (x86_64 or arm64) for bench/suite.
#
#   sudo bench/suite/setup_host.sh
#
# Installs pinned toolchains, Postgres 16 tuned per bench/suite/db, wrk and
# wrk2, and raises OS limits for tens of thousands of connections. Safe to
# re-run. Do NOT run it on a machine that serves anything: it changes
# sysctls, restarts Postgres and pins it to cores.
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
. /etc/os-release
[ "$ID" = ubuntu ] || echo "warning: tested on Ubuntu 24.04, this is $PRETTY_NAME" >&2

ARCH=$(uname -m)                      # x86_64 | aarch64
GOARCH=$([ "$ARCH" = aarch64 ] && echo arm64 || echo amd64)
NODEARCH=$([ "$ARCH" = aarch64 ] && echo arm64 || echo x64)
TARGET_USER=${SUDO_USER:-root}
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

# ---- pinned versions (update deliberately, and record why) ----
GO_VERSION=1.24.1
RUST_VERSION=1.95.0
DOTNET_CHANNEL=10.0
NODE_VERSION=22.14.0
BUN_VERSION=1.2.5
WRK2_COMMIT=44a94c17d8e6a0bac8559b53da76848e430cb7a7

# CPU split, the same default run.sh computes: server first half, load
# generator next quarter, database last quarter.
NCPU=$(nproc)
HALF=$((NCPU / 2)); QUARTER=$((NCPU / 4)); [ "$QUARTER" -lt 1 ] && QUARTER=1
DB_CPUS=${DB_CPUS:-"$((HALF + QUARTER))-$((NCPU - 1))"}

echo "== packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq build-essential pkg-config git curl unzip xz-utils ca-certificates \
    libpq-dev libssl-dev zlib1g-dev libsqlite3-dev \
    python3 python3-venv python3-dev \
    openjdk-21-jdk-headless maven \
    postgresql-16 postgresql-client-16 \
    wrk sysstat numactl >/dev/null
# python3-venv is a versioned virtual package (python3.NN-venv) and doesn't
# always get pulled in transitively (seen empty on a plain Ubuntu 24.04
# image: `python3 -m venv` then fails at ensurepip). Install the concrete
# package explicitly.
apt-get install -y -qq "python3.$(python3 -c 'import sys; print(sys.version_info[1])')-venv" >/dev/null

echo "== wrk2 ($WRK2_COMMIT)"
if ! command -v wrk2 >/dev/null; then
    rm -rf /tmp/wrk2 && git clone -q https://github.com/giltene/wrk2.git /tmp/wrk2
    (cd /tmp/wrk2 && git checkout -q "$WRK2_COMMIT")
    # Clang/GCC on Ubuntu 24.04 with -D_POSIX_C_SOURCE hide gettimeofday
    # unless <sys/time.h> is included; wrk2's pinned commit omits it.
    grep -q 'sys/time.h' /tmp/wrk2/src/script.c ||
        sed -i '1a #include <sys/time.h>' /tmp/wrk2/src/script.c
    if [ "$ARCH" = aarch64 ]; then
        # wrk2's bundled LuaJIT predates arm64; build against the system one
        apt-get install -y -qq libluajit-5.1-dev >/dev/null
        (cd /tmp/wrk2 && make -s WITH_LUAJIT=/usr WITH_OPENSSL=/usr >/dev/null)
    else
        (cd /tmp/wrk2 && make -s >/dev/null)
    fi
    install -m 755 /tmp/wrk2/wrk /usr/local/bin/wrk2
fi

echo "== Go $GO_VERSION"
if ! /usr/local/go/bin/go version 2>/dev/null | grep -q "go$GO_VERSION "; then
    rm -rf /usr/local/go
    curl -fsSL "https://go.dev/dl/go$GO_VERSION.linux-$GOARCH.tar.gz" | tar -C /usr/local -xz
fi
ln -sf /usr/local/go/bin/go /usr/local/bin/go

echo "== Rust $RUST_VERSION"
sudo -u "$TARGET_USER" -H bash -c "
  command -v rustup >/dev/null || curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain $RUST_VERSION >/dev/null
  \$HOME/.cargo/bin/rustup toolchain install $RUST_VERSION --profile minimal >/dev/null
  \$HOME/.cargo/bin/rustup default $RUST_VERSION >/dev/null"
for t in cargo rustc; do ln -sf "$TARGET_HOME/.cargo/bin/$t" /usr/local/bin/$t; done

echo "== .NET $DOTNET_CHANNEL"
if ! /usr/local/dotnet/dotnet --list-sdks 2>/dev/null | grep -q "^$DOTNET_CHANNEL"; then
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
    bash /tmp/dotnet-install.sh --channel "$DOTNET_CHANNEL" --install-dir /usr/local/dotnet >/dev/null
fi
ln -sf /usr/local/dotnet/dotnet /usr/local/bin/dotnet
cat >/etc/profile.d/dotnet-bench.sh <<'EOF'
DOTNET_CLI_TELEMETRY_OPTOUT=1
DOTNET_ROOT=/usr/local/dotnet
export DOTNET_CLI_TELEMETRY_OPTOUT DOTNET_ROOT
EOF
mkdir -p /etc/dotnet
echo /usr/local/dotnet >/etc/dotnet/install_location
echo /usr/local/dotnet >/etc/dotnet/install_location_x64
export DOTNET_ROOT=/usr/local/dotnet
export DOTNET_CLI_TELEMETRY_OPTOUT=1

echo "== Node $NODE_VERSION"
if ! node --version 2>/dev/null | grep -q "v$NODE_VERSION"; then
    curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-$NODEARCH.tar.xz" | tar -C /usr/local --strip-components=1 -xJ
fi

echo "== Bun $BUN_VERSION"
sudo -u "$TARGET_USER" -H bash -c "
  (\$HOME/.bun/bin/bun --version 2>/dev/null | grep -qx $BUN_VERSION) || curl -fsSL https://bun.sh/install | bash -s bun-v$BUN_VERSION >/dev/null"
ln -sf "$TARGET_HOME/.bun/bin/bun" /usr/local/bin/bun

echo "== Postgres 16"
CONF=/etc/postgresql/16/main/postgresql.conf
if ! grep -q 'slang bench' "$CONF"; then
    { echo; echo "# ---- slang bench (bench/suite/db/postgresql.bench.conf) ----"; cat "$(dirname "$0")/db/postgresql.bench.conf"; } >>"$CONF"
fi
mkdir -p /etc/systemd/system/postgresql@16-main.service.d
cat >/etc/systemd/system/postgresql@16-main.service.d/bench-cpus.conf <<EOF
[Service]
CPUAffinity=$(echo "$DB_CPUS" | tr ',' ' ')
EOF
if command -v systemctl >/dev/null && systemctl is-system-running >/dev/null 2>&1; then
    systemctl daemon-reload
    systemctl restart postgresql@16-main
else
    # Containers without systemd: start the cluster with pg_ctlcluster.
    pg_ctlcluster 16 main stop >/dev/null 2>&1 || true
    pg_ctlcluster 16 main start
fi
# Optional CPU pin when taskset is available (systemd Affinity is a no-op without systemd).
if command -v taskset >/dev/null; then
    PG_PID=$(head -1 /var/lib/postgresql/16/main/postmaster.pid 2>/dev/null || true)
    if [ -n "${PG_PID:-}" ]; then
        taskset -pc $(echo "$DB_CPUS" | tr '-' ',') "$PG_PID" >/dev/null 2>&1 ||
            taskset -pc "${DB_CPUS%%-*}" "$PG_PID" >/dev/null 2>&1 || true
    fi
fi
sudo -u postgres psql -q -c "DO \$\$BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'bench') THEN CREATE ROLE bench LOGIN PASSWORD 'bench'; END IF;
END\$\$;"
sudo -u postgres psql -Atq -c "SELECT 1 FROM pg_database WHERE datname = 'bench'" | grep -q 1 ||
    sudo -u postgres createdb -O bench bench
# the harness reads data_directory to find the postmaster for CPU sampling
sudo -u postgres psql -q -c "GRANT pg_read_all_settings TO bench"

echo "== OS limits"
cat >/etc/sysctl.d/90-slang-bench.conf <<'EOF'
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.core.netdev_max_backlog = 65535
fs.file-max = 4194304
vm.swappiness = 1
EOF
sysctl -q --system || true
cat >/etc/security/limits.d/90-slang-bench.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
EOF
if command -v cpupower >/dev/null; then cpupower frequency-set -g performance >/dev/null 2>&1 || true; fi
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -w "$g" ] && echo performance >"$g" 2>/dev/null || true
done

echo
echo "== versions"
for c in "cc --version" "go version" "rustc --version" "dotnet --version" "java -version" "mvn -v" \
         "python3 --version" "node --version" "bun --version" "psql --version" "wrk -v" "wrk2 -v"; do
    printf '%-18s %s\n' "${c%% *}" "$($c 2>&1 | head -1)"
done
echo
echo "Host ready. Postgres pinned to cpus $DB_CPUS. Log out and back in for the"
echo "file-descriptor limit, then: QUICK=1 bench/suite/run.sh"
