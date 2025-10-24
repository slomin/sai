package context

import (
	"bufio"
	"fmt"
	"os"
	"os/user"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"
)

const (
	maxDirEntries = 20
	historyLimit  = 10
)

// Snapshot captures the filesystem, shell, and environment context that
// accompanies each prompt.
type Snapshot struct {
	CWD       string
	Directory *DirectoryListing
	History   []string
	System    SystemInfo
	Warnings  []string
}

// DirectoryListing contains a truncated and formatted view of the current
// directory.
type DirectoryListing struct {
	Entries   []DirectoryEntry
	Total     int
	Truncated bool
}

// DirectoryEntry describes a single filesystem item shown in the listing.
type DirectoryEntry struct {
	Name   string
	Kind   EntryKind
	Hidden bool
}

// EntryKind mirrors the Rust enum and renders as a short label.
type EntryKind int

const (
	entryUnknown EntryKind = iota
	entryDirectory
	entryFile
	entrySymlink
)

// Label returns the short textual label for the entry kind.
func (k EntryKind) Label() string {
	switch k {
	case entryDirectory:
		return "DIR"
	case entryFile:
		return "FIL"
	case entrySymlink:
		return "LNK"
	default:
		return "OTH"
	}
}

// SystemInfo collects system metadata for the prompt context.
type SystemInfo struct {
	Timestamp string
	Username  string
	Hostname  string
	Distro    string
	Platform  string
	Shell     string
}

// Capture builds a snapshot and records best-effort warnings on failure.
func Capture() Snapshot {
	var warnings []string

	sys := collectSystemInfo()

	cwd, err := os.Getwd()
	if err != nil {
		warnings = append(warnings, fmt.Sprintf("current directory unavailable: %v", err))
	}

	var listing *DirectoryListing
	if err == nil {
		if l, derr := directoryListing(cwd, maxDirEntries); derr != nil {
			warnings = append(warnings, fmt.Sprintf("could not list directory entries: %v", derr))
		} else {
			listing = &l
		}
	}

	history, err := captureHistory(historyLimit)
	if err != nil {
		warnings = append(warnings, fmt.Sprintf("could not read shell history: %v", err))
	}

	return Snapshot{
		CWD:       cwd,
		Directory: listing,
		History:   history,
		System:    sys,
		Warnings:  warnings,
	}
}

// ComposePrompt trims the user prompt, appends the rendered snapshot, and
// returns the final payload sent to the language model.
func ComposePrompt(userPrompt string) (string, error) {
	snapshot := Capture()

	var b strings.Builder
	trimmed := strings.TrimSpace(userPrompt)
	if trimmed == "" {
		b.WriteString(userPrompt)
	} else {
		b.WriteString(trimmed)
	}
	b.WriteString("\n\n---\n")
	b.WriteString(snapshot.Render())
	return b.String(), nil
}

// Render formats the snapshot similarly to the existing Ratatui output.
func (s Snapshot) Render() string {
	var b strings.Builder
	fmt.Fprintln(&b, "Context:")

	fmt.Fprintf(&b, "- Timestamp: %s\n", s.System.Timestamp)
	fmt.Fprintf(&b, "- User: %s\n", s.SystemUser())
	fmt.Fprintf(&b, "- OS: %s (%s)\n", s.System.Distro, s.System.Platform)
	if s.System.Shell != "" {
		fmt.Fprintf(&b, "- Shell: %s\n", s.System.Shell)
	}

	if s.CWD != "" {
		fmt.Fprintf(&b, "- Current directory: %s\n", s.CWD)
	} else {
		fmt.Fprintln(&b, "- Current directory: unavailable")
	}

	if s.Directory != nil {
		fmt.Fprintf(
			&b,
			"- Directory entries (total %d, showing %d):\n",
			s.Directory.Total,
			len(s.Directory.Entries),
		)
		for i, entry := range s.Directory.Entries {
			hidden := ""
			if entry.Hidden {
				hidden = " (hidden)"
			}
			fmt.Fprintf(&b, "  %d. [%s] %s%s\n", i+1, entry.Kind.Label(), entry.Name, hidden)
		}
		if s.Directory.Truncated {
			fmt.Fprintln(&b, "  …")
		}
	} else {
		fmt.Fprintln(&b, "- Directory entries: unavailable")
	}

	if len(s.History) > 0 {
		fmt.Fprintf(&b, "- Recent commands (last %d):\n", len(s.History))
		for i, entry := range s.History {
			fmt.Fprintf(&b, "  %d. %s\n", i+1, entry)
		}
	} else {
		fmt.Fprintln(&b, "- Recent commands: unavailable")
	}

	if len(s.Warnings) > 0 {
		fmt.Fprintln(&b, "- Warnings:")
		for _, w := range s.Warnings {
			fmt.Fprintf(&b, "  • %s\n", w)
		}
	}

	return strings.TrimRight(b.String(), "\n")
}

// SystemUser returns "username@hostname" for convenience.
func (s Snapshot) SystemUser() string {
	username := s.System.Username
	if username == "" {
		username = "unknown-user"
	}
	hostname := s.System.Hostname
	if hostname == "" {
		hostname = "unknown-host"
	}
	return fmt.Sprintf("%s@%s", username, hostname)
}

func collectSystemInfo() SystemInfo {
	timestamp := time.Now().Format("2006-01-02 15:04:05 MST")
	username := currentUsername()
	hostname, _ := os.Hostname()
	distro := detectDistro()
	platform := fmt.Sprintf("%s-%s", runtime.GOOS, runtime.GOARCH)
	shell := os.Getenv("SHELL")

	return SystemInfo{
		Timestamp: timestamp,
		Username:  username,
		Hostname:  hostname,
		Distro:    distro,
		Platform:  platform,
		Shell:     shell,
	}
}

func currentUsername() string {
	if username := os.Getenv("USER"); username != "" {
		return username
	}
	u, err := user.Current()
	if err != nil {
		return "unknown-user"
	}
	if u.Username != "" {
		return u.Username
	}
	if u.Name != "" {
		return u.Name
	}
	return "unknown-user"
}

func detectDistro() string {
	if runtime.GOOS == "darwin" {
		return "macOS"
	}
	if runtime.GOOS == "windows" {
		return "Windows"
	}

	// Attempt /etc/os-release on Unix.
	file, err := os.Open("/etc/os-release")
	if err != nil {
		return runtime.GOOS
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "PRETTY_NAME=") {
			value := strings.TrimPrefix(line, "PRETTY_NAME=")
			return strings.Trim(value, "\"")
		}
	}
	if err := scanner.Err(); err != nil {
		return runtime.GOOS
	}
	return runtime.GOOS
}

func directoryListing(path string, limit int) (DirectoryListing, error) {
	dirEntries, err := os.ReadDir(path)
	if err != nil {
		return DirectoryListing{}, err
	}

	listing := DirectoryListing{Total: len(dirEntries)}

	entries := make([]DirectoryEntry, 0, len(dirEntries))
	for _, entry := range dirEntries {
		info := DirectoryEntry{
			Name:   entry.Name(),
			Hidden: strings.HasPrefix(entry.Name(), "."),
			Kind:   classifyEntry(path, entry),
		}
		entries = append(entries, info)
	}

	sort.Slice(entries, func(i, j int) bool {
		return strings.ToLower(entries[i].Name) < strings.ToLower(entries[j].Name)
	})

	if len(entries) > limit {
		listing.Truncated = true
		entries = entries[:limit]
	}
	listing.Entries = entries
	return listing, nil
}

func classifyEntry(parent string, entry os.DirEntry) EntryKind {
	info, err := entry.Info()
	if err != nil {
		return entryUnknown
	}
	switch {
	case info.IsDir():
		return entryDirectory
	case (info.Mode() & os.ModeSymlink) != 0:
		return entrySymlink
	case info.Mode().IsRegular():
		return entryFile
	default:
		return entryUnknown
	}
}

func captureHistory(limit int) ([]string, error) {
	path, err := historyFilePath()
	if err != nil {
		return nil, err
	}

	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 512), 1024*1024)

	ring := make([]string, 0, limit)
	for scanner.Scan() {
		line := parseHistoryLine(scanner.Text())
		if line == "" {
			continue
		}
		if len(ring) == limit {
			ring = ring[1:]
		}
		ring = append(ring, line)
	}

	if err := scanner.Err(); err != nil {
		return nil, err
	}
	if len(ring) == 0 {
		return nil, nil
	}
	return append([]string(nil), ring...), nil
}

func historyFilePath() (string, error) {
	if path := os.Getenv("HISTFILE"); path != "" {
		return path, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".zsh_history"), nil
}

func parseHistoryLine(line string) string {
	line = strings.TrimSpace(line)
	if line == "" {
		return ""
	}
	if idx := strings.IndexRune(line, ';'); idx >= 0 {
		return strings.TrimSpace(line[idx+1:])
	}
	return line
}
