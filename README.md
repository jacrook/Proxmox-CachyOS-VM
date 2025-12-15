# CachyOS Proxmox VM Creator

A production-ready shell script for automating CachyOS virtual machine creation on Proxmox VE. Handles disk provisioning, network configuration, EFI boot setup, and ISO verification with comprehensive error handling.

## Requirements

### Proxmox VE Versions

Tested and supported on:
- Proxmox VE 8.0 and later
- Proxmox VE 9.0 and later (recommended)
- Proxmox VE 9.0.11 (fully validated)

### Minimum Requirements

- Proxmox VE installation with root or sudo access
- 2 CPU cores minimum
- 4 GB RAM minimum for host
- 40 GB available storage for VM disk
- Network bridge configured (vmbr0 default)
- Internet connectivity for ISO download

### System Dependencies

The following packages must be installed on the Proxmox host:

- `bash` (4.0+)
- `qemu-server`
- `proxmox-ve`
- `ceph-common` (if using Ceph storage)
- `curl` or `wget`

These come standard with Proxmox VE installations.

## Installation

Clone or download the script to your Proxmox host:

```bash
wget https://example.com/fixed.sh
chmod +x fixed.sh
```

Or create the file directly:

```bash
nano fixed.sh
# paste the script contents
# Ctrl+X to save
```

## Basic Usage

Run as root or with sudo:

```bash
sudo ./fixed.sh
```

Or directly as root:

```bash
./fixed.sh
```

The script will prompt for configuration options interactively.

## Configuration Options

### VM ID
- **Range:** 100-999
- **Default:** 111
- **Must be unique** on the host
- Script validates availability

### VM Name
- Alphanumeric characters, dots, hyphens, underscores only
- **Default:** cachy
- Used for WebUI display and identification

### CPU Configuration
- **Range:** 1-128 cores
- **Default:** 4
- Host CPU type used for best performance

### Memory Configuration
- **Minimum:** 512 MB
- **Default:** 9000 MB
- Supports memory ballooning with configurable minimum

### Storage Configuration
- Pool selection (local-lvm, local, custom)
- **Default:** local-lvm
- Validates pool existence before creation

### Disk Size
- **Format:** Number + Unit (G, M, or T)
- **Default:** 32G
- **Valid examples:** 32G, 10240M, 1T
- Converted internally to GiB for Proxmox compatibility

### Network Configuration
- **Bridge selection:** vmbr0 default
- **VLAN tagging:** Optional (range: 1-4094)
- Validates bridge interface existence

### ISO Storage
- Separate storage location for installation media
- **Default:** local
- Used for CachyOS ISO and cloud-init provisioning

### VM Type Selection
- **Desktop (KDE Plasma)** - Recommended for GUI usage
- **Minimal** - For headless/server setup

### Cloud-Init
- Optional post-install configuration
- Requires cloud-init support in ISO storage
- **Default:** disabled

## Advanced Usage

### Debug Mode

Enable verbose logging for troubleshooting:

```bash
DEBUG=1 ./fixed.sh
```

Outputs detailed information about each step to both console and log file.

### Log File

All operations logged to:

```
/var/log/cachyos-vm-creator-3.5.log
```

Review logs for troubleshooting:

```bash
tail -f /var/log/cachyos-vm-creator-3.5.log
```

## Script Features

### Input Validation

- VM ID availability checked before creation
- Storage pools validated for existence
- Network bridges validated for presence
- VLAN IDs validated (1-4094 range)
- Memory balloon settings validated
- CPU core count validated (1-128)
- Disk size format validated

### Error Handling

- Automatic cleanup on script failure
- Partial VM destruction if creation fails
- Detailed error messages with context
- Failed downloads trigger retry information
- Checksum verification for ISO integrity

### Storage Management

- Automatic EFI disk creation
- Storage type detection (LVM, ZFS, directory, etc.)
- Proper format selection based on storage backend
- Disk size conversion from M/G/T to GiB
- SCSI controller with discard and I/O threading enabled

### Network Configuration

- Bridge interface validation
- VLAN tagging support with validation
- VirtIO network adapter for performance
- Proper MTU handling for VLANs

### Installation Process

The script performs these steps in order:

1. Environment validation (root check, Proxmox API connectivity)
2. Interactive configuration prompts
3. CachyOS ISO download and verification
4. VM creation with specified configuration
5. Disk attachment with performance optimizations
6. Boot configuration
7. Installation instructions

## Post-Installation

After the script completes:

1. Start the VM:
   ```bash
   qm start 111
   ```

2. Connect via console or VNC in WebUI

3. Boot from ISO and complete CachyOS installation

4. After installation, detach ISO:
   ```bash
   qm set 111 --delete ide1
   qm set 111 --boot 'order=scsi0'
   ```

5. Install Proxmox guest agent:
   ```bash
   sudo pacman -S qemu-guest-agent
   sudo systemctl enable --now qemu-guest-agent
   ```

## Troubleshooting

### Script fails to find Proxmox commands

Ensure you are running on a Proxmox host with:

```bash
pvesh get /api2/json/nodes
```

If this fails, you are not on a Proxmox VE system.

### VM creation fails with disk error

Check available storage space:

```bash
pvesm status
```

Verify storage pool exists and has sufficient capacity. The script validates this but confirm manually.

### ISO download fails

Check internet connectivity:

```bash
curl https://iso.cachyos.org/desktop/251129/cachyos-desktop-linux-251129.iso
```

If download works manually, retry the script. ISO download failures do not affect existing VMs.

### Network bridge not found

List available bridges:

```bash
ip link show
```

Specify an existing bridge during configuration. `vmbr0` is standard for most Proxmox installations.

### Insufficient disk space

Check free space:

```bash
df -h /var/lib/vz
```

The script requires approximately 3 GB for ISO plus disk size for VM.

### Checksum verification fails

ISO file is corrupted. Script automatically removes it and prompts for retry.

Manual cleanup:

```bash
rm /var/lib/vz/template/iso/cachyos-desktop-linux-251129.iso
```

## Performance Tuning

The script applies these optimizations automatically:

- VirtIO network adapter for network performance
- VirtIO graphics adapter for display performance
- I/O threading enabled on SCSI controller
- Discard support for thin provisioning
- Host CPU passthrough for native instruction set
- OVMF firmware for modern UEFI boot

## Storage-Specific Notes

### LVM/LVM-thin
- Default and recommended for Proxmox
- Raw format used automatically
- Best performance for local storage

### ZFS
- Raw format used automatically
- Supports snapshots and replication

### Directory Storage
- QCOW2 format used for compatibility
- Slower than LVM but works on NFS
- Supports image replication

## Security Considerations

### Root Access Required
- Script must run as root or with sudo
- Only run on trusted systems
- Review script contents before execution

### Network Security
- ISO downloaded over HTTPS
- Checksum verification prevents tampering
- VLAN support for network isolation

### VM Isolation
- Each VM gets unique ID
- Separate disk allocation
- Bridge network configuration allows segmentation

## Uninstallation

To remove a created VM:

```bash
qm stop VMID
qm destroy VMID
```

Example:

```bash
qm stop 111
qm destroy 111
```

The script does not perform automatic cleanup except on failure. Remove VMs manually as needed.

## Support and Reporting

For issues or feature requests:

1. Check the troubleshooting section above
2. Review log file at `/var/log/cachyos-vm-creator-3.5.log`
3. Run with `DEBUG=1` mode for detailed output
4. Verify Proxmox version compatibility

## Version History

### 3.5
- Added comprehensive error handling
- Improved environment validation
- Enhanced logging to file
- Added debug mode
- Stricter input validation
- Automatic cleanup on failure

### 3.4
- Fixed disk creation syntax for Proxmox 9.0+
- Corrected qm set scsi0 parameters
- Fixed size conversion to GiB

### 3.3
- Initial production release
- ISO verification and caching
- Cloud-init support
- VM type selection

## License

Production-ready script for CachyOS Proxmox VM automation.
