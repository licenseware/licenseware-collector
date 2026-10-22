#!/bin/sh
# Retired: kept at this URL so that `curl ... | sh` fails loudly instead of installing an outdated build.
printf '%s\n' \
  'licenseware-collector: this installer script is retired and installs nothing.' \
  'Use the current installer instead (Linux and macOS):' \
  '  curl -fsSL https://cdn.licenseware-collector.com/install.sh | sudo TOKEN=<enrolment-token> sh' \
  'or follow https://licenseware-collector.com/#installation' >&2
exit 1
