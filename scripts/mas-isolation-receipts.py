#!/usr/bin/env python3
"""Emit the four coupled MAS isolation receipts of SPEC section 2.

    python3 scripts/mas-isolation-receipts.py
    python3 scripts/mas-isolation-receipts.py --archive .build/Allward-MAS.app \
        --linker-map .build/mas-maps

Every rule comes from scripts/mas-isolation.json. The manifest is closed, so a
receipt fails on anything it does not list; widening MAS means editing that file
and nothing else.

The four receipts are coupled on purpose. Receipts 1 and 2 prove source and graph
visibility, receipts 3 and 4 prove artifact exclusion, and neither pair can stand
alone: a symbol scan cannot see a target the linker dead-stripped, and a clean
graph says nothing about what a signed bundle actually carries.

Exits non-zero when any receipt fails. Requires macOS: the Developer ID and MAS
application targets do not exist in the Linux half of the package graph, so there
is nothing here to prove on Linux.
"""

from __future__ import annotations

import argparse
import json
import plistlib
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MACH_O_MAGIC = {
    b"\xcf\xfa\xed\xfe",  # 64-bit little-endian
    b"\xce\xfa\xed\xfe",  # 32-bit little-endian
    b"\xfe\xed\xfa\xcf",
    b"\xfe\xed\xfa\xce",
    b"\xca\xfe\xba\xbe",  # universal
}
SCANNABLE_SUFFIXES = {".swift", ".c", ".h", ".m", ".mm"}


@dataclass
class Receipt:
    """One of the four receipts. `problems` empty means it passed."""

    number: int
    name: str
    problems: list[str] = field(default_factory=list)
    facts: list[str] = field(default_factory=list)

    def fail(self, message: str) -> None:
        self.problems.append(message)

    def note(self, message: str) -> None:
        self.facts.append(message)

    @property
    def passed(self) -> bool:
        return not self.problems

    def report(self) -> None:
        verdict = "PASS" if self.passed else "FAIL"
        print(f"\n== receipt {self.number}: {self.name} == {verdict}")
        for fact in self.facts:
            print(f"   {fact}")
        for problem in self.problems:
            print(f"   FAIL {problem}")


def run(command: list[str], cwd: Path = ROOT) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command, cwd=cwd, capture_output=True, text=True, check=False
    )


def swift_describe() -> dict:
    result = run(["swift", "package", "describe", "--type", "json"])
    if result.returncode != 0:
        raise SystemExit(
            "cannot resolve the package graph:\n"
            + (result.stderr or result.stdout).strip()
        )
    # SwiftPM may prepend resolution progress before the JSON document.
    text = result.stdout
    start = text.find("{")
    if start < 0:
        raise SystemExit("swift package describe produced no JSON")
    return json.loads(text[start:])


def mangled_module_prefix(module: str) -> str:
    """Swift mangles a module as its length followed by its name.

    So `AllwardLocalPTY` appears inside every mangled symbol it owns as
    `15AllwardLocalPTY`, which is what makes a symbol table searchable for a
    module rather than only for a function.
    """
    return f"{len(module)}{module}"


# --- receipt 1: resolved dependency graph -----------------------------------


def dependency_paths(
    targets: dict[str, dict], root: str, goal: str
) -> list[str] | None:
    """Shortest declared-dependency path from `root` to `goal`, or None."""
    if root not in targets:
        return None
    queue: list[list[str]] = [[root]]
    seen = {root}
    while queue:
        path = queue.pop(0)
        for dependency in targets[path[-1]].get("target_dependencies", []):
            if dependency == goal:
                return path + [dependency]
            if dependency in seen or dependency not in targets:
                continue
            seen.add(dependency)
            queue.append(path + [dependency])
    return None


def closure(targets: dict[str, dict], root: str) -> list[str]:
    if root not in targets:
        return []
    order = [root]
    seen = {root}
    index = 0
    while index < len(order):
        for dependency in targets[order[index]].get("target_dependencies", []):
            if dependency in seen or dependency not in targets:
                continue
            seen.add(dependency)
            order.append(dependency)
        index += 1
    return order


def receipt_graph(
    manifest: dict, targets: dict[str, dict], root: str
) -> Receipt:
    receipt = Receipt(1, "resolved package and target dependency graph exclusion")
    if root not in targets:
        receipt.fail(
            f"the package declares no target named {root!r}; "
            "the MAS product is missing from Package.swift"
        )
        return receipt

    members = closure(targets, root)
    receipt.note(f"{root} resolves {len(members)} targets")
    for forbidden in manifest["forbidden_targets"]:
        name = forbidden["name"]
        path = dependency_paths(targets, root, name)
        if path is None:
            receipt.note(f"ok {name} is absent from the {root} graph")
            continue
        # A shortest path can hide the edge that matters. `AllwardSSH` reaching
        # `AllwardLocalPTY` is the drift this plan set out to repair, and it
        # never appears in a shortest path while `AllwardControl` names the same
        # module directly. So every declaring target is named.
        declaring = [
            member
            for member in members
            if name in targets[member].get("target_dependencies", [])
        ]
        receipt.fail(
            f"{name} is reachable from {root} through "
            + " -> ".join(path)
            + f"\n        declared by: {', '.join(declaring)}"
            + f"\n        {forbidden['reason']}"
        )
    return receipt


# --- receipt 2: negative compile fixtures and source visibility -------------


def fixture_arguments(
    scratch: Path, root: str, targets: dict[str, dict], members: list[str]
) -> list[str]:
    """Compiler arguments that put exactly the MAS closure on the search path.

    A Swift module that wraps a C target cannot be imported without that target's
    generated module map, so the C targets inside the closure contribute their
    own arguments. Deriving them from the closure rather than naming them keeps
    the fixtures honest: once a C target leaves the MAS graph its map stops being
    offered, and the fixture then fails because the module is genuinely absent.
    """
    build = run(
        [
            "swift",
            "build",
            "--scratch-path",
            str(scratch),
            "--target",
            root,
        ]
    )
    if build.returncode != 0:
        raise RuntimeError(
            f"the {root} target does not build, so no fixture can be compiled "
            "against it:\n" + (build.stderr or build.stdout).strip()[-2000:]
        )
    where = run(
        ["swift", "build", "--scratch-path", str(scratch), "--show-bin-path"]
    )
    if where.returncode != 0:
        raise RuntimeError("cannot locate the build directory")
    binaries = Path(where.stdout.strip())
    arguments = ["-I", str(binaries / "Modules")]
    for name in members:
        if targets[name].get("module_type") != "ClangTarget":
            continue
        headers = ROOT / targets[name]["path"] / "include"
        if headers.is_dir():
            arguments += ["-Xcc", f"-I{headers}"]
        module_map = binaries / f"{name}.build" / "module.modulemap"
        if module_map.is_file():
            arguments += ["-Xcc", f"-fmodule-map-file={module_map}"]
    return arguments


def scan_sources(
    manifest: dict, targets: dict[str, dict], members: list[str]
) -> list[str]:
    """Find forbidden capability constructs in the MAS closure's own sources."""
    exemptions = {
        (entry["path"], entry["capability"])
        for entry in manifest["capability_source_exemptions"]["entries"]
    }
    compiled = [
        (capability["id"], re.compile(pattern))
        for capability in manifest["forbidden_capabilities"]
        for pattern in capability.get("source_patterns", [])
    ]
    problems: list[str] = []
    for name in members:
        target = targets[name]
        base = ROOT / target["path"]
        for source in target.get("sources", []):
            file = base / source
            if file.suffix not in SCANNABLE_SUFFIXES or not file.is_file():
                continue
            relative = str(file.relative_to(ROOT))
            text = file.read_text(encoding="utf-8", errors="replace")
            for line_number, line in enumerate(text.splitlines(), start=1):
                if line.lstrip().startswith("//"):
                    continue
                for capability_id, pattern in compiled:
                    if (relative, capability_id) in exemptions:
                        continue
                    if pattern.search(line):
                        problems.append(
                            f"{capability_id} at {relative}:{line_number}: "
                            f"{line.strip()[:96]}"
                        )
    return problems


UNRESOLVED_FORMS = (
    "no such module '{name}'",
    "cannot find '{name}' in scope",
    "cannot find type '{name}' in scope",
    "cannot find '{name}'",
)


def unresolved_name(diagnostic: str, names: list[str]) -> str | None:
    """The forbidden name the compiler could not resolve, if that is why it failed.

    Merely mentioning the name is not enough. A fixture that fails because some
    unrelated module is missing would otherwise read as isolation, which is the
    exact false pass this receipt exists to prevent.
    """
    for name in names:
        for form in UNRESOLVED_FORMS:
            if form.format(name=name) in diagnostic:
                return name
    return None


def receipt_fixtures(
    manifest: dict, targets: dict[str, dict], root: str, scratch: Path
) -> Receipt:
    receipt = Receipt(2, "negative MAS compile fixtures and source visibility")
    members = closure(targets, root)
    try:
        arguments = fixture_arguments(scratch, root, targets, members)
    except RuntimeError as error:
        receipt.fail(str(error))
        return receipt

    for fixture in manifest["negative_fixtures"]["entries"]:
        path = ROOT / fixture["path"]
        if not path.is_file():
            receipt.fail(f"fixture {fixture['path']} is missing")
            continue
        compile_result = run(["swiftc", "-typecheck", *arguments, str(path)])
        names = fixture["must_not_resolve"]
        if compile_result.returncode == 0:
            receipt.fail(
                f"{fixture['path']} compiled, so {' or '.join(names)} is visible "
                f"to {root}\n        {fixture['reason']}"
            )
            continue
        resolved = unresolved_name(compile_result.stderr, names)
        if resolved is None:
            receipt.fail(
                f"{fixture['path']} failed to compile without reporting any of "
                f"{names} as unresolved, so it proves nothing:\n"
                + "\n".join(
                    f"        {line}"
                    for line in compile_result.stderr.splitlines()[:6]
                )
            )
            continue
        receipt.note(f"ok {fixture['path']}: {resolved} does not resolve")

    for problem in scan_sources(manifest, targets, members):
        receipt.fail(problem)
    return receipt


# --- receipt 3: archive linker map and linked library closure ---------------


def linked_libraries(binary: Path) -> list[str]:
    result = run(["otool", "-L", str(binary)])
    if result.returncode != 0:
        raise RuntimeError(f"otool -L failed for {binary}: {result.stderr.strip()}")
    libraries = []
    for line in result.stdout.splitlines()[1:]:
        stripped = line.strip()
        if not stripped or "(compatibility version" not in stripped:
            continue
        libraries.append(stripped.split(" (compatibility version")[0])
    return libraries


def receipt_link(
    manifest: dict, archive: Path | None, linker_map_dir: Path | None
) -> Receipt:
    receipt = Receipt(3, "archive linker map and linked library closure")
    executables = manifest["artifacts"]["executables"]
    if archive is None:
        receipt.fail(
            "no MAS archive to inspect. This receipt reads a real archive, not a "
            "build directory, so it cannot pass before phase 6 produces one.\n"
            "        Pass one with --archive <Allward-MAS.app>."
        )
        return receipt

    permitted = manifest["linked_libraries"]["permitted_prefixes"]
    forbidden_exact = set(manifest["linked_libraries"]["forbidden_exact"])
    forbidden_targets = [entry["name"] for entry in manifest["forbidden_targets"]]

    for declared in executables:
        binary = archive / declared["path"]
        if not binary.is_file():
            receipt.fail(f"{declared['path']} is missing from {archive}")
            continue
        try:
            libraries = linked_libraries(binary)
        except RuntimeError as error:
            receipt.fail(str(error))
            continue
        receipt.note(f"{declared['path']} links {len(libraries)} libraries")
        for library in libraries:
            if library in forbidden_exact:
                receipt.fail(f"{declared['path']} links forbidden {library}")
            elif not any(library.startswith(prefix) for prefix in permitted):
                receipt.fail(
                    f"{declared['path']} links {library}, which the manifest "
                    "does not permit"
                )

        if linker_map_dir is None:
            receipt.fail(
                f"no linker map for {declared['path']}. Dead stripping can remove "
                "a forbidden target's code while leaving it in the graph, so the "
                "map is what proves what the linker was given.\n"
                "        Produce one with: swift build -c release --product "
                f"{declared['target']} -Xlinker -map -Xlinker <dir>/"
                f"{Path(declared['path']).name}.map\n"
                "        then pass --linker-map <dir>."
            )
            continue
        map_file = linker_map_dir / f"{Path(declared['path']).name}.map"
        if not map_file.is_file():
            receipt.fail(f"linker map {map_file} is missing")
            continue
        text = map_file.read_text(encoding="utf-8", errors="replace")
        listed = [
            name
            for name in forbidden_targets
            if f"{name}.build" in text or f"/{name}.o" in text
        ]
        for name in listed:
            receipt.fail(
                f"the linker map for {declared['path']} lists object files "
                f"from {name}"
            )
        if not listed:
            receipt.note(
                f"ok the linker map for {declared['path']} lists no forbidden target"
            )
    return receipt


# --- receipt 4: final artifact inspection ----------------------------------


def is_mach_o(path: Path) -> bool:
    try:
        with path.open("rb") as handle:
            return handle.read(4) in MACH_O_MAGIC
    except OSError:
        return False


def symbols(binary: Path) -> str:
    """Every symbol name the binary carries, defined and undefined."""
    text = []
    for arguments in (["nm", "-jU", str(binary)], ["nm", "-ju", str(binary)]):
        result = run(arguments)
        if result.returncode == 0:
            text.append(result.stdout)
    return "\n".join(text)


def entitlements(archive: Path) -> dict:
    result = run(["codesign", "-d", "--entitlements", "-", "--xml", str(archive)])
    if result.returncode != 0:
        raise RuntimeError(
            "cannot read entitlements: " + (result.stderr or result.stdout).strip()
        )
    raw = result.stdout.encode()
    start = raw.find(b"<?xml")
    if start < 0:
        raise RuntimeError("the archive carries no entitlements")
    return plistlib.loads(raw[start:])


def receipt_artifacts(manifest: dict, archive: Path | None) -> Receipt:
    receipt = Receipt(4, "final artifact symbol, import, and dependency inspection")
    artifacts = manifest["artifacts"]
    if archive is None:
        receipt.fail(
            "no MAS archive to inspect. The manifest's artifact set is closed, so "
            "this receipt compares it against a real bundle and cannot pass before "
            "phase 6 produces one.\n        Pass one with --archive <Allward-MAS.app>."
        )
        return receipt

    declared = {
        entry["path"]
        for group in ("executables", "helpers", "frameworks", "extensions", "bundled_libraries")
        for entry in artifacts[group]
    }
    found = {
        str(path.relative_to(archive))
        for path in archive.rglob("*")
        if path.is_file() and is_mach_o(path)
    }
    for missing in sorted(declared - found):
        receipt.fail(f"the manifest declares {missing}, which the archive lacks")
    for extra in sorted(found - declared):
        receipt.fail(
            f"the archive carries Mach-O {extra}, which the manifest does not list"
        )

    forbidden_symbols = {
        symbol: capability["id"]
        for capability in manifest["forbidden_capabilities"]
        for symbol in capability.get("symbols", [])
    }
    module_prefixes = {
        mangled_module_prefix(entry["name"]): entry["name"]
        for entry in manifest["forbidden_targets"]
    }

    for relative in sorted(found & declared):
        binary = archive / relative
        table = symbols(binary)
        if not table.strip():
            receipt.fail(
                f"{relative} yielded no symbol table, so nothing was inspected; "
                "a stripped binary cannot satisfy this receipt"
            )
            continue
        names = set(table.split())
        for symbol, capability_id in forbidden_symbols.items():
            if symbol in names:
                receipt.fail(f"{relative} imports {symbol} ({capability_id})")
        for prefix, module in module_prefixes.items():
            if any(prefix in name for name in names):
                receipt.fail(f"{relative} carries symbols mangled for {module}")
        receipt.note(f"inspected {len(names)} symbols in {relative}")

    try:
        granted = entitlements(archive)
    except RuntimeError as error:
        receipt.fail(str(error))
        return receipt
    for required in manifest["entitlements"]["required"]:
        if not granted.get(required):
            receipt.fail(f"the archive lacks required entitlement {required}")
    for banned in manifest["entitlements"]["forbidden"]:
        if granted.get(banned):
            receipt.fail(f"the archive claims forbidden entitlement {banned}")
    receipt.note(f"inspected {len(granted)} entitlements")
    return receipt


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Emit the four MAS isolation receipts of SPEC section 2."
    )
    parser.add_argument("--manifest", default=str(ROOT / "scripts/mas-isolation.json"))
    parser.add_argument(
        "--archive", help="path to a MAS .app bundle for receipts 3 and 4"
    )
    parser.add_argument(
        "--linker-map", help="directory holding one linker map per declared executable"
    )
    parser.add_argument(
        "--scratch",
        default=str(ROOT / ".build-mas-receipts"),
        help="build directory for the fixture module search path",
    )
    arguments = parser.parse_args()

    if sys.platform != "darwin":
        print(
            "mas-isolation-receipts requires macOS: the application targets are "
            "absent from the Linux half of the package graph, so there is nothing "
            "here to prove.",
            file=sys.stderr,
        )
        return 2

    manifest = json.loads(Path(arguments.manifest).read_text())
    root = manifest["product"]["root_target"]
    archive = Path(arguments.archive).resolve() if arguments.archive else None
    linker_map = Path(arguments.linker_map).resolve() if arguments.linker_map else None

    described = swift_describe()
    targets = {target["name"]: target for target in described["targets"]}

    print(f"MAS isolation receipts for {root}")
    print(f"manifest {Path(arguments.manifest).name} version {manifest['manifest_version']}")
    print(f"archive  {archive or 'none (receipts 3 and 4 cannot pass)'}")

    receipts = [
        receipt_graph(manifest, targets, root),
        receipt_fixtures(manifest, targets, root, Path(arguments.scratch)),
        receipt_link(manifest, archive, linker_map),
        receipt_artifacts(manifest, archive),
    ]
    for receipt in receipts:
        receipt.report()

    failed = [receipt for receipt in receipts if not receipt.passed]
    print()
    if failed:
        print(
            "MAS isolation is NOT proven: "
            + ", ".join(f"receipt {receipt.number}" for receipt in failed)
            + " failed."
        )
        return 1
    print("MAS isolation proven: all four receipts pass.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
