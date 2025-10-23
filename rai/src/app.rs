use std::io::Read;
use std::time::{Duration, Instant};

use anyhow::Result;
use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyModifiers};
use crossterm::tty::IsTty;
use ratatui::DefaultTerminal;
use ratatui::layout::{Constraint, Direction, Layout};
use ratatui::prelude::*;
use ratatui::widgets::{Block, Borders, List, ListItem, Paragraph, Wrap};
use std::panic::{self, AssertUnwindSafe};
use tokio::sync::mpsc;

use crate::cli::CliArgs;
use crate::lm::{CompletionResult, LmClient, StructuredAnswer, Usage};
use crate::spinner::Spinner;

const DEFAULT_SYSTEM_PROMPT: &str = r#"You are an expert macOS terminal assistant.
You MUST answer every user message with a single JSON object that has these string keys:
- explanation: concise, high-signal guidance for the user (one short paragraph max)
- recommended_command: the exact command the user should run (omit shell prompt and trailing comments)

Rules:
- Only return JSON; do not use backticks or additional commentary.
- If no safe or relevant command exists, set recommended_command to an empty string.
- Tailor answers to zsh on macOS.

Example response:
{
  "explanation": "Hidden files start with a dot. Use ls -a to show them.",
  "recommended_command": "ls -a"
}
"#;

pub fn resolve_system_prompt(args: &CliArgs) -> String {
    args.system_prompt
        .clone()
        .unwrap_or_else(|| DEFAULT_SYSTEM_PROMPT.to_string())
}

#[derive(Debug)]
enum Phase {
    Idle,
    Querying { _started: Instant, prompt: String },
    Presenting,
    Error(String),
}

#[derive(Debug)]
struct ResponseState {
    structured: StructuredAnswer,
    _raw_text: String,
    usage: Option<Usage>,
    elapsed: Duration,
    menu: MenuState,
}

#[derive(Debug)]
struct MenuState {
    options: Vec<MenuEntry>,
    selected: usize,
}

#[derive(Debug)]
struct MenuEntry {
    shortcut: char,
    title: String,
    preview: String,
    kind: MenuKind,
    enabled: bool,
}

#[derive(Debug, Clone, Copy)]
enum MenuKind {
    Explanation,
    Command,
    Cancel,
}

#[derive(Debug)]
struct CopyStatus {
    message: String,
    kind: CopyKind,
    created_at: Instant,
}

#[derive(Debug)]
enum CopyKind {
    Success,
    Warning,
}

#[derive(Debug)]
enum ClipboardOutcome {
    Copied,
    Skipped,
    Failed(String),
}
#[derive(Debug)]
enum AppEvent {
    Input(Event),
    Tick,
    ModelSuccess {
        data: CompletionResult,
        elapsed: Duration,
    },
    ModelError(String),
}

pub enum AppExit {
    None,
    Output { text: String },
}

pub struct App {
    args: CliArgs,
    client: LmClient,
    system_prompt: String,
    phase: Phase,
    spinner: Spinner,
    response: Option<ResponseState>,
    copy_feedback: Option<CopyStatus>,
    pending_prompt: Option<String>,
    exit_request: Option<AppExit>,
    input_buffer: String,
}

impl App {
    pub fn new(args: CliArgs, client: LmClient) -> Self {
        let system_prompt = resolve_system_prompt(&args);

        let pending_prompt = initial_prompt_from_args(&args);

        Self {
            args,
            client,
            system_prompt,
            phase: Phase::Idle,
            spinner: Spinner::thinking(),
            response: None,
            copy_feedback: None,
            pending_prompt,
            exit_request: None,
            input_buffer: String::new(),
        }
    }

    fn handle_idle_key(&mut self, key: KeyEvent, tx: &mpsc::Sender<AppEvent>) -> Result<()> {
        if key.modifiers.contains(KeyModifiers::CONTROL) {
            match key.code {
                KeyCode::Char('u') => self.input_buffer.clear(),
                KeyCode::Char('w') => {
                    let trimmed = self
                        .input_buffer
                        .trim_end_matches(|c: char| c.is_whitespace())
                        .to_string();
                    let without_word = trimmed
                        .trim_end_matches(|c: char| !c.is_whitespace())
                        .to_string();
                    self.input_buffer = without_word;
                }
                KeyCode::Char('h') | KeyCode::Backspace => {
                    self.input_buffer.pop();
                }
                _ => {}
            }
            return Ok(());
        }

        match key.code {
            KeyCode::Enter => {
                let prompt = self.input_buffer.trim();
                if !prompt.is_empty() {
                    let prompt = prompt.to_string();
                    self.input_buffer.clear();
                    self.submit_prompt(prompt, tx.clone());
                }
            }
            KeyCode::Esc => {
                self.exit_request = Some(AppExit::None);
            }
            KeyCode::Char(c) => {
                if key.modifiers.is_empty() || key.modifiers == KeyModifiers::SHIFT {
                    self.input_buffer.push(c);
                }
            }
            KeyCode::Backspace => {
                self.input_buffer.pop();
            }
            KeyCode::Delete => {
                self.input_buffer.pop();
            }
            KeyCode::Tab => {}
            KeyCode::Left | KeyCode::Right | KeyCode::Up | KeyCode::Down => {}
            _ => {}
        }

        Ok(())
    }

    pub async fn run(mut self) -> Result<AppExit> {
        if !std::io::stdout().is_tty() {
            return self.run_headless().await;
        }

        let mut terminal = ratatui::init();
        let result = self.event_loop(&mut terminal).await;
        ratatui::restore();
        result
    }

    async fn event_loop(&mut self, terminal: &mut DefaultTerminal) -> Result<AppExit> {
        let (tx, mut rx) = mpsc::channel::<AppEvent>(128);

        spawn_input_listener(tx.clone());
        spawn_tick_timer(tx.clone());

        if let Some(prompt) = self.pending_prompt.take() {
            self.submit_prompt(prompt, tx.clone());
        }

        loop {
            terminal.draw(|frame| self.render(frame))?;

            if let Some(exit) = self.exit_request.take() {
                return Ok(exit);
            }

            match rx.recv().await {
                Some(AppEvent::Tick) => self.on_tick(),
                Some(AppEvent::Input(event)) => self.on_input(event, &tx).await?,
                Some(AppEvent::ModelSuccess { data, elapsed }) => {
                    self.on_model_success(data, elapsed)
                }
                Some(AppEvent::ModelError(error)) => self.on_model_error(error),
                None => break,
            }
        }

        Ok(AppExit::None)
    }

    fn submit_prompt(&mut self, prompt: String, tx: mpsc::Sender<AppEvent>) {
        self.spinner.reset();
        self.response = None;
        self.copy_feedback = None;
        let started = Instant::now();
        self.phase = Phase::Querying {
            _started: started,
            prompt: prompt.clone(),
        };

        let client = self.client.clone();
        let system_prompt = self.system_prompt.clone();

        tokio::spawn(async move {
            let begin = Instant::now();
            let outcome = client.complete(&system_prompt, &prompt).await;
            let elapsed = begin.elapsed();
            let event = match outcome {
                Ok(data) => AppEvent::ModelSuccess { data, elapsed },
                Err(err) => AppEvent::ModelError(err.to_string()),
            };
            let _ = tx.send(event).await;
        });
    }

    fn on_tick(&mut self) {
        if matches!(self.phase, Phase::Querying { .. }) {
            self.spinner.tick();
        }
        if let Some(feedback) = self.copy_feedback.as_ref() {
            if feedback.created_at.elapsed() > Duration::from_secs(4) {
                self.copy_feedback = None;
            }
        }
    }

    async fn on_input(&mut self, event: Event, tx: &mpsc::Sender<AppEvent>) -> Result<()> {
        match event {
            Event::Key(key) => self.handle_key(key, tx).await?,
            Event::Resize(_, _) => {}
            Event::FocusGained | Event::FocusLost | Event::Mouse(_) | Event::Paste(_) => {}
        }
        Ok(())
    }

    async fn handle_key(&mut self, key: KeyEvent, tx: &mpsc::Sender<AppEvent>) -> Result<()> {
        if matches!(key.code, KeyCode::Char('c')) && key.modifiers.contains(KeyModifiers::CONTROL) {
            self.exit_request = Some(AppExit::None);
            return Ok(());
        }

        match self.phase {
            Phase::Querying { .. } => {
                if matches!(key.code, KeyCode::Esc) {
                    self.exit_request = Some(AppExit::None);
                }
            }
            Phase::Presenting => self.handle_menu_key(key)?,
            Phase::Error(_) => {
                if matches!(key.code, KeyCode::Enter | KeyCode::Esc) {
                    self.exit_request = Some(AppExit::None);
                }
            }
            Phase::Idle => self.handle_idle_key(key, tx)?,
        }

        Ok(())
    }

    fn handle_menu_key(&mut self, key: KeyEvent) -> Result<()> {
        let response = match self.response.as_mut() {
            Some(res) => res,
            None => return Ok(()),
        };
        let menu = &mut response.menu;

        match key.code {
            KeyCode::Up => menu.previous(),
            KeyCode::Down => menu.next(),
            KeyCode::Char('k') => menu.previous(),
            KeyCode::Char('j') => menu.next(),
            KeyCode::Home => menu.first(),
            KeyCode::End => menu.last(),
            KeyCode::Char(ch) => {
                if let Some(index) = menu.options.iter().position(|entry| entry.shortcut == ch) {
                    menu.selected = index;
                    self.activate_selection();
                }
            }
            KeyCode::Enter => self.activate_selection(),
            KeyCode::Esc => {
                self.exit_request = Some(AppExit::None);
            }
            _ => {}
        }

        Ok(())
    }

    fn activate_selection(&mut self) {
        let selection = match self.response.as_ref() {
            Some(res) => res.menu.current(),
            None => return,
        };

        if !selection.enabled {
            self.copy_feedback = Some(CopyStatus::warning("No data available for that option."));
            return;
        }

        let response = match self.response.as_ref() {
            Some(res) => res,
            None => return,
        };

        let (text, label) = match selection.kind {
            MenuKind::Explanation => {
                let explanation = format!("# {}", response.structured.explanation.trim());
                (explanation, "explanation")
            }
            MenuKind::Command => {
                let command = response.structured.recommended_command.trim().to_owned();
                (command, "command")
            }
            MenuKind::Cancel => {
                self.exit_request = Some(AppExit::None);
                return;
            }
        };

        match self.copy_to_clipboard(&text) {
            ClipboardOutcome::Copied => {
                self.copy_feedback =
                    Some(CopyStatus::success(format!("Copied {label} to clipboard.")));
            }
            ClipboardOutcome::Skipped => {
                self.copy_feedback = Some(CopyStatus::success(format!("Prepared {label} output.")));
            }
            ClipboardOutcome::Failed(err) => {
                let msg = format!("Clipboard unavailable: {err}");
                self.copy_feedback = Some(CopyStatus::warning(msg));
            }
        }

        self.exit_request = Some(AppExit::None);
    }

    fn on_model_success(&mut self, data: CompletionResult, elapsed: Duration) {
        self.phase = Phase::Presenting;
        self.response = Some(ResponseState::new(data, elapsed));
        self.spinner.reset();
    }

    fn on_model_error(&mut self, message: String) {
        self.phase = Phase::Error(message);
        self.spinner.reset();
    }

    fn copy_to_clipboard(&self, text: &str) -> ClipboardOutcome {
        if self.args.no_clipboard {
            return ClipboardOutcome::Skipped;
        }

        let clipboard_result = panic::catch_unwind(AssertUnwindSafe(arboard::Clipboard::new));
        let mut clipboard = match clipboard_result {
            Ok(Ok(clipboard)) => clipboard,
            Ok(Err(err)) => {
                return ClipboardOutcome::Failed(format!("{err}"));
            }
            Err(_) => {
                return ClipboardOutcome::Failed("clipboard backend panicked".to_string());
            }
        };

        let set_result =
            panic::catch_unwind(AssertUnwindSafe(|| clipboard.set_text(text.to_owned())));

        match set_result {
            Ok(Ok(())) => ClipboardOutcome::Copied,
            Ok(Err(err)) => ClipboardOutcome::Failed(format!("{err}")),
            Err(_) => ClipboardOutcome::Failed("clipboard backend panicked".to_string()),
        }
    }

    async fn run_headless(&mut self) -> Result<AppExit> {
        let prompt = if let Some(pending) = self.pending_prompt.take() {
            pending
        } else if let Some(from_args) = initial_prompt_from_args(&self.args) {
            from_args
        } else {
            return Ok(AppExit::None);
        };

        let start = Instant::now();
        match self
            .client
            .complete(&self.system_prompt, prompt.trim())
            .await
        {
            Ok(result) => {
                let mut output = result.structured.recommended_command.trim().to_string();
                if output.is_empty() {
                    output = format!("# {}", result.structured.explanation.trim());
                }
                eprintln!(
                    "[Total Response Time] {:.3}s",
                    start.elapsed().as_secs_f64()
                );
                Ok(AppExit::Output { text: output })
            }
            Err(err) => {
                eprintln!("Error: {err}");
                Ok(AppExit::None)
            }
        }
    }

    fn render(&mut self, frame: &mut Frame) {
        let size = frame.area();
        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Length(3),
                Constraint::Min(5),
                Constraint::Length(3),
            ])
            .split(size);

        frame.render_widget(self.render_header(), chunks[0]);
        match self.phase {
            Phase::Presenting => self.render_presenting(frame, chunks[1]),
            _ => {
                let widget = self.render_body(chunks[1]);
                frame.render_widget(widget, chunks[1]);
            }
        }
        frame.render_widget(self.render_footer(), chunks[2]);
    }

    fn render_header(&self) -> Paragraph<'_> {
        let (status_text, status_style) = match &self.phase {
            Phase::Querying { .. } => (
                format!("{} Thinking…", self.spinner.frame()),
                Style::default()
                    .fg(Color::Rgb(255, 165, 0))
                    .add_modifier(Modifier::BOLD),
            ),
            Phase::Presenting => (
                "Response ready — pick your answer.".to_string(),
                Style::default()
                    .fg(Color::Green)
                    .add_modifier(Modifier::BOLD),
            ),
            Phase::Error(_) => (
                "Request failed".to_string(),
                Style::default().fg(Color::Red).add_modifier(Modifier::BOLD),
            ),
            Phase::Idle => (
                "Type a prompt below or pass it as args.".to_string(),
                Style::default().fg(Color::Gray),
            ),
        };

        Paragraph::new(Line::from(vec![
            Span::styled(
                "rai",
                Style::default()
                    .fg(Color::Cyan)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::raw(" · "),
            Span::styled(status_text, status_style),
        ]))
    }

    fn render_body(&self, _area: Rect) -> Paragraph<'_> {
        match (&self.phase, &self.response) {
            (Phase::Querying { prompt, .. }, _) => {
                let content = format!("Prompt:\n{prompt}");
                Paragraph::new(content)
                    .block(Block::default().borders(Borders::ALL).title("Request"))
                    .wrap(Wrap { trim: true })
            }
            (Phase::Presenting, Some(response)) => {
                let explanation = response.structured.explanation.trim();
                let command = response.structured.recommended_command.trim();
                let mut lines = vec![
                    Line::styled("Explanation", Style::default().fg(Color::Green)),
                    Line::from(explanation),
                ];
                if !command.is_empty() {
                    lines.push(Line::default());
                    lines.push(Line::styled("Command", Style::default().fg(Color::Green)));
                    lines.push(Line::from(command));
                }

                Paragraph::new(lines)
                    .block(
                        Block::default()
                            .borders(Borders::ALL)
                            .title("Model response"),
                    )
                    .wrap(Wrap { trim: true })
            }
            (Phase::Error(message), _) => Paragraph::new(message.as_str())
                .block(Block::default().borders(Borders::ALL).title("Error"))
                .wrap(Wrap { trim: true }),
            (Phase::Idle, _) => {
                let caret = Span::styled("▌", Style::default().fg(Color::Cyan));
                let buffer_span: Span<'_> = if self.input_buffer.is_empty() {
                    Span::styled(" ", Style::default().fg(Color::DarkGray))
                } else {
                    Span::raw(self.input_buffer.as_str())
                };

                let instructions = Line::from(vec![Span::styled(
                    "Type a prompt, hit Enter to send, Esc to quit.",
                    Style::default().fg(Color::Gray),
                )]);
                let prompt_line = Line::from(vec![
                    Span::styled("> ", Style::default().fg(Color::Cyan)),
                    buffer_span,
                    caret,
                ]);
                let lines = vec![instructions, Line::default(), prompt_line];

                Paragraph::new(lines)
                    .block(Block::default().borders(Borders::ALL).title("Prompt"))
                    .wrap(Wrap { trim: false })
            }
            _ => Paragraph::new("Provide a prompt, e.g. `rai \"list hidden files\"`.")
                .wrap(Wrap { trim: true }),
        }
    }

    fn render_presenting(&mut self, frame: &mut Frame, area: Rect) {
        let Some(response) = self.response.as_ref() else {
            frame.render_widget(self.render_body(area), area);
            return;
        };

        let layout = Layout::default()
            .direction(Direction::Vertical)
            .constraints([Constraint::Min(5), Constraint::Length(9)])
            .split(area);

        let explanation = response.structured.explanation.trim();
        let command = response.structured.recommended_command.trim();
        let mut lines = vec![
            Line::styled("Explanation", Style::default().fg(Color::Green)),
            Line::from(explanation),
        ];
        if !command.is_empty() {
            lines.push(Line::default());
            lines.push(Line::styled("Command", Style::default().fg(Color::Green)));
            lines.push(Line::from(command));
        }
        let response_widget = Paragraph::new(lines)
            .block(
                Block::default()
                    .borders(Borders::ALL)
                    .title("Model response"),
            )
            .wrap(Wrap { trim: true });
        frame.render_widget(response_widget, layout[0]);

        let items: Vec<ListItem> = response
            .menu
            .options
            .iter()
            .enumerate()
            .map(|(idx, entry)| {
                let selected = idx == response.menu.selected;
                let title = format!("  {}) {}", entry.shortcut, entry.title);
                let preview = preview_text(&entry.preview);
                let title_style = if selected {
                    Style::default()
                        .fg(Color::Green)
                        .add_modifier(Modifier::BOLD)
                } else if entry.enabled {
                    Style::default().fg(Color::Cyan)
                } else {
                    Style::default().fg(Color::Gray)
                };
                let preview_style = if selected {
                    Style::default()
                        .fg(Color::Green)
                        .add_modifier(Modifier::ITALIC)
                } else if entry.enabled {
                    Style::default().fg(Color::Green)
                } else {
                    Style::default().fg(Color::Gray)
                };
                ListItem::new(vec![
                    Line::styled(title, title_style),
                    Line::from(Span::styled(format!("     {preview}"), preview_style)),
                ])
            })
            .collect();

        let menu = List::new(items).block(
            Block::default()
                .borders(Borders::ALL)
                .title("Pick your answer"),
        );
        frame.render_widget(menu, layout[1]);
    }

    fn render_footer(&self) -> Paragraph<'_> {
        let mut spans = Vec::new();

        if let Some(response) = self.response.as_ref() {
            let secs = response.elapsed.as_secs_f64();
            spans.push(Span::styled(
                format!("[Total Response Time] {:.3}s", secs),
                Style::default().fg(Color::Green),
            ));
        }

        if let Some(feedback) = self.copy_feedback.as_ref() {
            if !spans.is_empty() {
                spans.push(Span::raw("  ·  "));
            }
            let color = match feedback.kind {
                CopyKind::Success => Color::Green,
                CopyKind::Warning => Color::Yellow,
            };
            spans.push(Span::styled(
                feedback.message.as_str(),
                Style::default().fg(color),
            ));
        }

        if let Some(response) = self.response.as_ref() {
            if let Some(usage) = response.usage.as_ref() {
                let usage_text = format_usage(usage);
                if !usage_text.is_empty() {
                    if !spans.is_empty() {
                        spans.push(Span::raw("  ·  "));
                    }
                    spans.push(Span::styled(usage_text, Style::default().fg(Color::Gray)));
                }
            }
        }

        if matches!(self.phase, Phase::Presenting) {
            if !spans.is_empty() {
                spans.push(Span::raw("  ·  "));
            }
            spans.push(Span::styled(
                "Use ↑/↓ or press 1/2/0 then Enter.",
                Style::default().fg(Color::Gray),
            ));
        }

        if matches!(self.phase, Phase::Idle) {
            if !spans.is_empty() {
                spans.push(Span::raw("  ·  "));
            }
            spans.push(Span::styled(
                "Tip: type punctuation freely, then Enter to send.",
                Style::default().fg(Color::Gray),
            ));
        }

        if spans.is_empty() {
            spans.push(Span::raw("Esc/Ctrl+C to exit."));
        }

        Paragraph::new(Line::from(spans))
    }
}

fn spawn_input_listener(tx: mpsc::Sender<AppEvent>) {
    tokio::spawn(async move {
        loop {
            // poll with timeout to allow cancellation.
            match tokio::task::spawn_blocking(event::read).await {
                Ok(Ok(event)) => {
                    if tx.send(AppEvent::Input(event)).await.is_err() {
                        break;
                    }
                }
                Ok(Err(err)) => {
                    let _ = tx
                        .send(AppEvent::ModelError(format!(
                            "failed to read terminal input: {err}"
                        )))
                        .await;
                    break;
                }
                Err(_) => break,
            }
        }
    });
}

fn spawn_tick_timer(tx: mpsc::Sender<AppEvent>) {
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_millis(120));
        loop {
            interval.tick().await;
            if tx.send(AppEvent::Tick).await.is_err() {
                break;
            }
        }
    });
}

pub fn initial_prompt_from_args(args: &CliArgs) -> Option<String> {
    if !args.prompt.is_empty() {
        return Some(args.prompt.join(" "));
    }

    if atty::isnt(atty::Stream::Stdin) {
        let mut buffer = String::new();
        std::io::stdin().read_to_string(&mut buffer).ok()?;
        let trimmed = buffer.trim();
        if !trimmed.is_empty() {
            return Some(trimmed.to_string());
        }
    }

    None
}

impl ResponseState {
    fn new(result: CompletionResult, elapsed: Duration) -> Self {
        let menu = MenuState::new(&result.structured);
        Self {
            structured: result.structured,
            _raw_text: result.raw_text,
            usage: result.usage,
            elapsed,
            menu,
        }
    }
}

impl MenuState {
    fn new(answer: &StructuredAnswer) -> Self {
        let mut options = Vec::new();
        if !answer.explanation.trim().is_empty() {
            options.push(MenuEntry::explanation(answer.explanation.clone()));
        }
        if !answer.recommended_command.trim().is_empty() {
            options.push(MenuEntry::command(answer.recommended_command.clone()));
        }
        options.push(MenuEntry::cancel());

        let selected = options.iter().position(|entry| entry.enabled).unwrap_or(0);

        Self { options, selected }
    }

    fn current(&self) -> &MenuEntry {
        &self.options[self.selected]
    }

    fn next(&mut self) {
        let len = self.options.len();
        for _ in 0..len {
            self.selected = (self.selected + 1) % len;
            if self.options[self.selected].enabled {
                break;
            }
        }
    }

    fn previous(&mut self) {
        let len = self.options.len();
        for _ in 0..len {
            if self.selected == 0 {
                self.selected = len - 1;
            } else {
                self.selected -= 1;
            }
            if self.options[self.selected].enabled {
                break;
            }
        }
    }

    fn first(&mut self) {
        for (idx, entry) in self.options.iter().enumerate() {
            if entry.enabled {
                self.selected = idx;
                break;
            }
        }
    }

    fn last(&mut self) {
        for (idx, entry) in self.options.iter().enumerate().rev() {
            if entry.enabled {
                self.selected = idx;
                break;
            }
        }
    }
}

impl MenuEntry {
    fn explanation(explanation: String) -> Self {
        let preview = explanation.trim().to_string();
        Self {
            shortcut: '1',
            title: "Explanation".to_string(),
            preview,
            kind: MenuKind::Explanation,
            enabled: true,
        }
    }

    fn command(command: String) -> Self {
        let trimmed = command.trim().to_string();
        let enabled = !trimmed.is_empty();
        Self {
            shortcut: '2',
            title: "Command".to_string(),
            preview: trimmed,
            kind: MenuKind::Command,
            enabled,
        }
    }

    fn cancel() -> Self {
        Self {
            shortcut: '0',
            title: "Cancel".to_string(),
            preview: "Exit without printing output.".to_string(),
            kind: MenuKind::Cancel,
            enabled: true,
        }
    }
}

impl CopyStatus {
    fn success(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            kind: CopyKind::Success,
            created_at: Instant::now(),
        }
    }

    fn warning(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            kind: CopyKind::Warning,
            created_at: Instant::now(),
        }
    }
}

fn format_usage(usage: &Usage) -> String {
    match (
        usage.prompt_tokens,
        usage.completion_tokens,
        usage.total_tokens,
    ) {
        (Some(p), Some(c), Some(t)) => format!("prompt {p} · completion {c} · total {t} tokens"),
        (Some(p), Some(c), None) => format!("prompt {p} · completion {c} tokens"),
        (Some(p), None, None) => format!("prompt {p} tokens"),
        _ => String::new(),
    }
}

fn preview_text(text: &str) -> String {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return "(empty)".to_string();
    }

    const MAX_CHARS: usize = 72;
    let mut out = String::new();
    for (idx, ch) in trimmed.chars().enumerate() {
        if idx >= MAX_CHARS {
            out.push('…');
            break;
        }
        out.push(ch);
    }
    out
}
