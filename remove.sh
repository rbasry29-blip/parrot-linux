#!/data/data/com.termux/files/usr/bin/bash -e
# parrot-remove.sh
# Removes Parrot launcher and rootfs (archive or directory) — checks: archive (-e), dir (-d), launcher (-e)
#!/bin/bash

b='\033[0;34m'
c='\033[1;36m'
g='\033[1;32m'
r='\033[0m'

Print_banner() {
    clear
    printf "${b}▛▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▜\n"
    printf "${b}▌ ${c}█▀▀▖█▀▀█ █▀▀█ █▀▀█ █▀▀█ ▀█▀  ${b}▐\n"
    printf "${b}▌ ${c}█▀▀▘█▄▄█ █▄▄▀ █▄▄▀ █  █  █   ${b}▐\n"
    printf "${b}▌ ${c}▀   ▀  ▀ ▀  ▀ ▀  ▀ ▀▀▀▀  ▀   ${b}▐\n"
    printf "${b}▌${r}                              ${b}▐\n"
    printf "${b}▌${c}Parrot:${g}A unique installer     ${b}▐\n"
    printf "${b}▙▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▟${r}\n"
}

Print_banner

# Colors
red='\033[1;31m'
green='\033[1;32m'
blue='\033[1;34m'
light_cyan='\033[1;96m'
reset='\033[0m'

# Helpers (print style)
info()  { printf "${blue}[${green}*${blue}] ${light_cyan}%s${reset}\n" "$1"; }
warn()  { printf "${blue}[${red}!${blue}] ${red}%s${reset}\n" "$1"; }

ask_yesno() {
    # ask_yesno "Question" "default(Y/N)"
    local question="${1:-Proceed?}"
    local default="${2:-Y}"
    local reply prompt
    if [[ "$default" =~ ^[Yy]$ ]]; then prompt="Y/n"; else prompt="y/N"; fi
    printf "${blue}[${green}*${blue}] ${light_cyan}"
    read -r -p "$question [$prompt] " reply
    printf "${reset}"
    reply=${reply:-$default}
    case "$reply" in
        Y|y) return 0 ;;
        *)    return 1 ;;
    esac
}

# ---------------- Detect architecture ----------------
info "Detecting device architecture..."
ABI="$(getprop ro.product.cpu.abi 2>/dev/null || true)"
case "$ABI" in
    arm64-v8a) architecture="arm64" ;;
    armeabi|armeabi-v7a) architecture="armhf" ;;
    *)
        UNM="$(uname -m 2>/dev/null || true)"
        case "$UNM" in
            aarch64) architecture="arm64" ;;
            armv7l|armv8l) architecture="armhf" ;;
            *)
                warn "Unsupported Architecture. Exiting."
                exit 1
                ;;
        esac
        ;;
esac
info "Architecture detected: ${architecture}"

# ---------------- Paths (exact as you specified) ----------------
ROOTFS_ARCHIVE="/data/data/com.termux/files/home/parrot-rootfs-${architecture}.tar.xz"
ROOTFS_DIR="/data/data/com.termux/files/home/parrot-${architecture}"
LAUNCHER="/data/data/com.termux/files/usr/bin/parrot"
SHORTCUT="/data/data/com.termux/files/usr/bin/p"

# ---------------- Check rootfs (dir with -d, archive with -e) ----------------
info "Checking for rootfs..."
found_rootfs=0
if [ -d "$ROOTFS_DIR" ]; then
    warn "Rootfs directory found and it is going to remove"
    found_rootfs=1
elif [ -e "$ROOTFS_ARCHIVE" ]; then
    warn "Rootfs archive found and it is going to remove"
    found_rootfs=1
else
    warn "No rootfs found"
fi

# ---------------- Check launcher (-e) ----------------
info "Checking for launcher..."
found_launcher=0
if [ -e "$LAUNCHER" ]; then
    warn "Launcher found and it is going to remove"
    found_launcher=1
else
    warn "No launcher found"
fi

# ---------------- Nothing to remove ----------------
if [ "$found_rootfs" -eq 0 ] && [ "$found_launcher" -eq 0 ]; then
    info "Nothing to remove"
    exit 0
fi

# ---------------- Confirm & remove ----------------
if ask_yesno "Remove the found item(s) now?" "Y"; then
    # Remove launcher (file)
    if [ "$found_launcher" -eq 1 ]; then
        info "Removing launcher"
        rm -f "$LAUNCHER" 2>/dev/null || true
        # remove shortcut if exists
        if [ -e "$SHORTCUT" ]; then rm -f "$SHORTCUT" 2>/dev/null || true; fi
        info "Launcher removed"
    fi

    # Remove rootfs (directory and/or archive)
    if [ "$found_rootfs" -eq 1 ]; then
        if [ -d "$ROOTFS_DIR" ]; then
            info "Removing rootfs directory"
            rm -rf "$ROOTFS_DIR" 2>/dev/null || true
            info "Rootfs directory removed"
        fi
        if [ -e "$ROOTFS_ARCHIVE" ]; then
            info "Removing rootfs archive"
            rm -f "$ROOTFS_ARCHIVE" 2>/dev/null || true
            info "Rootfs archive removed"
        fi
    fi

    info "Removal complete"
else
    warn "Cancelled"
fi
