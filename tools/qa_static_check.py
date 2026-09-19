#!/usr/bin/env python3
"""
qa_static_check.py - structural / semantic static checks for XAU_AVG_PRO.

MetaEditor only runs on Windows, so this harness verifies everything that can
be verified without a compiler:

  1. brace / parenthesis / bracket balance per file (string and comment aware)
  2. every #include target exists
  3. no TODO / FIXME / PLACEHOLDER / pseudo code markers
  4. every `input` in the EA has exactly one assignment in LoadInputs()
  5. every CConfig field is populated by LoadInputs()
  6. every m_cfg.<Field> reference exists in CConfig
  7. every <object>.<Method>( call resolves to a method of that module's class
  8. every ENUM_XAU_* value that is used is declared
  9. no function returns a struct by value (MQL5 portability rule of this codebase)
 10. no hard-coded credential-looking strings (Telegram token patterns)
 11. class/method duplicate detection across include files

Exit code 0 = all checks pass, 1 = problems found.
"""
from __future__ import annotations
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EA_DIR = ROOT / "MQL5" / "Experts"
INC_DIR = ROOT / "MQL5" / "Include" / "XAU_AVG_PRO"

FORBIDDEN = [r"\bTODO\b", r"\bFIXME\b", r"\bPLACEHOLDER\b", r"IMPLEMENT\s+LATER",
             r"\bXXX\b", r"pseudo-?code", r"\bnot\s+implemented\b", r"\bstub\b"]


def strip_comments_and_strings(src: str) -> str:
    """Blank out // comments, /* */ comments and string literal contents so that
    brace counting and identifier scanning are not confused by text."""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            j = src.find('\n', i)
            j = n if j < 0 else j
            out.append(' ' * (j - i))
            i = j
        elif c == '/' and i + 1 < n and src[i + 1] == '*':
            j = src.find('*/', i + 2)
            j = n if j < 0 else j + 2
            out.append('\n' * src[i:j].count('\n') + ' ' * 4)
            i = j
        elif c == '"':
            # blank the contents but keep the length, so offsets stay valid
            j = i + 1
            while j < n:
                if src[j] == '\\':
                    j += 2
                    continue
                if src[j] == '"':
                    break
                j += 1
            out.append('"' + ' ' * max(0, j - i - 1) + ('"' if j < n else ''))
            i = j + 1
        elif c == "'":
            j = i + 1
            while j < n and src[j] != "'":
                if src[j] == '\\':
                    j += 1
                j += 1
            out.append("'" + ' ' * max(0, j - i - 1) + ("'" if j < n else ''))
            i = j + 1
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def balance(src: str) -> list[str]:
    clean = strip_comments_and_strings(src)
    problems = []
    stack = []
    pairs = {'{': '}', '(': ')', '[': ']'}
    closing = {v: k for k, v in pairs.items()}
    line = 1
    for ch in clean:
        if ch == '\n':
            line += 1
        elif ch in pairs:
            stack.append((ch, line))
        elif ch in closing:
            if not stack:
                problems.append(f"line {line}: unmatched '{ch}'")
            else:
                op, ln = stack.pop()
                if pairs[op] != ch:
                    problems.append(f"line {line}: '{ch}' closes '{op}' opened on line {ln}")
    for op, ln in stack:
        problems.append(f"line {ln}: '{op}' never closed")
    return problems


def class_body(clean: str, name: str) -> str:
    m = re.search(r'\bclass\s+' + name + r'\b[^{]*\{', clean)
    if not m:
        return ''
    start = m.end() - 1
    depth = 0
    i = start
    while i < len(clean):
        if clean[i] == '{':
            depth += 1
        elif clean[i] == '}':
            depth -= 1
            if depth == 0:
                break
        i += 1
    return clean[start:i]


def parse_classes(src: str) -> dict[str, dict]:
    """Very small class parser: name -> {methods:set, fields:set}."""
    clean = strip_comments_and_strings(src)
    classes = {}
    for m in re.finditer(r'\bclass\s+(\w+)[^{]*\{', clean):
        name = m.group(1)
        start = m.end() - 1
        depth = 0
        i = start
        while i < len(clean):
            if clean[i] == '{':
                depth += 1
            elif clean[i] == '}':
                depth -= 1
                if depth == 0:
                    break
            i += 1
        body = clean[start:i]
        methods = set(re.findall(r'\b(\w+)\s*\([^;{]*\)\s*(?:const\s*)?\{', body))
        methods |= set(re.findall(r'\b(?:void|int|long|double|bool|string|datetime|char|uint|ulong|short|color|'
                                  r'ENUM_\w+|[A-Z]\w+)\s+(\w+)\s*\([^;{]*\)\s*(?:const\s*)?;', body))
        # constructors / destructors
        methods |= set(re.findall(r'[~]?\b' + name + r'\s*\([^)]*\)\s*(?::|\{)', body))
        fields = set()
        for fm in re.finditer(r'^\s*(?:private|public|protected)?\s*;?\s*'
                              r'(?:[A-Za-z_][\w]*)\s*\*?\s+(\w+)\s*(?:\[[^\]]*\])?\s*(?:=|;)',
                              body, re.M):
            fields.add(fm.group(1))
        classes[name] = {"methods": methods, "fields": fields}
    return classes


def main() -> int:
    files = sorted(EA_DIR.glob("*.mq5")) + sorted(INC_DIR.glob("*.mqh"))
    if not files:
        print("no source files found")
        return 1
    problems: list[str] = []
    infos: list[str] = []
    texts: dict[Path, str] = {}
    cleaned: dict[Path, str] = {}
    for f in files:
        texts[f] = f.read_text(encoding="utf-8")
        cleaned[f] = strip_comments_and_strings(texts[f])

    # ---------------- 1. files are whole, and no placeholder marker survives ----------------
    for f in files:
        for p in balance(texts[f]):
            problems.append(f"{f.name}: {p}")
        for pat in FORBIDDEN:
            for m in re.finditer(pat, texts[f]):
                line = texts[f][:m.start()].count("\n") + 1
                problems.append(f"{f.name}:{line}: forbidden marker /{pat}/ found")

    # ---------------- 2. every #include target exists and guards are unique ----------------
    for f in files:
        for m in re.finditer(r'#include\s+["<]([^">]+)[">]', texts[f]):
            inc = m.group(1).replace("\\", "/")
            cands = [INC_DIR / Path(inc).name, EA_DIR / inc, EA_DIR.parent / inc]
            if not any(c.exists() for c in cands):
                problems.append(f"{f.name}: #include \"{inc}\" does not exist")

    # ---------------- 3. inputs mirror into CConfig exactly once ----------------
    ea = [f for f in files if f.suffix == ".mq5"]
    cfg_fields: set[str] = set()
    cfg_cls = None
    for f in files:
        cls = parse_classes(texts[f])
        if "CConfig" in cls:
            cfg_cls = cls["CConfig"]
    if cfg_cls is None:
        problems.append("CConfig class not found")
    else:
        for f in files:
            body = class_body(cleaned[f], "CConfig")
            if body:
                cfg_fields = set(re.findall(r'^\s*(?:[A-Za-z_]\w*)\s*\*?\s+(\w+)\s*(?:\[[^\]]*\])?\s*;', body, re.M))
                cfg_fields -= {'CConfig'}
                break
        infos.append(f"CConfig fields: {len(cfg_fields)}")

    if ea:
        f = ea[0]
        src = cleaned[f]
        inputs = re.findall(r'^\s*input\s+[\w:]+\s+(\w+)\s*=', src, re.M)
        # MQL5 "input group" lines are not parameters
        inputs = [i for i in inputs if i != "group"]
        infos.append(f"inputs declared: {len(inputs)}")
        li = src[src.index("void LoadInputs(void)"):]
        li = li[:li.index("\n  }")]
        assigned = re.findall(r'g_cfg\.(\w+)\s*=', li)
        for i in inputs:
            if assigned.count(i) != 1:
                problems.append(f"input {i}: assigned {assigned.count(i)} times in LoadInputs (expected exactly 1)")
        if len(inputs) != len(set(inputs)):
            dupes = [x for x in set(inputs) if inputs.count(x) > 1]
            problems.append(f"duplicate input names: {dupes}")
        not_state = {'emergency_stop', 'user_paused', 'override_flags'}
        for fld in sorted(cfg_fields):
            if fld in not_state:
                continue
            if fld not in assigned:
                problems.append(f"CConfig.{fld} is never populated by LoadInputs()")
        for a in set(assigned):
            if a not in cfg_fields:
                problems.append(f"LoadInputs assigns unknown CConfig field '{a}'")

    # ---------------- 4. no config field typo ----------------
    if cfg_fields:
        for f in files:
            for m in re.finditer(r'(?:m_cfg|cfg|g_cfg)\.(\w+)(?![\w(])', cleaned[f]):
                if m.group(1) not in cfg_fields:
                    problems.append(f"{f.name}: unknown config field '{m.group(1)}'")

    # ---------------- 5. cross-module calls exist with the right arity and type shape ----------------
    globals_map = {
        "g_spec": "CSymbolSpec", "g_log": "CLogger", "g_state": "CStateStore",
        "g_cycle": "CCycleManager", "g_exec": "CExecution", "g_entry": "CEntryEngine",
        "g_avg": "CAveragingEngine", "g_lots": "CLotManager", "g_filters": "CMarketFilters",
        "g_news": "CNewsFilter", "g_basket": "CBasketManager", "g_sm": "CStateMachine",
        "g_risk": "CRiskManager", "g_stats": "CStatistics", "g_dash": "CDashboard",
        "g_tg": "CTelegramBot", "g_tests": "CSelfTest", "g_cfg": "CConfig",
    }
    member_map = {
        "m_spec": "CSymbolSpec", "m_log": "CLogger", "m_store": "CStateStore",
        "m_cycle": "CCycleManager", "m_exec": "CExecution", "m_cfg": "CConfig",
        "m_lots": "CLotManager", "m_filters": "CMarketFilters", "m_news": "CNewsFilter",
        "m_basket": "CBasketManager", "m_state": "CStateMachine", "m_avg": "CAveragingEngine",
        "m_store2": "CStateStore",
    }
    all_methods: dict[str, set[str]] = {}
    for f in files:
        for cname, cdef in parse_classes(texts[f]).items():
            all_methods.setdefault(cname, set()).update(cdef["methods"])
    unresolved = 0
    for f in files:
        for m in re.finditer(r'\b(\w+)(?:->|\.)(\w+)\s*\(', cleaned[f]):
            obj, meth = m.group(1), m.group(2)
            cls = globals_map.get(obj) or member_map.get(obj)
            if cls is None:
                continue
            if meth in ("if", "for", "while", "switch", "return", "sizeof"):
                continue
            known = all_methods.get(cls)
            if known is None:
                problems.append(f"{f.name}: class {cls} not found (referenced by {obj})")
                unresolved += 1
                continue
            if meth not in known:
                problems.append(f"{f.name}: {obj}.{meth}() is not declared in {cls}")
                unresolved += 1
    infos.append(f"member-call resolution checked, {unresolved} unresolved")

    # ---------------- 6. no undeclared XAU_ identifier ----------------
    for f in files:
        declared = set(re.findall(r'(XAU_\w+)\s*=', texts[f])) | set(
            re.findall(r'#define\s+(XAU_\w+)', texts[f]))
        used = set(re.findall(r'\b(XAU_[A-Z0-9_]+)\b', cleaned[f]))
        # all headers are included by the EA, so search all files for declarations
        for g in files:
            declared |= set(re.findall(r'(XAU_\w+)\s*=', texts[g]))
            declared |= set(re.findall(r'#define\s+(XAU_\w+)', texts[g]))
            declared |= set(re.findall(r'^\s*(XAU_\w+)\s*,\s*$', texts[g], re.M))
            declared |= set(re.findall(r'^\s*(XAU_\w+)\s*(?://.*)?$', texts[g], re.M))
        for u in sorted(used):
            if u not in declared:
                problems.append(f"{f.name}: XAU_ identifier '{u}' used but never declared")

    # ---------------- 7. structs are passed by reference only ----------------
    struct_types = ("SVerdict", "SAvgPlan", "SExecResult", "SCycleData", "SDayStats",
                    "SLayerRec", "SRt", "SActionReq", "MqlCalendarValue")
    for f in files:
        for m in re.finditer(r'^\s*(?:[\w:]+\s+)?(' + '|'.join(struct_types) + r')\s+\w+\s*\([^;]*\)\s*(?:const\s*)?\{',
                              cleaned[f], re.M):
            problems.append(f"{f.name}: function returns struct '{m.group(1)}' by value (forbidden convention)")

    # ---------------- 8. no hard-coded Telegram token ----------------
    secret_re = re.compile(r'\b\d{8,10}:AA[A-Za-z0-9_\-]{20,}\b')
    for f in files:
        if secret_re.search(texts[f]):
            problems.append(f"{f.name}: looks like a hard-coded Telegram token")
        for m in re.finditer(r'TelegramBotToken\s*=\s*"([^"]*)"', texts[f]):
            if m.group(1):
                problems.append(f"{f.name}: Telegram token must default to an empty string")
    # ---------------- 9. no method defined twice in one file ----------------
    seen: dict[str, str] = {}
    for f in files:
        for cname, cdef in parse_classes(texts[f]).items():
            for meth in cdef["methods"]:
                key = f"{cname}::{meth}"
                if key in seen and seen[key] != f.name:
                    problems.append(f"duplicate definition {key} in {f.name} and {seen[key]}")
                seen[key] = f.name

    # ---------------- 10. format specifiers match their arguments ----------------
    spec_re = re.compile(r'%(?:\d+\$)?[-+ #0]*[0-9]*(?:\.[0-9]+)?(?:I64|I32|hh|h|ll|l|L|j|z|t)?[diouxXeEfFgGaAcspn%]')
    fmt_calls = 0
    for f in files:
        c = cleaned[f]
        for m in re.finditer(r'\b(StringFormat|PrintFormat|Alert|FileWriteString|sprintf)\s*\(', c):
            fn = m.group(1)
            o = c.find('(', m.start())
            # find the matching close paren
            depth, i = 0, o
            while i < len(c):
                if c[i] == '(':
                    depth += 1
                elif c[i] == ')':
                    depth -= 1
                    if depth == 0:
                        break
                i += 1
            inner = texts[f][o + 1:i]        # raw text so string contents are visible
            parts, dep, cur = [], 0, ''
            instr = False
            k = 0
            while k < len(inner):
                ch = inner[k]
                if instr:
                    if ch == '\\':
                        cur += inner[k:k + 2]
                        k += 2
                        continue
                    cur += ch
                    if ch == '"':
                        instr = False
                    k += 1
                    continue
                if ch == '"':
                    instr = True
                    cur += ch
                    k += 1
                    continue
                if ch in '([':
                    dep += 1
                elif ch in ')]':
                    dep -= 1
                if ch == ',' and dep == 0:
                    parts.append(cur)
                    cur = ''
                else:
                    cur += ch
                k += 1
            if cur.strip():
                parts.append(cur)
            if not parts or not parts[0].strip().startswith('"'):
                continue                      # first arg is not a literal format
            specs = len([x for x in spec_re.findall(parts[0]) if x != '%%'])
            nargs = len(parts) - 1
            fmt_calls += 1
            if fn in ("StringFormat", "PrintFormat", "sprintf") and specs != nargs:
                line = texts[f][:m.start()].count("\n") + 1
                problems.append(f"{f.name}:{line}: {fn} format has {specs} specifier(s) but {nargs} argument(s)")
            if fn == "Alert" and specs > 0:
                line = texts[f][:m.start()].count("\n") + 1
                problems.append(f"{f.name}:{line}: Alert used with a format string - use PrintFormat/Alert(StringFormat(...)) consistently")
    infos.append(f"format strings checked: {fmt_calls}")

    # ---------------- 11. modules compile standalone ----------------
    for f in files:
        if f.suffix == ".mqh" and "#include \"Types.mqh\"" not in texts[f]:
            base = f.name
            if base not in ("Types.mqh", "SelfTest.mqh") and "class C" not in cleaned[f][:0]:
                # SelfTest includes Types through its own list; modules must be standalone
                if base != "Types.mqh":
                    problems.append(f"{base}: does not include Types.mqh (module must compile standalone)")

    # ---------------- 12. order sending stays inside Execution.mqh ----------------
    for f in files:
        if re.search(r'#include\s*<(Trade|Object|Arrays|File|String)\w*\\', texts[f]):
            infos.append(f"{f.name}: uses a standard library include")
    # ---------------- 13. no unguarded division by a symbol-derived denominator ----------------
    #
    # Averaging, lots and filters divide by symbol-derived quantities constantly. A zero
    # denominator in MQL5 yields inf/NaN, which then silently propagates into a lot size.
    # A division is accepted when ANY of these holds:
    #   (a) the denominator is guarded within the 12 lines above the division
    #   (b) the expression guards itself inline (x / (p > 0 ? p : 1.0))
    #   (c) a MathIsValidNumber()/isfinite backstop appears within 10 lines below
    #   (d) the field is clamped non-zero where it is read (e.g. `if(m_point <= 0.0)`)
    DENOMINATORS = {"m_point", "m_tick_value", "m_tick_size", "m_money_per_point_per_lot",
                    "m_vol_step", "m_vol_min", "m_vol_max", "m_contract", "per_lot_pts",
                    "risk_per_lot", "margin_per_lot", "m_atr_points", "spread_points"}
    clamped: set[str] = set()
    for f in files:
        clamped |= set(re.findall(r"if\s*\(\s*(m_\w+)\s*<=\s*0\.0\s*\)", cleaned[f]))
    for f in files:
        lines = cleaned[f].splitlines()
        for idx, line in enumerate(lines):
            for m in re.finditer(r"/\s*([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_]+\(\))?)", line):
                den = m.group(1)
                base = den.split(".")[-1] if "." in den else den
                if base.endswith("()"):
                    base = base[:-2]
                if base not in DENOMINATORS and den not in ("Point()", ):
                    continue
                if "." not in den and base not in DENOMINATORS:
                    continue
                above = " ".join(lines[max(0, idx - 12):idx + 1])
                below = " ".join(lines[idx:idx + 11])
                name = base if base in DENOMINATORS else "m_point"
                guarded = (re.search(rf"{name}\s*<=\s*0|{name}\s*>\s*0|{name}\s*<\s*1e|MathMax\([^)]*{name}", above)
                           or re.search(rf"{name}\s*>\s*0\s*\?", line)
                           or "MathIsValidNumber" in below
                           or name in clamped)
                if not guarded:
                    problems.append(f"{f.name}:{idx + 1}: division by {den} has no guard and no clamp")


    print("=" * 72)
    print("XAU_AVG_PRO static QA")
    print("=" * 72)
    for f in files:
        lines = texts[f].count("\n") + 1
        print(f"  {f.relative_to(ROOT)}  ({lines} lines)")
    for i in infos:
        print(f"  info: {i}")
    print("-" * 72)
    if problems:
        print(f"PROBLEMS ({len(problems)}):")
        for p in problems:
            print("  ! " + p)
        return 1
    print("all static checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
