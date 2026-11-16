// Package scriptlint holds checks over the repository's own shell scripts (scripts/): rules a script's run on a shared
// box depends on and nothing else would catch. It has no code of its own; its tests read the scripts as text.
package scriptlint
