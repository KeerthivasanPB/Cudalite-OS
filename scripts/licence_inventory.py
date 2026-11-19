#!/usr/bin/env python3
"""Licence inventory of the CudaLite OS image, read from the built chroot.

For every installed package: version, Debian archive area (main / contrib / non-free / non-free-firmware,
from the package's Section) and the licence names declared in its /usr/share/doc/<pkg>/copyright file
(machine-readable DEP-5 "License:" fields; free-form files are marked "see copyright").

Usage: scripts/licence_inventory.py [chroot] [out.tsv]
"""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHROOT = sys.argv[1] if len(sys.argv) > 1 else f"{ROOT}/build/live/chroot"
OUT = sys.argv[2] if len(sys.argv) > 2 else f"{ROOT}/docs/licences.tsv"


def packages():
    text = open(f"{CHROOT}/var/lib/dpkg/status", encoding="utf-8", errors="replace").read()
    for block in text.split("\n\n"):
        f = dict(re.findall(r"^([A-Za-z-]+): ?(.*)$", block, re.M))
        if f.get("Package") and "installed" in f.get("Status", "").split():
            yield f


def area(section):
    return section.split("/")[0] if "/" in section else "main"


# Packages whose copyright file is free-form (not DEP-5): licence summarised by hand from that file.
FREEFORM = {
    **dict.fromkeys(["binutils", "binutils-common", "binutils-x86-64-linux-gnu", "libbinutils", "libctf0",
                     "libctf-nobfd0", "libgprofng0", "libsframe1"], "GPL-3+, LGPL-3+ (summarised)"),
    "busybox": "GPL-2 (summarised)",
    # shared linux-firmware copyright file lists every vendor; only the AMD terms apply to this package
    "firmware-amd-graphics": "binary-redist-AMD-permissive / AMD-restrictive (redistributable binary firmware)",
    "debian-archive-keyring": "GPL (summarised)",
    **dict.fromkeys(["gcc-14-base", "libgcc-s1", "libstdc++6"],
                    "GPL-3+ with GCC Runtime Library Exception (summarised)"),
    **dict.fromkeys(["klibc-utils", "libklibc"], "BSD-3-Clause, GPL-2 (summarised)"),
    "libcrypt1": "LGPL-2.1+, BSD, public-domain (summarised)",
    **dict.fromkeys(["libgssapi-krb5-2", "libk5crypto3", "libkrb5-3", "libkrb5support0"],
                    "MIT (Kerberos), BSD (summarised)"),
}


def licences(pkg):
    if pkg in FREEFORM:
        return FREEFORM[pkg]
    """Licence names from the copyright file. dpkg resolves the doc dir; some packages symlink it."""
    path = f"{CHROOT}/usr/share/doc/{pkg}/copyright"
    real = os.path.realpath(path)
    if not real.startswith(os.path.realpath(CHROOT)):            # absolute symlink: re-root it in the chroot
        real = CHROOT + os.path.realpath(path).split(CHROOT, 1)[-1]
    if os.path.islink(f"{CHROOT}/usr/share/doc/{pkg}"):
        target = os.readlink(f"{CHROOT}/usr/share/doc/{pkg}")
        real = os.path.join(f"{CHROOT}/usr/share/doc", target, "copyright") if not target.startswith("/") \
            else CHROOT + target + "/copyright"
    if not os.path.exists(real):
        return "no copyright file"
    text = open(real, encoding="utf-8", errors="replace").read()
    if pkg.startswith("linux-image-") and "Linux kernel" in text:
        return "GPL-2.0"
    names = []
    for n in re.findall(r"^License:[ \t]*(\S[^\n]*)$", text, re.M):
        for part in re.split(r"\s+or\s+|\s+and\s+|\s*,\s*", n.strip()):
            part = part.strip("() ")
            if part and part not in names:
                names.append(part)
    return ", ".join(names) if names else "see copyright (free-form)"


def main():
    rows = sorted(packages(), key=lambda f: f["Package"])
    with open(OUT, "w") as o:
        o.write("package\tversion\tarea\tlicences (from /usr/share/doc/<pkg>/copyright)\n")
        for f in rows:
            o.write(f"{f['Package']}\t{f.get('Version', '')}\t{area(f.get('Section', ''))}\t{licences(f['Package'])}\n")
    counts = {}
    for f in rows:
        a = area(f.get("Section", ""))
        counts[a] = counts.get(a, 0) + 1
    print(f"{len(rows)} packages -> {OUT}")
    for a, n in sorted(counts.items()):
        print(f"  {a:18} {n}")
    for f in rows:
        if area(f.get("Section", "")) != "main":
            print(f"  {area(f['Section']):18} {f['Package']} {f['Version']}")


if __name__ == "__main__":
    main()
