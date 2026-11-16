package export

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
)

// ErrTooBig: an object past the cap a bounded read was given (GetMax); the error names the object and the cap.
var ErrTooBig = errors.New("past its cap")

// MaxGetter is the optional bounded read of a destination: at most max + 1 bytes are read, and an object past max is
// refused with ErrTooBig. The folder, S3 and Azure Blob destinations have it; Destination does not require it.
type MaxGetter interface {
	GetMax(ctx context.Context, key string, max int64) ([]byte, error)
}

// Getter is the read GetMax falls back on.
type Getter interface {
	Get(ctx context.Context, key string) ([]byte, error)
}

// GetMax reads key under max bytes: through the destination's own GetMax when it has one, else a Get and a length
// check (the object is read whole first: a destination meant for untrusted objects implements MaxGetter).
func GetMax(ctx context.Context, d Getter, key string, max int64) ([]byte, error) {
	if g, ok := d.(MaxGetter); ok {
		return g.GetMax(ctx, key, max)
	}
	b, err := d.Get(ctx, key)
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > max {
		return nil, tooBig(key, max, int64(len(b)), true)
	}
	return b, nil
}

// tooBig: the error for key past max; size is exact, or (exact false) a lower bound - what was read before the stop
func tooBig(key string, max, size int64, exact bool) error {
	if exact {
		return fmt.Errorf("%s: %d bytes, %w of %d bytes", key, size, ErrTooBig, max)
	}
	return fmt.Errorf("%s: more than %d bytes, %w of %d bytes", key, max, ErrTooBig, max)
}

// rangeTotal: the object's whole size from a Content-Range answer ('bytes 0-10/4096'); false when it names none
func rangeTotal(contentRange string) (int64, bool) {
	_, total, ok := strings.Cut(contentRange, "/")
	if !ok || total == "*" {
		return 0, false
	}
	n, err := strconv.ParseInt(strings.TrimSpace(total), 10, 64)
	return n, err == nil
}
