package engine

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/chromedp/cdproto/accessibility"
)

func TestLightpandaEngine_Name(t *testing.T) {
	// Cannot create a full LightpandaEngine without a binary,
	// but we can test the struct directly.
	lp := &LightpandaEngine{tabs: make(map[string]*lpTab)}
	if lp.Name() != "lightpanda" {
		t.Errorf("Name() = %q, want %q", lp.Name(), "lightpanda")
	}
}

func TestLightpandaEngine_Capabilities(t *testing.T) {
	lp := &LightpandaEngine{tabs: make(map[string]*lpTab)}
	caps := lp.Capabilities()

	expected := map[Capability]bool{
		CapNavigate: true,
		CapSnapshot: true,
		CapText:     true,
		CapClick:    true,
		CapType:     true,
	}

	if len(caps) != len(expected) {
		t.Fatalf("Capabilities() length = %d, want %d", len(caps), len(expected))
	}
	for _, c := range caps {
		if !expected[c] {
			t.Errorf("unexpected capability %q", c)
		}
	}
}

func TestLightpandaEngine_SnapshotNoPage(t *testing.T) {
	lp := &LightpandaEngine{tabs: make(map[string]*lpTab)}
	_, err := lp.Snapshot(t.Context(), "")
	if err == nil {
		t.Error("expected error when no page loaded")
	}
}

func TestLightpandaEngine_TextNoPage(t *testing.T) {
	lp := &LightpandaEngine{tabs: make(map[string]*lpTab)}
	_, err := lp.Text(t.Context())
	if err == nil {
		t.Error("expected error when no page loaded")
	}
}

func TestLightpandaEngine_ClickNoPage(t *testing.T) {
	lp := &LightpandaEngine{tabs: make(map[string]*lpTab)}
	err := lp.Click(t.Context(), "e0")
	if err == nil {
		t.Error("expected error when no page loaded")
	}
}

func TestLightpandaEngine_TypeNoPage(t *testing.T) {
	lp := &LightpandaEngine{tabs: make(map[string]*lpTab)}
	err := lp.Type(t.Context(), "e0", "test")
	if err == nil {
		t.Error("expected error when no page loaded")
	}
}

func TestLightpandaEngine_CloseEmpty(t *testing.T) {
	lp := &LightpandaEngine{tabs: make(map[string]*lpTab)}
	if err := lp.Close(); err != nil {
		t.Errorf("Close() error = %v", err)
	}
}

func TestFindLightpandaBinary_Empty(t *testing.T) {
	// Will return empty string on most CI/dev machines.
	// Just make sure it doesn't panic.
	_ = findLightpandaBinary()
}

func TestIsInteractiveRole(t *testing.T) {
	tests := []struct {
		role string
		want bool
	}{
		{"button", true},
		{"link", true},
		{"textbox", true},
		{"checkbox", true},
		{"radio", true},
		{"combobox", true},
		{"menuitem", true},
		{"tab", true},
		{"switch", true},
		{"searchbox", true},
		{"spinbutton", true},
		{"slider", true},
		{"generic", false},
		{"heading", false},
		{"list", false},
		{"", false},
	}
	for _, tt := range tests {
		if got := isInteractiveRole(tt.role); got != tt.want {
			t.Errorf("isInteractiveRole(%q) = %v, want %v", tt.role, got, tt.want)
		}
	}
}

func TestStripHTMLTags(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{"<p>Hello</p>", " Hello "},
		{"no tags", "no tags"},
		{"<b>bold</b> and <i>italic</i>", " bold  and  italic "},
		{"<script>alert('xss')</script>", " alert('xss') "},
		{"", ""},
	}
	for _, tt := range tests {
		if got := stripHTMLTags(tt.input); got != tt.want {
			t.Errorf("stripHTMLTags(%q) = %q, want %q", tt.input, got, tt.want)
		}
	}
}

func TestBuildSnapshotFromAXTree(t *testing.T) {
	// Create mock AX nodes.
	makeValue := func(s string) *accessibility.Value {
		bs, _ := json.Marshal(s)
		return &accessibility.Value{Value: bs}
	}

	nodes := []*accessibility.Node{
		{
			NodeID:           "root",
			Role:             makeValue("WebArea"),
			Name:             makeValue("Test Page"),
			ChildIDs:         []accessibility.NodeID{"btn1", "heading1"},
			BackendDOMNodeID: 1,
		},
		{
			NodeID:           "btn1",
			Role:             makeValue("button"),
			Name:             makeValue("Click Me"),
			BackendDOMNodeID: 10,
		},
		{
			NodeID:           "heading1",
			Role:             makeValue("heading"),
			Name:             makeValue("Welcome"),
			BackendDOMNodeID: 20,
		},
	}

	refs := make(map[string]int64)
	result := buildSnapshotFromAXTree(nodes, refs, "")

	if len(result) != 3 {
		t.Fatalf("expected 3 nodes, got %d", len(result))
	}

	// First should be WebArea (root).
	if result[0].Role != "WebArea" {
		t.Errorf("node[0].Role = %q, want %q", result[0].Role, "WebArea")
	}
	if result[0].Depth != 0 {
		t.Errorf("node[0].Depth = %d, want 0", result[0].Depth)
	}

	// Button should be interactive.
	var btnNode *SnapshotNode
	for i := range result {
		if result[i].Role == "button" {
			btnNode = &result[i]
			break
		}
	}
	if btnNode == nil {
		t.Fatal("button node not found")
	}
	if !btnNode.Interactive {
		t.Error("button should be interactive")
	}
	if btnNode.Name != "Click Me" {
		t.Errorf("button name = %q, want %q", btnNode.Name, "Click Me")
	}
	if btnNode.Depth != 1 {
		t.Errorf("button depth = %d, want 1", btnNode.Depth)
	}

	// Verify refs mapping.
	if _, ok := refs[btnNode.Ref]; !ok {
		t.Error("button ref not in refs map")
	}
}

func TestBuildSnapshotFromAXTree_InteractiveFilter(t *testing.T) {
	makeValue := func(s string) *accessibility.Value {
		bs, _ := json.Marshal(s)
		return &accessibility.Value{Value: bs}
	}

	nodes := []*accessibility.Node{
		{
			NodeID:           "root",
			Role:             makeValue("WebArea"),
			Name:             makeValue("Page"),
			BackendDOMNodeID: 1,
		},
		{
			NodeID:           "btn",
			Role:             makeValue("button"),
			Name:             makeValue("Submit"),
			BackendDOMNodeID: 10,
		},
		{
			NodeID:           "heading",
			Role:             makeValue("heading"),
			Name:             makeValue("Title"),
			BackendDOMNodeID: 20,
		},
	}

	refs := make(map[string]int64)
	result := buildSnapshotFromAXTree(nodes, refs, "interactive")

	// Only button should pass the interactive filter.
	if len(result) != 1 {
		t.Fatalf("expected 1 interactive node, got %d", len(result))
	}
	if result[0].Role != "button" {
		t.Errorf("expected button, got %q", result[0].Role)
	}
}

func TestBuildSnapshotFromAXTree_SkipsNoneAndGeneric(t *testing.T) {
	makeValue := func(s string) *accessibility.Value {
		bs, _ := json.Marshal(s)
		return &accessibility.Value{Value: bs}
	}

	nodes := []*accessibility.Node{
		{
			NodeID: "n1",
			Role:   makeValue("none"),
		},
		{
			NodeID: "n2",
			Role:   makeValue("InlineTextBox"),
		},
		{
			NodeID: "n3",
			Role:   makeValue("generic"),
			Name:   makeValue(""),
		},
		{
			NodeID:           "n4",
			Role:             makeValue("button"),
			Name:             makeValue("OK"),
			BackendDOMNodeID: 5,
		},
	}

	refs := make(map[string]int64)
	result := buildSnapshotFromAXTree(nodes, refs, "")

	if len(result) != 1 {
		t.Fatalf("expected 1 node (button only), got %d", len(result))
	}
	if result[0].Role != "button" {
		t.Errorf("expected button, got %q", result[0].Role)
	}
}

func TestAxValueStr(t *testing.T) {
	// nil value.
	if s := axValueStr(nil); s != "" {
		t.Errorf("axValueStr(nil) = %q, want empty", s)
	}

	// Valid JSON string value.
	bs, _ := json.Marshal("hello")
	v := &accessibility.Value{Value: bs}
	if s := axValueStr(v); s != "hello" {
		t.Errorf("axValueStr() = %q, want %q", s, "hello")
	}
}

func TestDefaultLightpandaRule(t *testing.T) {
	rule := DefaultLightpandaRule{}

	if rule.Name() != "default-lightpanda" {
		t.Errorf("Name() = %q, want %q", rule.Name(), "default-lightpanda")
	}

	tests := []struct {
		op   Capability
		want Decision
	}{
		{CapNavigate, UseLightpanda},
		{CapSnapshot, UseLightpanda},
		{CapText, UseLightpanda},
		{CapClick, UseLightpanda},
		{CapType, UseLightpanda},
		{CapScreenshot, Undecided},
		{CapPDF, Undecided},
		{CapEvaluate, Undecided},
		{CapCookies, Undecided},
	}
	for _, tt := range tests {
		if got := rule.Decide(tt.op, ""); got != tt.want {
			t.Errorf("Decide(%v) = %v, want %v", tt.op, got, tt.want)
		}
	}
}

func TestRouterLightpandaMode(t *testing.T) {
	lp := &LightpandaEngine{tabs: make(map[string]*lpTab)}
	r := NewRouterWithEngines(ModeLightpanda, nil, lp)

	if r.Mode() != ModeLightpanda {
		t.Errorf("Mode() = %q, want %q", r.Mode(), ModeLightpanda)
	}

	// Navigate should route to lightpanda.
	eng := r.Route(CapNavigate, "https://example.com")
	if eng == nil {
		t.Fatal("Route(CapNavigate) returned nil, want lightpanda")
	}
	if eng.Name() != "lightpanda" {
		t.Errorf("Route(CapNavigate).Name() = %q, want %q", eng.Name(), "lightpanda")
	}

	// Screenshot should route to chrome (nil).
	eng = r.Route(CapScreenshot, "https://example.com")
	if eng != nil {
		t.Errorf("Route(CapScreenshot) = %v, want nil (chrome)", eng)
	}

	// Verify Lightpanda() accessor.
	if r.Lightpanda() == nil {
		t.Error("Lightpanda() returned nil")
	}
}

func TestRouterWithEngines_BackwardCompat(t *testing.T) {
	lite := NewLiteEngine()
	r := NewRouter(ModeLite, lite)

	// NewRouter (backward compat) should still work.
	eng := r.Route(CapNavigate, "https://example.com")
	if eng == nil {
		t.Fatal("Route(CapNavigate) returned nil")
	}
	if eng.Name() != "lite" {
		t.Errorf("Route(CapNavigate).Name() = %q, want %q", eng.Name(), "lite")
	}

	// Lightpanda should be nil.
	if r.Lightpanda() != nil {
		t.Error("Lightpanda() should be nil for NewRouter()")
	}
}

func TestWaitForCDP_Timeout(t *testing.T) {
	// Should timeout quickly when nothing is listening.
	err := waitForCDP("ws://127.0.0.1:19999", 500*time.Millisecond)
	if err == nil {
		t.Error("expected timeout error")
	}
}

func TestFindFreePortLP(t *testing.T) {
	port, err := findFreePortLP()
	if err != nil {
		t.Fatalf("findFreePortLP() error = %v", err)
	}
	if port <= 0 || port > 65535 {
		t.Errorf("port = %d, want valid range", port)
	}
}
