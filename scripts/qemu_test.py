#!/usr/bin/env python3
"""Boot the CudaLite ISO in QEMU, log in over the serial console and run non-GPU checks.

A VM without GPU passthrough cannot run CUDA; this verifies everything else: boot to a login,
unprivileged service account, firewall, read-only root + overlay, sysctl hardening, the systemd
sandbox of the benchmark unit, and the NVIDIA module wiring (module present, aliases resolve).
Usage: scripts/qemu_test.py [iso] [transcript]
"""
import os, socket, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ISO = sys.argv[1] if len(sys.argv) > 1 else f"{ROOT}/build/live/cudalite-os-rtx4060.iso"
OUT = sys.argv[2] if len(sys.argv) > 2 else f"{ROOT}/docs/results/qemu-boot-test.txt"
LIVE = f"{ROOT}/build/live/binary/live"
BOOT_TIMEOUT = 240

CHECKS = [
    "uname -a; grep PRETTY_NAME /etc/os-release; cat /proc/cmdline",
    "systemd-analyze 2>&1",
    "systemd-analyze blame --no-pager 2>&1 | head -8",
    "free -m; echo packages: $(dpkg-query -W -f='${binary:Package}\\n' | sort -u | wc -l)",
    "id cudalite; id cudauser",
    "systemctl get-default; systemctl is-enabled cudalite-benchmark.service nftables.service; systemctl --failed --no-legend",
    "systemctl is-active nftables.service",
    "sudo nft list ruleset",
    "sudo ss -tulpn; echo '(only DHCP *client* sockets expected; no listening services)'",
    "dpkg-query -W -f='${binary:Package}\\n' | grep -E '^(gcc|cpp|cron|logrotate|linux-headers)' || echo '(toolchain/cron removed)'; ls /lib/modules/*/updates/dkms/",
    "findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS / /run/live/medium /run/live/rootfs/filesystem.squashfs 2>&1",
    "sysctl kernel.kptr_restrict kernel.dmesg_restrict kernel.yama.ptrace_scope kernel.unprivileged_bpf_disabled",
    "ls -l /usr/local/bin/",
    "systemd-analyze verify /etc/systemd/system/cudalite-benchmark.service 2>&1; echo verify-exit=$?",
    "systemd-analyze security cudalite-benchmark.service --no-pager 2>&1 | tail -40",
    "modinfo nvidia-current 2>&1 | head -4",
    "modprobe -n -v nvidia 2>&1; modprobe -n -v nvidia-uvm 2>&1",
    "lsmod | grep -i -E 'nvidia|nouveau' || echo '(no nvidia/nouveau modules loaded: expected without the GPU)'",
    "ls -l /dev/nvidia* 2>&1 | head -3",
    "systemctl status cudalite-benchmark.service --no-pager 2>&1 | head -14",
    "journalctl -u cudalite-benchmark.service -b --no-pager 2>&1 | tail -8",
    "/usr/local/bin/hello_cuda 2>&1; echo hello_cuda-exit=$?",
    "sudo dmesg | grep -i -E 'nvidia|nouveau|firmware|amdgpu' | head -8; echo '(no GPU in this VM)'",
]


def main():
    sock_path = tempfile.mktemp(prefix="cl-serial-")
    cmd = [
        "qemu-system-x86_64", "-enable-kvm", "-m", "4G", "-smp", "4", "-cpu", "host",
        "-display", "none", "-no-reboot",
        "-cdrom", ISO,
        "-kernel", f"{LIVE}/vmlinuz", "-initrd", f"{LIVE}/initrd.img",
        "-append", "boot=live components hostname=cudalite username=cudauser "
                   "modprobe.blacklist=nouveau console=ttyS0,115200n8",
        "-serial", f"unix:{sock_path},server,nowait",
    ]
    qemu = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    t0 = time.time()
    for _ in range(50):
        if os.path.exists(sock_path):
            break
        time.sleep(0.1)
    s = socket.socket(socket.AF_UNIX)
    s.connect(sock_path)
    s.settimeout(1.0)
    log = []

    def read_until(marker, timeout):
        buf, end = "", time.time() + timeout
        while time.time() < end:
            try:
                d = s.recv(65536).decode("utf-8", "replace")
            except socket.timeout:
                continue
            if not d:
                break
            buf += d
            if marker in buf:
                return buf
        return buf + f"\n[TIMEOUT waiting for {marker!r}]"

    try:
        boot = read_until("cudalite login:", BOOT_TIMEOUT)
        log.append(boot)
        if "cudalite login:" not in boot:
            raise RuntimeError("never reached a login prompt")
        boot_s = time.time() - t0
        s.sendall(b"cudauser\n")
        out = read_until("$ ", 30)
        log.append(out)
        s.sendall(b"export PS1='$ ' PATH=$PATH:/usr/sbin:/sbin; bind 'set enable-bracketed-paste off'; stty -echo; echo READY\n")
        read_until("READY\r\n", 10)
        header = f"=== QEMU boot test: {ISO}\n=== reached login prompt after {boot_s:.1f} s wall-clock (KVM, 4 vCPU)\n"
        results = [header]
        for i, c in enumerate(CHECKS):
            tag = f"__END{i}__"
            s.sendall(f"{c}; echo {tag}\n".encode())   # one line: sudo flushes typed-ahead input
            o = read_until(tag + "\r\n", 60)
            o = o.split(tag)[0].replace("\r", "")
            results.append(f"\n$ {c}\n{o.strip()}\n")
        s.sendall(b"sudo poweroff\n")
        text = "".join(results)
    finally:
        try:
            qemu.wait(timeout=20)
        except Exception:
            qemu.kill()
        if os.path.exists(sock_path):
            os.unlink(sock_path)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        f.write(text)
        f.write("\n\n=== raw boot console (serial) ===\n")
        f.write("".join(log).replace("\r", ""))
    print(text)


if __name__ == "__main__":
    main()
