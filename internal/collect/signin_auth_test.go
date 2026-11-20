package collect

import (
	"errors"
	"fmt"
	"testing"
)

type signInStub struct{}

func (signInStub) Error() string       { return "the az sign-in of x gave no token" }
func (signInStub) SignInFailure() bool { return true }

// TestSignInIsAnAuthFailure: a sign-in that gave no token (mssqlopen.SignInError's mark), wrapped or not, is the
// login's failure, never the server unreachable.
func TestSignInIsAnAuthFailure(t *testing.T) {
	if !AuthFailure(signInStub{}) || !AuthFailure(fmt.Errorf("connect sql1: %w", signInStub{})) {
		t.Error("a sign-in failure is not counted as an auth failure")
	}
	if AuthFailure(errors.New("dial tcp: i/o timeout")) {
		t.Error("a network error counted as an auth failure")
	}
}
