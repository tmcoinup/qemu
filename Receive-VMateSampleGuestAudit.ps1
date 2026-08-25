param(
    [string]$OutputDirectory = 'C:\VMateLab\SampleGuestAudit',
    [ValidateRange(1024, 65535)]
    [int]$Port = 8765
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add("http://+:$Port/")
$listener.Start()
try {
    while ($true) {
        $context = $listener.GetContext()
        $name = $context.Request.Url.AbsolutePath.Trim('/').ToLowerInvariant()
        if ($name -eq 'stop') {
            $context.Response.StatusCode = 200
            $context.Response.Close()
            break
        }
        if ($context.Request.HttpMethod -cne 'POST' -or $name -notmatch '^pc0[12]$') {
            $context.Response.StatusCode = 404
            $context.Response.Close()
            continue
        }
        $reader = [IO.StreamReader]::new($context.Request.InputStream,
            [Text.Encoding]::UTF8, $true)
        try {
            $body = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
        $null = $body | ConvertFrom-Json
        $target = Join-Path $OutputDirectory ($name + '.json')
        [IO.File]::WriteAllText($target, $body, [Text.UTF8Encoding]::new($false))
        $context.Response.StatusCode = 200
        $context.Response.Close()
    }
}
finally {
    $listener.Stop()
    $listener.Close()
}
