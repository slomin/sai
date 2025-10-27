package settingsui

import (
	"context"
	"fmt"
	"strings"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/slomin/sai/internal/settings"
)

// Options configure the settings UI program.
type Options struct {
	Context        context.Context
	Current        settings.Config
	RemoteEndpoint string
	RemoteModel    string
	LocalEndpoint  string
	LocalModel     string
}

// Result captures the outcome of a settings session.
type Result struct {
	Saved  bool
	Config settings.Config
}

// NewProgram constructs the settings Bubble Tea program.
func NewProgram(opts Options) *tea.Program {
	defs := buildDefaults(opts)
	m := newModel(opts, defs)
	var programOpts []tea.ProgramOption
	if opts.Context != nil {
		programOpts = append(programOpts, tea.WithContext(opts.Context))
	}
	return tea.NewProgram(m, programOpts...)
}

// Run executes the settings UI until completion.
func Run(opts Options) (Result, error) {
	program := NewProgram(opts)
	mdl, err := program.Run()
	if err != nil {
		return Result{}, err
	}
	if m, ok := mdl.(model); ok {
		return m.result, nil
	}
	return Result{}, fmt.Errorf("unexpected model type %T", mdl)
}

const (
	itemMode = iota
	itemEndpoint
	itemModel
	itemAPIKey
	itemSave
	itemCancel
	itemCount
)

type defaults struct {
	remoteEndpoint string
	remoteModel    string
	localEndpoint  string
	localModel     string
}

type state struct {
	mode     settings.Mode
	endpoint string
	model    string
	apiKey   string
}

func newState(opts Options, defs defaults) state {
	mode := opts.Current.Mode
	if mode == settings.ModeUnset {
		mode = settings.ModeRemote
	}

	st := state{
		mode:     mode,
		endpoint: strings.TrimSpace(opts.Current.Endpoint),
		model:    strings.TrimSpace(opts.Current.Model),
		apiKey:   strings.TrimSpace(opts.Current.APIKey),
	}

	switch mode {
	case settings.ModeRemote:
		if st.endpoint == "" {
			st.endpoint = defs.remoteEndpoint
		}
		if st.model == "" {
			st.model = defs.remoteModel
		}
	case settings.ModeLocal:
		if st.endpoint == "" {
			st.endpoint = defs.localEndpoint
		}
		if st.model == "" {
			st.model = defs.localModel
		}
	case settings.ModeCustom:
		// keep as-is
	}

	return st
}

func (s *state) applyPreset(mode settings.Mode, defs defaults) {
	s.mode = mode
	switch mode {
	case settings.ModeRemote:
		s.endpoint = defs.remoteEndpoint
		s.model = defs.remoteModel
	case settings.ModeLocal:
		s.endpoint = defs.localEndpoint
		s.model = defs.localModel
	case settings.ModeCustom:
		// retain endpoint/model for custom presets
	}
}

func (s state) toConfig() settings.Config {
	return settings.Config{
		Mode:     s.mode,
		Endpoint: strings.TrimSpace(s.endpoint),
		Model:    strings.TrimSpace(s.model),
		APIKey:   strings.TrimSpace(s.apiKey),
	}
}

type model struct {
	ctx        context.Context
	defs       defaults
	state      state
	inputs     [3]textinput.Model
	focusIndex int
	result     Result
}

func newModel(opts Options, defs defaults) model {
	st := newState(opts, defs)

	var inputs [3]textinput.Model
	inputs[0] = textinput.New()
	inputs[0].Prompt = ""
	inputs[0].Placeholder = "Custom endpoint"
	inputs[0].CharLimit = 0

	inputs[1] = textinput.New()
	inputs[1].Prompt = ""
	inputs[1].Placeholder = "Custom model"
	inputs[1].CharLimit = 0

	inputs[2] = textinput.New()
	inputs[2].Prompt = ""
	inputs[2].Placeholder = "API key"
	inputs[2].CharLimit = 0

	m := model{
		ctx:    opts.Context,
		defs:   defs,
		state:  st,
		inputs: inputs,
	}
	m.focusIndex = itemMode
	m.syncInputs()
	return m
}

func (m *model) syncInputs() {
	m.inputs[0].SetValue(m.state.endpoint)
	m.inputs[1].SetValue(m.state.model)
	m.inputs[2].SetValue(m.state.apiKey)

	for i := range m.inputs {
		m.inputs[i].Blur()
	}

	switch m.focusIndex {
	case itemEndpoint:
		if m.state.mode == settings.ModeCustom {
			m.inputs[0].Focus()
		}
	case itemModel:
		if m.state.mode == settings.ModeCustom {
			m.inputs[1].Focus()
		}
	case itemAPIKey:
		m.inputs[2].Focus()
	}
}

func (m *model) setFocus(idx int) {
	if idx < 0 {
		idx = 0
	}
	if idx >= itemCount {
		idx = itemCount - 1
	}
	m.focusIndex = idx
	m.syncInputs()
}

func (m *model) moveFocus(delta int) {
	next := m.focusIndex + delta
	if next < 0 {
		next = itemCount - 1
	} else if next >= itemCount {
		next = 0
	}
	m.focusIndex = next
	m.syncInputs()
}

func (m *model) cycleMode(delta int) {
	modes := []settings.Mode{settings.ModeRemote, settings.ModeLocal, settings.ModeCustom}
	idx := 0
	for i, mode := range modes {
		if mode == m.state.mode {
			idx = i
			break
		}
	}
	idx = (idx + len(modes) + delta) % len(modes)
	m.state.applyPreset(modes[idx], m.defs)
	if m.focusIndex == itemEndpoint || m.focusIndex == itemModel {
		if m.state.mode != settings.ModeCustom {
			m.setFocus(itemAPIKey)
		}
	}
	m.syncInputs()
}

func (m model) Init() tea.Cmd {
	return textinput.Blink
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.Type {
		case tea.KeyCtrlC, tea.KeyEsc:
			m.result = Result{}
			return m, tea.Quit
		case tea.KeyUp:
			m.moveFocus(-1)
			return m, nil
		case tea.KeyDown:
			m.moveFocus(1)
			return m, nil
		case tea.KeyTab:
			m.moveFocus(1)
			return m, nil
		case tea.KeyShiftTab:
			m.moveFocus(-1)
			return m, nil
		case tea.KeyLeft:
			if m.focusIndex == itemMode {
				m.cycleMode(-1)
				return m, nil
			}
		case tea.KeyRight:
			if m.focusIndex == itemMode {
				m.cycleMode(1)
				return m, nil
			}
		case tea.KeyEnter:
			switch m.focusIndex {
			case itemMode:
				m.cycleMode(1)
				return m, nil
			case itemSave:
				m.result = Result{Saved: true, Config: m.exportConfig()}
				return m, tea.Quit
			case itemCancel:
				m.result = Result{}
				return m, tea.Quit
			}
		}

		if handled, cmd := m.updateInputs(msg); handled {
			return m, cmd
		}
		return m, nil
	}

	return m, nil
}

func (m *model) updateInputs(msg tea.KeyMsg) (bool, tea.Cmd) {
	switch m.focusIndex {
	case itemEndpoint:
		if m.state.mode != settings.ModeCustom {
			return true, nil
		}
		ti, cmd := m.inputs[0].Update(msg)
		m.inputs[0] = ti
		m.state.endpoint = ti.Value()
		return true, cmd
	case itemModel:
		if m.state.mode != settings.ModeCustom {
			return true, nil
		}
		ti, cmd := m.inputs[1].Update(msg)
		m.inputs[1] = ti
		m.state.model = ti.Value()
		return true, cmd
	case itemAPIKey:
		ti, cmd := m.inputs[2].Update(msg)
		m.inputs[2] = ti
		m.state.apiKey = ti.Value()
		return true, cmd
	default:
		return false, nil
	}
}

func (m model) View() string {
	var b strings.Builder
	b.WriteString("SAI Settings\n\n")
	b.WriteString(m.modeView())
	b.WriteString("\n\n")
	b.WriteString(m.inputView("Endpoint", m.inputs[0], itemEndpoint))
	b.WriteString("\n")
	b.WriteString(m.inputView("Model", m.inputs[1], itemModel))
	b.WriteString("\n")
	b.WriteString(m.inputView("API Key", m.inputs[2], itemAPIKey))
	b.WriteString("\n\n")
	b.WriteString(m.actionsView())
	b.WriteString("\n")
	return b.String()
}

func (m model) modeView() string {
	options := []settings.Mode{settings.ModeRemote, settings.ModeLocal, settings.ModeCustom}
	labels := map[settings.Mode]string{
		settings.ModeRemote: "Remote",
		settings.ModeLocal:  "Local",
		settings.ModeCustom: "Custom",
	}
	var parts []string
	for _, mode := range options {
		label := labels[mode]
		if mode == m.state.mode {
			label = "[" + label + "]"
		}
		parts = append(parts, label)
	}
	indicator := " Mode: " + strings.Join(parts, "  ")
	if m.focusIndex == itemMode {
		indicator = ">" + indicator
	} else {
		indicator = " " + indicator
	}
	return indicator
}

func (m model) inputView(label string, input textinput.Model, idx int) string {
	value := input.View()
	if idx == itemEndpoint || idx == itemModel {
		if m.state.mode != settings.ModeCustom {
			value = fmt.Sprintf("%s (preset)", strings.TrimSpace(value))
		}
	}
	prefix := " "
	if m.focusIndex == idx {
		prefix = ">"
	}
	return fmt.Sprintf("%s%s: %s", prefix, label, value)
}

func (m model) actionsView() string {
	save := "[ Save ]"
	cancel := "Cancel"
	if m.focusIndex == itemSave {
		save = ">" + save
	} else {
		save = " " + save
	}
	if m.focusIndex == itemCancel {
		cancel = ">" + cancel
	} else {
		cancel = " " + cancel
	}
	return save + "    " + cancel
}

func (m model) exportConfig() settings.Config {
	cfg := m.state.toConfig()
	if m.state.mode == settings.ModeRemote {
		cfg.Endpoint = m.defs.remoteEndpoint
		cfg.Model = m.defs.remoteModel
	}
	if m.state.mode == settings.ModeLocal {
		cfg.Endpoint = m.defs.localEndpoint
		cfg.Model = m.defs.localModel
	}
	return cfg
}

func buildDefaults(opts Options) defaults {
	return defaults{
		remoteEndpoint: strings.TrimSpace(opts.RemoteEndpoint),
		remoteModel:    strings.TrimSpace(opts.RemoteModel),
		localEndpoint:  strings.TrimSpace(opts.LocalEndpoint),
		localModel:     strings.TrimSpace(opts.LocalModel),
	}
}
