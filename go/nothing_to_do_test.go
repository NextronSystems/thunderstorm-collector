package main

import "testing"

func TestNothingToDoOnlyWithoutServerAndDryRun(t *testing.T) {
	cases := []struct {
		name     string
		argCount int
		config   Config
		want     bool
	}{
		{"no arguments, no server", 1, Config{}, true},
		{"no arguments, server in config.yml", 1, Config{Server: "thunderstorm"}, false},
		{"no arguments, dry run in config.yml", 1, Config{DryRun: true}, false},
		{"with arguments", 2, Config{}, false},
	}
	for _, c := range cases {
		if got := nothingToDo(c.argCount, c.config); got != c.want {
			t.Errorf("%s: nothingToDo = %v, want %v", c.name, got, c.want)
		}
	}
}
