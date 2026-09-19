#!/usr/bin/env python3
"""Documentation-vs-code consistency gate.

Every quantitative claim in the documentation is recomputed from the tree here and
required to appear, verbatim, in the file that states it. Numbers drift the moment
someone adds an input or an assertion, and a stale "17 groups" in a README is the kind
of small lie that makes a reader distrust the whole document set.

Run: python3 tools/qa_doc_claims.py
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INC = ROOT / "MQL5" / "Include" / "XAU_AVG_PRO"
EA = ROOT / "MQL5" / "Experts" / "XAU_AVG_PRO.mq5"
MODULES = sorted(INC.glob("*.mqh")) + [EA]


def norm(text: str) -> str:
    """Canonical form for comparing a claim against prose.

    Documentation writes numbers with a thin/non-breaking thousands separator ("9 607")
    and uses markdown emphasis, so an exact substring test would fail on formatting
    alone. Normalise both sides the same way and compare meaning, not typography.
    """
    text = text.replace("\u00a0", " ").replace("**", "").replace("`", "").replace(":", " ")
    text = re.sub(r"(?<=\d)[ \t](?=\d{3}(?:\D|$))", "", text)   # 9 607 -> 9607
    text = re.sub(r"(?<=\d),(?=\d{3}(?:\D|$))", "", text)
    return re.sub(r"\s+", " ", text).lower()


def count(path: Path, pattern: str) -> int:
    rx = re.compile(pattern)
    return sum(len(rx.findall(p.read_text(encoding="utf-8"))) for p in path
               if p.suffix in (".mq5", ".mqh")) if path.is_dir() else len(rx.findall(path.read_text(encoding="utf-8")))


def config_fields() -> tuple[list[str], list[str]]:
    """(CConfig field names, input names copied into it) - both parsed from source."""
    types = (ROOT / "MQL5" / "Include" / "XAU_AVG_PRO" / "Types.mqh").read_text(encoding="utf-8").splitlines()
    start = [i for i, l in enumerate(types) if l.startswith("class CConfig")][0]
    end = [i for i, l in enumerate(types[start:], start) if l.strip() == "};"][0]
    fields: list[str] = []
    for line in types[start:end]:
        stmt = line.split("//")[0].strip()
        if not stmt.endswith(";") or "(" in stmt:
            continue
        m = re.match(r"^(?:const\s+)?([A-Za-z_]\w*)\s+([A-Za-z_]\w*)\s*;$", stmt)
        if m:
            fields.append(m.group(2))

    lines = EA.read_text(encoding="utf-8").splitlines()
    i = [n for n, l in enumerate(lines) if l.startswith("void LoadInputs(void)")][-1]
    body = []
    for line in lines[i + 1:]:
        if line.strip() == "}":
            break
        body.append(line)
    assigned = re.findall(r"g_cfg\.(\w+)\s*=", "\n".join(body))
    return fields, sorted(set(assigned))


def enum_members() -> dict[str, tuple[list[str], int]]:
    """name -> (members, lines spanned) for every enum in Types.mqh."""
    text = (INC / "Types.mqh").read_text(encoding="utf-8")
    out: dict[str, tuple[list[str], int]] = {}
    for m in re.finditer(r"enum\s+(\w+)[^\{]*\{(.*?)\n\}", text, re.S):
        decl = m.group(2)
        members = re.findall(r"\b([A-Z][A-Z0-9_]{2,})\s*(?:=|,|$)", decl)
        span = decl.count("\n") + 1
        out[m.group(1)] = (members, span)
    return out


def telegram_whitelist() -> list[str]:
    tg = (INC / "Telegram.mqh").read_text(encoding="utf-8")
    m = re.search(r"string allowed\[\] = \{(.*?)\};", tg, re.S)
    if not m:
        raise SystemExit("cannot find the Telegram whitelist in Telegram.mqh")
    return sorted(set(re.findall(r'"(\w+)"', m.group(1))))


def stats() -> dict[str, int]:
    ea_src = EA.read_text(encoding="utf-8")
    src = "\n".join(p.read_text(encoding="utf-8") for p in MODULES)
    self_test = (INC / "SelfTest.mqh").read_text(encoding="utf-8")
    fields, assigned = config_fields()
    inputs = set(re.findall(r"^input\s+\S+\s+(\w+)\s*=", ea_src, re.M))
    blk = set(re.findall(r"\b(XAU_BLK_\w+)\b", src))
    return {
        "files": len(MODULES),
        "lines": sum(len(p.read_text(encoding="utf-8").splitlines()) for p in MODULES),
        "inputs": len(inputs),
        "groups": len(re.findall(r"^input group ", ea_src, re.M)),
        "fields": len(fields),
        "unwired_inputs": len(inputs - set(assigned)),
        "reasons": len(blk - {"XAU_BLK_NONE"}),
        "states": len(set(re.findall(r"^\s+(XAU_ST_\w+)\s*=", src, re.M))),
        "commands": len(telegram_whitelist()),
        "assertions": len(re.findall(r"\bCheck\(", self_test)) - 1,   # minus the declaration
        "skips": len(re.findall(r"\bSkip\(", self_test)),
        "format": len(re.findall(r"\bStringFormat\(", src)) + len(re.findall(r"\bPrintFormat\(", src)),
        "rows": len(re.findall(r"g_dash\.Add\(", ea_src)),
        "selftest_lines": len(self_test.splitlines()),
    }


def dead_enum_members() -> dict[str, list[str]]:
    """Members that appear only inside their own enum declaration = dead code."""
    text = (INC / "Types.mqh").read_text(encoding="utf-8")
    whole = "\n".join(p.read_text(encoding="utf-8") for p in MODULES)
    dead: dict[str, list[str]] = {}
    for name, (members, _span) in enum_members().items():
        unused = [m for m in members if len(re.findall(rf"\b{m}\b", whole)) <= 1]
        if unused:
            dead[name] = unused
    return dead


def qa_families() -> int:
    """How many check families `qa_static_check.py` declares, from its section banners."""
    text = (ROOT / "tools" / "qa_static_check.py").read_text(encoding="utf-8")
    return len(re.findall(r"^\s*# -{4,}\s*\d+\.", text, re.M))


def docs_stats() -> dict[str, int]:
    """How many documentation pages exist. The *line* total is deliberately not
    tracked: it changes with every prose edit, so quoting it in a document would be
    a number that is stale by construction."""
    return {"doc_files": len(list((ROOT / "docs").glob("*.md")))}


def evidence_counts() -> dict[str, int]:
    """`calls resolved` / `field accesses` from a run of qa_mql_symbol_check.py.

    Those two numbers are properties of the checker, not of the tree, so they cannot be
    recomputed here without duplicating it. Instead the chain hands over the captured
    log; if it is absent the claims are skipped and that is printed, not hidden.
    """
    path = None
    for i, a in enumerate(sys.argv):
        if a == "--evidence" and i + 1 < len(sys.argv):
            path = Path(sys.argv[i + 1])
    if path is None or not path.exists():
        return {}
    text = path.read_text(encoding="utf-8")
    out: dict[str, int] = {}
    for key, label in (("calls", "calls resolved"), ("fields", "field accesses")):
        m = re.search(rf"{label}\s*:\s*([0-9]+)", text)
        if m:
            out[key] = int(m.group(1))
    return out


def main() -> int:
    s = stats() | docs_stats() | {"families": qa_families()}
    ev = evidence_counts()
    files = {
        "README.md": ROOT / "README.md",
        "CHANGELOG.md": ROOT / "CHANGELOG.md",
        "docs/01-architecture.md": ROOT / "docs" / "01-architecture.md",
        "docs/07-telegram-command-spec.md": ROOT / "docs" / "07-telegram-command-spec.md",
        "docs/08-testing-strategy.md": ROOT / "docs" / "08-testing-strategy.md",
        "docs/13-code-audit.md": ROOT / "docs" / "13-code-audit.md",
    }
    lines = {k: [norm(l) for l in v.read_text(encoding="utf-8").splitlines()] for k, v in files.items()}

    # (file, computed value, words that must sit on the same line as that value)
    claims = [
        ("README.md", s["inputs"], ["inputs"]),
        ("README.md", s["reasons"], ["block reasons"]),
        ("README.md", s["states"], ["derived states"]),
        ("README.md", s["commands"], ["whitelisted"]),
        ("README.md", s["rows"], ["rows"]),
        ("README.md", s["assertions"], ["assertions"]),
        ("CHANGELOG.md", s["inputs"], ["inputs", "groups"]),
        ("CHANGELOG.md", s["assertions"], ["assertions"]),
        ("CHANGELOG.md", s["commands"], ["whitelisted"]),
        ("CHANGELOG.md", s["format"], ["format strings"]),
        ("docs/01-architecture.md", s["files"], ["source files"]),
        ("docs/01-architecture.md", s["lines"], ["lines"]),
        ("docs/08-testing-strategy.md", s["assertions"], ["assertions"]),
        ("docs/08-testing-strategy.md", s["skips"], ["skips"]),
        ("docs/13-code-audit.md", s["inputs"], ["inputs"]),
        ("docs/13-code-audit.md", s["reasons"], ["block reasons"]),
        ("docs/13-code-audit.md", s["lines"], ["lines"]),
        ("docs/13-code-audit.md", s["fields"], ["fields"]),
        ("docs/13-code-audit.md", s["states"], ["states"]),
        ("docs/13-code-audit.md", s["commands"], ["telegram commands"]),
        ("docs/13-code-audit.md", s["rows"], ["dashboard rows"]),
        ("docs/13-code-audit.md", s["groups"], ["groups"]),
        ("docs/13-code-audit.md", s["format"], ["format strings"]),
        ("docs/13-code-audit.md", s["doc_files"], ["documentation"]),
        ("docs/08-testing-strategy.md", s["families"], ["check families"]),
        ("CHANGELOG.md", s["families"], ["check families"]),
    ]
    if "calls" in ev:
        claims.append(("docs/08-testing-strategy.md", ev["calls"], ["call sites"]))
        claims.append(("docs/13-code-audit.md", ev["calls"], ["cross-module calls"]))
    if "fields" in ev:
        claims.append(("docs/13-code-audit.md", ev["fields"], ["member-field accesses"]))
    if not ev:
        print("  info no --evidence log given: the symbol-checker counts are not cross-checked")

    failed: list[str] = []
    for where, value, keywords in claims:
        needle = norm(f"{value:,}").replace(",", " ")      # allow "9,607" / "9 607"
        plain = norm(str(value))
        ok = any(all(k in ln for k in keywords) and (plain in ln or needle in ln)
                 for ln in lines[where])
        print(f"  {'ok  ' if ok else 'FAIL'} {where}: {value} {'+'.join(keywords)}")
        if not ok:
            failed.append(f"{where}: no line mentions {value} with {keywords}")

    for c in telegram_whitelist():                          # docs/07 must document each command
        ln_ok = norm(f"/{c}") in norm(files["docs/07-telegram-command-spec.md"].read_text(encoding="utf-8"))
        if not ln_ok:
            failed.append(f"docs/07: command /{c} is implemented but not documented")
    print(f"  ok   all {s['commands']} Telegram commands documented in docs/07"
          if not any("docs/07" in f for f in failed) else
          f"  FAIL docs/07: {len([f for f in failed if 'docs/07' in f])} undocumented command(s)")

    # Every file name the docs mention must exist, and every class they name must be
    # defined. Docs describing a *sibling* module that was renamed or never written is
    # the cheapest possible way for a specification to start lying, and no test catches it.
    repo_names = {q.name for q in ROOT.rglob("*") if q.is_file() and ".git" not in q.parts}
    all_docs = "\n".join(v.read_text(encoding="utf-8") for v in files.values())
    FILE_MENTION = re.compile(r"((?:~|/|\./)?[A-Za-z0-9_][A-Za-z0-9_.~-]*"
                              r"(?:/[A-Za-z0-9_.~-]+)*\.(?:mq5|mqh|py|md|set))")
    mentioned = set(FILE_MENTION.findall(all_docs))
    # <Trade/Trade.mqh> references are MQL5 standard library paths, not our files
    stdlib_files = {b for b in re.findall(r"<([A-Za-z0-9_/]+\.mqh)>", all_docs)}
    stdlib_files |= {b.split("/")[-1] for b in stdlib_files} | {"Trade.mqh", "Object.mqh",
                                                                 "Array.mqh", "String.mqh"}
    ghost: list[str] = []
    for name in sorted(mentioned):
        bare = name.split("/")[-1]
        if bare in stdlib_files:
            continue
        if "/" in name:
            # a written path must resolve inside the repository; absolute paths are scratch
            if name.startswith(("/", "~")):
                continue
            if not (ROOT / name).exists():
                ghost.append(name)
        elif bare not in repo_names:
            ghost.append(name)
    if ghost:
        failed.append(f"docs mention files that do not exist: {ghost}")
    print("  ok   every file name mentioned in the docs exists" if not ghost
          else f"  FAIL ghost file names: {ghost}")

    known_classes: set[str] = set()
    for path in MODULES:
        known_classes |= set(re.findall(r"^(?:class|struct)\s+(\w+)", path.read_text(encoding="utf-8"), re.M))
    # MQL5 standard-library classes: legitimately named here (mostly to say we do NOT use them)
    stdlib = {"CTrade", "CPositionInfo", "CSymbolInfo", "CAccountInfo", "COrderInfo",
              "CDealInfo", "CHistoryOrderInfo", "CChartObjectLabel", "CExpert"}
    named_classes = set(re.findall(r"\b(C[A-Z][a-z]\w+)\b", all_docs))
    ghost_c = sorted(named_classes - known_classes - stdlib)
    if ghost_c:
        failed.append(f"docs mention classes that do not exist: {ghost_c}")
    print("  ok   every class named in the docs is defined (or is MQL5 stdlib)" if not ghost_c
          else f"  FAIL ghost classes: {ghost_c}")

    dead = dead_enum_members()
    for enum, members in sorted(dead.items()):
        failed.append(f"{enum}: unused member(s) {', '.join(members)}")
    print("  ok   every enum member is used" if not dead else
          f"  FAIL unused enum members: {dead}")

    if s["unwired_inputs"]:
        failed.append(f"{s['unwired_inputs']} input(s) never copied into CConfig")
    print("  ok   every input is copied into CConfig")

    print(f"  info source: {s['files']} files / {s['lines']} lines; CConfig {s['fields']} fields; "
          f"{s['reasons']} block reasons; {s['states']} states; {s['commands']} commands; "
          f"{s['assertions']} assertions; {s['format']} format strings; {s['rows']} dashboard rows; "
          f"docs {s['doc_files']} files")
    if failed:
        print(f"\n{len(failed)} documentation/code mismatch(es):")
        for f in failed:
            print("  - " + f)
        return 1
    print("\ndocumentation matches the source")
    return 0


if __name__ == "__main__":
    sys.exit(main())
