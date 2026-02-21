#!/data/data/com.termux/files/usr/bin/bash -e


USERNAME=parrot
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

# Official EXALAB / AnLinux Parrot rootfs URLs (AnLinux resources)
ARM64_ROOTFS="https://raw.githubusercontent.com/EXALAB/Anlinux-Resources/master/Rootfs/Parrot/arm64/parrot-rootfs-arm64.tar.xz"
ARMHF_ROOTFS="https://raw.githubusercontent.com/EXALAB/Anlinux-Resources/master/Rootfs/Parrot/armhf/parrot-rootfs-armhf.tar.xz"

# Colors
red='\033[1;31m'
green='\033[1;32m'
yellow='\033[1;33m'
blue='\033[1;34m'
light_cyan='\033[1;96m'
reset='\033[0m'

# ------------------ Output helpers ------------------
info()     { printf "${blue}[${green}*${blue}] ${light_cyan}%s${reset}\n" "$1"; }
warn()     { printf "${blue}[${red}!${blue}] ${red}%s${reset}\n" "$1"; }
question() { printf "${blue}[${yellow}?${blue}] ${yellow}%s${reset}\n" "$1"; }

# ------------------ Helpers ------------------
unsupported_arch() {
    warn "Unsupported Architecture"
    exit 1
}

# ask: yellow [?] prefix, question text in yellow, default handling
ask() {
    while true; do
        if [ "${2:-}" = "Y" ]; then prompt="Y/n"; default=Y
        elif [ "${2:-}" = "N" ]; then prompt="y/N"; default=N
        else prompt="y/n"; default=; fi

        # Print colored bracket and yellow prompt text, then read
        printf "\n${blue}[${yellow}?${blue}] ${yellow}%s [${prompt}] ${reset}" "$1"
        read -r REPLY
        if [ -z "$REPLY" ]; then REPLY=$default; fi

        case "$REPLY" in
            Y*|y*) return 0 ;;
            N*|n*) return 1 ;;
        esac
    done
}

# ------------------ Arch detection ------------------
get_arch() {
    info "Checking device architecture ..."
    ABI="$(getprop ro.product.cpu.abi 2>/dev/null || true)"
    case "$ABI" in
        arm64-v8a) SYS_ARCH=arm64 ;;
        armeabi|armeabi-v7a) SYS_ARCH=armhf ;;
        *)
            # fallback to uname -m
            UNM="$(uname -m 2>/dev/null || true)"
            case "$UNM" in
                aarch64) SYS_ARCH=arm64 ;;
                armv7l|armv8l) SYS_ARCH=armhf ;;
                *) unsupported_arch ;;
            esac
            ;;
    esac
    info "Architecture detected: ${SYS_ARCH}"
}

# ------------------ Strings ------------------
set_strings() {
    CHROOT=${USERNAME}-${SYS_ARCH}
    if [[ "${SYS_ARCH}" == "arm64" ]]; then
        ROOTFS_URL="${ARM64_ROOTFS}"
    else
        ROOTFS_URL="${ARMHF_ROOTFS}"
    fi
    IMAGE_NAME="${ROOTFS_URL##*/}"
}

# ------------------ Filesystem prep ------------------
prepare_fs() {
    unset KEEP_CHROOT
    if [ -d "${CHROOT}" ]; then
        if ask "Existing rootfs directory found. Delete and create a new one?" "N"; then
            rm -rf "${CHROOT}"
        else
            info "Using existing rootfs directory"
            KEEP_CHROOT=1
        fi
    fi
}

cleanup() {
    if [ -f "${IMAGE_NAME}" ]; then
        if ask "Delete downloaded rootfs file?" "N"; then
            rm -f "${IMAGE_NAME}"
            info "Downloaded rootfs removed"
        fi
    fi
}

# ------------------ Dependencies ------------------
check_dependencies() {
    info "Checking package dependencies..."
    apt update -y &> /dev/null

    REQUIRED_PACKAGES=("proot" "tar" "xz-utils" "curl" "wget")
    for PACKAGE_NAME in "${REQUIRED_PACKAGES[@]}"; do
        if dpkg -s "$PACKAGE_NAME" &> /dev/null; then
            info "$PACKAGE_NAME is OK"
        else
            info "Installing ${PACKAGE_NAME}..."
            apt install -y "$PACKAGE_NAME" || {
                warn "ERROR: Failed to install ${PACKAGE_NAME}. Exiting."
                exit 1
            }
        fi
    done
    apt upgrade -y &> /dev/null
}

# ------------------ Download (curl primary) ------------------
get_rootfs() {
    unset KEEP_IMAGE
    if [ -f "${IMAGE_NAME}" ]; then
        if ask "Existing image file found. Delete and download a new one?" "N"; then
            rm -f "${IMAGE_NAME}"
            info "Old image removed"
        else
            warn "Using existing rootfs archive"
            KEEP_IMAGE=1
            return
        fi
    fi

    info "Downloading rootfs..."
    if command -v curl >/dev/null 2>&1; then
        # -L follow redirects, -C - resume, --progress-bar for clean progress
        curl -L -C - --progress-bar -o "${IMAGE_NAME}" "${ROOTFS_URL}" || {
            warn "curl failed, falling back to wget..."
            wget --continue -O "${IMAGE_NAME}" "${ROOTFS_URL}"
        }
    else
        wget --continue -O "${IMAGE_NAME}" "${ROOTFS_URL}"
    fi

    if [ ! -s "${IMAGE_NAME}" ]; then
        warn "Downloaded file is empty or missing. Exiting."
        exit 1
    fi
    info "Download finished: ${IMAGE_NAME}"
}

# ------------------ Extract ------------------
extract_rootfs() {
    if [ -z "${KEEP_CHROOT}" ]; then
        info "Extracting rootfs..."
        mkdir -p "${CHROOT}"
        # Try using proot tar if proot is present (keeps symlink handling), otherwise normal tar
        if command -v proot >/dev/null 2>&1; then
            proot --link2symlink tar -xJf "${IMAGE_NAME}" -C "${CHROOT}" --no-same-owner --no-same-permissions 2>/dev/null || true
        else
            tar -xJf "${IMAGE_NAME}" -C "${CHROOT}" --no-same-owner --no-same-permissions 2>/dev/null || true
        fi

        # If extraction likely failed (empty dir), fallback to try plain tar -xf (some archives differ)
        if [ -z "$(ls -A "${CHROOT}" 2>/dev/null)" ]; then
            warn "Initial extraction resulted in empty target — trying alternate extraction..."
            if command -v proot >/dev/null 2>&1; then
                proot --link2symlink tar -xf "${IMAGE_NAME}" -C "${CHROOT}" 2>/dev/null || true
            else
                tar -xf "${IMAGE_NAME}" -C "${CHROOT}" 2>/dev/null || true
            fi
        fi

        if [ -z "$(ls -A "${CHROOT}" 2>/dev/null)" ]; then
            warn "Extraction failed or rootfs directory is empty. You may need to check the downloaded file."
            # do not exit — user can inspect; but we notify
        else
            info "Extraction completed"
        fi
    else
        info "Skipping extraction (using existing rootfs directory)"
    fi
}

# ------------------ Launcher ------------------
create_launcher() {
    NH_LAUNCHER="${PREFIX}/bin/parrot"
    NH_SHORTCUT="${PREFIX}/bin/p"

    # Generate launcher with current CHROOT and PREFIX substituted now.
    cat > "${NH_LAUNCHER}" <<-EOF
#!/data/data/com.termux/files/usr/bin/bash -e
cd \$HOME
unset LD_PRELOAD

user="parrot"
home="/home/\$user"
start="sudo -u parrot /bin/bash"

# if parrot user not present, run as root
if ! grep -q "^parrot:" "${CHROOT}/etc/passwd" 2>/dev/null || [[ "\$#" != "0" && ("\$1" == "-r" || "\$1" == "-R") ]]; then
    user="root"
    home="/\$user"
    start="/bin/bash --login"
    if [[ "\$#" != "0" && ("\$1" == "-r" || "\$1" == "-R") ]]; then
        shift
    fi
fi

cmdline="proot \\
        --link2symlink \\
        -0 \\
        -r ${CHROOT} \\
        -b /dev \\
        -b /proc \\
        -b /sdcard \\
        -b ${PREFIX}/tmp:/tmp \\
        -b ${CHROOT}\${home}:/dev/shm \\
        -w \${home} \\
           /usr/bin/env -i \\
           HOME=\${home} \\
           PATH=/usr/local/sbin:/usr/local/bin:/bin:/usr/bin:/sbin:/usr/sbin \\
           TERM=\$TERM \\
           LANG=C.UTF-8 \\
           \${start}"

cmd="\$@"
if [ "\$#" == "0" ]; then
    exec \$cmdline
else
    \$cmdline -c "\$cmd"
fi
EOF

    chmod 700 "${NH_LAUNCHER}" || warn "Failed to chmod launcher"
    ln -sf "${NH_LAUNCHER}" "${NH_SHORTCUT}" || warn "Failed to symlink shortcut"
    info "Launcher created: parrot"
}

# ------------------ Profile & uid fixes ------------------
fix_profile_bash() {
    if [ -f "${CHROOT}/root/.bash_profile" ]; then
        sed -i '/if/,/fi/d' "${CHROOT}/root/.bash_profile" || true
    fi
}

ensure_parrot_user() {
    if [ -f "${CHROOT}/etc/passwd" ]; then
        if ! grep -q "^${USERNAME}:" "${CHROOT}/etc/passwd" 2>/dev/null; then
            printf "parrot:x:1000:1000:Parrot User:/home/parrot:/bin/bash\n" >> "${CHROOT}/etc/passwd" 2>/dev/null || true
        fi
    else
        mkdir -p "${CHROOT}/etc" || true
        printf "parrot:x:1000:1000:Parrot User:/home/parrot:/bin/bash\n" > "${CHROOT}/etc/passwd" 2>/dev/null || true
    fi

    if [ ! -d "${CHROOT}/home/parrot" ]; then
        mkdir -p "${CHROOT}/home/parrot" || true
        # try to set ownership but ignore failures on Termux
        chown -R 1000:1000 "${CHROOT}/home/parrot" 2>/dev/null || true
    fi
}

fix_uid() {
    USRID=$(id -u)
    GRPID=$(id -g)
    if [ -f "${CHROOT}/etc/passwd" ]; then
        sed -i "s|^${USERNAME}:[^:]*:[0-9]*:[0-9]*:|${USERNAME}:x:${USRID}:${GRPID}:|" "${CHROOT}/etc/passwd" 2>/dev/null || true
    fi
}

# ------------------ Banner ------------------
print_banner() {
b='\033[0;34m'
c='\033[1;36m'
g='\033[1;32m'
r='\033[0m'
clear
    printf "${b}▛▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▜\n"
    printf "${b}▌ ${c}█▀▀▖█▀▀█ █▀▀█ █▀▀█ █▀▀█ ▀█▀  ${b}▐\n"
    printf "${b}▌ ${c}█▀▀▘█▄▄█ █▄▄▀ █▄▄▀ █  █  █   ${b}▐\n"
    printf "${b}▌ ${c}▀   ▀  ▀ ▀  ▀ ▀  ▀ ▀▀▀▀  ▀   ${b}▐\n"
    printf "${b}▌${r}                              ${b}▐\n"
    printf "${b}▌${c}Parrot:${g} A unique installer    ${b}▐\n"
    printf "${b}▙▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▟${r}\n"
}

# ------------------ Main flow ------------------
cd "$HOME"
print_banner
get_arch
set_strings
prepare_fs
check_dependencies
get_rootfs
extract_rootfs

# make sure a parrot user/home exists to avoid proot warnings
ensure_parrot_user

create_launcher
cleanup

info "Configuring Parrot for Termux ..."
fix_profile_bash
fix_uid

print_banner
info "Parrot for Termux installed successfully"
info "To start Parrot, type:"
info "parrot          # To start Parrot CLI"