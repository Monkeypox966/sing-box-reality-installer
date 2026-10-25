#!/bin/sh
# ============================================================================
# setup-sing-box.sh
# Alpine Linux one-shot installer for sing-box VLESS + Reality.
# ============================================================================
set -eu

PORT=""
EXT_PORT=""
IPV6_EXT_PORT=""
IP_MODE="dual"
SNI="images.apple.com"
VERSION="latest"
DNS_OPT=""
CUSTOM_HOST=""
ALLOW_PROXY=0
EXPECTED_SHA256=""
SING_BOX_GOMEMLIMIT="${SING_BOX_GOMEMLIMIT:-64MiB}"
SING_BOX_GOGC="${SING_BOX_GOGC:-50}"
MIN_TMP_FREE_KB="${MIN_TMP_FREE_KB:-180000}"

CONFIG_DIR="/etc/sing-box"
BIN_PATH="/usr/local/bin/sing-box"
SERVICE_PATH="/etc/init.d/sing-box"
ERROR_LOG="/var/log/sing-box-error.log"
FALLBACK_VERSION="1.14.4"

INSTALL_TMP_DIR=""
TARBALL=""
EXTRACT_DIR=""
API_JSON=""
TEMP_CONF=""
NEW_BIN=""
TEMP_INIT=""
TEMP_CLIENT=""
BACKUP_SUFFIX=""
BIN_BAK=""
CONFIG_BAK=""
INIT_BAK=""
CLIENT_BAK=""
SERVICE_WAS_RUNNING=0
SERVICE_WAS_ENABLED=0
DEPLOYMENT_STARTED=0
DEPLOYMENT_COMMITTED=0
INSTALL_LOCK_HELD=0
INSTALL_LOCK_DIR="/run/sing-box-setup.lock"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

warn() {
  echo "WARN: $*" >&2
}

usage() {
  exit_code="${1:-1}"
  cat <<USAGE
Usage: $0 -p <internal-port> [options]

Required:
  -p  Internal listening port from your NAT VPS provider panel.

Options:
  -e  External mapped port for the client link. Defaults to -p.
  -E  IPv6 client port. Defaults to -e; use -p's value for native IPv6 on NAT VPS.
  -H  Client connection host, IP, or domain. Recommended for NAT VPS.
  -i  IP listen mode: 4, 6, or dual. Default: dual.
  -s  Reality SNI camouflage domain. Default: images.apple.com.
  -d  Custom DNS server IP. Domain names are intentionally rejected.
  -v  sing-box version without leading v. Default: latest.
  -S  Expected SHA256 of the release tarball.
  -P  Allow third-party GitHub proxy download, only with SHA256 verification.
  -h  Show this help.

Environment:
  INSTALL_TMP_PARENT  Disk-backed install temp parent. Default: /root.
  MIN_TMP_FREE_KB     Required free space for install temp parent. Default: 180000.
  SING_BOX_GOMEMLIMIT Go memory limit for sing-box commands/service. Default: 64MiB.
  SING_BOX_GOGC       Go GC percentage for sing-box commands/service. Default: 50.
  ALLOW_TMPFS_TMP=1   Allow /tmp fallback even when it is memory-backed. Not recommended.
USAGE
  exit "$exit_code"
}

cleanup() {
  if [ "$DEPLOYMENT_STARTED" = 1 ] && [ "$DEPLOYMENT_COMMITTED" != 1 ]; then
    rollback || warn "rollback was incomplete; inspect the saved backups"
  fi
  [ -n "$INSTALL_TMP_DIR" ] && rm -rf "$INSTALL_TMP_DIR"
  [ -n "$TARBALL" ] && rm -f "$TARBALL"
  [ -n "$API_JSON" ] && rm -f "$API_JSON"
  [ -n "$TEMP_CONF" ] && rm -f "$TEMP_CONF"
  [ -n "$NEW_BIN" ] && rm -f "$NEW_BIN"
  [ -n "$TEMP_INIT" ] && rm -f "$TEMP_INIT"
  [ -n "$TEMP_CLIENT" ] && rm -f "$TEMP_CLIENT"
  [ -n "$EXTRACT_DIR" ] && rm -rf "$EXTRACT_DIR"
  if [ "$INSTALL_LOCK_HELD" = 1 ]; then
    rm -f "$INSTALL_LOCK_DIR/pid"
    rmdir "$INSTALL_LOCK_DIR" || true
  fi
  return 0
}

acquire_install_lock() {
  mkdir "$INSTALL_LOCK_DIR" 2>/dev/null || return 1
  INSTALL_LOCK_HELD=1
  printf '%s\n' "$$" >"$INSTALL_LOCK_DIR/pid"
}

is_uint_port() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$1" | awk 'length($0) > 10 || $0 + 0 < 1 || $0 + 0 > 65535 { exit 1 }'
}

is_domain_name() {
  [ "${#1}" -le 253 ] || return 1
  printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$'
}

has_only_host_chars() {
  case "$1" in
    ''|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.:-]*) return 1 ;;
    *) return 0 ;;
  esac
}

is_valid_custom_host() {
  host="$1"

  case "$host" in
    *'['*|*']'*)
      case "$host" in
        \[*\]) inner="${host#\[}"; inner="${inner%\]}" ;;
        *) return 1 ;;
      esac
      case "$inner" in
        *'['*|*']'*) return 1 ;;
      esac
      ;;
    *) inner="$host" ;;
  esac

  has_only_host_chars "$inner" || return 1

  case "$inner" in
    *:*) is_ipv6_address "$inner" ;;
    *[!0-9.]*) is_domain_name "$inner" ;;
    *) is_ipv4_address "$inner" ;;
  esac
}

is_safe_ip_literal() {
  case "$1" in
    *:*) is_ipv6_address "$1" ;;
    *) is_ipv4_address "$1" ;;
  esac
}

is_safe_version() {
  [ "$1" = "latest" ] && return 0
  printf '%s\n' "$1" | grep -Eq '^[0-9]+[.][0-9]+[.][0-9]+([-._~A-Za-z0-9]+)?$'
}

is_sha256() {
  printf '%s\n' "$1" | grep -Eq '^[0-9A-Fa-f]{64}$'
}

# YAML scalar addresses must not use URI-style IPv6 square brackets.
normalize_yaml_host() {
  case "$1" in
    \[*\]) host="${1#\[}"; printf '%s\n' "${host%\]}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

is_ipv4_address() {
  printf '%s\n' "$1" | awk -F. '
    NF != 4 { exit 1 }
    { for (i = 1; i <= NF; i++) if ($i !~ /^[0-9]+$/ || length($i) > 3 || $i + 0 > 255) exit 1 }
  '
}

is_ipv6_address() {
  case "$1" in
    ''|*[!0-9A-Fa-f:]*) return 1 ;;
  esac
  printf '%s\n' "$1" | awk '
    function groups(side, parts, count, i) {
      if (side == "") return 0
      count = split(side, parts, ":")
      for (i = 1; i <= count; i++) if (length(parts[i]) < 1 || length(parts[i]) > 4) return -100
      return count
    }
    {
      halves = split($0, sides, "::")
      if (halves == 1) exit groups($0) == 8 ? 0 : 1
      if (halves != 2) exit 1
      left = groups(sides[1]); right = groups(sides[2])
      exit left >= 0 && right >= 0 && left + right < 8 ? 0 : 1
    }
  '
}

is_public_ipv6_address() {
  candidate="$(printf '%s' "$1" | tr 'A-F' 'a-f')"
  is_ipv6_address "$candidate" || return 1
  case "$candidate" in
    ::|::1|::ffff:*|fe8*|fe9*|fea*|feb*|fc*|fd*|ff*) return 1 ;;
  esac
  # Also reject expanded spellings of the unspecified / loopback address.
  printf '%s\n' "$candidate" | awk '
    { value=$0; gsub(/0+/, "", value); gsub(/:/, "", value)
      if (value == "") exit 1
      if (value == "1" && $0 ~ /:0*1$/) exit 1
    }
  '
}

detect_public_ipv4() {
  for endpoint in https://api.ipify.org https://ifconfig.me/ip; do
    candidate="$(wget -4 -qO- -T 5 -t 1 "$endpoint" 2>/dev/null)" || continue
    candidate="$(printf '%s' "$candidate" | tr -d '\r')"
    if is_ipv4_address "$candidate"; then printf '%s\n' "$candidate"; return 0; fi
  done
  return 1
}

detect_public_ipv6() {
  for endpoint in https://api6.ipify.org https://ifconfig.me/ip; do
    candidate="$(wget -6 -qO- -T 5 -t 1 "$endpoint" 2>/dev/null)" || continue
    candidate="$(printf '%s' "$candidate" | tr -d '\r')"
    if is_public_ipv6_address "$candidate"; then printf '%s\n' "$candidate"; return 0; fi
  done
  return 1
}

print_yaml_node() {
  node_name="$1"
  node_host="$(normalize_yaml_host "$2")"
  node_port="$EXT_PORT"
  [ "$node_name" != reality-ipv6 ] || node_port="${IPV6_EXT_PORT:-$EXT_PORT}"
  cat <<EOF
  - name: "${node_name}"
    type: vless
    server: "${node_host}"
    port: ${node_port}
    uuid: "${UUID}"
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: "${SNI}"
    reality-opts:
      public-key: "${PUBLIC_KEY}"
      short-id: "${SHORT_ID}"
    client-fingerprint: chrome
EOF
}

print_client_yaml() {
  ipv4_host=""
  ipv6_host=""
  custom_domain=""
  if [ -n "$CUSTOM_HOST" ]; then
    configured_host="$(normalize_yaml_host "$CUSTOM_HOST")"
    case "$configured_host" in
      *:*)
        ipv6_host="$configured_host"
        [ "$IP_MODE" != dual ] || ipv4_host="$(detect_public_ipv4 || true)"
        ;;
      *)
        if is_ipv4_address "$configured_host"; then
          ipv4_host="$configured_host"
        else
          custom_domain="$configured_host"
          ipv4_host=""
        fi
        [ "$IP_MODE" != dual ] || ipv6_host="$(detect_public_ipv6 || true)"
        ;;
    esac
  else
    case "$IP_MODE" in
      4) ipv4_host="$(detect_public_ipv4 || true)" ;;
      6) ipv6_host="$(detect_public_ipv6 || true)" ;;
      dual)
        ipv4_host="$(detect_public_ipv4 || true)"
        ipv6_host="$(detect_public_ipv6 || true)"
        ;;
    esac
  fi
  printf 'proxies:\n'
  [ -z "$custom_domain" ] || print_yaml_node reality-custom "$custom_domain"
  [ -z "$ipv4_host" ] || print_yaml_node reality-ipv4 "$ipv4_host"
  [ -z "$ipv6_host" ] || print_yaml_node reality-ipv6 "$ipv6_host"
  if [ -z "$custom_domain$ipv4_host$ipv6_host" ]; then
    warn 'public address detection failed; replace the placeholder server or rerun with -H'
    print_yaml_node reality-manual '<server-ip-or-domain>'
  fi
}

path_fs_type() {
  target="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  best_len=0
  best_type=""

  while read -r _dev mount type _rest; do
    if [ "$mount" = "/" ]; then
      matched=1
    else
      matched=0
      case "$target" in
        "$mount"|"$mount"/*) matched=1 ;;
      esac
    fi
    if [ "$matched" = "1" ]; then
      mount_len="${#mount}"
      if [ "$mount_len" -ge "$best_len" ]; then
        best_len="$mount_len"
        best_type="$type"
      fi
    fi
  done < /proc/mounts

  [ -n "$best_type" ] || return 1
  printf '%s\n' "$best_type"
}

is_memory_fs() {
  fs_type="$(path_fs_type "$1" 2>/dev/null || echo unknown)"
  case "$fs_type" in
    tmpfs|ramfs) return 0 ;;
    *) return 1 ;;
  esac
}

path_free_kb() {
  df -Pk "$1" 2>/dev/null | awk 'NR == 2 { print $4 }'
}

try_install_tmp_parent() {
    parent="$1"
    [ -d "$parent" ] || mkdir -p "$parent" 2>/dev/null || return 1
    [ -w "$parent" ] || return 1
    if is_memory_fs "$parent" && { [ "$parent" != /tmp ] || [ "${ALLOW_TMPFS_TMP:-0}" != 1 ]; }; then
      warn "skipping $parent because it is mounted on memory-backed filesystem"
      return 1
    fi

    free_kb="$(path_free_kb "$parent" || echo 0)"
    case "$free_kb" in
      ''|*[!0-9]*) free_kb=0 ;;
    esac
    if [ "$free_kb" -lt "$MIN_TMP_FREE_KB" ]; then
      warn "skipping $parent because free space is below ${MIN_TMP_FREE_KB}KB"
      return 1
    fi

    if INSTALL_TMP_DIR="$(mktemp -d "${parent%/}/sing-box-install.XXXXXX" 2>/dev/null)"; then
      chmod 700 "$INSTALL_TMP_DIR"
      return 0
    fi
  return 1
}

create_install_tmp_dir() {
  try_install_tmp_parent "${INSTALL_TMP_PARENT:-/root}" && return 0
  try_install_tmp_parent /var/tmp && return 0
  if [ "${ALLOW_TMPFS_TMP:-0}" = 1 ]; then try_install_tmp_parent /tmp && return 0; fi
  return 1
}

run_sing_box() {
  GOMEMLIMIT="$SING_BOX_GOMEMLIMIT" GOGC="$SING_BOX_GOGC" "$@"
}

fetch_direct() {
  # Avoid overwriting download_asset's global url when trying proxy fallbacks.
  wget -q -T 15 -t 2 -O "$2" "$1"
}

extract_release_tag() {
  jq -er '.tag_name | select(type == "string" and startswith("v")) | ltrimstr("v")' "$1"
}

extract_asset_digest() {
  jq -er --arg name "$2" '.assets[]? | select(.name == $name) | .digest |
    select(type == "string" and test("^sha256:[A-Fa-f0-9]{64}$")) | ltrimstr("sha256:")' "$1"
}

download_asset() {
  url="$1"
  out="$2"

  if fetch_direct "$url" "$out"; then
    return 0
  fi

  [ "$ALLOW_PROXY" = "1" ] || return 1
  [ -n "$EXPECTED_SHA256" ] || die "proxy download requires -S or GitHub API sha256 digest"

  warn "direct GitHub download failed; trying proxy mirrors with sha256 verification"
  for proxy in "https://gh-proxy.com/" "https://ghproxy.net/" "https://mirror.ghproxy.com/"; do
    echo "Trying proxy: $proxy"
    if fetch_direct "${proxy}${url}" "$out"; then
      return 0
    fi
  done

  return 1
}

verify_sha256_if_available() {
  file="$1"

  if [ -z "$EXPECTED_SHA256" ]; then
    warn "no sha256 digest available; direct GitHub TLS is the only authenticity check"
    return 0
  fi

  actual="$(sha256sum "$file" | awk '{print $1}')"
  expected_lc="$(printf '%s\n' "$EXPECTED_SHA256" | tr 'A-F' 'a-f')"
  actual_lc="$(printf '%s\n' "$actual" | tr 'A-F' 'a-f')"

  [ "$actual_lc" = "$expected_lc" ] || die "sha256 mismatch for downloaded tarball"
  echo ">> SHA256 verification passed"
}

restore_backup_or_remove() {
  restore_backup="$1"
  restore_target="$2"
  restore_mode="$3"
  if [ -n "$restore_backup" ] && [ -f "$restore_backup" ]; then
    restore_tmp="$(mktemp "${restore_target}.restore.XXXXXX")" || return 1
    if ! cp "$restore_backup" "$restore_tmp" || ! chmod "$restore_mode" "$restore_tmp" || ! mv -f "$restore_tmp" "$restore_target"; then
      rm -f "$restore_tmp"
      return 1
    fi
  else
    rm -f "$restore_target"
  fi
}

rollback() {
  warn "deployment did not complete; restoring the previous installation"
  rollback_failed=0
  # Stop only this service before restoring its executable and configuration.
  rc-service sing-box stop >/dev/null 2>&1 || true
  if [ "$SERVICE_WAS_ENABLED" != 1 ]; then
    rc-update del sing-box default >/dev/null 2>&1 || true
  fi
  restore_backup_or_remove "$BIN_BAK" "$BIN_PATH" 755 || rollback_failed=1
  restore_backup_or_remove "$CONFIG_BAK" "$CONFIG_DIR/config.json" 600 || rollback_failed=1
  restore_backup_or_remove "$INIT_BAK" "$SERVICE_PATH" 755 || rollback_failed=1
  restore_backup_or_remove "$CLIENT_BAK" "$CONFIG_DIR/client-info.txt" 600 || rollback_failed=1
  if [ "$SERVICE_WAS_RUNNING" = 1 ]; then
    if ! rc-service sing-box restart >/dev/null 2>&1; then
      warn "could not restart the previous service; saved backups are still available"
      rollback_failed=1
    fi
  fi
  [ "$rollback_failed" = 0 ]
}

print_service_failure_context() {
  warn "sing-box did not stay running"
  rc-service sing-box status >&2 2>/dev/null || true
  if [ -s "$ERROR_LOG" ]; then
    warn "recent $ERROR_LOG:"
    tail -n 40 "$ERROR_LOG" >&2 || true
  fi
}

write_vless_inbound() {
  inbound_listen="$1"
  inbound_tag="$2"
  cat <<EOF
    {
      "type": "vless",
      "tag": "${inbound_tag}",
      "listen": "${inbound_listen}",
      "listen_port": ${PORT},
      "users": [
        {
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${SNI}",
            "server_port": 443
          },
          "private_key": "${PRIVATE_KEY}",
          "short_id": [
            "${SHORT_ID}"
          ]
        }
      }
    }
EOF
}

write_server_config() {
  cat <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "remote-dns",
        "type": "udp",
        "server": "${DNS_SERVER}"
      }
    ],
    "strategy": "${STRATEGY}"
  },
  "inbounds": [
EOF
  write_vless_inbound "$LISTEN_ADDR" vless-in
  if [ "$IP_MODE" = dual ] && [ "${BINDV6ONLY:-0}" = 1 ]; then
    printf ',\n'
    write_vless_inbound 0.0.0.0 vless-in-v4
  fi
  cat <<EOF
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
}

write_openrc_service() {
  sed "s/:=64MiB/:=${SING_BOX_GOMEMLIMIT}/; s/:=50/:=${SING_BOX_GOGC}/" <<'EOF'
#!/sbin/openrc-run
name="sing-box"
description="sing-box daemon"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
supervisor="supervise-daemon"
respawn_delay="1"
respawn_max="5"
respawn_period="60"
output_log="/dev/null"
error_log="/var/log/sing-box-error.log"

: ${SING_BOX_GOMEMLIMIT:=64MiB}
: ${SING_BOX_GOGC:=50}
export GOMEMLIMIT="$SING_BOX_GOMEMLIMIT"
export GOGC="$SING_BOX_GOGC"

depend() {
    need net
    after firewall
}

start_pre() {
    if ! "$command" check -c /etc/sing-box/config.json >/dev/null; then
        eerror "config check failed; aborting start"
        return 1
    fi
}
EOF
}

configure_listen_mode() {
  ipv6_disabled="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0)"
  if [ "$ipv6_disabled" = 1 ]; then
    case "$IP_MODE" in
      dual) warn "IPv6 is disabled by the host; using IPv4 only"; IP_MODE=4 ;;
      6) die "IPv6 is disabled by the host" ;;
    esac
  fi
case "$IP_MODE" in
  4)
    LISTEN_ADDR="0.0.0.0"
    STRATEGY="ipv4_only"
    DNS_SERVER="${DNS_OPT:-8.8.8.8}"
    ;;
  6)
    LISTEN_ADDR="::"
    STRATEGY="ipv6_only"
    DNS_SERVER="${DNS_OPT:-2001:4860:4860::8888}"
    ;;
  dual)
    LISTEN_ADDR="::"
    STRATEGY="prefer_ipv6"
    DNS_SERVER="${DNS_OPT:-8.8.8.8}"
    ;;
  *) die "-i must be 4, 6, or dual" ;;
esac
BINDV6ONLY="$(sysctl -n net.ipv6.bindv6only 2>/dev/null || echo "0")"
if [ "$IP_MODE" = "dual" ] && [ "$BINDV6ONLY" = "1" ]; then
  echo ">> IPv6-only sockets detected; adding a separate IPv4 listener"
elif [ "$IP_MODE" = "6" ] && [ "$BINDV6ONLY" = "0" ]; then
  warn "net.ipv6.bindv6only=0; IPv6 listen on :: may also accept IPv4"
fi
}

# Test entry point: loading definitions must never install or restart anything.
if [ "${SING_BOX_SETUP_LIBRARY_ONLY:-0}" = 1 ]; then
  return 0
fi

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

umask 077
while getopts "p:e:E:H:i:s:v:d:S:hP" opt; do
  case "$opt" in
    p) PORT="$OPTARG" ;;
    e) EXT_PORT="$OPTARG" ;;
    E) IPV6_EXT_PORT="$OPTARG" ;;
    H) CUSTOM_HOST="$OPTARG" ;;
    i) IP_MODE="$OPTARG" ;;
    s) SNI="$OPTARG" ;;
    v) VERSION="$OPTARG" ;;
    d) DNS_OPT="$OPTARG" ;;
    S) EXPECTED_SHA256="$OPTARG" ;;
    P) ALLOW_PROXY=1 ;;
    h) usage 0 ;;
    *) usage 1 ;;
  esac
done
shift $((OPTIND - 1))
[ "$#" -eq 0 ] || die "unexpected positional argument: $1"

if [ -z "$PORT" ]; then
  if [ -t 0 ]; then
    printf "Internal port: "
    IFS= read -r PORT || PORT=""
  fi
  [ -n "$PORT" ] || { echo "ERROR: -p is required" >&2; usage 1; }
fi

[ -z "$EXT_PORT" ] && EXT_PORT="$PORT"
[ -n "$IPV6_EXT_PORT" ] || IPV6_EXT_PORT="$EXT_PORT"

is_uint_port "$PORT" || die "internal port must be 1-65535"
is_uint_port "$EXT_PORT" || die "external port must be 1-65535"
is_uint_port "$IPV6_EXT_PORT" || die "IPv6 external port must be 1-65535"
# JSON numbers cannot have leading zeroes.
PORT="$(printf '%s\n' "$PORT" | awk '{printf "%d\n", $0 + 0}')"
EXT_PORT="$(printf '%s\n' "$EXT_PORT" | awk '{printf "%d\n", $0 + 0}')"
IPV6_EXT_PORT="$(printf '%s\n' "$IPV6_EXT_PORT" | awk '{printf "%d\n", $0 + 0}')"
is_safe_version "$VERSION" || die "invalid version format"
is_domain_name "$SNI" || die "invalid SNI domain"
case "$SING_BOX_GOMEMLIMIT" in
  off) ;;
  *) printf '%s\n' "$SING_BOX_GOMEMLIMIT" | grep -Eq '^[0-9]+(B|KiB|MiB|GiB|TiB)$' || die "invalid SING_BOX_GOMEMLIMIT" ;;
esac
case "$SING_BOX_GOGC" in
  off) ;;
  ''|*[!0-9]*) die "invalid SING_BOX_GOGC" ;;
esac
case "$MIN_TMP_FREE_KB" in ''|*[!0-9]*) die "invalid MIN_TMP_FREE_KB" ;; esac

if [ -n "$CUSTOM_HOST" ]; then
  is_valid_custom_host "$CUSTOM_HOST" || die "invalid custom host; do not include a port, use -e for the external port"
fi

if [ -n "$DNS_OPT" ]; then
  is_safe_ip_literal "$DNS_OPT" || die "DNS must be an IPv4 or IPv6 literal"
fi

if [ -n "$EXPECTED_SHA256" ]; then
  is_sha256 "$EXPECTED_SHA256" || die "invalid sha256 format"
fi

configure_listen_mode

[ "$(id -u)" -eq 0 ] || die "please run as root"
if [ ! -f /etc/alpine-release ] || ! command -v apk >/dev/null 2>&1; then
  die "this installer requires Alpine Linux with OpenRC"
fi
if ! acquire_install_lock; then
  die "another installation may be running; inspect /run/sing-box-setup.lock/pid before retrying"
fi

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) SB_ARCH="amd64" ;;
  aarch64) SB_ARCH="arm64" ;;
  armv7l) SB_ARCH="armv7" ;;
  *) die "unsupported architecture: $ARCH" ;;
esac


echo ">> Installing dependencies"
apk add --no-cache wget tar ca-certificates openrc openssl jq

echo ">> Syncing time"
ntpd -q -p pool.ntp.org 2>/dev/null || warn "time sync failed; continuing"

echo ">> Checking SNI TLS 1.3 support"
if timeout 8 openssl s_client -connect "${SNI}:443" -servername "$SNI" -tls1_3 -brief </dev/null 2>&1 | grep -q "TLSv1.3"; then
  echo ">> SNI supports TLS 1.3"
else
  warn "$SNI may not support TLS 1.3, or the check timed out"
fi

create_install_tmp_dir || die "failed to create a disk-backed install temp directory; set INSTALL_TMP_PARENT to a writable non-tmpfs path"
echo ">> Using install temp directory: $INSTALL_TMP_DIR"
TARBALL="${INSTALL_TMP_DIR}/sing-box.tar.gz"
EXTRACT_DIR="${INSTALL_TMP_DIR}/extract"
API_JSON="${INSTALL_TMP_DIR}/release.json"
mkdir -p "$EXTRACT_DIR"
: > "$API_JSON"

if [ "$VERSION" = "latest" ]; then
  echo ">> Resolving latest sing-box version"
  if fetch_direct "https://api.github.com/repos/SagerNet/sing-box/releases/latest" "$API_JSON"; then
    VERSION="$(extract_release_tag "$API_JSON" || true)"
  fi
  if [ -z "$VERSION" ] || [ "$VERSION" = "latest" ]; then
    warn "failed to resolve latest; falling back to $FALLBACK_VERSION"
    VERSION="$FALLBACK_VERSION"
    : > "$API_JSON"
  fi
fi
is_safe_version "$VERSION" || die "official release response contained an invalid version"

ASSET_NAME="sing-box-${VERSION}-linux-${SB_ARCH}-musl.tar.gz"
DL_URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/${ASSET_NAME}"

if [ -z "$EXPECTED_SHA256" ]; then
  if ! grep -q '"tag_name"' "$API_JSON" 2>/dev/null; then
    fetch_direct "https://api.github.com/repos/SagerNet/sing-box/releases/tags/v${VERSION}" "$API_JSON" || true
  fi
  if grep -q '"assets"' "$API_JSON" 2>/dev/null; then
    EXPECTED_SHA256="$(extract_asset_digest "$API_JSON" "$ASSET_NAME" || true)"
  fi
fi

if [ "$ALLOW_PROXY" = "1" ] && [ -z "$EXPECTED_SHA256" ]; then
  die "-P requires a sha256 digest from GitHub API or explicit -S"
fi

echo ">> Downloading sing-box v${VERSION} (${SB_ARCH})"
download_asset "$DL_URL" "$TARBALL" || die "download failed"
verify_sha256_if_available "$TARBALL"

tar -tzf "$TARBALL" >/dev/null 2>&1 || die "tarball is corrupt or incomplete"
tar -zxf "$TARBALL" -C "$EXTRACT_DIR"
rm -f "$TARBALL"
TARBALL=""

SB_BIN="$(find "$EXTRACT_DIR" -type f -name sing-box | head -n 1 || true)"
[ -n "$SB_BIN" ] || die "sing-box binary not found in tarball"
chmod 755 "$SB_BIN"

echo ">> Generating credentials"
UUID="$(run_sing_box "$SB_BIN" generate uuid)"
KEYPAIR="$(run_sing_box "$SB_BIN" generate reality-keypair)"
PRIVATE_KEY="$(printf '%s\n' "$KEYPAIR" | awk '/PrivateKey/ {print $2}')"
PUBLIC_KEY="$(printf '%s\n' "$KEYPAIR" | awk '/PublicKey/ {print $2}')"
SHORT_ID="$(run_sing_box "$SB_BIN" generate rand --hex 4)"

[ -n "$UUID" ] || die "UUID generation failed"
[ -n "$PRIVATE_KEY" ] || die "Reality private key generation failed"
[ -n "$PUBLIC_KEY" ] || die "Reality public key generation failed"
[ -n "$SHORT_ID" ] || die "Reality short id generation failed"

mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

TEMP_CONF="${CONFIG_DIR}/config.json.new.$$"
write_server_config > "$TEMP_CONF"
chmod 600 "$TEMP_CONF"

echo ">> Validating new config with new binary"
run_sing_box "$SB_BIN" check -c "$TEMP_CONF" >/dev/null || die "new config validation failed; current service was not touched"

TEMP_INIT="$(mktemp "${SERVICE_PATH}.new.XXXXXX")"
write_openrc_service >"$TEMP_INIT"
chmod 755 "$TEMP_INIT"
sh -n "$TEMP_INIT"
TEMP_CLIENT="$(mktemp "${CONFIG_DIR}/client-info.new.XXXXXX")"
echo ">> Resolving IPv4 and IPv6 client addresses"
print_client_yaml >"$TEMP_CLIENT"

BIN_DIR="$(dirname "$BIN_PATH")"
mkdir -p "$BIN_DIR"
NEW_BIN="${BIN_DIR}/.sing-box.new.$$"
mv "$SB_BIN" "$NEW_BIN"
chmod 755 "$NEW_BIN"
rm -rf "$EXTRACT_DIR"
EXTRACT_DIR=""

BACKUP_SUFFIX="$(date +%Y%m%d%H%M%S).$$"
BIN_BAK="${BIN_PATH}.bak.${BACKUP_SUFFIX}"
CONFIG_BAK="${CONFIG_DIR}/config.json.bak.${BACKUP_SUFFIX}"
INIT_BAK="${SERVICE_PATH}.bak.${BACKUP_SUFFIX}"
CLIENT_BAK="${CONFIG_DIR}/client-info.txt.bak.${BACKUP_SUFFIX}"

[ -f "$BIN_PATH" ] && cp "$BIN_PATH" "$BIN_BAK"
[ -f "$CONFIG_DIR/config.json" ] && cp "$CONFIG_DIR/config.json" "$CONFIG_BAK"
[ -f "$SERVICE_PATH" ] && cp "$SERVICE_PATH" "$INIT_BAK"
[ -f "$CONFIG_DIR/client-info.txt" ] && cp "$CONFIG_DIR/client-info.txt" "$CLIENT_BAK"
[ ! -L /etc/runlevels/default/sing-box ] || SERVICE_WAS_ENABLED=1
if [ -f "$SERVICE_PATH" ] && rc-service sing-box status >/dev/null 2>&1; then
  SERVICE_WAS_RUNNING=1
fi

echo ">> Installing binary, config, and OpenRC service"
DEPLOYMENT_STARTED=1
mv "$NEW_BIN" "$BIN_PATH"
NEW_BIN=""
mv "$TEMP_CONF" "$CONFIG_DIR/config.json"
TEMP_CONF=""
chmod 755 "$BIN_PATH"
chmod 600 "$CONFIG_DIR/config.json"

mv "$TEMP_INIT" "$SERVICE_PATH"
TEMP_INIT=""
chmod +x "$SERVICE_PATH"

rc-update add sing-box default >/dev/null
mkdir -p "$(dirname "$ERROR_LOG")"
touch "$ERROR_LOG"
chmod 600 "$ERROR_LOG"

if [ "$SERVICE_WAS_RUNNING" = "1" ]; then
  SERVICE_ACTION="restart"
else
  SERVICE_ACTION="start"
fi

if ! rc-service sing-box "$SERVICE_ACTION" >/dev/null 2>&1; then
  print_service_failure_context
  die "deployment failed; restoring the previous installation on exit"
fi

sleep 2
if ! rc-service sing-box status >/dev/null 2>&1; then
  print_service_failure_context
  die "deployment failed; sing-box exited after start; restoring the previous installation on exit"
fi

mv "$TEMP_CLIENT" "$CONFIG_DIR/client-info.txt"
TEMP_CLIENT=""
chmod 600 "$CONFIG_DIR/client-info.txt"
DEPLOYMENT_COMMITTED=1

echo "================ Deployment succeeded ================"
echo "Client configuration ($CONFIG_DIR/client-info.txt):"
cat "$CONFIG_DIR/client-info.txt"
echo "Check your NAT provider panel/firewall for TCP port: $EXT_PORT"
