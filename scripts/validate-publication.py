#!/usr/bin/env python3

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = ROOT / "docs/SPEC.md"
DESIGN = ROOT / "docs/DESIGN-LANGUAGE.md"
PUBLIC_MARKDOWN = [ROOT / "README.md", *sorted((ROOT / "docs").rglob("*.md"))]

EXPECTED_ZSH_RECIPE = (
    '`[[ -r "${XDG_DATA_HOME:-$HOME/.local/share}/Allward/shell/v1/Allward.zsh" ]] '
    '&& source "${XDG_DATA_HOME:-$HOME/.local/share}/Allward/shell/v1/Allward.zsh" '
    "# Allward-managed:shell:zsh:v1`"
)
REQUIRED_DESIGN_SECTIONS = (
    "### 25.2 Breakpoint and state matrix",
    "### 25.3 Executable gate checklist",
    "### 25.6 Open design probes and owner approvals",
    "### 25.7 Gate output",
)
FORBIDDEN_PUBLIC_PATTERNS = (
    re.compile(r"\b[Tt]ern\b"),
    re.compile(r"\bTern[A-Z_]"),
    re.compile(r"\[(?:D\d|JP\d|E:)"),
    re.compile(r"JOINT-POSITION|ARCHITECT-BRIEF|drafts/|inputs/|agent://|artifact://"),
    re.compile(r"/home/|/Users/"),
    re.compile(r"designer-subagent|claude-fable|gpt-5"),
)
MARKDOWN_LINK = re.compile(r"(?<!!)\[[^\]]+\]\(([^)]+)\)")


def main() -> int:
    errors: list[str] = []
    spec = SPEC.read_text()
    design = DESIGN.read_text()

    if EXPECTED_ZSH_RECIPE not in spec:
        errors.append("SPEC.md does not contain the complete canonical zsh recipe")

    for section in REQUIRED_DESIGN_SECTIONS:
        if section not in design:
            errors.append(f"DESIGN-LANGUAGE.md is missing {section!r}")

    for path in PUBLIC_MARKDOWN:
        text = path.read_text()
        relative_path = path.relative_to(ROOT)

        if text.count("```") % 2:
            errors.append(f"{relative_path} has an unclosed fenced code block")

        for pattern in FORBIDDEN_PUBLIC_PATTERNS:
            if match := pattern.search(text):
                errors.append(
                    f"{relative_path} contains forbidden public text {match.group(0)!r}"
                )

        for match in MARKDOWN_LINK.finditer(text):
            target = match.group(1).split("#", 1)[0]
            if not target or "://" in target or target.startswith("mailto:"):
                continue
            if not (path.parent / target).resolve().exists():
                errors.append(f"{relative_path} links to missing path {target!r}")

    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1

    print(f"validated {len(PUBLIC_MARKDOWN)} public Markdown files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
