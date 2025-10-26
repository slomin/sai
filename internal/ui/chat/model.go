package chat

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/atotto/clipboard"
	"github.com/charmbracelet/bubbles/textinput"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/glamour"
	glamourStyles "github.com/charmbracelet/glamour/styles"
	"github.com/charmbracelet/lipgloss"

	appctx "github.com/slomin/sai/internal/context"
	"github.com/slomin/sai/internal/lm"
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
	tail           bool
	statusMessage  string
	mdRenderer     *glamour.TermRenderer
	mdWidth        int
	snippet        *snippetSelection
}

type snippetSelection struct {
	MessageIndex int
	BlockIndex   int
	Language     string
	Code         string
	Fenced       string
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

type copySuccessMsg struct{}

type statusClearMsg struct{}

type snippetCopiedMsg struct {
	err error
}

type streamLauncher func(ctx context.Context, client *lm.Client, system string, history []lm.ChatMessage) (chan streamEvent, context.CancelFunc)

func newModel(opts Options) model {
	vp := viewport.New(0, 0)
	vp.Style = lipgloss.NewStyle().Padding(0, 1)

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
		tail:           true,
		mdWidth:        0,
	}
}

var chatSnapshotConfig = appctx.SnapshotConfig{
	DirectoryLimit: 50,
	HistoryLimit:   25,
	IncludeGit:     true,
	IncludeEnv:     true,
}

const statusMessageTTL = 2 * time.Second

func (m model) Init() tea.Cmd {
	cmds := []tea.Cmd{textinput.Blink}
	if m.autoPrompt != "" {
		cmds = append(cmds, func() tea.Msg { return autoStartMsg{} })
	}
	return tea.Batch(cmds...)
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	var cmds []tea.Cmd

	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.viewport.Width = msg.Width
		m.viewport.Height = max(6, msg.Height-6)
		m.input.Width = max(10, msg.Width-4)
		m.ensureRenderer(max(0, msg.Width-6))
		m.refreshViewport()
		return m, nil
	case tea.QuitMsg:
		m.stopStreaming()
		return m, nil

	case assistantResponseMsg:
		m.clearSnippet()
		m.sending = false
		m.err = nil
		m.statusMessage = ""
		m.tail = true
		m.history = append(m.history, lm.ChatMessage{Role: "assistant", Content: msg.content})
		m.refreshViewport()
		return m, nil

	case streamEventMsg:
		return m.handleStreamEvent(msg.event)

	case assistantErrorMsg:
		m.clearSnippet()
		m.sending = false
		m.err = msg.err
		m.statusMessage = ""
		return m, nil

	case autoStartMsg:
		return m.handleAutoStart()
	case copySuccessMsg:
		m.err = nil
		m.statusMessage = "Copied last response"
		return m, tea.Tick(statusMessageTTL, func(time.Time) tea.Msg { return statusClearMsg{} })
	case snippetCopiedMsg:
		if msg.err != nil {
			m.err = fmt.Errorf("copy snippet: %w", msg.err)
			m.statusMessage = "Copy failed – snippet remains selected"
			return m, nil
		}
		m.err = nil
		m.statusMessage = "Snippet copied to clipboard"
		return m, tea.Quit
	case statusClearMsg:
		m.statusMessage = ""
		return m, nil
	case tea.KeyMsg:
		if msg.String() == "tab" {
			hadSnippet := m.snippet != nil
			if m.selectLatestSnippet() {
				m.refreshViewport()
			} else {
				if hadSnippet {
					m.statusMessage = "No more snippets"
				} else {
					m.statusMessage = "No code block to select yet"
				}
			}
			return m, nil
		}
		if m.snippet != nil {
			switch msg.Type {
			case tea.KeyEnter:
				return m, copySnippetCmd(m.snippet.Code)
			case tea.KeyEsc:
				m.stopStreaming()
				return m, tea.Quit
			}
		}
		switch msg.Type {
		case tea.KeyCtrlC, tea.KeyEsc:
			m.stopStreaming()
			return m, tea.Quit
		case tea.KeyEnter:
			return m.handleSubmit()
		}
		switch msg.String() {
		case "alt+c":
			cmd := m.triggerCopyLastAssistant()
			if cmd != nil {
				return m, cmd
			}
			return m, nil
		case "tab":
			if m.selectLatestSnippet() {
				m.refreshViewport()
				return m, nil
			}
			m.statusMessage = "No code block to select yet"
			return m, tea.Tick(statusMessageTTL, func(time.Time) tea.Msg { return statusClearMsg{} })
		case "alt+up":
			m.viewport.LineUp(1)
			m.tail = m.viewport.AtBottom()
			return m, nil
		case "alt+down":
			m.viewport.LineDown(1)
			m.tail = m.viewport.AtBottom()
			return m, nil
		case "pgup":
			m.viewport.ViewUp()
			m.tail = m.viewport.AtBottom()
			return m, nil
		case "pgdown":
			m.viewport.ViewDown()
			m.tail = m.viewport.AtBottom()
			return m, nil
		}
	case tea.MouseMsg:
		var cmd tea.Cmd
		m.viewport, cmd = m.viewport.Update(msg)
		m.tail = m.viewport.AtBottom()
		if cmd != nil {
			cmds = append(cmds, cmd)
		}
		return m, tea.Batch(cmds...)
	}

	var cmd tea.Cmd
	m.input, cmd = m.input.Update(msg)
	if cmd != nil {
		cmds = append(cmds, cmd)
	}

	m.viewport, cmd = m.viewport.Update(msg)
	if cmd != nil {
		cmds = append(cmds, cmd)
	}
	m.tail = m.viewport.AtBottom()

	if len(cmds) == 0 {
		return m, nil
	}
	return m, tea.Batch(cmds...)
}

func (m model) View() string {
	header := lipgloss.NewStyle().
		Foreground(colorAccent).
		Bold(true).
		Render(m.title)

	status := m.renderStatus()
	snippet := ""
	if m.snippet != nil {
		snippet = m.renderSnippetDrawer()
	}

	segments := []string{
		header,
		"",
		m.viewport.View(),
	}
	if snippet != "" {
		segments = append(segments, "", snippet)
	}
	segments = append(segments,
		"",
		status,
		m.input.View(),
		lipgloss.NewStyle().Foreground(colorMuted).Render("Esc quit • Enter send • PgUp/PgDn scroll • Alt+C copy last reply • Tab select snippet"),
	)

	return lipgloss.JoinVertical(lipgloss.Left, segments...)
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
	if m.statusMessage != "" {
		return lipgloss.NewStyle().Foreground(colorAccent).Render(m.statusMessage)
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

	m.clearSnippet()
	m.history = append(m.history, lm.ChatMessage{Role: "user", Content: trimmed})
	m.input.SetValue("")
	m.sending = true
	m.err = nil
	m.statusMessage = ""
	m.tail = true
	m.refreshViewport()

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
	m.clearSnippet()
	m.history = append(m.history, lm.ChatMessage{Role: "user", Content: prompt})
	m.sending = true
	m.err = nil
	m.statusMessage = ""
	m.tail = true
	m.refreshViewport()

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
	m.tail = true
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
			fmt.Fprintf(&b, "You:\n%s\n\n", entry.Content)
		case "assistant":
			fmt.Fprintf(&b, "SAI:\n%s\n\n", m.renderAssistant(entry.Content))
		}
	}
	if m.sending && (!m.streamEnabled || m.streamCh == nil) {
		fmt.Fprintf(&b, "SAI:\n%s\n\n", "…")
	}
	m.viewport.SetContent(strings.TrimRight(b.String(), "\n"))
	if m.tail {
		m.viewport.GotoBottom()
	}
}

func (m *model) renderAssistant(content string) string {
	if m.mdRenderer == nil {
		m.ensureRenderer(max(0, m.viewport.Width-6))
	}
	if m.mdRenderer != nil {
		if rendered, err := m.mdRenderer.Render(content); err == nil {
			return strings.TrimRight(rendered, "\n")
		}
	}
	return content
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

func copyToClipboardCmd(content string) tea.Cmd {
	return func() tea.Msg {
		if err := clipboard.WriteAll(content); err != nil {
			return assistantErrorMsg{err: fmt.Errorf("copy to clipboard: %w", err)}
		}
		return copySuccessMsg{}
	}
}

func copySnippetCmd(content string) tea.Cmd {
	return func() tea.Msg {
		if err := clipboard.WriteAll(content); err != nil {
			return snippetCopiedMsg{err: err}
		}
		return snippetCopiedMsg{}
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
	if chunk == "" {
		return
	}
	m.ensureAssistantEntry()
	idx := len(m.history) - 1
	m.history[idx].Content += chunk
}

func (m *model) triggerCopyLastAssistant() tea.Cmd {
	m.clearSnippet()
	for i := len(m.history) - 1; i >= 0; i-- {
		entry := m.history[i]
		if entry.Role != "assistant" {
			continue
		}
		content := strings.TrimSpace(entry.Content)
		if content == "" {
			continue
		}
		return copyToClipboardCmd(content)
	}
	m.statusMessage = "No assistant reply to copy"
	return tea.Tick(statusMessageTTL, func(time.Time) tea.Msg { return statusClearMsg{} })
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

func (m *model) ensureRenderer(width int) {
	if width < 0 {
		width = 0
	}
	if m.mdRenderer != nil && m.mdWidth == width {
		return
	}
	opts := []glamour.TermRendererOption{
		glamour.WithStandardStyle(glamourStyles.DarkStyle),
	}
	if width > 0 {
		opts = append(opts, glamour.WithWordWrap(width))
	}
	if renderer, err := glamour.NewTermRenderer(opts...); err == nil {
		m.mdRenderer = renderer
		m.mdWidth = width
	}
}

func (m *model) renderSnippetDrawer() string {
	if m.snippet == nil {
		return ""
	}
	header := lipgloss.NewStyle().
		Foreground(colorAccent).
		Bold(true).
		Render("Snippet ready · Enter to copy & exit")

	codeStyle := lipgloss.NewStyle().
		MarginTop(1).
		Padding(1, 2).
		Border(lipgloss.RoundedBorder()).
		BorderForeground(colorAccent)

	return lipgloss.JoinVertical(
		lipgloss.Left,
		header,
		codeStyle.Render(m.snippet.Fenced),
	)
}

func (m *model) clearSnippet() {
	m.snippet = nil
	m.statusMessage = ""
}

func (m *model) selectLatestSnippet() bool {
	startIndex := len(m.history) - 1
	if m.snippet != nil {
		startIndex = m.snippet.MessageIndex
	}

	for i := startIndex; i >= 0; i-- {
		entry := m.history[i]
		if entry.Role != "assistant" {
			continue
		}

		before := -1
		if m.snippet != nil && i == m.snippet.MessageIndex {
			before = m.snippet.BlockIndex
		}

		if lang, code, blockIdx, ok := findPrevCodeBlock(entry.Content, before); ok {
			m.snippet = &snippetSelection{
				MessageIndex: i,
				BlockIndex:   blockIdx,
				Language:     lang,
				Code:         code,
				Fenced:       buildFencedBlock(lang, code),
			}
			m.statusMessage = "Snippet selected · Enter to copy & exit, Tab to cycle, Esc cancel"
			m.tail = true
			m.viewport.GotoBottom()
			return true
		}

		if m.snippet != nil && i == m.snippet.MessageIndex {
			// reset snippet to allow scanning earlier messages
			m.snippet = nil
		}
	}

	m.snippet = nil
	return false
}

func (m *model) closeOpenFence() {
	if len(m.history) == 0 {
		return
	}
	idx := len(m.history) - 1
	if m.history[idx].Role != "assistant" {
		return
	}
	if strings.Count(m.history[idx].Content, "```")%2 != 0 {
		if !strings.HasSuffix(m.history[idx].Content, "\n") {
			m.history[idx].Content += "\n"
		}
		m.history[idx].Content += "```"
	}
}

func (m model) handleStreamEvent(ev streamEvent) (tea.Model, tea.Cmd) {
	if ev.err != nil {
		streamErr := ev.err
		m.stopStreaming()
		m.clearSnippet()
		m.sending = false
		if errors.Is(streamErr, context.Canceled) {
			return m, nil
		}
		if errors.Is(streamErr, lm.ErrStreamUnsupported) && len(m.pendingRequest) > 0 {
			history := append([]lm.ChatMessage(nil), m.pendingRequest...)
			m.pendingRequest = nil
			m.streamEnabled = false
			m.dropAssistantPlaceholder()
			m.tail = true
			m.refreshViewport()
			m.err = nil
			m.statusMessage = ""
			m.sending = true
			return m, tea.Batch(sendChatCmd(m.ctx, m.client, m.system, history))
		}
		m.err = streamErr
		m.pendingRequest = nil
		m.refreshViewport()
		return m, nil
	}

	if ev.chunk != "" {
		m.clearSnippet()
		m.appendStreamChunk(ev.chunk)
		m.refreshViewport()
		if m.streamCh != nil {
			return m, listenStreamCmd(m.streamCh)
		}
		return m, nil
	}

	if ev.done {
		m.stopStreaming()
		m.closeOpenFence()
		m.sending = false
		m.pendingRequest = nil
		m.refreshViewport()
		return m, nil
	}

	if m.streamCh != nil {
		return m, listenStreamCmd(m.streamCh)
	}
	return m, nil
}

func findPrevCodeBlock(content string, beforeIndex int) (string, string, int, bool) {
	type block struct {
		lang string
		body string
		idx  int
	}

	var blocks []block
	offset := 0
	for {
		start := strings.Index(content[offset:], "```")
		if start == -1 {
			break
		}
		start += offset
		end := strings.Index(content[start+3:], "```")
		if end == -1 {
			break
		}
		end += start + 3

		raw := strings.ReplaceAll(content[start+3:end], "\r\n", "\n")
		var lang, body string
		if ln := strings.Index(raw, "\n"); ln >= 0 {
			lang = strings.TrimSpace(raw[:ln])
			body = raw[ln+1:]
		} else {
			lang = strings.TrimSpace(raw)
			body = ""
		}
		body = strings.TrimRight(body, "\n")
		if strings.TrimSpace(body) != "" {
			blocks = append(blocks, block{
				lang: lang,
				body: body,
				idx:  len(blocks),
			})
		}

		offset = end + 3
	}

	limit := len(blocks)
	if beforeIndex >= 0 && beforeIndex < len(blocks) {
		limit = beforeIndex
	}

	for i := len(blocks) - 1; i >= 0; i-- {
		if i < limit {
			selected := blocks[i]
			return selected.lang, selected.body, selected.idx, true
		}
	}

	return "", "", 0, false
}

func buildFencedBlock(lang, code string) string {
	var b strings.Builder
	if lang != "" {
		fmt.Fprintf(&b, "```%s\n", lang)
	} else {
		b.WriteString("```\n")
	}
	b.WriteString(code)
	if !strings.HasSuffix(code, "\n") {
		b.WriteByte('\n')
	}
	b.WriteString("```")
	return b.String()
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

func SelectedSnippet(m tea.Model) (string, bool) {
	switch v := m.(type) {
	case model:
		if v.snippet != nil {
			return v.snippet.Code, true
		}
	case *model:
		if v != nil && v.snippet != nil {
			return v.snippet.Code, true
		}
	}
	return "", false
}
