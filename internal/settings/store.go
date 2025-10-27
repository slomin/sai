package settings

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Mode indicates the preferred runtime setup.
type Mode string

const (
	ModeUnset  Mode = ""
	ModeRemote Mode = "remote"
	ModeLocal  Mode = "local"
	ModeCustom Mode = "custom"
)

const (
	currentVersion    = 1
	defaultFolderName = "sai"
	configFileName    = "config.json"
)

var (
	ErrCorruptConfig       = errors.New("settings: corrupt config")
	ErrIncompatibleVersion = errors.New("settings: incompatible version")
)

// Config captures persisted user preferences.
type Config struct {
	Mode     Mode   `json:"mode,omitempty"`
	Endpoint string `json:"endpoint,omitempty"`
	Model    string `json:"model,omitempty"`
	APIKey   string `json:"apiKey,omitempty"`
}

// Store persists and loads configuration from disk.
type Store struct {
	path string
}

type filePayload struct {
	Version   int       `json:"version"`
	UpdatedAt int64     `json:"updatedAt,omitempty"`
	Config    Config    `json:"config"`
	Metadata  *Metadata `json:"metadata,omitempty"`
}

// Metadata captures auxiliary persistence details.
type Metadata struct {
	Source string `json:"source,omitempty"`
}

// Option configures the Store.
type Option func(*Store) error

// NewStore constructs a Store instance.
func NewStore(opts ...Option) (*Store, error) {
	dir, err := os.UserConfigDir()
	if err != nil {
		return nil, err
	}
	s := &Store{
		path: filepath.Join(dir, defaultFolderName, configFileName),
	}
	for _, opt := range opts {
		if err := opt(s); err != nil {
			return nil, err
		}
	}
	return s, nil
}

// Load retrieves the stored configuration.
func (s *Store) Load() (Config, error) {
	data, err := os.ReadFile(s.path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return Config{}, nil
		}
		return Config{}, fmt.Errorf("read config: %w", err)
	}

	var payload filePayload
	if err := json.Unmarshal(data, &payload); err != nil {
		return Config{}, fmt.Errorf("decode config: %w", ErrCorruptConfig)
	}

	if payload.Version == 0 {
		payload.Version = 1
	}
	if payload.Version > currentVersion {
		return Config{}, fmt.Errorf("file version %d > supported %d: %w", payload.Version, currentVersion, ErrIncompatibleVersion)
	}

	return sanitizeConfig(payload.Config), nil
}

// Save writes the configuration to disk.
func (s *Store) Save(cfg Config) error {
	cfg = sanitizeConfig(cfg)

	payload := filePayload{
		Version:   currentVersion,
		Config:    cfg,
		UpdatedAt: time.Now().Unix(),
	}

	dir := filepath.Dir(s.path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("create settings dir: %w", err)
	}

	tmp, err := os.CreateTemp(dir, "config-*.tmp")
	if err != nil {
		return fmt.Errorf("create temp file: %w", err)
	}
	tmpPath := tmp.Name()
	defer func() {
		_ = tmp.Close()
		_ = os.Remove(tmpPath)
	}()

	if err := tmp.Chmod(0o600); err != nil && !os.IsPermission(err) {
		return fmt.Errorf("chmod temp file: %w", err)
	}

	encoder := json.NewEncoder(tmp)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(payload); err != nil {
		return fmt.Errorf("encode config: %w", err)
	}

	if err := tmp.Sync(); err != nil {
		return fmt.Errorf("sync temp file: %w", err)
	}

	if err := tmp.Close(); err != nil {
		return fmt.Errorf("close temp file: %w", err)
	}

	if err := os.Chmod(tmpPath, 0o600); err != nil && !os.IsPermission(err) {
		return fmt.Errorf("chmod temp file: %w", err)
	}

	if err := os.Rename(tmpPath, s.path); err != nil {
		return fmt.Errorf("replace config: %w", err)
	}

	if err := os.Chmod(s.path, 0o600); err != nil && !os.IsPermission(err) {
		return fmt.Errorf("chmod config: %w", err)
	}

	return nil
}

// Path returns the underlying config file path, primarily for tests.
func (s *Store) Path() string {
	return s.path
}

// WithBaseDir overrides the default config directory. Intended for testing.
func WithBaseDir(dir string) Option {
	return func(s *Store) error {
		if dir == "" {
			return errors.New("base dir required")
		}
		s.path = filepath.Join(dir, configFileName)
		return nil
	}
}

func sanitizeConfig(cfg Config) Config {
	cfg.Endpoint = strings.TrimSpace(cfg.Endpoint)
	cfg.Model = strings.TrimSpace(cfg.Model)
	cfg.APIKey = strings.TrimSpace(cfg.APIKey)

	switch cfg.Mode {
	case ModeRemote, ModeLocal, ModeCustom, ModeUnset:
	default:
		cfg.Mode = ModeUnset
	}
	return cfg
}
