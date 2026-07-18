#!/usr/bin/env python3
"""Mechanical checks for the Natori character voice, per
references/evaluation-criteria.md. Pure standard library — no sudachipy —
because inputs are short voice-conversation replies (tens to ~200 chars),
not long-form documents, so regex/substring checks are sufficient.

Usage:
    python3 lint_natori.py <file>        # human-readable report
    python3 lint_natori.py <file> --json # JSON findings
    echo "text" | python3 lint_natori.py -

A file with multiple non-empty lines is treated as a multi-turn transcript
(one assistant reply per line) — this enables the cross-turn repetition
check (evaluation-criteria.md #7). A single-line file is scored as one
reply; the repetition check is skipped (not meaningful for a single turn).

Exit code is always 0 (this is a lint, not a gate) unless the input itself
cannot be read, matching natural-japanese's lint.py convention.
"""

import argparse
import json
import re
import sys

# --- Thresholds (see evaluation-criteria.md for rationale) -----------------

LENGTH_WARN = 100
LENGTH_CRITICAL = 160
LENGTH_HARD_WARN = 200  # ties to CLAUDE_MAX_TOKENS=220 in infra/cdk.json

POLITE_ENDING_WARN_RATIO = 0.5
POLITE_ENDING_CRITICAL_RATIO = 0.8

# --- Word lists --------------------------------------------------------

FORBIDDEN_FIRST_PERSON = ["私", "わたし", "わたくし", "僕", "ぼく", "俺", "おれ", "自分は"]

FORBIDDEN_SECOND_PERSON = ["あなた", "君は", "きみは", "お前", "おまえ"]

# High-keigo markers that contradict the character's casual tone.
# (Plain です/ます is allowed and checked separately as a ratio, not here.)
KEIGO_MARKERS = [
    "でございます",
    "いたします",
    "させていただきます",
    "なさいます",
    "おっしゃ",
    "いらっしゃ",
    "拝見",
    "申し上げ",
]

CHARACTER_BREAK_MARKERS = [
    "AIとして",
    "AIです",
    "言語モデル",
    "アシスタントとして",
    "ロールプレイ",
    "設定では",
    "キャラクターを演じ",
    "演者",
    "架空のキャラクター",
]

# Subset of natural-japanese's forbidden-patterns, refocused on
# conversational voice replies (see references/forbidden-patterns.md).
AI_SMELL_PHRASES = [
    "と言えるでしょう",
    "と言えるだろう",
    "ということになるでしょう",
    "のではないでしょうか",
    "結論から言うと",
    "結論として",
    "まとめると",
    "総じて",
    "いかがでしたか",
    "いかがでしょうか",
    "非常に重要",
    "極めて重要",
    "言うまでもなく",
    "言うまでもありません",
    "さて、",
    "それでは、",
    "このように",
    "一概には言えません",
    "何かあれば聞いてください",
    "ぜひ",
    "していきたいと思います",
]

TEMPO_FILLERS = ["でもさ", "なんかさ", "というか", "まあね", "えっとね"]

# Sentence-final soft-hedge forms the character favors (informational only).
SOFT_ENDINGS = ["かな", "って思う", "なんじゃない", "だよね", "じゃない"]

POLITE_ENDING_RE = re.compile(r"(です|ます|でした|ました)[。！？!?]?$")

SENTENCE_SPLIT_RE = re.compile(r"[。！？!?\n]")


def split_sentences(text: str) -> list[str]:
    parts = [s.strip() for s in SENTENCE_SPLIT_RE.split(text)]
    return [s for s in parts if s]


def find_all(text: str, phrases: list[str]) -> list[str]:
    return [p for p in phrases if p in text]


def check_length(text: str) -> list[dict]:
    n = len(text)
    findings = []
    if n > LENGTH_HARD_WARN:
        findings.append(
            {
                "category": "length",
                "severity": "critical",
                "message": f"{n}文字。実用上限({LENGTH_HARD_WARN}文字)を超過。"
                "CLAUDE_MAX_TOKENSの見直しも検討 (#10 長文警告)。",
            }
        )
    elif n > LENGTH_CRITICAL:
        findings.append(
            {
                "category": "length",
                "severity": "critical",
                "message": f"{n}文字。名取らしい短さの理想を大きく超過 (#5)。",
            }
        )
    elif n > LENGTH_WARN:
        findings.append(
            {
                "category": "length",
                "severity": "warn",
                "message": f"{n}文字。目安の{LENGTH_WARN}文字を超えている (#5)。",
            }
        )
    return findings


def check_first_person(text: str) -> list[dict]:
    hits = find_all(text, FORBIDDEN_FIRST_PERSON)
    if not hits:
        return []
    return [
        {
            "category": "first-person",
            "severity": "critical",
            "message": f"一人称『名取』以外の一人称を検出: {', '.join(hits)} (#3)。",
        }
    ]


def check_user_address(text: str) -> list[dict]:
    hits = find_all(text, FORBIDDEN_SECOND_PERSON)
    if not hits:
        return []
    return [
        {
            "category": "user-address",
            "severity": "critical",
            "message": f"「せんせえ」以外の二人称を検出: {', '.join(hits)} (#4)。",
        }
    ]


def check_keigo(text: str) -> list[dict]:
    findings = []
    hits = find_all(text, KEIGO_MARKERS)
    if hits:
        findings.append(
            {
                "category": "keigo",
                "severity": "critical",
                "message": f"改まった敬語表現を検出: {', '.join(hits)} (#8)。",
            }
        )
    return findings


def check_endings(text: str) -> list[dict]:
    sentences = split_sentences(text)
    if not sentences:
        return []
    polite = sum(1 for s in sentences if POLITE_ENDING_RE.search(s + "。"))
    ratio = polite / len(sentences)
    findings = []
    if ratio > POLITE_ENDING_CRITICAL_RATIO:
        findings.append(
            {
                "category": "endings",
                "severity": "critical",
                "message": f"丁寧語文末の比率が{ratio:.0%}。名取らしい柔らかい語尾がほぼ無い (#1)。",
            }
        )
    elif ratio > POLITE_ENDING_WARN_RATIO:
        findings.append(
            {
                "category": "endings",
                "severity": "warn",
                "message": f"丁寧語文末の比率が{ratio:.0%}。柔らかい語尾をもう少し増やしたい (#1)。",
            }
        )
    return findings


def check_character_break(text: str) -> list[dict]:
    hits = find_all(text, CHARACTER_BREAK_MARKERS)
    if not hits:
        return []
    return [
        {
            "category": "character-break",
            "severity": "critical",
            "message": f"キャラクター崩壊の疑いがある表現を検出: {', '.join(hits)} (#9)。",
        }
    ]


def check_ai_smell(text: str) -> list[dict]:
    hits = find_all(text, AI_SMELL_PHRASES)
    if not hits:
        return []
    severity = "critical" if len(hits) >= 3 else "warn"
    return [
        {
            "category": "ai-smell",
            "severity": severity,
            "message": f"AI臭のある定型句を検出: {', '.join(hits)} (#6)。",
        }
    ]


def check_tempo(text: str) -> list[dict]:
    fillers = find_all(text, TEMPO_FILLERS)
    if fillers:
        return []
    return [
        {
            "category": "tempo",
            "severity": "info",
            "message": "つなぎ言葉(でもさ・なんかさ等)が見当たらない。単発の判定では"
            "問題ないが、複数ターンで一度も出ないと単調な印象になりやすい (#2)。",
        }
    ]


def check_repetition(turns: list[str]) -> list[dict]:
    if len(turns) < 3:
        return []
    endings = []
    for t in turns:
        sentences = split_sentences(t)
        endings.append(sentences[-1][-2:] if sentences and len(sentences[-1]) >= 2 else "")
    findings = []
    run_len = 1
    for i in range(1, len(endings)):
        if endings[i] and endings[i] == endings[i - 1]:
            run_len += 1
        else:
            run_len = 1
        if run_len >= 3:
            findings.append(
                {
                    "category": "repetition",
                    "severity": "warn",
                    "message": f"文末『{endings[i]}』が{run_len}ターン連続。同じ文型の反復の疑い (#7)。",
                    "turn_index": i,
                }
            )
    return findings


CHECKS = {
    "length": lambda text, turns: check_length(text),
    "first-person": lambda text, turns: check_first_person(text),
    "user-address": lambda text, turns: check_user_address(text),
    "keigo": lambda text, turns: check_keigo(text),
    "endings": lambda text, turns: check_endings(text),
    "character-break": lambda text, turns: check_character_break(text),
    "ai-smell": lambda text, turns: check_ai_smell(text),
    "tempo": lambda text, turns: check_tempo(text),
    "repetition": lambda text, turns: check_repetition(turns),
}


def run_lint(full_text: str, turns: list[str], checks: list[str]) -> list[dict]:
    findings = []
    for name in checks:
        fn = CHECKS[name]
        if name == "repetition":
            findings.extend(fn(full_text, turns))
        else:
            # Per-turn checks run once over the whole text for single-reply
            # input, or once per turn for a transcript, so findings can be
            # attributed to a specific line.
            if len(turns) <= 1:
                findings.extend(fn(full_text, turns))
            else:
                for i, t in enumerate(turns):
                    for f in fn(t, turns):
                        f["turn_index"] = i
                        findings.append(f)
    return findings


def print_human_report(findings: list[dict], turn_count: int) -> None:
    if not findings:
        print(f"findings: 0 ({turn_count}ターン)。機械的なチェックは全て通過。")
        return
    order = {"critical": 0, "warn": 1, "info": 2}
    findings = sorted(findings, key=lambda f: order.get(f["severity"], 9))
    print(f"findings: {len(findings)} ({turn_count}ターン)")
    for f in findings:
        tag = {"critical": "[致命的]", "warn": "[要修正]", "info": "[参考]"}[f["severity"]]
        loc = f" (turn {f['turn_index']})" if "turn_index" in f else ""
        print(f"{tag} {f['category']}{loc}: {f['message']}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("file", help="対象ファイル(1行=1ターン)。'-' でstdin")
    parser.add_argument("--json", action="store_true", help="JSON形式で出力")
    parser.add_argument(
        "--check",
        default="all",
        help="カンマ区切りでチェック項目を指定(既定: all)。選択肢: "
        + ",".join(CHECKS.keys()),
    )
    args = parser.parse_args()

    try:
        raw = sys.stdin.read() if args.file == "-" else open(args.file, encoding="utf-8").read()
    except OSError as e:
        print(f"入力エラー: {e}", file=sys.stderr)
        return 1

    turns = [line.strip() for line in raw.splitlines() if line.strip()]
    full_text = "\n".join(turns)

    checks = list(CHECKS.keys()) if args.check == "all" else args.check.split(",")
    unknown = [c for c in checks if c not in CHECKS]
    if unknown:
        print(f"不明なチェック項目: {', '.join(unknown)}", file=sys.stderr)
        return 1

    findings = run_lint(full_text, turns, checks)

    if args.json:
        print(json.dumps({"findings": findings, "turn_count": len(turns)}, ensure_ascii=False, indent=2))
    else:
        print_human_report(findings, len(turns))

    return 0


if __name__ == "__main__":
    sys.exit(main())
