# Retired: kept at this URL so that running it fails loudly instead of installing an outdated build.
Write-Error -ErrorAction Continue -Message (@(
        'licenseware-collector: this script is retired and installs nothing.'
        'Download LicensewareCollector.msi from https://licenseware-collector.com/#downloads'
        'and run it from a Command Prompt as administrator:'
        '  msiexec /i LicensewareCollector.msi TOKEN=<enrolment-token>'
        'Guides: https://licenseware-collector.com/#single-machine and https://licenseware-collector.com/#intune'
    ) -join [Environment]::NewLine)
exit 1
