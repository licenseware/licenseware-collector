build-windows-installer:
  #!/bin/bash

  set -e

  GOOS=windows GOARCH=amd64 \
    go build \
    -trimpath \
    -ldflags "-s -w -extldflags '-static' -X main.Version=$(git describe --tags --always --dirty)" \
    -o ./public/install.exe .
  echo "Windows installer built at public/install.exe"
