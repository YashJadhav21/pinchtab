#!/bin/bash
# 24-tab-eviction-lru.sh — LRU tab eviction (maxTabs=2 on secure instance)
#
# The secure pinchtab instance is configured with maxTabs=2 and close_lru.
# Tests that opening a 3rd tab evicts the least recently used tab.

source "$(dirname "$0")/common.sh"

# Use the secure instance (maxTabs=2)
PINCHTAB_URL="$PINCHTAB_SECURE_URL"

# Close any existing tabs from previous tests or Chrome startup
for tab_id in $(curl -s "$PINCHTAB_URL/tabs" | jq -r '.tabs[].id // empty' 2>/dev/null); do
  curl -sf -X POST "$PINCHTAB_URL/tabs/$tab_id/close" > /dev/null 2>&1
done

# ─────────────────────────────────────────────────────────────────
start_test "LRU eviction: open 2 tabs (at limit)"

# Tab 1: index page
pt_post /navigate -d "{\"url\":\"${FIXTURES_URL}/index.html\"}"
TAB1=$(echo "$RESULT" | jq -r '.tabId')
assert_ok "open tab 1 (index)"
echo -e "  ${MUTED}tab1: ${TAB1:0:12}...${NC}"

sleep 0.5

# Tab 2: form page
pt_post /navigate -d "{\"url\":\"${FIXTURES_URL}/form.html\"}"
TAB2=$(echo "$RESULT" | jq -r '.tabId')
assert_ok "open tab 2 (form)"
echo -e "  ${MUTED}tab2: ${TAB2:0:12}...${NC}"

# Verify we have 2 tabs
pt_get /tabs > /dev/null
TAB_COUNT=$(echo "$RESULT" | jq '.tabs | length')
if [ "$TAB_COUNT" -eq 2 ]; then
  echo -e "  ${GREEN}✓${NC} 2 tabs open (at limit)"
  ((ASSERTIONS_PASSED++)) || true
else
  echo -e "  ${RED}✗${NC} expected 2 tabs, got $TAB_COUNT"
  ((ASSERTIONS_FAILED++)) || true
fi

end_test

# ─────────────────────────────────────────────────────────────────
start_test "LRU eviction: 3rd tab evicts least recently used"

# Touch tab2 (make it recently used) by taking a snapshot
pt_get "/tabs/$TAB2/snapshot" > /dev/null
sleep 0.5

# Tab 3: buttons page — should evict tab1 (LRU)
pt_post /navigate -d "{\"url\":\"${FIXTURES_URL}/buttons.html\"}"
TAB3=$(echo "$RESULT" | jq -r '.tabId')
assert_ok "open tab 3 (buttons) — triggers LRU eviction"
echo -e "  ${MUTED}tab3: ${TAB3:0:12}...${NC}"

# Still 2 tabs (one was evicted)
pt_get /tabs > /dev/null
TAB_COUNT=$(echo "$RESULT" | jq '.tabs | length')
if [ "$TAB_COUNT" -eq 2 ]; then
  echo -e "  ${GREEN}✓${NC} still 2 tabs (eviction worked)"
  ((ASSERTIONS_PASSED++)) || true
else
  echo -e "  ${RED}✗${NC} expected 2 tabs after eviction, got $TAB_COUNT"
  ((ASSERTIONS_FAILED++)) || true
fi

# Tab1 should be gone (evicted as LRU)
TAB1_EXISTS=$(echo "$RESULT" | jq --arg id "$TAB1" '[.tabs[] | select(.id == $id)] | length')
if [ "$TAB1_EXISTS" -eq 0 ]; then
  echo -e "  ${GREEN}✓${NC} tab1 was evicted (LRU)"
  ((ASSERTIONS_PASSED++)) || true
else
  echo -e "  ${RED}✗${NC} tab1 should have been evicted"
  ((ASSERTIONS_FAILED++)) || true
fi

# Tab2 should still exist (it was recently used)
TAB2_EXISTS=$(echo "$RESULT" | jq --arg id "$TAB2" '[.tabs[] | select(.id == $id)] | length')
if [ "$TAB2_EXISTS" -eq 1 ]; then
  echo -e "  ${GREEN}✓${NC} tab2 survived (recently used)"
  ((ASSERTIONS_PASSED++)) || true
else
  echo -e "  ${RED}✗${NC} tab2 should still exist"
  ((ASSERTIONS_FAILED++)) || true
fi

end_test

# ─────────────────────────────────────────────────────────────────
start_test "LRU eviction: evicted tab returns 404"

pt_get "/tabs/$TAB1/snapshot"
assert_http_error 404 "evicted tab snapshot"

end_test

# ─────────────────────────────────────────────────────────────────
start_test "LRU eviction: continuous eviction works"

# Open tab 4 — should evict tab2 (now LRU since tab3 was just created)
pt_post /navigate -d "{\"url\":\"${FIXTURES_URL}/table.html\"}"
TAB4=$(echo "$RESULT" | jq -r '.tabId')
assert_ok "open tab 4 (table) — triggers another eviction"

pt_get /tabs > /dev/null
TAB_COUNT=$(echo "$RESULT" | jq '.tabs | length')
if [ "$TAB_COUNT" -eq 2 ]; then
  echo -e "  ${GREEN}✓${NC} still 2 tabs after second eviction"
  ((ASSERTIONS_PASSED++)) || true
else
  echo -e "  ${RED}✗${NC} expected 2 tabs, got $TAB_COUNT"
  ((ASSERTIONS_FAILED++)) || true
fi

# Tab3 and tab4 should be the survivors
TAB3_EXISTS=$(echo "$RESULT" | jq --arg id "$TAB3" '[.tabs[] | select(.id == $id)] | length')
TAB4_EXISTS=$(echo "$RESULT" | jq --arg id "$TAB4" '[.tabs[] | select(.id == $id)] | length')
if [ "$TAB3_EXISTS" -eq 1 ] && [ "$TAB4_EXISTS" -eq 1 ]; then
  echo -e "  ${GREEN}✓${NC} tab3 and tab4 survived"
  ((ASSERTIONS_PASSED++)) || true
else
  echo -e "  ${RED}✗${NC} expected tab3 and tab4 to survive"
  ((ASSERTIONS_FAILED++)) || true
fi

end_test
