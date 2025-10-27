package ui

import (
	"context"
	"fmt"
	"strings"
	"time"
	"unicode"

	"github.com/atotto/clipboard"
	"github.com/charmbracelet/bubbles/key"
	"github.com/charmbracelet/bubbles/spinner"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	appctx "github.com/slomin/sai/internal/context"
	"github.com/slomin/sai/internal/lm"
)

// Options configure the Bubble Tea program.
type Options struct {
	Context          context.Context
	Client           *lm.Client
	SystemPrompt     string
	DisableClipboard bool
	PendingPrompt    string
}

// NewProgram initialises the Bubble Tea program with the requested options.
func NewProgram(opts Options) *tea.Program {
	m := newModel(opts)
	var programOpts []tea.ProgramOption
	if opts.Context != nil {
		programOpts = append(programOpts, tea.WithContext(opts.Context))
	}
	return tea.NewProgram(m, programOpts...)
}

type phase int

const (
	phaseIdle phase = iota
	phaseQuerying
	phasePresenting
	phaseError
)

type model struct {
	ctx              context.Context
	client           *lm.Client
	systemPrompt     string
	disableClipboard bool

	pendingPrompt string
	currentPrompt string
	phase         phase

	requestStarted time.Time
	response       *responseState

	textInput textinput.Model
	spinner   spinner.Model

	copyFeedback *copyFeedback
	width        int
	height       int

	err      error
	quitting bool

	keys keyMap
}

type keyMap struct {
	Confirm  key.Binding
	Quit     key.Binding
	MenuUp   key.Binding
	MenuDown key.Binding
}

type completionSuccessMsg struct {
	Result  lm.CompletionResult
	Elapsed time.Duration
}

type completionErrorMsg struct {
	Err error
}

type submitPromptMsg struct {
	prompt string
}

type copyExpiredMsg struct{}

type quitMsg struct{}

func newModel(opts Options) model {
	ti := textinput.New()
	ti.Placeholder = "Ask the assistant..."
	ti.Focus()
	ti.CharLimit = 0
	ti.Width = 60

	return model{
		ctx:              opts.Context,
		client:           opts.Client,
		systemPrompt:     opts.SystemPrompt,
		disableClipboard: opts.DisableClipboard,
		pendingPrompt:    strings.TrimSpace(opts.PendingPrompt),
		currentPrompt:    strings.TrimSpace(opts.PendingPrompt),
		phase:            phaseIdle,
		textInput:        ti,
		spinner:          newSpinnerModel(),
		keys: keyMap{
			Confirm:  key.NewBinding(key.WithKeys("enter")),
			Quit:     key.NewBinding(key.WithKeys("ctrl+c", "esc", "q")),
			MenuUp:   key.NewBinding(key.WithKeys("up", "k")),
			MenuDown: key.NewBinding(key.WithKeys("down", "j")),
		},
	}
}

func newSpinnerModel() spinner.Model {
	sp := spinner.New()
	sp.Spinner = spinner.Dot
	sp.Style = lipgloss.NewStyle().Foreground(colorAccent)
	return sp
}

func (m model) Init() tea.Cmd {
	cmds := []tea.Cmd{textinput.Blink}
	if m.pendingPrompt != "" {
		cmds = append(cmds, func() tea.Msg { return submitPromptMsg{prompt: m.pendingPrompt} })
	}
	return tea.Batch(cmds...)
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		m.textInput.Width = max(20, m.width-6)
		return m, nil

	case spinner.TickMsg:
		var cmd tea.Cmd
		m.spinner, cmd = m.spinner.Update(msg)
		if m.phase == phaseQuerying {
			return m, tea.Batch(cmd, m.spinner.Tick)
		}
		return m, cmd

	case submitPromptMsg:
		return m.handleSubmit(msg.prompt)

	case completionSuccessMsg:
		return m.handleSuccess(msg)

	case completionErrorMsg:
		return m.handleError(msg.Err)

	case copyExpiredMsg:
		m.copyFeedback = nil
		return m, nil

	case quitMsg:
		return m, tea.Quit

	case tea.KeyMsg:
		return m.handleKey(msg)
	}

	if m.phase == phaseIdle {
		var cmd tea.Cmd
		m.textInput, cmd = m.textInput.Update(msg)
		return m, cmd
	}

	return m, nil
}

func (m model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch m.phase {
	case phaseIdle:
		switch {
		case key.Matches(msg, m.keys.Quit):
			return m.quit()
		case key.Matches(msg, m.keys.Confirm):
			return m.handleSubmit(m.textInput.Value())
		case msg.Type == tea.KeyCtrlU:
			m.textInput.SetValue("")
			return m, nil
		case msg.Type == tea.KeyCtrlW:
			m.textInput.SetValue(trimTrailingWord(m.textInput.Value()))
			return m, nil
		case msg.Type == tea.KeyCtrlH:
			m.textInput.SetValue(trimLastRune(m.textInput.Value()))
			return m, nil
		default:
			var cmd tea.Cmd
			m.textInput, cmd = m.textInput.Update(msg)
			return m, cmd
		}

	case phaseQuerying:
		if key.Matches(msg, m.keys.Quit) {
			return m.quit()
		}
		return m, nil

	case phasePresenting:
		return m.handleMenuKey(msg)

	case phaseError:
		if key.Matches(msg, m.keys.Quit) || key.Matches(msg, m.keys.Confirm) {
			return m.quit()
		}
	}

	return m, nil
}

func (m model) handleSubmit(input string) (tea.Model, tea.Cmd) {
	prompt := strings.TrimSpace(input)
	if prompt == "" {
		return m, nil
	}

	newModel := m
	newModel.phase = phaseQuerying
	newModel.response = nil
	newModel.err = nil
	newModel.copyFeedback = nil
	newModel.pendingPrompt = ""
	newModel.currentPrompt = prompt
	newModel.textInput.SetValue("")
	newModel.requestStarted = time.Now()
	newModel.spinner = newSpinnerModel()

	cmd := runCompletionCmd(newModel.ctx, newModel.client, newModel.systemPrompt, prompt)
	return newModel, tea.Batch(newModel.spinner.Tick, cmd)
}

func (m model) handleSuccess(msg completionSuccessMsg) (tea.Model, tea.Cmd) {
	response := newResponseState(msg.Result, msg.Elapsed)
	m.phase = phasePresenting
	m.response = &response
	return m, nil
}

func (m model) handleError(err error) (tea.Model, tea.Cmd) {
	m.phase = phaseError
	m.err = err
	return m, nil
}

func (m model) handleMenuKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	if key.Matches(msg, m.keys.Quit) {
		return m.quit()
	}

	if m.response == nil {
		return m, nil
	}

	switch {
	case key.Matches(msg, m.keys.MenuUp):
		m.response.menu.previous()
		return m, nil

	case key.Matches(msg, m.keys.MenuDown):
		m.response.menu.next()
		return m, nil
	}

	switch msg.String() {
	case "enter":
		return m.activateSelection()
	case "1", "2", "0":
		return m.activateByShortcut(msg.String()[0])
	}

	return m, nil
}

func (m model) activateByShortcut(ch byte) (tea.Model, tea.Cmd) {
	if m.response == nil {
		return m, nil
	}

	if idx := m.response.menu.findByShortcut(rune(ch)); idx >= 0 {
		m.response.menu.selected = idx
		return m.activateSelection()
	}

	return m, nil
}

func (m model) activateSelection() (tea.Model, tea.Cmd) {
	if m.response == nil {
		return m, nil
	}
	entry := m.response.menu.current()
	if !entry.enabled {
		m.copyFeedback = &copyFeedback{
			message: "No data available for that option.",
			kind:    feedbackWarning,
		}
		return m, feedbackTimerCmd()
	}

	switch entry.kind {
	case menuExplanation:
		return m.copyAndMaybeQuit(fmt.Sprintf("# %s", m.response.structured.Explanation), "explanation")
	case menuCommand:
		return m.copyAndMaybeQuit(m.response.structured.RecommendedCommand, "command")
	case menuCancel:
		return m.quit()
	}

	return m, nil
}

func (m model) copyAndMaybeQuit(text, label string) (tea.Model, tea.Cmd) {
	outcome := copyOutcome{kind: copyKindSkipped}
	if strings.TrimSpace(text) != "" {
		outcome = copyToClipboard(text, m.disableClipboard)
	}

	switch outcome.kind {
	case copyKindSuccess:
		m.copyFeedback = &copyFeedback{
			message: fmt.Sprintf("Copied %s to clipboard.", label),
			kind:    feedbackSuccess,
		}
	case copyKindSkipped:
		m.copyFeedback = &copyFeedback{
			message: fmt.Sprintf("Prepared %s output.", label),
			kind:    feedbackSuccess,
		}
	case copyKindFailed:
		m.copyFeedback = &copyFeedback{
			message: fmt.Sprintf("Clipboard unavailable: %s", outcome.err),
			kind:    feedbackWarning,
		}
	}

	return m, tea.Batch(feedbackTimerCmd(), delayedQuitCmd())
}

func delayedQuitCmd() tea.Cmd {
	return tea.Tick(20*time.Millisecond, func(time.Time) tea.Msg {
		return quitMsg{}
	})
}

func feedbackTimerCmd() tea.Cmd {
	return tea.Tick(4*time.Second, func(time.Time) tea.Msg {
		return copyExpiredMsg{}
	})
}

func (m model) View() string {
	if m.quitting {
		return ""
	}

	switch m.phase {
	case phaseIdle:
		return m.renderLayout(m.renderHeader(), m.renderInput(), m.renderFooter())
	case phaseQuerying:
		return m.renderLayout(m.renderHeader(), m.renderQuerying(), m.renderFooter())
	case phasePresenting:
		return m.renderLayout(m.renderHeader(), m.renderPresenting(), m.renderFooter())
	case phaseError:
		return m.renderLayout(m.renderHeader(), m.renderError(), m.renderFooter())
	default:
		return m.renderLayout(m.renderHeader(), "", m.renderFooter())
	}
}

// Rendering helpers ----------------------------------------------------------

var (
	colorAccent     = lipgloss.Color("#6CAAFF")
	colorAccentDim  = lipgloss.Color("#466EB4")
	colorSuccess    = lipgloss.Color("#78F0AA")
	colorWarning    = lipgloss.Color("#FFD278")
	colorError      = lipgloss.Color("#FF7878")
	colorSurface    = lipgloss.Color("#1A1C20")
	colorSurfaceAlt = lipgloss.Color("#24272D")
	colorText       = lipgloss.Color("#DCE1EB")
	colorMuted      = lipgloss.Color("#969BA5")

	styleTitle = lipgloss.NewStyle().
			Foreground(colorSurface).
			Background(colorAccent).
			Bold(true)

	styleHeaderText = lipgloss.NewStyle().
			Foreground(colorText).
			Bold(true)

	styleBody = lipgloss.NewStyle().
			Foreground(colorText).
			Background(colorSurface)

	stylePanel = lipgloss.NewStyle().
			BorderStyle(lipgloss.RoundedBorder()).
			BorderForeground(colorAccentDim).
			Background(colorSurfaceAlt).
			Padding(1, 2)

	styleFooter = lipgloss.NewStyle().Foreground(colorMuted)
)

func (m model) renderLayout(header, body, footer string) string {
	var b strings.Builder
	if header != "" {
		b.WriteString(header)
		b.WriteString("\n\n")
	}
	if body != "" {
		b.WriteString(body)
		b.WriteString("\n\n")
	}
	if footer != "" {
		b.WriteString(footer)
	}
	return b.String()
}

func (m model) renderHeader() string {
	var icon, message string
	var color lipgloss.Color

	switch m.phase {
	case phaseQuerying:
		icon = m.spinner.View()
		message = "Thinking…"
		color = colorAccent
	case phasePresenting:
		icon = "✔"
		message = "Response ready"
		color = colorSuccess
	case phaseError:
		icon = "✖"
		message = "Request failed"
		color = colorError
	default:
		icon = "∙"
		message = "Awaiting prompt"
		color = colorMuted
	}

	title := styleTitle.Render(" SAI ")
	status := lipgloss.NewStyle().Foreground(color).Render(icon)
	text := styleHeaderText.Render(message)

	return lipgloss.JoinHorizontal(
		lipgloss.Top,
		title,
		"  ",
		status,
		" ",
		text,
	)
}

func (m model) renderPromptPanel(width int) string {
	content := strings.TrimSpace(m.currentPrompt)
	if content == "" {
		content = "(no prompt submitted)"
	}
	body := lipgloss.NewStyle().
		Foreground(colorText).
		Width(max(0, width-4)).
		Render(content)

	title := lipgloss.NewStyle().
		Foreground(colorAccent).
		Bold(true).
		Render("Prompt")

	return stylePanel.Width(width).Render(
		lipgloss.JoinVertical(lipgloss.Left, title, body),
	)
}

func (m model) renderInput() string {
	body := lipgloss.JoinVertical(
		lipgloss.Left,
		m.textInput.View(),
		lipgloss.NewStyle().Foreground(colorMuted).Render("Press Enter to send · Esc to quit."),
	)
	return stylePanel.Width(m.bodyWidth()).Render(body)
}

func (m model) renderQuerying() string {
	width := m.bodyWidth()
	prompt := m.renderPromptPanel(width)
	status := stylePanel.Width(width).Render(
		lipgloss.NewStyle().Foreground(colorAccent).Render(m.spinner.View() + " Requesting model response…"),
	)
	return lipgloss.JoinVertical(lipgloss.Left, prompt, "", status)
}

func (m model) renderPresenting() string {
	if m.response == nil {
		return ""
	}

	width := m.bodyWidth()
	prompt := m.renderPromptPanel(width)

	explanation := stylePanel.Width(width).
		Render(formatExplanation(m.response.structured.Explanation, width-4))

	menu := stylePanel.Width(width).
		Render(m.renderMenu())

	return lipgloss.JoinVertical(lipgloss.Left, prompt, "", explanation, "", menu)
}

func (m model) renderMenu() string {
	if m.response == nil {
		return ""
	}

	var rows []string
	for idx, entry := range m.response.menu.entries {
		line := fmt.Sprintf("%c. %s", entry.shortcut, entry.title)
		if !entry.enabled {
			line = styleFooter.Render(line + " · unavailable")
		} else if idx == m.response.menu.selected {
			line = lipgloss.NewStyle().
				Foreground(colorAccent).
				Bold(true).
				Render(line)
		}

		preview := styleFooter.Render("   " + previewText(entry.preview))
		rows = append(rows, lipgloss.JoinVertical(lipgloss.Left, line, preview))
	}

	return lipgloss.JoinVertical(lipgloss.Left, rows...)
}

func (m model) renderError() string {
	width := m.bodyWidth()
	prompt := m.renderPromptPanel(width)
	var message string
	if m.err != nil {
		message = m.err.Error()
	} else {
		message = "Unknown error."
	}
	errorPanel := stylePanel.Width(width).
		Render(lipgloss.NewStyle().Foreground(colorError).Render(message))
	return lipgloss.JoinVertical(lipgloss.Left, prompt, "", errorPanel)
}

func (m model) renderFooter() string {
	var parts []string

	if m.response != nil {
		parts = append(parts, fmt.Sprintf("⏱ %.3fs", m.response.elapsed.Seconds()))
		if text := formatUsage(m.response.usage); text != "" {
			parts = append(parts, text)
		}
	}

	if m.copyFeedback != nil {
		decorated := lipgloss.NewStyle()
		switch m.copyFeedback.kind {
		case feedbackSuccess:
			decorated = decorated.Foreground(colorSuccess)
		case feedbackWarning:
			decorated = decorated.Foreground(colorWarning)
		}
		parts = append(parts, decorated.Render("📋 "+m.copyFeedback.message))
	}

	switch m.phase {
	case phasePresenting:
		parts = append(parts, styleFooter.Render("↑/↓ move · 1/2 copy · 0 exit"))
	case phaseIdle:
		parts = append(parts, styleFooter.Render("Tip: type freely, then press Enter."))
	default:
		parts = append(parts, styleFooter.Render("Esc/Ctrl+C to exit."))
	}

	return strings.Join(parts, "   ")
}

func (m model) bodyWidth() int {
	if m.width <= 0 {
		return 80
	}
	return max(40, m.width-4)
}

func (m model) quit() (tea.Model, tea.Cmd) {
	m.quitting = true
	return m, tea.Quit
}

// Supporting types -----------------------------------------------------------

type responseState struct {
	structured lm.StructuredAnswer
	usage      *lm.Usage
	elapsed    time.Duration
	menu       menuState
}

func newResponseState(result lm.CompletionResult, elapsed time.Duration) responseState {
	return responseState{
		structured: result.Structured,
		usage:      result.Usage,
		elapsed:    elapsed,
		menu:       newMenuState(result.Structured),
	}
}

type menuKind int

const (
	menuExplanation menuKind = iota
	menuCommand
	menuCancel
)

type menuEntry struct {
	shortcut rune
	title    string
	preview  string
	kind     menuKind
	enabled  bool
}

type menuState struct {
	entries  []menuEntry
	selected int
}

func newMenuState(answer lm.StructuredAnswer) menuState {
	var entries []menuEntry
	if strings.TrimSpace(answer.Explanation) != "" {
		entries = append(entries, menuEntry{
			shortcut: '1',
			title:    "Explanation",
			preview:  answer.Explanation,
			kind:     menuExplanation,
			enabled:  true,
		})
	}
	if strings.TrimSpace(answer.RecommendedCommand) != "" {
		entries = append(entries, menuEntry{
			shortcut: '2',
			title:    "Command",
			preview:  answer.RecommendedCommand,
			kind:     menuCommand,
			enabled:  true,
		})
	}
	entries = append(entries, menuEntry{
		shortcut: '0',
		title:    "Cancel",
		preview:  "Exit without copying.",
		kind:     menuCancel,
		enabled:  true,
	})

	selected := 0
	for i, entry := range entries {
		if entry.enabled {
			selected = i
			break
		}
	}

	return menuState{entries: entries, selected: selected}
}

func (m *menuState) current() menuEntry {
	return m.entries[m.selected]
}

func (m *menuState) next() {
	for i := 1; i <= len(m.entries); i++ {
		idx := (m.selected + i) % len(m.entries)
		if m.entries[idx].enabled {
			m.selected = idx
			return
		}
	}
}

func (m *menuState) previous() {
	for i := 1; i <= len(m.entries); i++ {
		idx := (m.selected - i + len(m.entries)) % len(m.entries)
		if m.entries[idx].enabled {
			m.selected = idx
			return
		}
	}
}

func (m *menuState) findByShortcut(shortcut rune) int {
	for i, entry := range m.entries {
		if entry.shortcut == shortcut {
			return i
		}
	}
	return -1
}

type copyFeedback struct {
	message string
	kind    feedbackKind
}

type feedbackKind int

const (
	feedbackSuccess feedbackKind = iota
	feedbackWarning
)

type copyOutcome struct {
	kind copyKind
	err  error
}

type copyKind int

const (
	copyKindSuccess copyKind = iota
	copyKindSkipped
	copyKindFailed
)

func copyToClipboard(text string, disabled bool) copyOutcome {
	if disabled {
		return copyOutcome{kind: copyKindSkipped}
	}
	if err := clipboard.WriteAll(text); err != nil {
		return copyOutcome{kind: copyKindFailed, err: err}
	}
	return copyOutcome{kind: copyKindSuccess}
}

func formatExplanation(text string, width int) string {
	if strings.TrimSpace(text) == "" {
		return lipgloss.NewStyle().Foreground(colorMuted).Render("(no explanation provided)")
	}
	return lipgloss.NewStyle().
		Foreground(colorText).
		Width(width).
		Render(strings.TrimSpace(text))
}

func previewText(text string) string {
	trimmed := strings.TrimSpace(text)
	if trimmed == "" {
		return "(empty)"
	}
	const maxChars = 72
	if len([]rune(trimmed)) <= maxChars {
		return trimmed
	}
	return string([]rune(trimmed)[:maxChars]) + "…"
}

func formatUsage(usage *lm.Usage) string {
	if usage == nil {
		return ""
	}

	var parts []string
	if usage.PromptTokens != nil {
		parts = append(parts, fmt.Sprintf("prompt %d", *usage.PromptTokens))
	}
	if usage.CompletionTokens != nil {
		parts = append(parts, fmt.Sprintf("completion %d", *usage.CompletionTokens))
	}
	if usage.TotalTokens != nil {
		parts = append(parts, fmt.Sprintf("total %d", *usage.TotalTokens))
	}
	if len(parts) == 0 {
		return ""
	}
	return strings.Join(parts, " · ") + " tokens"
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func trimTrailingWord(input string) string {
	trimmed := strings.TrimRightFunc(input, unicode.IsSpace)
	return strings.TrimRightFunc(trimmed, func(r rune) bool {
		return !unicode.IsSpace(r)
	})
}

func trimLastRune(input string) string {
	runes := []rune(input)
	if len(runes) == 0 {
		return input
	}
	return string(runes[:len(runes)-1])
}

// Commands -------------------------------------------------------------------

func runCompletionCmd(ctx context.Context, client *lm.Client, systemPrompt, prompt string) tea.Cmd {
	return func() tea.Msg {
		composed, err := appctx.ComposePrompt(prompt)
		if err != nil {
			return completionErrorMsg{Err: err}
		}

		callCtx := ctx
		if callCtx == nil {
			callCtx = context.Background()
		}

		start := time.Now()
		result, err := client.Complete(callCtx, systemPrompt, composed)
		if err != nil {
			return completionErrorMsg{Err: err}
		}
		return completionSuccessMsg{Result: result, Elapsed: time.Since(start)}
	}
}
