#!/usr/bin/env python3
"""Boot the ISO in QEMU through UEFI firmware (OVMF) and GRUB, exactly like the laptop does, and save
screenshots of the GRUB menu and the booted console (autologin) as PNG files.

Usage: scripts/qemu_uefi_screenshot.py [iso] [outdir]
"""
import os, shutil, socket, struct, subprocess, sys, tempfile, time, zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ISO = sys.argv[1] if len(sys.argv) > 1 else f"{ROOT}/build/live/cudalite-os-rtx4060.iso"
OUT = sys.argv[2] if len(sys.argv) > 2 else f"{ROOT}/docs/results"
SHOTS = [(4.5, "qemu-uefi-1-grub-menu"), (55, "qemu-uefi-2-booted-console")]


def ppm_to_png(src, dst):
    head, px = open(src, "rb").read().split(b"\n", 3)[:3], open(src, "rb").read().split(b"\n", 3)[3]
    w, h = map(int, head[1].split())
    raw = b"".join(b"\x00" + px[y * w * 3:(y + 1) * w * 3] for y in range(h))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    with open(dst, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def main():
    tmp = tempfile.mkdtemp(prefix="cl-uefi-")
    mon, vars_fd = f"{tmp}/mon.sock", f"{tmp}/OVMF_VARS.fd"
    shutil.copy("/usr/share/OVMF/OVMF_VARS_4M.fd", vars_fd)
    q = subprocess.Popen([
        "qemu-system-x86_64", "-enable-kvm", "-m", "4G", "-smp", "4", "-cpu", "host", "-machine", "q35",
        "-vga", "std", "-display", "none",
        "-drive", "if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd",
        "-drive", f"if=pflash,format=raw,file={vars_fd}",
        "-cdrom", ISO, "-boot", "d", "-monitor", f"unix:{mon},server,nowait"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(50):
        if os.path.exists(mon):
            break
        time.sleep(0.1)
    m = socket.socket(socket.AF_UNIX)
    m.connect(mon)
    m.settimeout(2)

    def cmd(c):
        m.sendall((c + "\n").encode())
        time.sleep(0.5)
        try:
            m.recv(65536)
        except Exception:
            pass

    t0 = time.time()
    os.makedirs(OUT, exist_ok=True)
    for at, name in SHOTS:
        time.sleep(max(0, at - (time.time() - t0)))
        cmd(f"screendump {tmp}/{name}.ppm")
        time.sleep(1)
        ppm_to_png(f"{tmp}/{name}.ppm", f"{OUT}/{name}.png")
        print(f"saved {OUT}/{name}.png (t={time.time() - t0:.0f}s)")
    cmd("quit")
    q.wait(timeout=15)
    shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
