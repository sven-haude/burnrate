#Requires -Version 5.1
<#
  burnrate for Windows - a small always-on-top widget showing Claude Code and Codex usage.
  Windows PowerShell 5.1 + WPF, nothing to install. Start it via start.cmd / start.ps1.
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Root = Split-Path -Parent $PSScriptRoot
$StateDir = Join-Path $env:APPDATA 'burnrate'
$StatePath = Join-Path $StateDir 'state.json'
$LogPath = Join-Path $StateDir 'burnrate.log'

# --- Sprache: Deutsch bei deutscher Systemsprache, sonst Englisch

$German = (Get-UICulture).TwoLetterISOLanguageName -eq 'de'
$Culture = [Globalization.CultureInfo]::GetCultureInfo($(if ($German) { 'de-DE' } else { 'en-US' }))
function T([string]$de, [string]$en) { if ($German) { $de } else { $en } }

function Write-Log([string]$message) {
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    Add-Content -LiteralPath $LogPath -Value "$(Get-Date -Format s) $message" -Encoding UTF8
}

function Fail([string]$message) {
    Write-Log $message
    [System.Windows.MessageBox]::Show($message, 'burnrate', 'OK', 'Error') | Out-Null
    exit 1
}

# --- Nur eine Instanz

$Mutex = New-Object System.Threading.Mutex($false, 'Local\burnrate')
try { $owned = $Mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { exit 0 }

# --- Konfiguration (config.env, gemeinsam mit macOS)

$ConfigPath = Join-Path $Root 'config.env'
if (-not (Test-Path -LiteralPath $ConfigPath)) { Fail "config.env missing: $ConfigPath" }
$Config = @{}
foreach ($line in [IO.File]::ReadAllLines($ConfigPath)) {
    $text = $line.Trim()
    if ($text -eq '' -or $text.StartsWith('#')) { continue }
    $i = $text.IndexOf('=')
    if ($i -lt 1) { continue }
    $Config[$text.Substring(0, $i).Trim()] = $text.Substring($i + 1).Trim().Trim('"').Replace('$HOME', $env:USERPROFILE)
}
function Need([string]$key) {
    $value = $Config[$key]
    if ([string]::IsNullOrWhiteSpace($value)) { Fail "$key missing in config.env" }
    $value
}
$RefreshSeconds = [double](Need 'CLAUDE_USAGE_REFRESH_SECONDS')
$BurnMinutes = [double](Need 'CLAUDE_USAGE_BURN_MINUTES')
if ($RefreshSeconds -lt 30) { Fail 'CLAUDE_USAGE_REFRESH_SECONDS must be >= 30' }
if ($BurnMinutes -lt 5) { Fail 'CLAUDE_USAGE_BURN_MINUTES must be >= 5' }

# --- Daten vom Server

$Hour = 3600.0
$Week = 7 * 24 * $Hour

function New-Limit($title, $percent, $severity, $resetsAt, $window) {
    if (-not $severity) { $severity = 'normal' }
    [pscustomobject]@{ Title = $title; Percent = [double]$percent; Severity = $severity; ResetsAt = $resetsAt; Window = $window }
}

function ConvertTo-UtcDate($value) {
    if ($null -eq $value -or $value -eq '') { return $null }
    if ($value -is [DateTime]) { return $value.ToUniversalTime() }
    [DateTimeOffset]::Parse([string]$value, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
}

function Invoke-Api([string]$url, [hashtable]$headers, [string]$tokenHint) {
    try {
        Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 20 -UseBasicParsing
    } catch {
        $status = 0
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        if ($status -eq 401 -or $status -eq 403) { throw "HTTP $status - $tokenHint" }
        if ($status -eq 429) { throw (T 'Rate-Limit (429) – später erneut' 'Rate limited (429) – retrying later') }
        if ($status -gt 0) { throw "HTTP $status" }
        throw ((T 'Netzwerk: ' 'Network: ') + $_.Exception.Message)
    }
}

# Claude: OAuth-Token aus ~/.claude/.credentials.json (von Claude Code gepflegt)
function Get-ClaudeData {
    $path = Need 'CLAUDE_CREDENTIALS_FILE'
    if (-not (Test-Path -LiteralPath $path)) { throw ((T 'Kein Claude-Login gefunden: ' 'No Claude login found: ') + $path) }
    $oauth = ([IO.File]::ReadAllText($path) | ConvertFrom-Json).claudeAiOauth
    if (-not $oauth -or -not $oauth.accessToken) { throw (T 'Claude-Login hat unerwartetes Format' 'Unexpected Claude login format') }
    if ($oauth.expiresAt -and [DateTimeOffset]::FromUnixTimeMilliseconds([long]$oauth.expiresAt).UtcDateTime -lt [DateTime]::UtcNow) {
        throw (T 'Token abgelaufen – Claude Code kurz starten' 'Token expired – open Claude Code briefly')
    }
    $headers = @{ 'Authorization' = "Bearer $($oauth.accessToken)"; 'anthropic-beta' = (Need 'CLAUDE_USAGE_BETA_HEADER') }
    $json = Invoke-Api (Need 'CLAUDE_USAGE_URL') $headers (T 'Claude Code kurz starten' 'open Claude Code briefly')
    if ($null -eq $json.limits) { throw (T 'Antwort ohne „limits“ – API geändert?' 'Response without "limits" – API changed?') }

    $limits = foreach ($l in $json.limits) {
        switch ($l.kind) {
            'session' { $title = T 'Aktuelle Session' 'Current session'; $window = 5 * $Hour }
            'weekly_all' { $title = T 'Aktuelle Woche · alle Modelle' 'Current week · all models'; $window = $Week }
            'weekly_scoped' {
                $name = $l.scope.model.display_name
                if (-not $name) { $name = $l.scope.surface.display_name }
                if (-not $name) { $name = T 'eingeschränkt' 'scoped' }
                $title = (T 'Aktuelle Woche · ' 'Current week · ') + $name
                $window = $Week
            }
            default { $title = [string]$l.kind; $window = $null }
        }
        New-Limit $title $l.percent $l.severity (ConvertTo-UtcDate $l.resets_at) $window
    }
    @{ Limits = @($limits); Plan = $oauth.subscriptionType }
}

# Codex: ChatGPT-Token aus ~/.codex/auth.json (von der Codex CLI gepflegt)
function Get-CodexWindows($rateLimit, [string]$prefix) {
    if ($null -eq $rateLimit) { return }
    foreach ($key in 'primary_window', 'secondary_window') {
        $w = $rateLimit.$key
        if ($null -eq $w) { continue }
        $seconds = [double]$w.limit_window_seconds
        $hours = [int][Math]::Floor($seconds / $Hour)
        if ($hours -eq 168) { $span = T 'Aktuelle Woche' 'Current week' }
        elseif ($hours -lt 24) { $span = (T 'Aktuelle Session' 'Current session') + " ($hours h)" }
        else { $span = "$([Math]::Floor($hours / 24)) " + (T 'Tage' 'days') }
        $title = if ($prefix) { "$span · $prefix" } else { $span }
        $reset = $null
        if ($w.reset_at) { $reset = [DateTimeOffset]::FromUnixTimeSeconds([long]$w.reset_at).UtcDateTime }
        $severity = if ($rateLimit.limit_reached) { 'limit_reached' } else { 'normal' }
        New-Limit $title $w.used_percent $severity $reset $seconds
    }
}

function Get-CodexData {
    $path = Need 'CODEX_AUTH_FILE'
    if (-not (Test-Path -LiteralPath $path)) { throw ($path + (T ' fehlt – in Codex eingeloggt?' ' missing – logged in to Codex?')) }
    $tokens = ([IO.File]::ReadAllText($path) | ConvertFrom-Json).tokens
    if (-not $tokens -or -not $tokens.access_token) { throw (T 'auth.json ohne ChatGPT-Login (API-Key-Modus?)' 'auth.json without ChatGPT login (API key mode?)') }
    $headers = @{ 'Authorization' = "Bearer $($tokens.access_token)" }
    if ($tokens.account_id) { $headers['ChatGPT-Account-Id'] = $tokens.account_id }
    $json = Invoke-Api (Need 'CODEX_USAGE_URL') $headers (T 'Codex kurz starten' 'open Codex briefly')
    if (-not ($json.PSObject.Properties.Name -contains 'rate_limit')) {
        throw (T 'Antwort ohne „rate_limit“ – API geändert?' 'Response without "rate_limit" – API changed?')
    }
    $limits = @(Get-CodexWindows $json.rate_limit '') + @(Get-CodexWindows $json.code_review_rate_limit 'Code Review')
    @{ Limits = $limits; Plan = $json.plan_type }
}

# --- Tempo & Prognose (lineare Hochrechnung über das ganze Fenster)

function Get-Pace($limit) {
    if (-not $limit.Window -or -not $limit.ResetsAt -or $limit.Percent -le 0) { return $null }
    $elapsed = $limit.Window - ($limit.ResetsAt - [DateTime]::UtcNow).TotalSeconds
    if ($elapsed -le $limit.Window * 0.03) { return $null }  # zu früh im Fenster für eine Aussage
    $perHour = $limit.Percent / ($elapsed / $Hour)
    $projected = $limit.Percent * $limit.Window / $elapsed
    $untilFull = $null
    if ($projected -ge 100) { $untilFull = (100 - $limit.Percent) / $perHour * $Hour }
    [pscustomobject]@{ PerHour = $perHour; Projected = $projected; UntilFull = $untilFull }
}

# --- Burn Rate aus den lokalen Logs (nur Dateien, die im Burn-Zeitraum geschrieben wurden)

function Get-Num([string]$text, [string]$key) {
    $m = [regex]::Match($text, '"' + $key + '":(\d+)')
    if ($m.Success) { [long]$m.Groups[1].Value } else { 0L }
}

function Get-BurnRate([string]$format, [string]$dir) {
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    $since = [DateTime]::UtcNow.AddMinutes(-$BurnMinutes)
    $events = @{}
    $files = Get-ChildItem -LiteralPath $dir -Recurse -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -ge $since }
    foreach ($file in $files) {
        foreach ($line in [IO.File]::ReadLines($file.FullName)) {
            if ($format -eq 'claude') {
                # Nur die nötigen Felder per Regex holen, die Zeilen können über 1 MB groß sein
                if (-not $line.Contains('"type":"assistant"')) { continue }
                $u = $line.LastIndexOf('"usage":{')
                $id = [regex]::Match($line, '"id":"(msg_[^"]+)"')
                $ts = [regex]::Match($line, '"timestamp":"([^"]+)"', 'RightToLeft')
                if ($u -lt 0 -or -not $id.Success -or -not $ts.Success) { continue }
                if ((ConvertTo-UtcDate $ts.Groups[1].Value) -lt $since) { continue }
                $usage = $line.Substring($u)
                $request = [regex]::Match($line, '"requestId":"([^"]+)"', 'RightToLeft').Groups[1].Value
                $output = Get-Num $usage 'output_tokens'
                $tokens = (Get-Num $usage 'input_tokens') + $output + (Get-Num $usage 'cache_creation_input_tokens')
                # Claude Code schreibt pro Content-Block eine Zeile mit derselben Message-ID -> letzte gewinnt
                $events["$($id.Groups[1].Value):$request"] = @($tokens, $output)
            } else {
                if (-not $line.Contains('"type":"token_count"')) { continue }
                $l = $line.IndexOf('"last_token_usage":{')
                $t = $line.IndexOf('"total_token_usage":{')
                $ts = [regex]::Match($line, '"timestamp":"([^"]+)"')
                if ($l -lt 0 -or $t -lt 0 -or -not $ts.Success) { continue }
                if ((ConvertTo-UtcDate $ts.Groups[1].Value) -lt $since) { continue }
                $last = $line.Substring($l, $line.IndexOf('}', $l) - $l)
                $total = $line.Substring($t, $line.IndexOf('}', $t) - $t)
                $output = Get-Num $last 'output_tokens'
                $tokens = (Get-Num $last 'input_tokens') - (Get-Num $last 'cached_input_tokens') + $output + (Get-Num $last 'cache_write_input_tokens')
                # Codex wiederholt token_count-Events mit identischer Gesamtsumme -> darüber deduplizieren
                $events["$($file.FullName):$(Get-Num $total 'total_tokens')"] = @($tokens, $output)
            }
        }
    }
    $sum = 0L
    $out = 0L
    foreach ($e in $events.Values) { $sum += $e[0]; $out += $e[1] }
    [pscustomobject]@{ PerMinute = $sum / $BurnMinutes; OutputPerMinute = $out / $BurnMinutes }
}

# --- Formatierung

function Format-Number([double]$value, [int]$digits) { $value.ToString("N$digits", $Culture) }

function Format-Tokens([double]$n) {
    if ($n -ge 1000000) { return (Format-Number ($n / 1000000) 1) + (T ' Mio' ' M') }
    if ($n -ge 10000) { return (Format-Number ($n / 1000) 0) + ' k' }
    if ($n -ge 1000) { return (Format-Number ($n / 1000) 1) + ' k' }
    Format-Number $n 0
}

function Format-Duration([double]$seconds) {
    $minutes = [Math]::Max(0, [int][Math]::Floor($seconds / 60))
    $days = [Math]::Floor($minutes / 1440)
    $hours = [Math]::Floor(($minutes % 1440) / 60)
    $mins = $minutes % 60
    if ($days -gt 0) { return "$days $(T 'T' 'd') $hours h" }
    if ($hours -gt 0) { return "$hours h $mins min" }
    "$mins min"
}

function Format-Reset($date) {
    if (-not $date) { return '' }
    $remaining = ($date - [DateTime]::UtcNow).TotalSeconds
    if ($remaining -le 0) { return (T 'Reset fällig' 'Reset due') }
    if ($remaining -lt 24 * $Hour) { return 'Reset in ' + (Format-Duration $remaining) }
    'Reset ' + $date.ToLocalTime().ToString($(if ($German) { 'ddd, HH:mm' } else { 'ddd HH:mm' }), $Culture)
}

# --- UI-Bausteine

$BrushConverter = New-Object System.Windows.Media.BrushConverter
function Brush([string]$hex) { $BrushConverter.ConvertFromString($hex) }
$Colors = @{
    Text       = Brush '#FFFFFFFF'
    Secondary  = Brush '#B3FFFFFF'
    Tertiary   = Brush '#73FFFFFF'
    Track      = Brush '#26FFFFFF'
    Green      = Brush '#FF30D158'
    Orange     = Brush '#FFFF9F0A'
    Red        = Brush '#FFFF453A'
    Background = Brush '#E61E1E20'
}

function Get-LimitBrush([double]$percent, [string]$severity) {
    if ($severity -ne 'normal' -or $percent -ge 90) { return $Colors.Red }
    if ($percent -ge 70) { return $Colors.Orange }
    $Colors.Green
}

function New-Text([string]$text, [double]$size, $brush, [System.Windows.FontWeight]$weight = [System.Windows.FontWeights]::Normal) {
    $block = New-Object System.Windows.Controls.TextBlock
    $block.Text = $text
    $block.FontSize = $size
    $block.Foreground = $brush
    $block.FontWeight = $weight
    $block.TextTrimming = 'CharacterEllipsis'
    $block
}

# Zeile mit Text links und Text rechts
function New-Row($left, $right) {
    $dock = New-Object System.Windows.Controls.DockPanel
    [System.Windows.Controls.DockPanel]::SetDock($right, [System.Windows.Controls.Dock]::Right)
    $right.Margin = New-Object System.Windows.Thickness(6, 0, 0, 0)
    [void]$dock.Children.Add($right)
    [void]$dock.Children.Add($left)
    $dock
}

# Balken: Verbrauch, heller die Prognose bis zum Reset
function New-Bar([double]$percent, [double]$projected, $brush) {
    $grid = New-Object System.Windows.Controls.Grid
    $grid.Height = 6
    $actual = [Math]::Min(100, [Math]::Max(0, $percent))
    $ghost = [Math]::Max(0, [Math]::Min(100, $projected) - $actual)
    foreach ($width in $actual, $ghost, [Math]::Max(0, 100 - $actual - $ghost)) {
        $column = New-Object System.Windows.Controls.ColumnDefinition
        $column.Width = New-Object System.Windows.GridLength($width, [System.Windows.GridUnitType]::Star)
        [void]$grid.ColumnDefinitions.Add($column)
    }
    $track = New-Object System.Windows.Controls.Border
    $track.CornerRadius = New-Object System.Windows.CornerRadius(3)
    $track.Background = $Colors.Track
    [System.Windows.Controls.Grid]::SetColumnSpan($track, 3)
    [void]$grid.Children.Add($track)

    $ghostBrush = $brush.Clone()
    $ghostBrush.Opacity = 0.3
    $ghostBar = New-Object System.Windows.Controls.Border
    $ghostBar.CornerRadius = New-Object System.Windows.CornerRadius(0, 3, 3, 0)
    $ghostBar.Background = $ghostBrush
    [System.Windows.Controls.Grid]::SetColumn($ghostBar, 1)
    [void]$grid.Children.Add($ghostBar)

    $fill = New-Object System.Windows.Controls.Border
    $fill.CornerRadius = New-Object System.Windows.CornerRadius(3)
    $fill.Background = $brush
    [void]$grid.Children.Add($fill)
    $grid
}

# --- Fenster

$Window = New-Object System.Windows.Window
$Window.WindowStyle = 'None'
$Window.AllowsTransparency = $true
$Window.Background = [System.Windows.Media.Brushes]::Transparent
$Window.Topmost = $true
$Window.ShowInTaskbar = $false
$Window.ResizeMode = 'NoResize'
$Window.SizeToContent = 'Height'
$Window.Width = 270
$Window.WindowStartupLocation = 'Manual'
$Window.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI')

$Border = New-Object System.Windows.Controls.Border
$Border.CornerRadius = New-Object System.Windows.CornerRadius(12)
$Border.Padding = New-Object System.Windows.Thickness(14)
$Border.Background = $Colors.Background
$Stack = New-Object System.Windows.Controls.StackPanel
$Border.Child = $Stack
$Window.Content = $Border

function Add-Child($element, [double]$spacingAfter) {
    $element.Margin = New-Object System.Windows.Thickness(0, 0, 0, $spacingAfter)
    [void]$Stack.Children.Add($element)
}

function Save-Position {
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    @{ Left = $Window.Left; Top = $Window.Top } | ConvertTo-Json | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

function Move-ToCorner {
    $area = [System.Windows.SystemParameters]::WorkArea
    $Window.Left = $area.Left + 10
    $Window.Top = $area.Top + 10
    Save-Position
}

# Zuletzt gespeicherte Position, sofern sie noch auf einem Bildschirm liegt
function Restore-Position {
    if (Test-Path -LiteralPath $StatePath) {
        try {
            $saved = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
            $left = [double]$saved.Left
            $top = [double]$saved.Top
            $screenLeft = [System.Windows.SystemParameters]::VirtualScreenLeft
            $screenTop = [System.Windows.SystemParameters]::VirtualScreenTop
            $onScreen = $left -ge $screenLeft -and $left -lt $screenLeft + [System.Windows.SystemParameters]::VirtualScreenWidth - 40 -and
                $top -ge $screenTop -and $top -lt $screenTop + [System.Windows.SystemParameters]::VirtualScreenHeight - 40
            if ($onScreen) {
                $Window.Left = $left
                $Window.Top = $top
                return
            }
        } catch {
            Write-Log "Position not restored: $($_.Exception.Message)"
        }
    }
    Move-ToCorner
}

# Ziehen zum Verschieben, Position merken
$Window.Add_MouseLeftButtonDown({
    try { $Window.DragMove(); Save-Position } catch { }
})

$Menu = New-Object System.Windows.Controls.ContextMenu
function Add-MenuItem([string]$header, [scriptblock]$action) {
    $item = New-Object System.Windows.Controls.MenuItem
    $item.Header = $header
    $item.Add_Click($action)
    [void]$Menu.Items.Add($item)
}
Add-MenuItem (T 'Jetzt aktualisieren' 'Refresh now') { Update-All }
Add-MenuItem (T 'Nach oben links' 'Move to top left') { Move-ToCorner }
[void]$Menu.Items.Add((New-Object System.Windows.Controls.Separator))
Add-MenuItem (T 'Beenden' 'Quit') { $Window.Close() }
$Border.ContextMenu = $Menu

# --- Zustand & Darstellung

$State = @{
    claude = @{ Name = 'Claude'; Plan = $null; Limits = @(); Error = $null; Burn = $null; Installed = $false }
    codex  = @{ Name = 'Codex'; Plan = $null; Limits = @(); Error = $null; Burn = $null; Installed = $false }
}
$script:UpdatedAt = $null

function Render-Section($section) {
    $heading = (@($section.Name, $section.Plan) | Where-Object { $_ }) -join ' · '
    $title = New-Text $heading.ToUpper() 11 $Colors.Secondary ([System.Windows.FontWeights]::Bold)
    if ($section.Burn) {
        $brush = if ($section.Burn.PerMinute -gt 0) { $Colors.Text } else { $Colors.Tertiary }
        $burn = New-Text ([char]::ConvertFromUtf32(0x1F525) + ' ' + (Format-Tokens $section.Burn.PerMinute) + '/min') 11 $brush ([System.Windows.FontWeights]::Bold)
        $burn.ToolTip = (T 'Tokens pro Minute (ohne Cache-Reads), letzte ' 'Tokens per minute (excluding cache reads), last ') + "$BurnMinutes min"
        Add-Child (New-Row $title $burn) 6
    } else {
        Add-Child $title 6
    }

    foreach ($limit in $section.Limits) {
        $brush = Get-LimitBrush $limit.Percent $limit.Severity
        $name = New-Text $limit.Title 13 $Colors.Text ([System.Windows.FontWeights]::SemiBold)
        $percent = New-Text ('{0} %' -f [Math]::Round($limit.Percent)) 13 $brush ([System.Windows.FontWeights]::Bold)
        Add-Child (New-Row $name $percent) 3

        $pace = Get-Pace $limit
        $projected = if ($pace) { $pace.Projected } else { 0 }
        Add-Child (New-Bar $limit.Percent $projected $brush) 3

        $paceText = ''
        $paceBrush = $Colors.Secondary
        if ($pace -and $pace.UntilFull -and $limit.ResetsAt -and $pace.UntilFull -lt ($limit.ResetsAt - [DateTime]::UtcNow).TotalSeconds) {
            $paceText = (T 'voll in ~' 'full in ~') + (Format-Duration $pace.UntilFull)
            # Rot nur, wenn es bald eng wird – früh im Fenster schwankt die Hochrechnung stark
            $paceBrush = if ($pace.UntilFull -lt 6 * $Hour) { $Colors.Red } else { $Colors.Orange }
        } elseif ($pace) {
            $paceText = (Format-Number $pace.PerHour 1) + ' %/h → ' + [Math]::Round($pace.Projected) + ' %'
            if ($pace.Projected -ge 90) { $paceBrush = $Colors.Orange }
        }
        $paceBlock = New-Text $paceText 11 $paceBrush
        $paceBlock.ToolTip = T 'Ø Tempo seit Fensterbeginn → Prognose bei Reset' 'Avg. pace since window start → projection at reset'
        Add-Child (New-Row (New-Text (Format-Reset $limit.ResetsAt) 11 $Colors.Secondary) $paceBlock) 10
    }

    if ($section.Error) {
        $warning = New-Text ([string][char]0x26A0 + ' ' + $section.Error) 11 $Colors.Orange
        $warning.TextWrapping = 'Wrap'
        Add-Child $warning 10
    } elseif ($section.Limits.Count -eq 0) {
        Add-Child (New-Text (T 'lädt …' 'loading …') 11 $Colors.Secondary) 10
    }
}

function Render {
    $Stack.Children.Clear()
    $visible = @($State.claude, $State.codex | Where-Object { $_.Installed })
    foreach ($section in $visible) {
        Render-Section $section
        if ($Stack.Children.Count -gt 0) {
            $lastChild = $Stack.Children[$Stack.Children.Count - 1]
            $lastChild.Margin = New-Object System.Windows.Thickness(0, 0, 0, 14)
        }
    }
    if ($visible.Count -eq 0) {
        Add-Child (New-Text (T 'Weder Claude Code noch Codex gefunden' 'Neither Claude Code nor Codex found') 12 $Colors.Secondary) 8
    }
    $stamp = if ($script:UpdatedAt) { (T 'Stand ' 'Updated ') + $script:UpdatedAt.ToString('HH:mm') } else { '' }
    Add-Child (New-Text $stamp 10.5 $Colors.Tertiary) 0
}

function Update-Section($section, [scriptblock]$fetch, [string]$format, [string]$logDir) {
    if (-not $section.Installed) { return }
    try {
        $data = & $fetch
        $section.Limits = $data.Limits
        $section.Plan = $data.Plan
        $section.Error = $null
        $script:UpdatedAt = Get-Date
    } catch {
        # letzte Werte bleiben stehen, Fehler wird darunter angezeigt
        $section.Error = $_.Exception.Message
    }
    try {
        $section.Burn = Get-BurnRate $format $logDir
    } catch {
        $section.Burn = $null
        Write-Log "Burn rate ($format): $($_.Exception.Message)"
    }
}

function Update-All {
    try {
        $claudeLogs = Need 'CLAUDE_PROJECTS_DIR'
        $codexLogs = Need 'CODEX_SESSIONS_DIR'
        $State.claude.Installed = (Test-Path -LiteralPath (Need 'CLAUDE_CREDENTIALS_FILE')) -or (Test-Path -LiteralPath $claudeLogs)
        $State.codex.Installed = (Test-Path -LiteralPath (Need 'CODEX_AUTH_FILE')) -or (Test-Path -LiteralPath $codexLogs)
        Update-Section $State.claude { Get-ClaudeData } 'claude' $claudeLogs
        Update-Section $State.codex { Get-CodexData } 'codex' $codexLogs
        Render
    } catch {
        Write-Log "Update failed: $($_.Exception.Message)"
    }
}

# --- Start

try {
    Restore-Position
    Render
    $Window.Add_ContentRendered({ Update-All })
    $Timer = New-Object System.Windows.Threading.DispatcherTimer
    $Timer.Interval = [TimeSpan]::FromSeconds($RefreshSeconds)
    $Timer.Add_Tick({ Update-All })
    $Timer.Start()
    [void]$Window.ShowDialog()
} catch {
    Fail "burnrate crashed: $($_.Exception.Message)"
} finally {
    $Mutex.ReleaseMutex()
}
