"""Check the DCO for BASE..HEAD in the current, non-shallow Git repository."""

import argparse
import re
import subprocess
import sys


IDENTITY = re.compile(rb"[^<>\x00-\x1f]+ <[^<>\s\x00-\x1f]+>")


def git(*args, data=None):
    return subprocess.run(
        ["git", "--no-replace-objects", *args], input=data, stdout=subprocess.PIPE, check=True
    ).stdout


def violation(oid):
    raw = git("cat-file", "commit", oid)
    headers, sep, message = raw.partition(b"\n\n")
    authors = [h[7:] for h in headers.split(b"\n") if h.startswith(b"author ")]
    if not sep or b"\0" in raw or len(authors) != 1:
        return "malformed commit"
    # Ignore the raw timestamp and time zone. Do not consult a mailmap, a
    # GitHub account, or the committer when checking the author's identity.
    author = authors[0].rsplit(b" ", 2)[0]
    if not IDENTITY.fullmatch(author):
        return "malformed Git author identity"

    signers = set()
    coauthors = set()
    # --parse accepts only Git's trailing block, unfolding continuations;
    # --no-divider treats '---' as message text, not an email patch boundary.
    for line in git("interpret-trailers", "--parse", "--no-divider", data=message).split(b"\n"):
        key, _, value = line.partition(b":")
        key = key.lower()
        if key == b"signed-off-by":
            signers.add(value.strip())
        elif key == b"co-authored-by":
            coauthor = value.strip()
            if not IDENTITY.fullmatch(coauthor):
                return "malformed Co-authored-by trailer"
            coauthors.add(coauthor)
    if author not in signers:
        return "missing Signed-off-by matching the Git author"
    if not coauthors.issubset(signers):
        return "missing Signed-off-by matching a co-author"
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base", metavar="BASE_SHA")
    parser.add_argument("head", metavar="HEAD_SHA")
    args = parser.parse_args()
    if not all(re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", sha) for sha in (args.base, args.head)):
        parser.error("expected two full Git object IDs")
    if git("rev-parse", "--is-shallow-repository").strip() != b"false":
        parser.error("complete commit ancestry is required")
    for sha in (args.base, args.head):
        if git("cat-file", "-t", sha).strip() != b"commit":
            parser.error("both endpoints must be commits")
    # Subtract all of the base's ancestors, not just one merge base. This
    # includes side parents brought in by contributor-created merge commits.
    commits = git("rev-list", f"{args.base}..{args.head}", "--").splitlines()
    failed = 0
    for commit in commits:
        oid = commit.decode("ascii")
        problem = violation(oid)
        if problem:
            # Never emit candidate-controlled text as a workflow log command.
            print(f"{oid}: {problem}", file=sys.stderr)
            failed += 1
    print(f"DCO: checked {len(commits)} commit(s); {failed} failed.")
    return int(bool(failed))


if __name__ == "__main__":
    sys.exit(main())
