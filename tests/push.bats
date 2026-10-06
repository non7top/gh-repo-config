#!/usr/bin/env bash
set -o errexit -o errtrace -o nounset -o pipefail

setup() {
    load "../vendor/bats-support/load"
    load "../vendor/bats-assert/load"
    load "helpers/common"
    setup_fake_gh
    FULL_CONFIG="${TEST_FIXTURES_DIR}/expected/repo-config.json"
    CONFIG="${BATS_TEST_TMPDIR}/repo-config.json"
}

teardown() {
    teardown_fake_gh
}

# Write a config file containing only the given top-level sections.
config_with() {
    jq "{$1}" "${FULL_CONFIG}" >"${CONFIG}"
}

@test "push: fails when the config file does not exist" {
    run ./gh-repo-config push --config "${BATS_TEST_TMPDIR}/missing.json"
    assert_failure
    assert_line --partial "not found"
}

@test "push: fails when the config file is not a JSON object" {
    echo '[]' >"${CONFIG}"
    run ./gh-repo-config push --config "${CONFIG}"
    assert_failure
    assert_line --partial "not a valid JSON object"
}

@test "push: calls the API for each section" {
    run ./gh-repo-config push --config "${FULL_CONFIG}"
    assert_success
    assert_line "[someuser/somerepo]: Configuring repo"
    assert_line "[someuser/somerepo]: Configuring repo topics"
    assert_line "[someuser/somerepo]: Configuring branch protection rules for 'main'"
    assert_line "[someuser/somerepo]: Configuring ruleset 'require pr'"
    assert_line "[someuser/somerepo]: Configuring labels"
    assert_line "[someuser/somerepo]: Configuring environment 'production'"
    assert_line "[someuser/somerepo]: Configuring Actions permissions"
    assert_line "[someuser/somerepo]: Configuring vulnerability alerts"

    run gh_calls
    assert_line --regexp '^PATCH /repos/:owner/:repo \{.*"allow_squash_merge":true'
    assert_line 'PUT /repos/:owner/:repo/topics {"names":[]}'
    assert_line --regexp '^PUT /repos/:owner/:repo/branches/main/protection \{"allow_force_pushes":false'
    assert_line --regexp '^PUT /repos/:owner/:repo/rulesets/4242 \{"name":"require pr"'
    assert_line --regexp '^POST /repos/:owner/:repo/labels \{"name":"bug"'
    assert_line --regexp '^PUT /repos/:owner/:repo/environments/production \{"wait_timer":30'
    assert_line 'PUT /repos/:owner/:repo/actions/permissions {"enabled":true,"allowed_actions":"all"}'
    assert_line 'PUT /repos/:owner/:repo/actions/permissions/workflow {"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}'
    assert_line 'PUT /repos/:owner/:repo/vulnerability-alerts '
}

@test "push: never sends x-comment fields to the API" {
    run ./gh-repo-config push --config "${FULL_CONFIG}"
    assert_success

    run gh_calls
    refute_output --partial "x-comment"
}

@test "push: only touches the sections present in the file" {
    config_with '"topics"'

    run ./gh-repo-config push --config "${CONFIG}"
    assert_success

    run gh_calls
    assert_output 'PUT /repos/:owner/:repo/topics {"names":[]}'
}

@test "push: refuses to change the default branch without the flag" {
    config_with '"repo"'
    jq '.repo.default_branch = "other"' "${CONFIG}" >"${CONFIG}.new" && mv "${CONFIG}.new" "${CONFIG}"

    run ./gh-repo-config push --config "${CONFIG}"
    assert_success
    assert_line --partial "ERROR: default_branch in repo ('other') differs from live ('main')"
    assert_line --partial "--allow-default-branch-change"

    # The PATCH still happens, without default_branch.
    run gh_calls
    assert_line --regexp '^PATCH /repos/:owner/:repo \{'
    refute_output --partial "default_branch"
}

@test "push: changes the default branch with --allow-default-branch-change" {
    config_with '"repo"'
    jq '.repo.default_branch = "other"' "${CONFIG}" >"${CONFIG}.new" && mv "${CONFIG}.new" "${CONFIG}"

    run ./gh-repo-config push --config "${CONFIG}" --allow-default-branch-change
    assert_success
    assert_line --partial "Changing default branch: 'main' -> 'other'"

    run gh_calls
    assert_output --partial '"default_branch":"other"'
}

@test "push: skips branch protection and rulesets for private repos" {
    set_api GET /repos/:owner/:repo "$(jq '.private = true' "${TEST_FIXTURES_DIR}/gh/GET__repos__owner__repo.json")"

    run ./gh-repo-config push --config "${FULL_CONFIG}"
    assert_success
    assert_line "[    warn]: Skipping branch protection: unavailable on private repos"
    assert_line "[    warn]: Skipping rulesets: unavailable on private repos"

    run gh_calls
    refute_output --partial "/protection"
    refute_output --partial "/rulesets"
    assert_output --partial "PUT /repos/:owner/:repo/topics"
}

@test "push: patches a label that exists and creates one that does not" {
    config_with '"labels"'
    jq '.labels += [{"name": "new thing", "color": "ffffff", "description": ""}]' "${CONFIG}" >"${CONFIG}.new" && mv "${CONFIG}.new" "${CONFIG}"
    set_api GET /repos/:owner/:repo/labels/bug '{"name":"bug"}'

    run ./gh-repo-config push --config "${CONFIG}"
    assert_success

    run gh_calls
    assert_line --regexp '^PATCH /repos/:owner/:repo/labels/bug \{"name":"bug"'
    assert_line --regexp '^POST /repos/:owner/:repo/labels \{"name":"new thing"'
}

@test "push: updates a ruleset by id when the name matches and creates it otherwise" {
    config_with '"rulesets"'
    jq '.rulesets += [(.rulesets[0] | .name = "brand new")]' "${CONFIG}" >"${CONFIG}.new" && mv "${CONFIG}.new" "${CONFIG}"

    run ./gh-repo-config push --config "${CONFIG}"
    assert_success

    run gh_calls
    assert_line --regexp '^PUT /repos/:owner/:repo/rulesets/4242 \{"name":"require pr"'
    assert_line --regexp '^POST /repos/:owner/:repo/rulesets \{"name":"brand new"'
}

@test "push: disables vulnerability alerts when the value is false" {
    echo '{"vulnerability_alerts": false}' >"${CONFIG}"

    run ./gh-repo-config push --config "${CONFIG}"
    assert_success

    run gh_calls
    assert_output "DELETE /repos/:owner/:repo/vulnerability-alerts "
}

@test "push: URL-encodes label and environment names" {
    cat >"${CONFIG}" <<'EOF'
{
  "labels": [{"name": "good first issue", "color": "7057ff", "description": ""}],
  "environments": {"prod eu": {"wait_timer": 0}}
}
EOF

    run ./gh-repo-config push --config "${CONFIG}"
    assert_success

    run gh_calls
    assert_line --regexp '^POST /repos/:owner/:repo/labels \{"name":"good first issue"'
    assert_line --regexp '^PUT /repos/:owner/:repo/environments/prod%20eu '
}

@test "push: --dry-run makes no changes" {
    run ./gh-repo-config push --config "${FULL_CONFIG}" --dry-run
    assert_success
    assert_line "[ dry-run]: PUT /repos/:owner/:repo/topics"

    run gh_calls
    assert_output ""
}

@test "push: ~DEFAULT_BRANCH resolves to the live default branch and other keys stay literal" {
    set_api GET /repos/:owner/:repo "$(jq '.default_branch = "2026_06_05_k8s"' "${TEST_FIXTURES_DIR}/gh/GET__repos__owner__repo.json")"
    jq '{branch_protection: (.branch_protection + {"release/1": .branch_protection["~DEFAULT_BRANCH"]})}' "${FULL_CONFIG}" >"${CONFIG}"

    run ./gh-repo-config push --config "${CONFIG}"
    assert_success
    assert_line "[someuser/somerepo]: Configuring branch protection rules for '2026_06_05_k8s'"
    assert_line "[someuser/somerepo]: Configuring branch protection rules for 'release/1'"

    run gh_calls
    assert_line --regexp '^PUT /repos/:owner/:repo/branches/2026_06_05_k8s/protection '
    assert_line --regexp '^PUT /repos/:owner/:repo/branches/release/1/protection '
    refute_output --partial "~DEFAULT_BRANCH"
}

@test "push: pull then push sends back exactly what was pulled" {
    run ./gh-repo-config pull --config "${CONFIG}"
    assert_success

    run ./gh-repo-config push --config "${CONFIG}"
    assert_success

    run gh_calls
    assert_line "PUT /repos/:owner/:repo/branches/main/protection $(jq -c '.branch_protection["~DEFAULT_BRANCH"]' "${CONFIG}")"
    assert_line "PUT /repos/:owner/:repo/rulesets/4242 $(jq -c '.rulesets[0]' "${CONFIG}")"
    assert_line "PUT /repos/:owner/:repo/topics $(jq -c '.topics' "${CONFIG}")"
    assert_line "PUT /repos/:owner/:repo/environments/production $(jq -c '.environments.production' "${CONFIG}")"
}

@test "push: keeps every log line when stderr is redirected to a file" {
    run bash -c './gh-repo-config push --config "$1" --dry-run 2>"$2"' _ "${FULL_CONFIG}" "${BATS_TEST_TMPDIR}/stderr.log"
    assert_success

    run cat "${BATS_TEST_TMPDIR}/stderr.log"
    assert_line "[someuser/somerepo]: Configuring repo"
    assert_line "[someuser/somerepo]: Configuring vulnerability alerts"
}
