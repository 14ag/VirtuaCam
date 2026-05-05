param(
    [Parameter(Mandatory=$true)][string]$Root,
    [int]$Port = 8000
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Web

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        try {
            $reqPath = [System.Web.HttpUtility]::UrlDecode($ctx.Request.Url.AbsolutePath.TrimStart('/'))
            if ([string]::IsNullOrWhiteSpace($reqPath)) {
                $reqPath = 'webcam.html'
            }

            $filePath = Join-Path $Root $reqPath
            if ((Test-Path -LiteralPath $filePath) -and -not (Get-Item -LiteralPath $filePath).PSIsContainer) {
                $ext = [System.IO.Path]::GetExtension($filePath).ToLowerInvariant()
                $contentType = switch ($ext) {
                    '.html' { 'text/html; charset=utf-8' }
                    '.js'   { 'application/javascript; charset=utf-8' }
                    '.css'  { 'text/css; charset=utf-8' }
                    '.json' { 'application/json; charset=utf-8' }
                    '.png'  { 'image/png' }
                    '.jpg'  { 'image/jpeg' }
                    '.jpeg' { 'image/jpeg' }
                    default { 'application/octet-stream' }
                }

                $bytes = [System.IO.File]::ReadAllBytes($filePath)
                $ctx.Response.StatusCode = 200
                $ctx.Response.ContentType = $contentType
                $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            else {
                $ctx.Response.StatusCode = 404
            }
        }
        finally {
            $ctx.Response.OutputStream.Close()
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
}
