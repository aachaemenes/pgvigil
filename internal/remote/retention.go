package remote

import (
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"time"
)

// SweepOutbox is the outbox's retention without a push (R12): a finished bundle not pushed goes keep_days after its
// window's end; then, while the outbox's finished bundles hold more than maxMB, the oldest goes first (the hub sees the
// gap; the caller logs it ERROR). A pushed bundle's keep_days are the push's (Pusher.Prune), its size counts toward the
// cap. A .part folder is never touched. It returns how many bundles went by age and how many by the cap.
func SweepOutbox(outbox string, keepDays, maxMB int, now time.Time) (aged, capped int) {
	bundles, err := finishedBundles(outbox)
	if err != nil {
		return 0, 0
	}
	var kept []outboxBundle
	for _, b := range bundles {
		_, pushedErr := os.Stat(b.dir + pushedExt)
		if pushedErr != nil && now.Sub(b.ref.End) > time.Duration(keepDays)*24*time.Hour {
			if os.RemoveAll(b.dir) == nil {
				aged++
				continue
			}
		}
		kept = append(kept, b)
	}
	size := func(dir string) int64 {
		var n int64
		_ = filepath.WalkDir(dir, func(_ string, d fs.DirEntry, err error) error {
			if err == nil && !d.IsDir() {
				if fi, err := d.Info(); err == nil {
					n += fi.Size()
				}
			}
			return nil
		})
		return n
	}
	var total int64
	sizes := map[string]int64{}
	for _, b := range kept {
		sizes[b.dir] = size(b.dir)
		total += sizes[b.dir]
	}
	sort.Slice(kept, func(i, j int) bool { return kept[i].ref.End.Before(kept[j].ref.End) })
	for _, b := range kept {
		if total <= int64(maxMB)<<20 {
			break
		}
		if os.RemoveAll(b.dir) == nil {
			_ = os.Remove(b.dir + pushedExt)
			total -= sizes[b.dir]
			capped++
		}
	}
	return aged, capped
}
