// Command genicon writes assets/icon.png — the source artwork for the
// packxy.app icon set. The PNG is then fanned out to a multi-resolution
// iconset and converted to .icns by the Makefile (sips + iconutil).
//
// Design: a 1024x1024 rounded square with a vertical violet→cyan gradient
// background and a stylized white padlock (the same palette as the CLI
// banner). It's intentionally simple — no font dependencies, no SVG
// pipeline — so the build stays self-contained. Replace the output with
// any 1024x1024 PNG to ship a different icon.
package main

import (
	"image"
	"image/color"
	"image/png"
	"log"
	"math"
	"os"
)

const (
	size       = 1024
	cornerR    = 220
	bodyTop    = 460
	bodyHeight = 460
	bodyHalf   = 230 // body half-width
	shackleR   = 160 // shackle outer radius
	shackleT   = 70  // shackle thickness
	keyholeR   = 50
	keyholeStem = 90
)

func main() {
	img := image.NewRGBA(image.Rect(0, 0, size, size))

	// Vertical violet → cyan gradient inside a rounded square; transparent
	// outside.
	for y := 0; y < size; y++ {
		for x := 0; x < size; x++ {
			if !inRoundedRect(x, y, size, size, cornerR) {
				img.Set(x, y, color.RGBA{})
				continue
			}
			img.Set(x, y, gradient(y, size))
		}
	}

	// White padlock centered horizontally.
	cx := size / 2
	drawPadlock(img, cx)

	f, err := os.Create("assets/icon.png")
	if err != nil {
		log.Fatalf("create assets/icon.png: %v", err)
	}
	defer f.Close()
	if err := png.Encode(f, img); err != nil {
		log.Fatalf("encode: %v", err)
	}
	log.Printf("wrote assets/icon.png (%dx%d)", size, size)
}

// gradient returns the background colour at vertical position y, blending
// between the CLI's primary (violet) at the top and accent (cyan) at the
// bottom.
func gradient(y, h int) color.RGBA {
	top := color.RGBA{R: 0xC3, G: 0x42, B: 0xB6, A: 0xFF}    // ColPrimary (light)
	bot := color.RGBA{R: 0x5B, G: 0xD7, B: 0xE0, A: 0xFF}    // ColAccent (dark)
	t := float64(y) / float64(h-1)
	mix := func(a, b uint8) uint8 {
		return uint8(float64(a)*(1-t) + float64(b)*t)
	}
	return color.RGBA{R: mix(top.R, bot.R), G: mix(top.G, bot.G), B: mix(top.B, bot.B), A: 0xFF}
}

// inRoundedRect reports whether (x,y) falls inside a w×h rectangle whose
// corners are arcs of radius r.
func inRoundedRect(x, y, w, h, r int) bool {
	if x < 0 || x >= w || y < 0 || y >= h {
		return false
	}
	cx, cy := r, r
	switch {
	case x >= r && x < w-r:
		return true
	case y >= r && y < h-r:
		return true
	}
	if x >= w-r {
		cx = w - 1 - r
	}
	if y >= h-r {
		cy = h - 1 - r
	}
	dx := x - cx
	dy := y - cy
	return dx*dx+dy*dy <= r*r
}

// drawPadlock paints a centered white padlock onto img: rounded body
// rectangle + arc shackle on top + small keyhole.
func drawPadlock(img *image.RGBA, cx int) {
	white := color.RGBA{R: 0xFF, G: 0xFF, B: 0xFF, A: 0xFF}

	// Body — rounded rectangle.
	bodyL := cx - bodyHalf
	bodyR := cx + bodyHalf
	bodyB := bodyTop + bodyHeight
	bodyCornerR := 60
	for y := bodyTop; y < bodyB; y++ {
		for x := bodyL; x < bodyR; x++ {
			if inRoundedRectAt(x, y, bodyL, bodyTop, bodyR, bodyB, bodyCornerR) {
				img.Set(x, y, white)
			}
		}
	}

	// Shackle — open arc above the body. Center sits just above bodyTop.
	shackleCY := bodyTop - 10
	for y := shackleCY - shackleR - shackleT; y <= shackleCY; y++ {
		for x := cx - shackleR - shackleT; x <= cx+shackleR+shackleT; x++ {
			dx := x - cx
			dy := y - shackleCY
			d2 := dx*dx + dy*dy
			outer := (shackleR + shackleT) * (shackleR + shackleT)
			inner := shackleR * shackleR
			if d2 <= outer && d2 >= inner && y <= shackleCY {
				img.Set(x, y, white)
			}
		}
	}
	// Continue the shackle's two legs straight down into the body so it
	// doesn't look like a free-floating arc.
	legBottom := bodyTop + 50
	for y := shackleCY; y < legBottom; y++ {
		for dx := -shackleT / 2; dx <= shackleT/2; dx++ {
			x1 := cx - shackleR - shackleT/2 + dx
			x2 := cx + shackleR + shackleT/2 + dx
			img.Set(x1, y, white)
			img.Set(x2, y, white)
		}
	}

	// Keyhole — small circle with a stem, drawn in gradient colour to look
	// punched out of the body.
	keyCY := bodyTop + bodyHeight/2 - 20
	for y := keyCY - keyholeR; y <= keyCY+keyholeR+keyholeStem; y++ {
		for x := cx - keyholeR; x <= cx+keyholeR; x++ {
			dx := x - cx
			dy := y - keyCY
			inCircle := dx*dx+dy*dy <= keyholeR*keyholeR && y <= keyCY+keyholeR/2
			inStem := math.Abs(float64(dx)) <= float64(keyholeR)/2.5 &&
				y > keyCY && y <= keyCY+keyholeR+keyholeStem
			if inCircle || inStem {
				img.Set(x, y, gradient(y, size))
			}
		}
	}
}

// inRoundedRectAt is the same predicate as inRoundedRect but for a rectangle
// positioned at (l,t,r,b) instead of anchored at (0,0,w,h).
func inRoundedRectAt(x, y, l, t, r, b, radius int) bool {
	if x < l || x >= r || y < t || y >= b {
		return false
	}
	cx, cy := l+radius, t+radius
	switch {
	case x >= l+radius && x < r-radius:
		return true
	case y >= t+radius && y < b-radius:
		return true
	}
	if x >= r-radius {
		cx = r - 1 - radius
	}
	if y >= b-radius {
		cy = b - 1 - radius
	}
	dx := x - cx
	dy := y - cy
	return dx*dx+dy*dy <= radius*radius
}
