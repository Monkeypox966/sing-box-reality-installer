#!/bin/sh
# Validate generated server configurations with a supplied real sing-box binary.
set -eu
[ "$#" -eq 1 ] || { echo 'Usage: sh tests/check-config.sh /absolute/path/to/sing-box' >&2; exit 1; }
test_binary="$1"
project_dir="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
export SING_BOX_SETUP_LIBRARY_ONLY=1
# shellcheck source=setup-sing-box.sh
. "$project_dir/setup-sing-box.sh"
umask 077
test_temp="$(mktemp -d)"
trap 'rm -rf "$test_temp"' EXIT
UUID="$(run_sing_box "$test_binary" generate uuid)"
test_pair="$(run_sing_box "$test_binary" generate reality-keypair)"
PRIVATE_KEY="$(printf '%s\n' "$test_pair" | awk '/PrivateKey/ {print $2}')"
SHORT_ID=0012
PORT=57111
SNI=images.apple.com
for test_mode in 4 6 dual dual-v6only; do
  IP_MODE="$test_mode"
  BINDV6ONLY=0
  case "$test_mode" in
    4) DNS_SERVER=8.8.8.8; STRATEGY=ipv4_only; LISTEN_ADDR=0.0.0.0 ;;
    6) DNS_SERVER=2001:4860:4860::8888; STRATEGY=ipv6_only; LISTEN_ADDR=:: ;;
    dual) DNS_SERVER=8.8.8.8; STRATEGY=prefer_ipv6; LISTEN_ADDR=:: ;;
    dual-v6only) IP_MODE=dual; BINDV6ONLY=1; DNS_SERVER=8.8.8.8; STRATEGY=prefer_ipv6; LISTEN_ADDR=:: ;;
  esac
  write_server_config >"$test_temp/config.json"
  run_sing_box "$test_binary" check -c "$test_temp/config.json"
  printf 'Validated server config: %s\n' "$test_mode"
done
