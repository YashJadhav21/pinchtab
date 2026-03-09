package main

import (
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/pinchtab/pinchtab/internal/config"
)

type startupBannerOptions struct {
	Mode       string
	ListenAddr string
	PublicURL  string
	Strategy   string
	ProfileDir string
}

func printStartupBanner(cfg *config.RuntimeConfig, opts startupBannerOptions) {
	writeBannerLine(renderStartupLogo(blankIfEmpty(opts.Mode, "server")))
	writeBannerf("  %s  %s\n", styleLabel("listen"), styleValue(blankIfEmpty(opts.ListenAddr, cfg.ListenAddr())))
	if opts.PublicURL != "" {
		writeBannerf("  %s  %s\n", styleLabel("url"), styleValue(opts.PublicURL))
	}
	if opts.Strategy != "" {
		writeBannerf("  %s  %s\n", styleLabel("strategy"), styleValue(opts.Strategy))
	}
	if opts.ProfileDir != "" {
		writeBannerf("  %s  %s\n", styleLabel("profile"), styleValue(opts.ProfileDir))
	}
	printSecuritySummary(os.Stdout, cfg, "  ")
	writeBannerLine("")
}

func printSecuritySummary(w io.Writer, cfg *config.RuntimeConfig, prefix string) {
	posture := assessSecurityPosture(cfg)

	writeSummaryf(
		w,
		"%s%s  %s  %s\n",
		prefix,
		styleLabel("security"),
		styleSecurityLevel(posture.Level),
		styleSecurityBar(posture.Level, renderPostureBar(posture.Passed, posture.Total)),
	)
	for _, check := range posture.Checks {
		writeSummaryf(
			w,
			"%s  [%s] %s %s\n",
			prefix,
			styleMarker(check.Passed),
			styleCheckLabel(check.Label),
			styleCheckDetail(check.Passed, check.Detail),
		)
	}
}

func renderPostureBar(passed, total int) string {
	if total <= 0 {
		return "[--------]"
	}
	var b strings.Builder
	b.WriteByte('[')
	for i := 0; i < total; i++ {
		if i < passed {
			b.WriteByte('#')
		} else {
			b.WriteByte('-')
		}
	}
	b.WriteByte(']')
	return b.String()
}

func blankIfEmpty(value, fallback string) string {
	if strings.TrimSpace(value) == "" {
		return fallback
	}
	return value
}

func renderStartupLogo(mode string) string {
	return styleLogo(startupLogo) + "  " + styleMode(mode)
}

func writeBannerLine(line string) {
	_, _ = fmt.Fprintln(os.Stdout, line)
}

func writeBannerf(format string, args ...any) {
	_, _ = fmt.Fprintf(os.Stdout, format, args...)
}

func writeSummaryf(w io.Writer, format string, args ...any) {
	_, _ = fmt.Fprintf(w, format, args...)
}

func styleLogo(text string) string {
	return applyStyle(text, ansiBold, ansiCyan)
}

func styleMode(text string) string {
	return applyStyle(text, ansiDim)
}

func styleLabel(text string) string {
	return applyStyle(fmt.Sprintf("%-8s", text), ansiDim)
}

func styleValue(text string) string {
	return applyStyle(text, ansiBold)
}

func styleCheckLabel(text string) string {
	return applyStyle(fmt.Sprintf("%-20s", text), ansiDim)
}

func styleCheckDetail(passed bool, text string) string {
	if passed {
		return applyStyle(text, ansiGreen)
	}
	return applyStyle(text, ansiYellow)
}

func styleMarker(passed bool) string {
	if passed {
		return applyStyle("ok", ansiBold, ansiGreen)
	}
	return applyStyle("!!", ansiBold, ansiRed)
}

func styleSecurityLevel(level string) string {
	return applyStyle(level, ansiBold, securityLevelColor(level))
}

func styleSecurityBar(level, bar string) string {
	return applyStyle(bar, ansiBold, securityLevelColor(level))
}

func securityLevelColor(level string) string {
	switch level {
	case "LOCKED":
		return ansiGreen
	case "GUARDED":
		return ansiYellow
	case "ELEVATED":
		return ansiRed
	default:
		return ansiRed
	}
}

func applyStyle(text string, codes ...string) string {
	if !shouldColorizeOutput() || len(codes) == 0 {
		return text
	}
	return "\x1b[" + strings.Join(codes, ";") + "m" + text + "\x1b[0m"
}

func shouldColorizeOutput() bool {
	if os.Getenv("NO_COLOR") != "" {
		return false
	}
	if force := os.Getenv("CLICOLOR_FORCE"); force != "" && force != "0" {
		return true
	}
	if strings.EqualFold(os.Getenv("TERM"), "dumb") {
		return false
	}
	info, err := os.Stdout.Stat()
	if err != nil {
		return false
	}
	return (info.Mode() & os.ModeCharDevice) != 0
}

const (
	ansiBold   = "1"
	ansiDim    = "2"
	ansiRed    = "31"
	ansiGreen  = "32"
	ansiYellow = "33"
	ansiCyan   = "36"
)

const startupLogo = `   ____  _            _     _____     _
  |  _ \(_)_ __   ___| |__ |_   _|_ _| |__
  | |_) | | '_ \ / __| '_ \  | |/ _  | '_ \
  |  __/| | | | | (__| | | | | | (_| | |_) |
  |_|   |_|_| |_|\___|_| |_| |_|\__,_|_.__/`
