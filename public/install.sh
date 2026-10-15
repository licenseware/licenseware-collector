#!/bin/sh
# Retired: kept at this URL so that `curl ... | sh` fails loudly instead of installing an outdated build.
printf '%s\n' \
  'licenseware-collector: this script has moved and installs nothing.' \
  'Install with the script on the CDN instead:' \
  '  curl -fsSL https://cdn.licenseware-collector.com/install.sh | sudo TOKEN=<enrolment-token> sh' \
  'Guide: https://licenseware-collector.com/#single-machine' >&2
exit 1
