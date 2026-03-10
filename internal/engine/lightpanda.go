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

	"github.com/chromedp/cdproto/accessibility"
	"github.com/chromedp/chromedp"
)

// ErrLightpandaNotSupported signals an operation not available in Lightpanda mode.
var ErrLightpandaNotSupported = errors.New("operation not supported in lightpanda mode")

// lpTab tracks a single Lightpanda browser tab.
type lpTab struct {
	ctx    context.Context
	cancel context.CancelFunc
	refs   map[string]int64 // ref → backend DOM node ID
}

// LightpandaEngine implements Engine by managing a Lightpanda subprocess
// and communicating through CDP (Chrome DevTools Protocol) via chromedp.
type LightpandaEngine struct {
	binaryPath string
	cmd        *exec.Cmd
	port       int

	allocCtx    context.Context
	allocCancel context.CancelFunc

	tabs    map[string]*lpTab
	current string
	seq     int
	mu      sync.Mutex
}

// NewLightpandaEngine creates a Lightpanda-based engine.
// binaryPath is the path to the lightpanda executable.
// If empty, it tries to auto-detect from common locations or PATH.
func NewLightpandaEngine(binaryPath string) (*LightpandaEngine, error) {
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

func (lp *LightpandaEngine) Name() string { return "lightpanda" }

func (lp *LightpandaEngine) Capabilities() []Capability {
	return []Capability{CapNavigate, CapSnapshot, CapText, CapClick, CapType}
}

// Navigate opens a URL via Lightpanda's CDP endpoint.
func (lp *LightpandaEngine) Navigate(ctx context.Context, url string) (*NavigateResult, error) {
	lp.mu.Lock()
	defer lp.mu.Unlock()

	// Create a new tab via CDP.
	tabCtx, tabCancel := chromedp.NewContext(lp.allocCtx)

	navCtx, navCancel := context.WithTimeout(tabCtx, 30*time.Second)
	defer navCancel()

	if err := chromedp.Run(navCtx, chromedp.Navigate(url)); err != nil {
		tabCancel()
		return nil, fmt.Errorf("lightpanda navigate: %w", err)
	}

	// Wait briefly for title to populate.
	var title string
	_ = chromedp.Run(navCtx, chromedp.Title(&title))

	var currentURL string
	if err := chromedp.Run(navCtx, chromedp.Location(&currentURL)); err != nil {
		currentURL = url
	}

	lp.seq++
	tabID := fmt.Sprintf("lp-%d", lp.seq)
	lp.tabs[tabID] = &lpTab{
		ctx:    tabCtx,
		cancel: tabCancel,
		refs:   make(map[string]int64),
	}
	lp.current = tabID

	return &NavigateResult{
		TabID: tabID,
		URL:   currentURL,
		Title: title,
	}, nil
}

// Snapshot returns the accessibility tree from Lightpanda.
func (lp *LightpandaEngine) Snapshot(ctx context.Context, filter string) ([]SnapshotNode, error) {
	lp.mu.Lock()
	defer lp.mu.Unlock()

	tab := lp.tabs[lp.current]
	if tab == nil {
		return nil, errors.New("no page loaded")
	}

	snapCtx, snapCancel := context.WithTimeout(tab.ctx, 15*time.Second)
	defer snapCancel()

	// Get the full accessibility tree via CDP.
	var axNodes []*accessibility.Node
	if err := chromedp.Run(snapCtx, chromedp.ActionFunc(func(ctx context.Context) error {
		var err error
		axNodes, err = accessibility.GetFullAXTree().Do(ctx)
		return err
	})); err != nil {
		return nil, fmt.Errorf("lightpanda snapshot: %w", err)
	}

	tab.refs = make(map[string]int64)
	return buildSnapshotFromAXTree(axNodes, tab.refs, filter), nil
}

// Text returns the visible text content of the current page.
func (lp *LightpandaEngine) Text(ctx context.Context) (string, error) {
	lp.mu.Lock()
	defer lp.mu.Unlock()

	tab := lp.tabs[lp.current]
	if tab == nil {
		return "", errors.New("no page loaded")
	}

	textCtx, textCancel := context.WithTimeout(tab.ctx, 15*time.Second)
	defer textCancel()

	var text string
	if err := chromedp.Run(textCtx, chromedp.ActionFunc(func(ctx context.Context) error {
		// Get document root node.
		var result json.RawMessage
		if err := chromedp.FromContext(ctx).Target.Execute(ctx, "DOM.getDocument", nil, &result); err != nil {
			return err
		}
		var doc struct {
			Root struct {
				NodeID int64 `json:"nodeId"`
			} `json:"root"`
		}
		if err := json.Unmarshal(result, &doc); err != nil {
			return err
		}
		// Get outer HTML of document.
		var htmlResult json.RawMessage
		if err := chromedp.FromContext(ctx).Target.Execute(ctx, "DOM.getOuterHTML", map[string]any{
			"nodeId": doc.Root.NodeID,
		}, &htmlResult); err != nil {
			return err
		}
		var outer struct {
			OuterHTML string `json:"outerHTML"`
		}
		if err := json.Unmarshal(htmlResult, &outer); err != nil {
			return err
		}
		text = outer.OuterHTML
		return nil
	})); err != nil {
		// Fallback: try innerText via evaluate.
		if evalErr := chromedp.Run(textCtx, chromedp.InnerHTML("body", &text, chromedp.ByQuery)); evalErr != nil {
			return "", fmt.Errorf("lightpanda text: %w", err)
		}
	}

	// Strip HTML tags to extract visible text.
	text = stripHTMLTags(text)
	return normalizeWhitespace(text), nil
}

// Click clicks an element identified by ref.
func (lp *LightpandaEngine) Click(ctx context.Context, ref string) error {
	lp.mu.Lock()
	defer lp.mu.Unlock()

	tab := lp.tabs[lp.current]
	if tab == nil {
		return errors.New("no page loaded")
	}

	nodeID, ok := tab.refs[ref]
	if !ok {
		return fmt.Errorf("ref %q not found (take a snapshot first)", ref)
	}

	clickCtx, clickCancel := context.WithTimeout(tab.ctx, 10*time.Second)
	defer clickCancel()

	return chromedp.Run(clickCtx, chromedp.ActionFunc(func(ctx context.Context) error {
		// Scroll into view.
		if err := chromedp.FromContext(ctx).Target.Execute(ctx, "DOM.scrollIntoViewIfNeeded", map[string]any{
			"backendNodeId": nodeID,
		}, nil); err != nil {
			slog.Debug("lightpanda scroll failed (non-fatal)", "err", err)
		}
		// Focus the element.
		if err := chromedp.FromContext(ctx).Target.Execute(ctx, "DOM.focus", map[string]any{
			"backendNodeId": nodeID,
		}, nil); err != nil {
			return fmt.Errorf("focus for click: %w", err)
		}
		// Get element box model for coordinates.
		var result json.RawMessage
		if err := chromedp.FromContext(ctx).Target.Execute(ctx, "DOM.getBoxModel", map[string]any{
			"backendNodeId": nodeID,
		}, &result); err != nil {
			// Fallback: simulate via JS click.
			return chromedp.FromContext(ctx).Target.Execute(ctx, "DOM.resolveNode", map[string]any{
				"backendNodeId": nodeID,
			}, nil)
		}
		var box struct {
			Model struct {
				Content []float64 `json:"content"`
			} `json:"model"`
		}
		if err := json.Unmarshal(result, &box); err != nil || len(box.Model.Content) < 4 {
			return fmt.Errorf("invalid box model for click")
		}
		x := (box.Model.Content[0] + box.Model.Content[2]) / 2
		y := (box.Model.Content[1] + box.Model.Content[5]) / 2
		// Mouse click.
		if err := chromedp.FromContext(ctx).Target.Execute(ctx, "Input.dispatchMouseEvent", map[string]any{
			"type": "mousePressed", "button": "left", "clickCount": 1, "x": x, "y": y,
		}, nil); err != nil {
			return err
		}
		return chromedp.FromContext(ctx).Target.Execute(ctx, "Input.dispatchMouseEvent", map[string]any{
			"type": "mouseReleased", "button": "left", "clickCount": 1, "x": x, "y": y,
		}, nil)
	}))
}

// Type enters text into an element identified by ref.
func (lp *LightpandaEngine) Type(ctx context.Context, ref, text string) error {
	lp.mu.Lock()
	defer lp.mu.Unlock()

	tab := lp.tabs[lp.current]
	if tab == nil {
		return errors.New("no page loaded")
	}

	nodeID, ok := tab.refs[ref]
	if !ok {
		return fmt.Errorf("ref %q not found (take a snapshot first)", ref)
	}

	typeCtx, typeCancel := context.WithTimeout(tab.ctx, 10*time.Second)
	defer typeCancel()

	return chromedp.Run(typeCtx, chromedp.ActionFunc(func(ctx context.Context) error {
		// Focus the element.
		if err := chromedp.FromContext(ctx).Target.Execute(ctx, "DOM.focus", map[string]any{
			"backendNodeId": nodeID,
		}, nil); err != nil {
			return fmt.Errorf("focus for type: %w", err)
		}
		// Type text via Input.insertText.
		return chromedp.FromContext(ctx).Target.Execute(ctx, "Input.insertText", map[string]any{
			"text": text,
		}, nil)
	}))
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

// ---------- accessibility tree helpers ----------

// buildSnapshotFromAXTree converts CDP accessibility nodes to SnapshotNodes.
func buildSnapshotFromAXTree(axNodes []*accessibility.Node, refs map[string]int64, filter string) []SnapshotNode {
	if len(axNodes) == 0 {
		return nil
	}

	// Build parent map for depth calculation.
	parentMap := make(map[accessibility.NodeID]accessibility.NodeID, len(axNodes))
	for _, n := range axNodes {
		for _, childID := range n.ChildIDs {
			parentMap[childID] = n.NodeID
		}
	}

	depth := func(id accessibility.NodeID) int {
		d := 0
		for {
			pid, ok := parentMap[id]
			if !ok {
				return d
			}
			d++
			id = pid
		}
	}

	var nodes []SnapshotNode
	seq := 0
	for _, n := range axNodes {
		role := axValueStr(n.Role)
		if role == "" || role == "none" || role == "InlineTextBox" || role == "LineBreak" {
			continue
		}

		name := axValueStr(n.Name)
		value := axValueStr(n.Value)
		interactive := isInteractiveRole(role)

		if filter == "interactive" && !interactive {
			continue
		}

		// Skip generic containers with no name.
		if role == "generic" && name == "" && !interactive {
			continue
		}

		ref := fmt.Sprintf("e%d", seq)
		seq++

		if n.BackendDOMNodeID != 0 {
			refs[ref] = n.BackendDOMNodeID.Int64()
		}

		nodes = append(nodes, SnapshotNode{
			Ref:         ref,
			Role:        role,
			Name:        name,
			Value:       value,
			Depth:       depth(n.NodeID),
			Interactive: interactive,
		})
	}

	return nodes
}

func axValueStr(v *accessibility.Value) string {
	if v == nil {
		return ""
	}
	// Value.Value is jsontext.Value; unmarshal to get string.
	var s string
	if err := json.Unmarshal(v.Value, &s); err != nil {
		return ""
	}
	return s
}

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
