#!/usr/bin/env python3
"""LibreSDR B210 FPGA: build, check, flash.

Requires WORK_DIR environment variable pointing to the build output directory.
"""

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
BASH = shutil.which("bash") or "/bin/bash"
RUN_SH = SCRIPT_DIR.parent / "vivado-docker" / "run.vivado.sh"


def _work_dir():
    """Return WORK_DIR from environment, or exit with an error."""
    d = os.environ.get("WORK_DIR")
    if not d:
        print("ERROR: WORK_DIR environment variable is required.", file=sys.stderr)
        sys.exit(1)
    return Path(d)


def cmd_build(clean=False):
    """Run Vivado synthesis via Docker."""
    work = _work_dir()
    if clean:
        for suffix in [".runs", ".gen", ".cache"]:
            p = SCRIPT_DIR / "src" / f"libresdr_b210{suffix}"
            if p.exists():
                print(f"  cleaning {p.name}")
                shutil.rmtree(p, ignore_errors=True)
    work.mkdir(parents=True, exist_ok=True)
    print(f"Building...  output: {work}")
    rc = subprocess.call(
        [BASH, str(RUN_SH)],
        env={**os.environ, "WORK_DIR": str(work)},
    )
    if rc != 0:
        print(f"Build failed (exit {rc})", file=sys.stderr)
        return rc
    cmd_check()
    return 0


def cmd_check():
    """Parse reports and print summary."""
    work = _work_dir()

    def grab(path, pattern):
        try:
            return re.search(pattern, Path(path).read_text(), re.MULTILINE)
        except FileNotFoundError:
            return None

    print(f"\nFPGA Reports  ({work})")
    print("-" * 52)

    # Timing
    m = grab(
        work / "timing_summary.rpt",
        r"^\s+([\d.-]+)\s+([\d.-]+)\s+(\d+)\s+\d+\s+([\d.-]+)\s+([\d.-]+)\s+(\d+)",
    )
    if m:
        wns, whs = float(m[1]), float(m[4])
        ok = wns >= 0 and whs >= 0
        status = "PASS" if ok else "FAIL"
        print(f"  Timing   {status}  WNS={wns:+.3f}ns  WHS={whs:+.3f}ns")
    else:
        print("  Timing   (no report)")

    # DRC
    m = grab(work / "drc.rpt", r"Checks found:\s*(\d+)")
    errs = 0
    if m:
        text = (work / "drc.rpt").read_text()
        for line in text.splitlines():
            if (
                line.strip().startswith("|")
                and "Error" in line
                and "Warning" not in line
            ):
                parts = [p.strip() for p in line.split("|") if p.strip()]
                if len(parts) >= 4:
                    try:
                        errs += int(parts[3])
                    except ValueError:
                        pass
        status = "PASS" if errs == 0 else "FAIL"
        print(f"  DRC      {status}  {errs} errors, {m[1]} total checks")
    else:
        print("  DRC      (no report)")

    # Utilization
    ut = work / "utilization.rpt"
    if ut.exists():
        text = ut.read_text()
        parts = []
        for label, pat in [
            ("LUT", r"Slice LUTs"),
            ("Reg", r"Slice Registers"),
            ("BRAM", r"Block RAM Tile"),
            ("DSP", r"DSPs\s"),
        ]:
            for line in text.splitlines():
                if re.search(pat, line) and line.strip().startswith("|"):
                    fields = [c.strip() for c in line.split("|")[1:-1]]
                    if len(fields) >= 6:
                        parts.append(f"{label} {fields[5]}%")
                    break
        print(f"  Util     {', '.join(parts)}")
    else:
        print("  Util     (no report)")

    # Power
    m = grab(work / "power.rpt", r"Total On-Chip Power.*\|\s*([\d.]+)")
    if m:
        print(f"  Power    {m[1]}W")

    # Bitstream
    p = work / "libresdr_b210.bin"
    if p.exists():
        mb = p.stat().st_size / (1024 * 1024)
        print(f"  Bit      libresdr_b210.bin ({mb:.1f} MB)")
    else:
        print("  Bit      MISSING")

    print()


def cmd_flash():
    """Copy .bin to UHD images directory."""
    work = _work_dir()
    bin_path = work / "libresdr_b210.bin"
    if not bin_path.exists():
        print(f"ERROR: {bin_path} not found", file=sys.stderr)
        return 1

    # Find UHD images directory
    images_dir = os.environ.get("UHD_IMAGES_DIR")
    if images_dir:
        images_dir = Path(images_dir)
    else:
        candidates = sorted(Path("/opt/homebrew/Cellar/uhd").glob("*/share/uhd/images"))
        if not candidates:
            candidates = sorted(Path("/usr/share/uhd").glob("images"))
        images_dir = candidates[-1] if candidates else None
    if not images_dir or not images_dir.is_dir():
        print("ERROR: UHD images dir not found (set UHD_IMAGES_DIR)", file=sys.stderr)
        return 1

    target = images_dir / "usrp_b210_fpga.bin"
    mb = bin_path.stat().st_size / (1024 * 1024)

    # Backup existing (once)
    if target.exists() and target.read_bytes() != bin_path.read_bytes():
        bak = target.with_suffix(".bin.bak")
        if not bak.exists():
            shutil.copy2(target, bak)
            print(f"  Backup: {bak}")

    shutil.copy2(bin_path, target)
    print(f"  Installed {mb:.1f} MB -> {target}")
    print("  Restart your application to load the new firmware.")
    return 0


if __name__ == "__main__":
    cmds = {"build": cmd_build, "check": cmd_check, "flash": cmd_flash}
    if len(sys.argv) < 2 or sys.argv[1] not in cmds:
        print(f"Usage: WORK_DIR=<dir> {sys.argv[0]} <{'|'.join(cmds)}> [--clean]")
        sys.exit(1)
    cmd = sys.argv[1]
    clean = "--clean" in sys.argv
    if cmd == "build":
        sys.exit(cmd_build(clean=clean))
    elif cmd == "flash":
        sys.exit(cmd_flash() or 0)
    else:
        cmd_check()
