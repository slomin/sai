package chat

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/charmbracelet/bubbles/textinput"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	appctx "github.com/sai-project/sai-go/internal/context"
	"github.com/sai-project/sai-go/internal/lm"
)

// Options configure the chat Bubble Tea program.
type Options struct {
	Context      context.Context
	Client       *lm.Client
	SystemPrompt string
	Title        string
	AutoPrompt   string
	Stream       bool
}

// NewProgram wires the chat model.
func NewProgram(opts Options) *tea.Program {
	m := newModel(opts)
	var programOpts []tea.ProgramOption
	if opts.Context != nil {
		programOpts = append(programOpts, tea.WithContext(opts.Context))
	}
	return tea.NewProgram(m, programOpts...)
}

type model struct {
	ctx            context.Context
	client         *lm.Client
	system         string
	title          string
	autoPrompt     string
	history        []lm.ChatMessage
	viewport       viewport.Model
	input          textinput.Model
	sending        bool
	err            error
	streamEnabled  bool
	streamCh       chan streamEvent
	streamCancel   context.CancelFunc
	pendingRequest []lm.ChatMessage
	streamLauncher streamLauncher
}

type autoStartMsg struct{}

type assistantResponseMsg struct {
	content string
}

type assistantErrorMsg struct {
	err error
}

type streamEvent struct {
	chunk string
	err   error
	done  bool
}

type streamEventMsg struct {
	event streamEvent
}

type streamLauncher func(ctx context.Context, client *lm.Client, system string, history []lm.ChatMessage) (chan streamEvent, context.CancelFunc)

func newModel(opts Options) model {
	vp := viewport.New(0, 0)
	vp.Style = lipgloss.NewStyle().Padding(1, 2)

	input := textinput.New()
	input.Placeholder = "Type a message and press Enter"
	input.Prompt = "› "
	input.Focus()

	return model{
		ctx:            opts.Context,
		client:         opts.Client,
		system:         opts.SystemPrompt,
		title:          defaultTitle(opts.Title),
		autoPrompt:     strings.TrimSpace(opts.AutoPrompt),
		history:        make([]lm.ChatMessage, 0, 16),
		viewport:       vp,
		input:          input,
		streamEnabled:  opts.Stream,
		streamLauncher: defaultStreamLauncher,
	}
}

var chatSnapshotConfig = appctx.SnapshotConfig{
	DirectoryLimit: 50,
	HistoryLimit:   25,
	IncludeGit:     true,
	IncludeEnv:     true,
}

func (m model) Init() tea.Cmd {
	cmds := []tea.Cmd{textinput.Blink}
	if m.autoPrompt != "" {
		cmds = append(cmds, func() tea.Msg { return autoStartMsg{} })
	}
	return tea.Batch(cmds...)
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.viewport.Width = msg.Width
		m.viewport.Height = max(6, msg.Height-5)
		m.input.Width = max(10, msg.Width-4)
		m.refreshViewport()
		m.viewport.GotoBottom()
		return m, nil

	case assistantResponseMsg:
		m.sending = false
		m.err = nil
		m.history = append(m.history, lm.ChatMessage{Role: "assistant", Content: msg.content})
		m.refreshViewport()
		m.viewport.GotoBottom()
		return m, nil

	case streamEventMsg:
		return m.handleStreamEvent(msg.event)

	case assistantErrorMsg:
		m.sending = false
		m.err = msg.err
		return m, nil

	case autoStartMsg:
		return m.handleAutoStart()
	case tea.KeyMsg:
		switch msg.Type {
		case tea.KeyCtrlC, tea.KeyEsc:
			m.stopStreaming()
			return m, tea.Quit
		case tea.KeyEnter:
			return m.handleSubmit()
		}
	}

	var cmd tea.Cmd
	m.input, cmd = m.input.Update(msg)
	return m, cmd
}

func (m model) View() string {
	header := lipgloss.NewStyle().
		Foreground(colorAccent).
		Bold(true).
		Render(m.title)

	status := m.renderStatus()

	return lipgloss.JoinVertical(
		lipgloss.Left,
		header,
		"",
		m.viewport.View(),
		"",
		status,
		m.input.View(),
		lipgloss.NewStyle().Foreground(colorMuted).Render("Esc to quit • Enter to send"),
	)
}

func (m model) renderStatus() string {
	if m.sending {
		label := "Thinking…"
		if m.streamEnabled && m.streamCh != nil {
			label = "Streaming…"
		}
		return lipgloss.NewStyle().Foreground(colorAccent).Render(label)
	}
	if m.err != nil {
		return lipgloss.NewStyle().Foreground(colorError).Render(fmt.Sprintf("Error: %v", m.err))
	}
	return ""
}

func (m model) handleSubmit() (tea.Model, tea.Cmd) {
	if m.sending {
		return m, nil
	}
	trimmed := strings.TrimSpace(m.input.Value())
	if trimmed == "" {
		m.input.SetValue("")
		return m, nil
	}

	m.history = append(m.history, lm.ChatMessage{Role: "user", Content: trimmed})
	m.input.SetValue("")
	m.sending = true
	m.err = nil
	m.refreshViewport()
	m.viewport.GotoBottom()

	historyCopy := append([]lm.ChatMessage(nil), m.history...)
	composed, err := appctx.ComposePromptWithConfig(trimmed, chatSnapshotConfig)
	if err != nil {
		m.sending = false
		m.err = err
		return m, nil
	}
	historyCopy[len(historyCopy)-1].Content = composed
	if m.streamEnabled {
		cmd := m.startStreaming(historyCopy)
		return m, cmd
	}
	return m, tea.Batch(sendChatCmd(m.ctx, m.client, m.system, historyCopy))
}

func (m model) handleAutoStart() (tea.Model, tea.Cmd) {
	if m.autoPrompt == "" || m.sending {
		return m, nil
	}
	prompt := m.autoPrompt
	m.autoPrompt = ""
	m.history = append(m.history, lm.ChatMessage{Role: "user", Content: prompt})
	m.sending = true
	m.err = nil
	m.refreshViewport()
	m.viewport.GotoBottom()

	historyCopy := append([]lm.ChatMessage(nil), m.history...)
	composed, err := appctx.ComposePromptWithConfig(prompt, chatSnapshotConfig)
	if err != nil {
		m.sending = false
		m.err = err
		return m, nil
	}
	historyCopy[len(historyCopy)-1].Content = composed
	if m.streamEnabled {
		cmd := m.startStreaming(historyCopy)
		return m, cmd
	}
	return m, tea.Batch(sendChatCmd(m.ctx, m.client, m.system, historyCopy))
}

func (m *model) startStreaming(history []lm.ChatMessage) tea.Cmd {
	m.stopStreaming()
	m.pendingRequest = append([]lm.ChatMessage(nil), history...)
	m.addAssistantPlaceholder()
	m.refreshViewport()
	baseCtx := m.ctx
	if baseCtx == nil {
		baseCtx = context.Background()
	}
	launcher := m.streamLauncher
	if launcher == nil {
		launcher = defaultStreamLauncher
	}
	streamCh, cancel := launcher(baseCtx, m.client, m.system, append([]lm.ChatMessage(nil), history...))
	m.streamCh = streamCh
	m.streamCancel = cancel
	return listenStreamCmd(streamCh)
}

func (m *model) stopStreaming() {
	if m.streamCancel != nil {
		m.streamCancel()
		m.streamCancel = nil
	}
	m.streamCh = nil
}

func defaultStreamLauncher(ctx context.Context, client *lm.Client, system string, history []lm.ChatMessage) (chan streamEvent, context.CancelFunc) {
	ch := make(chan streamEvent, 16)
	baseCtx := ctx
	if baseCtx == nil {
		baseCtx = context.Background()
	}
	streamCtx, cancel := context.WithCancel(baseCtx)
	go func() {
		defer close(ch)
		handler := func(chunk string) error {
			select {
			case ch <- streamEvent{chunk: chunk}:
				return nil
			case <-streamCtx.Done():
				return streamCtx.Err()
			}
		}
		err := client.StreamChat(streamCtx, system, history, handler)
		if err != nil && !errors.Is(err, context.Canceled) {
			ch <- streamEvent{err: err}
		}
		ch <- streamEvent{done: true}
	}()
	return ch, func() {
		cancel()
	}
}

func (m *model) refreshViewport() {
	var b strings.Builder
	for _, entry := range m.history {
		switch entry.Role {
		case "user":
			fmt.Fprintf(&b, "You:\n%s\n\n", strings.TrimSpace(entry.Content))
		case "assistant":
			fmt.Fprintf(&b, "SAI:\n%s\n\n", strings.TrimSpace(entry.Content))
		}
	}
	if m.sending && (!m.streamEnabled || m.streamCh == nil) {
		fmt.Fprintf(&b, "SAI:\n%s\n\n", "…")
	}
	m.viewport.SetContent(strings.TrimRight(b.String(), "\n"))
}

func sendChatCmd(ctx context.Context, client *lm.Client, system string, history []lm.ChatMessage) tea.Cmd {
	return func() tea.Msg {
		callCtx := ctx
		if callCtx == nil {
			callCtx = context.Background()
		}
		response, err := client.Chat(callCtx, system, history)
		if err != nil {
			return assistantErrorMsg{err: err}
		}
		return assistantResponseMsg{content: response}
	}
}

func listenStreamCmd(ch <-chan streamEvent) tea.Cmd {
	return func() tea.Msg {
		ev, ok := <-ch
		if !ok {
			return streamEventMsg{event: streamEvent{done: true}}
		}
		return streamEventMsg{event: ev}
	}
}

func (m *model) ensureAssistantEntry() {
	if len(m.history) == 0 || m.history[len(m.history)-1].Role != "assistant" {
		m.history = append(m.history, lm.ChatMessage{Role: "assistant", Content: ""})
	}
}

func (m *model) addAssistantPlaceholder() {
	if len(m.history) > 0 {
		last := m.history[len(m.history)-1]
		if last.Role == "assistant" && strings.TrimSpace(last.Content) == "" {
			return
		}
	}
	m.history = append(m.history, lm.ChatMessage{Role: "assistant", Content: ""})
}

func (m *model) appendStreamChunk(chunk string) {
	if strings.TrimSpace(chunk) == "" {
		return
	}
	m.ensureAssistantEntry()
	idx := len(m.history) - 1
	m.history[idx].Content += chunk
}

func (m *model) dropAssistantPlaceholder() {
	if len(m.history) == 0 {
		return
	}
	last := m.history[len(m.history)-1]
	if last.Role == "assistant" && strings.TrimSpace(last.Content) == "" {
		m.history = m.history[:len(m.history)-1]
	}
}

func (m model) handleStreamEvent(ev streamEvent) (tea.Model, tea.Cmd) {
	if ev.err != nil {
		streamErr := ev.err
		m.stopStreaming()
		m.sending = false
		if errors.Is(streamErr, context.Canceled) {
			return m, nil
		}
		if errors.Is(streamErr, lm.ErrStreamUnsupported) && len(m.pendingRequest) > 0 {
			history := append([]lm.ChatMessage(nil), m.pendingRequest...)
			m.pendingRequest = nil
			m.streamEnabled = false
			m.dropAssistantPlaceholder()
			m.refreshViewport()
			m.err = nil
			m.sending = true
			return m, tea.Batch(sendChatCmd(m.ctx, m.client, m.system, history))
		}
		m.err = streamErr
		m.pendingRequest = nil
		m.refreshViewport()
		return m, nil
	}

	if ev.chunk != "" {
		m.appendStreamChunk(ev.chunk)
		m.refreshViewport()
		m.viewport.GotoBottom()
		if m.streamCh != nil {
			return m, listenStreamCmd(m.streamCh)
		}
		return m, nil
	}

	if ev.done {
		m.stopStreaming()
		m.sending = false
		m.pendingRequest = nil
		m.refreshViewport()
		m.viewport.GotoBottom()
		return m, nil
	}

	if m.streamCh != nil {
		return m, listenStreamCmd(m.streamCh)
	}
	return m, nil
}

var (
	colorAccent = lipgloss.Color("#6CAAFF")
	colorError  = lipgloss.Color("#FF7878")
	colorMuted  = lipgloss.Color("#969BA5")
)

func defaultTitle(in string) string {
	if strings.TrimSpace(in) != "" {
		return strings.TrimSpace(in)
	}
	return "SAI Chat"
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
