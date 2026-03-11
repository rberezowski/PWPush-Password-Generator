Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

# ============================================================
# PWPush GUI
# Version : 1.7
# Purpose : Generate or enter a password, optionally add
#           multiline extra information, push it to PWPush,
#           and optionally open a new email with the PWPush URL.
#
# Notes:
# - Default PWPush URL = https://pwpush..com
# - Startup cursor lands in Recipient Email
# - Max Days  = 14
# - Max Views = 10
# - "Generate" only generates a password
# - "Push" pushes:
#       Password: <password>
#       <optional extra lines>
# - "Email PWPush URL" opens the default mail client with the
#   generated PWPush URL in the message body
# ============================================================

# ------------------------------------------------------------
# Script-scope storage
# ------------------------------------------------------------
$script:LastPushUrl = ""
$script:PushCooldownSeconds = 5
$script:PushTimer = $null
$script:PushTimerRemaining = 0

# ------------------------------------------------------------
# Helper: Status / Log
# ------------------------------------------------------------
function Set-Status {
    param(
        [string]$Message,
        [System.Drawing.Color]$Color = [System.Drawing.Color]::Black
    )

    $lblStatus.Text = $Message
    $lblStatus.ForeColor = $Color
}

function Write-Log {
    param(
        [string]$Message
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $txtLog.AppendText("[$timestamp] $Message`r`n")
}

# ------------------------------------------------------------
# Helper: Password Generator
# ------------------------------------------------------------
function Generate-RandomPassword {
    param(
        [int]$Length = 20,
        [bool]$UseLetters = $true,
        [bool]$UseNumbers = $true,
        [bool]$UseUppercase = $true,
        [bool]$UseSpecial = $true
    )

    $lowerChars   = "abcdefghijklmnopqrstuvwxyz"
    $upperChars   = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    $numberChars  = "0123456789"
    $specialChars = "!@#$%^&*()-_=+[]{};:,.?/"

    $charPool = ""
    $required = New-Object System.Collections.Generic.List[char]

    if ($UseLetters) {
        $charPool += $lowerChars
        $required.Add(($lowerChars.ToCharArray() | Get-Random))
    }

    if ($UseUppercase) {
        $charPool += $upperChars
        $required.Add(($upperChars.ToCharArray() | Get-Random))
    }

    if ($UseNumbers) {
        $charPool += $numberChars
        $required.Add(($numberChars.ToCharArray() | Get-Random))
    }

    if ($UseSpecial) {
        $charPool += $specialChars
        $required.Add(($specialChars.ToCharArray() | Get-Random))
    }

    if ([string]::IsNullOrWhiteSpace($charPool)) {
        throw "Select at least one character type for password generation."
    }

    if ($Length -lt $required.Count) {
        $Length = $required.Count
    }

    $passwordChars = New-Object System.Collections.Generic.List[char]

    foreach ($char in $required) {
        $passwordChars.Add($char)
    }

    $poolArray = $charPool.ToCharArray()

    for ($i = $passwordChars.Count; $i -lt $Length; $i++) {
        $passwordChars.Add(($poolArray | Get-Random))
    }

    $shuffled = $passwordChars | Sort-Object { Get-Random }
    return (-join $shuffled)
}

# ------------------------------------------------------------
# Helper: Extract PWPush URL from response
# ------------------------------------------------------------
function Get-PWPushUrlFromResponse {
    param(
        [object]$Response,
        [string]$BaseUrl
    )

    if ($null -eq $Response) {
        return $null
    }

    $possibleProps = @(
        "html_url",
        "htmlUrl",
        "url",
        "direct_url",
        "link"
    )

    foreach ($prop in $possibleProps) {
        if ($Response.PSObject.Properties.Name -contains $prop) {
            $value = $Response.$prop
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return $value
            }
        }
    }

    $tokenProps = @("url_token", "token", "id")
    foreach ($prop in $tokenProps) {
        if ($Response.PSObject.Properties.Name -contains $prop) {
            $token = $Response.$prop
            if (-not [string]::IsNullOrWhiteSpace($token)) {
                return ($BaseUrl.TrimEnd("/") + "/p/" + $token)
            }
        }
    }

    if ($Response.PSObject.Properties.Name -contains "password") {
        $pwObj = $Response.password

        foreach ($prop in $possibleProps) {
            if ($pwObj.PSObject.Properties.Name -contains $prop) {
                $value = $pwObj.$prop
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    return $value
                }
            }
        }

        foreach ($prop in $tokenProps) {
            if ($pwObj.PSObject.Properties.Name -contains $prop) {
                $token = $pwObj.$prop
                if (-not [string]::IsNullOrWhiteSpace($token)) {
                    return ($BaseUrl.TrimEnd("/") + "/p/" + $token)
                }
            }
        }
    }

    return $null
}

# ------------------------------------------------------------
# Helper: Push password to PWPush
# ------------------------------------------------------------
function Push-PWPush {
    param(
        [string]$BaseUrl,
        [string]$Password,
        [int]$ExpireDays,
        [int]$ExpireViews
    )

    if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
        throw "PWPush URL is required."
    }

    if ([string]::IsNullOrWhiteSpace($Password)) {
        throw "Generate or enter a password first before pushing."
    }

    if ($ExpireDays -lt 1)  { $ExpireDays = 1 }
    if ($ExpireDays -gt 14) { $ExpireDays = 14 }

    if ($ExpireViews -lt 1)  { $ExpireViews = 1 }
    if ($ExpireViews -gt 10) { $ExpireViews = 10 }

    $base = $BaseUrl.TrimEnd('/')
    $apiUrl = "$base/p.json"

    $body = @{
        "password[payload]"            = $Password
        "password[expire_after_days]"  = $ExpireDays
        "password[expire_after_views]" = $ExpireViews
    }

    try {
        $response = Invoke-RestMethod -Uri $apiUrl -Method Post -Body $body -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
        $pushUrl = Get-PWPushUrlFromResponse -Response $response -BaseUrl $base

        if ([string]::IsNullOrWhiteSpace($pushUrl)) {
            throw "PWPush accepted the request but no usable URL was returned."
        }

        return $pushUrl
    }
    catch {
        throw $_.Exception.Message
    }
}

# ------------------------------------------------------------
# Helper: Open email with PWPush URL
# ------------------------------------------------------------
function Open-PWPushEmail {
    param(
        [string]$PushUrl,
        [string]$Recipient = ""
    )

    if ([string]::IsNullOrWhiteSpace($PushUrl) -or $PushUrl -notmatch '^https?://') {
        [System.Windows.Forms.MessageBox]::Show(
            "There is no valid PWPush URL to email yet.",
            "PWPush URL Missing",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        return
    }

    $subject = "Your secure PWPush link"

    $body = @"
Hello,

Here is your secure PWPush link:

$PushUrl

Thanks
"@

    $mailto = "mailto:{0}?subject={1}&body={2}" -f `
        [System.Uri]::EscapeDataString($Recipient), `
        [System.Uri]::EscapeDataString($subject), `
        [System.Uri]::EscapeDataString($body)

    Start-Process $mailto
}

# ------------------------------------------------------------
# Helper: Start push cooldown timer
# ------------------------------------------------------------
function Start-PushCooldown {
    $script:PushTimerRemaining = $script:PushCooldownSeconds
    $btnPush.Enabled = $false
    $btnPush.Text = "Push ($script:PushTimerRemaining)"

    if ($script:PushTimer -eq $null) {
        $script:PushTimer = New-Object System.Windows.Forms.Timer
        $script:PushTimer.Interval = 1000
        $script:PushTimer.Add_Tick({
            $script:PushTimerRemaining--

            if ($script:PushTimerRemaining -le 0) {
                $script:PushTimer.Stop()
                $btnPush.Enabled = $true
                $btnPush.Text = "Push"
            }
            else {
                $btnPush.Text = "Push ($script:PushTimerRemaining)"
            }
        })
    }

    $script:PushTimer.Start()
}

# ------------------------------------------------------------
# Form
# ------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "PWPush Password Sender"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(880, 820)
$form.MinimumSize = New-Object System.Drawing.Size(880, 820)
$form.BackColor = [System.Drawing.Color]::WhiteSmoke
$form.Font = New-Object System.Drawing.Font("Segoe UI", 10)

# ------------------------------------------------------------
# Title
# ------------------------------------------------------------
$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "PWPush Password Sender"
$lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$lblTitle.Location = New-Object System.Drawing.Point(20, 15)
$lblTitle.Size = New-Object System.Drawing.Size(350, 35)
$form.Controls.Add($lblTitle)

# ------------------------------------------------------------
# PWPush Base URL
# ------------------------------------------------------------
$lblBaseUrl = New-Object System.Windows.Forms.Label
$lblBaseUrl.Text = "PWPush Base URL:"
$lblBaseUrl.Location = New-Object System.Drawing.Point(20, 65)
$lblBaseUrl.Size = New-Object System.Drawing.Size(130, 25)
$form.Controls.Add($lblBaseUrl)

$txtBaseUrl = New-Object System.Windows.Forms.TextBox
$txtBaseUrl.Location = New-Object System.Drawing.Point(170, 62)
$txtBaseUrl.Size = New-Object System.Drawing.Size(520, 28)
$txtBaseUrl.Text = "https://pwpush.com"
$txtBaseUrl.TabIndex = 4
$form.Controls.Add($txtBaseUrl)

# ------------------------------------------------------------
# Recipient Email
# ------------------------------------------------------------
$lblRecipient = New-Object System.Windows.Forms.Label
$lblRecipient.Text = "Recipient Email:"
$lblRecipient.Location = New-Object System.Drawing.Point(20, 105)
$lblRecipient.Size = New-Object System.Drawing.Size(130, 25)
$form.Controls.Add($lblRecipient)

$txtRecipient = New-Object System.Windows.Forms.TextBox
$txtRecipient.Location = New-Object System.Drawing.Point(170, 102)
$txtRecipient.Size = New-Object System.Drawing.Size(300, 28)
$txtRecipient.TabIndex = 0
$form.Controls.Add($txtRecipient)

# ------------------------------------------------------------
# Password
# ------------------------------------------------------------
$lblPassword = New-Object System.Windows.Forms.Label
$lblPassword.Text = "Custom Password:"
$lblPassword.Location = New-Object System.Drawing.Point(20, 145)
$lblPassword.Size = New-Object System.Drawing.Size(130, 25)
$form.Controls.Add($lblPassword)

$txtPassword = New-Object System.Windows.Forms.TextBox
$txtPassword.Location = New-Object System.Drawing.Point(170, 142)
$txtPassword.Size = New-Object System.Drawing.Size(430, 28)
$txtPassword.UseSystemPasswordChar = $false
$txtPassword.TabIndex = 1
$form.Controls.Add($txtPassword)

$btnClearPassword = New-Object System.Windows.Forms.Button
$btnClearPassword.Text = "Clear"
$btnClearPassword.Location = New-Object System.Drawing.Point(610, 140)
$btnClearPassword.Size = New-Object System.Drawing.Size(80, 30)
$btnClearPassword.Add_Click({
    $txtPassword.Text = ""
    Set-Status -Message "Password cleared." -Color ([System.Drawing.Color]::DarkOrange)
    Write-Log "Password box cleared."
})
$form.Controls.Add($btnClearPassword)

# ------------------------------------------------------------
# Additional Information
# ------------------------------------------------------------
$lblAdditionalInfo = New-Object System.Windows.Forms.Label
$lblAdditionalInfo.Text = "Additional Information:"
$lblAdditionalInfo.Location = New-Object System.Drawing.Point(20, 185)
$lblAdditionalInfo.Size = New-Object System.Drawing.Size(140, 25)
$form.Controls.Add($lblAdditionalInfo)

$txtAdditionalInfo = New-Object System.Windows.Forms.TextBox
$txtAdditionalInfo.Location = New-Object System.Drawing.Point(170, 182)
$txtAdditionalInfo.Size = New-Object System.Drawing.Size(520, 95)
$txtAdditionalInfo.Multiline = $true
$txtAdditionalInfo.ScrollBars = "Vertical"
$txtAdditionalInfo.AcceptsReturn = $true
$txtAdditionalInfo.AcceptsTab = $false
$form.Controls.Add($txtAdditionalInfo)

# ------------------------------------------------------------
# Password generation options
# ------------------------------------------------------------
$grpGenerate = New-Object System.Windows.Forms.GroupBox
$grpGenerate.Text = "Password Generation Options"
$grpGenerate.Location = New-Object System.Drawing.Point(20, 290)
$grpGenerate.Size = New-Object System.Drawing.Size(820, 110)
$form.Controls.Add($grpGenerate)

$chkLetters = New-Object System.Windows.Forms.CheckBox
$chkLetters.Text = "Letters (lowercase)"
$chkLetters.Location = New-Object System.Drawing.Point(20, 30)
$chkLetters.Size = New-Object System.Drawing.Size(150, 25)
$chkLetters.Checked = $true
$grpGenerate.Controls.Add($chkLetters)

$chkUppercase = New-Object System.Windows.Forms.CheckBox
$chkUppercase.Text = "Uppercase"
$chkUppercase.Location = New-Object System.Drawing.Point(190, 30)
$chkUppercase.Size = New-Object System.Drawing.Size(120, 25)
$chkUppercase.Checked = $true
$grpGenerate.Controls.Add($chkUppercase)

$chkNumbers = New-Object System.Windows.Forms.CheckBox
$chkNumbers.Text = "Numbers"
$chkNumbers.Location = New-Object System.Drawing.Point(320, 30)
$chkNumbers.Size = New-Object System.Drawing.Size(100, 25)
$chkNumbers.Checked = $true
$grpGenerate.Controls.Add($chkNumbers)

$chkSpecial = New-Object System.Windows.Forms.CheckBox
$chkSpecial.Text = "Special Characters"
$chkSpecial.Location = New-Object System.Drawing.Point(430, 30)
$chkSpecial.Size = New-Object System.Drawing.Size(160, 25)
$chkSpecial.Checked = $true
$grpGenerate.Controls.Add($chkSpecial)

$lblLength = New-Object System.Windows.Forms.Label
$lblLength.Text = "Password Length:"
$lblLength.Location = New-Object System.Drawing.Point(20, 67)
$lblLength.Size = New-Object System.Drawing.Size(130, 25)
$grpGenerate.Controls.Add($lblLength)

$numLength = New-Object System.Windows.Forms.NumericUpDown
$numLength.Location = New-Object System.Drawing.Point(160, 64)
$numLength.Size = New-Object System.Drawing.Size(80, 28)
$numLength.Minimum = 4
$numLength.Maximum = 128
$numLength.Value = 20
$grpGenerate.Controls.Add($numLength)

$btnGenerate = New-Object System.Windows.Forms.Button
$btnGenerate.Text = "Generate"
$btnGenerate.Location = New-Object System.Drawing.Point(270, 61)
$btnGenerate.Size = New-Object System.Drawing.Size(110, 32)
$btnGenerate.TabIndex = 2
$btnGenerate.Add_Click({
    try {
        $generatedPassword = Generate-RandomPassword `
            -Length ([int]$numLength.Value) `
            -UseLetters $chkLetters.Checked `
            -UseNumbers $chkNumbers.Checked `
            -UseUppercase $chkUppercase.Checked `
            -UseSpecial $chkSpecial.Checked

        $txtPassword.Text = $generatedPassword
        Set-Status -Message "Password generated." -Color ([System.Drawing.Color]::ForestGreen)
        Write-Log "Password generated successfully."
    }
    catch {
        Set-Status -Message $_.Exception.Message -Color ([System.Drawing.Color]::Firebrick)
        Write-Log "Generate failed: $($_.Exception.Message)"
    }
})
$grpGenerate.Controls.Add($btnGenerate)

# ------------------------------------------------------------
# Expiry controls
# ------------------------------------------------------------
$grpExpiry = New-Object System.Windows.Forms.GroupBox
$grpExpiry.Text = "PWPush Expiry Settings"
$grpExpiry.Location = New-Object System.Drawing.Point(20, 415)
$grpExpiry.Size = New-Object System.Drawing.Size(820, 80)
$form.Controls.Add($grpExpiry)

$lblDays = New-Object System.Windows.Forms.Label
$lblDays.Text = "Days (max 14):"
$lblDays.Location = New-Object System.Drawing.Point(20, 33)
$lblDays.Size = New-Object System.Drawing.Size(120, 25)
$grpExpiry.Controls.Add($lblDays)

$numDays = New-Object System.Windows.Forms.NumericUpDown
$numDays.Location = New-Object System.Drawing.Point(140, 30)
$numDays.Size = New-Object System.Drawing.Size(80, 28)
$numDays.Minimum = 1
$numDays.Maximum = 14
$numDays.Value = 7
$grpExpiry.Controls.Add($numDays)

$lblViews = New-Object System.Windows.Forms.Label
$lblViews.Text = "Views (max 10):"
$lblViews.Location = New-Object System.Drawing.Point(260, 33)
$lblViews.Size = New-Object System.Drawing.Size(120, 25)
$grpExpiry.Controls.Add($lblViews)

$numViews = New-Object System.Windows.Forms.NumericUpDown
$numViews.Location = New-Object System.Drawing.Point(380, 30)
$numViews.Size = New-Object System.Drawing.Size(80, 28)
$numViews.Minimum = 1
$numViews.Maximum = 10
$numViews.Value = 5
$grpExpiry.Controls.Add($numViews)

# ------------------------------------------------------------
# PWPush URL result
# ------------------------------------------------------------
$lblPushUrl = New-Object System.Windows.Forms.Label
$lblPushUrl.Text = "PWPush URL:"
$lblPushUrl.Location = New-Object System.Drawing.Point(20, 515)
$lblPushUrl.Size = New-Object System.Drawing.Size(130, 25)
$form.Controls.Add($lblPushUrl)

$txtPushUrl = New-Object System.Windows.Forms.TextBox
$txtPushUrl.Location = New-Object System.Drawing.Point(170, 512)
$txtPushUrl.Size = New-Object System.Drawing.Size(520, 28)
$txtPushUrl.ReadOnly = $true
$form.Controls.Add($txtPushUrl)

$btnCopyUrl = New-Object System.Windows.Forms.Button
$btnCopyUrl.Text = "Copy URL"
$btnCopyUrl.Location = New-Object System.Drawing.Point(700, 510)
$btnCopyUrl.Size = New-Object System.Drawing.Size(100, 30)
$btnCopyUrl.Enabled = $false
$btnCopyUrl.Add_Click({
    if (-not [string]::IsNullOrWhiteSpace($txtPushUrl.Text)) {
        [System.Windows.Forms.Clipboard]::SetText($txtPushUrl.Text)
        Set-Status -Message "PWPush URL copied to clipboard." -Color ([System.Drawing.Color]::ForestGreen)
        Write-Log "PWPush URL copied to clipboard."
    }
})
$form.Controls.Add($btnCopyUrl)

# ------------------------------------------------------------
# Buttons
# ------------------------------------------------------------
$btnPush = New-Object System.Windows.Forms.Button
$btnPush.Text = "Push"
$btnPush.Location = New-Object System.Drawing.Point(20, 560)
$btnPush.Size = New-Object System.Drawing.Size(120, 40)
$btnPush.TabIndex = 3
$btnPush.Add_Click({
    try {
        $passwordText = $txtPassword.Text.Trim()

        if ([string]::IsNullOrWhiteSpace($passwordText)) {
            throw "Generate or enter a password first before pushing."
        }

        $payloadText = "Password: $passwordText"

        if (-not [string]::IsNullOrWhiteSpace($txtAdditionalInfo.Text)) {
            $extraText = $txtAdditionalInfo.Text.Trim()
            $payloadText += "`r`n$extraText"
        }

        Set-Status -Message "Pushing password to PWPush..." -Color ([System.Drawing.Color]::DodgerBlue)
        Write-Log "Push requested."

        $pushUrl = Push-PWPush `
            -BaseUrl $txtBaseUrl.Text.Trim() `
            -Password $payloadText `
            -ExpireDays ([int]$numDays.Value) `
            -ExpireViews ([int]$numViews.Value)

        $script:LastPushUrl = $pushUrl
        $txtPushUrl.Text = $pushUrl
        $btnCopyUrl.Enabled = $true
        $btnEmailUrl.Enabled = $true

        Set-Status -Message "Password pushed successfully." -Color ([System.Drawing.Color]::ForestGreen)
        Write-Log "Push successful. URL: $pushUrl"

        Start-PushCooldown
    }
    catch {
        Set-Status -Message "Push failed: $($_.Exception.Message)" -Color ([System.Drawing.Color]::Firebrick)
        Write-Log "Push failed: $($_.Exception.Message)"
    }
})
$form.Controls.Add($btnPush)

$btnEmailUrl = New-Object System.Windows.Forms.Button
$btnEmailUrl.Text = "Email PWPush URL"
$btnEmailUrl.Location = New-Object System.Drawing.Point(155, 560)
$btnEmailUrl.Size = New-Object System.Drawing.Size(150, 40)
$btnEmailUrl.Enabled = $false
$btnEmailUrl.Add_Click({
    Open-PWPushEmail -PushUrl $txtPushUrl.Text.Trim() -Recipient $txtRecipient.Text.Trim()
    Set-Status -Message "Opened default mail client." -Color ([System.Drawing.Color]::ForestGreen)
    Write-Log "Opened mail client for PWPush URL email."
})
$form.Controls.Add($btnEmailUrl)

$btnOpenUrl = New-Object System.Windows.Forms.Button
$btnOpenUrl.Text = "Open URL"
$btnOpenUrl.Location = New-Object System.Drawing.Point(320, 560)
$btnOpenUrl.Size = New-Object System.Drawing.Size(110, 40)
$btnOpenUrl.Add_Click({
    if (-not [string]::IsNullOrWhiteSpace($txtPushUrl.Text)) {
        Start-Process $txtPushUrl.Text
        Set-Status -Message "Opened PWPush URL in browser." -Color ([System.Drawing.Color]::ForestGreen)
        Write-Log "Opened PWPush URL in browser."
    }
    else {
        Set-Status -Message "No PWPush URL available to open." -Color ([System.Drawing.Color]::DarkOrange)
        Write-Log "Open URL requested with no PWPush URL available."
    }
})
$form.Controls.Add($btnOpenUrl)

$btnReset = New-Object System.Windows.Forms.Button
$btnReset.Text = "Reset"
$btnReset.Location = New-Object System.Drawing.Point(445, 560)
$btnReset.Size = New-Object System.Drawing.Size(110, 40)
$btnReset.Add_Click({
    $txtRecipient.Text = ""
    $txtPassword.Text = ""
    $txtAdditionalInfo.Text = ""
    $txtPushUrl.Text = ""
    $script:LastPushUrl = ""
    $btnCopyUrl.Enabled = $false
    $btnEmailUrl.Enabled = $false
    $numDays.Value = 7
    $numViews.Value = 5
    $numLength.Value = 20
    $chkLetters.Checked = $true
    $chkUppercase.Checked = $true
    $chkNumbers.Checked = $true
    $chkSpecial.Checked = $true
    Set-Status -Message "Form reset." -Color ([System.Drawing.Color]::DodgerBlue)
    Write-Log "Form reset."
    $txtRecipient.Focus()
    $txtRecipient.Select()
})
$form.Controls.Add($btnReset)

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text = "Close"
$btnClose.Location = New-Object System.Drawing.Point(570, 560)
$btnClose.Size = New-Object System.Drawing.Size(110, 40)
$btnClose.Add_Click({
    $form.Close()
})
$form.Controls.Add($btnClose)

# ------------------------------------------------------------
# Status
# ------------------------------------------------------------
$lblStatusHeader = New-Object System.Windows.Forms.Label
$lblStatusHeader.Text = "Status:"
$lblStatusHeader.Location = New-Object System.Drawing.Point(20, 620)
$lblStatusHeader.Size = New-Object System.Drawing.Size(60, 25)
$form.Controls.Add($lblStatusHeader)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "Ready."
$lblStatus.Location = New-Object System.Drawing.Point(85, 620)
$lblStatus.Size = New-Object System.Drawing.Size(750, 25)
$lblStatus.ForeColor = [System.Drawing.Color]::Black
$form.Controls.Add($lblStatus)

# ------------------------------------------------------------
# Log Output
# ------------------------------------------------------------
$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text = "Activity Log:"
$lblLog.Location = New-Object System.Drawing.Point(20, 650)
$lblLog.Size = New-Object System.Drawing.Size(100, 25)
$form.Controls.Add($lblLog)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(20, 675)
$txtLog.Size = New-Object System.Drawing.Size(820, 90)
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$form.Controls.Add($txtLog)

# ------------------------------------------------------------
# Startup log
# ------------------------------------------------------------
Write-Log "PWPush GUI started."
Set-Status -Message "Ready." -Color ([System.Drawing.Color]::Black)

# ------------------------------------------------------------
# Set initial focus
# ------------------------------------------------------------
$form.Add_Shown({
    $form.Activate()
    $txtRecipient.Focus()
    $txtRecipient.Select()
})

# ------------------------------------------------------------
# Show form
# ------------------------------------------------------------
[void]$form.ShowDialog()