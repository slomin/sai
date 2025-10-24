package chat

import (
	"context"
	"fmt"
	"strings"

	"github.com/charmbracelet/bubbles/textinput"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/sai-project/sai-go/internal/lm"
)

// Options configure the chat Bubble Tea program.
type Options struct {
	Context      context.Context
	Client       *lm.Client
	SystemPrompt string
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
	ctx     context.Context
	client  *lm.Client
	system  string
	history []lm.ChatMessage

	viewport viewport.Model
	input    textinput.Model

	sending bool
	err     error
}

type assistantResponseMsg struct {
	content string
}

type assistantErrorMsg struct {
	err error
}

func newModel(opts Options) model {
	vp := viewport.New(0, 0)
	vp.Style = lipgloss.NewStyle().Padding(1, 2)

	input := textinput.New()
	input.Placeholder = "Type a message and press Enter"
	input.Prompt = "› "
	input.Focus()

	return model{
		ctx:      opts.Context,
		client:   opts.Client,
		system:   opts.SystemPrompt,
		history:  make([]lm.ChatMessage, 0, 16),
		viewport: vp,
		input:    input,
	}
}

func (m model) Init() tea.Cmd {
	return textinput.Blink
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

	case assistantErrorMsg:
		m.sending = false
		m.err = msg.err
		return m, nil

	case tea.KeyMsg:
		switch msg.Type {
		case tea.KeyCtrlC, tea.KeyEsc:
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
		Render("SAI Chat")

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
		return lipgloss.NewStyle().Foreground(colorAccent).Render("Thinking…")
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
	return m, tea.Batch(sendChatCmd(m.ctx, m.client, m.system, historyCopy))
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
	if m.sending {
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

var (
	colorAccent = lipgloss.Color("#6CAAFF")
	colorError  = lipgloss.Color("#FF7878")
	colorMuted  = lipgloss.Color("#969BA5")
)

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
