#!/bin/bash
set -e

# check.sh — Local pre-push checks matching GitHub Actions CI
# Uses gotestsum for structured test output with summaries

BOLD=$'\033[1m'
ACCENT=$'\033[38;2;251;191;36m'
INFO=$'\033[38;2;136;146;176m'
SUCCESS=$'\033[38;2;0;229;204m'
ERROR=$'\033[38;2;230;57;70m'
MUTED=$'\033[38;2;90;100;128m'
NC=$'\033[0m'

CORE_REGEX='^Test(Health|Orchestrator_|Navigate_|Tabs_|Config_|Metrics_|Cookies_|Error_|Eval_|Upload_|Screenshot_)'
TMPDIR_CHECK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_CHECK" pinchtab coverage.out 2>/dev/null' EXIT

ok()      { echo -e "  ${SUCCESS}✓${NC} $1"; }
fail()    { echo -e "  ${ERROR}✗${NC} $1"; [ -n "${2:-}" ] && echo -e "    ${MUTED}$2${NC}"; }
hint()    { echo -e "    ${MUTED}$1${NC}"; }

section() {
  echo ""
  echo -e "${ACCENT}${BOLD}$1${NC}"
}

# Parse gotestsum JSON events and print summary
test_summary() {
  local json_file="$1"
  local label="$2"

  if [ ! -s "$json_file" ]; then
    echo -e "    ${MUTED}No test events recorded${NC}"
    return
  fi

  local total=0 pass=0 fail=0 skip=0
  read total pass fail skip <<<"$(jq -r \
    'select(.Test != null and (.Action == "pass" or .Action == "fail" or .Action == "skip"))
     | [.Package, .Test, .Action] | @tsv' "$json_file" \
    | awk -F'\t' 'NF == 3 { key = $1 "\t" $2; status[key] = $3 }
      END {
        for (k in status) {
          t++
          if (status[k] == "pass") p++
          else if (status[k] == "fail") f++
          else if (status[k] == "skip") s++
        }
        printf "%d %d %d %d\n", t+0, p+0, f+0, s+0
      }')"

  echo ""
  echo -e "    ${BOLD}$label${NC}"
  echo -e "    ${MUTED}────────────────────────────${NC}"
  echo -e "    Total:   ${BOLD}$total${NC}"
  [ "$pass" -gt 0 ] && echo -e "    Passed:  ${SUCCESS}$pass${NC}"
  [ "$fail" -gt 0 ] && echo -e "    Failed:  ${ERROR}$fail${NC}"
  [ "$skip" -gt 0 ] && echo -e "    Skipped: ${ACCENT}$skip${NC}"

  # Show failed test names
  if [ "$fail" -gt 0 ]; then
    echo ""
    echo -e "    ${ERROR}Failed tests:${NC}"
    jq -r 'select(.Test != null and .Action == "fail") | "      ✗ \(.Test)"' "$json_file" | sort -u
  fi
}

# ── Start ────────────────────────────────────────────────────────────

echo ""
echo -e "  ${ACCENT}${BOLD}🦀 Pinchtab Check${NC}"
echo -e "  ${INFO}Running pre-push checks (matches GitHub Actions CI)...${NC}"

# ── Check gotestsum ──────────────────────────────────────────────────

HAS_GOTESTSUM=false
if command -v gotestsum &>/dev/null; then
  HAS_GOTESTSUM=true
fi

# Run unit tests with dots progress
# Usage: run_unit_tests <json_file> <go test args...>
run_unit_tests() {
  local json_file="$1"; shift
  local exit_code=0

  if $HAS_GOTESTSUM; then
    gotestsum --format dots --jsonfile "$json_file" -- "$@" 2>&1 || exit_code=$?
  else
    go test "$@" 2>&1 | grep -E '^(ok|FAIL|---) ' || exit_code=${PIPESTATUS[0]}
  fi

  echo ""
  return $exit_code
}

# Run integration tests with live progress counter
# Pipes go test -json directly for real-time output
# Usage: run_integration_tests <json_file> <go test args...>
run_integration_tests() {
  local json_file="$1"; shift
  local exit_code=0
  local count=0

  # Stream JSON events from go test, tee to file, show live progress
  go test -json "$@" 2>&1 | tee "$json_file" | while IFS= read -r line; do
    local action test_name
    action=$(echo "$line" | jq -r '.Action // empty' 2>/dev/null) || continue
    test_name=$(echo "$line" | jq -r '.Test // empty' 2>/dev/null) || continue

    [ -z "$test_name" ] && continue

    # Track elapsed time from Elapsed field
    local elapsed
    elapsed=$(echo "$line" | jq -r '.Elapsed // empty' 2>/dev/null)

    # Truncate long test names
    local display_name="$test_name"
    local max_len=40
    if [ ${#display_name} -gt $max_len ]; then
      display_name="${display_name:0:$((max_len - 1))}…"
    fi

    case "$action" in
      run)
        printf "\r    ${MUTED}▸ %-${max_len}s${NC}        \r" "$display_name"
        ;;
      pass)
        count=$((count + 1))
        if [ -n "$elapsed" ]; then
          printf "\r    ${SUCCESS}✓${NC} ${MUTED}[%2d]${NC} %-${max_len}s ${MUTED}%6ss${NC}\n" "$count" "$display_name" "$elapsed"
        else
          printf "\r    ${SUCCESS}✓${NC} ${MUTED}[%2d]${NC} %-${max_len}s\n" "$count" "$display_name"
        fi
        ;;
      fail)
        count=$((count + 1))
        if [ -n "$elapsed" ]; then
          printf "\r    ${ERROR}✗${NC} ${MUTED}[%2d]${NC} %-${max_len}s ${MUTED}%6ss${NC}\n" "$count" "$display_name" "$elapsed"
        else
          printf "\r    ${ERROR}✗${NC} ${MUTED}[%2d]${NC} %-${max_len}s\n" "$count" "$display_name"
        fi
        ;;
      skip)
        count=$((count + 1))
        printf "\r    ${ACCENT}·${NC} ${MUTED}[%2d]${NC} %-${max_len}s ${MUTED}  skip${NC}\n" "$count" "$display_name"
        ;;
    esac
  done
  exit_code=${PIPESTATUS[0]}
  printf "\r%*s\r" 60 ""  # clear last line

  return $exit_code
}

# ── Format ───────────────────────────────────────────────────────────

section "Format Check"

unformatted=$(gofmt -l .)
if [ -n "$unformatted" ]; then
  fail "gofmt" "Files not formatted:"
  echo "$unformatted" | while read f; do hint "  $f"; done
  hint "Run: gofmt -w ."
  exit 1
fi
ok "gofmt"

# ── Vet ──────────────────────────────────────────────────────────────

section "Go Vet"

if ! go vet ./... 2>&1; then
  fail "go vet"
  exit 1
fi
ok "go vet"

# ── Build ────────────────────────────────────────────────────────────

section "Build"

if ! go build -o pinchtab ./cmd/pinchtab 2>&1; then
  fail "go build"
  exit 1
fi
ok "go build"

# ── Unit Tests ───────────────────────────────────────────────────────

section "Unit Tests"

UNIT_JSON="$TMPDIR_CHECK/unit-events.json"

if ! run_unit_tests "$UNIT_JSON" \
  -count=1 -coverprofile=coverage.out -covermode=atomic ./...; then
  fail "Unit tests"
  test_summary "$UNIT_JSON" "Unit Test Results"
  exit 1
fi
ok "Unit tests"
test_summary "$UNIT_JSON" "Unit Test Results"

echo ""
echo -e "    ${BOLD}Coverage${NC}"
echo -e "    ${MUTED}────────────────────────────${NC}"
go tool cover -func=coverage.out | tail -1 | awk '{printf "    %s\n", $0}'

# ── Integration Tests (Core) ────────────────────────────────────────

section "Integration Tests (Core)"

CORE_JSON="$TMPDIR_CHECK/core-events.json"

if ! run_integration_tests "$CORE_JSON" \
  -tags integration -timeout 10m -count=1 \
  -run "$CORE_REGEX" ./tests/integration/; then
  fail "Integration core"
  test_summary "$CORE_JSON" "Core Test Results"
  exit 1
fi
ok "Integration core"
test_summary "$CORE_JSON" "Core Test Results"

# ── Integration Tests (Rest) ────────────────────────────────────────

section "Integration Tests (Rest)"

REST_JSON="$TMPDIR_CHECK/rest-events.json"

if ! run_integration_tests "$REST_JSON" \
  -tags integration -timeout 12m -count=1 \
  -run '^Test' -skip "$CORE_REGEX" ./tests/integration/; then
  fail "Integration rest"
  test_summary "$REST_JSON" "Rest Test Results"
  exit 1
fi
ok "Integration rest"
test_summary "$REST_JSON" "Rest Test Results"

# ── Lint ─────────────────────────────────────────────────────────────

section "Lint"

LINT_CMD=""
if command -v golangci-lint >/dev/null 2>&1; then
  LINT_CMD="golangci-lint"
elif [ -x "$HOME/bin/golangci-lint" ]; then
  LINT_CMD="$HOME/bin/golangci-lint"
elif [ -x "/usr/local/bin/golangci-lint" ]; then
  LINT_CMD="/usr/local/bin/golangci-lint"
fi

if [ -n "$LINT_CMD" ]; then
  if ! $LINT_CMD run ./...; then
    fail "golangci-lint"
    exit 1
  fi
  ok "golangci-lint"
else
  echo -e "  ${ACCENT}·${NC} golangci-lint not installed — skipping"
  hint "Install: brew install golangci-lint"
fi

# ── Summary ──────────────────────────────────────────────────────────

section "Summary"
echo ""
echo -e "  ${SUCCESS}${BOLD}All checks passed!${NC} Ready to push."
echo ""
