package main

// iconPixel is one pixel of the app's icon at size n: a teal disc with a white eye (an almond outline
// and a pupil), as premultiplied BGRA, each pixel the mean of a 4 x 4 sample grid (anti-aliased).
func iconPixel(x, y, n int) uint32 {
	const ss = 4
	var a, r, g, b float64
	for sy := 0; sy < ss; sy++ {
		for sx := 0; sx < ss; sx++ {
			// u, v in -1..1 from the pixel's sample point
			u := (float64(x)+(float64(sx)+0.5)/ss)/float64(n)*2 - 1
			v := (float64(y)+(float64(sy)+0.5)/ss)/float64(n)*2 - 1
			if u*u+v*v > 0.94*0.94 {
				continue // outside the disc: transparent
			}
			cr, cg, cb := 15.0, 118.0, 110.0 // #0f766e
			if eye(u, v) {
				cr, cg, cb = 255, 255, 255
			}
			a++
			r += cr
			g += cg
			b += cb
		}
	}
	const total = ss * ss
	// premultiplied: the colour sums over all samples (the outside ones count as black)
	return uint32(a*255/total)<<24 | uint32(r/total)<<16 | uint32(g/total)<<8 | uint32(b/total)
}

// eye is the white part: the band between two arcs (the lids) and a pupil in the middle.
func eye(u, v float64) bool {
	if u*u+v*v < 0.17*0.17 {
		return true // the pupil
	}
	if u < -0.68 || u > 0.68 {
		return false
	}
	// each lid is a parabola v = +-h(1 - (u/0.68)^2); the white is a band 0.11 thick along each
	h := 0.42 * (1 - (u/0.68)*(u/0.68))
	d := v
	if d < 0 {
		d = -d
	}
	return d <= h && d >= h-0.11
}
