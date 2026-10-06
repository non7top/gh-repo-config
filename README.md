# Repo Config

:sparkles: A GitHub (`gh`) [CLI](https://cli.github.com) extension to manage GitHub repository settings via declarative configuration.

## Installation

1. Install the `gh` CLI - see the [installation](https://github.com/cli/cli#installation)

   _Installation requires a minimum version (2.0.0) of the the GitHub CLI that supports extensions._

2. Install this extension:

   ```sh
   gh extension install twelvelabs/gh-repo-config
   ```

## Usage

Navigate to the repo you would like to configure and run either:

```sh
gh repo-config init   # a starter file with the built-in defaults
gh repo-config pull   # the repo's live settings
```

Both write `.github/repo-config.json`. Edit it, then apply it:

```sh
gh repo-config push
```

| Command | What it does |
| --- | --- |
| `init` | Writes the built-in defaults to a new config file. Refuses to overwrite one. |
| `pull` | Live settings → config file. Shows a diff and asks before overwriting. |
| `push` | Config file → live settings. Sections missing from the file are left alone. |
| `sync` | Like `push`, but also deletes labels, rulesets, environments and branch protection that the file does not list. Asks first. |

Flags: `--config <file>`, `--dry-run` (print changes instead of making them), `--yes` (skip prompts), `--allow-default-branch-change`.

`push --dry-run` and `sync --dry-run` print a unified diff of the live settings against the file, with each hunk headed by its section, then the API calls they would make. Fields the file leaves out are not part of the diff, and `push` shows no deletions (`sync` does). "No changes" means the repo matches the file, so a dry-run doubles as a drift check.

### Config file

Each section is the request body of one GitHub API endpoint, using the API's own field names, so the GitHub docs describe it:

| Section | API |
| --- | --- |
| `repo` | [Update a repository](https://docs.github.com/en/rest/repos/repos#update-a-repository) |
| `topics` | [Replace all repository topics](https://docs.github.com/en/rest/repos/repos#replace-all-repository-topics) |
| `branch_protection` | [Update branch protection](https://docs.github.com/en/rest/branches/branch-protection#update-branch-protection), keyed by branch name. The key `~DEFAULT_BRANCH` (GitHub's own token, as in rulesets) means whatever the default branch currently is, so a rename doesn't stale the file. |
| `rulesets` | [Create](https://docs.github.com/en/rest/repos/rules#create-a-repository-ruleset) / [update](https://docs.github.com/en/rest/repos/rules#update-a-repository-ruleset) a ruleset, matched by `name` |
| `labels` | [Labels](https://docs.github.com/en/rest/issues/labels): `name`, `color`, `description` |
| `environments` | [Create or update an environment](https://docs.github.com/en/rest/deployments/environments#create-or-update-an-environment), keyed by name |
| `actions` | `permissions` and `workflow` are the bodies of [`PUT /actions/permissions`](https://docs.github.com/en/rest/actions/permissions) and `PUT /actions/permissions/workflow`. `workflow.can_approve_pull_request_reviews` is the "allow Actions to create and approve pull requests" setting that release-please needs. |
| `vulnerability_alerts` | `true` or `false`; the [endpoint](https://docs.github.com/en/rest/repos/repos#enable-vulnerability-alerts) has no body |

Where the API has nothing usable, the file differs from it:

- `branch_protection` holds the `PUT` shape, not the `GET` shape (which wraps booleans in `{"enabled": …}`). `restrictions` lists user logins, team slugs and app slugs.
- `rulesets` and `labels` are matched by name. `push` never deletes them; `sync` does.
- Environment `reviewers` are numeric IDs, as the API wants them.
- Private repos on a free plan can't have branch protection or rulesets, so `pull` leaves those sections out, and `push` and `sync` skip them.
- `pull` only records branch protection for branches that are currently protected.

JSON has no comments, so every section can have an `x-comment-<section>` sibling (for example `x-comment-repo`). They are never sent to the API, and `pull` keeps the ones you wrote. A section without one gets a link to its API docs. The diff `pull` shows names the changed section's comment in each hunk header.

### Defaults

`init` writes only settings that are the same across the maintainer's own repos: all merge methods allowed, no auto-merge, secret scanning with push protection, a `default` ruleset on the default branch (PR required with no approvals, no deletion, no force-push), a read-only workflow token, and Actions allowed to create and approve PRs. Anything that varies per repo (description, wiki, branch cleanup, labels, topics) is left out, so it stays unmanaged. Rulesets are left out for private repos.

An editor schema with a description per section is in [`repo-config.schema.json`](./repo-config.schema.json).

**Note: Your auth token will need to have appropriate access to the repo you are trying to configure.** Before filing bugs, please check the following:

- Navigate to <https://github.com/:owner/:repo/settings> and ensure you have access to administer the repo.
- Run `gh auth status` and ensure you have a valid token.

## Development

```sh
git clone git@github.com:twelvelabs/gh-repo-config.git
cd ./gh-repo-config

# Bootstrap for local development
make setup
# Test the extension
make test
# Run the extension w/out installing
make run
# Install the extension
make install
```
