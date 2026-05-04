package ui

import (
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/charmbracelet/huh"
	"github.com/charmbracelet/huh/spinner"
	"github.com/charmbracelet/lipgloss"
)

const boxWidth = 56

var (
	colPrimary = lipgloss.Color("212")
	colOK      = lipgloss.Color("10")
	colFail    = lipgloss.Color("9")
	colWarn    = lipgloss.Color("11")
	colMuted   = lipgloss.Color("240")
	colWhite   = lipgloss.Color("15")
	colHint    = lipgloss.Color("7")
)

func Page() {
	fmt.Print("\033[H\033[2J")
}

func Header() {
	box := lipgloss.NewStyle().
		Foreground(colPrimary).
		BorderForeground(colPrimary).
		Border(lipgloss.DoubleBorder()).
		Align(lipgloss.Center).
		Width(boxWidth).
		Margin(1, 2).
		Padding(1, 2).
		Render("📦 Packxy\n\nKeep calm and Pack through the Proxy VPN!")
	fmt.Println(box)
	fmt.Println()
}

func Banner(color lipgloss.Color, title, subtitle string) {
	body := title
	if subtitle != "" {
		body = title + "\n\n" + subtitle
	}
	box := lipgloss.NewStyle().
		Foreground(color).
		BorderForeground(color).
		Border(lipgloss.DoubleBorder()).
		Align(lipgloss.Center).
		Width(boxWidth).
		Margin(1, 2).
		Padding(1, 2).
		Render(body)
	fmt.Println(box)
}

func Tagline(color lipgloss.Color, text string) {
	out := lipgloss.NewStyle().
		Foreground(color).
		Italic(true).
		Align(lipgloss.Center).
		Width(boxWidth).
		Margin(0, 2).
		Render(text)
	fmt.Println(out)
}

func StepOK(s string)   { fmt.Println(lipgloss.NewStyle().Foreground(colOK).Render("  ✔  " + s)) }
func StepFail(s string) { fmt.Println(lipgloss.NewStyle().Foreground(colFail).Render("  ✖  " + s)) }
func StepWarn(s string) { fmt.Println(lipgloss.NewStyle().Foreground(colWarn).Render("  ⚠  " + s)) }
func StepInfo(s string) { fmt.Println(lipgloss.NewStyle().Foreground(colMuted).Render("     " + s)) }

type CardLine struct {
	Icon, Label, Value string
}

func SummaryCard(color lipgloss.Color, lines []CardLine) {
	var sb strings.Builder
	for i, l := range lines {
		if i > 0 {
			sb.WriteString("\n")
		}
		sb.WriteString(fmt.Sprintf("%-4s %-10s %s", l.Icon, l.Label, l.Value))
	}
	box := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(color).
		Width(boxWidth).
		Padding(0, 2).
		Margin(0, 2).
		Foreground(colWhite).
		Render(sb.String())
	fmt.Println(box)
}

func ErrorCard(text string) {
	var sb strings.Builder
	for i, line := range strings.Split(strings.TrimRight(text, "\n"), "\n") {
		if i > 0 {
			sb.WriteString("\n")
		}
		sb.WriteString("  " + line)
	}
	box := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(colFail).
		Width(boxWidth).
		Padding(0, 2).
		Margin(0, 2).
		Foreground(colFail).
		Render(sb.String())
	fmt.Println(box)
}

func Footer() {
	fmt.Println()
	mute := lipgloss.NewStyle().Foreground(colMuted)
	hint := lipgloss.NewStyle().Foreground(colHint)
	fmt.Println(mute.Render("     ⏎  Stop   ") + hint.Render("packxy stop"))
	fmt.Println(mute.Render("     ≡  Logs   ") + hint.Render("docker compose logs -f"))
}

func MutedHint(s string) {
	fmt.Println(lipgloss.NewStyle().Foreground(colMuted).Render(s))
}

// Input asks for a single text input. The current value is the placeholder default.
func Input(header, placeholder, value string) (string, error) {
	out := value
	form := huh.NewForm(
		huh.NewGroup(
			huh.NewInput().
				Title(header).
				Placeholder(placeholder).
				Value(&out),
		),
	).WithTheme(huh.ThemeCharm())
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
	).WithTheme(huh.ThemeCharm())
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
	).WithTheme(huh.ThemeCharm())
	if err := form.Run(); err != nil {
		return "", err
	}
	return out, nil
}

// Spin runs fn in the background while showing a spinner with title.
// Returns whatever error fn produces.
func Spin(title string, fn func() error) error {
	var fnErr error
	err := spinner.New().
		Title("  " + title).
		Action(func() {
			fnErr = fn()
		}).
		Run()
	if err != nil {
		return err
	}
	return fnErr
}

// PressEnter blocks waiting for the user to press Enter.
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
	).WithTheme(huh.ThemeCharm()).Run()
}

// Sleep is a small helper used to give the spinner time to render.
func Sleep(d time.Duration) { time.Sleep(d) }

// PrintErr writes to stderr with newline.
func PrintErr(format string, a ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", a...)
}
