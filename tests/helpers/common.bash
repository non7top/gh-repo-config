#!/usr/bin/env bash

TEST_FIXTURES_DIR="$(dirname "${BATS_TEST_FILENAME}")/fixtures"

# Point the script at the fake gh, with a private copy of the API fixtures
# (tests edit it to simulate other repo states) and a call log.
setup_fake_gh() {
    FAKE_GH_FIXTURES="$(mktemp -d)"
    cp "${TEST_FIXTURES_DIR}/gh/"* "${FAKE_GH_FIXTURES}/"
    FAKE_GH_LOG="$(mktemp)"
    export FAKE_GH_FIXTURES FAKE_GH_LOG
    export APP_ENV="test"
    export _GH="$(dirname "${BATS_TEST_FILENAME}")/helpers/fake-gh"
}

teardown_fake_gh() {
    rm -rf "${FAKE_GH_FIXTURES}" "${FAKE_GH_LOG}"
}

# Replace one API fixture, e.g. set_api GET /repos/:owner/:repo/labels '[]'
set_api() {
    local -r method="$1"
    local key="${2#/}"
    key="${key//:/}"
    key="${key//\//__}"
    printf '%s\n' "$3" >"${FAKE_GH_FIXTURES}/${method}__${key}.json"
}

# Remove one API fixture so the fake gh answers 404.
unset_api() {
    local -r method="$1"
    local key="${2#/}"
    key="${key//:/}"
    key="${key//\//__}"
    rm -f "${FAKE_GH_FIXTURES}/${method}__${key}.json"
}

# Mutating calls the script made, one "METHOD path BODY" line each.
gh_calls() {
    cat "${FAKE_GH_LOG}"
}
