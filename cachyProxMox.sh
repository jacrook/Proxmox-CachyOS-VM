#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_VERSION="3.5.7"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOG_FILE="/var/log/cachyos-vm-creator-${SCRIPT_VERSION}.log"
EXIT_CODE=0

log() { echo -e "${GREEN}[INFO]${NC} $1" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"; }
debug() { [[ "${DEBUG:-0}" == "1" ]] && echo -e "${BLUE}[DEBUG]${NC} $1" | tee -a "$LOG_FILE" || true; }
error() { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE" >&2; exit 1; }

cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        warn "Script failed with exit code $exit_code"
        if [[ -n "${VMID:-}" ]]; then
            warn "Cleaning up VM $VMID..."
            if qm status "$VMID" &>/dev/null; then
                qm stop "$VMID" 2>/dev/null || true
                sleep 2
                qm destroy "$VMID" 2>/dev/null || true
            fi
        fi
    fi
    log "Log file: $LOG_FILE"
    exit $exit_code
}

trap cleanup EXIT
trap 'error "Script interrupted"' INT TERM

validate_environment() {
    debug "Validating environment..."

    if [[ $EUID -ne 0 ]]; then
        error "Root privileges required"
    fi

    local required_cmds=("qm" "pvesm" "grep" "awk" "sed" "ip" "stat" "du")
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            error "Required command not found: $cmd"
        fi
        debug "Found: $cmd"
    done

    debug "Testing qm list..."
    qm list >/dev/null || error "qm command failed"

    debug "Testing pvesm status..."
    pvesm status >/dev/null || error "pvesm command failed"

    log "Environment validation passed"
}

validate_disksize() {
    local size=$1
    if [[ ! "$size" =~ ^[0-9]+[GMT]$ ]]; then
        error "Disk size must end with G, M, or T. Example: 32G"
    fi
}

validate_vmid_available() {
    local vmid=$1
    if qm status "$vmid" &>/dev/null; then
        error "VM ID $vmid already in use"
    fi
}

validate_storage_exists() {
    local storage=$1
    if ! pvesm status | awk -v storage="$storage" 'NR > 1 && $1 == storage {found=1} END {exit !found}'; then
        echo -e "\n${RED}Available storage pools:${NC}"
        pvesm status | awk 'NR > 1 {printf "  - %-15s (Type: %s, Available: %s)\n", $1, $2, $4}'
        echo ""
        error "Storage pool '$storage' not found. Please choose from the list above."
    fi
}

get_latest_iso_url() {
    local version="251129"
    local base_url="https://iso.cachyos.org/desktop"
    local iso_name="cachyos-desktop-linux-${version}.iso"
    echo "${base_url}/${version}/${iso_name}"
}

convert_to_gib() {
    local size=$1
    local num unit
    num="${size%[GMT]}"
    unit="${size: -1}"

    case "$unit" in
        G) echo "$num" ;;
        M) echo $((num / 1024)) ;;
        T) echo $((num * 1024)) ;;
        *) error "Invalid size unit: $unit" ;;
    esac
}

prompt_config() {
    log "Please provide the following VM configuration..."

    while true; do
        read -rp "Enter VM ID (100-999) [111]: " VMID
        VMID=${VMID:-111}
        if [[ ! "$VMID" =~ ^[0-9]+$ ]] || ((VMID < 100 || VMID > 999)); then
            warn "Invalid VM ID. Enter a number between 100-999."
            continue
        fi
        validate_vmid_available "$VMID" && break
    done
    debug "VMID set to: $VMID"

    read -rp "Enter VM Name [cachy]: " VM_NAME
    VM_NAME=${VM_NAME:-"cachy"}
    if [[ ! "$VM_NAME" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        error "VM name contains invalid characters. Use alphanumeric, dots, hyphens, underscores only"
    fi
    debug "VM Name set to: $VM_NAME"

    read -rp "Enter number of CPU cores [4]: " CORES
    CORES=${CORES:-4}
    if [[ ! "$CORES" =~ ^[0-9]+$ ]] || ((CORES < 1 || CORES > 128)); then
        error "CPU cores must be 1-128"
    fi
    debug "CPU cores set to: $CORES"

    read -rp "Enter RAM size in MB [9000]: " MEMORY
    MEMORY=${MEMORY:-9000}
    if [[ ! "$MEMORY" =~ ^[0-9]+$ ]] || ((MEMORY < 512)); then
        error "RAM must be at least 512 MB"
    fi
    debug "Memory set to: $MEMORY MB"

    read -rp "Enable memory ballooning? (y/n) [Y]: " BALLOON
    BALLOON=${BALLOON:-Y}
    if [[ "$BALLOON" =~ ^[Yy]$ ]]; then
        read -rp "Enter minimum RAM for ballooning in MB [4096]: " BALLOON_MEM
        BALLOON_MEM=${BALLOON_MEM:-4096}
        if [[ ! "$BALLOON_MEM" =~ ^[0-9]+$ ]] || ((BALLOON_MEM >= MEMORY)); then
            error "Balloon memory must be less than total memory"
        fi
    else
        BALLOON_MEM=0
    fi
    debug "Balloon memory set to: $BALLOON_MEM MB"

    read -rp "Enter primary storage pool [local-lvm]: " STORAGE
    STORAGE=${STORAGE:-"local-lvm"}
    validate_storage_exists "$STORAGE"
    debug "Storage pool set to: $STORAGE"

    while true; do
        read -rp "Enter disk size (e.g., 32G) [32G]: " DISKSIZE
        DISKSIZE=${DISKSIZE:-"32G"}
        validate_disksize "$DISKSIZE" && break
        warn "Invalid format. Please include unit (G, M, or T). Example: 32G"
    done
    debug "Disk size set to: $DISKSIZE"

    DISKSIZE_GIB=$(convert_to_gib "$DISKSIZE")
    debug "Disk size converted to: $DISKSIZE_GIB GiB"

    read -rp "Enter network bridge [vmbr0]: " BRIDGE
    BRIDGE=${BRIDGE:-"vmbr0"}
    if ! ip link show "$BRIDGE" &>/dev/null; then
        error "Bridge interface '$BRIDGE' not found"
    fi
    debug "Bridge set to: $BRIDGE"

    read -rp "Enter VLAN tag (leave empty for none): " VLAN
    NET_PARAMS=""
    if [[ -n "$VLAN" ]]; then
        if [[ ! "$VLAN" =~ ^[0-9]{1,4}$ ]] || ((VLAN > 4094)); then
            error "VLAN ID must be 1-4094"
        fi
        NET_PARAMS=",tag=$VLAN"
        debug "VLAN tag set to: $VLAN"
    fi

    read -rp "Enter ISO storage location [local]: " ISO_STORAGE
    ISO_STORAGE=${ISO_STORAGE:-"local"}
    validate_storage_exists "$ISO_STORAGE"
    debug "ISO storage set to: $ISO_STORAGE"

    echo
    echo "Select VM optimization type:"
    echo "1) Desktop (KDE Plasma) - Recommended for GUI usage"
    echo "2) Minimal - For headless/server setup"
    read -rp "Enter choice [1]: " VMTYPE
    VMTYPE=${VMTYPE:-1}
    if [[ ! "$VMTYPE" =~ ^[12]$ ]]; then
        error "Invalid choice. Select 1 or 2"
    fi
    debug "VM type set to: $VMTYPE"

    echo
    echo "Select firmware type:"
    echo "1) OVMF (UEFI) - Modern systems, requires EFI bootloader"
    echo "2) SeaBIOS (BIOS) - Traditional BIOS, uses GRUB bootloader"
    read -rp "Enter choice [1]: " FIRMWARE
    FIRMWARE=${FIRMWARE:-1}
    if [[ ! "$FIRMWARE" =~ ^[12]$ ]]; then
        error "Invalid choice. Select 1 or 2"
    fi
    debug "Firmware type set to: $FIRMWARE"

    read -rp "Add cloud-init drive for post-install configuration? (y/n) [n]: " CLOUDINIT
    CLOUDINIT=${CLOUDINIT:-"n"}
    debug "Cloud-init enabled: $CLOUDINIT"

    if [[ "$FIRMWARE" == "1" ]]; then
        local storage_type
        storage_type=$(pvesm status | awk -v storage="$STORAGE" '$1 == storage {print $2}')
        case $storage_type in
            dir|nfs|cifs|glusterfs|cephfs)
                EFI_DISK="${STORAGE}:0,efitype=4m,format=qcow2,size=4M"
                ;;
            lvm|lvmthin|zfs|rbd)
                EFI_DISK="${STORAGE}:0,efitype=4m,size=4M"
                ;;
            *)
                EFI_DISK="${STORAGE}:0,efitype=4m,size=4M"
                ;;
        esac
        BIOS_TYPE="ovmf"
        debug "EFI disk config: $EFI_DISK"
    else
        EFI_DISK=""
        BIOS_TYPE="seabios"
        debug "Using SeaBIOS firmware"
    fi
}

download_iso() {
    local iso_url iso_name iso_path checksum_url checksum_path
    iso_url=$(get_latest_iso_url)
    iso_name=$(basename "$iso_url")
    iso_path="/var/lib/vz/template/iso/${iso_name}"
    checksum_url="${iso_url}.sha256"
    checksum_path="${iso_path}.sha256"

    if [[ -f "$iso_path" ]]; then
        local size
        size=$(stat -c%s "$iso_path" 2>/dev/null || echo 0)
        if ((size < 2000000000)); then
            warn "Found corrupted ISO (size: $size bytes), deleting..."
            rm -f "$iso_path" "$checksum_path" || error "Failed to remove corrupted ISO"
        else
            log "ISO already exists (size: $(du -h "$iso_path" | cut -f1)): $iso_path"
            ISO_FILE="$iso_path"
            return 0
        fi
    fi

    log "Downloading CachyOS ISO from: $iso_url"

    local download_tool
    if command -v wget &>/dev/null; then
        download_tool="wget --progress=bar:force:noscroll"
    elif command -v curl &>/dev/null; then
        download_tool="curl -L --progress-bar"
    else
        error "Neither wget nor curl found. Please install one of them."
    fi

    if ! $download_tool -o "$iso_path.tmp" "$iso_url" 2>&1 | tee -a "$LOG_FILE"; then
        rm -f "$iso_path.tmp"
        error "Failed to download ISO"
    fi

    if ! $download_tool -o "$checksum_path.tmp" "$checksum_url" 2>&1 | tee -a "$LOG_FILE"; then
        rm -f "$iso_path.tmp" "$checksum_path.tmp"
        error "Failed to download checksum"
    fi

    mv "$iso_path.tmp" "$iso_path" || error "Failed to move ISO file"
    mv "$checksum_path.tmp" "$checksum_path" || error "Failed to move checksum file"

    log "Verifying download..."
    if ! (cd "$(dirname "$iso_path")" && sha256sum -c "$(basename "$checksum_path")") | tee -a "$LOG_FILE"; then
        rm -f "$iso_path" "$checksum_path"
        error "ISO checksum verification failed. Download corrupted."
    fi

    ISO_FILE="$iso_path"
    log "Download verified: $(du -h "$ISO_FILE" | cut -f1)"
}

create_vm() {
    log "Creating VM $VMID ($VM_NAME)..."

    if qm status "$VMID" &>/dev/null; then
        warn "VM $VMID exists. Deleting..."
        qm stop "$VMID" 2>/dev/null || true
        sleep 2
        qm destroy "$VMID" || error "Failed to destroy existing VM $VMID"
    fi

    debug "Creating VM with qm create..."

    local create_cmd=(
        qm create "$VMID"
        --name "$VM_NAME"
        --ostype l26
        --machine q35
        --bios "$BIOS_TYPE"
        --agent 1
        --vga virtio
        --memory "$MEMORY"
        --cores "$CORES"
        --sockets 1
        --cpu host
        --net0 "virtio,bridge=${BRIDGE}${NET_PARAMS}"
    )

    if [[ "$FIRMWARE" == "1" ]]; then
        create_cmd+=(--efidisk0 "$EFI_DISK")
    fi

    if ((BALLOON_MEM > 0)); then
        create_cmd+=(--balloon "$BALLOON_MEM")
    fi

    if ! "${create_cmd[@]}" 2>&1 | tee -a "$LOG_FILE"; then
        error "Failed to create VM"
    fi

    debug "Adding SCSI disk to VM..."
    # FIXED: Removed 'G' suffix for LVM-thin compatibility
    if ! qm set "$VMID" --scsi0 "${STORAGE}:${DISKSIZE_GIB},discard=on,iothread=1" 2>&1 | tee -a "$LOG_FILE"; then
        error "Failed to add disk"
    fi

    if [[ "$CLOUDINIT" =~ ^[Yy]$ ]]; then
        debug "Adding cloud-init drive..."
        if ! qm set "$VMID" --ide2 "${ISO_STORAGE}:cloudinit" 2>&1 | tee -a "$LOG_FILE"; then
            warn "Failed to add cloud-init drive"
        fi
    fi

    debug "Attaching ISO..."
    if ! qm set "$VMID" --ide1 "${ISO_FILE},media=cdrom" 2>&1 | tee -a "$LOG_FILE"; then
        error "Failed to attach ISO"
    fi

    debug "Setting boot order..."
    if ! qm set "$VMID" --boot order=ide1;scsi0 2>&1 | tee -a "$LOG_FILE"; then
        error "Failed to set boot order"
    fi

    debug "Adding serial console..."
    if ! qm set "$VMID" --serial0 socket 2>&1 | tee -a "$LOG_FILE"; then
        warn "Failed to add serial console"
    fi

    log "VM $VMID created successfully"
}

print_instructions() {
    echo
    log "Installation Instructions:"
    echo "=========================="
    echo "1. Start VM: qm start $VMID"
    echo "2. Connect: qm console $VMID or WebUI VNC"
    echo "3. In installer: Select 'Launch Installer' → 'Erase Disk' → Complete setup"
    echo "4. After install:"
    echo "   qm set $VMID --delete ide1"
    echo "   qm set $VMID --boot order=scsi0"
    echo "5. Install Guest Agent: sudo pacman -S qemu-guest-agent && sudo systemctl enable --now qemu-guest-agent"
    echo
}

main() {
    log "CachyOS Proxmox VM Creator v$SCRIPT_VERSION"
    log "Start time: $(date)"

    validate_environment
    prompt_config
    download_iso
    create_vm
    print_instructions

    log "Setup complete! Run: qm start $VMID"
    log "End time: $(date)"
}

main "$@"
