// main.go — Entry point for terraform-provider-aurora-bluegreen
//
// Build:
//   go build -o terraform-provider-aurora-bluegreen .
//
// Install for local testing (macOS arm64):
//   make install-darwin-arm64
//
// Install for local testing (linux amd64):
//   make install-linux-amd64
//
// Usage in Terraform:
//   terraform {
//     required_providers {
//       aurora-bluegreen = {
//         source  = "local/aurora-bluegreen"
//         version = "~> 1.0"
//       }
//     }
//   }

package main

import (
	"context"
	"flag"
	"log"

	"github.com/hashicorp/terraform-plugin-framework/providerserver"
	"github.com/modmed/terraform-provider-aurora-bluegreen/internal/provider"
)

// version is set at build time via -ldflags "-X main.version=x.y.z"
var version string = "1.0.0"

func main() {
	var debug bool
	flag.BoolVar(&debug, "debug", false, "enable debug mode for provider development")
	flag.Parse()

	opts := providerserver.ServeOpts{
		Address: "registry.terraform.io/local/aurora-bluegreen",
		Debug:   debug,
	}

	err := providerserver.Serve(context.Background(), provider.New(version), opts)
	if err != nil {
		log.Fatal(err.Error())
	}
}
