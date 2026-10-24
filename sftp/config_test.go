package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestTemplateIsReadLikeTheFlagParserReadsIt(t *testing.T) {
	directory := t.TempDir()
	profile := filepath.Join(directory, "profile.yml")
	if err := os.WriteFile(profile, []byte("max-filesize: 7\npath: [/srv]\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	other := filepath.Join(directory, "other.yml")
	if err := os.WriteFile(other, []byte("max-filesize: 3\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{
		{"-t", profile},
		{"-t=" + profile},
		{"-t" + profile},
		{"--template", profile},
		{"--template=" + profile},
		{"-t", other, "-t", profile},
	} {
		config, err := parseConfig(args)
		if err != nil {
			t.Errorf("parseConfig(%q): %v", args, err)
			continue
		}
		if config.MaxFileSizeMB != 7 || !reflect.DeepEqual(config.RootPaths, []string{"/srv"}) {
			t.Errorf("parseConfig(%q): max-filesize %d, paths %v; want the profile's 7 and [/srv]", args, config.MaxFileSizeMB, config.RootPaths)
		}
	}

	config, err := parseConfig([]string{"-t", profile, "-m", "9", "-p", "/opt"})
	if err != nil {
		t.Fatal(err)
	}
	if config.MaxFileSizeMB != 9 || !reflect.DeepEqual(config.RootPaths, []string{"/opt"}) {
		t.Errorf("command-line values: max-filesize %d, paths %v; want 9 and [/opt]", config.MaxFileSizeMB, config.RootPaths)
	}
}

func TestResponseTimeoutDefaultsAndValidation(t *testing.T) {
	base := Config{SFTPHost: "source", Server: "thunderstorm", MaxFileSizeMB: 1, Threads: 1, WalkThreads: 1, RootPaths: []string{"/"}}
	settings, err := validateConfig(base)
	if err != nil || settings.ResponseTimeout.Minutes() != 2 {
		t.Errorf("asynchronous default: %v, %v; want 2m", settings.ResponseTimeout, err)
	}
	synchronous := base
	synchronous.Sync = true
	if settings, err = validateConfig(synchronous); err != nil || settings.ResponseTimeout.Minutes() != 30 {
		t.Errorf("synchronous default: %v, %v; want 30m", settings.ResponseTimeout, err)
	}
	explicit := base
	explicit.ResponseTimeout = "90s"
	if settings, err = validateConfig(explicit); err != nil || settings.ResponseTimeout.Seconds() != 90 {
		t.Errorf("explicit: %v, %v; want 90s", settings.ResponseTimeout, err)
	}
	for _, value := range []string{"90", "-5s", "soon"} {
		invalid := base
		invalid.ResponseTimeout = value
		if _, err := validateConfig(invalid); err == nil {
			t.Errorf("response-timeout %q accepted, want an error", value)
		}
	}
}
