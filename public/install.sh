#!/bin/sh
# Retired: kept at this URL so that `curl ... | sh` fails loudly instead of installing an outdated build.
printf '%s\n' \
  'licenseware-collector: this installer script is retired and installs nothing.' \
  'Download the package for your OS (deb, rpm, pkg or msi) from' \
  '  https://licenseware-collector.com/#downloads' \
  'and follow https://licenseware-collector.com/#installation, for example on Debian/Ubuntu:' \
  '  sudo apt install ./licenseware-collector_amd64.deb' \
  '  sudo TOKEN=<enrollment-token> licenseware-collector register' >&2
exit 1
