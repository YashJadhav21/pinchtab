package engine

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestLightpandaEngine_Name(t *testing.T) {
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

func TestLightpandaEngine_ClickNoSelector(t *testing.T) {
	lp := &LightpandaEngine{
		tabs:    make(map[string]*lpTab),
		current: "tab1",
	}
	lp.tabs["tab1"] = &lpTab{
		refs:      make(map[string]int64),
		selectors: make(map[string]string),
	}
	err := lp.Click(t.Context(), "e99")
	if err == nil {
		t.Error("expected error for unknown ref")
	}
	if !strings.Contains(err.Error(), "not found") {
		t.Errorf("error should mention 'not found', got: %v", err)
	}
}

func TestLightpandaEngine_TypeNoSelector(t *testing.T) {
	lp := &LightpandaEngine{
		tabs:    make(map[string]*lpTab),
		current: "tab1",
	}
	lp.tabs["tab1"] = &lpTab{
		refs:      make(map[string]int64),
		selectors: make(map[string]string),
	}
	err := lp.Type(t.Context(), "e99", "hello")
	if err == nil {
		t.Error("expected error for unknown ref")
	}
	if !strings.Contains(err.Error(), "not found") {
		t.Errorf("error should mention 'not found', got: %v", err)
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

// ---------- snapshotJS / jsSnapshotNode tests ----------

func TestSnapshotJS_ReturnsValidJS(t *testing.T) {
	js := snapshotJS("")
	if !strings.Contains(js, "function inferRole") {
		t.Error("snapshotJS should contain inferRole function")
	}
	if !strings.Contains(js, "JSON.stringify") {
		t.Error("snapshotJS should return JSON.stringify")
	}
	if strings.Contains(js, "INTERACTIVE_ONLY = true") {
		t.Error("snapshotJS('') should set INTERACTIVE_ONLY = false")
	}
}

func TestSnapshotJS_InteractiveFilter(t *testing.T) {
	js := snapshotJS("interactive")
	if !strings.Contains(js, "INTERACTIVE_ONLY = true") {
		t.Error("snapshotJS('interactive') should set INTERACTIVE_ONLY = true")
	}
}

func TestSnapshotJS_NonInteractiveFilter(t *testing.T) {
	js := snapshotJS("other")
	if !strings.Contains(js, "INTERACTIVE_ONLY = false") {
		t.Error("snapshotJS with non-interactive filter should set INTERACTIVE_ONLY = false")
	}
}

func TestJsonString(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{"hello", `"hello"`},
		{`has "quotes"`, `"has \"quotes\""`},
		{"has\nnewline", `"has\nnewline"`},
		{"", `""`},
		{`back\slash`, `"back\\slash"`},
		{"<script>alert('xss')</script>", `"\u003cscript\u003ealert('xss')\u003c/script\u003e"`},
	}
	for _, tt := range tests {
		got := jsonString(tt.input)
		if got != tt.want {
			t.Errorf("jsonString(%q) = %s, want %s", tt.input, got, tt.want)
		}
	}
}

func TestJsSnapshotNode_Unmarshal(t *testing.T) {
	raw := `[
		{"role":"button","name":"Click Me","tag":"button","value":"","depth":1,"interactive":true,"selector":"#btn1"},
		{"role":"heading","name":"Welcome","tag":"h1","value":"","depth":0,"interactive":false,"selector":"h1"},
		{"role":"textbox","name":"Email","tag":"input","value":"test@example.com","depth":2,"interactive":true,"selector":"#email"}
	]`

	var nodes []jsSnapshotNode
	if err := json.Unmarshal([]byte(raw), &nodes); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if len(nodes) != 3 {
		t.Fatalf("expected 3 nodes, got %d", len(nodes))
	}

	// Button node.
	if nodes[0].Role != "button" || nodes[0].Name != "Click Me" || !nodes[0].Interactive {
		t.Errorf("button node = %+v", nodes[0])
	}
	if nodes[0].Selector != "#btn1" {
		t.Errorf("button selector = %q, want %q", nodes[0].Selector, "#btn1")
	}

	// Heading node.
	if nodes[1].Role != "heading" || nodes[1].Interactive {
		t.Errorf("heading node = %+v", nodes[1])
	}

	// Textbox with value.
	if nodes[2].Role != "textbox" || nodes[2].Value != "test@example.com" {
		t.Errorf("textbox node = %+v", nodes[2])
	}
}

func TestJsSnapshotNode_EmptyArray(t *testing.T) {
	var nodes []jsSnapshotNode
	if err := json.Unmarshal([]byte("[]"), &nodes); err != nil {
		t.Fatalf("unmarshal empty: %v", err)
	}
	if len(nodes) != 0 {
		t.Errorf("expected 0 nodes, got %d", len(nodes))
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
