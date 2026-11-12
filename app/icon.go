package main

// iconPixel is one pixel of the app's icon at size n: mark E - a teal rounded square, a white eye (an almond), a teal
// iris, a dark pupil and, from 32 px, a white glint - as premultiplied BGRA, each pixel the mean of a 4 x 4 sample grid
// (anti-aliased). Up to 24 px it draws the mark's own 16 px drawing (a larger iris and pupil, so the eye still reads in a
// 16 px tray), above that the 32 px drawing scaled.
func iconPixel(x, y, n int) uint32 {
	const ss = 4
	d := &mark32
	if n <= 24 {
		d = &mark16
	}
	var a, r, g, b float64
	for sy := 0; sy < ss; sy++ {
		for sx := 0; sx < ss; sx++ {
			// the sample point in the drawing's own units (0..d.size)
			u := (float64(x) + (float64(sx)+0.5)/ss) / float64(n) * d.size
			v := (float64(y) + (float64(sy)+0.5)/ss) / float64(n) * d.size
			c, in := d.at(u, v)
			if !in {
				continue // outside the square: transparent
			}
			a++
			r += c[0]
			g += c[1]
			b += c[2]
		}
	}
	const total = ss * ss
	// premultiplied: the colour sums over all samples (the outside ones count as black)
	return uint32(a*255/total)<<24 | uint32(r/total)<<16 | uint32(g/total)<<8 | uint32(b/total)
}

var (
	teal  = [3]float64{15, 118, 110} // #0f766e
	white = [3]float64{255, 255, 255}
	dark  = [3]float64{11, 31, 42} // #0b1f2a
)

// markDrawing is one of the mark's two drawings (e-eye-16.svg, e-eye.svg), in its viewBox units.
type markDrawing struct {
	size           float64 // the viewBox's side
	sq0, sq1, rx   float64 // the rounded square from sq0 to sq1 on both axes, its corner radius
	ax0, ax1       float64 // the almond's two tips (on the middle line)
	cx0, cx1, cy   float64 // the upper lid's Bezier control points (cx0, cy) and (cx1, cy); the lower lid mirrors it
	iris, pupil    float64 // radii about the centre
	gx, gy, glintR float64 // the glint (none when glintR is 0)
}

var (
	mark16 = markDrawing{size: 16, sq0: 0, sq1: 16, rx: 3.5, ax0: 1, ax1: 15, cx0: 3.6, cx1: 12.4, cy: 3.4, iris: 3.4, pupil: 1.5}
	mark32 = markDrawing{size: 32, sq0: 1, sq1: 31, rx: 7, ax0: 3.2, ax1: 28.8, cx0: 8.4, cx1: 23.6, cy: 7.6, iris: 6, pupil: 2.7, gx: 17.6, gy: 14.4, glintR: 1.1}
)

// at is the colour at (u, v), the shapes painted in the SVG's order; false outside the rounded square.
func (d *markDrawing) at(u, v float64) ([3]float64, bool) {
	if !d.inSquare(u, v) {
		return teal, false
	}
	m := d.size / 2
	r2 := (u-m)*(u-m) + (v-m)*(v-m)
	switch {
	case d.glintR > 0 && (u-d.gx)*(u-d.gx)+(v-d.gy)*(v-d.gy) <= d.glintR*d.glintR:
		return white, true
	case r2 <= d.pupil*d.pupil:
		return dark, true
	case r2 <= d.iris*d.iris:
		return teal, true
	case d.inAlmond(u, v):
		return white, true
	}
	return teal, true
}

func (d *markDrawing) inSquare(u, v float64) bool {
	if u < d.sq0 || u > d.sq1 || v < d.sq0 || v > d.sq1 {
		return false
	}
	dx := max(d.sq0+d.rx-u, 0, u-(d.sq1-d.rx))
	dy := max(d.sq0+d.rx-v, 0, v-(d.sq1-d.rx))
	return dx*dx+dy*dy <= d.rx*d.rx
}

// inAlmond: between the upper lid (a cubic Bezier from (ax0, m) to (ax1, m)) and its mirror about the middle line.
func (d *markDrawing) inAlmond(u, v float64) bool {
	if u <= d.ax0 || u >= d.ax1 {
		return false
	}
	m := d.size / 2
	bez := func(t, p0, p1, p2, p3 float64) float64 {
		s := 1 - t
		return s*s*s*p0 + 3*s*s*t*p1 + 3*s*t*t*p2 + t*t*t*p3
	}
	// x(t) rises with t (the control points lie in order): bisect for the t at u
	lo, hi := 0.0, 1.0
	for i := 0; i < 30; i++ {
		t := (lo + hi) / 2
		if bez(t, d.ax0, d.cx0, d.cx1, d.ax1) < u {
			lo = t
		} else {
			hi = t
		}
	}
	top := bez((lo+hi)/2, m, d.cy, d.cy, m)
	return v >= top && v <= 2*m-top
}
