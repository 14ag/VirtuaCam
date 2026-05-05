param(
    [Parameter(Mandatory=$true)][string]$HwndPath,
    [Parameter(Mandatory=$true)][string]$PidPath,
    [string]$AttemptId = "",
    [string]$MarkerText = ""
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$attemptText = if ($AttemptId) { $AttemptId } else { 'n/a' }
$markerText = if ($MarkerText) { $MarkerText } else { 'marker-missing' }

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Proof Window'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(900, 620)
$form.BackColor = [System.Drawing.Color]::FromArgb(24, 28, 34)

$header = New-Object System.Windows.Forms.Label
$header.Text = 'Virtual Camera Proof Window'
$header.ForeColor = [System.Drawing.Color]::White
$header.Font = New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold)
$header.AutoSize = $true
$header.Location = New-Object System.Drawing.Point(24, 20)
$form.Controls.Add($header)

$group = New-Object System.Windows.Forms.GroupBox
$group.Text = 'Feed'
$group.ForeColor = [System.Drawing.Color]::White
$group.Size = New-Object System.Drawing.Size(840, 500)
$group.Location = New-Object System.Drawing.Point(24, 70)
$form.Controls.Add($group)

$preview = New-Object System.Windows.Forms.Panel
$preview.BackColor = [System.Drawing.Color]::White
$preview.Size = New-Object System.Drawing.Size(520, 360)
$preview.Location = New-Object System.Drawing.Point(24, 40)
$group.Controls.Add($preview)

$pc = New-Object System.Windows.Forms.Label
$pc.Text = "SYNTHETIC DEBUG WINDOW

Attempt: $attemptText

Marker:
$markerText"
$pc.ForeColor = [System.Drawing.Color]::Black
$pc.Font = New-Object System.Drawing.Font('Consolas', 16, [System.Drawing.FontStyle]::Bold)
$pc.AutoSize = $true
$pc.BackColor = [System.Drawing.Color]::Transparent
$pc.Location = New-Object System.Drawing.Point(28, 46)
$preview.Controls.Add($pc)

$btn = New-Object System.Windows.Forms.Button
$btn.Text = 'Synthetic Debug Mode'
$btn.Size = New-Object System.Drawing.Size(180, 36)
$btn.Location = New-Object System.Drawing.Point(580, 60)
$group.Controls.Add($btn)

$list = New-Object System.Windows.Forms.ListBox
$list.Size = New-Object System.Drawing.Size(220, 160)
$list.Location = New-Object System.Drawing.Point(580, 120)
$list.Items.AddRange(@('Synthetic only', 'Do not count as proof', 'Use Notepad or Explorer instead'))
$group.Controls.Add($list)

$status = New-Object System.Windows.Forms.Label
$status.Text = 'Status: Synthetic debug source'
$status.ForeColor = [System.Drawing.Color]::White
$status.AutoSize = $true
$status.Location = New-Object System.Drawing.Point(580, 310)
$group.Controls.Add($status)

$form.Add_Shown({
    param($sender, $eventArgs)
    [System.IO.File]::WriteAllText($HwndPath, ($sender.Handle.ToInt64()).ToString())
    [System.IO.File]::WriteAllText($PidPath, $PID.ToString())
})

[System.Windows.Forms.Application]::Run($form)
