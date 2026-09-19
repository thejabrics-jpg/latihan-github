#!/usr/bin/env python3
"""
gen_input_docs.py - generate docs/02-input-specification.md from the source.

The input table and the CConfig field list are extracted from
MQL5/Experts/XAU_AVG_PRO.mq5 and MQL5/Include/XAU_AVG_PRO/Types.mqh, so the
documented parameter reference can never drift away from the code.

Usage:  python3 tools/gen_input_docs.py [--check]
  --check  do not write the file, only report differences (used by QA)
"""
from __future__ import annotations
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EA = ROOT / "MQL5" / "Experts" / "XAU_AVG_PRO.mq5"
TYPES = ROOT / "MQL5" / "Include" / "XAU_AVG_PRO" / "Types.mqh"
DOC = ROOT / "docs" / "02-input-specification.md"

INPUT_RE = re.compile(
    r'^input\s+(?P<type>[\w:]+)\s+(?P<name>\w+)\s*=\s*(?P<def>.*?);\s*(?://\s*(?P<cmt>.*))?$')
GROUP_RE = re.compile(r'^input\s+group\s+"(?P<title>[^"]*)"')
DESC_RE = re.compile(r'^\s*(?://|///)\s*(?P<text>.*)$')


def literal_kind(default: str, typ: str) -> str:
    d = default.strip()
    if d in ('true', 'false'):
        return 'bool'
    if d.startswith('"'):
        return 'string'
    if re.fullmatch(r'-?\d+', d):
        return 'int'
    if re.fullmatch(r'-?\d*\.\d+[fF]?', d):
        return 'double'
    return 'enum'


def validation_hint(name: str, typ: str, default: str) -> str:
    """Validation summary, kept in sync with ValidateConfig() rules by hand
    but generated from the declared type so no row is ever missing."""
    d = default.strip()
    if typ.startswith('ENUM_'):
        return f'one of the declared {typ} values (compiler enforced)'
    if name.lower().startswith(('max', 'maximum', 'minimum')) and typ == 'double':
        return 'finite, >= 0; hard caps are additionally clamped to the broker limits'
    if typ == 'double':
        return 'finite; range rules in ValidateConfig()'
    if typ == 'int':
        return 'ValidateConfig() clamps the value into its documented range'
    if typ == 'bool':
        return 'no validation needed'
    if typ == 'string':
        if 'Comment' in name:
            return 'sanitised to printable ASCII and truncated to 28 characters'
        return 'length/character rules in ValidateConfig()'
    return 'see ValidateConfig()'


def parse_inputs() -> list[dict]:
    rows: list[dict] = []
    group = 'GENERAL'
    pending_desc: list[str] = []
    lines = EA.read_text().splitlines()
    for ln in lines:
        g = GROUP_RE.match(ln.strip())
        if g:
            group = g.group('title').strip('= ').strip()
            continue
        m = INPUT_RE.match(ln.strip())
        if m:
            rows.append({
                'group': group,
                'type': m.group('type'),
                'name': m.group('name'),
                'default': m.group('def').strip(),
                'comment': (m.group('cmt') or '').strip(),
                'desc': ' '.join(pending_desc).strip(),
            })
            pending_desc = []
            continue
        d = DESC_RE.match(ln)
        if d and not ln.strip().startswith('///---'):
            pending_desc.append(d.group('text').strip())
        elif ln.strip() == '' and pending_desc:
            pending_desc = []
    return rows


def parse_cconfig() -> dict[str, str]:
    txt = TYPES.read_text()
    m = re.search(r'\bclass CConfig\b[^{]*\{', txt)
    if not m:
        raise SystemExit('CConfig not found')
    i = m.end() - 1
    depth = 0
    j = i
    while j < len(txt):
        if txt[j] == '{':
            depth += 1
        elif txt[j] == '}':
            depth -= 1
            if depth == 0:
                break
        j += 1
    body = txt[i:j]
    body = re.sub(r'/\*.*?\*/', '', body, flags=re.S)
    fields = {}
    for fm in re.finditer(r'^\s*(?://.*)$', body, re.M):
        pass
    cur_comment = ''
    for line in body.splitlines():
        ls = line.strip()
        if ls.startswith('//'):
            cur_comment = ls[2:].strip()
            continue
        fm = re.match(r'^(?:const\s+)?([A-Za-z_]\w*)\s+([A-Za-z_]\w*)\s*;\s*(?://\s*(.*))?$', ls)
        if fm:
            fields[fm.group(2)] = {'type': fm.group(1), 'note': (fm.group(3) or cur_comment or '').strip()}
            cur_comment = ''
        else:
            cur_comment = ''
    return fields


def render(rows: list[dict], cfg: dict) -> str:
    out: list[str] = []
    out.append('# 02 - Complete Input Specification')
    out.append('')
    out.append('This document is **generated** from the source by `tools/gen_input_docs.py`;')
    out.append('it is the authoritative list of every input of XAU_AVG_PRO v1.0.0 and it is')
    out.append('guaranteed to match `MQL5/Experts/XAU_AVG_PRO.mq5` exactly.')
    out.append('')
    out.append('* Every input is read once in `OnInit()` and copied into the `CConfig`')
    out.append('  struct. No module ever reads an `input` variable directly, which is what')
    out.append('  makes the Telegram overrides and the unit self tests possible.')
    out.append('* Defaults are the **conservative** values intended for a first live run on')
    out.append('  a cent or demo account (see `docs/09-known-risks-and-limitations.md`).')
    out.append('* `ValidateConfig()` (in the `.mq5`) clamps or rejects the values listed in')
    out.append('  the *Validation* column. A hard error keeps the EA running in a trading-')
    out.append('  disabled state so that the dashboard and the log stay readable.')
    out.append('')
    out.append(f'**{len(rows)} inputs / {len(cfg)} CConfig fields** '
               f'({len(cfg) - len(rows)} fields are operator state, not inputs: '
               '`emergency_stop`, `user_paused`, `override_flags`).')
    out.append('')
    groups: dict[str, list[dict]] = {}
    for r in rows:
        groups.setdefault(r['group'], []).append(r)
    for gname, items in groups.items():
        out.append(f'## {gname}')
        out.append('')
        out.append('| Input | Type | Default | Meaning | Validation |')
        out.append('|---|---|---|---|---|')
        for r in items:
            meaning = r['comment'] or r['desc'] or r['name']
            default = r['default'].replace('|', '\\|')
            t = r['type']
            kind = literal_kind(default, t)
            if kind == 'enum':
                default = f'`{default}`'
            elif kind == 'string':
                default = f'`{default}`'
            else:
                default = f'`{default}`'
            out.append(f'| `{r["name"]}` | `{t}` | {default} | {meaning} | {validation_hint(r["name"], t, r["default"])} |')
        out.append('')
    # cross-reference table for CConfig state fields
    state_only = [k for k in cfg if k not in {r['name'] for r in rows}]
    if state_only:
        out.append('## Non-input `CConfig` fields (operator state)')
        out.append('')
        out.append('| Field | Type | Purpose |')
        out.append('|---|---|---|')
        for k in state_only:
            out.append(f'| `{k}` | `{cfg[k]["type"]}` | {cfg[k]["note"] or "runtime operator state, restored from the state file"} |')
        out.append('')
    out.append('## Enums used by the inputs')
    out.append('')
    out.append('Every enum type below is declared in `MQL5/Include/XAU_AVG_PRO/Types.mqh`.')
    out.append('Because the values are declared as `input enum` with explicit member names,')
    out.append('MetaEditor shows readable names in the dialog instead of numbers.')
    out.append('')
    out.append('`ENUM_TIMEFRAMES` (`EMATimeframe`, `ATRTimeframe`, `VolatilityTimeframe`) is the')
    out.append('MQL5 standard enum, and `ValidateConfig()` checks each of them: `0`')
    out.append('(`PERIOD_CURRENT`) is accepted and resolved to the chart period by the indicator')
    out.append('call itself, while any *other* value must be one of the real periods')
    out.append('(`PERIOD_M1..PERIOD_MN1`); a value outside that set is snapped to')
    out.append('`PERIOD_CURRENT` and reported as a `[CFG]` warning, because a handle created on a')
    out.append('meaningless timeframe would silently return no data and freeze the entry logic.')
    out.append('')
    enums = {}
    txt = TYPES.read_text()
    for em in re.finditer(r'enum\s+(ENUM_XAU_\w+)\s*\{([^}]*)\}', txt, re.S):
        name, bodytxt = em.group(1), em.group(2)
        members = []
        for line in bodytxt.splitlines():
            line = line.strip()
            if not line or line.startswith('//') or line.startswith('/*'):
                continue
            mm = re.match(r'([A-Z0-9_]+)\s*=\s*([^,]+?)\s*(?://\s*(.*))?$', line)
            if mm:
                members.append((mm.group(1), mm.group(2).strip(), (mm.group(3) or '').strip()))
        enums[name] = members
    for name, members in enums.items():
        used = [r['name'] for r in rows if r['type'] == name]
        out.append(f'### `{name}`')
        out.append('')
        out.append(f'Used by: ' + (', '.join(f'`{u}`' for u in used) if used else '_internal state only_'))
        out.append('')
        out.append('| Value | Numeric | Meaning |')
        out.append('|---|---|---|')
        for v, num, cmt in members:
            out.append(f'| `{v}` | {num} | {cmt or "-"} |')
        out.append('')
    out.append('---')
    out.append('')
    out.append('Next: [03 - State machine](03-state-machine.md)')
    out.append('')
    return '\n'.join(out) + '\n'


def main() -> int:
    rows = parse_inputs()
    cfg = parse_cconfig()
    names = {r['name'] for r in rows}
    missing = sorted(set(cfg) - names - {'emergency_stop', 'user_paused', 'override_flags'})
    extra = sorted(names - set(cfg))
    if missing:
        print(f"ERROR CConfig fields with no input: {missing}")
    if extra:
        print(f"ERROR inputs with no CConfig field: {extra}")
    text = render(rows, cfg)
    if '--check' in sys.argv:
        if DOC.exists() and DOC.read_text() == text:
            print(f"docs/02 is up to date ({len(rows)} inputs)")
            return 0 if not missing and not extra else 1
        print("docs/02 differs from the source - regenerate it")
        return 1
    DOC.parent.mkdir(exist_ok=True)
    DOC.write_text(text)
    print(f"wrote {DOC.relative_to(ROOT)} ({len(rows)} inputs, {len(cfg)} CConfig fields)")
    return 0 if not missing and not extra else 1


if __name__ == '__main__':
    sys.exit(main())
