// Binary hello prints the sample greeting. Lets `go build ./...` exercise the
// command path as well as the library.
package main

import (
	"fmt"
	"os"

	"github.com/pretty-useful-scripts/test-env/go/internal/sample"
)

func main() {
	name := ""
	if len(os.Args) > 1 {
		name = os.Args[1]
	}
	fmt.Println(sample.Greet(name))
}
