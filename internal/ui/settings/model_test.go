package settingsui

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/slomin/sai/internal/settings"
)

var testDefaults = defaults{
	remoteEndpoint: "http://remote",
	remoteModel:    "remote-model",
	localEndpoint:  "http://local",
	localModel:     "local-model",
}

func TestNewStateSeedsFromCurrentConfig(t *testing.T) {
	opts := Options{
		Current: settings.Config{
			Mode:     settings.ModeCustom,
			Endpoint: "http://custom",
			Model:    "custom-model",
			APIKey:   "secret",
		},
	}
	st := newState(opts, testDefaults)
	if st.mode != settings.ModeCustom {
		t.Fatalf("expected custom mode, got %s", st.mode)
	}
	if st.endpoint != "http://custom" || st.model != "custom-model" {
		t.Fatalf("state did not seed endpoint/model from current config: %+v", st)
	}
	if st.apiKey != "secret" {
		t.Fatalf("state did not seed api key")
	}
}

func TestStateApplyPresetRemoteUsesDefaults(t *testing.T) {
	st := state{}
	st.applyPreset(settings.ModeRemote, testDefaults)
	if st.mode != settings.ModeRemote {
		t.Fatalf("mode should be remote, got %s", st.mode)
	}
	if st.endpoint != testDefaults.remoteEndpoint {
		t.Fatalf("expected remote endpoint, got %s", st.endpoint)
	}
	if st.model != testDefaults.remoteModel {
		t.Fatalf("expected remote model, got %s", st.model)
	}
}

func TestStateApplyPresetLocalUsesDefaults(t *testing.T) {
	st := state{}
	st.applyPreset(settings.ModeLocal, testDefaults)
	if st.mode != settings.ModeLocal {
		t.Fatalf("mode should be local")
	}
	if st.endpoint != testDefaults.localEndpoint {
		t.Fatalf("expected local endpoint, got %s", st.endpoint)
	}
	if st.model != testDefaults.localModel {
		t.Fatalf("expected local model, got %s", st.model)
	}
}

func TestStateToConfigTrimsWhitespace(t *testing.T) {
	st := state{
		mode:     settings.ModeCustom,
		endpoint: "  http://custom  ",
		model:    "  model  ",
		apiKey:   "  key  ",
	}
	cfg := st.toConfig()
	if cfg.Endpoint != "http://custom" || cfg.Model != "model" || cfg.APIKey != "key" {
		t.Fatalf("expected trimmed values, got %+v", cfg)
	}
}

func TestModelToggleModeCyclesPresets(t *testing.T) {
	m := newModel(Options{}, testDefaults)
	if m.state.mode != settings.ModeRemote {
		t.Fatalf("expected default mode remote, got %s", m.state.mode)
	}
	updated, _ := m.Update(tea.KeyMsg{Type: tea.KeyRight})
	m = updated.(model)
	if m.state.mode != settings.ModeLocal {
		t.Fatalf("expected mode to toggle to local, got %s", m.state.mode)
	}
	if m.state.endpoint != testDefaults.localEndpoint {
		t.Fatalf("local preset should set endpoint, got %s", m.state.endpoint)
	}
	updated, _ = m.Update(tea.KeyMsg{Type: tea.KeyRight})
	m = updated.(model)
	if m.state.mode != settings.ModeCustom {
		t.Fatalf("expected next mode custom, got %s", m.state.mode)
	}
}

func TestModelSaveGeneratesResult(t *testing.T) {
	m := newModel(Options{}, testDefaults)
	m.state.mode = settings.ModeCustom
	m.state.endpoint = "http://custom"
	m.state.model = "model"
	m.state.apiKey = "key"
	m.focusIndex = itemSave

	updated, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil {
		t.Fatalf("expected quit command")
	}
	m = updated.(model)
	if !m.result.Saved {
		t.Fatalf("expected result saved")
	}
	if m.result.Config.Endpoint != "http://custom" {
		t.Fatalf("unexpected config %+v", m.result.Config)
	}
}

func TestModelCancelExitsWithoutSaving(t *testing.T) {
	m := newModel(Options{}, testDefaults)
	m.focusIndex = itemCancel
	updated, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil {
		t.Fatalf("expected quit command")
	}
	m = updated.(model)
	if m.result.Saved {
		t.Fatalf("expected cancel to not save")
	}
}
