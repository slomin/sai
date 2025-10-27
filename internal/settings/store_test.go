package settings

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestNewStoreDefaultPath(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", "") // ensure we rely on os.UserConfigDir semantics

	dir, err := os.UserConfigDir()
	if err != nil {
		t.Fatalf("user config dir: %v", err)
	}

	store, err := NewStore()
	if err != nil {
		t.Fatalf("new store: %v", err)
	}

	want := filepath.Join(dir, "sai", "config.json")
	if !strings.HasSuffix(store.Path(), filepath.FromSlash("sai/config.json")) {
		t.Fatalf("store path %q does not end with sai/config.json", store.Path())
	}
	if filepath.Clean(store.Path()) != filepath.Clean(want) {
		t.Fatalf("store path = %q, want %q", store.Path(), want)
	}
}

func TestLoadMissingFileReturnsEmptyConfig(t *testing.T) {
	base := t.TempDir()
	store, err := NewStore(WithBaseDir(base))
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	cfg, err := store.Load()
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if (cfg != Config{}) {
		t.Fatalf("expected empty config, got %+v", cfg)
	}
}

func TestSaveAndLoadRoundTrip(t *testing.T) {
	base := t.TempDir()
	store, err := NewStore(WithBaseDir(base))
	if err != nil {
		t.Fatalf("new store: %v", err)
	}

	want := Config{
		Mode:     ModeLocal,
		Endpoint: "http://localhost:8080/v1/chat/completions",
		Model:    "my-model",
		APIKey:   "secret",
	}

	if err := store.Save(want); err != nil {
		t.Fatalf("save: %v", err)
	}

	got, err := store.Load()
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if got != want {
		t.Fatalf("round trip mismatch: got %+v want %+v", got, want)
	}

	data, err := os.ReadFile(store.Path())
	if err != nil {
		t.Fatalf("read file: %v", err)
	}

	var payload map[string]any
	if err := json.Unmarshal(data, &payload); err != nil {
		t.Fatalf("decode json: %v", err)
	}
	if v, ok := payload["version"]; !ok || v.(float64) != 1 {
		t.Fatalf("expected version=1, payload=%v", payload)
	}
}

func TestLoadCorruptFileReturnsError(t *testing.T) {
	base := t.TempDir()
	store, err := NewStore(WithBaseDir(base))
	if err != nil {
		t.Fatalf("new store: %v", err)
	}

	path := store.Path()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(path, []byte("{not-json]"), 0o600); err != nil {
		t.Fatalf("write file: %v", err)
	}

	_, err = store.Load()
	if err == nil {
		t.Fatal("expected error when loading corrupt file")
	}
	if !errors.Is(err, ErrCorruptConfig) {
		t.Fatalf("got error %v, want ErrCorruptConfig", err)
	}
}

func TestSaveCreatesDirectoryAndUsesTightPermissions(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("permission bits not reliable on windows")
	}
	base := filepath.Join(t.TempDir(), "nested")
	store, err := NewStore(WithBaseDir(base))
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	if err := store.Save(Config{Mode: ModeRemote}); err != nil {
		t.Fatalf("save: %v", err)
	}
	info, err := os.Stat(store.Path())
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("file mode = %v, want 0600", info.Mode().Perm())
	}
	dirInfo, err := os.Stat(filepath.Dir(store.Path()))
	if err != nil {
		t.Fatalf("stat dir: %v", err)
	}
	if dirInfo.Mode().Perm() != 0o700 {
		t.Fatalf("dir mode = %v, want 0700", dirInfo.Mode().Perm())
	}
}
