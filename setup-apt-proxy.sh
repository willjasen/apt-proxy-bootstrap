#!/bin/sh
set -eu

PROXY_URL="${APT_PROXY_URL:-https://apt1.risk-mermaid.ts.net}"
HEALTH_URL="${APT_PROXY_HEALTH_URL:-${PROXY_URL%/}/acng-report.html}"
TIMEOUT="${APT_PROXY_TIMEOUT:-3}"
DETECTOR="/usr/local/sbin/apt-proxy-detect"
APT_CONFIG="/etc/apt/apt.conf.d/99-apt-proxy"
COMMAND_LINK="/usr/local/sbin/apt-proxy"
MARKER="Managed by setup-apt-proxy.sh"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
    RESET='\033[0m'
    BOLD='\033[1m'
    RED='\033[31m'
    GREEN='\033[32m'
    YELLOW='\033[33m'
    CYAN='\033[36m'
else
    RESET=''
    BOLD=''
    RED=''
    GREEN=''
    YELLOW=''
    CYAN=''
fi

info() {
    printf '%b[INFO]%b %s\n' "$CYAN" "$RESET" "$*"
}

success() {
    printf '%b[ OK ]%b %s\n' "$GREEN" "$RESET" "$*"
}

warn() {
    printf '%b[WARN]%b %s\n' "$YELLOW" "$RESET" "$*" >&2
}

die() {
    printf '%b[FAIL]%b %s\n' "$RED" "$RESET" "$*" >&2
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
        info "Backed up $target to $backup"
    fi
}

fix_debian_security_sources() {
    for source_file in \
        /etc/apt/sources.list \
        /etc/apt/sources.list.d/*.list \
        /etc/apt/sources.list.d/*.sources
    do
        [ -f "$source_file" ] || continue

        if grep -Eq 'https?://security\.debian\.org/?([[:space:]]|$)' \
            "$source_file"; then
            backup="${source_file}.pre-apt-proxy-security"
            if [ ! -e "$backup" ]; then
                cp -p "$source_file" "$backup"
                info "Backed up $source_file to $backup"
            fi

            sed -i \
                -e 's|http://security\.debian\.org/\{0,1\}\([[:space:]]\)|http://deb.debian.org/debian-security\1|g' \
                -e 's|https://security\.debian\.org/\{0,1\}\([[:space:]]\)|http://deb.debian.org/debian-security\1|g' \
                -e 's|http://security\.debian\.org/\{0,1\}$|http://deb.debian.org/debian-security|' \
                -e 's|https://security\.debian\.org/\{0,1\}$|http://deb.debian.org/debian-security|' \
                "$source_file"

            warn "Corrected an incomplete Debian Security URL in $source_file"
        fi
    done
}

ensure_curl() {
    if command -v curl >/dev/null 2>&1; then
        return
    fi

    command -v apt-get >/dev/null 2>&1 ||
        die "curl is missing and this system does not provide apt-get"

    info "Installing curl using a direct repository connection..."
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

install_command_link() {
    script_path="$(readlink -f "$0")"
    [ -n "$script_path" ] && [ -f "$script_path" ] ||
        die "could not determine the installer's absolute path"

    if [ -e "$COMMAND_LINK" ] || [ -L "$COMMAND_LINK" ]; then
        if [ -L "$COMMAND_LINK" ] &&
            [ "$(readlink -f "$COMMAND_LINK")" = "$script_path" ]; then
            return
        fi
        die "$COMMAND_LINK already exists and is not managed by this installer"
    fi

    ln -s "$script_path" "$COMMAND_LINK"
    success "Installed command: $COMMAND_LINK"
}

show_status() {
    decision="not installed"
    if [ -x "$DETECTOR" ]; then
        decision="$("$DETECTOR")"
    fi

    printf '%bProxy:%b    %s\n' "$BOLD" "$RESET" "$PROXY_URL"
    if [ "$decision" = "DIRECT" ]; then
        printf '%bDecision:%b %b%s%b\n' \
            "$BOLD" "$RESET" "$YELLOW" "$decision" "$RESET"
    else
        printf '%bDecision:%b %b%s%b\n' \
            "$BOLD" "$RESET" "$GREEN" "$decision" "$RESET"
    fi

    if [ -f "$APT_CONFIG" ]; then
        printf '%bAPT config:%b\n' "$BOLD" "$RESET"
        apt-config dump |
            grep -E 'Acquire::(http::Proxy-Auto-Detect|https::Proxy)' ||
            true
    else
        warn "APT config is not installed"
    fi
}

test_setup() {
    [ -x "$DETECTOR" ] || die "$DETECTOR is not installed"
    [ -f "$APT_CONFIG" ] || die "$APT_CONFIG is not installed"

    decision="$("$DETECTOR")"
    info "Current proxy decision: $decision"

    if [ "$decision" = "DIRECT" ]; then
        warn "The configured proxy is unavailable; testing direct repository access."
    else
        info "The configured proxy is available; testing cached HTTP and direct HTTPS access."
    fi

    apt_log="$(mktemp)"
    trap 'rm -f "$apt_log"' EXIT HUP INT TERM
    apt_status=0
    apt-get update >"$apt_log" 2>&1 || apt_status=$?
    cat "$apt_log"

    if [ "$apt_status" -ne 0 ] ||
        grep -Eq '^(Err:|E:|W: Failed to fetch)' "$apt_log"; then
        rm -f "$apt_log"
        trap - EXIT HUP INT TERM
        die "APT update reported one or more repository failures"
    fi

    rm -f "$apt_log"
    trap - EXIT HUP INT TERM
    success "APT update completed without repository failures."
}

install_setup() {
    require_root "$@"
    validate_settings
    fix_debian_security_sources
    ensure_curl
    backup_unmanaged_file "$DETECTOR"
    backup_unmanaged_file "$APT_CONFIG"
    write_detector
    write_apt_config
    install_command_link

    success "Installed APT proxy configuration."
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
        success "Restored $target"
    fi
}

uninstall_setup() {
    require_root "$@"
    script_path="$(readlink -f "$0")"
    if [ -L "$COMMAND_LINK" ] &&
        [ "$(readlink -f "$COMMAND_LINK")" = "$script_path" ]; then
        rm -f "$COMMAND_LINK"
        success "Removed $COMMAND_LINK"
    fi
    restore_or_remove "$APT_CONFIG"
    restore_or_remove "$DETECTOR"
    success "Removed the APT proxy configuration."
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
