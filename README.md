# kvm-usb-passthrough

一个用于 **KVM / libvirt** 虚拟机的通用 USB 设备自动热插拔直通管理工具（交互式菜单 + CLI）。

解决诸如 **高通 9008（EDL）**、**Fastboot / Fastbootd**、**MTK BROM / Preloader** 等易在模式切换或被宿主机内核驱动（如 `qcserial`、`cdc_acm`）抢占时掉线的设备，在通过 SPICE USB 重定向时触发 `USB Reset` 导致 `LIBUSB_ERROR_NOT_FOUND` 或断开的问题。

## 工作原理

1. **绕开 SPICE 前端重定向**：在 `/etc/libvirt/qemu/` 下生成 `<hostdev mode='subsystem' type='usb' managed='yes'>` 设备描述文件。
2. **udev 热插拔触发**：在 `/etc/udev/rules.d/` 创建 `add` / `remove` 规则：
   - 设备接入时自动执行 `virsh -c qemu:///system attach-device ... --live`（先尝试 `detach-device` 保证幂等）。
   - 设备断开时匹配内核原生 `ENV{PRODUCT}`（无前导零十六进制）自动 `detach-device`。
3. **可选宿主机驱动屏蔽**：对会抢占设备节点的内核驱动（如高通 9008 对应的 `qcserial`），在 `/etc/modprobe.d/blacklist-<driver>.conf` 中写入 `install <driver> /bin/false` 并卸载，防止宿主机先行占用。多个规则共用同一驱动时，仅在最后一条引用规则被移除后才清理黑名单并恢复加载。

## 依赖要求

- Linux 宿主机（已配置 `libvirt` / `qemu:///system`）
- `virsh`、`udevadm`、`lsusb`、`pkexec`（`polkit`）
- 建议使用虚拟机前，在 `virt-manager` 的 **编辑 → 首选项 → 控制台** 中关闭 **Auto-redirect USB devices**，避免 SPICE 与底层直通争抢设备。

## 使用方法

### 交互式模式（推荐）

直接运行脚本即可进入编号菜单：

```bash
chmod +x kvm-usb-passthrough.sh
./kvm-usb-passthrough.sh
```

菜单功能：
1. **从当前已连接 USB 设备 (`lsusb`) 点选直通**：自动过滤系统 Root Hub，列出在线设备与 `virsh` 虚拟机供编号选择；若设备已在线且目标虚拟机正在运行，会立即热挂载生效。
2. **从常用刷机预设点选直通**：内置高通 9008 EDL（`05c6:9008`，自动屏蔽 `qcserial`）、Android Fastboot/d（`18d1:d00d`）、MTK BROM（`0e8d:0003`）、MTK Preloader（`0e8d:2000`）。
3. **手动输入 VID:PID 添加直通规则**：适合设备尚未接入时预先配置。
4. **管理 / 恢复已配置的直通规则**：自动扫描 `/etc/udev/rules.d/` 下由本脚本生成的规则元数据，支持按编号单条移除或输入 `all` 全部清理并恢复驱动。
5. **查看所有规则与虚拟机直通状态**。

### 命令行模式

```bash
# 添加高通 9008 -> win10 自动直通（默认屏蔽 qcserial）
./kvm-usb-passthrough.sh enable --vm win10 --vid 05c6 --pid 9008 --name edl-9008

# 添加其他设备（例如 Fastboot）
./kvm-usb-passthrough.sh enable --vm win10 --vid 18d1 --pid d00d --name android-fastboot

# 列出所有受管规则 / 查看挂载状态
./kvm-usb-passthrough.sh list
./kvm-usb-passthrough.sh status

# 移除规则并恢复驱动
./kvm-usb-passthrough.sh disable --vm win10 --vid 05c6 --pid 9008 --name edl-9008 --driver qcserial
```

## 开源协议

[MIT](LICENSE)
