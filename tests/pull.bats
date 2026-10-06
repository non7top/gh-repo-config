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

@test "pull: writes the live settings, creating intermediate dirs" {
    run ./gh-repo-config pull --config "${CONFIG}"
    assert_success
    assert_files_equal "${CONFIG}" "${TEST_FIXTURES_DIR}/expected/repo-config.json"
}

@test "pull: is a no-op when nothing changed" {
    run ./gh-repo-config pull --config "${CONFIG}"
    assert_success

    run ./gh-repo-config pull --config "${CONFIG}"
    assert_success
    assert_line --partial "(unchanged)"
}

@test "pull: keeps custom x-comment values and shows them in the diff hunk header" {
    jq '.["x-comment-repo"] = "my note" | .repo.description = "stale"' \
        "${TEST_FIXTURES_DIR}/expected/repo-config.json" >"${BATS_TEST_TMPDIR}/in.json"
    mkdir -p "$(dirname "${CONFIG}")"
    cp "${BATS_TEST_TMPDIR}/in.json" "${CONFIG}"

    run ./gh-repo-config pull --config "${CONFIG}" --yes
    assert_success

    # The comment is not a change; it labels the hunk, and only the stale description differs.
    assert_line --regexp '^@@ .* @@ "x-comment-repo": "my note",$'
    assert_line '-    "description": "stale",'
    refute_output --partial '-  "x-comment-repo"'
    run jq -c '[.["x-comment-repo"], .repo.description]' "${CONFIG}"
    assert_output '["my note",""]'
}

@test "pull: seeds a default x-comment for sections that have none" {
    jq 'with_entries(select(.key | startswith("x-comment-") | not))' \
        "${TEST_FIXTURES_DIR}/expected/repo-config.json" >"${BATS_TEST_TMPDIR}/in.json"
    mkdir -p "$(dirname "${CONFIG}")"
    cp "${BATS_TEST_TMPDIR}/in.json" "${CONFIG}"

    run ./gh-repo-config pull --config "${CONFIG}" --yes
    assert_success
    assert_line --partial '+  "x-comment-repo": "https://docs.github.com/'
}

@test "pull: asks before overwriting and keeps the file on N" {
    mkdir -p "$(dirname "${CONFIG}")"
    echo '{"repo": {"description": "mine"}}' >"${CONFIG}"

    run ./gh-repo-config pull --config "${CONFIG}" <<<"N"
    assert_success
    assert_line "[    keep]: ${CONFIG}"
    run jq -r '.repo.description' "${CONFIG}"
    assert_output "mine"
}

@test "pull: overwrites on Y" {
    mkdir -p "$(dirname "${CONFIG}")"
    echo '{"repo": {"description": "mine"}}' >"${CONFIG}"

    run ./gh-repo-config pull --config "${CONFIG}" <<<"Y"
    assert_success
    assert_files_equal "${CONFIG}" "${TEST_FIXTURES_DIR}/expected/repo-config.json"
}

@test "pull: --dry-run does not write the file" {
    run ./gh-repo-config pull --config "${CONFIG}" --dry-run
    assert_success
    assert_line --partial "would create ${CONFIG}"
    assert_file_not_exist "${CONFIG}"
}

@test "pull: leaves out branch protection and rulesets for private repos" {
    set_api GET /repos/:owner/:repo "$(jq '.private = true' "${TEST_FIXTURES_DIR}/gh/GET__repos__owner__repo.json")"

    run ./gh-repo-config pull --config "${CONFIG}"
    assert_success
    assert_line --partial "Skipping branch protection and rulesets: unavailable on private repos"
    run jq -c '[has("branch_protection"), has("rulesets"), has("x-comment-branch_protection")]' "${CONFIG}"
    assert_output "[false,false,false]"
}

@test "pull: records protection for every protected branch, keyed by branch name" {
    set_api GET /repos/:owner/:repo/branches '[{"name":"main","protected":true},{"name":"release/1","protected":true},{"name":"dev","protected":false}]'
    cp "${TEST_FIXTURES_DIR}/gh/GET__repos__owner__repo__branches__main__protection.json" \
        "${FAKE_GH_FIXTURES}/GET__repos__owner__repo__branches__release__1__protection.json"

    run ./gh-repo-config pull --config "${CONFIG}"
    assert_success
    run jq -c '.branch_protection | keys' "${CONFIG}"
    assert_output '["main","release/1"]'
}

@test "pull: uses empty sections when a public repo has no protection or rulesets" {
    set_api GET /repos/:owner/:repo/branches '[{"name":"main","protected":false}]'
    set_api GET /repos/:owner/:repo/rulesets '[]'

    run ./gh-repo-config pull --config "${CONFIG}"
    assert_success
    run jq -c '[.branch_protection, .rulesets]' "${CONFIG}"
    assert_output "[{},[]]"
}

@test "pull: vulnerability_alerts is false when the endpoint 404s" {
    unset_api GET /repos/:owner/:repo/vulnerability-alerts

    run ./gh-repo-config pull --config "${CONFIG}"
    assert_success
    run jq -r '.vulnerability_alerts' "${CONFIG}"
    assert_output "false"
}

@test "pull: leaves out actions when the endpoints are unavailable" {
    unset_api GET /repos/:owner/:repo/actions/permissions

    run ./gh-repo-config pull --config "${CONFIG}"
    assert_success
    run jq -r 'has("actions")' "${CONFIG}"
    assert_output "false"
}

@test "pull: the repo section carries the actual default branch" {
    set_api GET /repos/:owner/:repo "$(jq '.default_branch = "2026_06_05_k8s"' "${TEST_FIXTURES_DIR}/gh/GET__repos__owner__repo.json")"
    set_api GET /repos/:owner/:repo/branches '[{"name":"2026_06_05_k8s","protected":true}]'
    cp "${TEST_FIXTURES_DIR}/gh/GET__repos__owner__repo__branches__main__protection.json" \
        "${FAKE_GH_FIXTURES}/GET__repos__owner__repo__branches__2026_06_05_k8s__protection.json"

    run ./gh-repo-config pull --config "${CONFIG}"
    assert_success
    run jq -r '.repo.default_branch, (.branch_protection | keys[])' "${CONFIG}"
    assert_output "2026_06_05_k8s"$'\n'"2026_06_05_k8s"
}

@test "pull: a label without a description is written with an empty one" {
    set_api GET /repos/:owner/:repo/labels '[{"name":"autorelease: pending","color":"ededed","description":null}]'

    run ./gh-repo-config pull --config "${CONFIG}"
    assert_success
    run jq -c '.labels' "${CONFIG}"
    assert_output '[{"name":"autorelease: pending","color":"ededed","description":""}]'
}
