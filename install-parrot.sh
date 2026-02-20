#!/data/data/com.termux/files/usr/bin/bash -e

VERSION=20250525
USERNAME=parrot

# Official EXALAB / AnLinux Parrot rootfs URLs
ARM64_ROOTFS="https://raw.githubusercontent.com/EXALAB/Anlinux-Resources/master/Rootfs/Parrot/arm64/parrot-rootfs-arm64.tar.xz"
ARMHF_ROOTFS="https://raw.githubusercontent.com/EXALAB/Anlinux-Resources/master/Rootfs/Parrot/armhf/parrot-rootfs-armhf.tar.xz"

# Colors
red='\033[1;31m'
green='\033[1;32m'
yellow='\033[1;33m'
blue='\033[1;34m'
light_cyan='\033[1;96m'
reset='\033[0m'

# ------------------ Helpers ------------------
unsupported_arch() {
    printf "${red}"
    echo "[*] Unsupported Architecture\n\n"
    printf "${reset}"
    exit 1
}

ask() {
    while true; do
        if [ "${2:-}" = "Y" ]; then prompt="Y/n"; default=Y
        elif [ "${2:-}" = "N" ]; then prompt="y/N"; default=N
        else prompt="y/n"; default=; fi

        printf "${light_cyan}\n[?] "
        read -p "$1 [$prompt] " REPLY
        if [ -z "$REPLY" ]; then REPLY=$default; fi
        printf "${reset}"

        case "$REPLY" in
            Y*|y*) return 0 ;;
            N*|n*) return 1 ;;
        esac
    done
}

# ------------------ Arch detection ------------------
get_arch() {
    printf "${blue}[*] Checking device architecture ...${reset}\n"
    case "$(getprop ro.product.cpu.abi 2>/dev/null)" in
        arm64-v8a) SYS_ARCH=arm64 ;;
        armeabi|armeabi-v7a) SYS_ARCH=armhf ;;
        *) unsupported_arch ;;
    esac
}

# ------------------ Strings (CLI only — no menu) ------------------
set_strings() {
    # CLI installer: no image selection menu (single rootfs per arch)
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
            KEEP_CHROOT=1
        fi
    fi
}

cleanup() {
    if [ -f "${IMAGE_NAME}" ]; then
        if ask "Delete downloaded rootfs file?" "N"; then
            rm -f "${IMAGE_NAME}"
        fi
    fi
}

# ------------------ Dependencies ------------------
check_dependencies() {
    printf "${blue}\n[*] Checking package dependencies...${reset}\n"
    apt update -y &> /dev/null

    REQUIRED_PACKAGES=("proot" "tar" "xz-utils" "curl" "wget")
    for PACKAGE_NAME in "${REQUIRED_PACKAGES[@]}"; do
        if dpkg -s "$PACKAGE_NAME" &> /dev/null; then
            echo "  $PACKAGE_NAME is OK"
        else
            printf "  Installing ${PACKAGE_NAME}...\n"
            apt install -y "$PACKAGE_NAME" || {
                printf "${red}ERROR: Failed to install ${PACKAGE_NAME}.\nExiting.\n${reset}"
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
        else
            printf "${yellow}[!] Using existing rootfs archive${reset}\n"
            KEEP_IMAGE=1
            return
        fi
    fi

    printf "${blue}[*] Downloading rootfs...${reset}\n\n"
    if command -v curl >/dev/null 2>&1; then
        # -L follow redirects, -C - resume, --progress-bar for clean progress
        curl -L -C - --progress-bar -o "${IMAGE_NAME}" "${ROOTFS_URL}" || {
            printf "${yellow}[!] curl failed, falling back to wget...${reset}\n"
            wget --continue -O "${IMAGE_NAME}" "${ROOTFS_URL}"
        }
    else
        wget --continue -O "${IMAGE_NAME}" "${ROOTFS_URL}"
    fi
}

# ------------------ Extract ------------------
extract_rootfs() {
    if [ -z "${KEEP_CHROOT}" ]; then
        printf "\n${blue}[*] Extracting rootfs... ${reset}\n\n"
        mkdir -p "${CHROOT}"
        # Use tar for xz (parrot rootfs is tar.xz)
        proot --link2symlink tar -xJf "${IMAGE_NAME}" -C "${CHROOT}" --no-same-owner --no-same-permissions 2>/dev/null || :
    else
        printf "${yellow}[!] Using existing rootfs directory${reset}\n"
    fi
}

# ------------------ Launcher ------------------
create_launcher() {
    NH_LAUNCHER=${PREFIX}/bin/parrot
    NH_SHORTCUT=${PREFIX}/bin/p

    cat > "$NH_LAUNCHER" <<- 'EOF'
#!/data/data/com.termux/files/usr/bin/bash -e
cd ${HOME}
unset LD_PRELOAD

user="parrot"
home="/home/${user}"
start="sudo -u parrot /bin/bash"

# if parrot user not present, run as root (keep same behaviour as original)
if ! grep -q "^parrot:" ${1:-}/etc/passwd 2>/dev/null || [[ "$#" != "0" && ("$1" == "-r" || "$1" == "-R") ]]; then
    user="root"
    home="/${user}"
    start="/bin/bash --login"
    if [[ "$#" != "0" && ("$1" == "-r" || "$1" == "-R") ]]; then
        shift
    fi
fi

cmdline="proot \
        --link2symlink \
        -0 \
        -r ${CHROOT} \
        -b /dev \
        -b /proc \
        -b /sdcard \
        -b ${CHROOT}${home}:/dev/shm \
        -w ${home} \
           /usr/bin/env -i \
           HOME=${home} \
           PATH=/usr/local/sbin:/usr/local/bin:/bin:/usr/bin:/sbin:/usr/sbin \
           TERM=${TERM} \
           LANG=C.UTF-8 \
           ${start}"

cmd="$@"
if [ "$#" == "0" ]; then
    exec $cmdline
else
    $cmdline -c "$cmd"
fi
EOF

    # replace ${CHROOT} in the generated launcher (heredoc used 'EOF' so we need to substitute)
    sed -i "s|\${CHROOT}|${CHROOT}|g" "$NH_LAUNCHER" || :
    chmod 700 "$NH_LAUNCHER"
    ln -sf "${NH_LAUNCHER}" "${NH_SHORTCUT}"
}

# ------------------ Profile & uid fixes ------------------
fix_profile_bash() {
    if [ -f "${CHROOT}/root/.bash_profile" ]; then
        sed -i '/if/,/fi/d' "${CHROOT}/root/.bash_profile" || :
    fi
}

ensure_parrot_user() {
    # ensure /etc/passwd and home exist inside chroot
    if [ -f "${CHROOT}/etc/passwd" ]; then
        if ! grep -q "^${USERNAME}:" "${CHROOT}/etc/passwd" 2>/dev/null; then
            printf "parrot:x:1000:1000:Parrot User:/home/parrot:/bin/bash\n" >> "${CHROOT}/etc/passwd" 2>/dev/null || :
        fi
    else
        mkdir -p "${CHROOT}/etc" || :
        printf "parrot:x:1000:1000:Parrot User:/home/parrot:/bin/bash\n" > "${CHROOT}/etc/passwd" 2>/dev/null || :
    fi

    if [ ! -d "${CHROOT}/home/parrot" ]; then
        mkdir -p "${CHROOT}/home/parrot" || :
        chown -R 1000:1000 "${CHROOT}/home/parrot" 2>/dev/null || :
    fi
}

fix_uid() {
    USRID=$(id -u)
    GRPID=$(id -g)
    if [ -f "${CHROOT}/etc/passwd" ]; then
        sed -i "s|^${USERNAME}:[^:]*:[0-9]*:[0-9]*:|${USERNAME}:x:${USRID}:${GRPID}:|" "${CHROOT}/etc/passwd" 2>/dev/null || :
    fi
}

# ------------------ Banner ------------------
print_banner() {
b='\033[0;34m'
c='\033[1;36m'
g='\033[1;32m'
r='\033[0m'

    printf "${b}▛▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▜\n"
    printf "${b}▌ ${c}█▀▀▖█▀▀█ █▀▀█ █▀▀█ █▀▀█ ▀█▀  ${b}▐\n"
    printf "${b}▌ ${c}█▀▀▘█▄▄█ █▄▄▀ █▄▄▀ █  █  █   ${b}▐\n"
    printf "${b}▌ ${c}▀   ▀  ▀ ▀  ▀ ▀  ▀ ▀▀▀▀  ▀   ${b}▐\n"
    printf "${b}▌${r}                              ${b}▐\n"
    printf "${b}▌${c}Parrot:${g} A unique installer     ${b}▐\n"
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

printf "\n${blue}[*] Configuring Parrot for Termux ...${reset}\n"
fix_profile_bash
fix_uid

print_banner
printf "${green}[=] Parrot for Termux installed successfully${reset}\n\n"
printf "${green}[+] To start Parrot, type:${reset}\n"
printf "${green}[+] parrot          # To start Parrot CLI${reset}\n"
printf "${green}[+] p               # Shortcut for parrot${reset}\n\n"