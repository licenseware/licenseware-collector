# Retired: kept at this URL so that running it fails loudly instead of installing an outdated build.
Write-Error -ErrorAction Continue -Message (@(
        'licenseware-collector: this installer script is retired and installs nothing.'
        'Download LicensewareCollector.msi from https://licenseware-collector.com/#downloads'
        'and follow https://licenseware-collector.com/#installation:'
        '  msiexec /i LicensewareCollector.msi TOKEN=<enrollment-token>'
    ) -join [Environment]::NewLine)
exit 1
