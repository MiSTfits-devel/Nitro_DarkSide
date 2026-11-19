"""Exercise the DCO CLI with real Git objects in disposable repositories only."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


CHECK = Path(__file__).with_name("check_dco.py").resolve()
AUTHOR = "Fixture Author <author@example.invalid>"
COAUTHOR = "Second Fixture <second@example.invalid>"
COMMITTER = "Fixture Integrator <integrator@example.invalid>"
SIGNED = "Signed-off-by: " + AUTHOR


class DcoTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.repo = Path(tmp.name) / "objects.git"
        self.repo.mkdir()
        self.env = {
            "PATH": os.environ["PATH"], "HOME": tmp.name, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_COMMITTER_NAME": "Fixture Integrator", "GIT_COMMITTER_EMAIL": "integrator@example.invalid",
        }
        self.git("init", "--quiet", "--bare")
        self.tree = self.git("mktree", message="")
        self.base = self.commit("Unsigned historical baseline")

    def git(self, *args, message=None, author=AUTHOR):
        name, email = author[:-1].split(" <")
        return subprocess.run(
            ["git", *args], cwd=self.repo, input=message, text=True, capture_output=True,
            env=dict(self.env, GIT_AUTHOR_NAME=name, GIT_AUTHOR_EMAIL=email), check=True,
        ).stdout.strip()

    def commit(self, message, *parents, author=AUTHOR):
        args = [arg for parent in parents for arg in ("-p", parent)]
        return self.git("commit-tree", self.tree, *args, message=message + "\n", author=author)

    def check(self, head, expected, base=None):
        result = subprocess.run(
            [sys.executable, "-I", CHECK, base or self.base, head], cwd=self.repo,
            text=True, capture_output=True, env=self.env,
        )
        self.assertEqual(result.returncode, int(bool(expected)), result.stdout + result.stderr)
        self.assertEqual({line.split(":")[0] for line in result.stderr.splitlines()}, set(expected))
        return result.stdout

    def test_multi_commit_and_unsigned_middle(self):
        first = self.commit("First change\n\n" + SIGNED, self.base)
        second = self.commit("Second change\n\n" + SIGNED, first)
        self.assertIn("checked 2 commit(s)", self.check(second, []))
        middle = self.commit("Middle change without a sign-off", first)
        tip = self.commit("Signed tip\n\n" + SIGNED, middle)
        self.assertIn("checked 3 commit(s)", self.check(tip, [middle]))

    def test_body_is_not_a_trailer(self):
        for message in (
            SIGNED,
            "Subject\n\n" + SIGNED + "\n\nThis is still the body.",
            "Subject\n\n" + SIGNED + "\n\n---\nThere is more body text after the divider.",
        ):
            with self.subTest(message=message):
                head = self.commit(message, self.base)
                self.check(head, [head])

    def test_exact_author_not_committer(self):
        for identity in (COMMITTER, "Other Name <author@example.invalid>",
                         "Fixture Author <other@example.invalid>", AUTHOR.upper()):
            with self.subTest(identity=identity):
                head = self.commit("Subject\n\nSigned-off-by: " + identity, self.base)
                self.check(head, [head])

    def test_all_coauthors_must_sign(self):
        message = "Joint change\n\nCo-Authored-By: " + COAUTHOR + "\n" + SIGNED
        missing = self.commit(message, self.base)
        self.check(missing, [missing])
        complete = self.commit(message + "\nsigned-off-by: " + COAUTHOR, self.base)
        self.check(complete, [])
        malformed = self.commit(message + "\nSigned-off-by: " + COAUTHOR + "\nCo-authored-by: incomplete", self.base)
        self.check(malformed, [malformed])

    def test_bot_and_merges_have_no_exemption(self):
        bot = "Fixture[bot] <fixture-bot@example.invalid>"
        unsigned = self.commit("Automated change", self.base, author=bot)
        signed = self.commit("Automated change\n\nSigned-off-by: " + bot, self.base, author=bot)
        self.check(signed, [])
        main = self.commit("Contributor change\n\n" + SIGNED, self.base)
        unsigned_merge = self.commit("Merge branch", main, signed)
        self.check(unsigned_merge, [unsigned_merge])
        side_failure = self.commit("Merge branch\n\n" + SIGNED, main, unsigned)
        self.check(side_failure, [unsigned])

    def test_divergent_base_and_criss_cross_history(self):
        left = self.commit("Already in base, left", self.base)
        right = self.commit("Already in base, right", self.base)
        base = self.commit("Base merged both changes", left, right)
        candidate = self.commit("PR merged both independently\n\n" + SIGNED, right, left)
        self.assertEqual(len(self.git("merge-base", "--all", base, candidate).splitlines()), 2)
        self.assertIn("checked 1 commit(s)", self.check(candidate, [], base=base))

    def test_shallow_history_cannot_return_a_pass(self):
        head = self.commit("Unsigned side branch", self.base)
        (self.repo / "shallow").write_text(head + "\n")
        result = subprocess.run([sys.executable, "-I", CHECK, self.base, head], cwd=self.repo,
                                text=True, capture_output=True, env=self.env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("complete commit ancestry", result.stderr)


if __name__ == "__main__":
    unittest.main()
