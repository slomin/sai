package app

// Config mirrors the existing Ratatui CLI options for the Bubble Tea port.
type Config struct {
	Endpoint         string
	Model            string
	APIKey           string
	RemotePreset     bool
	DisableClipboard bool
	SystemPrompt     string
	LogFilter        string
	DebugPerformance bool
	Debug            bool
	Args             []string
}
