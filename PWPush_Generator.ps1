<#
    .SYNOPSIS
    PWPush.com password generator / custom password pusher GUI.

    .NOTES
    - If Custom Password is entered, that exact value is used.
    - If Custom Password is blank, Generate creates a random password using Length + selected options.
    - Push sends the currently displayed password to PWPush.
    - Timer/reset only applies to Push.
    - No hashing is performed on your custom password.
    - Days slider max is 14.
    - Views slider max is 10.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# -----------------------------
# Functions
# -----------------------------

function New-RandomPassword {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$PasswordLength,

        [Parameter(Mandatory = $true)]
        [bool]$UseLetters,

        [Parameter(Mandatory = $true)]
        [bool]$UseNumbers,

        [Parameter(Mandatory = $true)]
        [bool]$UseUppercase,

        [Parameter(Mandatory = $true)]
        [bool]$UseSpecial
    )

    $validCharacters = New-Object System.Collections.Generic.List[char]

    if ($UseLetters) {
        97..122 | ForEach-Object { [void]$validCharacters.Add([char]$_) }
        if ($UseUppercase) {
            65..90 | ForEach-Object { [void]$validCharacters.Add([char]$_) }
        }
    }

    if ($UseNumbers) {
        48..57 | ForEach-Object { [void]$validCharacters.Add([char]$_) }
    }

    if ($UseSpecial) {
        @('!', '@', '#', '%', '^', '&', '*') | ForEach-Object {
            [void]$validCharacters.Add([char]$_)
        }
    }

    if ($validCharacters.Count -eq 0) {
        throw "Select at least one random password option: Letters, Numbers, or Special Characters."
    }

    return (1..$PasswordLength | ForEach-Object {
        Get-Random -InputObject $validCharacters
    }) -join ''
}

function ConvertFrom-SecurePassword {
    param (
        [Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
        [SecureString]$Password
    )

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringUni($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Publish-Password {
    param (
        [Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
        [Alias("p")]
        [SecureString]$Password,

        [Alias("d")]
        [int]$Days = 7,

        [Alias("v")]
        [int]$Views = 5,

        [Alias("s")]
        [string]$Server = "pwpush.com",

        [Alias("k")]
        [switch]$KillSwitch,

        [Alias("f")]
        [switch]$FirstView,

        [Alias("w")]
        [switch]$Wipe,

        [Alias("r")]
        [int]$Retrieval,

        [Alias("ph")]
        [string]$Passphrase
    )

    $payload = ConvertFrom-SecurePassword $Password

    $bodyObject = @{
        password = @{
            payload            = $payload
            expire_after_days  = $Days
            expire_after_views = $Views
            retrieval_step     = $Retrieval
            passphrase         = $Passphrase
            first_view         = $FirstView.IsPresent.ToString().ToLower()
        }
    }

    if ($KillSwitch) {
        $bodyObject.password["deletable_by_viewer"] = $true
    }

    $Reply = Invoke-RestMethod -Method Post `
        -Uri "https://$Server/p.json" `
        -ContentType "application/json" `
        -Body ($bodyObject | ConvertTo-Json -Depth 5)

    if ($Reply.url_token) {
        if ($Wipe) {
            $Password.Dispose()
        }
        return "https://$Server/p/$($Reply.url_token)"
    }
    else {
        throw "Unable to get URL from service"
    }
}

function Get-GeneratedPassword {
    $PasswordLengthText = $txtPasswordLength.Text.Trim()

    if ([string]::IsNullOrWhiteSpace($PasswordLengthText)) {
        throw "Enter a valid numeric length."
    }

    $parsedLength = 0
    if (-not [int]::TryParse($PasswordLengthText, [ref]$parsedLength)) {
        throw "Password length must be a valid number."
    }

    if ($parsedLength -lt 1) {
        throw "Password length must be greater than 0."
    }

    return (New-RandomPassword `
        -PasswordLength $parsedLength `
        -UseLetters $chkLetters.Checked `
        -UseNumbers $chkNumbers.Checked `
        -UseUppercase $chkUppercase.Checked `
        -UseSpecial $chkSpecial.Checked)
}

function Update-RandomOptionState {
    $usingCustom = -not [string]::IsNullOrWhiteSpace($txtCustomPassword.Text)

    $txtPasswordLength.Enabled = -not $usingCustom
    $lblPasswordLength.Enabled = -not $usingCustom

    $chkLetters.Enabled = -not $usingCustom
    $chkNumbers.Enabled = -not $usingCustom
    $chkUppercase.Enabled = (-not $usingCustom) -and $chkLetters.Checked
    $chkSpecial.Enabled = -not $usingCustom

    if (-not $chkLetters.Checked) {
        $chkUppercase.Checked = $false
        $chkUppercase.Enabled = $false
    }
}

function Reset-PushState {
    $pwpushTextBox.Clear()
    $btnPush.Text = "Push"
    $btnPush.Enabled = $true
    $timer.Stop()
}

# -----------------------------
# Form
# -----------------------------

$form = New-Object System.Windows.Forms.Form
$form.Text = "PWPush.com Generator 1.8"
$form.Width = 500
$form.Height = 470
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.MaximizeBox = $false
$form.TopMost = $true

# Passphrase
$lblpassphrase = New-Object System.Windows.Forms.Label
$lblpassphrase.Text = "Passphrase:"
$lblpassphrase.AutoSize = $true
$lblpassphrase.Location = New-Object System.Drawing.Point(10, 18)

$txtpassphrase = New-Object System.Windows.Forms.TextBox
$txtpassphrase.Width = 90
$txtpassphrase.Location = New-Object System.Drawing.Point(85, 15)

# Length
$lblPasswordLength = New-Object System.Windows.Forms.Label
$lblPasswordLength.Text = "Length:"
$lblPasswordLength.AutoSize = $true
$lblPasswordLength.Location = New-Object System.Drawing.Point(180, 18)

$txtPasswordLength = New-Object System.Windows.Forms.TextBox
$txtPasswordLength.Width = 45
$txtPasswordLength.Location = New-Object System.Drawing.Point(230, 15)

# 1-click
$checkBox = New-Object System.Windows.Forms.CheckBox
$checkBox.Text = "1-Click"
$checkBox.AutoSize = $true
$checkBox.Location = New-Object System.Drawing.Point(290, 17)

# Custom Password
$lblCustomPassword = New-Object System.Windows.Forms.Label
$lblCustomPassword.Text = "Custom Password:"
$lblCustomPassword.AutoSize = $true
$lblCustomPassword.Location = New-Object System.Drawing.Point(10, 50)

$txtCustomPassword = New-Object System.Windows.Forms.TextBox
$txtCustomPassword.Width = 250
$txtCustomPassword.Location = New-Object System.Drawing.Point(135, 47)
$txtCustomPassword.UseSystemPasswordChar = $true

# Show/hide custom
$chkShowCustom = New-Object System.Windows.Forms.CheckBox
$chkShowCustom.Text = "Show"
$chkShowCustom.AutoSize = $true
$chkShowCustom.Location = New-Object System.Drawing.Point(395, 49)
$chkShowCustom.Add_CheckedChanged({
    $txtCustomPassword.UseSystemPasswordChar = -not $chkShowCustom.Checked
})

# Random options label
$lblRandomOptions = New-Object System.Windows.Forms.Label
$lblRandomOptions.Text = "Random Password Options:"
$lblRandomOptions.AutoSize = $true
$lblRandomOptions.Location = New-Object System.Drawing.Point(10, 82)

# Random option checkboxes
$chkLetters = New-Object System.Windows.Forms.CheckBox
$chkLetters.Text = "Letters"
$chkLetters.AutoSize = $true
$chkLetters.Location = New-Object System.Drawing.Point(25, 105)
$chkLetters.Checked = $true

$chkNumbers = New-Object System.Windows.Forms.CheckBox
$chkNumbers.Text = "Numbers"
$chkNumbers.AutoSize = $true
$chkNumbers.Location = New-Object System.Drawing.Point(115, 105)
$chkNumbers.Checked = $true

$chkUppercase = New-Object System.Windows.Forms.CheckBox
$chkUppercase.Text = "Uppercase"
$chkUppercase.AutoSize = $true
$chkUppercase.Location = New-Object System.Drawing.Point(220, 105)
$chkUppercase.Checked = $true

$chkSpecial = New-Object System.Windows.Forms.CheckBox
$chkSpecial.Text = "Special Characters"
$chkSpecial.AutoSize = $true
$chkSpecial.Location = New-Object System.Drawing.Point(335, 105)
$chkSpecial.Checked = $true

# Disable Length and random options when custom password is entered
$txtCustomPassword.Add_TextChanged({
    Update-RandomOptionState
    Reset-PushState
})

$chkLetters.Add_CheckedChanged({
    Update-RandomOptionState
    Reset-PushState
})

$chkNumbers.Add_CheckedChanged({
    Reset-PushState
})

$chkUppercase.Add_CheckedChanged({
    Reset-PushState
})

$chkSpecial.Add_CheckedChanged({
    Reset-PushState
})

$txtPasswordLength.Add_TextChanged({
    Reset-PushState
})

$txtpassphrase.Add_TextChanged({
    Reset-PushState
})

$checkBox.Add_CheckedChanged({
    Reset-PushState
})

# Enter key support
$txtPasswordLength.Add_KeyDown({
    if ($_.KeyCode -eq 'Enter') {
        $btnGenerate.PerformClick()
    }
})

$txtCustomPassword.Add_KeyDown({
    if ($_.KeyCode -eq 'Enter') {
        if (-not [string]::IsNullOrWhiteSpace($txtCustomPassword.Text)) {
            $btnPush.PerformClick()
        }
        else {
            $btnGenerate.PerformClick()
        }
    }
})

# Days
$lblDays = New-Object System.Windows.Forms.Label
$lblDays.Text = "Days: 7"
$lblDays.Location = New-Object System.Drawing.Point(30, 145)
$lblDays.Width = 80

$sliderDays = New-Object System.Windows.Forms.TrackBar
$sliderDays.Minimum = 0
$sliderDays.Maximum = 14
$sliderDays.Value = 7
$sliderDays.Location = New-Object System.Drawing.Point(100, 135)
$sliderDays.Width = 360
$sliderDays.TickFrequency = 1
$sliderDays.Add_ValueChanged({
    $lblDays.Text = "Days: " + $sliderDays.Value
    Reset-PushState
})

# Views
$lblViews = New-Object System.Windows.Forms.Label
$lblViews.Text = "Views: 5"
$lblViews.Location = New-Object System.Drawing.Point(30, 185)
$lblViews.Width = 80

$sliderViews = New-Object System.Windows.Forms.TrackBar
$sliderViews.Minimum = 0
$sliderViews.Maximum = 10
$sliderViews.Value = 5
$sliderViews.Location = New-Object System.Drawing.Point(100, 175)
$sliderViews.Width = 360
$sliderViews.TickFrequency = 1
$sliderViews.Add_ValueChanged({
    $lblViews.Text = "Views: " + $sliderViews.Value
    Reset-PushState
})

# Generate button
$btnGenerate = New-Object System.Windows.Forms.Button
$btnGenerate.Text = "Generate"
$btnGenerate.Width = 120
$btnGenerate.Height = 36
$btnGenerate.Location = New-Object System.Drawing.Point(120, 220)

# Push button
$btnPush = New-Object System.Windows.Forms.Button
$btnPush.Text = "Push"
$btnPush.Width = 120
$btnPush.Height = 36
$btnPush.Location = New-Object System.Drawing.Point(255, 220)

# Output textbox
$outputTextBox = New-Object System.Windows.Forms.TextBox
$outputTextBox.Multiline = $true
$outputTextBox.Width = 450
$outputTextBox.Height = 49
$outputTextBox.Location = New-Object System.Drawing.Point(10, 270)
$outputTextBox.ReadOnly = $true
$outputTextBox.TabStop = $false
$outputTextBox.BackColor = [System.Drawing.Color]::White

# PWPush label
$PWPushnotif = New-Object System.Windows.Forms.Label
$PWPushnotif.Text = "PWPush URL:"
$PWPushnotif.AutoSize = $true
$PWPushnotif.Location = New-Object System.Drawing.Point(10, 327)

# PWPush URL textbox
$pwpushTextBox = New-Object System.Windows.Forms.TextBox
$pwpushTextBox.Multiline = $true
$pwpushTextBox.Width = 450
$pwpushTextBox.Height = 20
$pwpushTextBox.Location = New-Object System.Drawing.Point(10, 345)
$pwpushTextBox.ReadOnly = $true
$pwpushTextBox.TabStop = $false
$pwpushTextBox.BackColor = [System.Drawing.Color]::White

# Clipboard buttons
$passClip = New-Object System.Windows.Forms.Button
$passClip.Text = "Password to Clipboard"
$passClip.Width = 140
$passClip.Height = 36
$passClip.Location = New-Object System.Drawing.Point(85, 375)
$passClip.Add_Click({
    if ($outputTextBox.Text) {
        Set-Clipboard -Value $outputTextBox.Text
    }
})

$pwpushClip = New-Object System.Windows.Forms.Button
$pwpushClip.Text = "PWPush URL to Clipboard"
$pwpushClip.Width = 160
$pwpushClip.Height = 36
$pwpushClip.Location = New-Object System.Drawing.Point(255, 375)
$pwpushClip.Add_Click({
    if ($pwpushTextBox.Text) {
        Set-Clipboard -Value $pwpushTextBox.Text
    }
})

# Timer for Push button only
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    $countdown = [int]($btnPush.Text.Split(' ')[-1]) - 1
    $btnPush.Text = "Push reset in: $countdown"

    if ($countdown -le 0) {
        $pwpushTextBox.Clear()
        $btnPush.Text = "Push"
        $btnPush.Enabled = $true
        $timer.Stop()
    }
})

# Generate action
$btnGenerate.Add_Click({
    try {
        Reset-PushState

        if (-not [string]::IsNullOrWhiteSpace($txtCustomPassword.Text)) {
            $outputTextBox.Text = $txtCustomPassword.Text
        }
        else {
            $outputTextBox.Text = Get-GeneratedPassword
        }
    }
    catch {
        $outputTextBox.Text = $_.Exception.Message
        $pwpushTextBox.Clear()
    }
})

# Push action
$btnPush.Add_Click({
    try {
        $timer.Stop()
        $pwpushTextBox.Clear()

        # Always prefer the Custom Password box if it has text
        if (-not [string]::IsNullOrWhiteSpace($txtCustomPassword.Text)) {
            $PlainPassword = $txtCustomPassword.Text
            $outputTextBox.Text = $PlainPassword
        }
        else {
            $PlainPassword = $outputTextBox.Text
        }

        if ([string]::IsNullOrWhiteSpace($PlainPassword)) {
            throw "Generate or enter a password first before pushing."
        }

        $Days = $sliderDays.Value
        $Views = $sliderViews.Value
        $Passphrase = $txtpassphrase.Text.Trim()
        $OneClickSuffix = if ($checkBox.Checked) { "/r" } else { "" }

        Write-Host "PW being pushed: [$PlainPassword]"

        $SecurePassword = ConvertTo-SecureString -String $PlainPassword -AsPlainText -Force

        if ([string]::IsNullOrWhiteSpace($Passphrase)) {
            $PWPUSH = Publish-Password -Password $SecurePassword -Days $Days -Views $Views
        }
        else {
            $PWPUSH = Publish-Password -Password $SecurePassword -Days $Days -Views $Views -Passphrase $Passphrase
        }

        if ([string]::IsNullOrWhiteSpace($PWPUSH)) {
            throw "PWPush did not return a URL."
        }

        if ($checkBox.Checked) {
            $pwpushTextBox.Text = $PWPUSH + $OneClickSuffix
        }
        else {
            $pwpushTextBox.Text = $PWPUSH
        }

        $btnPush.Text = "Push reset in: 30"
        $btnPush.Enabled = $false
        $timer.Start()
    }
    catch {
        $pwpushTextBox.Clear()
        $outputTextBox.Text = $_.Exception.Message
    }
})

# Add controls
$form.Controls.Add($lblpassphrase)
$form.Controls.Add($txtpassphrase)
$form.Controls.Add($lblPasswordLength)
$form.Controls.Add($txtPasswordLength)
$form.Controls.Add($checkBox)
$form.Controls.Add($lblCustomPassword)
$form.Controls.Add($txtCustomPassword)
$form.Controls.Add($chkShowCustom)
$form.Controls.Add($lblRandomOptions)
$form.Controls.Add($chkLetters)
$form.Controls.Add($chkNumbers)
$form.Controls.Add($chkUppercase)
$form.Controls.Add($chkSpecial)
$form.Controls.Add($lblDays)
$form.Controls.Add($sliderDays)
$form.Controls.Add($lblViews)
$form.Controls.Add($sliderViews)
$form.Controls.Add($btnGenerate)
$form.Controls.Add($btnPush)
$form.Controls.Add($outputTextBox)
$form.Controls.Add($PWPushnotif)
$form.Controls.Add($pwpushTextBox)
$form.Controls.Add($passClip)
$form.Controls.Add($pwpushClip)

# Initialize control state
Update-RandomOptionState

# Show form
$form.Add_Shown({ $form.Activate() })
$form.Add_FormClosed({
    $timer.Dispose()
})

[void]$form.ShowDialog()