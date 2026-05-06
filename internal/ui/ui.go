// Package ui renders the packxy CLI experience using the charmbracelet
// stack (lipgloss, lipgloss/table, lipgloss/list, huh, huh/spinner).
//
// All public colors and helpers are designed to compose: cmd/packxy mostly
// strings calls together (Page → Header → Section → Spin → StepOK →
// SummaryCard → Footer) and lets this package handle every layout and
// styling concern.
package ui

import (
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/charmbracelet/huh"
	"github.com/charmbracelet/huh/spinner"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/lipgloss/list"
)

const boxWidth = 56

// Color is the palette type used by helpers like SummaryCard and Banner.
type Color = lipgloss.TerminalColor

// Public color palette so callers can pick a tone for banners/cards without
// re-declaring the same constants. Adaptive entries pick a value tuned for the
// active terminal background.
var (
	ColPrimary lipgloss.TerminalColor = lipgloss.AdaptiveColor{Light: "#C342B6", Dark: "#FF7DCB"}
	ColAccent  lipgloss.TerminalColor = lipgloss.AdaptiveColor{Light: "#0090A8", Dark: "#5BD7E0"}
	ColOK      lipgloss.TerminalColor = lipgloss.AdaptiveColor{Light: "#1E7C3C", Dark: "#5DD88E"}
	ColFail    lipgloss.TerminalColor = lipgloss.AdaptiveColor{Light: "#B0202B", Dark: "#FF6B7A"}
	ColWarn    lipgloss.TerminalColor = lipgloss.AdaptiveColor{Light: "#9B6B00", Dark: "#FFD479"}
	ColMuted   lipgloss.TerminalColor = lipgloss.AdaptiveColor{Light: "#7A7A7A", Dark: "#9A9A9A"}
	ColHint    lipgloss.TerminalColor = lipgloss.AdaptiveColor{Light: "#3A3A3A", Dark: "#D6D6D6"}
)

var (
	primary = lipgloss.NewStyle().Foreground(ColPrimary)
	muted   = lipgloss.NewStyle().Foreground(ColMuted)
	hint    = lipgloss.NewStyle().Foreground(ColHint)
	okSt    = lipgloss.NewStyle().Foreground(ColOK)
	failSt  = lipgloss.NewStyle().Foreground(ColFail)
	warnSt  = lipgloss.NewStyle().Foreground(ColWarn)
)

// Page clears the terminal.
func Page() {
	fmt.Print("\033[H\033[2J")
}

// Header prints the application banner.
func Header() {
	title := primary.Bold(true).Render("📦  P A C K X Y")
	subtitle := muted.Render("Keep calm! and Pack through the Proxy VPN!")
	body := title + "\n\n" + subtitle

	box := lipgloss.NewStyle().
		BorderForeground(ColPrimary).
		Border(lipgloss.DoubleBorder()).
		Align(lipgloss.Center).
		Width(boxWidth).
		Margin(1, 2).
		Padding(1, 2).
		Render(body)
	fmt.Println(box)
}

// Section prints a labeled divider used to separate phases of the run, e.g.
//
//	── Credentials ───────────────────────────────────────────
func Section(label string) {
	prefix := "── "
	titled := primary.Bold(true).Render(label)
	used := lipgloss.Width(prefix) + lipgloss.Width(label) + 1
	tail := strings.Repeat("─", max(0, boxWidth+2-used))
	line := muted.Render(prefix) + titled + " " + muted.Render(tail)
	fmt.Println()
	fmt.Println("  " + line)
	fmt.Println()
}

// Banner prints a large centered status box.
func Banner(color lipgloss.TerminalColor, title, subtitle string) {
	body := lipgloss.NewStyle().Bold(true).Foreground(color).Render(title)
	if subtitle != "" {
		body += "\n\n" + lipgloss.NewStyle().Foreground(color).Render(subtitle)
	}
	box := lipgloss.NewStyle().
		BorderForeground(color).
		Border(lipgloss.DoubleBorder()).
		Align(lipgloss.Center).
		Width(boxWidth).
		Margin(1, 2).
		Padding(1, 2).
		Render(body)
	fmt.Println(box)
}

// Tagline prints centered italic text framed with sparkle decorators.
func Tagline(color lipgloss.TerminalColor, text string) {
	out := lipgloss.NewStyle().
		Foreground(color).
		Italic(true).
		Align(lipgloss.Center).
		Width(boxWidth).
		Margin(0, 2).
		Render("✦  " + text + "  ✦")
	fmt.Println(out)
}

// StepOK prints a green check row. If a non-zero duration is provided, it is
// shown muted and right-aligned to the section width.
func StepOK(text string, dur ...time.Duration) {
	stepLine(okSt.Bold(true).Render("✔"), ColOK, text, optDur(dur))
}

// StepFail prints a red cross row.
func StepFail(text string) {
	stepLine(failSt.Bold(true).Render("✖"), ColFail, text, "")
}

// StepWarn prints a yellow warn row.
func StepWarn(text string) {
	stepLine(warnSt.Bold(true).Render("⚠"), ColWarn, text, "")
}

// StepInfo prints a muted indented info row (no icon).
func StepInfo(text string) {
	fmt.Println("     " + muted.Render(text))
}

func stepLine(icon string, color lipgloss.TerminalColor, text, right string) {
	body := lipgloss.NewStyle().Foreground(color).Render(text)
	left := "  " + icon + "  " + body
	if right == "" {
		fmt.Println(left)
		return
	}
	pad := max(2, boxWidth+4-lipgloss.Width(left)-lipgloss.Width(right))
	fmt.Println(left + strings.Repeat(" ", pad) + muted.Render(right))
}

func optDur(d []time.Duration) string {
	if len(d) == 0 || d[0] == 0 {
		return ""
	}
	return formatDur(d[0])
}

func formatDur(d time.Duration) string {
	switch {
	case d < time.Millisecond:
		return "<1ms"
	case d < time.Second:
		return fmt.Sprintf("%dms", d.Milliseconds())
	case d < time.Minute:
		return fmt.Sprintf("%.1fs", d.Seconds())
	default:
		return d.Round(time.Second).String()
	}
}

// CardLine is one row in a SummaryCard.
type CardLine struct{ Icon, Label, Value string }

// SummaryCard renders a tidy three-column layout (icon, label, value) inside a
// rounded border tinted with the given color.
func SummaryCard(color lipgloss.TerminalColor, lines []CardLine) {
	iconW, labelW := 0, 0
	for _, l := range lines {
		if w := lipgloss.Width(l.Icon); w > iconW {
			iconW = w
		}
		if w := lipgloss.Width(l.Label); w > labelW {
			labelW = w
		}
	}

	iconCol := lipgloss.NewStyle().Width(iconW).Align(lipgloss.Center)
	labelCol := lipgloss.NewStyle().Foreground(ColMuted).Bold(true).Width(labelW)
	valueCol := lipgloss.NewStyle().Foreground(ColHint)

	rendered := make([]string, 0, len(lines))
	for _, l := range lines {
		row := iconCol.Render(l.Icon) + "  " + labelCol.Render(l.Label) + "  " + valueCol.Render(l.Value)
		rendered = append(rendered, row)
	}
	body := strings.Join(rendered, "\n")

	box := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(color).
		Width(boxWidth).
		Padding(0, 2).
		Margin(0, 2).
		Render(body)
	fmt.Println(box)
}

// ErrorCard renders raw error output inside a red rounded box.
func ErrorCard(text string) {
	body := strings.TrimRight(text, "\n")
	box := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(ColFail).
		Width(boxWidth).
		Padding(0, 2).
		Margin(0, 2).
		Foreground(ColFail).
		Render(body)
	fmt.Println(box)
}

// Footer prints a help bar with key actions, rendered as a bulleted list.
func Footer() {
	fmt.Println()
	sep := muted.Render(" › ")
	keyStyle := lipgloss.NewStyle().Foreground(ColMuted).Bold(true)
	cmdStyle := hint

	items := []any{
		keyStyle.Render("Disconnect") + sep + cmdStyle.Render("packxy stop"),
		keyStyle.Render("Live logs ") + sep + cmdStyle.Render("docker compose logs -f"),
	}

	l := list.New(items...).
		Enumerator(list.Bullet).
		EnumeratorStyle(lipgloss.NewStyle().Foreground(ColPrimary))

	fmt.Println(lipgloss.NewStyle().Margin(0, 4).Render(l.String()))
}

// MutedHint prints a subtle hint line.
func MutedHint(s string) {
	fmt.Println(muted.Render(s))
}

// KeyValue renders one aligned key/value row for help and usage screens.
// The key is emphasized; the description is rendered as hint text.
func KeyValue(key, value string) {
	const keyW = 12
	pad := strings.Repeat(" ", max(0, keyW-lipgloss.Width(key)))
	fmt.Println("    " + primary.Bold(true).Render(key) + pad + hint.Render(value))
}

// Line prints a left-padded plain line, useful for help/usage bodies.
func Line(s string) {
	fmt.Println("    " + hint.Render(s))
}

// formTheme returns a custom huh theme aligned with the project palette.
func formTheme() *huh.Theme {
	t := huh.ThemeCharm()
	pri := lipgloss.NewStyle().Foreground(ColPrimary).Bold(true)
	t.Focused.Title = pri
	t.Focused.NoteTitle = pri
	t.Focused.Description = lipgloss.NewStyle().Foreground(ColMuted)
	t.Focused.Base = t.Focused.Base.BorderForeground(ColPrimary)
	t.Focused.SelectSelector = pri
	t.Focused.SelectedOption = pri
	t.Focused.SelectedPrefix = pri
	t.Focused.FocusedButton = lipgloss.NewStyle().
		Foreground(lipgloss.Color("0")).
		Background(ColPrimary).
		Padding(0, 2).
		Bold(true)
	t.Focused.TextInput.Cursor = lipgloss.NewStyle().Foreground(ColPrimary)
	t.Focused.TextInput.Prompt = lipgloss.NewStyle().Foreground(ColPrimary)
	t.Focused.TextInput.Placeholder = lipgloss.NewStyle().Foreground(ColMuted)
	t.Blurred = t.Focused
	t.Blurred.Base = t.Blurred.Base.BorderForeground(ColMuted)
	return t
}

// Input asks for a single text input. The current value is the default.
func Input(header, placeholder, value string) (string, error) {
	out := value
	form := huh.NewForm(
		huh.NewGroup(
			huh.NewInput().
				Title(header).
				Placeholder(placeholder).
				Value(&out),
		),
	).WithTheme(formTheme())
	if err := form.Run(); err != nil {
		return "", err
	}
	return out, nil
}

// Password asks for a hidden text input.
func Password(header, placeholder, value string) (string, error) {
	out := value
	form := huh.NewForm(
		huh.NewGroup(
			huh.NewInput().
				Title(header).
				Placeholder(placeholder).
				EchoMode(huh.EchoModePassword).
				Value(&out),
		),
	).WithTheme(formTheme())
	if err := form.Run(); err != nil {
		return "", err
	}
	return out, nil
}

// SixDigitOTP asks until the user provides a 6-digit code.
func SixDigitOTP(value string) (string, error) {
	out := value
	form := huh.NewForm(
		huh.NewGroup(
			huh.NewInput().
				Title("  2FA Code").
				Placeholder("123456").
				Value(&out).
				Validate(func(s string) error {
					if len(s) != 6 {
						return fmt.Errorf("must be exactly 6 digits")
					}
					for _, r := range s {
						if r < '0' || r > '9' {
							return fmt.Errorf("must be exactly 6 digits")
						}
					}
					return nil
				}),
		),
	).WithTheme(formTheme())
	if err := form.Run(); err != nil {
		return "", err
	}
	return out, nil
}

// Spin runs fn while showing a themed spinner. Returns elapsed wall-clock time
// and fn's error (or the spinner's, whichever fired first).
func Spin(title string, fn func() error) (time.Duration, error) {
	var fnErr error
	titleStyle := lipgloss.NewStyle().Foreground(ColHint)
	spinStyle := lipgloss.NewStyle().Foreground(ColPrimary).Bold(true)

	start := time.Now()
	err := spinner.New().
		Type(spinner.MiniDot).
		Style(spinStyle).
		TitleStyle(titleStyle).
		Title("  " + title).
		Action(func() {
			fnErr = fn()
		}).
		Run()
	dur := time.Since(start)
	if err != nil {
		return dur, err
	}
	return dur, fnErr
}

// PressEnter blocks until the user confirms.
func PressEnter(prompt string) {
	confirm := false
	_ = huh.NewForm(
		huh.NewGroup(
			huh.NewConfirm().
				Title(prompt).
				Affirmative("OK").
				Negative("").
				Value(&confirm),
		),
	).WithTheme(formTheme()).Run()
}

// Sleep gives the spinner time to render after starting.
func Sleep(d time.Duration) { time.Sleep(d) }

// PrintErr writes an error line to stderr.
func PrintErr(format string, a ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", a...)
}
