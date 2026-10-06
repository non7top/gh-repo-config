#!/usr/bin/env bash
set -o errexit -o errtrace -o nounset -o pipefail

setup() {
    load "../vendor/bats-support/load"
    load "../vendor/bats-assert/load"
    load "../vendor/bats-file/load"
    load "../vendor/bats-mock/load"

    TEST_TEMP_DIR="$(temp_make)"
    # Transform tempdir paths in the test output to make it easier to read
    # See: https://github.com/ztombol/bats-file#transforming-displayed-paths
    export BATSLIB_FILE_PATH_REM="#${TEST_TEMP_DIR}"
    export BATSLIB_FILE_PATH_ADD="<temp>"

    TEST_FIXTURES_DIR="$(dirname "$BATS_TEST_FILENAME")/fixtures"
}

teardown() {
    temp_del "$TEST_TEMP_DIR"
}

# Create a gh mock pre-loaded with standard API responses for the 5 init calls:
#   1: GET /repos/:owner/:repo
#   2: GET /repos/:owner/:repo/topics
#   3: GET /repos/:owner/:repo/branches/{default_branch}/protection
#   4: GET /repos/:owner/:repo/labels (--paginate)
#   5: GET /repos/:owner/:repo/environments
setup_init_mock() {
    local gh
    gh="$(mock_create)"
    mock_set_output "${gh}" "$(cat "${TEST_FIXTURES_DIR}/api-responses/repo.json")" 1
    mock_set_output "${gh}" "$(cat "${TEST_FIXTURES_DIR}/api-responses/topics.json")" 2
    mock_set_output "${gh}" "$(cat "${TEST_FIXTURES_DIR}/api-responses/branch-protection.json")" 3
    mock_set_output "${gh}" "$(cat "${TEST_FIXTURES_DIR}/api-responses/labels.json")" 4
    mock_set_output "${gh}" '{"total_count":0,"environments":[]}' 5
    printf '%s' "${gh}"
}

@test "init: should create intermediate dirs if needed" {
    local gh
    gh="$(setup_init_mock)"
    mkdir "${TEST_TEMP_DIR}/foo"
    _GH="${gh}" run ./gh-repo-config init --config "${TEST_TEMP_DIR}/foo/bar/baz"
    assert_success
    assert_dir_exists "${TEST_TEMP_DIR}/foo/bar/baz"
}

@test "init: should generate files from live API data" {
    local gh
    gh="$(setup_init_mock)"
    _GH="${gh}" run ./gh-repo-config init --config "${TEST_TEMP_DIR}"
    assert_success

    assert_file_exist "${TEST_TEMP_DIR}/repo.json"
    assert_files_equal \
        "${TEST_TEMP_DIR}/repo.json" \
        "${TEST_FIXTURES_DIR}/expected/repo.json"

    assert_file_exist "${TEST_TEMP_DIR}/topics.json"
    assert_files_equal \
        "${TEST_TEMP_DIR}/topics.json" \
        "${TEST_FIXTURES_DIR}/expected/topics.json"

    # Must use the live default branch name as the source for branch protection,
    # and write it under the special "default" filename (not the literal branch name).
    assert_file_exist "${TEST_TEMP_DIR}/branch-protection/default.json"
    assert_files_equal \
        "${TEST_TEMP_DIR}/branch-protection/default.json" \
        "${TEST_FIXTURES_DIR}/expected/branch-protection/default.json"

    assert_file_exist "${TEST_TEMP_DIR}/labels.json"
    assert_files_equal \
        "${TEST_TEMP_DIR}/labels.json" \
        "${TEST_FIXTURES_DIR}/expected/labels.json"
}

@test "init: should generate environments from live API data" {
    local gh
    gh="$(mock_create)"
    mock_set_output "${gh}" "$(cat "${TEST_FIXTURES_DIR}/api-responses/repo.json")" 1
    mock_set_output "${gh}" "$(cat "${TEST_FIXTURES_DIR}/api-responses/topics.json")" 2
    mock_set_output "${gh}" "$(cat "${TEST_FIXTURES_DIR}/api-responses/branch-protection.json")" 3
    mock_set_output "${gh}" "$(cat "${TEST_FIXTURES_DIR}/api-responses/labels.json")" 4
    mock_set_output "${gh}" "$(cat "${TEST_FIXTURES_DIR}/api-responses/environments.json")" 5

    _GH="${gh}" run ./gh-repo-config init --config "${TEST_TEMP_DIR}"
    assert_success

    assert_file_exist "${TEST_TEMP_DIR}/environments/production.json"
    assert_files_equal \
        "${TEST_TEMP_DIR}/environments/production.json" \
        "${TEST_FIXTURES_DIR}/expected/environments/production.json"
}

@test "init: repo.json contains the actual default branch from the API" {
    local gh
    # Return a repo where default_branch is NOT main
    local custom_repo_json
    custom_repo_json=$(jq '.default_branch = "2026_06_05_k8s"' \
        "${TEST_FIXTURES_DIR}/api-responses/repo.json")

    gh="$(mock_create)"
    mock_set_output "${gh}" "${custom_repo_json}" 1
    mock_set_output "${gh}" "$(cat "${TEST_FIXTURES_DIR}/api-responses/topics.json")" 2
    mock_set_output "${gh}" "$(cat "${TEST_FIXTURES_DIR}/api-responses/branch-protection.json")" 3
    mock_set_output "${gh}" "$(cat "${TEST_FIXTURES_DIR}/api-responses/labels.json")" 4
    mock_set_output "${gh}" '{"total_count":0,"environments":[]}' 5

    _GH="${gh}" run ./gh-repo-config init --config "${TEST_TEMP_DIR}"
    assert_success

    # repo.json must reflect the real default branch, not a hardcoded "main"
    run jq -r '.default_branch' "${TEST_TEMP_DIR}/repo.json"
    assert_output "2026_06_05_k8s"

    # branch-protection file must always be named "default", not the branch name
    assert_file_exist "${TEST_TEMP_DIR}/branch-protection/default.json"
    assert_file_not_exist "${TEST_TEMP_DIR}/branch-protection/2026_06_05_k8s.json"
    assert_file_not_exist "${TEST_TEMP_DIR}/branch-protection/main.json"
}

@test "init: should prompt if repo.json already exists" {
    local gh
    gh="$(setup_init_mock)"
    echo "EXISTING" >"${TEST_TEMP_DIR}/repo.json"

    _GH="${gh}" run ./gh-repo-config init --config "${TEST_TEMP_DIR}" <<<"N"

    assert_line "[    warn]: ${TEST_TEMP_DIR}/repo.json already exists!"
    assert_line "[    keep]: ${TEST_TEMP_DIR}/repo.json"
    assert_file_contains "${TEST_TEMP_DIR}/repo.json" "EXISTING"
}

@test "init: should prompt if topics.json already exists" {
    local gh
    gh="$(setup_init_mock)"
    echo "EXISTING" >"${TEST_TEMP_DIR}/topics.json"

    _GH="${gh}" run ./gh-repo-config init --config "${TEST_TEMP_DIR}" <<<"N"

    assert_line "[    warn]: ${TEST_TEMP_DIR}/topics.json already exists!"
    assert_line "[    keep]: ${TEST_TEMP_DIR}/topics.json"
    assert_file_contains "${TEST_TEMP_DIR}/topics.json" "EXISTING"
}

@test "init: should prompt if branch-protection/default.json already exists" {
    local gh
    gh="$(setup_init_mock)"
    mkdir -p "${TEST_TEMP_DIR}/branch-protection"
    echo "EXISTING" >"${TEST_TEMP_DIR}/branch-protection/default.json"

    _GH="${gh}" run ./gh-repo-config init --config "${TEST_TEMP_DIR}" <<<"N"

    assert_line "[    warn]: ${TEST_TEMP_DIR}/branch-protection/default.json already exists!"
    assert_line "[    keep]: ${TEST_TEMP_DIR}/branch-protection/default.json"
    assert_file_contains "${TEST_TEMP_DIR}/branch-protection/default.json" "EXISTING"
}

@test "init: should skip branch protection when none configured" {
    local gh
    gh="$(mock_create)"
    mock_set_output "${gh}" "$(cat "${TEST_FIXTURES_DIR}/api-responses/repo.json")" 1
    mock_set_output "${gh}" "$(cat "${TEST_FIXTURES_DIR}/api-responses/topics.json")" 2
    # Call 3 (branch protection) returns non-zero to simulate 404
    mock_set_status "${gh}" 1 3
    mock_set_output "${gh}" "$(cat "${TEST_FIXTURES_DIR}/api-responses/labels.json")" 4
    mock_set_output "${gh}" '{"total_count":0,"environments":[]}' 5

    _GH="${gh}" run ./gh-repo-config init --config "${TEST_TEMP_DIR}"
    assert_success
    assert_line --partial "No branch protection rules found for 'main'"
    assert_file_not_exist "${TEST_TEMP_DIR}/branch-protection/default.json"
}

@test "init: repo.json carries extended security_and_analysis and merge commit fields" {
    local gh extended
    extended=$(jq '
        .has_discussions = true
        | .merge_commit_title = "MERGE_MESSAGE"
        | .merge_commit_message = "PR_TITLE"
        | .security_and_analysis += {
            "secret_scanning_push_protection": {"status": "enabled"},
            "dependabot_security_updates": {"status": "disabled"}
        }' "${TEST_FIXTURES_DIR}/api-responses/repo.json")

    gh="$(mock_create)"
    mock_set_output "${gh}" "${extended}" 1
    mock_set_output "${gh}" "$(cat "${TEST_FIXTURES_DIR}/api-responses/topics.json")" 2
    mock_set_output "${gh}" "$(cat "${TEST_FIXTURES_DIR}/api-responses/branch-protection.json")" 3
    mock_set_output "${gh}" "$(cat "${TEST_FIXTURES_DIR}/api-responses/labels.json")" 4
    mock_set_output "${gh}" '{"total_count":0,"environments":[]}' 5

    _GH="${gh}" run ./gh-repo-config init --config "${TEST_TEMP_DIR}"
    assert_success

    run jq -c '[.has_discussions, .merge_commit_title, .merge_commit_message, .security_and_analysis.secret_scanning_push_protection.status, .security_and_analysis.dependabot_security_updates.status]' "${TEST_TEMP_DIR}/repo.json"
    assert_output '[true,"MERGE_MESSAGE","PR_TITLE","enabled","disabled"]'
}

@test "init: private repos skip branch protection" {
    local gh private_repo_json
    private_repo_json=$(jq '.private = true' "${TEST_FIXTURES_DIR}/api-responses/repo.json")

    gh="$(mock_create)"
    mock_set_output "${gh}" "${private_repo_json}" 1
    mock_set_output "${gh}" "$(cat "${TEST_FIXTURES_DIR}/api-responses/topics.json")" 2
    mock_set_output "${gh}" "$(cat "${TEST_FIXTURES_DIR}/api-responses/labels.json")" 3
    mock_set_output "${gh}" '{"total_count":0,"environments":[]}' 4

    _GH="${gh}" run ./gh-repo-config init --config "${TEST_TEMP_DIR}"
    assert_success
    assert_line --partial "Skipping branch protection: unavailable on private repos"
    assert_file_not_exist "${TEST_TEMP_DIR}/branch-protection/default.json"

    # No protection endpoint was called.
    run mock_get_call_num "${gh}"
    assert_output "4"
}
