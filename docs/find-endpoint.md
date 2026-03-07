# `/find` Endpoint

## Overview

The `/find` endpoint allows AI agents to locate interactive elements on a web page using natural language descriptions instead of brittle CSS selectors or XPaths. It searches the current accessibility snapshot of a tab and returns the best-matching element reference, which can be passed directly to `/action` to interact with the element.

This solves a core problem in browser automation: agents no longer need to know exact selectors ahead of time. They describe *what* they want to interact with, and PinchTab resolves *which* element matches.

---

## Endpoint

```
POST /tabs/{tabId}/find
```

The endpoint is available on both the per-instance API and the orchestrator (dashboard) API, where the orchestrator proxies the request to the correct instance.

---

## Request Format

### Request Body (JSON)

| Field             | Type    | Required | Default | Description                                                              |
|-------------------|---------|----------|---------|--------------------------------------------------------------------------|
| `query`           | string  | **Yes**  | —       | Natural language description of the target element                       |
| `tabId`           | string  | No       | active  | Tab ID to search; defaults to the currently active tab                   |
| `threshold`       | float   | No       | `0.3`   | Minimum similarity score (0–1); results below this are filtered out      |
| `topK`            | int     | No       | `3`     | Maximum number of matches to return                                      |
| `lexicalWeight`   | float   | No       | `0.6`   | Weight for lexical scoring component (should sum to 1.0 with embedding)  |
| `embeddingWeight` | float   | No       | `0.4`   | Weight for embedding scoring component (should sum to 1.0 with lexical)  |
| `explain`         | bool    | No       | `false` | Include per-match score breakdown for debugging                          |

### Example Request

```json
{
  "query": "search input",
  "threshold": 0.3,
  "topK": 3
}
```

### Example Request with Debug

```json
{
  "query": "login button",
  "threshold": 0.2,
  "topK": 5,
  "explain": true
}
```

---

## Response Format

### Response Fields

| Field           | Type    | Description                                                             |
|-----------------|---------|-------------------------------------------------------------------------|
| `best_ref`      | string  | Reference ID of the highest-scoring element; pass this to `/action`     |
| `confidence`    | string  | Human-readable label: `"high"`, `"medium"`, or `"low"`                 |
| `score`         | float   | Similarity score of the best match (0–1)                                |
| `matches`       | array   | Top-K scored matches (see Match Object below)                           |
| `strategy`      | string  | Matching strategy used (e.g. `"combined:lexical+embedding:hashing"`)    |
| `threshold`     | float   | Threshold that was applied for this request                             |
| `latency_ms`    | int     | Time taken to execute the search in milliseconds                        |
| `element_count` | int     | Total number of elements evaluated from the snapshot                    |

### Match Object

Each entry in the `matches` array contains:

| Field     | Type    | Description                                         |
|-----------|---------|-----------------------------------------------------|
| `ref`     | string  | Element reference ID                                |
| `score`   | float   | Combined similarity score (0–1)                     |
| `role`    | string  | Accessibility role (e.g. `"button"`, `"textbox"`)   |
| `name`    | string  | Accessible name of the element                      |
| `explain` | object  | *(Only when `explain: true`)* Score breakdown       |

### Explain Object

When `explain` is enabled, each match includes:

| Field             | Type    | Description                                      |
|-------------------|---------|--------------------------------------------------|
| `lexical_score`   | float   | Weighted lexical similarity contribution         |
| `embedding_score` | float   | Weighted embedding similarity contribution       |
| `composite`       | string  | The element's composite text used for matching   |

### Example Response

```json
{
  "best_ref": "e7",
  "confidence": "high",
  "score": 0.91,
  "matches": [
    { "ref": "e7",  "score": 0.91, "role": "textbox", "name": "Search" },
    { "ref": "e12", "score": 0.54, "role": "button",  "name": "Search Wikipedia" }
  ],
  "strategy": "combined:lexical+embedding:hashing",
  "threshold": 0.3,
  "latency_ms": 18,
  "element_count": 142
}
```

### Confidence Labels

| Label    | Score Range  | Meaning                                          |
|----------|--------------|--------------------------------------------------|
| `high`   | ≥ 0.80       | Strong match — safe to act on immediately        |
| `medium` | 0.60 – 0.79  | Reasonable match — verify before critical actions|
| `low`    | < 0.60       | Weak match — consider rephrasing the query       |

---

### Embedding Matcher

Converts text into fixed-dimension vectors using feature hashing (the "hashing trick"):

- **Word-level features** — whole word hashes for exact overlap
- **Character n-gram features** — 2-to-4 character subsequences capture sub-word similarity
- **Role-aware features** — known UI roles get boosted feature weights
- **Synonym injection** — synonym tokens are added at reduced weight so related terms share vector space
- Vectors are **L2-normalized** and scored via **cosine similarity**
- Zero external dependencies — no ML models, APIs, or vocabulary files required

### Combined Scoring

The final score for each element is a weighted average:

```
final_score = 0.6 × lexical_score + 0.4 × embedding_score
```

Both matchers run **concurrently**. The combined matcher uses a lower internal threshold (50% of the requested threshold) to capture candidates that might only score well on one strategy but pass when combined.

Per-request weight overrides are supported via `lexicalWeight` and `embeddingWeight`.

---

## Matching Strategy Details

### Synonym Categories

The built-in synonym table covers 10 UI categories:

| Category             | Examples                                                     |
|----------------------|--------------------------------------------------------------|
| Authentication       | login ↔ sign in ↔ log in ↔ authenticate ↔ log on            |
| Account              | register ↔ sign up ↔ create account ↔ join                   |
| Navigation           | search ↔ find ↔ lookup; menu ↔ navigation ↔ sidebar          |
| Form actions         | submit ↔ send ↔ confirm ↔ save; cancel ↔ abort ↔ discard     |
| UI elements          | button ↔ btn; input ↔ textbox ↔ text field                   |
| Shopping             | cart ↔ basket ↔ bag; checkout ↔ purchase ↔ buy               |
| Content              | image ↔ picture ↔ photo ↔ icon; title ↔ heading ↔ header     |
| Dialogs              | modal ↔ dialog ↔ popup ↔ overlay                             |
| User feedback        | notification ↔ alert ↔ toast ↔ banner                        |
| Common actions       | click ↔ press ↔ tap; accept ↔ agree ↔ ok ↔ confirm           |

### Element Descriptors

Each element from the accessibility snapshot is converted into a composite text string:

```
{Role}: {Name} [{Value}]
```

For example, a search box might produce: `textbox: Search`.

---

## Example Usage

### Find a search input

```bash
curl -X POST http://localhost:9868/tabs/t1/find \
  -H "Content-Type: application/json" \
  -d '{"query": "search input"}'
```

### Find the login button

```bash
curl -X POST http://localhost:9868/tabs/t1/find \
  -H "Content-Type: application/json" \
  -d '{"query": "login button"}'
```

### Find with debug scoring

```bash
curl -X POST http://localhost:9868/tabs/t1/find \
  -H "Content-Type: application/json" \
  -d '{"query": "submit button", "explain": true, "topK": 5}'
```

---

## Typical AI Agent Workflow

```
navigate → find → action
```

### Step-by-Step

```jsonc
// Step 1: Navigate to a page
POST /tabs/t1/navigate
{ "url": "https://github.com/login" }

// Step 2: Find the username field
POST /tabs/t1/find
{ "query": "username input" }
// → { "best_ref": "e14", "confidence": "high", "score": 0.85 }

// Step 3: Type into it
POST /tabs/t1/action
{ "ref": "e14", "action": "type", "value": "user@example.com" }

// Step 4: Find the password field
POST /tabs/t1/find
{ "query": "password field" }
// → { "best_ref": "e18", "confidence": "high", "score": 0.82 }

// Step 5: Type password
POST /tabs/t1/action
{ "ref": "e18", "action": "type", "value": "••••••••" }

// Step 6: Find and click the sign-in button
POST /tabs/t1/find
{ "query": "sign in button" }
// → { "best_ref": "e23", "confidence": "high", "score": 0.88 }

POST /tabs/t1/action
{ "ref": "e23", "action": "click" }
```

---

## Example Queries

| Query                       | What it finds                            |
|-----------------------------|------------------------------------------|
| `"search input"`            | Main search text field                   |
| `"login button"`            | Sign-in / log-in button                  |
| `"submit button"`           | Form submit button                       |
| `"cart icon"`               | Shopping cart link or button              |
| `"sign up"`                 | Registration / create account link       |
| `"close modal"`             | Dialog dismiss button                    |
| `"top right profile menu"`  | User profile button in the header        |
| `"accept cookies"`          | Cookie consent accept button             |

Synonyms are handled automatically — `"sign in"`, `"log in"`, `"login"`, and `"log on"` all resolve to the same element.

---

## Performance Characteristics

- **Latency**: typically < 20ms for pages with 100–200 elements
- **Snapshot**: operates on a cached accessibility snapshot (no DOM traversal per query)
- **Auto-fetch**: if no cached snapshot exists, one is fetched automatically via CDP before matching
- **Concurrency**: lexical and embedding matchers run concurrently in separate goroutines
- **Zero external dependencies**: all matching runs in-process using pure Go — no ML model downloads, no API calls
- **Intent caching**: successful matches are stored in an intent cache, enabling the recovery engine to re-find elements if references go stale after page changes

---

## Error Handling

| Status | Condition                                      | Response Body                                     |
|--------|------------------------------------------------|---------------------------------------------------|
| `400`  | Request body cannot be decoded                 | `{"error": "decode: ..."}`                        |
| `400`  | `query` field is missing or empty              | `{"error": "missing required field 'query'"}`     |
| `404`  | Tab ID does not exist                          | `{"error": "..."}`                                |
| `500`  | Chrome not initialized                         | `{"error": "chrome initialization: ..."}`         |
| `500`  | No elements in snapshot                        | `{"error": "no elements found in snapshot ..."}`  |
| `500`  | Internal matcher error                         | `{"error": "matcher error: ..."}`                 |

When `best_ref` is an empty string in a 200 response, no element met the threshold. Lower the threshold or rephrase the query.

---

## Notes for Developers

### Integration with PinchTab Architecture

1. **Accessibility Snapshot** — `/find` reads from the same snapshot cache used by `/snapshot`. When a snapshot is not cached, it is auto-fetched via CDP (`getAccessibilityTree`). No separate snapshot call is needed.

2. **Element Descriptors** — each `A11yNode` from the snapshot is converted into an `ElementDescriptor` with `Ref`, `Role`, `Name`, and `Value` fields. These are combined into a composite string (`"role: Name [Value]"`) for matching.

3. **Semantic Matching Pipeline** — the `CombinedMatcher` runs `LexicalMatcher` and `EmbeddingMatcher` concurrently, merges scores by element ref, applies the weighted average, and filters by threshold.

4. **Intent Caching & Recovery** — after a successful match, the query and matched descriptor are stored in an `IntentCache`. If a subsequent `/action` call fails because the ref is stale (e.g. after a page re-render), the recovery engine uses the cached intent to re-run the semantic search and find the element at its new ref.

5. **Orchestrator Proxy** — the dashboard orchestrator exposes `POST /tabs/{id}/find` and proxies the request to the correct browser instance. No code duplication — the same handler runs on both the instance and orchestrator APIs.

6. **No External Dependencies** — the entire matching pipeline (tokenization, stopwords, synonyms, hashing embedder, cosine similarity) is implemented in pure Go with zero external libraries or ML models.
