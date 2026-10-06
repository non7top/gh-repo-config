#!/usr/bin/env bash
set -o errexit -o errtrace -o nounset -o pipefail

setup() {
    load "../vendor/bats-support/load"
    load "../vendor/bats-assert/load"
    load "../vendor/bats-file/load"
    load "helpers/common"
    setup_fake_gh
    CONFIG="${BATS_TEST_TMPDIR}/.github/repo-config.json"
}

teardown() {
    teardown_fake_gh
}

@test "init: writes the defaults, creating intermediate dirs" {
    run ./gh-repo-config init --config "${CONFIG}"
    assert_success
    assert_file_exist "${CONFIG}"

    run jq -c '[.repo.allow_merge_commit, .rulesets[0].name, .actions.workflow.can_approve_pull_request_reviews]' "${CONFIG}"
    assert_output '[true,"default",true]'
}

@test "init: the default ruleset targets the default branch whatever its name" {
    run ./gh-repo-config init --config "${CONFIG}"
    assert_success

    run jq -c '.rulesets[0] | [.conditions.ref_name.include, [.rules[].type]]' "${CONFIG}"
    assert_output '[["~DEFAULT_BRANCH"],["deletion","non_fast_forward","pull_request"]]'
}

@test "init: leaves out settings that differ between repos" {
    run ./gh-repo-config init --config "${CONFIG}"
    assert_success

    run jq -c '[.repo | has("description"), has("homepage"), has("default_branch"), has("has_wiki"), has("delete_branch_on_merge")]' "${CONFIG}"
    assert_output "[false,false,false,false,false]"
    run jq -c '[has("topics"), has("labels"), has("environments"), has("branch_protection"), has("vulnerability_alerts")]' "${CONFIG}"
    assert_output "[false,false,false,false,false]"
}

@test "init: every section has an x-comment" {
    run ./gh-repo-config init --config "${CONFIG}"
    assert_success

    run jq -r '. as $d | [keys[] | select(startswith("x-comment-") | not)] | map(select($d["x-comment-" + .] == null)) | length' "${CONFIG}"
    assert_output "0"
}

@test "init: leaves out rulesets for private repos" {
    set_api GET /repos/:owner/:repo "$(jq '.private = true' "${TEST_FIXTURES_DIR}/gh/GET__repos__owner__repo.json")"

    run ./gh-repo-config init --config "${CONFIG}"
    assert_success
    assert_line "[    warn]: Leaving out rulesets: unavailable on private repos"
    run jq -c '[has("rulesets"), has("x-comment-rulesets")]' "${CONFIG}"
    assert_output "[false,false]"
}

@test "init: refuses to overwrite an existing file" {
    mkdir -p "$(dirname "${CONFIG}")"
    echo '{"mine": true}' >"${CONFIG}"

    run ./gh-repo-config init --config "${CONFIG}"
    assert_failure
    assert_line --partial "already exists"
    run jq -r '.mine' "${CONFIG}"
    assert_output "true"
}

@test "init: --dry-run does not write the file" {
    run ./gh-repo-config init --config "${CONFIG}" --dry-run
    assert_success
    assert_line --partial "would create ${CONFIG}"
    assert_file_not_exist "${CONFIG}"
}

@test "init: the generated file can be pushed" {
    run ./gh-repo-config init --config "${CONFIG}"
    assert_success

    run ./gh-repo-config push --config "${CONFIG}"
    assert_success

    run gh_calls
    assert_line --regexp '^PATCH /repos/:owner/:repo \{"allow_auto_merge":false'
    assert_line --regexp '^POST /repos/:owner/:repo/rulesets \{"name":"default"'
    assert_line 'PUT /repos/:owner/:repo/actions/permissions/workflow {"default_workflow_permissions":"read","can_approve_pull_request_reviews":true}'
    refute_output --partial "x-comment"
}
