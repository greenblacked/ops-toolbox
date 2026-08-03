package sample

import "testing"

func TestGreet(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name, in, want string
	}{
		{"default", "", "hello, world"},
		{"named", "docker", "hello, docker"},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			if got := Greet(tc.in); got != tc.want {
				t.Fatalf("Greet(%q) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}

func TestVersion(t *testing.T) {
	t.Parallel()
	if Version != "0.1.0" {
		t.Fatalf("Version = %q, want %q", Version, "0.1.0")
	}
}
