package auth

import (
	"strings"
	"testing"
)

func TestHashRoundTrip(t *testing.T) {
	h, err := Hash("correct horse battery")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(h, "$argon2id$v=19$m=19456,t=2,p=1$") {
		t.Fatalf("unexpected PHC prefix: %s", h)
	}
	ok, err := Verify(h, "correct horse battery")
	if err != nil || !ok {
		t.Fatalf("the right password: ok=%v err=%v", ok, err)
	}
	ok, err = Verify(h, "correct horse batterx")
	if err != nil || ok {
		t.Fatalf("a wrong password: ok=%v err=%v", ok, err)
	}
	h2, _ := Hash("correct horse battery")
	if h2 == h {
		t.Fatal("two hashes of one password share a salt")
	}
	if ok, err := Verify(Dummy(), "anything at all"); err != nil || ok {
		t.Fatalf("the dummy hash verified: ok=%v err=%v", ok, err)
	}
}

func TestPasswordRule(t *testing.T) {
	for _, bad := range []string{"", "short", "elevenchars", " twelve chars", "twelve chars "} {
		if _, err := Hash(bad); err == nil {
			t.Errorf("%q was accepted", bad)
		}
	}
	if _, err := Hash("twelve chars"); err != nil {
		t.Errorf("a 12-character password refused: %v", err)
	}
}

func TestVerifyRejectsMalformed(t *testing.T) {
	for _, s := range []string{"", "plain", "$argon2i$v=19$m=19456,t=2,p=1$c2FsdA$aGFzaA", "$argon2id$v=19$m=19456,t=2,p=1$c2FsdA",
		"$argon2id$v=19$m=99999999,t=2,p=1$c2FsdA$aGFzaA", "$argon2id$v=19$m=19456,t=2,p=300$c2FsdA$aGFzaA", "$argon2id$v=19$m=19456,t=2,p=1$!!$aGFzaA"} {
		if ok, err := Verify(s, "x"); err == nil || ok {
			t.Errorf("%q: ok=%v err=%v, want an error", s, ok, err)
		}
	}
}
