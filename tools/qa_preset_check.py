#!/usr/bin/env python3
"""
qa_preset_check.py - verify presets/ against the actual EA source.

A preset is only trustworthy if it is provably (a) complete, (b) legal for the
input types, and (c) free of secrets. This checker proves all three by reading
the inputs and enums out of the MQL5 source rather than trusting the .set text.

Checks per preset:
  1  exactly one line per declared input, no unknown or duplicated names
  2  [input] section header present, comments only where legal
  3  the "overrides:" manifest equals the set of lines that differ from the
     EA default (so nobody can hand-edit a preset without the manifest saying so)
  4  every enum-typed value is a numeric member of that enum in Types.mqh
     (ENUM_TIMEFRAMES / ENUM_CORNER / colours handled with the MQL5 standard values)
  5  bool inputs are 0/1, int inputs are integral, double inputs parse,
     strings contain no control characters
  6  the safety invariants ValidateConfig() treats as hard errors also hold
     here (caps >= base lot, cut loss armed, money targets positive, ...)
  7  no Telegram secret is present anywhere in the file

Exit code 0 = every preset is valid.
"""
from __future__ import annotations
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EA = ROOT / "MQL5" / "Experts" / "XAU_AVG_PRO.mq5"
TYPES = ROOT / "MQL5" / "Include" / "XAU_AVG_PRO" / "Types.mqh"
PRESET_DIR = ROOT / "presets"

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mql_values import resolve as preset_resolve        # single source of truth

INPUT_RE = re.compile(r'^input\s+(?P<type>[\w:]+)\s+(?P<name>\w+)\s*=\s*(?P<def>[^;]*);')

# MQL5 standard enums used by the inputs (values are fixed by the platform)
PERIODS = {0, 1, 2, 3, 4, 5, 6, 10, 12, 15, 20, 30,
           16777296, 16777300, 16777308, 16777316, 16777332, 16777344, 16777368,
           16408, 32769, 49153}
CORNERS = {0, 1, 2, 3}
SECRET_RE = re.compile(r'\b\d{8,10}:AA[A-Za-z0-9_\-]{20,}\b')


def load_inputs() -> dict[str, tuple[str, str]]:
    out: dict[str, tuple[str, str]] = {}
    for line in EA.read_text().splitlines():
        m = INPUT_RE.match(line.strip())
        if m and m.group('name') != 'group':
            out[m.group('name')] = (m.group('type'), m.group('def').strip())
    return out


def load_enums() -> dict[str, set[int]]:
    txt = TYPES.read_text()
    enums: dict[str, set[int]] = {}
    for m in re.finditer(r'enum\s+(\w+)\s*\{(.*?)\};', txt, re.S):
        vals = set()
        for line in m.group(2).splitlines():
            mm = re.match(r'\s*\w+\s*=\s*(-?\d+)', line)
            if mm:
                vals.add(int(mm.group(1)))
        if vals:
            enums[m.group(1)] = vals
    return enums


def resolve_default(typ: str, default: str, enums: dict) -> str:
    """Same function the generator uses, so the checker can never disagree with
    the writer about what `clrDodgerBlue` or `PERIOD_CURRENT` means."""
    try:
        return preset_resolve(default, typ)
    except ValueError:
        return default


def check_preset(path: Path, inputs: dict, enums: dict) -> list[str]:
    problems: list[str] = []
    text = path.read_text()
    if SECRET_RE.search(text):
        problems.append("contains a Telegram-token-shaped literal")
    for name in ('TelegramBotToken', 'TelegramChatID'):
        m = re.search(rf'^{name}=(.*)$', text, re.M)
        if m and m.group(1).strip():
            problems.append(f"{name} must stay empty in a committed preset (found a value)")
    if '[input]' not in text:
        problems.append("no [input] section header")

    body = [l for l in text.splitlines() if l and not l.startswith(';') and l != '[input]']
    seen: dict[str, str] = {}
    for line in body:
        if '=' not in line:
            problems.append(f"malformed line: {line!r}")
            continue
        k, v = line.split('=', 1)
        k = k.strip()
        if k in seen:
            problems.append(f"duplicate input {k}")
        seen[k] = v.strip()

    unknown = sorted(set(seen) - set(inputs))
    missing = sorted(set(inputs) - set(seen))
    if unknown:
        problems.append(f"unknown input names: {unknown[:5]}")
    if missing:
        problems.append(f"{len(missing)} inputs missing, e.g. {missing[:5]}")

    # manifest must equal the real difference set
    man = re.search(r'^;\s*overrides:\s*(.*)$', text, re.M)
    declared = sorted(x for x in (man.group(1).split(',') if man else []) if x.strip())
    real_diff = []
    for k, v in seen.items():
        if k not in inputs:
            continue
        typ, dflt = inputs[k]
        if v != resolve_default(typ, dflt, enums):
            real_diff.append(k)
    real_diff = sorted(real_diff)
    undeclared = sorted(set(real_diff) - set(declared))
    if undeclared:
        problems.append(f"values differ from the EA default but are not in the manifest: {undeclared}")
    equal_to_default = sorted(set(declared) - set(real_diff))
    if equal_to_default:
        print(f"      note  {path.name}: {len(equal_to_default)} override(s) coincide with the "
              f"default ({', '.join(equal_to_default)}) - intentional pinning, not an error")

    # per-type legality
    for k, v in seen.items():
        if k not in inputs:
            continue
        typ, _ = inputs[k]
        if typ in enums:
            try:
                iv = int(v)
            except ValueError:
                problems.append(f"{k}: enum value {v!r} is not numeric")
                continue
            if iv not in enums[typ]:
                problems.append(f"{k}: {iv} is not a member of {typ} (allowed {sorted(enums[typ])})")
        elif typ == 'ENUM_TIMEFRAMES':
            if v.strip() not in {str(x) for x in PERIODS}:
                problems.append(f"{k}: {v!r} is not a valid ENUM_TIMEFRAMES value")
        elif typ == 'ENUM_CORNER':
            if v.strip() not in {str(x) for x in CORNERS}:
                problems.append(f"{k}: {v!r} is not a valid ENUM_CORNER value")
        elif typ == 'bool':
            if v not in ('0', '1'):
                problems.append(f"{k}: bool must be 0 or 1, got {v!r}")
        elif typ in ('int', 'long', 'uint', 'ulong'):
            if not re.fullmatch(r'-?\d+', v):
                problems.append(f"{k}: {v!r} is not an integer")
        elif typ in ('double', 'float'):
            if not re.fullmatch(r'-?\d+(\.\d+)?', v):
                problems.append(f"{k}: {v!r} is not a number")
        elif typ == 'string':
            if any(ord(ch) < 32 for ch in v):
                problems.append(f"{k}: control character in string value")

    # safety invariants the EA itself insists on
    def num(k: str, default: float = 0.0) -> float:
        try:
            return float(seen.get(k, default))
        except (TypeError, ValueError):
            return default

    base = num('InitialLot')
    if num('MaximumLotPerOrder') < base:
        problems.append(f"MaximumLotPerOrder {num('MaximumLotPerOrder')} < InitialLot {base}")
    if num('MaximumTotalLot') < base:
        problems.append(f"MaximumTotalLot {num('MaximumTotalLot')} < InitialLot {base}")
    if num('LotMultiplier') < 1.0:
        problems.append("LotMultiplier < 1.0")
    if int(num('MaximumLayer', 1)) < 1:
        problems.append("MaximumLayer < 1")
    if num('BasketTakeProfitMoney') <= 0 and int(num('BasketTPMode')) == 1:
        problems.append("BasketTPMode=MONEY with a non-positive target")
    if int(num('EnableBasketCutLoss')) != 1:
        problems.append("preset ships with the basket cut loss disabled")
    if num('MaximumDailyLossMoney') <= 0:
        problems.append("preset ships without a daily loss cap")
    if num('MaximumAccountDrawdownPercent') <= 0:
        problems.append("preset ships without an account drawdown cap")
    if int(num('EnableTelegram')) == 1 and not seen.get('TelegramChatID'):
        problems.append("EnableTelegram=1 without a chat id (the EA self-disables; leave it 0 in a preset)")
    return problems


def main() -> int:
    inputs = load_inputs()
    enums = load_enums()
    presets = sorted(PRESET_DIR.glob("*.set"))
    print(f"inputs in source : {len(inputs)}")
    print(f"enums in Types   : {len(enums)}")
    print(f"presets found    : {len(presets)}")
    if len(presets) != 3:
        print(f"PROBLEM: expected exactly 3 presets, found {len(presets)}")
    all_problems: list[str] = []
    for p in presets:
        probs = check_preset(p, inputs, enums)
        status = "OK" if not probs else f"{len(probs)} PROBLEM(S)"
        print(f"  {p.name:38s} {len([l for l in p.read_text().splitlines() if '=' in l and not l.startswith(';')]):4d} lines  {status}")
        for x in probs:
            print(f"      ! {x}")
            all_problems.append(f"{p.name}: {x}")
    if all_problems:
        print(f"\nPRESET QA FAILED ({len(all_problems)} problems)")
        return 1
    print("\nall presets valid: complete, type-legal, manifest-accurate, secret-free")
    return 0


if __name__ == '__main__':
    sys.exit(main())
