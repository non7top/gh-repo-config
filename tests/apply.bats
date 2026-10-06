#!/usr/bin/env bash
set -o errexit -o errtrace -o nounset -o pipefail

setup() {
    load "../vendor/bats-support/load"
    load "../vendor/bats-assert/load"
    load "../vendor/bats-mock/load"

    TEST_FIXTURES_DIR="$(dirname "$BATS_TEST_FILENAME")/fixtures"
}

@test "apply: makes api calls for each file in the config directory" {
    gh="$(mock_create)"
    mock_set_output "${gh}" "someuser/somerepo" 1
    # Call 2: GET /repos/:owner/:repo for live default_branch
    mock_set_output "${gh}" "main" 2

    _GH="${gh}" run ./gh-repo-config apply --config "${TEST_FIXTURES_DIR}"

    assert_success
    assert_line "[someuser/somerepo]: Configuring repo"
    assert_line "[someuser/somerepo]: Configuring repo topics"

    call1=$(mock_get_call_args "${gh}" 1)
    assert_regex \
        "${call1}" \
        "repo view"

    call2=$(mock_get_call_args "${gh}" 2)
    assert_regex \
        "${call2}" \
        "api /repos/:owner/:repo"

    call3=$(mock_get_call_args "${gh}" 3)
    assert_regex \
        "${call3}" \
        "api -X PATCH /repos/:owner/:repo --input=${TEST_FIXTURES_DIR}/repo.json"

    call4=$(mock_get_call_args "${gh}" 4)
    assert_regex \
        "${call4}" \
        "api -X PUT /repos/:owner/:repo/topics --input=${TEST_FIXTURES_DIR}/topics.json"

    call5=$(mock_get_call_args "${gh}" 5)
    assert_regex \
        "${call5}" \
        "api -X PUT /repos/:owner/:repo/branches/main/protection --input=${TEST_FIXTURES_DIR}/branch-protection/main.json"

    call6=$(mock_get_call_args "${gh}" 6)
    assert_regex \
        "${call6}" \
        "api -X PUT /repos/:owner/:repo/branches/prod/protection --input=${TEST_FIXTURES_DIR}/branch-protection/prod.json"
}

@test "apply: branch-protection/default.json is resolved to the live default branch" {
    local config_dir
    config_dir="$(mktemp -d)"
    mkdir -p "${config_dir}/branch-protection"
    cp "${TEST_FIXTURES_DIR}/branch-protection/main.json" "${config_dir}/branch-protection/default.json"

    gh="$(mock_create)"
    mock_set_output "${gh}" "someuser/somerepo" 1
    mock_set_output "${gh}" "actual-default" 2

    _GH="${gh}" run ./gh-repo-config apply --config "${config_dir}"
    assert_success

    call3=$(mock_get_call_args "${gh}" 3)
    assert_regex \
        "${call3}" \
        "api -X PUT /repos/:owner/:repo/branches/actual-default/protection"

    rm -rf "${config_dir}"
}

@test "apply: default_branch change guard refuses without flag" {
    local config_dir
    config_dir="$(mktemp -d)"
    # repo.json says default_branch is "other", but live is "main"
    jq '.default_branch = "other"' "${TEST_FIXTURES_DIR}/repo.json" >"${config_dir}/repo.json"

    gh="$(mock_create)"
    mock_set_output "${gh}" "someuser/somerepo" 1
    mock_set_output "${gh}" "main" 2

    _GH="${gh}" run ./gh-repo-config apply --config "${config_dir}"
    assert_success

    # Error about the mismatch must appear
    assert_line --partial "ERROR: default_branch in repo.json ('other') differs from live ('main')"
    assert_line --partial "--allow-default-branch-change"

    # The PATCH still happens — just without default_branch (via --input=-)
    call3=$(mock_get_call_args "${gh}" 3)
    assert_regex \
        "${call3}" \
        "api -X PATCH /repos/:owner/:repo --input=-"

    rm -rf "${config_dir}"
}

@test "apply: default_branch change is allowed with --allow-default-branch-change" {
    local config_dir
    config_dir="$(mktemp -d)"
    jq '.default_branch = "other"' "${TEST_FIXTURES_DIR}/repo.json" >"${config_dir}/repo.json"

    gh="$(mock_create)"
    mock_set_output "${gh}" "someuser/somerepo" 1
    mock_set_output "${gh}" "main" 2

    _GH="${gh}" run ./gh-repo-config apply --config "${config_dir}" --allow-default-branch-change
    assert_success

    # Should log the branch change
    assert_line --partial "Changing default branch: 'main' -> 'other'"

    # The PATCH uses the original file (not stripped)
    call3=$(mock_get_call_args "${gh}" 3)
    assert_regex \
        "${call3}" \
        "api -X PATCH /repos/:owner/:repo --input=${config_dir}/repo.json"

    rm -rf "${config_dir}"
}

@test "apply: labels are upserted (create new, update existing)" {
    local config_dir
    config_dir="$(mktemp -d)"
    cp "${TEST_FIXTURES_DIR}/labels.json" "${config_dir}/"

    gh="$(mock_create)"
    mock_set_output "${gh}" "someuser/somerepo" 1
    mock_set_output "${gh}" "main" 2
    # Call 3: GET /repos/:owner/:repo/labels/bug — returns success (label exists)
    mock_set_output "${gh}" '{"name":"bug"}' 3

    _GH="${gh}" run ./gh-repo-config apply --config "${config_dir}"
    assert_success

    assert_line "[someuser/somerepo]: Configuring labels"

    # Should PATCH the existing label
    call4=$(mock_get_call_args "${gh}" 4)
    assert_regex \
        "${call4}" \
        "api -X PATCH /repos/:owner/:repo/labels/bug"

    rm -rf "${config_dir}"
}

@test "apply: labels are created when they do not exist" {
    local config_dir
    config_dir="$(mktemp -d)"
    cp "${TEST_FIXTURES_DIR}/labels.json" "${config_dir}/"

    gh="$(mock_create)"
    mock_set_output "${gh}" "someuser/somerepo" 1
    mock_set_output "${gh}" "main" 2
    # Call 3: GET /repos/:owner/:repo/labels/bug — returns failure (label missing)
    mock_set_status "${gh}" 1 3

    _GH="${gh}" run ./gh-repo-config apply --config "${config_dir}"
    assert_success

    # Should POST a new label
    call4=$(mock_get_call_args "${gh}" 4)
    assert_regex \
        "${call4}" \
        "api -X POST /repos/:owner/:repo/labels"

    rm -rf "${config_dir}"
}

@test "apply: environments are applied via PUT" {
    local config_dir
    config_dir="$(mktemp -d)"
    mkdir -p "${config_dir}/environments"
    cp "${TEST_FIXTURES_DIR}/environments/production.json" "${config_dir}/environments/"

    gh="$(mock_create)"
    mock_set_output "${gh}" "someuser/somerepo" 1
    mock_set_output "${gh}" "main" 2

    _GH="${gh}" run ./gh-repo-config apply --config "${config_dir}"
    assert_success

    assert_line "[someuser/somerepo]: Configuring environment 'production'"

    call3=$(mock_get_call_args "${gh}" 3)
    assert_regex \
        "${call3}" \
        "api -X PUT /repos/:owner/:repo/environments/production --input=${config_dir}/environments/production.json"

    rm -rf "${config_dir}"
}
