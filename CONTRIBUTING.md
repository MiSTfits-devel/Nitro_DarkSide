# Contributor License Agreement (CLA)

By submitting changes to this repository, you agree that:

- Your contributions will be licensed irrevocably under the [GNU General
  Public License version 3](LICENSE.txt).
- Your contributions are your own work, or you otherwise have the right to
  submit them, and they are free of legal restrictions—including patent or
  copyright restrictions—that would prevent their inclusion or distribution
  under that license.

If you do not agree to these terms, do not submit contributions to this
repository. If you have questions about these terms, contact the project
maintainers through GitHub Issues before contributing.

## Developer Certificate of Origin (DCO)

The [Developer Certificate of Origin 1.1](DCO.txt) is a separate
certification of a contribution's origin and your right to submit it. It
does not replace or change the CLA above. The DCO text is also available
from its [official source](https://developercertificate.org/).

Sign off each commit you contribute to a pull request to certify that you
agree to the DCO for that commit. Once the DCO check is enabled, it examines
commits reachable from the pull request head but not its base, including
merge commits and bot commits. It does not retroactively check commits
already in the base.
Each commit must have a `Signed-off-by` trailer whose name and email
exactly match its Git author, including case. Each `Co-authored-by` trailer
also requires a sign-off matching that co-author's name and email exactly.
Every person must provide their own sign-off; never sign for someone else.

After the DCO check has been verified on a real pull request and the
repository ruleset activated, changes must go through pull requests rather
than direct pushes, including for administrators. No additional reviewer is
required by that ruleset.

Configure your own Git author name and GitHub-provided noreply email
address, then use lowercase `-s` to add your sign-off. The repository's
public-safety check accepts the GitHub noreply form
`<numeric user ID>+<GitHub username>@users.noreply.github.com` (or
`noreply@github.com`) for author and committer email. Find your own
address in your GitHub email settings; do not substitute another person's
identity. For example, after setting `GITHUB_NOREPLY_EMAIL` to your own
address:

```sh
git config user.name "Your Name"
git config user.email "$GITHUB_NOREPLY_EMAIL"
git commit -s -m "Describe your change"
```

This adds a `Signed-off-by` trailer using your configured name and email.
Lowercase `-s` is a DCO sign-off; uppercase `-S` instead requests a
cryptographic signature and does not replace the sign-off.

If your own most recent commit is missing your sign-off and has not been
pushed, correct it with:

```sh
git commit --amend --no-edit -s
```

This rewrites the commit. Do not rewrite published commits to add
sign-offs; ask the maintainers how to proceed instead.
