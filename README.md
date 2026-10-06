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

Navigate to the repo you would like to configure and run:

```sh
gh repo-config init
```

This will generate a number of files in .github/config:

```text
.github/config/
├── branch-protection
│   └── main.json
├── topics.json
└── repo.json
```

The files are generated from the repo's live settings (plus `actions.json`, `environments/`, `labels.json`, `rulesets/` and `security.json` when present). They are API payloads for the following endpoints:

- `./repo.json`: [Update repository](https://docs.github.com/en/rest/repos/repos#update-a-repository)
- `./topics.json`: [Replace repository topics](https://docs.github.com/en/rest/repos/repos#replace-all-repository-topics)
- `./branch-protection/${name}.json`: [Update branch protection](https://docs.github.com/en/rest/branches/branch-protection#update-branch-protection). `default.json` targets the live default branch.
- `./rulesets/${name}.json`: [Create](https://docs.github.com/en/rest/repos/rules#create-a-repository-ruleset) or [update](https://docs.github.com/en/rest/repos/rules#update-a-repository-ruleset) a ruleset, matched by `name`
- `./labels.json`: [Labels](https://docs.github.com/en/rest/issues/labels), created or updated, never deleted
- `./environments/${name}.json`: [Create or update an environment](https://docs.github.com/en/rest/deployments/environments#create-or-update-an-environment)
- `./actions.json`: [Actions permissions](https://docs.github.com/en/rest/actions/permissions), including whether Actions can create and approve pull requests (needed by release-please)
- `./security.json`: [Vulnerability alerts](https://docs.github.com/en/rest/repos/repos#enable-vulnerability-alerts)

Private repos on a free plan can't have branch protection or rulesets, so `init` and `apply` skip both for them.

Edit the default values to your liking. To apply the settings, run:

```sh
gh repo-config apply
```

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
