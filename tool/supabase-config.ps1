# Whitelist public client configuration; never pass unrelated .env values to Dart.
function Get-TrackStudyDefines {
    param([string]$ProjectRoot)
    $file = Join-Path $ProjectRoot '.env.local'
    if (!(Test-Path -LiteralPath $file)) { return @() }
    $values = @{}
    foreach ($line in [IO.File]::ReadAllLines($file)) {
        if ($line -match '^\s*(SUPABASE_URL|SUPABASE_PUBLISHABLE_KEY)\s*=\s*(.*?)\s*$') {
            $value = $Matches[2].Trim()
            if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            $values[$Matches[1]] = $value
        }
    }
    if (!$values['SUPABASE_URL'] -or !$values['SUPABASE_PUBLISHABLE_KEY']) { return @() }
    if ($values['SUPABASE_PUBLISHABLE_KEY'] -notmatch '^sb_publishable_' -or $values['SUPABASE_URL'] -notmatch '^https://[^/\s]+/?$') {
        throw 'Invalid Supabase client configuration. Use an HTTPS project URL and an sb_publishable_ key; never a secret/service-role key.'
    }
    return @("SUPABASE_URL=$($values['SUPABASE_URL'])", "SUPABASE_PUBLISHABLE_KEY=$($values['SUPABASE_PUBLISHABLE_KEY'])")
}
