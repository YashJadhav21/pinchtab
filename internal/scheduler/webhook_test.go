package scheduler

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

func TestSendWebhookSuccess(t *testing.T) {
	var received atomic.Bool
	var gotBody []byte
	var gotHeaders http.Header

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		received.Store(true)
		gotHeaders = r.Header.Clone()
		var err error
		gotBody, err = io.ReadAll(r.Body)
		if err != nil {
			t.Errorf("read body: %v", err)
		}
		w.WriteHeader(200)
	}))
	defer srv.Close()

	task := &Task{
		ID:      "tsk_webhook_1",
		AgentID: "a1",
		Action:  "click",
		State:   StateDone,
	}

	sendWebhook(srv.URL, task)

	if !received.Load() {
		t.Fatal("webhook was never received")
	}

	// Verify headers.
	if ct := gotHeaders.Get("Content-Type"); ct != "application/json" {
		t.Errorf("expected application/json, got %s", ct)
	}
	if ev := gotHeaders.Get("X-PinchTab-Event"); ev != "task.completed" {
		t.Errorf("expected task.completed event, got %s", ev)
	}
	if tid := gotHeaders.Get("X-PinchTab-Task-ID"); tid != "tsk_webhook_1" {
		t.Errorf("expected task ID header, got %s", tid)
	}

	// Verify body is a valid task snapshot.
	var snap Task
	if err := json.Unmarshal(gotBody, &snap); err != nil {
		t.Fatalf("unmarshal body: %v", err)
	}
	if snap.ID != "tsk_webhook_1" {
		t.Errorf("expected task ID in body, got %s", snap.ID)
	}
}

func TestSendWebhookEmptyURL(t *testing.T) {
	// Should be a no-op, no panic.
	sendWebhook("", &Task{ID: "tsk_empty"})
}

func TestSendWebhookUnsupportedScheme(t *testing.T) {
	// file:// scheme should be rejected for SSRF protection.
	sendWebhook("file:///etc/passwd", &Task{ID: "tsk_ssrf"})
	// ftp:// should also be rejected.
	sendWebhook("ftp://malicious.host/data", &Task{ID: "tsk_ssrf2"})
}

func TestSendWebhookInvalidURL(t *testing.T) {
	sendWebhook("://bad-url", &Task{ID: "tsk_bad_url"})
}

func TestSendWebhookServerError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(500)
	}))
	defer srv.Close()

	// Should not panic — just logs warning.
	sendWebhook(srv.URL, &Task{ID: "tsk_500", State: StateFailed})
}

func TestSendWebhookTimeout(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(100 * time.Millisecond)
		w.WriteHeader(200)
	}))
	defer srv.Close()

	// Use a short-timeout client for testing.
	origClient := webhookClient
	webhookClient = &http.Client{Timeout: 10 * time.Millisecond}
	defer func() { webhookClient = origClient }()

	// Should not panic — timeout is logged.
	sendWebhook(srv.URL, &Task{ID: "tsk_timeout"})
}

func TestWebhookFiredOnFinishTask(t *testing.T) {
	var received atomic.Bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		received.Store(true)
		w.WriteHeader(200)
	}))
	defer srv.Close()

	s, executor := newTestScheduler(t)
	defer executor.Close()

	task := &Task{
		ID:          "tsk_cb_1",
		AgentID:     "a1",
		Action:      "click",
		State:       StateDone,
		CallbackURL: srv.URL,
	}
	s.live["tsk_cb_1"] = task

	s.finishTask(task)

	// Give goroutine time to fire.
	time.Sleep(200 * time.Millisecond)

	if !received.Load() {
		t.Error("webhook should have been fired from finishTask")
	}
}

func TestWebhookNotFiredWithoutCallback(t *testing.T) {
	var received atomic.Bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		received.Store(true)
		w.WriteHeader(200)
	}))
	defer srv.Close()

	s, executor := newTestScheduler(t)
	defer executor.Close()

	task := &Task{
		ID:      "tsk_no_cb",
		AgentID: "a1",
		State:   StateDone,
	}
	s.live["tsk_no_cb"] = task

	s.finishTask(task)
	time.Sleep(100 * time.Millisecond)

	if received.Load() {
		t.Error("webhook should not fire when no callbackUrl")
	}
}
