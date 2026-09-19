#!/usr/bin/env python3
"""
mql_values.py - the single place that maps an MQL5 literal to .set-file text.

Shared by tools/gen_preset.py (writing) and tools/qa_preset_check.py (verifying)
so the two can never disagree about, say, what `clrDodgerBlue` or
`PERIOD_CURRENT` means. Any duplication of these tables would eventually produce
a preset whose value does not match what the EA's own default resolves to.
"""
from __future__ import annotations
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TYPES = ROOT / "MQL5" / "Include" / "XAU_AVG_PRO" / "Types.mqh"

# ENUM_TIMEFRAMES: numeric values are fixed by the platform, PERIOD_CURRENT is 0
PERIODS = {
    'PERIOD_CURRENT': 0, 'PERIOD_M1': 1, 'PERIOD_M2': 2, 'PERIOD_M3': 3, 'PERIOD_M4': 4,
    'PERIOD_M5': 5, 'PERIOD_M6': 6, 'PERIOD_M10': 10, 'PERIOD_M12': 12, 'PERIOD_M15': 15,
    'PERIOD_M20': 20, 'PERIOD_M30': 30, 'PERIOD_H1': 16777296, 'PERIOD_H2': 16777300,
    'PERIOD_H3': 16777308, 'PERIOD_H4': 16777316, 'PERIOD_H6': 16777332, 'PERIOD_H8': 16777344,
    'PERIOD_H12': 16777368, 'PERIOD_D1': 16408, 'PERIOD_W1': 32769, 'PERIOD_MN1': 49153,
}
# ENUM_BASE_CORNER - the MQL5 chart-corner enum (OBJPROP_CORNER). Note the MQL4 names
# UPPER_LEFT_CORNER / LOWER_RIGHT_CORNER are a different enum with a different numbering:
# using them here is what produced a type the MQL5 compiler has never heard of.
CORNERS = {'CORNER_LEFT_UPPER': 0, 'CORNER_LEFT_LOWER': 1,
           'CORNER_RIGHT_LOWER': 2, 'CORNER_RIGHT_UPPER': 3}
# web colours, as MQL5 stores them: 0x00BBGGRR
CLR = {
    'clrBlack': 0, 'clrWhite': 16777215, 'clrSilver': 12632256, 'clrGainsboro': 14474460,
    'clrGray': 8421504, 'clrOrange': 42546, 'clrTomato': 4678655, 'clrDodgerBlue': 16748574,
    'clrRed': 255, 'clrGreen': 32768, 'clrYellow': 65535, 'clrGold': 3381887,
    'clrLightGray': 13882323, 'clrDimGray': 6908265, 'clrAqua': 16777036, 'clrFuchsia': 65280,
    'clrLime': 65280, 'clrMaroon': 128, 'clrNavy': 8388608, 'clrTeal': 8421376,
    'clrMediumSeaGreen': 10181046, 'clrKhaki': 9385911, 'clrIndianRed': 3465414,
    'clrChocolate': 4222735, 'clrDarkOrange': 36395, 'clrLightSteelBlue': 14474430,
    'clrSteelBlue': 11829830, 'clrRoyalBlue': 13563011, 'clrSlateGray': 8421504,
}


def enums_from_types() -> dict[str, dict[str, int]]:
    """`{ENUM_NAME: {MEMBER: value}}` parsed from Types.mqh."""
    txt = TYPES.read_text()
    out: dict[str, dict[str, int]] = {}
    for m in re.finditer(r'enum\s+(\w+)\s*\{(.*?)\};', txt, re.S):
        members: dict[str, int] = {}
        for line in m.group(2).splitlines():
            line = line.split('//')[0].strip().rstrip(',')
            mm = re.match(r'(\w+)\s*=\s*(-?\d+)', line)
            if mm:
                members[mm.group(1)] = int(mm.group(2))
        if members:
            out[m.group(1)] = members
    return out


def all_enum_members() -> dict[str, int]:
    flat: dict[str, int] = {}
    for members in enums_from_types().values():
        flat.update(members)
    return flat


def resolve(value: str, typ: str = '') -> str:
    """MQL5 source literal -> the text MT5 stores in a .set file.

    Raises ValueError for anything that cannot be represented exactly, because a
    guessed value in a preset is worse than no preset.
    """
    v = (value or '').strip()
    if v == '':
        return ''
    if v in ('true', 'false'):
        return '1' if v == 'true' else '0'
    if v.startswith('"') and v.endswith('"'):
        return v[1:-1]
    if v in PERIODS:
        return str(PERIODS[v])
    if v in CORNERS:
        return str(CORNERS[v])
    if v in CLR:
        return str(CLR[v])
    if v.startswith('clr'):
        raise ValueError(f"colour {v} has no numeric mapping - add it to CLR in tools/mql_values.py")
    if typ and typ.startswith('ENUM_'):
        table = enums_from_types().get(typ)
        if table and v in table:
            return str(table[v])
    if v.endswith('f') and re.fullmatch(r'-?\d*\.?\d+f', v):
        return v[:-1]
    if re.fullmatch(r'-?\d+', v) or re.fullmatch(r'-?\d*\.\d+', v):
        return v
    # a bare identifier that is not a known literal: only acceptable when the
    # type is a string input (e.g. a symbol or a comment fragment)
    if typ in ('string', ''):
        return v
    raise ValueError(f"cannot resolve {v!r} for type {typ!r}")


STANDARD_ENUMS = {'ENUM_BASE_CORNER', 'ENUM_ANCHOR_POINT', 'ENUM_TIMEFRAMES',
                 'ENUM_ORDER_TYPE_FILLING', 'ENUM_SYMBOL_INFO_INTEGER', 'ENUM_CHART_PROPERTY_INTEGER'}


def numeric_domain(typ: str) -> set[int] | None:
    """The set of legal integers for an enum-typed input, if it is an enum."""
    if typ in PERIODS.values() or typ == 'ENUM_TIMEFRAMES':
        return set(PERIODS.values())
    if typ == 'ENUM_BASE_CORNER':
        return set(CORNERS.values())
    table = enums_from_types().get(typ)
    return set(table.values()) if table else None
