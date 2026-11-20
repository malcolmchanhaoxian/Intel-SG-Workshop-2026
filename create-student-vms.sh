#!/usr/bin/env bash
set -Eeuo pipefail

B70_ID="${B70_ID:-8086:e223}"
BASE_IMAGE="${BASE_IMAGE:-$PWD/ubuntu-24.04-base.img}"
BMG_INSTALLER_DIR="${BMG_INSTALLER_DIR:-$HOME/multi-arc-bmg-offline-installer-26.39.10.2-combo}"
LIBVIRT_NETWORK="${LIBVIRT_NETWORK:-default}"
STUDENT_USER="${STUDENT_USER:-intel}"
STUDENT_RAM_GIB="${STUDENT_RAM_GIB:-48}"
STUDENT_VCPUS="${STUDENT_VCPUS:-12}"
STUDENT_DISK_GIB="${STUDENT_DISK_GIB:-80}"
HOST_RAM_RESERVE_GIB="${HOST_RAM_RESERVE_GIB:-16}"
STORAGE_RESERVE_GIB="${STORAGE_RESERVE_GIB:-20}"
SSH_TIMEOUT_SEC="${SSH_TIMEOUT_SEC:-900}"
KERNEL_EXPECTED="${KERNEL_EXPECTED:-6.17.0-1009-intel}"
MODEL_NAME="${MODEL_NAME:-Qwen-SEA-LION-v4.5-27B-IT}"
MODEL_MOUNT_TAG="${MODEL_MOUNT_TAG:-workshop_models}"
GUEST_MODEL_ROOT="${GUEST_MODEL_ROOT:-/llm/models}"
PREFLIGHT_ONLY=0
NON_INTERACTIVE=0
MODEL_DIR="${MODEL_DIR:-}"

usage(){ echo "Usage: sudo $0 [--preflight] [--model-dir PATH] [--non-interactive]"; }
while (($#)); do
  case "$1" in
    --preflight) PREFLIGHT_ONLY=1; shift ;;
    --model-dir) [[ $# -ge 2 ]] || { echo "Missing --model-dir value" >&2; exit 2; }; MODEL_DIR="$2"; shift 2 ;;
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

log(){ printf '[%s] %s\n' "$1" "$2"; }
die(){ log ERROR "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }
is_student_name(){ [[ "$1" =~ ^student[0-9]{2}$ ]]; }
bytes_to_gib(){ awk -v b="$1" 'BEGIN{printf "%.1f",b/1024/1024/1024}'; }

[[ $EUID -eq 0 ]] || die "Run with sudo from the desired VM storage directory"
for c in virsh virt-install qemu-img cloud-localds lspci openssl sshpass curl awk grep findmnt df realpath fuser; do need "$c"; done
[[ -f "$BASE_IMAGE" ]] || die "Base image not found: $BASE_IMAGE"
[[ -x "$BMG_INSTALLER_DIR/installer.sh" ]] || die "Battlemage installer missing: $BMG_INSTALLER_DIR"
[[ -x /usr/libexec/virtiofsd ]] || die "virtiofsd missing"

FW_DMC=/lib/firmware/i915/bmg_dmc.bin.zst
FW_GUC=/lib/firmware/xe/bmg_guc_70.bin.zst
FW_HUC=/lib/firmware/xe/bmg_huc.bin.zst
for fw in "$FW_DMC" "$FW_GUC" "$FW_HUC"; do [[ -f "$fw" ]] || die "Missing firmware: $fw"; done

if [[ -z "$MODEL_DIR" ]]; then
  (( NON_INTERACTIVE == 0 )) || die "MODEL_DIR required"
  read -r -p "Host directory containing $MODEL_NAME: " MODEL_DIR
fi
MODEL_DIR="$(realpath -e "$MODEL_DIR")"
MODEL_PATH="$MODEL_DIR/$MODEL_NAME"
[[ -f "$MODEL_PATH/config.json" ]] || die "Missing $MODEL_PATH/config.json"
[[ -f "$MODEL_PATH/model.safetensors.index.json" ]] || die "Missing model index"
MODEL_SHARDS="$(find "$MODEL_PATH" -maxdepth 1 -type f -name 'model-*.safetensors' | wc -l)"
(( MODEL_SHARDS > 0 )) || die "No model shards found"
log OK "Model validated: $MODEL_PATH ($(du -sh "$MODEL_PATH"|awk '{print $1}'), $MODEL_SHARDS shards)"

mapfile -t GPUS < <(lspci -Dnn | grep -i "\\[$B70_ID\\]" | awk '{print $1}' | sort)
GPU_COUNT=${#GPUS[@]}
(( GPU_COUNT > 0 )) || die "No B70 devices detected"
log INFO "Detected $GPU_COUNT B70 GPU(s): ${GPUS[*]}"
for pci in "${GPUS[@]}"; do
  sys=/sys/bus/pci/devices/$pci
  [[ -L "$sys/iommu_group" ]] || die "$pci has no IOMMU group"
  gp="$(readlink -f "$sys/iommu_group")"
  mapfile -t members < <(find "$gp/devices" -mindepth 1 -maxdepth 1 -printf '%f\n')
  (( ${#members[@]} == 1 )) || die "$pci shares IOMMU group $(basename "$gp"): ${members[*]}"
  driver=none; [[ -L "$sys/driver" ]] && driver="$(basename "$(readlink -f "$sys/driver")")"
  log INFO "$pci IOMMU group=$(basename "$gp") driver=$driver"
done

avail_bytes="$(df -B1 --output=avail "$PWD"|tail -1|tr -d ' ')"
mem_bytes="$(awk '/MemTotal/{printf "%.0f",$2*1024}' /proc/meminfo)"
req_disk=$((GPU_COUNT*STUDENT_DISK_GIB+STORAGE_RESERVE_GIB))
req_ram=$((GPU_COUNT*STUDENT_RAM_GIB+HOST_RAM_RESERVE_GIB))
printf '\nSTUDENT VM PREFLIGHT\n====================\n'
printf 'Storage directory:        %s\nModel source:             %s\nDetected B70s:            %d\nPlanned student VMs:      %d\n' "$PWD" "$MODEL_DIR" "$GPU_COUNT" "$GPU_COUNT"
printf 'Virtual disk per VM:      %d GiB\nDisk required:            %d GiB\nDisk available:           %s GiB\n' "$STUDENT_DISK_GIB" "$req_disk" "$(bytes_to_gib "$avail_bytes")"
printf 'RAM per VM:               %d GiB\nRAM required:             %d GiB\nPhysical RAM:             %s GiB\n' "$STUDENT_RAM_GIB" "$req_ram" "$(bytes_to_gib "$mem_bytes")"
(( avail_bytes >= req_disk*1024*1024*1024 )) || die "Insufficient storage"
(( mem_bytes >= req_ram*1024*1024*1024 )) || die "Insufficient RAM"
virsh net-info "$LIBVIRT_NETWORK" >/dev/null 2>&1 || die "Missing libvirt network: $LIBVIRT_NETWORK"

ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8)
remote(){ local vm=$1 ip=$2; shift 2; sshpass -p "$vm" ssh "${ssh_opts[@]}" "$STUDENT_USER@$ip" "$@"; }
copy_to_vm(){ local vm=$1 src=$2 ip=$3 dst=$4; sshpass -p "$vm" scp -r "${ssh_opts[@]}" "$src" "$STUDENT_USER@$ip:$dst"; }
wait_for_ip(){ local vm=$1 mac=$2 end=$((SECONDS+SSH_TIMEOUT_SEC)) ip; while ((SECONDS<end)); do ip="$(virsh domifaddr "$vm" 2>/dev/null|awk '/ipv4/{split($4,a,"/");print a[1];exit}')"; [[ -z "$ip" ]] && ip="$(virsh net-dhcp-leases "$LIBVIRT_NETWORK" 2>/dev/null|awk -v m="$mac" '$0~m{split($5,a,"/");print a[1];exit}')"; [[ -n "$ip" ]] && { printf '%s' "$ip"; return 0; }; sleep 3; done; return 1; }
wait_for_ssh(){ local vm=$1 ip=$2 end=$((SECONDS+SSH_TIMEOUT_SEC)); while ((SECONDS<end)); do remote "$vm" "$ip" true >/dev/null 2>&1 && return 0; sleep 5; done; return 1; }
wait_for_dpkg(){ local vm=$1 ip=$2; remote "$vm" "$ip" 'for i in $(seq 1 180); do if ! sudo fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; then exit 0; fi; sleep 2; done; exit 1'; }
vm_ip(){ local vm=$1 mac; mac="$(virsh domiflist "$vm" 2>/dev/null|awk '/network/{print $5;exit}')"; [[ -n "$mac" ]] && wait_for_ip "$vm" "$mac"; }

health_check(){
  local vm=$1 pci=$2 ip state
  is_student_name "$vm" || return 1
  virsh dominfo "$vm" >/dev/null 2>&1 || return 1
  [[ -f "$PWD/$vm.qcow2" && -f "$PWD/$vm-seed.img" ]] || return 1
  state="$(virsh domstate "$vm"|tr -d '\r')"; [[ "$state" == running ]] || virsh start "$vm" >/dev/null || return 1
  ip="$(vm_ip "$vm")" || return 1; wait_for_ssh "$vm" "$ip" || return 1
  remote "$vm" "$ip" "test \"\$(hostname)\" = '$vm'" >/dev/null 2>&1 || return 1
  remote "$vm" "$ip" "test \"\$(uname -r)\" = '$KERNEL_EXPECTED'" >/dev/null 2>&1 || return 1
  remote "$vm" "$ip" "test \"\$(lspci -Dnn|grep -ic '\\[$B70_ID\\]')\" = 1" >/dev/null 2>&1 || return 1
  remote "$vm" "$ip" "lspci -Dnnk|grep -A4 '$B70_ID'|grep -q 'Kernel driver in use: xe'" >/dev/null 2>&1 || return 1
  remote "$vm" "$ip" "test -e /dev/dri/renderD128" >/dev/null 2>&1 || return 1
  remote "$vm" "$ip" "xpu-smi discovery|grep -q 'Device State: normal'" >/dev/null 2>&1 || return 1
  remote "$vm" "$ip" "id $STUDENT_USER|grep -q video && id $STUDENT_USER|grep -q render && id $STUDENT_USER|grep -q docker" >/dev/null 2>&1 || return 1
  remote "$vm" "$ip" "systemctl is-active --quiet docker" >/dev/null 2>&1 || return 1
  remote "$vm" "$ip" "findmnt -n -t virtiofs '$GUEST_MODEL_ROOT'|grep -q '$MODEL_MOUNT_TAG'" >/dev/null 2>&1 || return 1
  remote "$vm" "$ip" "test -f '$GUEST_MODEL_ROOT/$MODEL_NAME/config.json'" >/dev/null 2>&1 || return 1
  printf '%s' "$ip"
}
cleanup_vm(){ local vm=$1; is_student_name "$vm" || die "Unsafe VM name: $vm"; log WARN "Deleting faulty $vm"; virsh destroy "$vm" >/dev/null 2>&1 || true; virsh undefine "$vm" --nvram >/dev/null 2>&1 || virsh undefine "$vm" >/dev/null 2>&1 || true; rm -f "$PWD/$vm.qcow2" "$PWD/$vm-seed.img" "$PWD/$vm.xml" "$PWD/$vm-gpu.xml"; rm -rf "$PWD/cloud-init/$vm"; }

create_vm(){
  local vm=$1 pci=$2 disk=$PWD/$vm.qcow2 seed=$PWD/$vm-seed.img ci=$PWD/cloud-init/$vm hash mac ip d b s f inst
  mkdir -p "$ci"; hash="$(openssl passwd -6 "$vm")"
  cat >"$ci/user-data" <<CLOUD
#cloud-config
hostname: $vm
manage_etc_hosts: true
ssh_pwauth: true
users:
  - name: $STUDENT_USER
    groups: [adm, sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    passwd: '$hash'
write_files:
  - path: /etc/ssh/sshd_config.d/01-workshop.conf
    permissions: '0644'
    content: |
      PasswordAuthentication yes
      PermitEmptyPasswords no
      AllowTcpForwarding yes
      GatewayPorts clientspecified
packages: [qemu-guest-agent]
runcmd:
  - mkdir -p $GUEST_MODEL_ROOT
  - grep -q '^$MODEL_MOUNT_TAG ' /etc/fstab || echo '$MODEL_MOUNT_TAG $GUEST_MODEL_ROOT virtiofs ro,relatime 0 0' >> /etc/fstab
  - systemctl enable --now qemu-guest-agent
  - systemctl restart ssh
CLOUD
  printf 'instance-id: %s\nlocal-hostname: %s\n' "$vm" "$vm" >"$ci/meta-data"
  qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$disk" "${STUDENT_DISK_GIB}G" >/dev/null
  cloud-localds "$seed" "$ci/user-data" "$ci/meta-data"
  virt-install --name "$vm" --memory $((STUDENT_RAM_GIB*1024)) --vcpus "$STUDENT_VCPUS" --cpu host-passthrough --machine q35 --osinfo ubuntu24.04 --boot uefi --memorybacking source.type=memfd,access.mode=shared --disk "path=$disk,format=qcow2,bus=virtio" --disk "path=$seed,device=cdrom" --filesystem "source=$MODEL_DIR,target=$MODEL_MOUNT_TAG,type=mount,accessmode=passthrough,driver.type=virtiofs" --network "network=$LIBVIRT_NETWORK,model=virtio" --graphics none --console pty,target_type=serial --import --print-xml >"$PWD/$vm.xml"
  virsh define "$PWD/$vm.xml" >/dev/null
  IFS=':.' read -r d b s f <<<"$pci"
  cat >"$PWD/$vm-gpu.xml" <<GPU
<hostdev mode='subsystem' type='pci' managed='yes'><source><address domain='0x$d' bus='0x$b' slot='0x$s' function='0x$f'/></source></hostdev>
GPU
  virsh attach-device "$vm" "$PWD/$vm-gpu.xml" --config >/dev/null
  mac="$(virsh domiflist "$vm"|awk '/network/{print $5;exit}')"; virsh start "$vm" >/dev/null
  ip="$(wait_for_ip "$vm" "$mac")" || die "No IP for $vm"; wait_for_ssh "$vm" "$ip" || die "SSH unavailable on $vm"

  # SSH can become available before cloud-init/apt/dpkg has finished.
  # Wait for initial guest provisioning and package activity before BMG install.
  log INFO "$vm: waiting for cloud-init"
  remote "$vm" "$ip" "sudo cloud-init status --wait" || die "$vm cloud-init failed"

  log INFO "$vm: waiting for apt/dpkg before BMG install"
  wait_for_dpkg "$vm" "$ip" || die "$vm package manager remained busy before BMG install"

  log OK "$vm: cloud-init complete and package manager idle"

  copy_to_vm "$vm" "$BMG_INSTALLER_DIR" "$ip" "~/"
  copy_to_vm "$vm" "$FW_DMC" "$ip" /tmp/bmg_dmc.bin.zst; copy_to_vm "$vm" "$FW_GUC" "$ip" /tmp/bmg_guc_70.bin.zst; copy_to_vm "$vm" "$FW_HUC" "$ip" /tmp/bmg_huc.bin.zst
  inst="$(basename "$BMG_INSTALLER_DIR")"
  remote "$vm" "$ip" "cd ~/$inst && sudo ./installer.sh || true"
  wait_for_dpkg "$vm" "$ip"
  remote "$vm" "$ip" "sudo DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y"
  wait_for_dpkg "$vm" "$ip"
  remote "$vm" "$ip" "sudo dpkg --configure -a && sudo dpkg --audit && sudo apt-get check"
  remote "$vm" "$ip" "test \"\$(dpkg-query -W -f='\${db:Status-Status}' linux-image-$KERNEL_EXPECTED)\" = installed && test \"\$(dpkg-query -W -f='\${db:Status-Status}' linux-modules-$KERNEL_EXPECTED)\" = installed && test -f /boot/vmlinuz-$KERNEL_EXPECTED && test -d /lib/modules/$KERNEL_EXPECTED"
  remote "$vm" "$ip" "sudo install -D -m0644 /tmp/bmg_dmc.bin.zst /lib/firmware/i915/bmg_dmc.bin.zst; sudo install -D -m0644 /tmp/bmg_guc_70.bin.zst /lib/firmware/xe/bmg_guc_70.bin.zst; sudo install -D -m0644 /tmp/bmg_huc.bin.zst /lib/firmware/xe/bmg_huc.bin.zst; sudo update-initramfs -u -k '$KERNEL_EXPECTED'; sudo reboot" || true
  sleep 10; wait_for_ssh "$vm" "$ip" || die "$vm failed kernel reboot"
  remote "$vm" "$ip" "sudo apt-get update && sudo apt-get install -y ca-certificates curl; sudo install -m0755 -d /etc/apt/keyrings; sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc; sudo chmod a+r /etc/apt/keyrings/docker.asc"
  remote "$vm" "$ip" 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null'
  remote "$vm" "$ip" "sudo apt-get update && sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; sudo systemctl enable --now docker; sudo usermod -aG video,render,docker '$STUDENT_USER'; sudo reboot" || true
  sleep 10; wait_for_ssh "$vm" "$ip" || die "$vm failed Docker reboot"
}

update_hosts(){ local tmp="$(mktemp)" vm ip; awk '$0=="# BEGIN WORKSHOP STUDENT VMS"{s=1;next}$0=="# END WORKSHOP STUDENT VMS"{s=0;next}!s{print}' /etc/hosts >"$tmp"; echo '# BEGIN WORKSHOP STUDENT VMS' >>"$tmp"; for i in "${!GPUS[@]}"; do vm="student$(printf '%02d' "$((i+1))")"; ip="$(vm_ip "$vm"||true)"; [[ -n "$ip" ]] && echo "$ip $vm" >>"$tmp"; done; echo '# END WORKSHOP STUDENT VMS' >>"$tmp"; install -m0644 "$tmp" /etc/hosts; rm -f "$tmp"; }

declare -A STATUS
printf '\nEXISTING VM HEALTH\n==================\n'
for i in "${!GPUS[@]}"; do vm="student$(printf '%02d' "$((i+1))")"; pci="${GPUS[$i]}"; if ! virsh dominfo "$vm" >/dev/null 2>&1 && [[ ! -e "$PWD/$vm.qcow2" && ! -e "$PWD/$vm-seed.img" ]]; then STATUS[$vm]=MISSING; elif health_check "$vm" "$pci" >/dev/null 2>&1; then STATUS[$vm]=HEALTHY; else STATUS[$vm]=FAULTY; fi; printf '%-10s %-8s host-GPU=%s\n' "$vm" "${STATUS[$vm]}" "$pci"; done
((PREFLIGHT_ONLY==0)) || exit 0
printf '\nPROVISIONING PLAN\n=================\n'; for i in "${!GPUS[@]}"; do vm="student$(printf '%02d' "$((i+1))")"; echo "$vm -> ${STATUS[$vm]}"; done
if ((NON_INTERACTIVE==0)); then read -r -p 'Proceed? [y/N] ' a; [[ "$a" =~ ^[Yy]$ ]] || die Cancelled; fi
for i in "${!GPUS[@]}"; do vm="student$(printf '%02d' "$((i+1))")"; pci="${GPUS[$i]}"; case "${STATUS[$vm]}" in HEALTHY) log OK "$vm preserved" ;; FAULTY) cleanup_vm "$vm"; create_vm "$vm" "$pci"; health_check "$vm" "$pci" >/dev/null || die "$vm failed clean rebuild" ;; MISSING) create_vm "$vm" "$pci"; if ! health_check "$vm" "$pci" >/dev/null; then cleanup_vm "$vm"; log WARN "$vm failed initial validation; rebuilding once"; create_vm "$vm" "$pci"; health_check "$vm" "$pci" >/dev/null || die "$vm failed clean rebuild"; fi ;; esac; done
update_hosts
printf '\nSTUDENT VM PROVISIONING COMPLETE\n================================\n'; printf '%-10s %-18s %-16s %-8s\n' VM HOST_GPU IP STATUS; for i in "${!GPUS[@]}"; do vm="student$(printf '%02d' "$((i+1))")"; printf '%-10s %-18s %-16s READY\n' "$vm" "${GPUS[$i]}" "$(vm_ip "$vm")"; done
echo; echo "Model source: $MODEL_DIR"; echo "Guest model path: $GUEST_MODEL_ROOT"; echo; for i in "${!GPUS[@]}"; do vm="student$(printf '%02d' "$((i+1))")"; echo "ssh $STUDENT_USER@$vm    password: $vm"; done
