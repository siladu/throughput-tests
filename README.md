## Powershell setup

```
# set for user
[Environment]::SetEnvironmentVariable('IMAGE_REGISTRY', '<docker registry url', 'User')
# set for current terminal
$env:IMAGE_REGISTRY = '<docker registry url>'
# Put the spamoor key outside the repo so it can never be committed
Set-Content -Path "$HOME\spamoor-privkey.txt" -Value "<your-key>"
```

## Run

```
.\scripts\Run-SpamoorTests.ps1
```
