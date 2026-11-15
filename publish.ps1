# Publica o projeto de build do kernel no GitHub Actions.
# Uso:
#   .\publish.ps1 -Token "github_pat_xxx" -SourceZip "..\downloads\kernel\SM-A525F_CIS_14_Opensource.zip"
#   .\publish.ps1 -Token "..." -SourceZip "..." -Name "a52q-kernel"
param(
    [Parameter(Mandatory = $true)][string]$Token,
    [Parameter(Mandatory = $true)][string]$SourceZip,
    [string]$Name = "a52q-kernel",
    [switch]$Private,
    [ValidateSet("stock", "defconfig")][string]$Base = "stock",
    [ValidateSet("true", "false")][string]$Docker = "true"
)

$ErrorActionPreference = "Stop"
$api = "https://api.github.com"
$hdr = @{
    Authorization          = "Bearer $Token"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
    "User-Agent"           = "a52-server"
}

function Invoke-GH([string]$Method, [string]$Url, $Body) {
    $p = @{ Method = $Method; Uri = $Url; Headers = $hdr }
    if ($Body -ne $null) {
        $p.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 }
        $p.ContentType = "application/json"
    }
    return Invoke-RestMethod @p
}

if (-not (Test-Path $SourceZip)) { throw "Arquivo nao encontrado: $SourceZip" }
$zipItem = Get-Item $SourceZip
Write-Host ("[1/6] Kernel source: {0} ({1:N0} MB)" -f $zipItem.Name, ($zipItem.Length / 1MB))

$me = Invoke-GH GET "$api/user"
$owner = $me.login
Write-Host "[2/6] Autenticado como $owner"

# --- repo ---
$exists = $true
try { Invoke-GH GET "$api/repos/$owner/$Name" | Out-Null } catch { $exists = $false }
if (-not $exists) {
    $vis = if ($Private) { $true } else { $false }
    Invoke-GH POST "$api/user/repos" @{ name = $Name; private = $vis; auto_init = $true; description = "Kernel A52 (a52q) com Docker nativo" } | Out-Null
    Write-Host "[3/6] Repositorio $owner/$Name criado (privado=$vis)"
    Start-Sleep -Seconds 3
} else {
    Write-Host "[3/6] Repositorio $owner/$Name ja existe"
}

# --- arquivos do workflow ---
$root = $PSScriptRoot
$files = @(
    @{ path = ".github/workflows/build.yml"; file = "$root\.github\workflows\build.yml" },
    @{ path = "configs/docker.fragment";     file = "$root\configs\docker.fragment" },
    @{ path = "configs/stock.config";        file = "$root\configs\stock.config" },
    @{ path = "docs/APRENDIZADOS.md";        file = "$root\docs\APRENDIZADOS.md" },
    @{ path = "README.md";                   file = "$root\README.md" }
)
foreach ($f in $files) {
    if (-not (Test-Path $f.file)) { Write-Warning "faltando: $($f.file)"; continue }
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($f.file))
    $body = @{ message = "add $($f.path)"; content = $b64 }
    $existing = $null
    try { $existing = Invoke-GH GET "$api/repos/$owner/$Name/contents/$($f.path)" } catch { }
    if ($existing) { $body.sha = $existing.sha; $body.message = "update $($f.path)" }
    Invoke-GH PUT "$api/repos/$owner/$Name/contents/$($f.path)" $body | Out-Null
    Write-Host "      + $($f.path)"
}
Write-Host "[4/6] Arquivos publicados"

# --- release com o source ---
$rel = $null
try { $rel = Invoke-GH GET "$api/repos/$owner/$Name/releases/tags/kernel-src" }
catch {
    $rel = Invoke-GH POST "$api/repos/$owner/$Name/releases" @{
        tag_name = "kernel-src"; name = "kernel-src"
        body = "Kernel source (asset binario, fora do git)"
    }
}
$existingAsset = $rel.assets | Where-Object { $_.name -eq $zipItem.Name }
if ($existingAsset) {
    Write-Host "[5/6] Asset ja existe, pulando upload"
} else {
    Write-Host ("[5/6] Enviando asset ({0:N0} MB)... pode demorar" -f ($zipItem.Length / 1MB))
    $upHdr = $hdr.Clone()
    $upHdr["Content-Type"] = "application/octet-stream"
    $url = "https://uploads.github.com/repos/$owner/$Name/releases/$($rel.id)/assets?name=$([uri]::EscapeDataString($zipItem.Name))"
    Invoke-RestMethod -Method POST -Uri $url -Headers $upHdr -InFile $zipItem.FullName -TimeoutSec 1800 | Out-Null
    Write-Host "      asset enviado"
}

# --- dispara o build ---
try {
    Invoke-GH POST "$api/repos/$owner/$Name/actions/workflows/build.yml/dispatches" @{
        ref    = "main"
        inputs = @{ base = $Base; docker = $Docker }
    } | Out-Null
    Write-Host "[6/6] Build disparado! (base=$Base docker=$Docker)"
} catch {
    Write-Warning "[6/6] Nao consegui disparar automaticamente: $($_.Exception.Message)"
    Write-Host "      Abra: https://github.com/$owner/$Name/actions e clique em Run workflow"
}

Write-Host ""
Write-Host "Acompanhe em: https://github.com/$owner/$Name/actions"
Write-Host "Quando terminar, baixe o artifact 'kernel-a52q-docker' (contem Image)."
