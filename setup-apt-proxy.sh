#!/bin/sh
set -eu

PROXY_URL="${APT_PROXY_URL:-https://apt1.risk-mermaid.ts.net}"
HEALTH_URL="${APT_PROXY_HEALTH_URL:-${PROXY_URL%/}/acng-report.html}"
TIMEOUT="${APT_PROXY_TIMEOUT:-3}"
DETECTOR="/usr/local/sbin/apt-proxy-detect"
APT_CONFIG="/etc/apt/apt.conf.d/99-apt-proxy"
MARKER="Managed by setup-apt-proxy.sh"

say() {
    printf '%s\n' "$*"
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "run this script as root (for example: sudo $0 $*)"
}

validate_settings() {
    case "$PROXY_URL" in
        http://*|https://*) ;;
        *) die "APT_PROXY_URL must begin with http:// or https://" ;;
    esac

    case "$PROXY_URL" in
        *[!A-Za-z0-9._:/-]*) die "APT_PROXY_URL contains unsupported characters" ;;
    esac

    case "$TIMEOUT" in
        ''|*[!0-9]*) die "APT_PROXY_TIMEOUT must be a positive integer" ;;
        0) die "APT_PROXY_TIMEOUT must be greater than zero" ;;
    esac
}

backup_unmanaged_file() {
    target="$1"
    backup="${target}.pre-apt-proxy"

    if [ -e "$target" ] && ! grep -q "$MARKER" "$target" 2>/dev/null; then
        [ ! -e "$backup" ] ||
            die "$backup already exists; move it aside before installing"
        cp -p "$target" "$backup"
        say "Backed up $target to $backup"
    fi
}

ensure_curl() {
    if command -v curl >/dev/null 2>&1; then
        return
    fi

    command -v apt-get >/dev/null 2>&1 ||
        die "curl is missing and this system does not provide apt-get"

    say "Installing curl using a direct repository connection..."
    apt-get \
        -o Acquire::http::Proxy=DIRECT \
        -o Acquire::https::Proxy=DIRECT \
        update
    DEBIAN_FRONTEND=noninteractive apt-get \
        -o Acquire::http::Proxy=DIRECT \
        -o Acquire::https::Proxy=DIRECT \
        install -y --no-install-recommends curl ca-certificates
}

write_detector() {
    temp_file="$(mktemp)"
    trap 'rm -f "$temp_file"' EXIT HUP INT TERM

    {
        printf '%s\n' '#!/bin/sh'
        printf '# %s\n' "$MARKER"
        printf '%s\n' "PROXY_URL='$PROXY_URL'"
        printf '%s\n' "HEALTH_URL='$HEALTH_URL'"
        printf '%s\n' "TIMEOUT='$TIMEOUT'"
        printf '%s\n' \
            'if /usr/bin/curl --noproxy '"'"'*'"'"' --silent --fail --max-time "$TIMEOUT" --output /dev/null "$HEALTH_URL"; then' \
            '    printf '"'"'%s/\n'"'"' "${PROXY_URL%/}"' \
            'else' \
            '    printf '"'"'DIRECT\n'"'"'' \
            'fi'
    } >"$temp_file"

    install -o root -g root -m 0755 "$temp_file" "$DETECTOR"
    rm -f "$temp_file"
    trap - EXIT HUP INT TERM
}

write_apt_config() {
    temp_file="$(mktemp)"
    trap 'rm -f "$temp_file"' EXIT HUP INT TERM

    {
        printf '// %s\n' "$MARKER"
        printf 'Acquire::http::Proxy-Auto-Detect "%s";\n' "$DETECTOR"
        printf 'Acquire::https::Proxy "DIRECT";\n'
    } >"$temp_file"

    install -o root -g root -m 0644 "$temp_file" "$APT_CONFIG"
    rm -f "$temp_file"
    trap - EXIT HUP INT TERM
}

show_status() {
    decision="not installed"
    if [ -x "$DETECTOR" ]; then
        decision="$("$DETECTOR")"
    fi

    say "Proxy:    $PROXY_URL"
    say "Decision: $decision"

    if [ -f "$APT_CONFIG" ]; then
        say "APT config:"
        apt-config dump |
            grep -E 'Acquire::(http::Proxy-Auto-Detect|https::Proxy)' ||
            true
    else
        say "APT config: not installed"
    fi
}

test_setup() {
    [ -x "$DETECTOR" ] || die "$DETECTOR is not installed"
    [ -f "$APT_CONFIG" ] || die "$APT_CONFIG is not installed"

    decision="$("$DETECTOR")"
    say "Current proxy decision: $decision"

    if [ "$decision" = "DIRECT" ]; then
        say "The configured proxy is unavailable; testing direct repository access."
    else
        say "The configured proxy is available; testing cached HTTP and direct HTTPS access."
    fi

    apt-get update
    say "APT update completed successfully."
}

install_setup() {
    require_root "$@"
    validate_settings
    ensure_curl
    backup_unmanaged_file "$DETECTOR"
    backup_unmanaged_file "$APT_CONFIG"
    write_detector
    write_apt_config

    say "Installed APT proxy configuration."
    show_status
    test_setup
}

restore_or_remove() {
    target="$1"
    backup="${target}.pre-apt-proxy"

    if [ -e "$target" ]; then
        grep -q "$MARKER" "$target" 2>/dev/null ||
            die "refusing to remove unmanaged file $target"
        rm -f "$target"
    fi

    if [ -e "$backup" ]; then
        mv "$backup" "$target"
        say "Restored $target"
    fi
}

uninstall_setup() {
    require_root "$@"
    restore_or_remove "$APT_CONFIG"
    restore_or_remove "$DETECTOR"
    say "Removed the APT proxy configuration."
}

usage() {
    cat <<EOF
Usage: $0 [install|test|status|uninstall]

Commands:
  install     Install or refresh the configuration and run apt-get update
  test        Display the current decision and run apt-get update
  status      Display the current decision and effective APT settings
  uninstall   Remove this configuration and restore saved files

Optional environment variables:
  APT_PROXY_URL         Proxy URL (default: $PROXY_URL)
  APT_PROXY_HEALTH_URL  Health-check URL (default: $HEALTH_URL)
  APT_PROXY_TIMEOUT     Health-check timeout in seconds (default: $TIMEOUT)
EOF
}

command_name="${1:-install}"
case "$command_name" in
    install) install_setup "$@" ;;
    test) test_setup ;;
    status) show_status ;;
    uninstall) uninstall_setup "$@" ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
esac
