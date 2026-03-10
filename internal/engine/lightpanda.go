package engine

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/chromedp/chromedp"
)

// ErrLightpandaNotSupported signals an operation not available in Lightpanda mode.
var ErrLightpandaNotSupported = errors.New("operation not supported in lightpanda mode")

// lpTab tracks a single Lightpanda browser tab.
type lpTab struct {
	ctx       context.Context
	cancel    context.CancelFunc
	lastURL   string             // URL last navigated to (for re-navigation)
	refs      map[string]int64   // ref → index (for backward compat)
	selectors map[string]string  // ref → CSS selector (for JS click/type)
}

// LightpandaEngine implements Engine by managing a Lightpanda subprocess
// and communicating through CDP (Chrome DevTools Protocol) via chromedp.
// It also supports connecting to an already-running Lightpanda instance
// (e.g. Docker) via the LIGHTPANDA_WS_URL environment variable.
type LightpandaEngine struct {
	binaryPath string
	cmd        *exec.Cmd
	port       int
	externalWS bool // true when connecting to an external/Docker instance

	allocCtx    context.Context
	allocCancel context.CancelFunc

	tabs    map[string]*lpTab
	current string
	seq     int
	mu      sync.Mutex
}

// NewLightpandaEngine creates a Lightpanda-based engine.
// If LIGHTPANDA_WS_URL is set, connects to that existing CDP endpoint
// (e.g. a Docker container) without spawning a subprocess.
// Otherwise binaryPath is the path to the lightpanda executable;
// if empty, auto-detected from LIGHTPANDA_BIN, PATH, or common locations.
func NewLightpandaEngine(binaryPath string) (*LightpandaEngine, error) {
	// Prefer an already-running external instance (Docker, WSL, remote).
	if wsURL := os.Getenv("LIGHTPANDA_WS_URL"); wsURL != "" {
		lp := &LightpandaEngine{
			tabs:       make(map[string]*lpTab),
			externalWS: true,
		}
		if err := lp.connectExternal(wsURL); err != nil {
			return nil, fmt.Errorf("lightpanda connect to %s: %w", wsURL, err)
		}
		return lp, nil
	}

	if binaryPath == "" {
		binaryPath = findLightpandaBinary()
	}
	if binaryPath == "" {
		return nil, errors.New("lightpanda binary not found: set LIGHTPANDA_BIN or install lightpanda (https://github.com/lightpanda-io/browser)")
	}

	lp := &LightpandaEngine{
		binaryPath: binaryPath,
		tabs:       make(map[string]*lpTab),
	}

	if err := lp.start(); err != nil {
		return nil, fmt.Errorf("lightpanda start: %w", err)
	}

	return lp, nil
}

// connectExternal connects to an already-running Lightpanda CDP endpoint.
// wsURL may be a base address like "ws://127.0.0.1:9222" or a full
// websocket URL returned by /json/version.
func (lp *LightpandaEngine) connectExternal(wsURL string) error {
	// Verify the endpoint is reachable before connecting.
	if err := waitForCDP(wsURL, 5*time.Second); err != nil {
		return fmt.Errorf("lightpanda CDP not reachable at %s: %w", wsURL, err)
	}

	lp.allocCtx, lp.allocCancel = chromedp.NewRemoteAllocator(context.Background(), wsURL)
	slog.Info("lightpanda connected to external instance", "ws", wsURL)
	return nil
}

func (lp *LightpandaEngine) Name() string { return "lightpanda" }

func (lp *LightpandaEngine) Capabilities() []Capability {
	return []Capability{CapNavigate, CapSnapshot, CapText, CapClick, CapType}
}

// freshContext creates a new chromedp context, navigates to the given
// URL, and returns the context. The caller must call cancel when done.
// Lightpanda may drop the websocket after each command batch, so we
// create a fresh context for every API operation.
func (lp *LightpandaEngine) freshContext(url string, timeout time.Duration) (context.Context, context.CancelFunc, error) {
	tabCtx, tabCancel := chromedp.NewContext(lp.allocCtx)
	opCtx, opCancel := context.WithTimeout(tabCtx, timeout)

	if err := chromedp.Run(opCtx, chromedp.Navigate(url)); err != nil {
		opCancel()
		tabCancel()
		return nil, nil, fmt.Errorf("lightpanda navigate %s: %w", url, err)
	}

	cancel := func() { opCancel(); tabCancel() }
	return opCtx, cancel, nil
}

// Navigate opens a URL via Lightpanda's CDP endpoint.
func (lp *LightpandaEngine) Navigate(ctx context.Context, url string) (*NavigateResult, error) {
	lp.mu.Lock()
	defer lp.mu.Unlock()

	opCtx, cancel, err := lp.freshContext(url, 30*time.Second)
	if err != nil {
		return nil, err
	}

	// Read title and current URL before closing the connection.
	var title string
	_ = chromedp.Run(opCtx, chromedp.Title(&title))

	var currentURL string
	if err := chromedp.Run(opCtx, chromedp.Location(&currentURL)); err != nil {
		currentURL = url
	}

	// Close the context — Lightpanda doesn't persist connections.
	cancel()

	lp.seq++
	tabID := fmt.Sprintf("lp-%d", lp.seq)

	// Clean up old tab entries.
	for id, tab := range lp.tabs {
		if tab.cancel != nil {
			tab.cancel()
		}
		delete(lp.tabs, id)
	}

	lp.tabs[tabID] = &lpTab{
		lastURL:   url,
		refs:      make(map[string]int64),
		selectors: make(map[string]string),
	}
	lp.current = tabID

	return &NavigateResult{
		TabID: tabID,
		URL:   currentURL,
		Title: title,
	}, nil
}

// Snapshot returns the DOM tree from Lightpanda using JavaScript evaluation.
// Lightpanda does not support Accessibility.getFullAXTree, so we walk the DOM
// via Runtime.evaluate and build an accessibility-style tree in JS.
func (lp *LightpandaEngine) Snapshot(ctx context.Context, filter string) ([]SnapshotNode, error) {
	lp.mu.Lock()
	defer lp.mu.Unlock()

	tab := lp.tabs[lp.current]
	if tab == nil {
		return nil, errors.New("no page loaded")
	}

	opCtx, cancel, err := lp.freshContext(tab.lastURL, 30*time.Second)
	if err != nil {
		return nil, fmt.Errorf("lightpanda snapshot: %w", err)
	}
	defer cancel()

	// JavaScript that walks the DOM and builds a snapshot array.
	var result string
	if err := chromedp.Run(opCtx, chromedp.Evaluate(snapshotJS(filter), &result)); err != nil {
		return nil, fmt.Errorf("lightpanda snapshot eval: %w", err)
	}

	var jsNodes []jsSnapshotNode
	if err := json.Unmarshal([]byte(result), &jsNodes); err != nil {
		return nil, fmt.Errorf("lightpanda snapshot parse: %w", err)
	}

	// Convert JS nodes to engine SnapshotNodes and populate ref/selector maps.
	tab.refs = make(map[string]int64)
	tab.selectors = make(map[string]string, len(jsNodes))
	nodes := make([]SnapshotNode, 0, len(jsNodes))
	for i, n := range jsNodes {
		ref := fmt.Sprintf("e%d", i)
		tab.refs[ref] = int64(i)
		tab.selectors[ref] = n.Selector

		nodes = append(nodes, SnapshotNode{
			Ref:         ref,
			Role:        n.Role,
			Name:        n.Name,
			Tag:         n.Tag,
			Value:       n.Value,
			Depth:       n.Depth,
			Interactive: n.Interactive,
		})
	}

	return nodes, nil
}

// Text returns the visible text content of the current page via JavaScript.
func (lp *LightpandaEngine) Text(ctx context.Context) (string, error) {
	lp.mu.Lock()
	defer lp.mu.Unlock()

	tab := lp.tabs[lp.current]
	if tab == nil {
		return "", errors.New("no page loaded")
	}

	opCtx, cancel, err := lp.freshContext(tab.lastURL, 30*time.Second)
	if err != nil {
		return "", fmt.Errorf("lightpanda text: %w", err)
	}
	defer cancel()

	var text string
	if err := chromedp.Run(opCtx, chromedp.Evaluate(`document.body ? document.body.innerText : ""`, &text)); err != nil {
		// Fallback: try textContent which is more widely supported.
		var fallback string
		if err2 := chromedp.Run(opCtx, chromedp.Evaluate(`document.body ? document.body.textContent : ""`, &fallback)); err2 != nil {
			return "", fmt.Errorf("lightpanda text: %w", err)
		}
		text = fallback
	}

	return normalizeWhitespace(text), nil
}

// Click clicks an element identified by ref using JavaScript.
func (lp *LightpandaEngine) Click(ctx context.Context, ref string) error {
	lp.mu.Lock()
	defer lp.mu.Unlock()

	tab := lp.tabs[lp.current]
	if tab == nil {
		return errors.New("no page loaded")
	}

	selector, ok := tab.selectors[ref]
	if !ok || selector == "" {
		return fmt.Errorf("ref %q not found (take a snapshot first)", ref)
	}

	opCtx, cancel, err := lp.freshContext(tab.lastURL, 15*time.Second)
	if err != nil {
		return fmt.Errorf("lightpanda click: %w", err)
	}
	defer cancel()

	// Use JavaScript to find and click the element via its unique selector.
	var success bool
	js := fmt.Sprintf(`(function() {
		var el = document.querySelector(%s);
		if (!el) return false;
		el.scrollIntoView({block: 'center'});
		el.focus();
		el.click();
		return true;
	})()`, jsonString(selector))

	if err := chromedp.Run(opCtx, chromedp.Evaluate(js, &success)); err != nil {
		return fmt.Errorf("lightpanda click: %w", err)
	}
	if !success {
		return fmt.Errorf("element for ref %q not found in DOM", ref)
	}
	return nil
}

// Type enters text into an element identified by ref using JavaScript.
func (lp *LightpandaEngine) Type(ctx context.Context, ref, text string) error {
	lp.mu.Lock()
	defer lp.mu.Unlock()

	tab := lp.tabs[lp.current]
	if tab == nil {
		return errors.New("no page loaded")
	}

	selector, ok := tab.selectors[ref]
	if !ok || selector == "" {
		return fmt.Errorf("ref %q not found (take a snapshot first)", ref)
	}

	opCtx, cancel, err := lp.freshContext(tab.lastURL, 15*time.Second)
	if err != nil {
		return fmt.Errorf("lightpanda type: %w", err)
	}
	defer cancel()

	var success bool
	js := fmt.Sprintf(`(function() {
		var el = document.querySelector(%s);
		if (!el) return false;
		el.focus();
		el.value = %s;
		el.dispatchEvent(new Event('input', {bubbles: true}));
		el.dispatchEvent(new Event('change', {bubbles: true}));
		return true;
	})()`, jsonString(selector), jsonString(text))

	if err := chromedp.Run(opCtx, chromedp.Evaluate(js, &success)); err != nil {
		return fmt.Errorf("lightpanda type: %w", err)
	}
	if !success {
		return fmt.Errorf("element for ref %q not found in DOM", ref)
	}
	return nil
}

// Close shuts down the Lightpanda subprocess and releases resources.
func (lp *LightpandaEngine) Close() error {
	lp.mu.Lock()
	defer lp.mu.Unlock()

	for _, tab := range lp.tabs {
		if tab.cancel != nil {
			tab.cancel()
		}
	}
	lp.tabs = make(map[string]*lpTab)

	if lp.allocCancel != nil {
		lp.allocCancel()
	}

	// Only kill subprocess if we launched it ourselves.
	if lp.externalWS {
		return nil
	}

	if lp.cmd != nil && lp.cmd.Process != nil {
		slog.Info("stopping lightpanda subprocess", "pid", lp.cmd.Process.Pid)
		if err := lp.cmd.Process.Signal(os.Interrupt); err != nil {
			_ = lp.cmd.Process.Kill()
		}
		_ = lp.cmd.Wait()
		lp.cmd = nil
	}
	return nil
}

// ---------- subprocess management ----------

func (lp *LightpandaEngine) start() error {
	port, err := findFreePortLP()
	if err != nil {
		return fmt.Errorf("find free port: %w", err)
	}
	lp.port = port

	lp.cmd = exec.Command(lp.binaryPath,
		"--cd-port", strconv.Itoa(port),
	)
	lp.cmd.Env = append(os.Environ(), "LIGHTPANDA_DISABLE_TELEMETRY=true")
	lp.cmd.Stdout = os.Stdout
	lp.cmd.Stderr = os.Stderr

	slog.Info("starting lightpanda", "binary", lp.binaryPath, "port", port)

	if err := lp.cmd.Start(); err != nil {
		return fmt.Errorf("lightpanda start: %w", err)
	}

	// Wait for the CDP endpoint to become available.
	wsURL := fmt.Sprintf("ws://127.0.0.1:%d", port)
	if err := waitForCDP(wsURL, 10*time.Second); err != nil {
		_ = lp.cmd.Process.Kill()
		return fmt.Errorf("lightpanda CDP not ready: %w", err)
	}

	// Connect chromedp via RemoteAllocator.
	lp.allocCtx, lp.allocCancel = chromedp.NewRemoteAllocator(context.Background(), wsURL)

	slog.Info("lightpanda started", "pid", lp.cmd.Process.Pid, "port", port, "ws", wsURL)
	return nil
}

// waitForCDP polls the WebSocket endpoint until it accepts a connection.
func waitForCDP(wsURL string, timeout time.Duration) error {
	// Extract host:port from ws URL.
	addr := strings.TrimPrefix(wsURL, "ws://")
	addr = strings.TrimPrefix(addr, "wss://")

	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp", addr, 500*time.Millisecond)
		if err == nil {
			conn.Close()
			return nil
		}
		time.Sleep(200 * time.Millisecond)
	}
	return fmt.Errorf("timeout waiting for CDP at %s", wsURL)
}

// findFreePortLP finds an available TCP port for Lightpanda.
func findFreePortLP() (int, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	port := l.Addr().(*net.TCPAddr).Port
	l.Close()
	return port, nil
}

// findLightpandaBinary searches for the lightpanda binary.
func findLightpandaBinary() string {
	// Check environment variable first.
	if bin := os.Getenv("LIGHTPANDA_BIN"); bin != "" {
		if _, err := os.Stat(bin); err == nil {
			return bin
		}
	}

	// Check PATH.
	if path, err := exec.LookPath("lightpanda"); err == nil {
		return path
	}

	// Platform-specific common locations.
	var candidates []string
	if runtime.GOOS == "windows" {
		candidates = []string{
			`C:\lightpanda\lightpanda.exe`,
			`C:\Program Files\lightpanda\lightpanda.exe`,
		}
	} else {
		candidates = []string{
			"/usr/local/bin/lightpanda",
			"/usr/bin/lightpanda",
			"/opt/lightpanda/lightpanda",
		}
		if home := os.Getenv("HOME"); home != "" {
			candidates = append(candidates,
				home+"/lightpanda/lightpanda",
				home+"/.local/bin/lightpanda",
			)
		}
	}

	for _, p := range candidates {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return ""
}

// ---------- JavaScript-based DOM helpers ----------

// jsSnapshotNode is the Go-side representation of the snapshot node
// returned by the JavaScript DOM walker.
type jsSnapshotNode struct {
	Role        string `json:"role"`
	Name        string `json:"name"`
	Tag         string `json:"tag"`
	Value       string `json:"value"`
	Depth       int    `json:"depth"`
	Interactive bool   `json:"interactive"`
	Selector    string `json:"selector"` // unique CSS selector for click/type
}

// snapshotJS returns JavaScript that walks the DOM and builds a JSON
// array of snapshot nodes. This works on any CDP-compatible browser
// including Lightpanda which does not support Accessibility.getFullAXTree.
func snapshotJS(filter string) string {
	interactiveOnly := "false"
	if filter == "interactive" {
		interactiveOnly = "true"
	}
	return `(function() {
	var INTERACTIVE_ONLY = ` + interactiveOnly + `;
	var SKIP_TAGS = {SCRIPT:1,STYLE:1,NOSCRIPT:1,LINK:1,META:1,BR:1,HR:1,SVG:1};
	var INTERACTIVE_TAGS = {A:1,BUTTON:1,INPUT:1,TEXTAREA:1,SELECT:1,SUMMARY:1};

	function inferRole(el) {
		var tag = el.tagName;
		var role = el.getAttribute && el.getAttribute('role');
		if (role) return role;
		switch (tag) {
			case 'A': return el.href ? 'link' : 'generic';
			case 'BUTTON': return 'button';
			case 'INPUT':
				var t = (el.type || 'text').toLowerCase();
				if (t === 'submit' || t === 'button') return 'button';
				if (t === 'checkbox') return 'checkbox';
				if (t === 'radio') return 'radio';
				if (t === 'search') return 'searchbox';
				if (t === 'range') return 'slider';
				if (t === 'number') return 'spinbutton';
				return 'textbox';
			case 'TEXTAREA': return 'textbox';
			case 'SELECT': return 'combobox';
			case 'IMG': return 'img';
			case 'NAV': return 'navigation';
			case 'MAIN': return 'main';
			case 'HEADER': return 'banner';
			case 'FOOTER': return 'contentinfo';
			case 'ASIDE': return 'complementary';
			case 'FORM': return 'form';
			case 'H1': case 'H2': case 'H3': case 'H4': case 'H5': case 'H6': return 'heading';
			case 'UL': case 'OL': return 'list';
			case 'LI': return 'listitem';
			case 'TABLE': return 'table';
			case 'TR': return 'row';
			case 'TD': return 'cell';
			case 'TH': return 'columnheader';
			case 'DETAILS': return 'group';
			case 'SUMMARY': return 'button';
			case 'DIALOG': return 'dialog';
			case 'ARTICLE': return 'article';
			default: return 'generic';
		}
	}

	function getName(el) {
		var n = el.getAttribute && (el.getAttribute('aria-label') || el.getAttribute('title') || '');
		if (n) return n;
		var tag = el.tagName;
		if (tag === 'IMG') return el.getAttribute('alt') || '';
		if (tag === 'INPUT' || tag === 'TEXTAREA') return el.getAttribute('placeholder') || '';
		if (isInteractive(el)) {
			var t = (el.textContent || '').trim();
			return t.length > 100 ? t.substring(0,100) + '...' : t;
		}
		return '';
	}

	function isInteractive(el) {
		if (INTERACTIVE_TAGS[el.tagName]) {
			if (el.tagName === 'A') return !!el.href;
			if (el.tagName === 'INPUT' && el.type === 'hidden') return false;
			return true;
		}
		if (el.getAttribute && el.getAttribute('onclick')) return true;
		var ti = el.getAttribute && el.getAttribute('tabindex');
		if (ti !== null && ti !== '-1' && ti !== undefined) return true;
		var r = el.getAttribute && el.getAttribute('role');
		if (r && {button:1,link:1,tab:1,menuitem:1,switch:1,checkbox:1,radio:1}[r]) return true;
		return false;
	}

	function uniqueSelector(el) {
		if (el.id) return '#' + CSS.escape(el.id);
		var parts = [];
		var cur = el;
		while (cur && cur.nodeType === 1 && cur !== document.body) {
			var tag = cur.tagName.toLowerCase();
			var parent = cur.parentElement;
			if (cur.id) { parts.unshift('#' + CSS.escape(cur.id)); break; }
			if (parent) {
				var siblings = parent.children;
				var sameTag = 0, idx = 0;
				for (var i = 0; i < siblings.length; i++) {
					if (siblings[i].tagName === cur.tagName) {
						sameTag++;
						if (siblings[i] === cur) idx = sameTag;
					}
				}
				parts.unshift(sameTag > 1 ? tag + ':nth-of-type(' + idx + ')' : tag);
			} else {
				parts.unshift(tag);
			}
			cur = parent;
		}
		return parts.join(' > ');
	}

	var nodes = [];
	function walk(el, depth) {
		if (!el || el.nodeType !== 1) return;
		var tag = el.tagName;
		if (SKIP_TAGS[tag]) return;

		var role = inferRole(el);
		var interactive = isInteractive(el);

		if (INTERACTIVE_ONLY && !interactive) {
			var children = el.children;
			for (var i = 0; i < children.length; i++) walk(children[i], depth);
			return;
		}

		if (role === 'generic' && !interactive) {
			var name = getName(el);
			if (!name) {
				var children = el.children;
				for (var i = 0; i < children.length; i++) walk(children[i], depth + 1);
				return;
			}
		}

		var node = {
			role: role,
			name: getName(el),
			tag: tag.toLowerCase(),
			value: '',
			depth: depth,
			interactive: interactive,
			selector: uniqueSelector(el)
		};

		if (tag === 'INPUT' || tag === 'TEXTAREA') node.value = el.value || '';
		if (tag === 'SELECT') node.value = el.value || '';

		nodes.push(node);
		var children = el.children;
		for (var i = 0; i < children.length; i++) walk(children[i], depth + 1);
	}

	walk(document.body || document.documentElement, 0);
	return JSON.stringify(nodes);
})()
`
}

// jsonString returns a JSON-encoded string literal safe for embedding in JS.
func jsonString(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

// isInteractiveRole checks if an ARIA role is interactive (used in tests).
func isInteractiveRole(role string) bool {
	switch role {
	case "button", "link", "textbox", "checkbox", "radio", "combobox",
		"menuitem", "tab", "switch", "searchbox", "spinbutton", "slider":
		return true
	}
	return false
}

// stripHTMLTags removes HTML tags from a string (simple approach).
func stripHTMLTags(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	inTag := false
	for _, r := range s {
		if r == '<' {
			inTag = true
			continue
		}
		if r == '>' {
			inTag = false
			b.WriteByte(' ')
			continue
		}
		if !inTag {
			b.WriteRune(r)
		}
	}
	return b.String()
}
