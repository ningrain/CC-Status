Set-StrictMode -Version 2.0

function New-ClaudeTranscriptCursor {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$InitialTailBytes = 4194304
    )

    $offset = 0L
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $length = (Get-Item -LiteralPath $Path -ErrorAction Stop).Length
            $offset = [Math]::Max(0L, $length - [Math]::Max(65536, $InitialTailBytes))
            if ($offset -gt 0) {
                $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
                try {
                    $null = $stream.Seek($offset, [System.IO.SeekOrigin]::Begin)
                    while ($stream.Position -lt $stream.Length) {
                        if ($stream.ReadByte() -eq 10) {
                            $offset = $stream.Position
                            break
                        }
                    }
                }
                finally {
                    $stream.Dispose()
                }
            }
        }
    }
    catch {
        $offset = 0L
    }
    return [pscustomobject]@{ offset = $offset }
}

function Read-ClaudeTranscriptRowsIncremental {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Cursor
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        $start = [long]$Cursor.offset
        if ($start -lt 0 -or $start -gt $stream.Length) { $start = 0L }
        $null = $stream.Seek($start, [System.IO.SeekOrigin]::Begin)
        $available = $stream.Length - $start
        if ($available -le 0) { return @() }

        $buffer = New-Object byte[] ([int]$available)
        $readTotal = 0
        while ($readTotal -lt $buffer.Length) {
            $read = $stream.Read($buffer, $readTotal, $buffer.Length - $readTotal)
            if ($read -le 0) { break }
            $readTotal += $read
        }
        $lastNewline = -1
        for ($index = $readTotal - 1; $index -ge 0; $index--) {
            if ($buffer[$index] -eq 10) {
                $lastNewline = $index
                break
            }
        }
        if ($lastNewline -lt 0) { return @() }

        $Cursor.offset = $start + $lastNewline + 1
        $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $lastNewline + 1)
        $rows = New-Object System.Collections.ArrayList
        foreach ($line in @($text -split "`r?`n")) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $null = $rows.Add(($line | ConvertFrom-Json)) } catch {}
        }
        return @($rows)
    }
    catch {
        return @()
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}
