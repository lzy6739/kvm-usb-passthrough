#!/usr/bin/env bash
set -euo pipefail

# KVM / libvirt 通用 USB 自动直通管理工具
# - 无参数运行：进入交互式菜单（支持 lsusb 点选、常用预设、手动输入、自动扫描恢复）
# - 带参数运行：支持命令行自动化调用 (enable / disable / list / status)

LIBVIRT_URI="qemu:///system"
RULE_DIR="/etc/udev/rules.d"
XML_DIR="/etc/libvirt/qemu"
MODPROBE_DIR="/etc/modprobe.d"
MANAGED_TAG="MANAGED-BY: kvm-usb-passthrough"

VM=""
VID=""
PID=""
NAME=""
DRIVER=""
DESC=""
DRIVER_SET=0

usage() {
    cat <<'EOF'
用法:
  ./kvm-usb-passthrough.sh                  # 进入交互式菜单
  ./kvm-usb-passthrough.sh <子命令> [选项]  # 命令行模式

子命令:
  enable    添加/更新自动直通规则 (需提权)
  disable   移除指定直通规则并恢复状态 (需提权)
  list      列出所有由本脚本管理的直通规则
  status    查看所有规则及虚拟机当前挂载状态

选项:
  --vm <名称>       目标 libvirt 虚拟机名称 (默认: 自动检测或 win10)
  --vid <4位hex>    USB Vendor ID
  --pid <4位hex>    USB Product ID
  --name <标签>     规则与 XML 标签名 (默认: usb-<vid>-<pid>)
  --driver <模块>   需屏蔽的宿主机内核驱动 (传 "" 表示不屏蔽)
  --desc <描述>     设备备注描述
  -h, --help        显示帮助
EOF
}

validate_hex4() {
    local val="${1,,}"
    [[ "$val" =~ ^[0-9a-f]{4}$ ]]
}

validate_ident() {
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

compute_paths() {
    VID="${VID,,}"
    PID="${PID,,}"
    if ! validate_hex4 "$VID" || ! validate_hex4 "$PID"; then
        echo "错误: VID 和 PID 必须是 4 位十六进制数 (当前: ${VID}:${PID})" >&2
        exit 1
    fi

    VM="${VM:-win10}"
    NAME="${NAME:-usb-${VID}-${PID}}"

    if ! validate_ident "$VM" || ! validate_ident "$NAME"; then
        echo "错误: --vm 和 --name 仅支持字母、数字、点、下划线和连字符。" >&2
        exit 1
    fi
    if [[ -n "$DRIVER" ]] && ! validate_ident "$DRIVER"; then
        echo "错误: --driver 名称不合法: $DRIVER" >&2
        exit 1
    fi

    if [[ "$DRIVER_SET" -eq 0 && "$VID" == "05c6" && "$PID" == "9008" ]]; then
        DRIVER="qcserial"
    fi

    XML_PATH="${XML_DIR}/kvm-usb-${NAME}.xml"
    RULE_PATH="${RULE_DIR}/99-kvm-usb-${NAME}-${VM}.rules"
    MODPROBE_PATH="${MODPROBE_DIR}/blacklist-${DRIVER}.conf"
    # udev remove 事件中 sysfs 属性已消失，只能匹配内核原生 ENV{PRODUCT}（十六进制无前导零）
    PRODUCT_SHORT="$(printf '%x/%x/*' "0x${VID}" "0x${PID}")"
}

run_privileged() {
    pkexec "$(readlink -f "$0")" "$@"
}

# 检查是否还有其他托管规则在屏蔽同一个驱动
driver_still_needed() {
    local target_drv="$1"
    local exclude_rule="$2"
    local f drv
    for f in "${RULE_DIR}"/99-kvm-usb-*.rules; do
        [[ -f "$f" ]] || continue
        [[ "$f" == "$exclude_rule" ]] && continue
        drv="$(sed -n '1s/.*| DRIVER=\([^ |]*\).*/\1/p' "$f" 2>/dev/null || true)"
        if [[ "$drv" == "$target_drv" ]]; then
            return 0
        fi
    done
    return 1
}

do_enable() {
    compute_paths
    if [[ "${EUID}" -ne 0 ]]; then
        local args=(enable --vm "$VM" --vid "$VID" --pid "$PID" --name "$NAME")
        if [[ "$DRIVER_SET" -eq 1 || -n "$DRIVER" ]]; then
            args+=(--driver "$DRIVER")
        fi
        if [[ -n "$DESC" ]]; then
            args+=(--desc "$DESC")
        fi
        run_privileged "${args[@]}"
        return $?
    fi

    cat > "$XML_PATH" <<EOF
<hostdev mode='subsystem' type='usb' managed='yes'>
  <source>
    <vendor id='0x${VID}'/>
    <product id='0x${PID}'/>
  </source>
</hostdev>
EOF

    if [[ -n "$DRIVER" ]]; then
        echo "install ${DRIVER} /bin/false" > "$MODPROBE_PATH"
        modprobe -r "$DRIVER" 2>/dev/null || true
    fi

    local safe_desc="${DESC//|/ }"
    cat > "$RULE_PATH" <<EOF
# ${MANAGED_TAG} | VM=${VM} | VID=${VID} | PID=${PID} | NAME=${NAME} | DRIVER=${DRIVER} | DESC=${safe_desc}
ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="${VID}", ATTR{idProduct}=="${PID}", RUN+="/bin/sh -c '/usr/bin/virsh -c ${LIBVIRT_URI} detach-device ${VM} ${XML_PATH} --live 2>/dev/null; /usr/bin/virsh -c ${LIBVIRT_URI} attach-device ${VM} ${XML_PATH} --live || true'"
ACTION=="remove", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ENV{PRODUCT}=="${PRODUCT_SHORT}", RUN+="/bin/sh -c '/usr/bin/virsh -c ${LIBVIRT_URI} detach-device ${VM} ${XML_PATH} --live 2>/dev/null || true'"
EOF

    udevadm control --reload-rules

    echo ""
    echo "已启用自动直通:"
    echo "  设备: ${VID}:${PID}${DESC:+ ($DESC)} -> 虚拟机: ${VM}"
    echo "  XML:  ${XML_PATH}"
    echo "  规则: ${RULE_PATH}"
    if [[ -n "$DRIVER" ]]; then
        echo "  驱动屏蔽: ${MODPROBE_PATH} (${DRIVER})"
    fi

    # 若设备当前已经插入且目标 VM 正在运行，立即尝试挂载，无需重新拔插
    if lsusb -d "${VID}:${PID}" >/dev/null 2>&1; then
        local vm_state
        vm_state="$(virsh -c "$LIBVIRT_URI" domstate "$VM" 2>/dev/null || true)"
        if [[ "$vm_state" == "running" ]]; then
            virsh -c "$LIBVIRT_URI" detach-device "$VM" "$XML_PATH" --live 2>/dev/null || true
            if virsh -c "$LIBVIRT_URI" attach-device "$VM" "$XML_PATH" --live 2>/dev/null; then
                echo "  实时状态: 检测到设备已在线，已立即直通进 ${VM}。"
            fi
        fi
    fi
}

do_disable() {
    compute_paths
    if [[ "${EUID}" -ne 0 ]]; then
        local args=(disable --vm "$VM" --vid "$VID" --pid "$PID" --name "$NAME")
        if [[ "$DRIVER_SET" -eq 1 || -n "$DRIVER" ]]; then
            args+=(--driver "$DRIVER")
        fi
        run_privileged "${args[@]}"
        return $?
    fi

    if [[ -f "$XML_PATH" ]]; then
        virsh -c "$LIBVIRT_URI" detach-device "$VM" "$XML_PATH" --live 2>/dev/null || true
    fi

    rm -f "$RULE_PATH" "$XML_PATH"

    # 兼容清理早期版本（未加 kvm-usb- 前缀）的文件
    local legacy_xml="${XML_DIR}/${NAME}.xml"
    local legacy_rule="${RULE_DIR}/99-${NAME}-${VM}.rules"
    if [[ -f "$legacy_xml" ]]; then
        virsh -c "$LIBVIRT_URI" detach-device "$VM" "$legacy_xml" --live 2>/dev/null || true
        rm -f "$legacy_xml"
    fi
    rm -f "$legacy_rule"

    if [[ -n "$DRIVER" ]]; then
        if ! driver_still_needed "$DRIVER" "$RULE_PATH"; then
            rm -f "$MODPROBE_PATH"
        fi
    fi

    udevadm control --reload-rules

    if [[ -n "$DRIVER" ]] && [[ ! -f "$MODPROBE_PATH" ]]; then
        modprobe "$DRIVER" 2>/dev/null || true
    fi

    echo ""
    echo "已移除自动直通并复原:"
    echo "  已清理规则: ${RULE_PATH}"
    if [[ -n "$DRIVER" ]]; then
        if [[ ! -f "$MODPROBE_PATH" ]]; then
            echo "  已恢复驱动: ${DRIVER}"
        else
            echo "  驱动 ${DRIVER} 仍被其他直通规则引用，暂保留屏蔽。"
        fi
    fi
}

# 扫描所有已托管的规则，将元数据存入全局数组 MANAGED_RULES
scan_managed_rules() {
    MANAGED_RULES=()
    local f line vm vid pid name drv desc
    for f in "${RULE_DIR}"/99-kvm-usb-*.rules "${RULE_DIR}"/99-edl-9008-*.rules; do
        [[ -f "$f" ]] || continue
        line="$(head -n 1 "$f" 2>/dev/null || true)"
        if [[ "$line" == *"$MANAGED_TAG"* ]]; then
            vm="$(sed -n 's/.*| VM=\([^ |]*\).*/\1/p' <<<"$line")"
            vid="$(sed -n 's/.*| VID=\([^ |]*\).*/\1/p' <<<"$line")"
            pid="$(sed -n 's/.*| PID=\([^ |]*\).*/\1/p' <<<"$line")"
            name="$(sed -n 's/.*| NAME=\([^ |]*\).*/\1/p' <<<"$line")"
            drv="$(sed -n 's/.*| DRIVER=\([^ |]*\).*/\1/p' <<<"$line")"
            desc="$(sed -n 's/.*| DESC=\(.*\)/\1/p' <<<"$line")"
            MANAGED_RULES+=("${f}|${vm}|${vid}|${pid}|${name}|${drv}|${desc}")
        elif [[ "$(basename "$f")" == "99-edl-9008-win10.rules" ]]; then
            # 兼容早期版本创建的 9008 规则
            MANAGED_RULES+=("${f}|win10|05c6|9008|edl-9008|qcserial|高通 9008 (旧版规则)")
        fi
    done
}

do_list() {
    scan_managed_rules
    echo ""
    if [[ ${#MANAGED_RULES[@]} -eq 0 ]]; then
        echo "当前未配置任何由本脚本管理的 USB 自动直通规则。"
        return 0
    fi
    echo "已配置的自动直通规则:"
    local i=1 entry f vm vid pid name drv desc online
    for entry in "${MANAGED_RULES[@]}"; do
        IFS='|' read -r f vm vid pid name drv desc <<<"$entry"
        online="$(lsusb -d "${vid}:${pid}" >/dev/null 2>&1 && echo '在线' || echo '未连接')"
        echo "  [${i}] ${vid}:${pid}${desc:+ ($desc)} -> VM: ${vm} | 标签: ${name} | 屏蔽驱动: ${drv:-无} | 设备状态: ${online}"
        ((i++))
    done
}

do_status() {
    do_list
    echo ""
    echo "虚拟机当前挂载的 USB hostdev:"
    local vms vm found=0
    mapfile -t vms < <(virsh -c "$LIBVIRT_URI" list --name 2>/dev/null | sed '/^$/d')
    if [[ ${#vms[@]} -eq 0 ]]; then
        echo "  (当前没有正在运行的虚拟机)"
        return 0
    fi
    for vm in "${vms[@]}"; do
        local devs
        devs="$(virsh -c "$LIBVIRT_URI" dumpxml "$vm" 2>/dev/null | grep -A 5 "<hostdev.*type='usb'" || true)"
        echo "  [VM: ${vm}]"
        if [[ -n "$devs" ]]; then
            sed 's/^/    /' <<<"$devs"
            found=1
        else
            echo "    (无)"
        fi
    done
}

select_vm() {
    local vms=()
    mapfile -t vms < <(virsh -c "$LIBVIRT_URI" list --all --name 2>/dev/null | sed '/^$/d')
    echo ""
    if [[ ${#vms[@]} -eq 0 ]]; then
        read -rp "未检测到 libvirt 虚拟机，请输入目标虚拟机名称 [默认 win10]: " input_vm
        VM="${input_vm:-win10}"
        return 0
    fi

    echo "--- 选择目标虚拟机 ---"
    local i=1 vm state
    for vm in "${vms[@]}"; do
        state="$(virsh -c "$LIBVIRT_URI" domstate "$vm" 2>/dev/null || echo 'unknown')"
        echo "  ${i}) ${vm} (${state})"
        ((i++))
    done
    echo "  0) 手动输入其他名称"

    if [[ ${#vms[@]} -eq 1 ]]; then
        read -rp "请选择虚拟机序号 [默认 1: ${vms[0]}]: " vm_idx
        vm_idx="${vm_idx:-1}"
    else
        read -rp "请选择虚拟机序号 [0-${#vms[@]}]: " vm_idx
    fi

    if [[ "$vm_idx" == "0" ]]; then
        read -rp "请输入虚拟机名称: " VM
    elif [[ "$vm_idx" =~ ^[0-9]+$ ]] && (( vm_idx >= 1 && vm_idx <= ${#vms[@]} )); then
        VM="${vms[$((vm_idx - 1))]}"
    else
        echo "输入无效，默认使用 ${vms[0]}。"
        VM="${vms[0]}"
    fi
}

menu_from_lsusb() {
    local lines=() filtered=() line vidpid desc
    mapfile -t lines < <(lsusb 2>/dev/null || true)
    for line in "${lines[@]}"; do
        if [[ "$line" =~ ID\ ([0-9a-fA-F]{4}):([0-9a-fA-F]{4})\ ?(.*) ]]; then
            local v="${BASH_REMATCH[1],,}"
            local p="${BASH_REMATCH[2],,}"
            local d="${BASH_REMATCH[3]}"
            [[ "$v" == "1d6b" ]] && continue
            filtered+=("${v}|${p}|${d}")
        fi
    done

    echo ""
    if [[ ${#filtered[@]} -eq 0 ]]; then
        echo "当前未检测到非 Root Hub 的 USB 设备。"
        return 1
    fi

    echo "--- 当前已连接的 USB 设备 ---"
    local i=1 item
    for item in "${filtered[@]}"; do
        IFS='|' read -r vidpid p desc <<<"$item"
        echo "  ${i}) [${vidpid}:${p}] ${desc}"
        ((i++))
    done
    echo "  0) 返回上一级"

    read -rp "请选择要直通的设备序号: " idx
    [[ "$idx" == "0" || -z "$idx" ]] && return 1
    if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > ${#filtered[@]} )); then
        echo "无效序号。"
        return 1
    fi

    IFS='|' read -r VID PID DESC <<<"${filtered[$((idx - 1))]}"
    select_vm
    local default_name="usb-${VID}-${PID}"
    read -rp "规则标签名称 [默认 ${default_name}]: " input_name
    NAME="${input_name:-$default_name}"

    if [[ "$VID" == "05c6" && "$PID" == "9008" ]]; then
        read -rp "需屏蔽的宿主机驱动 [默认 qcserial，输入 none 不屏蔽]: " input_drv
        if [[ "$input_drv" == "none" ]]; then
            DRIVER=""
        else
            DRIVER="${input_drv:-qcserial}"
        fi
    else
        read -rp "需屏蔽的宿主机驱动模块名 (可选，直接回车表示不屏蔽): " input_drv
        DRIVER="$input_drv"
    fi
    DRIVER_SET=1
    do_enable
}

menu_from_presets() {
    echo ""
    echo "--- 常用刷机 / 调试设备预设 ---"
    echo "  1) 高通 9008 EDL          (05c6:9008, 自动屏蔽 qcserial)"
    echo "  2) Android Fastboot/d     (18d1:d00d)"
    echo "  3) 联发科 MTK BROM        (0e8d:0003, 屏蔽 cdc_acm)"
    echo "  4) 联发科 MTK Preloader   (0e8d:2000, 屏蔽 cdc_acm)"
    echo "  0) 返回上一级"
    read -rp "请选择预设 [0-4]: " p_choice

    case "$p_choice" in
        1) VID="05c6"; PID="9008"; NAME="edl-9008"; DRIVER="qcserial"; DESC="Qualcomm 9008 EDL" ;;
        2) VID="18d1"; PID="d00d"; NAME="android-fastboot"; DRIVER=""; DESC="Android Fastboot" ;;
        3) VID="0e8d"; PID="0003"; NAME="mtk-brom"; DRIVER="cdc_acm"; DESC="MediaTek BROM" ;;
        4) VID="0e8d"; PID="2000"; NAME="mtk-preloader"; DRIVER="cdc_acm"; DESC="MediaTek Preloader" ;;
        0|"") return 0 ;;
        *) echo "无效选项。"; return 0 ;;
    esac
    DRIVER_SET=1
    select_vm
    do_enable
}

menu_manual_add() {
    echo ""
    select_vm
    while true; do
        read -rp "设备 Vendor ID (4位十六进制，如 05c6): " input_vid
        if validate_hex4 "$input_vid"; then
            VID="${input_vid,,}"
            break
        fi
        echo "格式无效，请输入 4 位十六进制。"
    done
    while true; do
        read -rp "设备 Product ID (4位十六进制，如 9008): " input_pid
        if validate_hex4 "$input_pid"; then
            PID="${input_pid,,}"
            break
        fi
        echo "格式无效，请输入 4 位十六进制。"
    done
    local default_name="usb-${VID}-${PID}"
    read -rp "规则标签名称 [默认 ${default_name}]: " input_name
    NAME="${input_name:-$default_name}"
    read -rp "设备备注描述 (可选): " DESC
    read -rp "需屏蔽的宿主机驱动模块名 (可选，回车跳过): " DRIVER
    DRIVER_SET=1
    do_enable
}

menu_manage_rules() {
    while true; do
        do_list
        [[ ${#MANAGED_RULES[@]} -eq 0 ]] && return 0
        echo ""
        echo "  输入序号可移除对应直通规则并复原驱动"
        echo "  输入 all 可一键移除全部以上规则"
        echo "  输入 0 返回主菜单"
        read -rp "请选择: " m_choice

        if [[ "$m_choice" == "0" || -z "$m_choice" ]]; then
            return 0
        elif [[ "$m_choice" == "all" ]]; then
            local entry f vm vid pid name drv desc
            for entry in "${MANAGED_RULES[@]}"; do
                IFS='|' read -r f vm vid pid name drv desc <<<"$entry"
                VM="$vm"; VID="$vid"; PID="$pid"; NAME="$name"; DRIVER="$drv"; DRIVER_SET=1
                do_disable
            done
            return 0
        elif [[ "$m_choice" =~ ^[0-9]+$ ]] && (( m_choice >= 1 && m_choice <= ${#MANAGED_RULES[@]} )); then
            local f vm vid pid name drv desc
            IFS='|' read -r f vm vid pid name drv desc <<<"${MANAGED_RULES[$((m_choice - 1))]}"
            VM="$vm"; VID="$vid"; PID="$pid"; NAME="$name"; DRIVER="$drv"; DRIVER_SET=1
            do_disable
        else
            echo "无效输入。"
        fi
    done
}

interactive_menu() {
    while true; do
        echo ""
        echo "=================================================="
        echo "   KVM / libvirt 通用 USB 自动直通管理工具"
        echo "=================================================="
        echo "  1) 从当前已连接 USB 设备 (lsusb) 点选直通"
        echo "  2) 从常用刷机预设点选直通 (9008 / Fastboot / MTK)"
        echo "  3) 手动输入 VID:PID 添加直通规则"
        echo "  4) 管理 / 恢复已配置的直通规则"
        echo "  5) 查看所有规则与虚拟机直通状态"
        echo "  0) 退出"
        echo "--------------------------------------------------"
        read -rp "请输入选项 [0-5]: " choice

        case "$choice" in
            1) menu_from_lsusb || true; read -rp "按回车继续..." _ ;;
            2) menu_from_presets; read -rp "按回车继续..." _ ;;
            3) menu_manual_add; read -rp "按回车继续..." _ ;;
            4) menu_manage_rules; read -rp "按回车继续..." _ ;;
            5) do_status; read -rp "按回车继续..." _ ;;
            0) exit 0 ;;
            *) echo "无效选项，请输入 0-5。" ;;
        esac
    done
}

if [[ $# -eq 0 ]]; then
    interactive_menu
    exit 0
fi

ACTION="$1"
shift

if [[ "$ACTION" == "-h" || "$ACTION" == "--help" ]]; then
    usage
    exit 0
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vm)     VM="${2:?缺少 --vm 参数}"; shift 2 ;;
        --vid)    VID="${2:?缺少 --vid 参数}"; shift 2 ;;
        --pid)    PID="${2:?缺少 --pid 参数}"; shift 2 ;;
        --name)   NAME="${2:?缺少 --name 参数}"; shift 2 ;;
        --driver) DRIVER="${2}"; DRIVER_SET=1; shift 2 ;;
        --desc)   DESC="${2}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数: $1" >&2; usage; exit 1 ;;
    esac
done

case "$ACTION" in
    enable)  do_enable ;;
    disable) do_disable ;;
    list)    do_list ;;
    status)  do_status ;;
    *)
        echo "未知子命令: $ACTION" >&2
        usage
        exit 1
        ;;
esac
