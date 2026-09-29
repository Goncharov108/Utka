#!/bin/bash
# Последняя цифра растёт сама, когда появляется новое обновление.
# Установка с main передаёт UTKA_INSTALL=1 и номер не придумывает.
# Повторная сборка уже сдвинутого номера ничего не прибавляет. Хуков нет.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "${UTKA_INSTALL:-}" = "1" ]; then
  exit 0
fi
ROOT="$ROOT" python3 - << 'PY'
import os
import re
import subprocess
import sys

root = os.environ["ROOT"]
path = os.path.join(root, "VERSION")
triple = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")


def git(*args):
    run = subprocess.run(
        ["git", "-C", root, *args],
        capture_output=True,
        text=True,
    )
    return run.returncode, run.stdout


def parts(text):
    lines = text.splitlines()
    version = lines[0].strip() if lines else ""
    note = "\n".join(lines[1:]).strip()
    return version, note


code, inside = git("rev-parse", "--is-inside-work-tree")
if code != 0 or inside.strip() != "true":
    sys.exit(0)
if git("cat-file", "-e", "HEAD:VERSION")[0] != 0:
    sys.exit(0)
code, head_text = git("show", "HEAD:VERSION")
if code != 0:
    sys.exit(0)
head_version, head_note = parts(head_text)
with open(path, encoding="utf-8") as handle:
    work_version, work_note = parts(handle.read())
if not triple.match(head_version) or not triple.match(work_version):
    sys.exit(0)
if work_version != head_version:
    sys.exit(0)

code, version_commit = git("log", "-1", "--format=%H", "--", "VERSION")
_, head_commit = git("rev-parse", "HEAD")
version_commit = version_commit.strip()
head_commit = head_commit.strip()
new_commits = 0
if code == 0 and version_commit and version_commit != head_commit:
    count_code, count = git("rev-list", "--count", f"{version_commit}..HEAD")
    if count_code == 0:
        new_commits = int(count.strip() or "0")
note_edited = work_note != head_note
if new_commits == 0 and not note_edited:
    sys.exit(0)

major, minor, patch = work_version.split(".")
bumped = f"{major}.{minor}.{int(patch) + 1}"
note = work_note if note_edited else ""
body = bumped + "\n\n"
if note:
    body += note + "\n"
with open(path, "w", encoding="utf-8") as handle:
    handle.write(body)
print(f"номер обновления {work_version} → {bumped}")
PY
