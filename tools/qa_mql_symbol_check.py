#!/usr/bin/env python3
"""
qa_mql_symbol_check.py - mini front end for the XAU_AVG_PRO sources.

Because MetaEditor cannot run in this environment, this script performs the
checks a compiler would do first:

  * method call arity        : every obj.method(args) against the declaration
  * member existence         : every obj.field against the class/struct fields
  * unknown identifiers      : calls to methods that exist nowhere
  * parameter type shape     : reference/out parameters are passed as variables
  * struct field existence   : SVerdict.code etc.
It intentionally ignores MQL5 builtins (ObjectSet*, PositionGet*, ...) and the
standard library types.

Exit code 0 = clean, 1 = mismatches found.
"""
from __future__ import annotations
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EA_DIR = ROOT / "MQL5" / "Experts"
INC_DIR = ROOT / "MQL5" / "Include" / "XAU_AVG_PRO"

BUILTIN = {
    "void", "int", "uint", "long", "ulong", "short", "ushort", "char", "uchar",
    "float", "double", "bool", "string", "datetime", "color", "uchar", "size_t",
}
KEYWORDS = {"if", "for", "while", "switch", "return", "else", "do", "break", "continue",
            "new", "delete", "sizeof", "input", "class", "struct", "enum", "const",
            "public", "private", "protected", "this", "true", "false", "NULL", "Print",
            "static", "virtual", "override", "operator", "friend", "union", "namespace",
            "using", "try", "catch", "throw", "case", "default", "goto", "register",
            "explicit", "export", "import", "template", "typename", "typedef"}
# MQL5 runtime/library functions that are always available
MQL_API = set("""
Print PrintFormat Alert Comment PlotIndexGetInteger TimeCurrent TimeTradeServer TimeLocal TimeGMT
TimeToStruct StructToTime StringFormat StringLen StringSubstr StringFind StringSplit StringReplace
StringTrimLeft StringTrimRight StringToUpper StringToLower StringGetCharacter CharToStr StringAdd
ArraySize ArrayResize ArrayFree ArrayInitialize ArraySetAsSeries ArrayCopy ArrayMaximum ArrayMinimum
ArrayBands ArrayiMA ArraySetAsSeries RatesTotal iMA iATR iBands iCustom iClose iHigh iLow iOpen iTime
SymbolInfoDouble SymbolInfoInteger SymbolInfoString SymbolInfoTick SymbolPeriodDigitsDigitsDigits
AccountBalance AccountEquity AccountFreeMargin AccountInfoDouble AccountInfoInteger AccountInfoString
PositionsTotal PositionSelectByTicket PositionSelect PositionGetTicket PositionGetDouble PositionGetInteger
PositionGetString PositionClose PositionOpen OrdersTotal OrderSend OrderCheck OrderGetTicket OrderSelect
HistorySelect HistoryDealsTotal HistoryOrdersTotal HistoryDealGetDouble HistoryDealGetInteger HistoryDealGetString
HistoryOrderGetDouble HistoryOrderGetInteger HistoryOrderGetString MathMax MathMin MathPow MathAbs MathSqrt
MathFloor MathCeil MathRand MathRound NormalizeDouble DoubleToString IntegerToString TimeToString
StringToDouble StringToInteger ObjectCreate ObjectDelete ObjectsTotal ObjectFind ObjectSetInteger
ObjectSetString ObjectSetDouble ObjectGetString ObjectGetInteger ChartRedraw ChartID ChartGetString
ObjectsDeleteAll EventSetTimer EventKillTimer GetTickCount GetLastError ResetLastError Sleep
FileOpen FileClose FileWriteString FileReadString FileWrite FileSize FileFlush FileIsExist FileDelete
FileGetInteger FolderCreate TerminalInfoInteger TerminalInfoString TerminalInfoDouble
CalendarValueHistory CalendarEventById CalendarCountryById TimeGMTOffset PeriodSeconds
Digits Point Ask Bid Volume Time LocalTime MarketBookAdd SendTelegramRequest WebRequest
GlobalVariableSet GlobalVariableGet GlobalVariableCheck GlobalVariablesTotal
StringInit StringGetArray StringSetArray CharArrayToString StringToCharArray
ZeroMemory MemoryCompare StructToBytes BytesToStruct
MathIsValidNumber StringIsAlphanumeric StringIsValidCharacter
""".split())


def strip_all(src: str) -> str:
    """Blank out comments and string contents (keep positions)."""
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
            out.append(''.join(ch if ch == '\n' else ' ' for ch in src[i:j]))
            i = j
        elif c == '"':
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
            out.append("' '")
            i = j + 1
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def find_matching(txt: str, start: int, open_ch: str, close_ch: str) -> int:
    depth = 0
    i = start
    n = len(txt)
    while i < n:
        ch = txt[i]
        if ch == '"':
            i += 1
            while i < n and txt[i] != '"':
                if txt[i] == '\\':
                    i += 1
                i += 1
        elif ch == "'":
            i += 1
            while i < n and txt[i] != "'":
                if txt[i] == '\\':
                    i += 1
                i += 1
        elif ch == open_ch:
            depth += 1
        elif ch == close_ch:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def split_args(argstr: str) -> list[str]:
    if not argstr.strip() or argstr.strip() == "void":
        return []
    out, depth, cur = [], 0, ''
    for ch in argstr:
        if ch in '([':
            depth += 1
        elif ch in ')]':
            depth -= 1
        if ch == ',' and depth == 0:
            out.append(cur.strip())
            cur = ''
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


TYPE_RE = r'(?:const\s+)?([A-Za-z_]\w*)\s*\*?'


class ClassInfo:
    def __init__(self, name, kind):
        self.name = name
        self.kind = kind          # class | struct
        self.methods = {}         # name -> (nparams, is_const, raw_params)
        self.fields = {}          # name -> type
        self.order = []


def parse_types(clean: str, infos: dict[str, ClassInfo]):
    for m in re.finditer(r'\b(class|struct)\s+(\w+)', clean):
        kind, name = m.group(1), m.group(2)
        brace = clean.find('{', m.end())
        if brace < 0:
            continue
        end = find_matching(clean, brace, '{', '}')
        if end < 0:
            continue
        body = clean[brace + 1:end]
        info = infos.setdefault(name, ClassInfo(name, kind))
        # ---- methods: "ret name(params) [const] {" or ";", also "name(...) :"
        for mm in re.finditer(r'([A-Za-z_]\w*)\s*\(', body):
            mname = mm.group(1)
            if mname in KEYWORDS or mname in MQL_API:
                continue
            p_open = body.find('(', mm.end() - 1)
            p_close = find_matching(body, p_open, '(', ')')
            if p_close < 0:
                continue
            after = body[p_close + 1:p_close + 400]
            nxt = after.lstrip()
            is_ctor = mname == name or mname == '~' + name
            if not is_ctor:
                # require a preceding type token on the same logical line
                line_start = body.rfind('\n', 0, mm.start()) + 1
                prefix = body[line_start:mm.start()].strip()
                if not prefix or prefix in ('return', 'else') or not re.fullmatch(r'(?:const\s+)?[A-Za-z_]\w*\s*\*?', prefix):
                    continue
            # method definition or declaration only
            if not (nxt.startswith('{') or nxt.startswith(';') or nxt.startswith('const')):
                continue
            if nxt.startswith('const'):
                rest = nxt[5:].lstrip()
                if not (rest.startswith('{') or rest.startswith(';')):
                    continue
            params = body[p_open + 1:p_close]
            argc = len(split_args(params))
            plist = []
            for par in split_args(params):
                par = par.strip()
                if par == "void":
                    continue
                pm = re.match(r'(?:const\s+)?([A-Za-z_]\w*)\s*(\*?)\s*&?\s*([A-Za-z_]\w*)?\s*(?:\[[^\]]*\])?\s*(?:=[^\n]*)?$', par)
                if pm:
                    plist.append((pm.group(1), pm.group(3) or '', pm.group(2) == '*'))
                else:
                    plist.append(('?', par, False))
            info.methods[mname] = (argc, nxt.startswith('const'), params, plist)
        # ---- fields: type name;  (only lines that are not inside a method body)
        depth = 0
        for line in body.split('\n'):
            ls = line.strip()
            if ls.count('{') > ls.count('}'):
                depth += 1
                continue
            if depth > 0:
                depth = max(0, depth - ls.count('}') + ls.count('{'))
                continue
            if ls.endswith(';') and '(' not in ls and '=' not in ls.split(';')[0].split('[')[0]:
                fm = re.fullmatch(r'(?:static\s+)?(?:const\s+)?[A-Za-z_]\w*\s*\*?\s+([A-Za-z_]\w*)\s*(?:\[[^\]]*\])?\s*;', ls)
                if fm and fm.group(1) not in BUILTIN:
                    tm = re.match(r'(?:static\s+)?(?:const\s+)?([A-Za-z_]\w*)', ls)
                    info.fields[fm.group(1)] = tm.group(1) if tm else '?'
            elif ls.endswith(';') and '=' in ls:
                fm = re.fullmatch(r'(?:static\s+)?(?:const\s+)?[A-Za-z_]\w*\s*\*?\s+([A-Za-z_]\w*)\s*(?:\[[^\]]*\])?\s*=[^;]*;', ls)
                if fm:
                    tm = re.match(r'(?:static\s+)?(?:const\s+)?([A-Za-z_]\w*)', ls)
                    info.fields[fm.group(1)] = tm.group(1) if tm else '?'


def build_var_map(clean: str, infos: dict[str, ClassInfo]) -> dict[str, str]:
    """variable name -> type name for object/struct instances and pointers."""
    vars_ = {}
    for m in re.finditer(r'(?:^|[;{}\n])\s*((?:input|extern|static)\s+)?([A-Z]\w*)\s*(\*?)\s*([a-zA-Z_]\w*)\s*(?:\[[^\]]*\])?\s*(?:=|;|\()', clean):
        tname = m.group(2)
        vname = m.group(4)
        if tname in KEYWORDS or tname in BUILTIN:
            continue
        if tname not in infos:
            continue
        vars_[vname] = tname
    return vars_


def main() -> int:
    files = sorted(EA_DIR.glob("*.mq5")) + sorted(INC_DIR.glob("*.mqh"))
    raw = {f: f.read_text(encoding="utf-8") for f in files}
    clean = {f: strip_all(raw[f]) for f in files}

    infos: dict[str, ClassInfo] = {}
    for f in files:
        parse_types(clean[f], infos)
    known_types = set(infos)

    # collect vars globally (a var declared in the .mq5 is visible in the .mq5 only,
    # but module members are per file; we merge per file plus a global view)
    vars_by_file = {f: build_var_map(clean[f], infos) for f in files}
    gvars: dict[str, str] = {}
    # explicit module globals from the EA file
    ea = EA_DIR / "XAU_AVG_PRO.mq5"
    if ea in clean:
        for m in re.finditer(r'^\s*([A-Z]\w*)\s+(g_\w+)\s*[;=]', clean[ea], re.M):
            if m.group(1) in infos:
                gvars[m.group(2)] = m.group(1)

    problems: list[str] = []
    checked_calls = 0
    checked_fields = 0

    for f in files:
        c = clean[f]
        # a method body of class K: know the enclosing class to resolve m_x members
        for m in re.finditer(r'\b([a-zA-Z_]\w*)\s*(\.|->)\s*([a-zA-Z_]\w*)\s*(\()?', c):
            var, sep, name, is_call = m.group(1), m.group(2), m.group(3), bool(m.group(4))
            if var in KEYWORDS or var in MQL_API:
                continue
            tname = vars_by_file[f].get(var) or gvars.get(var)
            if tname is None:
                # member of the enclosing class? find nearest "class K" before m.start()
                cls = None
                for cm in re.finditer(r'\bclass\s+(\w+)', c):
                    if cm.start() < m.start():
                        cls = cm.group(1)
                    else:
                        break
                if cls:
                    # member variable declared in that class?
                    finfo = infos.get(cls)
                    if finfo and name in finfo.fields and not is_call:
                        continue
                    mv = re.match(r'm_(\w+)', var)
                    if mv and finfo:
                        pass
                    tname = None
                    for fname, ftype in (finfo.fields.items() if finfo else []):
                        if fname == var:
                            tname = ftype
                            break
                    if tname is None:
                        continue
            if tname not in infos:
                continue
            info = infos[tname]
            if is_call:
                p_open = c.find('(', m.end() - 1)
                p_close = find_matching(c, p_open, '(', ')')
                if p_close < 0:
                    continue
                nargs = len(split_args(c[p_open + 1:p_close]))
                checked_calls += 1
                if name in info.methods:
                    decl = info.methods[name]
                    line = c[:m.start()].count("\n") + 1
                    if nargs != decl[0]:
                        problems.append(f"{f.name}:{line}: {var}.{name}( ) called with {nargs} args, "
                                        f"{tname} declares {decl[0]} ({decl[2][:70]})")
                    else:
                        arg_txt = c[p_open + 1:p_close]
                        args = split_args(arg_txt)
                        for idx, (arg, pdecl) in enumerate(zip(args, decl[3])):
                            ptype = pdecl[0]
                            # reference/out parameter must receive a variable
                            is_ref = '&' in arg_txt or re.search(r'(?:const\s+)?[A-Za-z_]\w*\s*\*?\s*&\s*\w+', pdecl[1] if pdecl[1] else '')
                            a = arg.strip()
                            a_type = None
                            gp = re.fullmatch(r'GetPointer\s*\(\s*([A-Za-z_]\w*)\s*\)', a)
                            if gp:
                                a = gp.group(1)
                            if re.fullmatch(r'[A-Za-z_]\w*', a):
                                a_type = vars_by_file[f].get(a) or gvars.get(a)
                            elif re.fullmatch(r'-?\d+\.?\w*[fF]?', a):
                                a_type = 'number'
                            elif a.startswith('"'):
                                a_type = 'string'
                            elif a in ('true', 'false'):
                                a_type = 'bool'
                            elif re.fullmatch(r'[A-Za-z_]\w*\s*\(', a):
                                a_type = None
                            if ptype in infos and a_type and a_type != 'number' and ptype != a_type and a_type in infos:
                                problems.append(f"{f.name}:{line}: {var}.{name}( ) arg#{idx + 1} is {a_type} "
                                                f"({a}), {tname} expects {ptype}")
                            if ptype in ('double', 'float', 'int', 'long', 'uint', 'ulong', 'short', 'bool') and a.startswith('"'):
                                problems.append(f"{f.name}:{line}: {var}.{name}( ) arg#{idx + 1} passes a string where {ptype} is expected")
                            if ptype == 'string' and re.fullmatch(r'-?\d+\.?\w*', a or '0'):
                                problems.append(f"{f.name}:{line}: {var}.{name}( ) arg#{idx + 1} passes a number where string is expected")
                elif name in MQL_API:
                    pass
                else:
                    line = c[:m.start()].count("\n") + 1
                    problems.append(f"{f.name}:{line}: {var}.{name}( ) does not exist in {tname}")
            else:
                checked_fields += 1
                if info.fields and name not in info.fields and name not in info.methods:
                    line = c[:m.start()].count("\n") + 1
                    problems.append(f"{f.name}:{line}: {tname} has no field '{name}' (used as {var}.{name})")

    print("=" * 72)
    print("XAU_AVG_PRO symbol / arity check")
    print("=" * 72)
    print(f"  types parsed        : {len(known_types)}")
    print(f"  module globals      : {len(gvars)}")
    print(f"  calls resolved      : {checked_calls}")
    print(f"  field accesses      : {checked_fields}")
    for t in sorted(infos):
        i = infos[t]
        print(f"  {t:16s} methods={len(i.methods):3d} fields={len(i.fields):3d}")
    print("-" * 72)
    if problems:
        print(f"MISMATCHES ({len(problems)}):")
        for p in sorted(set(problems)):
            print("  ! " + p)
        return 1
    print("no signature or member mismatches")
    return 0


if __name__ == "__main__":
    sys.exit(main())
