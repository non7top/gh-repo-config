#!/usr/bin/env bash
set -o errexit -o errtrace -o nounset -o pipefail

setup() {
    load "../vendor/bats-support/load"
    load "../vendor/bats-assert/load"
    load "helpers/common"
    setup_fake_gh
    FULL_CONFIG="${TEST_FIXTURES_DIR}/expected/repo-config.json"
    CONFIG="${BATS_TEST_TMPDIR}/repo-config.json"

    # Live state has one extra of everything that the config file lacks.
    set_api GET /repos/:owner/:repo/labels '[
        {"name":"bug","color":"d73a4a","description":"Something isn'"'"'t working"},
        {"name":"stale thing","color":"ffffff","description":""}
    ]'
    set_api GET /repos/:owner/:repo/rulesets '[
        {"id":4242,"name":"require pr"},
        {"id":9,"name":"old rule"}
    ]'
    set_api GET /repos/:owner/:repo/rulesets/9 "$(jq '.id = 9 | .name = "old rule"' \
        "${TEST_FIXTURES_DIR}/gh/GET__repos__owner__repo__rulesets__4242.json")"
    set_api GET /repos/:owner/:repo/environments "$(jq '
        .total_count = 2
        | .environments += [(.environments[0] | .name = "staging")]
    ' "${TEST_FIXTURES_DIR}/gh/GET__repos__owner__repo__environments.json")"
    set_api GET /repos/:owner/:repo/branches '[
        {"name":"main","protected":true},
        {"name":"release/1","protected":true}
    ]'
    cp "${TEST_FIXTURES_DIR}/gh/GET__repos__owner__repo__branches__main__protection.json" \
        "${FAKE_GH_FIXTURES}/GET__repos__owner__repo__branches__release__1__protection.json"
}

teardown() {
    teardown_fake_gh
}

@test "sync: with --yes pushes, then deletes what the file does not list" {
    run ./gh-repo-config sync --config "${FULL_CONFIG}" --yes
    assert_success
    assert_line "  - label stale thing"
    assert_line "  - ruleset old rule"
    assert_line "  - environment staging"
    assert_line "  - branch protection release/1"

    run gh_calls
    assert_line 'DELETE /repos/:owner/:repo/labels/stale%20thing '
    assert_line 'DELETE /repos/:owner/:repo/rulesets/9 '
    assert_line 'DELETE /repos/:owner/:repo/environments/staging '
    assert_line 'DELETE /repos/:owner/:repo/branches/release/1/protection '
    assert_line --regexp '^PUT /repos/:owner/:repo/topics '

    # Anything the file lists is kept.
    refute_output --partial "DELETE /repos/:owner/:repo/labels/bug"
    refute_output --partial "DELETE /repos/:owner/:repo/rulesets/4242"
    refute_output --partial "DELETE /repos/:owner/:repo/environments/production"
    refute_output --partial "DELETE /repos/:owner/:repo/branches/main/protection"
}

@test "sync: deletes nothing and writes nothing when the prompt is declined" {
    run ./gh-repo-config sync --config "${FULL_CONFIG}" <<<"N"
    assert_failure
    assert_line "Aborted."

    run gh_calls
    assert_output ""
}

@test "sync: proceeds when the prompt is accepted" {
    run ./gh-repo-config sync --config "${FULL_CONFIG}" <<<"y"
    assert_success

    run gh_calls
    assert_output --partial "DELETE /repos/:owner/:repo/rulesets/9"
}

@test "sync: --dry-run lists the deletions and changes nothing" {
    run ./gh-repo-config sync --config "${FULL_CONFIG}" --dry-run
    assert_success
    assert_line "  - ruleset old rule"
    assert_line "[ dry-run]: DELETE /repos/:owner/:repo/rulesets/9"

    run gh_calls
    assert_output ""
}

@test "sync: leaves sections the file does not have alone" {
    jq '{labels}' "${FULL_CONFIG}" >"${CONFIG}"

    run ./gh-repo-config sync --config "${CONFIG}" --yes
    assert_success

    run gh_calls
    assert_line 'DELETE /repos/:owner/:repo/labels/stale%20thing '
    refute_output --partial "/rulesets/9"
    refute_output --partial "/environments/staging"
    refute_output --partial "/protection"
}

@test "sync: an empty section deletes everything live in it" {
    jq '{environments: {}}' "${FULL_CONFIG}" >"${CONFIG}"

    run ./gh-repo-config sync --config "${CONFIG}" --yes
    assert_success

    run gh_calls
    assert_line 'DELETE /repos/:owner/:repo/environments/production '
    assert_line 'DELETE /repos/:owner/:repo/environments/staging '
}

@test "sync: never prunes branch protection or rulesets on private repos" {
    set_api GET /repos/:owner/:repo "$(jq '.private = true' "${TEST_FIXTURES_DIR}/gh/GET__repos__owner__repo.json")"

    run ./gh-repo-config sync --config "${FULL_CONFIG}" --yes
    assert_success

    run gh_calls
    assert_output --partial "DELETE /repos/:owner/:repo/labels/stale%20thing"
    refute_output --partial "/protection"
    refute_output --partial "/rulesets"
}

@test "sync: asks nothing when there is nothing to delete" {
    set_api GET /repos/:owner/:repo/labels "$(jq '.' "${TEST_FIXTURES_DIR}/gh/GET__repos__owner__repo__labels.json")"
    set_api GET /repos/:owner/:repo/rulesets "$(jq '.' "${TEST_FIXTURES_DIR}/gh/GET__repos__owner__repo__rulesets.json")"
    set_api GET /repos/:owner/:repo/environments "$(jq '.' "${TEST_FIXTURES_DIR}/gh/GET__repos__owner__repo__environments.json")"
    set_api GET /repos/:owner/:repo/branches "$(jq '.' "${TEST_FIXTURES_DIR}/gh/GET__repos__owner__repo__branches.json")"

    run ./gh-repo-config sync --config "${FULL_CONFIG}" </dev/null
    assert_success

    run gh_calls
    refute_output --partial "DELETE"
}

@test "sync: --dry-run diff shows what would be deleted" {
    run ./gh-repo-config sync --config "${FULL_CONFIG}" --dry-run
    assert_success
    assert_line --regexp '^-.*"name": "stale thing"'
    assert_line --regexp '^-.*"name": "old rule"'
    assert_line --regexp '^-.*"staging": \{'
    assert_line --regexp '^-.*"release/1": \{'
}
