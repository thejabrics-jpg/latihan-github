#!/usr/bin/env python3
"""
gen_preset.py - build MT5 .set presets from the EA inputs, with overrides.

The parameter *names* are extracted from MQL5/Experts/XAU_AVG_PRO.mq5, so a
preset can never contain a name that the EA does not have, and it cannot drift
when an input is renamed (the generation step fails instead).

Usage:
  python3 tools/gen_preset.py --name conservative \\
      --set InitialLot=0.01 --set LotMode=XAU_LOT_FIXED --out presets/XAU_AVG_PRO_conservative.set

Enum inputs accept either the member name (XAU_LOT_FIXED) or a number; member
names are resolved through Types.mqh so the file MT5 loads always contains the
numeric value MT5 expects.
"""
from __future__ import annotations
import argparse
import datetime
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EA = ROOT / "MQL5" / "Experts" / "XAU_AVG_PRO.mq5"
TYPES = ROOT / "MQL5" / "Include" / "XAU_AVG_PRO" / "Types.mqh"
sys.path.insert(0, str(Path(__file__).resolve().parent))

INPUT_RE = re.compile(r'^input\s+(?P<type>[\w:]+)\s+(?P<name>\w+)\s*=\s*(?P<def>[^;]*);')


from mql_values import resolve          # noqa: E402  (shared with qa_preset_check.py)


def enum_values() -> dict[str, int]:
    """All `XAU_* = <int>` members declared in Types.mqh enums."""
    txt = TYPES.read_text()
    out: dict[str, int] = {}
    for m in re.finditer(r'enum\s+\w+\s*\{(.*?)\};', txt, re.S):
        for line in m.group(1).splitlines():
            line = line.strip().rstrip(',')
            mm = re.match(r'(XAU_\w+)\s*=\s*(-?\d+)', line)
            if mm:
                out[mm.group(1)] = int(mm.group(2))
    return out


def inputs() -> list[tuple[str, str, str]]:
    rows, seen = [], set()
    for line in EA.read_text().splitlines():
        m = INPUT_RE.match(line.strip())
        if not m:
            continue
        name = m.group('name')
        if name in seen or name == 'group':
            continue
        seen.add(name)
        rows.append((m.group('type'), name, m.group('def').strip()))
    return rows


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--name', required=True)
    ap.add_argument('--set', action='append', default=[], help='Name=value (repeatable)')
    ap.add_argument('--comment', action='append', default=[])
    ap.add_argument('--out', required=True)
    args = ap.parse_args()

    enums = enum_values()
    overrides: dict[str, str] = {}
    for item in args.set:
        if '=' not in item:
            raise SystemExit(f"--set expects Name=value, got {item!r}")
        k, v = item.split('=', 1)
        overrides[k.strip()] = v.strip()

    rows = inputs()
    known = {n for _, n, _ in rows}
    unknown = sorted(set(overrides) - known)
    if unknown:
        raise SystemExit(f"unknown input name(s) in overrides: {unknown}")

    lines = [
        f"; XAU_AVG_PRO preset: {args.name}",
        f"; generated {datetime.date.today().isoformat()} by tools/gen_preset.py - do not edit by hand",
        f"; {len(rows)} inputs, {len(overrides)} overridden",
    ]
    lines += [f"; {c}" for c in args.comment]
    # the manifest lets tools/qa_preset_check.py prove that nothing in this file
    # differs from the EA default except what was deliberately overridden
    if overrides:
        lines.append("; overrides: " + ",".join(sorted(overrides)))
    lines += ["[input]"]
    for typ, name, default in rows:
        value = resolve(overrides.get(name, default), typ)
        # one "name=value" per line: MT5 reads the value up to the end of the
        # line or to the "||" optimisation metadata, which we deliberately do
        # not write - a preset must set values, never optimisation ranges
        lines.append(f"{name}={value}")
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines) + "\n")
    try:
        shown = out.resolve().relative_to(ROOT)
    except ValueError:
        shown = out
    print(f"wrote {shown} ({len(rows)} inputs, {len(overrides)} overrides)")
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
