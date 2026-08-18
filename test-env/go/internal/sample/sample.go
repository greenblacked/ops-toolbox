// Package sample is the minimal package used to validate the Go test-env wiring.
package sample

import "fmt"

const Version = "0.1.0"

// Greet returns a greeting for name (defaults to "world" when empty).
func Greet(name string) string {
	if name == "" {
		name = "world"
	}
	return fmt.Sprintf("hello, %s", name)
}
