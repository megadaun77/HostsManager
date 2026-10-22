#Requires -Version 5.1
<#
.SYNOPSIS
    Hosts Manager - графическая утилита для управления файлом hosts.

.DESCRIPTION
    Минималистичный WPF-интерфейс в тёмной теме WinUtil (Chris Titus Tech):
      * проверка прав администратора с возможностью перезапуска;
      * автоматическая резервная копия оригинального hosts (hosts.bak);
      * редактор записей: добавление, удаление, включение/выключение строк;
      * массовое добавление: вставка целого списка записей за один раз;
      * профили: сохранение и мгновенное переключение конфигураций;
      * сброс hosts к заводскому шаблону Windows (со страховочной копией);
      * автоматическая очистка DNS-кэша после каждой записи;
      * консольное окно PowerShell скрывается при запуске.

.NOTES
    Запуск: правый клик по файлу -> "Выполнить с помощью PowerShell"
    либо: powershell -NoProfile -ExecutionPolicy Bypass -File .\HostsManager.ps1
    Автор: Senior PowerShell Developer / UI-UX
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# ============================================================
#  Скрытие консольного окна
# ============================================================

function Hide-HostConsole {
    <#
        Прячет консоль PowerShell, чтобы позади WPF-окна не висело синее окно.
        После выхода из утилиты окно возвращается (Restore-HostConsole), чтобы
        не потерять терминал, из которого скрипт был запущен вручную.
    #>
    try {
        if (-not ('HostsUtil.ConsoleApi' -as [type])) {
            Add-Type -Namespace HostsUtil -Name ConsoleApi -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr GetConsoleWindow();

[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool IsWindowVisible(System.IntPtr hWnd);

[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@
        }

        $handle = [HostsUtil.ConsoleApi]::GetConsoleWindow()
        if ($handle -eq [IntPtr]::Zero) { return }

        if ([HostsUtil.ConsoleApi]::IsWindowVisible($handle)) {
            $script:ConsoleHandle = $handle
            $script:ConsoleHidden = $true
            [void][HostsUtil.ConsoleApi]::ShowWindow($handle, 0)  # SW_HIDE
        }
    } catch {
        # Скрытие консоли - косметика, при ошибке просто продолжаем.
    }
}

function Restore-HostConsole {
    <# Возвращает ранее скрытое консольное окно, не забирая фокус. #>
    if (-not $script:ConsoleHidden) { return }
    try {
        [void][HostsUtil.ConsoleApi]::ShowWindow($script:ConsoleHandle, 4)  # SW_SHOWNOACTIVATE
    } catch { }
    $script:ConsoleHidden = $false
}

$script:ConsoleHandle = [IntPtr]::Zero
$script:ConsoleHidden = $false
Hide-HostConsole

$script:StartupComplete = $false

trap {
    <#
        Необработанная ошибка на старте: консоль скрыта, поэтому без этого
        блока пользователь увидел бы только «ничего не произошло».
        Пишем подробный лог рядом со скриптом и показываем сообщение.
    #>
    if ($script:StartupComplete) { throw }

    $errorText = $_.Exception.Message
    $stackText = $_.ScriptStackTrace
    $logText = ("[{0}] {1}`r`n{2}`r`n`r`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $errorText, $stackText)

    $logDir = if (-not [string]::IsNullOrWhiteSpace($script:ScriptDir)) { $script:ScriptDir }
              elseif (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot }
              else { $env:TEMP }
    $logPath = Join-Path $logDir 'HostsManager.error.log'

    try {
        [System.IO.File]::AppendAllText($logPath, $logText, (New-Object System.Text.UTF8Encoding($true)))
    } catch {
        try {
            [System.IO.File]::AppendAllText((Join-Path $env:TEMP 'HostsManager.error.log'), $logText, (New-Object System.Text.UTF8Encoding($true)))
        } catch { }
    }

    try { Restore-HostConsole } catch { }
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        [void][System.Windows.MessageBox]::Show(
            ("Не удалось запустить Hosts Manager.`n`n{0}`n`nПодробности записаны в:`n{1}" -f $errorText, $logPath),
            'Hosts Manager',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error)
    } catch { }
    exit 1
}

# ============================================================
#  0. Константы и пути
# ============================================================

$script:HostsPath   = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$script:BackupPath  = Join-Path (Split-Path -Parent $script:HostsPath) 'hosts.bak'
$script:ScriptDir   = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { (Get-Location).Path }
$script:ProfilesDir = Join-Path $script:ScriptDir 'hosts_profiles'
$script:ProfileExt  = '.hosts'
$script:EntryPattern = '^(?<indent>[ \t]*)(?<comment>#[ \t]*)?(?<ip>(?:\d{1,3}\.){3}\d{1,3}|[0-9A-Fa-f]*:[0-9A-Fa-f:]+)[ \t]+(?<hosts>[^#\s]+(?:[ \t]+[^#\s]+)*)[ \t]*(?:#.*)?$'

# ============================================================
#  1. Проверка потока STA (WPF требует STA)
# ============================================================

function Get-HostExecutable {
    try {
        $path = (Get-Process -Id $PID).Path
        if ($path -and (Split-Path -Leaf $path) -ieq 'powershell_ise.exe') {
            return (Join-Path $PSHOME 'powershell.exe')
        }
        if ($path) { return $path }
    } catch { }
    if ($PSVersionTable.PSEdition -eq 'Core') { return (Join-Path $PSHOME 'pwsh.exe') }
    return (Join-Path $PSHOME 'powershell.exe')
}

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    if (-not [string]::IsNullOrWhiteSpace($PSCommandPath) -and (Test-Path -LiteralPath $PSCommandPath)) {
        try {
            Start-Process -FilePath (Get-HostExecutable) -WindowStyle Hidden -ArgumentList @(
                '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
                '-File', ('"{0}"' -f $PSCommandPath)
            )
            Restore-HostConsole
            exit
        } catch {
            Restore-HostConsole
            Write-Host 'Не удалось перезапустить скрипт в STA-потоке. Запустите его из powershell.exe.' -ForegroundColor Yellow
            Read-Host 'Нажмите Enter для выхода'
            exit 1
        }
    }
    Restore-HostConsole
    Write-Host 'WPF требует STA-поток. Сохраните скрипт в файл и запустите через powershell.exe -Sta -File.' -ForegroundColor Yellow
    exit 1
}

# ============================================================
#  2. Подключение сборок WPF
# ============================================================

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# ============================================================
#  3. Базовые помощники
# ============================================================

function Load-Xaml {
    <#
        Загружает XAML-строку в объект WPF через XamlReader.Load().
        Возвращает корневой элемент (обычно Window).
    #>
    param([Parameter(Mandatory)][string]$Xaml)

    $stringReader = New-Object System.IO.StringReader($Xaml)
    $xmlReader = [System.Xml.XmlReader]::Create($stringReader)
    try {
        return [System.Windows.Markup.XamlReader]::Load($xmlReader)
    } finally {
        $xmlReader.Dispose()
        $stringReader.Dispose()
    }
}

function Test-Administrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Set-DarkTitleBar {
    <# Делает системный заголовок окна тёмным (Windows 10 1809+ / Windows 11). #>
    param([Parameter(Mandatory)]$Window)

    try {
        if (-not ('HostsUtil.DwmApi' -as [type])) {
            Add-Type -Namespace HostsUtil -Name DwmApi -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("dwmapi.dll", PreserveSig = true)]
public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attribute, ref int value, int size);
'@
        }
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($Window)
        if ($helper.Handle -eq [IntPtr]::Zero) { return }
        $enabled = 1
        # 20 = DWMWA_USE_IMMERSIVE_DARK_MODE (Win10 2004+), 19 = ранние сборки Win10
        [void][HostsUtil.DwmApi]::DwmSetWindowAttribute($helper.Handle, 20, [ref]$enabled, 4)
        [void][HostsUtil.DwmApi]::DwmSetWindowAttribute($helper.Handle, 19, [ref]$enabled, 4)
    } catch {
        # Оформление заголовка - необязательная косметика, ошибку игнорируем.
    }
}

# ============================================================
#  4. Универсальное тёмное диалоговое окно
# ============================================================

$script:DialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:sys="clr-namespace:System;assembly=mscorlib"
        Width="560" SizeToContent="Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        WindowStartupLocation="CenterScreen" ShowInTaskbar="False" ResizeMode="NoResize"
        FontFamily="Segoe UI" Foreground="#F7F7F7" SnapsToDevicePixels="True"
        UseLayoutRounding="True">
    <Window.Resources>
        <SolidColorBrush x:Key="CardBg" Color="#282D31"/>

        <Style x:Key="DlgButton" TargetType="Button">
            <Setter Property="Foreground" Value="#F7F7F7"/>
            <Setter Property="Background" Value="#1E3747"/>
            <Setter Property="BorderBrush" Value="#2F4A59"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="16,8"/>
            <Setter Property="MinWidth" Value="108"/>
            <Setter Property="FontSize" Value="12.5"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1"
                                CornerRadius="3" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#3B4252"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#162D3B"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="DlgAccent" TargetType="Button" BasedOn="{StaticResource DlgButton}">
            <Setter Property="Background" Value="#2E77FF"/>
            <Setter Property="BorderBrush" Value="#2E77FF"/>
            <Setter Property="Foreground" Value="#FFFFFF"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="#2E77FF" BorderBrush="#2E77FF" BorderThickness="1"
                                CornerRadius="3" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#4A8CFF"/>
                                <Setter TargetName="Bd" Property="BorderBrush" Value="#4A8CFF"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#1F5FD0"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="DlgDanger" TargetType="Button" BasedOn="{StaticResource DlgAccent}">
            <Setter Property="Background" Value="#FF6B6B"/>
            <Setter Property="BorderBrush" Value="#FF6B6B"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="#FF6B6B" BorderBrush="#FF6B6B" BorderThickness="1"
                                CornerRadius="3" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#FF8A8A"/>
                                <Setter TargetName="Bd" Property="BorderBrush" Value="#FF8A8A"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#D94F4F"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="DlgInput" TargetType="TextBox">
            <Setter Property="Background" Value="#1B1F22"/>
            <Setter Property="Foreground" Value="#F7F7F7"/>
            <Setter Property="BorderBrush" Value="#2F4A59"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="11,8"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="CaretBrush" Value="#F7F7F7"/>
            <Setter Property="SelectionBrush" Value="#2E77FF"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="3">
                            <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"
                                          VerticalAlignment="Stretch" Focusable="False"
                                          HorizontalScrollBarVisibility="{TemplateBinding HorizontalScrollBarVisibility}"
                                          VerticalScrollBarVisibility="{TemplateBinding VerticalScrollBarVisibility}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter TargetName="Bd" Property="BorderBrush" Value="#2E77FF"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- ===== Тонкий тёмный скроллбар для многострочного поля ===== -->
        <Style x:Key="DlgScrollThumb" TargetType="Thumb">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Thumb">
                        <Border Background="#3B4252" CornerRadius="3" Margin="2"/>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="ScrollBar">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Width" Value="10"/>
            <Setter Property="MinWidth" Value="10"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ScrollBar">
                        <Grid Background="Transparent">
                            <Track x:Name="PART_Track" IsDirectionReversed="True">
                                <Track.DecreaseRepeatButton>
                                    <RepeatButton Command="ScrollBar.PageUpCommand" Focusable="False"
                                                  IsTabStop="False" Opacity="0"/>
                                </Track.DecreaseRepeatButton>
                                <Track.Thumb>
                                    <Thumb Style="{StaticResource DlgScrollThumb}"/>
                                </Track.Thumb>
                                <Track.IncreaseRepeatButton>
                                    <RepeatButton Command="ScrollBar.PageDownCommand" Focusable="False"
                                                  IsTabStop="False" Opacity="0"/>
                                </Track.IncreaseRepeatButton>
                            </Track>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="Orientation" Value="Horizontal">
                                <Setter Property="Width" Value="{x:Static sys:Double.NaN}"/>
                                <Setter Property="MinWidth" Value="0"/>
                                <Setter Property="Height" Value="10"/>
                                <Setter TargetName="PART_Track" Property="IsDirectionReversed" Value="False"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Border x:Name="DlgRoot" Background="{StaticResource CardBg}" BorderBrush="#2F373D"
            BorderThickness="1" CornerRadius="8" Margin="22">
        <Border.Effect>
            <DropShadowEffect Color="#000000" BlurRadius="26" ShadowDepth="6" Opacity="0.6"/>
        </Border.Effect>
        <StackPanel Margin="26,24,26,22">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Border x:Name="DlgIcon" Width="38" Height="38" CornerRadius="6"
                        Background="#1E3747" VerticalAlignment="Top">
                    <TextBlock x:Name="DlgIconText" Text="i" FontFamily="Segoe UI" FontSize="19"
                               FontWeight="Bold" Foreground="#5BDCFF"
                               HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <StackPanel Grid.Column="1" Margin="15,0,0,0">
                    <TextBlock x:Name="DlgTitle" Text="Заголовок" FontSize="16.5" FontWeight="SemiBold"
                               Foreground="#FFFFFF" TextWrapping="Wrap"/>
                    <TextBlock x:Name="DlgMessage" Text="Сообщение" Margin="0,7,0,0" FontSize="12.5"
                               Foreground="#A7B0B7" TextWrapping="Wrap" LineHeight="19"/>
                </StackPanel>
            </Grid>

            <TextBox x:Name="DlgInput" Style="{StaticResource DlgInput}" Visibility="Collapsed" Margin="0,18,0,0"/>
            <TextBlock x:Name="DlgError" Text="" Foreground="#FF6B6B" FontSize="11.5"
                       Margin="2,8,0,0" Visibility="Collapsed"/>

            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,22,0,0">
                <Button x:Name="DlgCancel" Content="Отмена" Style="{StaticResource DlgButton}" IsCancel="True"/>
                <Button x:Name="DlgOk" Content="OK" Style="{StaticResource DlgAccent}"
                        Margin="10,0,0,0" IsDefault="True"/>
            </StackPanel>
        </StackPanel>
    </Border>
</Window>
'@

function Show-DarkDialog {
    <#
        Показывает модальное окно в стиле приложения.
        Mode = Info    -> одна кнопка, возвращает $true;
        Mode = Confirm -> две кнопки, возвращает $true/$false;
        Mode = Input   -> поле ввода, возвращает строку или $null;
        Mode = Bulk    -> большое многострочное поле (список записей).
    #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Confirm', 'Input', 'Bulk')][string]$Mode = 'Info',
        [string]$OkText = 'OK',
        [string]$CancelText = 'Отмена',
        [string]$DefaultValue = '',
        [scriptblock]$Validator,
        [switch]$Danger
    )

    $script:DlgWindow  = Load-Xaml $script:DialogXaml
    $script:DlgMode    = $Mode
    $script:DlgResult  = $null
    $script:DlgRoot    = $script:DlgWindow.FindName('DlgRoot')
    $script:DlgTitle   = $script:DlgWindow.FindName('DlgTitle')
    $script:DlgMessage = $script:DlgWindow.FindName('DlgMessage')
    $script:DlgInput   = $script:DlgWindow.FindName('DlgInput')
    $script:DlgError   = $script:DlgWindow.FindName('DlgError')
    $script:DlgOk      = $script:DlgWindow.FindName('DlgOk')
    $script:DlgCancel  = $script:DlgWindow.FindName('DlgCancel')
    $script:DlgValidator = $Validator

    $script:DlgTitle.Text   = $Title
    $script:DlgMessage.Text = $Message
    $script:DlgOk.Content     = $OkText
    $script:DlgCancel.Content = $CancelText

    if ($Danger) {
        $dangerStyle = $script:DlgWindow.FindResource('DlgDanger')
        if ($dangerStyle) { $script:DlgOk.Style = $dangerStyle }
    }

    if ($Danger -and $Mode -eq 'Confirm') {
        # Enter не должен подтверждать опасное действие: по умолчанию — «Отмена».
        $script:DlgOk.IsDefault = $false
        $script:DlgCancel.IsDefault = $true
        $script:DlgWindow.Add_Loaded({
            if ($script:DlgMode -eq 'Confirm') {
                try { $script:DlgCancel.Focus() | Out-Null } catch { }
            }
        })
    }

    switch ($Mode) {
        'Info' {
            $script:DlgCancel.Visibility = 'Collapsed'
        }
        'Confirm' {
            $script:DlgCancel.Visibility = 'Visible'
        }
        'Input' {
            $script:DlgCancel.Visibility = 'Visible'
            $script:DlgInput.Visibility  = 'Visible'
            $script:DlgInput.Text        = $DefaultValue
            $script:DlgInput.Add_Loaded({
                $script:DlgInput.Focus() | Out-Null
                $script:DlgInput.SelectAll()
            })
        }
        'Bulk' {
            $script:DlgWindow.Width           = 700
            $script:DlgCancel.Visibility      = 'Visible'
            $script:DlgInput.Visibility       = 'Visible'
            $script:DlgInput.Text             = $DefaultValue
            $script:DlgInput.AcceptsReturn    = $true
            $script:DlgInput.TextWrapping     = 'NoWrap'
            $script:DlgInput.Height           = 250
            $script:DlgInput.FontFamily       = 'Consolas'
            $script:DlgInput.FontSize         = 12
            $script:DlgInput.VerticalContentAlignment   = 'Top'
            $script:DlgInput.VerticalScrollBarVisibility   = 'Auto'
            $script:DlgInput.HorizontalScrollBarVisibility = 'Auto'
            $script:DlgInput.Add_Loaded({
                $script:DlgInput.Focus() | Out-Null
            })
        }
    }

    # Перетаскивание окна за свободную область
    $script:DlgRoot.Add_MouseLeftButtonDown({
        try { $script:DlgWindow.DragMove() } catch { }
    })

    $script:DlgOk.Add_Click({
        if ($script:DlgMode -eq 'Input' -or $script:DlgMode -eq 'Bulk') {
            $text = $script:DlgInput.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($text)) {
                $script:DlgError.Text = 'Поле не может быть пустым.'
                $script:DlgError.Visibility = 'Visible'
                $script:DlgInput.Focus() | Out-Null
                return
            }
            if ($script:DlgValidator) {
                $validationError = & $script:DlgValidator $text
                if (-not [string]::IsNullOrWhiteSpace([string]$validationError)) {
                    $script:DlgError.Text = [string]$validationError
                    $script:DlgError.Visibility = 'Visible'
                    $script:DlgInput.Focus() | Out-Null
                    return
                }
            }
            $script:DlgResult = $text
        } else {
            $script:DlgResult = $true
        }
        $script:DlgWindow.Close()
    })

    $script:DlgCancel.Add_Click({
        $script:DlgResult = if ($script:DlgMode -eq 'Input' -or $script:DlgMode -eq 'Bulk') { $null } else { $false }
        $script:DlgWindow.Close()
    })

    if ($script:Window -and $script:Window.IsVisible) {
        $script:DlgWindow.Owner = $script:Window
        $script:DlgWindow.WindowStartupLocation = 'CenterOwner'
    }

    [void]$script:DlgWindow.ShowDialog()

    $result = $script:DlgResult
    $script:DlgWindow = $null
    $script:DlgRoot = $null
    $script:DlgInput = $null
    $script:DlgValidator = $null
    return $result
}

# ============================================================
#  5. Проверка прав администратора
# ============================================================

if (-not (Test-Administrator)) {
    $restart = Show-DarkDialog `
        -Title 'Требуются права администратора' `
        -Message ("Файл hosts защищён системой, поэтому для его изменения нужны права администратора.`n`n" +
                  "Утилита может перезапуститься с повышенными правами — Windows покажет запрос UAC.`n`n" +
                  "Путь к файлу: $($script:HostsPath)") `
        -Mode Confirm `
        -OkText 'Перезапустить' `
        -CancelText 'Выход'

    if ($restart -and -not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
        try {
            Start-Process -FilePath (Get-HostExecutable) -Verb RunAs -WindowStyle Hidden -WorkingDirectory $script:ScriptDir -ArgumentList @(
                '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
                '-File', ('"{0}"' -f $PSCommandPath)
            )
        } catch {
            [void](Show-DarkDialog `
                -Title 'Не удалось перезапуститься' `
                -Message ("Запрос прав администратора был отменён или завершился ошибкой.`n`n" +
                          "Запустите файл вручную: правый клик по HostsManager.ps1 -> «Выполнить с помощью PowerShell».") `
                -Mode Info -OkText 'Понятно')
        }
    }
    elseif ($restart) {
        [void](Show-DarkDialog `
            -Title 'Запустите файл вручную' `
            -Message ('Скрипт запущен не из файла, поэтому автоматический перезапуск невозможен. ' +
                      'Сохраните HostsManager.ps1 на диск и запустите его от имени администратора.') `
            -Mode Info -OkText 'Понятно')
    }
    Restore-HostConsole
    exit
}

# ============================================================
#  6. Проверка наличия файла hosts
# ============================================================

if (-not (Test-Path -LiteralPath $script:HostsPath)) {
    [void](Show-DarkDialog `
        -Title 'Файл hosts не найден' `
        -Message "Не удалось найти системный файл по пути:`n$($script:HostsPath)`n`nПроверьте целостность системы." `
        -Mode Info -OkText 'Закрыть')
    Restore-HostConsole
    exit 1
}

# ============================================================
#  7. Работа с файлом hosts: кодировка, чтение, запись, DNS
# ============================================================

function Get-HostsEncoding {
    <# Определяет кодировку файла hosts, чтобы не испортить кириллицу в комментариях. #>
    $bytes = [System.IO.File]::ReadAllBytes($script:HostsPath)

    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return (New-Object System.Text.UTF8Encoding($true))
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return [System.Text.Encoding]::Unicode
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        return [System.Text.Encoding]::BigEndianUnicode
    }

    # BOM отсутствует: если байты корректны как UTF-8 - пишем UTF-8, иначе системная ANSI.
    try {
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $null = $strictUtf8.GetString($bytes)
        return (New-Object System.Text.UTF8Encoding($false))
    } catch {
        # В PowerShell 7 (Core) Encoding.Default — это UTF-8, а не ANSI,
        # поэтому для файла без BOM берём системную кодовую страницу явно.
        if ($PSVersionTable.PSEdition -eq 'Core') {
            try {
                return [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage)
            } catch { }
        }
        return [System.Text.Encoding]::Default
    }
}

function Read-HostsLines {
    if (-not (Test-Path -LiteralPath $script:HostsPath)) {
        throw "Файл hosts не найден: $($script:HostsPath)"
    }
    $encoding = Get-HostsEncoding
    return @([System.IO.File]::ReadAllLines($script:HostsPath, $encoding))
}

function Clear-DnsCache {
    <# Очищает DNS-кэш; при недоступности cmdlet использует ipconfig /flushdns. #>
    try {
        Clear-DnsClientCache -ErrorAction Stop
        return $true
    } catch {
        try {
            $null = & ipconfig.exe /flushdns 2>&1
            return ($LASTEXITCODE -eq 0)
        } catch {
            return $false
        }
    }
}

function Invoke-HostsMutation {
    <#
        Единая точка записи в hosts:
          Kind = Lines -> перезаписать файл массивом строк из Payload;
          Kind = Copy  -> заменить файл копией из Payload.
        Снимает/возвращает атрибут ReadOnly, очищает DNS-кэш, обновляет интерфейс.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('Lines', 'Copy')][string]$Kind,
        [Parameter(Mandatory)][object]$Payload,
        [Parameter(Mandatory)][string]$SuccessMessage
    )

    try {
        $item = Get-Item -LiteralPath $script:HostsPath -Force -ErrorAction Stop
    } catch {
        Set-Status -Message "Нет доступа к hosts: $($_.Exception.Message)" -Kind 'Error'
        return $false
    }

    $wasReadOnly = $item.IsReadOnly

    $tempPath = $script:HostsPath + '.hostsmanager.tmp'

    try {
        if ($wasReadOnly) { $item.IsReadOnly = $false }

        # Основной путь: временный файл рядом с hosts + атомарная подмена.
        # Если во временный файл писать нельзя (антивирус запрещает создавать
        # файлы в папке etc), откатываемся к прямой записи - как было раньше.
        $atomicDone = $false
        try {
            # Убираем хвост от прошлой неудачной записи (он мог остаться read-only).
            if ([System.IO.File]::Exists($tempPath)) {
                try { (Get-Item -LiteralPath $tempPath -Force).IsReadOnly = $false } catch { }
                try { [System.IO.File]::Delete($tempPath) } catch { }
            }

            if ($Kind -eq 'Lines') {
                $encoding = Get-HostsEncoding
                [System.IO.File]::WriteAllLines($tempPath, [string[]]$Payload, $encoding)
            } else {
                [System.IO.File]::Copy([string]$Payload, $tempPath, $true)
                # Копия профиля может унаследовать ReadOnly — для замены он мешает.
                $tempItem = Get-Item -LiteralPath $tempPath -Force
                if ($tempItem.IsReadOnly) { $tempItem.IsReadOnly = $false }
            }

            try {
                # [NullString]::Value обязателен: PowerShell 5.1 иначе передаёт пустой путь.
                [System.IO.File]::Replace($tempPath, $script:HostsPath, [NullString]::Value)
            } catch {
                # Fallback для файловых систем, где атомарная замена недоступна.
                [System.IO.File]::Copy($tempPath, $script:HostsPath, $true)
            }
            $atomicDone = $true
        } catch {
            $atomicDone = $false
        }

        if (-not $atomicDone) {
            if ($Kind -eq 'Lines') {
                $encoding = Get-HostsEncoding
                [System.IO.File]::WriteAllLines($script:HostsPath, [string[]]$Payload, $encoding)
            } else {
                [System.IO.File]::Copy([string]$Payload, $script:HostsPath, $true)
            }
        }
    } catch {
        Set-Status -Message "Ошибка записи: $($_.Exception.Message)" -Kind 'Error'
        [void](Show-DarkDialog -Title 'Ошибка записи' `
            -Message ("Не удалось изменить файл hosts.`n`n$($_.Exception.Message)`n`n" +
                      'Убедитесь, что файл не заблокирован антивирусом или другим приложением.') `
            -Mode Info -OkText 'Закрыть')
        return $false
    } finally {
        if ([System.IO.File]::Exists($tempPath)) {
            try { (Get-Item -LiteralPath $tempPath -Force).IsReadOnly = $false } catch { }
            try { [System.IO.File]::Delete($tempPath) } catch { }
        }

        # Возвращаем атрибут ReadOnly в исходное состояние (в том числе снимаем его,
        # если копируемый профиль был помечен «только для чтения»).
        try {
            $fresh = Get-Item -LiteralPath $script:HostsPath -Force
            $fresh.IsReadOnly = $wasReadOnly
        } catch {
            # Не критично: вернуть атрибут не удалось.
        }
    }

    # Очистка DNS-кэша и обновление интерфейса
    $dnsOk = Clear-DnsCache
    Refresh-Editor

    $dnsText = if ($dnsOk) { 'DNS-кэш очищен.' } else { 'DNS-кэш очистить не удалось (ipconfig /flushdns).' }
    $statusKind = if ($dnsOk) { 'Success' } else { 'Warning' }
    Set-Status -Message ("{0} {1}" -f $SuccessMessage, $dnsText) -Kind $statusKind
    if ($script:StatusRight) {
        $script:StatusRight.Text = "Последнее изменение: $(Get-Date -Format 'HH:mm:ss')"
    }
    return $true
}

function Save-HostsLines {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory)][string]$SuccessMessage
    )
    return Invoke-HostsMutation -Kind 'Lines' -Payload $Lines -SuccessMessage $SuccessMessage
}

function Copy-HostsFile {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$SuccessMessage
    )
    return Invoke-HostsMutation -Kind 'Copy' -Payload $Source -SuccessMessage $SuccessMessage
}

function Initialize-HostsBackup {
    <# Создаёт hosts.bak при первом запуске, если копии ещё нет. #>
    if (Test-Path -LiteralPath $script:BackupPath) {
        return 'exists'
    }
    Copy-Item -LiteralPath $script:HostsPath -Destination $script:BackupPath -Force -ErrorAction Stop
    return 'created'
}

# ============================================================
#  8. Парсинг записей hosts
# ============================================================

$script:BrushActive   = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(110, 255, 114))
$script:BrushMuted    = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(167, 176, 183))
$script:BrushTextSoft = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(215, 222, 227))
$script:BrushActive.Freeze()
$script:BrushMuted.Freeze()
$script:BrushTextSoft.Freeze()
$script:SelectAfterRefresh = $null

function Get-HostsEntries {
    <#
        Возвращает только реальные записи hosts (IP + домены).
        Чистые комментарии и пустые строки в таблицу не попадают.
        Index - номер строки в файле, используется для удаления/переключения.
    #>
    $entries = New-Object System.Collections.Generic.List[object]
    $lines = @(Read-HostsLines)

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch $script:EntryPattern) { continue }

        $isCommented = $false
        if ($Matches.ContainsKey('comment')) {
            $isCommented = -not [string]::IsNullOrWhiteSpace($Matches['comment'])
        }
        $ip = $Matches['ip']
        $hostList = @($Matches['hosts'] -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

        # rhino.acme.com и x.acme.com — стандартные примеры Windows в комментариях,
        # а не реальные записи. Скрываем строку, если кроме них в ней ничего нет.
        $templateHosts = @('rhino.acme.com', 'x.acme.com')
        if (@($hostList | Where-Object { $templateHosts -notcontains $_ }).Count -eq 0) { continue }

        $entries.Add([PSCustomObject]@{
            Index       = $i
            RawLine     = $line
            Status      = if ($isCommented) { 'Закомментирован' } else { 'Активен' }
            StatusBrush = if ($isCommented) { $script:BrushMuted } else { $script:BrushActive }
            IP          = $ip
            Hosts       = ($hostList -join ', ')
            HostList    = $hostList
        })
    }

    return $entries.ToArray()
}

function Set-Status {
    <# Обновляет сообщение в статус-баре; безопасно вызывается до создания окна. #>
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error')][string]$Kind = 'Info'
    )

    if (-not $script:StatusText) { return }

    $colors = @{
        Info    = '#5BDCFF'
        Success = '#6EFF72'
        Warning = '#FFC83D'
        Error   = '#FF6B6B'
    }
    try {
        $color = [System.Windows.Media.ColorConverter]::ConvertFromString($colors[$Kind])
        $brush = New-Object System.Windows.Media.SolidColorBrush($color)
        $brush.Freeze()
        $script:StatusDot.Fill = $brush
        $script:StatusText.Foreground = if ($Kind -eq 'Warning' -or $Kind -eq 'Error') { $brush } else { $script:BrushTextSoft }
        $script:StatusText.Text = $Message
        # Подсказка показывает полный текст, если он обрезан по ширине окна
        $script:StatusText.ToolTip = $Message
    } catch { }
}

# ============================================================
#  9. Основное окно: XAML (тёмная тема в духе WinUtil)
# ============================================================

$script:MainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:sys="clr-namespace:System;assembly=mscorlib"
        Title="Hosts Manager"
        Width="1120" Height="800" MinWidth="940" MinHeight="680"
        WindowStartupLocation="CenterScreen"
        Background="#232629" Foreground="#F7F7F7"
        FontFamily="Segoe UI" FontSize="13"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">

    <Window.Resources>
        <!-- ===== Палитра ===== -->
        <SolidColorBrush x:Key="ClrAccent" Color="#2E77FF"/>
        <SolidColorBrush x:Key="ClrAccentHover" Color="#4A8CFF"/>
        <SolidColorBrush x:Key="ClrText" Color="#F7F7F7"/>
        <SolidColorBrush x:Key="ClrMuted" Color="#A7B0B7"/>
        <SolidColorBrush x:Key="ClrBorder" Color="#2F373D"/>

        <!-- ===== Карточка ===== -->
        <Style x:Key="CardStyle" TargetType="Border">
            <Setter Property="Background" Value="#282D31"/>
            <Setter Property="BorderBrush" Value="{StaticResource ClrBorder}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="12"/>
        </Style>

        <Style x:Key="CardTitle" TargetType="TextBlock">
            <Setter Property="FontSize" Value="13.5"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Foreground" Value="#FFFFFF"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
        </Style>

        <Style x:Key="FieldLabel" TargetType="TextBlock">
            <Setter Property="FontSize" Value="10.5"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Foreground" Value="#A7B0B7"/>
        </Style>

        <!-- ===== Кнопки ===== -->
        <Style x:Key="ButtonBase" TargetType="Button">
            <Setter Property="Background" Value="#1E3747"/>
            <Setter Property="BorderBrush" Value="#2F4A59"/>
            <Setter Property="Foreground" Value="{StaticResource ClrText}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="15,8"/>
            <Setter Property="FontSize" Value="12.5"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="SnapsToDevicePixels" Value="True"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="3" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                              RecognizesAccessKey="True"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#3B4252"/>
                                <Setter TargetName="Bd" Property="BorderBrush" Value="#4C5D6B"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#162D3B"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.4"/>
                                <Setter Property="Cursor" Value="Arrow"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="AccentButton" TargetType="Button" BasedOn="{StaticResource ButtonBase}">
            <Setter Property="Foreground" Value="#FFFFFF"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="#2E77FF" BorderBrush="#2E77FF"
                                BorderThickness="1" CornerRadius="3" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#4A8CFF"/>
                                <Setter TargetName="Bd" Property="BorderBrush" Value="#4A8CFF"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#1F5FD0"/>
                                <Setter TargetName="Bd" Property="BorderBrush" Value="#1F5FD0"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.4"/>
                                <Setter Property="Cursor" Value="Arrow"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource ButtonBase}">
            <Setter Property="Background" Value="#2A1E1E"/>
            <Setter Property="BorderBrush" Value="#5A3030"/>
            <Setter Property="Foreground" Value="#FF8A8A"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="1" CornerRadius="3" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#3A2424"/>
                                <Setter TargetName="Bd" Property="BorderBrush" Value="#7A3A3A"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#221818"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.4"/>
                                <Setter Property="Cursor" Value="Arrow"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="GhostButton" TargetType="Button" BasedOn="{StaticResource ButtonBase}">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderBrush" Value="#3A444B"/>
            <Setter Property="Foreground" Value="#D7DEE3"/>
        </Style>

        <Style x:Key="IconButton" TargetType="Button" BasedOn="{StaticResource GhostButton}">
            <Setter Property="Width" Value="30"/>
            <Setter Property="Height" Value="30"/>
            <Setter Property="Padding" Value="0"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="ToolTipService.InitialShowDelay" Value="250"/>
        </Style>

        <!-- ===== Поле ввода ===== -->
        <Style x:Key="InputBox" TargetType="TextBox">
            <Setter Property="Background" Value="#1B1F22"/>
            <Setter Property="Foreground" Value="#F7F7F7"/>
            <Setter Property="BorderBrush" Value="#2F4A59"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="11,8"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="CaretBrush" Value="#F7F7F7"/>
            <Setter Property="SelectionBrush" Value="#2E77FF"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="3">
                            <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"
                                          VerticalAlignment="Stretch" Focusable="False"
                                          HorizontalScrollBarVisibility="{TemplateBinding HorizontalScrollBarVisibility}"
                                          VerticalScrollBarVisibility="{TemplateBinding VerticalScrollBarVisibility}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter TargetName="Bd" Property="BorderBrush" Value="#2E77FF"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="BorderBrush" Value="#4C5D6B"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- ===== Вкладки ===== -->
        <Style TargetType="TabControl">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="0"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="VerticalContentAlignment" Value="Stretch"/>
        </Style>

        <Style TargetType="TabItem">
            <Setter Property="Foreground" Value="#B9C2C9"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="VerticalContentAlignment" Value="Stretch"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TabItem">
                        <Border x:Name="Bd" Background="Transparent" CornerRadius="3"
                                Padding="20,9" Margin="0,0,8,0">
                            <ContentPresenter ContentSource="Header" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#2C3338"/>
                            </Trigger>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#5E81AC"/>
                                <Setter Property="Foreground" Value="#FFFFFF"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Foreground" Value="#FFFFFF"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <!-- ===== Тонкий скроллбар ===== -->
        <Style x:Key="ScrollThumb" TargetType="Thumb">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Thumb">
                        <Border Background="#3B4252" CornerRadius="3" Margin="2"/>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="ScrollBar">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Width" Value="10"/>
            <Setter Property="MinWidth" Value="10"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ScrollBar">
                        <Grid Background="Transparent">
                            <Track x:Name="PART_Track" IsDirectionReversed="True">
                                <Track.DecreaseRepeatButton>
                                    <RepeatButton Command="ScrollBar.PageUpCommand" Focusable="False"
                                                  IsTabStop="False" Opacity="0"/>
                                </Track.DecreaseRepeatButton>
                                <Track.Thumb>
                                    <Thumb Style="{StaticResource ScrollThumb}"/>
                                </Track.Thumb>
                                <Track.IncreaseRepeatButton>
                                    <RepeatButton Command="ScrollBar.PageDownCommand" Focusable="False"
                                                  IsTabStop="False" Opacity="0"/>
                                </Track.IncreaseRepeatButton>
                            </Track>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="Orientation" Value="Horizontal">
                                <Setter Property="Width" Value="{x:Static sys:Double.NaN}"/>
                                <Setter Property="MinWidth" Value="0"/>
                                <Setter Property="Height" Value="10"/>
                                <Setter TargetName="PART_Track" Property="IsDirectionReversed" Value="False"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- ===== DataGrid ===== -->
        <Style TargetType="DataGridColumnHeader">
            <Setter Property="Background" Value="#212528"/>
            <Setter Property="Foreground" Value="#A7B0B7"/>
            <Setter Property="FontSize" Value="10.5"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="14,10"/>
            <Setter Property="BorderBrush" Value="#2D3338"/>
            <Setter Property="BorderThickness" Value="0,0,0,1"/>
            <Setter Property="HorizontalContentAlignment" Value="Left"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="DataGridColumnHeader">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter VerticalAlignment="Center"
                                              HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="DataGridCell">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Foreground" Value="#F7F7F7"/>
            <Setter Property="Padding" Value="14,0"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="DataGridCell">
                        <Border Background="Transparent" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True">
                            <ContentPresenter VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="DataGridRow">
            <Setter Property="Background" Value="#1E2225"/>
            <Setter Property="Foreground" Value="#F7F7F7"/>
            <Setter Property="MinHeight" Value="40"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="SnapsToDevicePixels" Value="True"/>
            <Style.Triggers>
                <Trigger Property="AlternationIndex" Value="1">
                    <Setter Property="Background" Value="#1B1F22"/>
                </Trigger>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#2C3237"/>
                </Trigger>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#22384A"/>
                    <Setter Property="Foreground" Value="#FFFFFF"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style TargetType="DataGrid">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#F7F7F7"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="GridLinesVisibility" Value="Horizontal"/>
            <Setter Property="HorizontalGridLinesBrush" Value="#1E3747"/>
            <Setter Property="HeadersVisibility" Value="Column"/>
            <Setter Property="RowHeaderWidth" Value="0"/>
            <Setter Property="CanUserAddRows" Value="False"/>
            <Setter Property="CanUserDeleteRows" Value="False"/>
            <Setter Property="CanUserResizeRows" Value="False"/>
            <Setter Property="CanUserSortColumns" Value="False"/>
            <Setter Property="CanUserReorderColumns" Value="False"/>
            <Setter Property="IsReadOnly" Value="True"/>
            <Setter Property="SelectionMode" Value="Single"/>
            <Setter Property="SelectionUnit" Value="FullRow"/>
            <Setter Property="AutoGenerateColumns" Value="False"/>
            <Setter Property="AlternationCount" Value="2"/>
            <Setter Property="ColumnHeaderHeight" Value="36"/>
            <Setter Property="RowHeight" Value="40"/>
            <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
            <Setter Property="HorizontalScrollBarVisibility" Value="Auto"/>
        </Style>

        <!-- ===== ListBox (профили) ===== -->
        <Style TargetType="ListBox">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Disabled"/>
            <Setter Property="ScrollViewer.VerticalScrollBarVisibility" Value="Auto"/>
        </Style>

        <Style TargetType="ListBoxItem">
            <Setter Property="Foreground" Value="#F7F7F7"/>
            <Setter Property="Margin" Value="0,2"/>
            <Setter Property="Padding" Value="0"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ListBoxItem">
                        <Border x:Name="Bd" Background="Transparent" BorderBrush="Transparent"
                                BorderThickness="1" CornerRadius="3" Padding="13,10">
                            <ContentPresenter HorizontalAlignment="Stretch"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#2A3034"/>
                            </Trigger>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#1E3747"/>
                                <Setter TargetName="Bd" Property="BorderBrush" Value="#2F5A70"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- ================= Шапка ================= -->
        <Border Grid.Row="0" Background="#1B1F22" BorderBrush="#2F373D"
                BorderThickness="0,0,0,1" Padding="24,14">
            <Grid>
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <Border Width="40" Height="40" CornerRadius="6" Background="#2E77FF">
                        <TextBlock Text="H" FontSize="20" FontWeight="Bold" Foreground="#FFFFFF"
                                   HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <StackPanel Margin="14,0,0,0" VerticalAlignment="Center">
                        <TextBlock Text="HOSTS MANAGER" FontSize="17" FontWeight="Bold"
                                   Foreground="#FFFFFF"/>
                        <TextBlock Text="Управление файлом hosts · WPF" FontSize="11.5"
                                   Foreground="#A7B0B7" Margin="0,3,0,0"/>
                    </StackPanel>
                </StackPanel>

                <StackPanel HorizontalAlignment="Right" Orientation="Horizontal" VerticalAlignment="Center">
                    <Border Background="#14251A" BorderBrush="#27502F" BorderThickness="1"
                            CornerRadius="999" Padding="10,4" VerticalAlignment="Center">
                        <StackPanel Orientation="Horizontal">
                            <Ellipse Width="7" Height="7" Fill="#6EFF72" Margin="0,0,6,0" VerticalAlignment="Center"/>
                            <TextBlock Text="ADMIN" FontSize="10.5" FontWeight="SemiBold" Foreground="#8BE89A"/>
                        </StackPanel>
                    </Border>
                    <StackPanel Margin="16,0,0,0" VerticalAlignment="Center">
                        <TextBlock Text="СИСТЕМНЫЙ ФАЙЛ" Style="{StaticResource FieldLabel}" HorizontalAlignment="Right"/>
                        <TextBlock x:Name="PathLabel" Text="C:\Windows\System32\drivers\etc\hosts"
                                   FontSize="10.5" Foreground="#96A0A7" Margin="0,3,0,0"/>
                    </StackPanel>
                </StackPanel>
            </Grid>
        </Border>

        <!-- ================= Вкладки ================= -->
        <TabControl x:Name="MainTabs" Grid.Row="1" Margin="24,14,24,0">
            <TabItem Header="Редактор">
                <Grid Margin="0,14,0,0">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <!-- Таблица записей -->
                    <Border Grid.Row="0" Style="{StaticResource CardStyle}" Padding="0">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                            </Grid.RowDefinitions>

                            <Grid Margin="18,14,18,12">
                                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                                    <TextBlock Text="Записи hosts" Style="{StaticResource CardTitle}"/>
                                    <Border Background="#2F373D" CornerRadius="999" Padding="9,3"
                                            Margin="10,0,0,0" VerticalAlignment="Center">
                                        <TextBlock x:Name="EntryCount" Text="0 записей" FontSize="10.5"
                                                   Foreground="#B9C2C9"/>
                                    </Border>
                                </StackPanel>
                                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                                    <Button x:Name="BtnRefresh" Style="{StaticResource IconButton}"
                                            ToolTip="Обновить список">
                                        <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE72C;" FontSize="14"/>
                                    </Button>
                                    <Button x:Name="BtnNotepad" Style="{StaticResource IconButton}" Margin="6,0,0,0"
                                            ToolTip="Открыть hosts в Блокноте">
                                        <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE70F;" FontSize="14"/>
                                    </Button>
                                    <Border Width="1" Background="#2F373D" Margin="10,5"/>
                                    <Button x:Name="BtnResetDefault" Style="{StaticResource GhostButton}"
                                            ToolTip="Заменить hosts заводским шаблоном Windows (без пользовательских записей)">
                                        <StackPanel Orientation="Horizontal">
                                            <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE713;" FontSize="12"
                                                       Margin="0,0,7,0" VerticalAlignment="Center"/>
                                            <TextBlock Text="Сбросить к заводскому" VerticalAlignment="Center"/>
                                        </StackPanel>
                                    </Button>
                                    <Button x:Name="BtnRestore" Style="{StaticResource DangerButton}" Margin="8,0,0,0"
                                            ToolTip="Вернуть копию hosts, снятую при первом запуске утилиты">
                                        <StackPanel Orientation="Horizontal">
                                            <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE7A7;" FontSize="12"
                                                       Margin="0,0,7,0" VerticalAlignment="Center"/>
                                            <TextBlock Text="Откатить из hosts.bak" VerticalAlignment="Center"/>
                                        </StackPanel>
                                    </Button>
                                </StackPanel>
                            </Grid>

                            <Grid Grid.Row="1">
                                <DataGrid x:Name="GridEntries">
                                    <DataGrid.Columns>
                                        <DataGridTemplateColumn Header="СТАТУС" Width="200">
                                            <DataGridTemplateColumn.CellTemplate>
                                                <DataTemplate>
                                                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                                                        <Ellipse Width="7" Height="7" Fill="{Binding StatusBrush}"
                                                                 Margin="0,0,9,0" VerticalAlignment="Center"/>
                                                        <TextBlock Text="{Binding Status}" Foreground="{Binding StatusBrush}"
                                                                   FontSize="12" VerticalAlignment="Center"/>
                                                    </StackPanel>
                                                </DataTemplate>
                                            </DataGridTemplateColumn.CellTemplate>
                                        </DataGridTemplateColumn>
                                        <DataGridTextColumn Header="IP-АДРЕС" Binding="{Binding IP}" Width="190"/>
                                        <DataGridTextColumn Header="ДОМЕНЫ" Binding="{Binding Hosts}" Width="*"/>
                                    </DataGrid.Columns>
                                </DataGrid>

                                <StackPanel x:Name="EditorEmptyState" Visibility="Collapsed"
                                            HorizontalAlignment="Center" VerticalAlignment="Center"
                                            IsHitTestVisible="False">
                                    <TextBlock Text="Записей пока нет" FontSize="14" Foreground="#A7B0B7"
                                               HorizontalAlignment="Center"/>
                                    <TextBlock Text="Добавьте первую запись в форме ниже" FontSize="11.5"
                                               Foreground="#7B858C" Margin="0,6,0,0" HorizontalAlignment="Center"/>
                                </StackPanel>
                            </Grid>
                        </Grid>
                    </Border>

                    <!-- Действия с выбранной записью -->
                    <Border Grid.Row="1" Style="{StaticResource CardStyle}" Padding="18,12" Margin="0,12,0,12">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                                <Border Background="#1E3747" CornerRadius="4" Width="26" Height="26" VerticalAlignment="Center">
                                    <TextBlock Text="›" Foreground="#5BDCFF" FontSize="17" FontWeight="Bold"
                                               HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                </Border>
                                <TextBlock x:Name="SelectionHint" Text="Выберите запись в таблице, чтобы изменить её статус или удалить."
                                           FontSize="12" Foreground="#B9C2C9" Margin="11,0,0,0" VerticalAlignment="Center"
                                           TextTrimming="CharacterEllipsis" MaxWidth="520"/>
                            </StackPanel>
                            <StackPanel Grid.Column="1" Orientation="Horizontal">
                                <Button x:Name="BtnToggle" Style="{StaticResource ButtonBase}"
                                        Margin="0,0,8,0" IsEnabled="False">
                                    <StackPanel Orientation="Horizontal">
                                        <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE7E8;" FontSize="11"
                                                   Margin="0,0,6,0" VerticalAlignment="Center"/>
                                        <TextBlock Text="Переключить статус" VerticalAlignment="Center"/>
                                    </StackPanel>
                                </Button>
                                <Button x:Name="BtnDelete" Style="{StaticResource DangerButton}" IsEnabled="False">
                                    <StackPanel Orientation="Horizontal">
                                        <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE74D;" FontSize="11"
                                                   Margin="0,0,6,0" VerticalAlignment="Center"/>
                                        <TextBlock Text="Удалить" VerticalAlignment="Center"/>
                                    </StackPanel>
                                </Button>
                            </StackPanel>
                        </Grid>
                    </Border>

                    <!-- Добавление записи -->
                    <Border Grid.Row="2" Style="{StaticResource CardStyle}" Padding="18,14">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <StackPanel Orientation="Horizontal">
                                <StackPanel>
                                    <TextBlock Text="IP-АДРЕС" Style="{StaticResource FieldLabel}"/>
                                    <TextBox x:Name="TxtIp" Style="{StaticResource InputBox}" Width="170" Margin="0,6,0,0"
                                             ToolTip="Например: 127.0.0.1"/>
                                </StackPanel>
                                <StackPanel Margin="14,0,0,0">
                                    <TextBlock Text="ДОМЕН" Style="{StaticResource FieldLabel}"/>
                                    <TextBox x:Name="TxtDomain" Style="{StaticResource InputBox}" Width="210" Margin="0,6,0,0"
                                             ToolTip="Например: example.com"/>
                                </StackPanel>
                                <StackPanel VerticalAlignment="Bottom" Margin="14,0,0,0" Orientation="Horizontal">
                                    <Button x:Name="BtnAdd" Style="{StaticResource AccentButton}" Padding="18,9">
                                        <StackPanel Orientation="Horizontal">
                                            <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE710;" FontSize="12"
                                                       Margin="0,0,7,0" VerticalAlignment="Center"/>
                                            <TextBlock Text="Добавить запись" VerticalAlignment="Center"/>
                                        </StackPanel>
                                    </Button>
                                    <Button x:Name="BtnBulk" Style="{StaticResource GhostButton}"
                                            Padding="14,9" Margin="10,0,0,0"
                                            ToolTip="Вставить сразу много записей: по одной в строке">
                                        <StackPanel Orientation="Horizontal">
                                            <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE8FD;" FontSize="12"
                                                       Margin="0,0,6,0" VerticalAlignment="Center"/>
                                            <TextBlock Text="Списком…" VerticalAlignment="Center"/>
                                        </StackPanel>
                                    </Button>
                                </StackPanel>
                            </StackPanel>
                            <StackPanel Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="14,0,0,12">
                                <TextBlock Text="«Списком…» — много строк сразу" FontSize="10.5"
                                           Foreground="#8A949B" HorizontalAlignment="Right"
                                           TextTrimming="CharacterEllipsis"
                                           ToolTip="Вставка большого списка записей за один раз"/>
                                <TextBlock Text="Формат: IP + домен" FontSize="10.5"
                                           Foreground="#6E7880" HorizontalAlignment="Right" Margin="0,4,0,0"
                                           TextTrimming="CharacterEllipsis"/>
                            </StackPanel>
                        </Grid>
                    </Border>
                </Grid>
            </TabItem>

            <TabItem Header="Профили">
                <Grid Margin="0,14,0,0">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <Border Grid.Row="0" Style="{StaticResource CardStyle}" Padding="18,15">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <StackPanel Grid.Column="0" Margin="0,0,16,0" VerticalAlignment="Center">
                                <TextBlock Text="Профили конфигурации" Style="{StaticResource CardTitle}"/>
                                <TextBlock Text="Сохраняйте наборы записей и переключайтесь между ними одним нажатием."
                                           FontSize="11.5" Foreground="#A7B0B7" Margin="0,6,0,0"
                                           TextTrimming="CharacterEllipsis"/>
                            </StackPanel>
                            <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                                <Button x:Name="BtnOpenProfilesFolder"
                                        Style="{StaticResource GhostButton}" Margin="0,0,8,0">
                                    <StackPanel Orientation="Horizontal">
                                        <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE8B7;" FontSize="11"
                                                   Margin="0,0,6,0" VerticalAlignment="Center"/>
                                        <TextBlock Text="Папка профилей" VerticalAlignment="Center"/>
                                    </StackPanel>
                                </Button>
                                <Button x:Name="BtnSaveProfile" Style="{StaticResource AccentButton}">
                                    <StackPanel Orientation="Horizontal">
                                        <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE74E;" FontSize="11"
                                                   Margin="0,0,6,0" VerticalAlignment="Center"/>
                                        <TextBlock Text="Сохранить профиль" VerticalAlignment="Center"/>
                                    </StackPanel>
                                </Button>
                            </StackPanel>
                        </Grid>
                    </Border>

                    <Border Grid.Row="1" Style="{StaticResource CardStyle}" Padding="0" Margin="0,12,0,12">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                            </Grid.RowDefinitions>
                            <Grid Margin="18,14,18,10">
                                <TextBlock Text="Сохранённые профили" Style="{StaticResource CardTitle}"/>
                                <TextBlock x:Name="ProfileDirLabel" HorizontalAlignment="Right" VerticalAlignment="Center"
                                           FontSize="10.5" Foreground="#8A949B" TextTrimming="CharacterEllipsis"
                                           MaxWidth="560"/>
                            </Grid>
                            <Grid Grid.Row="1">
                                <ListBox x:Name="ListProfiles" Margin="8,0,8,10">
                                    <ListBox.ItemTemplate>
                                        <DataTemplate>
                                            <Grid>
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="Auto"/>
                                                </Grid.ColumnDefinitions>
                                                <StackPanel>
                                                    <TextBlock Text="{Binding Name}" FontSize="13" FontWeight="SemiBold"
                                                               Foreground="#FFFFFF"/>
                                                    <TextBlock Text="{Binding Info}" FontSize="10.5"
                                                               Foreground="#A7B0B7" Margin="0,4,0,0"/>
                                                </StackPanel>
                                                <TextBlock Grid.Column="1" Text="{Binding Size}" FontSize="10.5"
                                                           Foreground="#8A949B" VerticalAlignment="Center"/>
                                            </Grid>
                                        </DataTemplate>
                                    </ListBox.ItemTemplate>
                                </ListBox>
                                <StackPanel x:Name="ProfilesEmptyState" Visibility="Collapsed"
                                            HorizontalAlignment="Center" VerticalAlignment="Center"
                                            IsHitTestVisible="False">
                                    <TextBlock Text="Профилей пока нет" FontSize="14" Foreground="#A7B0B7"
                                               HorizontalAlignment="Center"/>
                                    <TextBlock Text="Нажмите «Сохранить профиль»" FontSize="11.5"
                                               Foreground="#7B858C" Margin="0,6,0,0" HorizontalAlignment="Center"/>
                                </StackPanel>
                            </Grid>
                        </Grid>
                    </Border>

                    <Border Grid.Row="2" Style="{StaticResource CardStyle}" Padding="18,12">
                        <Grid>
                            <TextBlock x:Name="ProfileHint" Text="Выберите профиль из списка."
                                       FontSize="12" Foreground="#B9C2C9" VerticalAlignment="Center"
                                       TextTrimming="CharacterEllipsis" MaxWidth="520"/>
                            <StackPanel HorizontalAlignment="Right" Orientation="Horizontal">
                                <Button x:Name="BtnDeleteProfile" Style="{StaticResource DangerButton}"
                                        Margin="0,0,8,0" IsEnabled="False">
                                    <StackPanel Orientation="Horizontal">
                                        <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE74D;" FontSize="11"
                                                   Margin="0,0,6,0" VerticalAlignment="Center"/>
                                        <TextBlock Text="Удалить профиль" VerticalAlignment="Center"/>
                                    </StackPanel>
                                </Button>
                                <Button x:Name="BtnActivateProfile" Style="{StaticResource AccentButton}" IsEnabled="False">
                                    <StackPanel Orientation="Horizontal">
                                        <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE8FB;" FontSize="11"
                                                   Margin="0,0,6,0" VerticalAlignment="Center"/>
                                        <TextBlock Text="Активировать выбранный" VerticalAlignment="Center"/>
                                    </StackPanel>
                                </Button>
                            </StackPanel>
                        </Grid>
                    </Border>
                </Grid>
            </TabItem>
        </TabControl>

        <!-- ================= Статус-бар ================= -->
        <Border Grid.Row="2" Background="#1B1F22" BorderBrush="#2F373D"
                BorderThickness="0,1,0,0" Padding="24,0">
            <Grid Height="44">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Grid Grid.Column="0" VerticalAlignment="Center" Margin="0,0,16,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <Ellipse x:Name="StatusDot" Width="8" Height="8" Fill="#2E77FF"
                             Margin="0,0,9,0" VerticalAlignment="Center"/>
                    <TextBlock x:Name="StatusText" Grid.Column="1" Text="Запуск…"
                               FontSize="12" Foreground="#D7DEE3" VerticalAlignment="Center"
                               TextTrimming="CharacterEllipsis"/>
                </Grid>
                <TextBlock x:Name="StatusRight" Grid.Column="1" HorizontalAlignment="Right"
                           VerticalAlignment="Center" FontSize="10.5" Foreground="#7B858C"
                           Text="Clear-DnsClientCache выполняется автоматически"/>
            </Grid>
        </Border>
    </Grid>
</Window>
'@

# ============================================================
#  10. Создание окна и привязка элементов
# ============================================================

$script:Window = Load-Xaml $script:MainXaml

function Find-UiElement {
    param([Parameter(Mandatory)][string]$Name)
    $element = $script:Window.FindName($Name)
    if ($null -eq $element) {
        throw "Элемент интерфейса не найден: $Name"
    }
    return $element
}

$script:PathLabel            = Find-UiElement 'PathLabel'
$script:MainTabs             = Find-UiElement 'MainTabs'
$script:EntryCount           = Find-UiElement 'EntryCount'
$script:BtnRefresh           = Find-UiElement 'BtnRefresh'
$script:BtnNotepad           = Find-UiElement 'BtnNotepad'
$script:BtnResetDefault      = Find-UiElement 'BtnResetDefault'
$script:BtnRestore           = Find-UiElement 'BtnRestore'
$script:GridEntries          = Find-UiElement 'GridEntries'
$script:EditorEmptyState     = Find-UiElement 'EditorEmptyState'
$script:SelectionHint        = Find-UiElement 'SelectionHint'
$script:BtnToggle            = Find-UiElement 'BtnToggle'
$script:BtnDelete            = Find-UiElement 'BtnDelete'
$script:TxtIp                = Find-UiElement 'TxtIp'
$script:TxtDomain            = Find-UiElement 'TxtDomain'
$script:BtnAdd               = Find-UiElement 'BtnAdd'
$script:BtnBulk              = Find-UiElement 'BtnBulk'
$script:BtnOpenProfilesFolder = Find-UiElement 'BtnOpenProfilesFolder'
$script:BtnSaveProfile       = Find-UiElement 'BtnSaveProfile'
$script:ProfileDirLabel      = Find-UiElement 'ProfileDirLabel'
$script:ListProfiles         = Find-UiElement 'ListProfiles'
$script:ProfilesEmptyState   = Find-UiElement 'ProfilesEmptyState'
$script:ProfileHint          = Find-UiElement 'ProfileHint'
$script:BtnDeleteProfile     = Find-UiElement 'BtnDeleteProfile'
$script:BtnActivateProfile   = Find-UiElement 'BtnActivateProfile'
$script:StatusDot            = Find-UiElement 'StatusDot'
$script:StatusText           = Find-UiElement 'StatusText'
$script:StatusRight          = Find-UiElement 'StatusRight'

$script:PathLabel.Text = $script:HostsPath
$script:PathLabel.ToolTip = $script:HostsPath

# ============================================================
#  11. Обновление интерфейса
# ============================================================

function Format-EntriesCount {
    param([int]$Count)
    $mod100 = $Count % 100
    $mod10  = $Count % 10
    if ($mod100 -ge 11 -and $mod100 -le 14) { $word = 'записей' }
    elseif ($mod10 -eq 1) { $word = 'запись' }
    elseif ($mod10 -ge 2 -and $mod10 -le 4) { $word = 'записи' }
    else { $word = 'записей' }
    return "$Count $word"
}

function Update-SelectionState {
    $selected = $script:GridEntries.SelectedItem
    if ($selected) {
        $script:SelectionHint.Text = "Выбрано: $($selected.IP) → $($selected.Hosts)"
        $script:BtnToggle.IsEnabled = $true
        $script:BtnDelete.IsEnabled = $true
    } else {
        $script:SelectionHint.Text = 'Выберите запись в таблице, чтобы изменить её статус или удалить.'
        $script:BtnToggle.IsEnabled = $false
        $script:BtnDelete.IsEnabled = $false
    }
}

function Update-ProfileSelectionState {
    $selected = $script:ListProfiles.SelectedItem
    if ($selected) {
        $script:ProfileHint.Text = "Выбран профиль: $($selected.Name)"
        $script:BtnActivateProfile.IsEnabled = $true
        $script:BtnDeleteProfile.IsEnabled = $true
    } else {
        $script:ProfileHint.Text = 'Выберите профиль из списка.'
        $script:BtnActivateProfile.IsEnabled = $false
        $script:BtnDeleteProfile.IsEnabled = $false
    }
}

function Update-BackupState {
    $exists = Test-Path -LiteralPath $script:BackupPath
    $script:BtnRestore.IsEnabled = $exists
    $script:BtnRestore.ToolTip = if ($exists) {
        "Снимок hosts, сделанный при первом запуске: $($script:BackupPath)"
    } else {
        'Резервная копия ещё не создана'
    }
}

function Refresh-Editor {
    try {
        $entries = @(Get-HostsEntries)
        $script:GridEntries.ItemsSource = $entries
        $script:EntryCount.Text = Format-EntriesCount $entries.Count
        $script:EditorEmptyState.Visibility = if ($entries.Count -eq 0) { 'Visible' } else { 'Collapsed' }
        $script:GridEntries.SelectedItem = $null

        # По возможности сохраняем выбор после добавления/переключения статуса.
        if ($null -ne $script:SelectAfterRefresh) {
            $targetIndex = [int]$script:SelectAfterRefresh
            $match = @($entries | Where-Object { $_.Index -eq $targetIndex }) | Select-Object -First 1
            if ($match) { $script:GridEntries.SelectedItem = $match }
            $script:SelectAfterRefresh = $null
        }

        Update-SelectionState
    } catch {
        Set-Status -Message "Не удалось прочитать hosts: $($_.Exception.Message)" -Kind 'Error'
    }
}

function Get-ProfilesList {
    if (-not (Test-Path -LiteralPath $script:ProfilesDir)) { return @() }

    $files = @(Get-ChildItem -LiteralPath $script:ProfilesDir -File -Filter ('*' + $script:ProfileExt) -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($file in $files) {
        $count = 0
        try {
            foreach ($line in [System.IO.File]::ReadAllLines($file.FullName)) {
                if (-not [string]::IsNullOrWhiteSpace($line) -and $line -match $script:EntryPattern) { $count++ }
            }
        } catch { }

        $result.Add([PSCustomObject]@{
            Name     = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
            FullName = $file.FullName
            Info     = ("{0} · изменён {1}" -f (Format-EntriesCount $count), $file.LastWriteTime.ToString('dd.MM.yyyy HH:mm'))
            Size     = ("{0:N1} КБ" -f ($file.Length / 1KB))
        })
    }
    return $result.ToArray()
}

function Refresh-Profiles {
    try {
        $previousFullName = $null
        if ($script:ListProfiles.SelectedItem) {
            $previousFullName = [string]$script:ListProfiles.SelectedItem.FullName
        }

        $profiles = @(Get-ProfilesList)
        $script:ListProfiles.ItemsSource = $profiles
        $script:ProfilesEmptyState.Visibility = if ($profiles.Count -eq 0) { 'Visible' } else { 'Collapsed' }
        $script:ProfileDirLabel.Text = $script:ProfilesDir
        $script:ProfileDirLabel.ToolTip = $script:ProfilesDir
        $script:ListProfiles.SelectedItem = $null

        # Возвращаем выбор, если профиль всё ещё существует (например, после сохранения).
        if (-not [string]::IsNullOrWhiteSpace($previousFullName)) {
            $restored = @($profiles | Where-Object { $_.FullName -eq $previousFullName }) | Select-Object -First 1
            if ($restored) { $script:ListProfiles.SelectedItem = $restored }
        }

        Update-ProfileSelectionState
    } catch {
        Set-Status -Message "Не удалось прочитать профили: $($_.Exception.Message)" -Kind 'Error'
    }
}

function Refresh-All {
    Refresh-Editor
    Refresh-Profiles
}

# ============================================================
#  12. Действия пользователя (логика кнопок)
# ============================================================

function Ensure-ProfilesDirectory {
    if (-not (Test-Path -LiteralPath $script:ProfilesDir)) {
        $null = New-Item -ItemType Directory -Path $script:ProfilesDir -Force -ErrorAction Stop
    }
}

function Add-HostsEntryFromForm {
    $ipText     = $script:TxtIp.Text.Trim()
    $domainText = $script:TxtDomain.Text.Trim()

    # [::1] — привычная запись IPv6 в скобках; в hosts скобки не нужны.
    if ($ipText -match '^\[(.+)\]$') {
        $ipText = $Matches[1].Trim()
        $script:TxtIp.Text = $ipText
    }

    # --- Проверка IP ---
    if ([string]::IsNullOrWhiteSpace($ipText) -or -not (Test-HostsIpValue -Value $ipText)) {
        Set-Status -Message 'Укажите корректный IP-адрес, например 127.0.0.1 или ::1.' -Kind 'Error'
        $script:TxtIp.Focus() | Out-Null
        return
    }

    # --- Проверка домена ---
    if ([string]::IsNullOrWhiteSpace($domainText)) {
        Set-Status -Message 'Укажите домен, например example.com.' -Kind 'Error'
        $script:TxtDomain.Focus() | Out-Null
        return
    }
    $domainText = $domainText.TrimEnd('.')
    if (-not (Test-HostsDomainValue -Value $domainText)) {
        Set-Status -Message 'Некорректный домен: метки не должны быть пустыми или начинаться/заканчиваться дефисом; IP вместо домена не подходит.' -Kind 'Error'
        $script:TxtDomain.Focus() | Out-Null
        return
    }

    # --- Проверка дубликата: в пределах одного семейства адресов домен уникален ---
    # В hosts срабатывает первая активная запись, поэтому IPv4 и IPv6 на один домен
    # (dual-stack) — это норма, а вот два разных IP одного семейства конфликтуют.
    $existingForDomain = @(Get-HostsEntries | Where-Object { $_.HostList -contains $domainText })
    if ($existingForDomain.Count -gt 0) {
        $isV6 = $ipText.Contains(':')
        $activeSameFamily = @($existingForDomain |
            Where-Object { ($_.Status -eq 'Активен') -and ((([string]$_.IP).Contains(':')) -eq $isV6) })

        if (@($activeSameFamily | Where-Object { $_.IP -eq $ipText }).Count -gt 0) {
            Set-Status -Message ("Запись {0} → {1} уже существует и активна." -f $ipText, $domainText) -Kind 'Warning'
            return
        }
        if ($activeSameFamily.Count -gt 0) {
            $bound = $activeSameFamily[0]
            Set-Status -Message ("Домен {0} уже привязан к {1}. Для одного семейства адресов допустима только одна активная запись." -f $domainText, $bound.IP) -Kind 'Warning'
            return
        }
        # Закомментированные записи и записи другого семейства добавление не блокируют.
    }

    # --- Итоговая проверка: строка должна распознаваться парсером hosts ---
    # Ловит IPv6 с зоной (fe80::1%12) и формы вроде ::ffff:1.2.3.4: валидатор IP их
    # пропускает, а EntryPattern — нет, поэтому такая строка была бы записана "вслепую".
    $lineToWrite = ("{0}`t{1}" -f $ipText, $domainText)
    if ($lineToWrite -notmatch $script:EntryPattern) {
        Set-Status -Message 'Такую запись файл hosts не распознает. Проверьте IP: IPv6 с зоной (%) и форма ::ffff:1.2.3.4 не поддерживаются.' -Kind 'Error'
        $script:TxtIp.Focus() | Out-Null
        return
    }

    try {
        $lines = @(Read-HostsLines)
        $newLines = [string[]](@($lines) + @($lineToWrite))
        $script:SelectAfterRefresh = $newLines.Count - 1

        $ok = Save-HostsLines -Lines $newLines -SuccessMessage ("Добавлена запись {0} → {1}." -f $ipText, $domainText)
        if (-not $ok) { $script:SelectAfterRefresh = $null }
        if ($ok) {
            $script:TxtIp.Clear()
            $script:TxtDomain.Clear()
            $script:TxtIp.Focus() | Out-Null
        }
    } catch {
        Set-Status -Message "Не удалось добавить запись: $($_.Exception.Message)" -Kind 'Error'
    }
}

function Test-HostsIpValue {
    <# Проверяет, является ли строка корректным IPv4/IPv6-адресом. #>
    param([Parameter(Mandatory)][string]$Value)

    if ($Value -match ':') {
        $address = $null
        return [System.Net.IPAddress]::TryParse($Value, [ref]$address)
    }
    return ($Value -match '^(?:(?:25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)$')
}

function Test-HostsDomainValue {
    <# Проверяет имя домена (в том числе односоставные имена вроде nas). #>
    param([Parameter(Mandatory)][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    if ($Value.Length -gt 253) { return $false }
    if (Test-HostsIpValue -Value $Value) { return $false }
    if ($Value -match '^[0-9]+(?:\.[0-9]+)*$') { return $false }

    foreach ($label in $Value.Split('.')) {
        if ($label.Length -eq 0 -or $label.Length -gt 63) { return $false }
        if ($label -notmatch '^[A-Za-z0-9_](?:[A-Za-z0-9_\-]*[A-Za-z0-9_])?$') { return $false }
    }
    return $true
}

# Скомпилированные regex и кэш последнего разбора: большие списки
# не должны парситься дважды (валидатор + обработчик кнопки).
$script:BulkIpRegex      = New-Object System.Text.RegularExpressions.Regex('^(?:(?:\d{1,3}\.){3}\d{1,3}|[0-9A-Fa-f]*:[0-9A-Fa-f:]+)$', [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:BulkLabelRegex   = New-Object System.Text.RegularExpressions.Regex('^[A-Za-z0-9_](?:[A-Za-z0-9_\-]*[A-Za-z0-9_])?$', [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:BulkNumericRegex = New-Object System.Text.RegularExpressions.Regex('^[0-9]+(?:\.[0-9]+)*$', [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:BulkCacheText    = $null
$script:BulkCacheResult  = $null

function ConvertFrom-BulkHostsText {
    <#
        Разбирает многострочный список в записи hosts.
        Поддерживает:
          127.0.0.1 site.local
          192.168.1.10 site.local router.local   (несколько домён)
          site.local                              (без IP -> 127.0.0.1)
          https://site.local/path                 (из ссылки берётся домен)
        Строки с # и пустые строки игнорируются; дубликаты отбрасываются в пределах семейства адресов.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $records = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $skipped = 0

    $allLines = $Text -split "`r?`n"
    for ($lineIndex = 0; $lineIndex -lt $allLines.Length; $lineIndex++) {
        $line = $allLines[$lineIndex].Trim()
        if ($line.Length -eq 0) { continue }
        if ($line[0] -eq [char]'#') { continue }

        # Отрезаем комментарий в конце строки
        $commentAt = $line.IndexOf('#')
        if ($commentAt -gt 0 -and [char]::IsWhiteSpace($line[$commentAt - 1])) {
            $line = $line.Substring(0, $commentAt).Trim()
        }
        if ($line.Length -eq 0) { continue }

        $parts = @($line -split '[\s,;]+')
        $firstHost = 0
        $ip = '127.0.0.1'

        # [::1] -> ::1: в файле hosts скобки недопустимы.
        $firstPart = $parts[0]
        if ($firstPart.Length -gt 2 -and $firstPart.StartsWith('[') -and $firstPart.EndsWith(']')) {
            $parts[0] = $firstPart.Substring(1, $firstPart.Length - 2)
        }

        if ($script:BulkIpRegex.IsMatch($parts[0])) {
            $ipAddress = $null
            if (-not [System.Net.IPAddress]::TryParse($parts[0], [ref]$ipAddress)) {
                $skipped++
                continue
            }
            $ip = $parts[0]
            $firstHost = 1
        } elseif ($parts[0] -match '^[0-9A-Fa-f:.%]+$' -and
                  ($parts[0].Contains(':') -or $script:BulkNumericRegex.IsMatch($parts[0]))) {
            # Похоже на IP, но не распознано (зона %, форма ::ffff:1.2.3.4,
            # лишние точки). Всю строку пропускаем, а не превращаем домен в 127.0.0.1.
            # Проверка по набору символов не даёт принять URL (https://...) за IPv6.
            $skipped++
            continue
        }
        if ($parts.Length -le $firstHost) {
            $skipped++
            continue
        }

        for ($partIndex = $firstHost; $partIndex -lt $parts.Length; $partIndex++) {
            $hostName = $parts[$partIndex]
            if ($hostName.Length -eq 0) { continue }

            # Если вставили ссылку - берём из неё только домен
            if ($hostName.StartsWith('http://', [System.StringComparison]::OrdinalIgnoreCase) -or
                $hostName.StartsWith('https://', [System.StringComparison]::OrdinalIgnoreCase)) {
                try {
                    $hostName = ([System.Uri]$hostName).Host
                } catch {
                    $skipped++
                    continue
                }
            }

            $hostName = $hostName.TrimEnd('.')
            if ($hostName.Length -eq 0 -or $hostName.Length -gt 253) {
                $skipped++
                continue
            }

            $isValid = $true
            foreach ($label in $hostName.Split('.')) {
                if ($label.Length -eq 0 -or $label.Length -gt 63 -or -not $script:BulkLabelRegex.IsMatch($label)) {
                    $isValid = $false
                    break
                }
            }
            # Число, записанное через точки, - это IP, а не домен
            if ($isValid -and $script:BulkNumericRegex.IsMatch($hostName)) { $isValid = $false }
            if (-not $isValid) {
                $skipped++
                continue
            }

            # Дубликаты отбрасываем только внутри одного семейства адресов:
            # 0.0.0.0 a.com и :: a.com — это разные строки (dual-stack), обе нужны.
            $family = if ($ip.Contains(':')) { 'v6' } else { 'v4' }
            if (-not $seen.Add(("{0}|{1}" -f $hostName, $family))) {
                $skipped++
                continue
            }
            $records.Add([PSCustomObject]@{ IP = $ip; Host = $hostName })
        }
    }

    return [PSCustomObject]@{
        Records = $records.ToArray()
        Skipped = $skipped
    }
}

function Invoke-BulkImport {
    <# Диалог массового добавления записей и запись их в hosts одним проходом. #>
    $validator = {
        param($value)
        $preview = ConvertFrom-BulkHostsText -Text $value
        # Кэшируем разбор: обработчик кнопки возьмёт готовый результат.
        $script:BulkCacheText = $value
        $script:BulkCacheResult = $preview
        if (@($preview.Records).Count -eq 0) {
            return 'Не найдено ни одной корректной строки. Пример: 127.0.0.1 mysite.local'
        }
        return $null
    }

    $text = Show-DarkDialog `
        -Title 'Добавить списком' `
        -Message ("Вставьте записи — по одной в строке.`n`n" +
                  "127.0.0.1 site.local`n" +
                  "192.168.1.10 nas.local router.local`n" +
                  "site2.local   — без IP будет 127.0.0.1`n`n" +
                  "Можно вставлять комментарии # и ссылки — из них берётся домен.") `
        -Mode Bulk `
        -OkText 'Добавить' `
        -Validator $validator
    if ($null -eq $text) { return }

    $records = @()
    $skipped = 0
    $nothingToAdd = $false
    $previousCursor = [System.Windows.Input.Mouse]::OverrideCursor

    try {
        [System.Windows.Input.Mouse]::OverrideCursor = [System.Windows.Input.Cursors]::Wait
        Set-Status -Message 'Обработка списка…' -Kind 'Info'
        try {
            $script:Window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
        } catch { }

        # Валидатор уже разобрал этот же текст — второй раз не парсим.
        if ($null -ne $script:BulkCacheResult -and $script:BulkCacheText -ceq $text) {
            $parsed = $script:BulkCacheResult
        } else {
            $parsed = ConvertFrom-BulkHostsText -Text $text
        }
        $script:BulkCacheText = $null
        $script:BulkCacheResult = $null

        $records = @($parsed.Records)
        $skipped = [int]$parsed.Skipped

        # Домены, которые уже есть в hosts, — активные и отдельно по семейству адресов.
        # Так :: a.com после 0.0.0.0 a.com не считается дубликатом,
        # а закомментированная запись не мешает добавить рабочую.
        # HashSet с OrdinalIgnoreCase быстрее, чем хэш-таблица с ToLower() на каждой строке.
        $existing = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in @(Get-HostsEntries)) {
            if ($entry.Status -ne 'Активен') { continue }
            $family = if (([string]$entry.IP).Contains(':')) { 'v6' } else { 'v4' }
            foreach ($hostName in @($entry.HostList)) {
                [void]$existing.Add(("{0}|{1}" -f [string]$hostName, $family))
            }
        }

        $toAdd = New-Object System.Collections.Generic.List[object]
        foreach ($record in $records) {
            $recordFamily = if (([string]$record.IP).Contains(':')) { 'v6' } else { 'v4' }
            if (-not $existing.Contains(("{0}|{1}" -f $record.Host, $recordFamily))) { $toAdd.Add($record) }
        }
        $skipped += ($records.Count - $toAdd.Count)

        if ($toAdd.Count -eq 0) {
            $nothingToAdd = $true
        } else {
            $lines = @(Read-HostsLines)
            $newLines = New-Object System.Collections.Generic.List[string]
            foreach ($line in $lines) { $newLines.Add([string]$line) }
            foreach ($record in $toAdd) {
                $newLines.Add(("{0}`t{1}" -f $record.IP, $record.Host))
            }
            $script:SelectAfterRefresh = $newLines.Count - 1

            $summary = ("Добавлено записей: {0}." -f $toAdd.Count)
            if ($skipped -gt 0) { $summary += (" Пропущено: {0}." -f $skipped) }

            $ok = Save-HostsLines -Lines $newLines.ToArray() -SuccessMessage $summary
            if (-not $ok) { $script:SelectAfterRefresh = $null }
        }
    } catch {
        Set-Status -Message "Не удалось добавить список: $($_.Exception.Message)" -Kind 'Error'
    } finally {
        [System.Windows.Input.Mouse]::OverrideCursor = $previousCursor
    }

    if ($nothingToAdd) {
        Set-Status -Message ("В hosts уже есть все записи из списка ({0} шт.)." -f $records.Count) -Kind 'Warning'
        [void](Show-DarkDialog `
            -Title 'Добавлять нечего' `
            -Message ("В hosts уже есть все записи из списка ({0} шт.).`n`nПропущено строк: {1}." -f $records.Count, $skipped) `
            -Mode Info -OkText 'Понятно')
    }
}

function Invoke-ToggleSelectedEntry {
    $selected = $script:GridEntries.SelectedItem
    if (-not $selected) {
        Set-Status -Message 'Сначала выберите запись в таблице.' -Kind 'Warning'
        return
    }

    try {
        $lines = @(Read-HostsLines)
        $index = [int]$selected.Index
        if ($index -lt 0 -or $index -ge $lines.Count) {
            Set-Status -Message 'Файл hosts изменился извне. Список обновлён.' -Kind 'Warning'
            Refresh-Editor
            return
        }

        $line = $lines[$index]
        if ($line -cne [string]$selected.RawLine) {
            Set-Status -Message 'Файл hosts изменился извне. Список обновлён.' -Kind 'Warning'
            Refresh-Editor
            return
        }

        if ($line -match '^\s*#') {
            $lines[$index] = ($line -replace '^(\s*)#+\s?', '$1')
            $message = 'Запись активирована.'
        } else {
            $lines[$index] = '#' + $line
            $message = 'Запись закомментирована.'
        }

        $script:SelectAfterRefresh = $index
        $ok = Save-HostsLines -Lines $lines -SuccessMessage $message
        if (-not $ok) { $script:SelectAfterRefresh = $null }
    } catch {
        Set-Status -Message "Не удалось изменить статус: $($_.Exception.Message)" -Kind 'Error'
    }
}

function Invoke-DeleteSelectedEntry {
    $selected = $script:GridEntries.SelectedItem
    if (-not $selected) {
        Set-Status -Message 'Сначала выберите запись в таблице.' -Kind 'Warning'
        return
    }

    $confirmed = Show-DarkDialog `
        -Title 'Удалить запись?' `
        -Message ("Запись будет удалена из файла hosts без возможности отмены.`n`n{0} → {1}" -f $selected.IP, $selected.Hosts) `
        -Mode Confirm -OkText 'Удалить' -Danger
    if (-not $confirmed) { return }

    try {
        $lines = @(Read-HostsLines)
        $index = [int]$selected.Index
        if ($index -lt 0 -or $index -ge $lines.Count) {
            Set-Status -Message 'Файл hosts изменился извне. Список обновлён.' -Kind 'Warning'
            Refresh-Editor
            return
        }

        if ($lines[$index] -cne [string]$selected.RawLine) {
            Set-Status -Message 'Файл hosts изменился извне. Список обновлён.' -Kind 'Warning'
            Refresh-Editor
            return
        }

        $newLines = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($i -ne $index) { $newLines.Add($lines[$i]) }
        }

        [void](Save-HostsLines -Lines $newLines.ToArray() -SuccessMessage ("Удалена запись {0} → {1}." -f $selected.IP, $selected.Hosts))
    } catch {
        Set-Status -Message "Не удалось удалить запись: $($_.Exception.Message)" -Kind 'Error'
    }
}

function Invoke-RestoreOriginalHosts {
    if (-not (Test-Path -LiteralPath $script:BackupPath)) {
        Set-Status -Message 'Резервная копия hosts.bak не найдена.' -Kind 'Warning'
        Update-BackupState
        return
    }

    $confirmed = Show-DarkDialog `
        -Title 'Откатить из hosts.bak?' `
        -Message ("Текущее содержимое hosts будет заменено резервной копией:`n{0}`n`n" +
                  "Это снимок hosts, сделанный при первом запуске утилиты, а не заводской файл Windows.`n" +
                  "Все изменения, сделанные после создания копии, будут потеряны." -f $script:BackupPath) `
        -Mode Confirm -OkText 'Откатить' -Danger
    if (-not $confirmed) { return }

    # Перед восстановлением сохраняем текущий hosts, чтобы откатиться было можно.
    try {
        Ensure-ProfilesDirectory
        $safetyCopy = Join-Path $script:ProfilesDir 'hosts.before-restore.bak'
        Copy-Item -LiteralPath $script:HostsPath -Destination $safetyCopy -Force -ErrorAction Stop
    } catch {
        Set-Status -Message "Не удалось создать страховочную копию: $($_.Exception.Message)" -Kind 'Error'
        [void](Show-DarkDialog `
            -Title 'Восстановление отменено' `
            -Message ("Не удалось сохранить текущий hosts в hosts.before-restore.bak.`n`n" +
                      "Файл hosts не изменён.`n`n$($_.Exception.Message)") `
            -Mode Info -OkText 'Закрыть')
        return
    }

    [void](Copy-HostsFile -Source $script:BackupPath -SuccessMessage 'Файл hosts восстановлен из hosts.bak.')
}

function Invoke-ResetHostsToDefault {
    <#
        Заменяет hosts заводским шаблоном Windows.
        Это не пользовательская резервная копия hosts.bak: сначала создаётся
        страховочная копия текущего файла, чтобы откатиться было можно.
    #>
    $confirmed = Show-DarkDialog `
        -Title 'Сбросить к заводскому hosts?' `
        -Message ("Файл hosts будет заменён заводским шаблоном Windows (закомментированные localhost, без пользовательских записей).`n`n" +
                  "Это не пользовательская резервная копия hosts.bak. Текущий файл сохранится как hosts.before-reset.bak в папке профилей.`n`n" +
                  "Все добавленные и изменённые записи пропадут.") `
        -Mode Confirm -OkText 'Сбросить' -Danger
    if (-not $confirmed) { return }

    try {
        Ensure-ProfilesDirectory
        $safetyCopy = Join-Path $script:ProfilesDir 'hosts.before-reset.bak'
        Copy-Item -LiteralPath $script:HostsPath -Destination $safetyCopy -Force -ErrorAction Stop
    } catch {
        Set-Status -Message "Не удалось создать страховочную копию: $($_.Exception.Message)" -Kind 'Error'
        [void](Show-DarkDialog `
            -Title 'Сброс отменён' `
            -Message ("Не удалось сохранить текущий hosts в hosts.before-reset.bak.`n`n" +
                      "Файл hosts не изменён.`n`n$($_.Exception.Message)") `
            -Mode Info -OkText 'Закрыть')
        return
    }

    # Заводское содержимое hosts (чистый ASCII, как поставляет Windows).
    $defaultLines = @(
        '# Copyright (c) 1993-2009 Microsoft Corp.'
        '#'
        '# This is a sample HOSTS file used by Microsoft TCP/IP for Windows.'
        '#'
        '# This file contains the mappings of IP addresses to host names. Each'
        '# entry should be kept on an individual line. The IP address should'
        '# be placed in the first column followed by the corresponding host name.'
        '# The IP address and the host name should be separated by at least one'
        '# space.'
        '#'
        '# Additionally, comments (such as these) may be inserted on individual'
        '# lines or following the machine name denoted by a ''#'' symbol.'
        '#'
        '# For example:'
        '#'
        '#      102.54.94.97     rhino.acme.com          # source server'
        '#       38.25.63.10     x.acme.com              # x client host'
        ''
        '# localhost name resolution is handled within DNS itself.'
        "#`t127.0.0.1       localhost"
        "#`t::1             localhost"
    )

    $tempFile = Join-Path $script:ProfilesDir ('hosts-default-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.tmp')
    try {
        # Пишем во временный файл в ASCII и заливаем его как обычную копию,
        # чтобы сработала атомарная запись и очистка DNS-кэша.
        [System.IO.File]::WriteAllLines($tempFile, [string[]]$defaultLines, [System.Text.Encoding]::ASCII)
        [void](Copy-HostsFile -Source $tempFile -SuccessMessage 'Файл hosts сброшен к заводскому.')
    } catch {
        Set-Status -Message "Не удалось сбросить hosts: $($_.Exception.Message)" -Kind 'Error'
    } finally {
        try { [System.IO.File]::Delete($tempFile) } catch { }
    }
}

function Invoke-SaveCurrentAsProfile {
    $suggested = 'Профиль ' + (Get-Date -Format 'dd.MM.yyyy HH-mm')
    $name = Show-DarkDialog `
        -Title 'Сохранить профиль' `
        -Message 'Введите название профиля. Текущее содержимое hosts будет сохранено в папку профилей.' `
        -Mode Input -OkText 'Сохранить' -DefaultValue $suggested
    if ($null -eq $name) { return }

    $safeName = ($name -replace '[\\/:*?"<>|]', '_').Trim().TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($safeName)) {
        Set-Status -Message 'Название профиля содержит только недопустимые символы.' -Kind 'Error'
        return
    }

    try {
        Ensure-ProfilesDirectory
        $target = Join-Path $script:ProfilesDir ($safeName + $script:ProfileExt)

        if (Test-Path -LiteralPath $target) {
            $overwrite = Show-DarkDialog `
                -Title 'Профиль уже существует' `
                -Message ("Профиль «{0}» уже существует. Заменить его текущим состоянием hosts?" -f $safeName) `
                -Mode Confirm -OkText 'Заменить'
            if (-not $overwrite) { return }
        }

        [System.IO.File]::Copy($script:HostsPath, $target, $true)
        # Профиль не должен наследовать атрибут «только для чтения».
        (Get-Item -LiteralPath $target -Force).IsReadOnly = $false
        Refresh-Profiles
        Set-Status -Message ("Профиль «{0}» сохранён." -f $safeName) -Kind 'Success'
    } catch {
        Set-Status -Message "Не удалось сохранить профиль: $($_.Exception.Message)" -Kind 'Error'
    }
}

function Invoke-ActivateSelectedProfile {
    $selected = $script:ListProfiles.SelectedItem
    if (-not $selected) {
        Set-Status -Message 'Сначала выберите профиль в списке.' -Kind 'Warning'
        return
    }
    if (-not (Test-Path -LiteralPath $selected.FullName)) {
        Set-Status -Message 'Файл профиля не найден. Список обновлён.' -Kind 'Error'
        Refresh-Profiles
        return
    }

    $confirmed = Show-DarkDialog `
        -Title 'Активировать профиль?' `
        -Message ("Текущий hosts будет заменён профилем «{0}».`n`nТекущая конфигурация будет сохранена как hosts.previous.bak в папке профилей." -f $selected.Name) `
        -Mode Confirm -OkText 'Активировать'
    if (-not $confirmed) { return }

    try {
        Ensure-ProfilesDirectory
        $safetyCopy = Join-Path $script:ProfilesDir 'hosts.previous.bak'
        Copy-Item -LiteralPath $script:HostsPath -Destination $safetyCopy -Force -ErrorAction Stop
    } catch {
        Set-Status -Message "Не удалось создать страховочную копию: $($_.Exception.Message)" -Kind 'Error'
        [void](Show-DarkDialog `
            -Title 'Активация отменена' `
            -Message ("Не удалось сохранить текущий hosts как hosts.previous.bak.`n`n" +
                      "Активация отменена, файл hosts не изменён.`n`n$($_.Exception.Message)") `
            -Mode Info -OkText 'Закрыть')
        return
    }

    [void](Copy-HostsFile -Source $selected.FullName -SuccessMessage ("Активирован профиль «{0}»." -f $selected.Name))
}

function Invoke-DeleteSelectedProfile {
    $selected = $script:ListProfiles.SelectedItem
    if (-not $selected) {
        Set-Status -Message 'Сначала выберите профиль в списке.' -Kind 'Warning'
        return
    }

    $confirmed = Show-DarkDialog `
        -Title 'Удалить профиль?' `
        -Message ("Профиль «{0}» будет удалён из папки профилей. Файл hosts при этом не изменится." -f $selected.Name) `
        -Mode Confirm -OkText 'Удалить' -Danger
    if (-not $confirmed) { return }

    try {
        Remove-Item -LiteralPath $selected.FullName -Force -ErrorAction Stop
        Refresh-Profiles
        Set-Status -Message ("Профиль «{0}» удалён." -f $selected.Name) -Kind 'Success'
    } catch {
        Set-Status -Message "Не удалось удалить профиль: $($_.Exception.Message)" -Kind 'Error'
    }
}

function Open-ProfilesDirectory {
    try {
        Ensure-ProfilesDirectory
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $script:ProfilesDir)
    } catch {
        Set-Status -Message "Не удалось открыть папку профилей: $($_.Exception.Message)" -Kind 'Error'
    }
}

# ============================================================
#  13. Подписка на события интерфейса
# ============================================================

$script:GridEntries.Add_SelectionChanged({ Update-SelectionState })
$script:ListProfiles.Add_SelectionChanged({ Update-ProfileSelectionState })

$script:GridEntries.Add_MouseDoubleClick({
    try { Invoke-ToggleSelectedEntry }
    catch { Set-Status -Message "Ошибка: $($_.Exception.Message)" -Kind 'Error' }
})

$script:BtnRefresh.Add_Click({
    try {
        Refresh-All
        Set-Status -Message 'Список записей hosts обновлён.' -Kind 'Info'
    } catch {
        Set-Status -Message "Ошибка обновления: $($_.Exception.Message)" -Kind 'Error'
    }
})

$script:BtnNotepad.Add_Click({
    try {
        Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $script:HostsPath)
        Set-Status -Message 'Файл hosts открыт в Блокноте.' -Kind 'Info'
    } catch {
        Set-Status -Message "Не удалось открыть Блокнот: $($_.Exception.Message)" -Kind 'Error'
    }
})

$script:BtnRestore.Add_Click({
    try { Invoke-RestoreOriginalHosts }
    catch { Set-Status -Message "Ошибка восстановления: $($_.Exception.Message)" -Kind 'Error' }
})

$script:BtnResetDefault.Add_Click({
    try { Invoke-ResetHostsToDefault }
    catch { Set-Status -Message "Ошибка сброса: $($_.Exception.Message)" -Kind 'Error' }
})

$script:BtnToggle.Add_Click({
    try { Invoke-ToggleSelectedEntry }
    catch { Set-Status -Message "Ошибка: $($_.Exception.Message)" -Kind 'Error' }
})

$script:BtnDelete.Add_Click({
    try { Invoke-DeleteSelectedEntry }
    catch { Set-Status -Message "Ошибка: $($_.Exception.Message)" -Kind 'Error' }
})

$script:BtnAdd.Add_Click({
    try { Add-HostsEntryFromForm }
    catch { Set-Status -Message "Ошибка добавления: $($_.Exception.Message)" -Kind 'Error' }
})

$script:BtnBulk.Add_Click({
    try { Invoke-BulkImport }
    catch { Set-Status -Message "Ошибка добавления списка: $($_.Exception.Message)" -Kind 'Error' }
})

$enterHandler = {
    if ($_.Key -eq [System.Windows.Input.Key]::Return) {
        try { Add-HostsEntryFromForm }
        catch { Set-Status -Message "Ошибка добавления: $($_.Exception.Message)" -Kind 'Error' }
    }
}
$script:TxtIp.Add_KeyDown($enterHandler)
$script:TxtDomain.Add_KeyDown($enterHandler)

$script:BtnSaveProfile.Add_Click({
    try { Invoke-SaveCurrentAsProfile }
    catch { Set-Status -Message "Ошибка сохранения профиля: $($_.Exception.Message)" -Kind 'Error' }
})

$script:BtnActivateProfile.Add_Click({
    try { Invoke-ActivateSelectedProfile }
    catch { Set-Status -Message "Ошибка активации профиля: $($_.Exception.Message)" -Kind 'Error' }
})

$script:BtnDeleteProfile.Add_Click({
    try { Invoke-DeleteSelectedProfile }
    catch { Set-Status -Message "Ошибка удаления профиля: $($_.Exception.Message)" -Kind 'Error' }
})

$script:BtnOpenProfilesFolder.Add_Click({
    try { Open-ProfilesDirectory }
    catch { Set-Status -Message "Ошибка: $($_.Exception.Message)" -Kind 'Error' }
})

$script:Window.Add_SourceInitialized({
    try { Set-DarkTitleBar -Window $script:Window } catch { }
})

$script:Window.Add_Loaded({
    try { $script:TxtIp.Focus() | Out-Null } catch { }
    # С этого момента окно работает: ошибки в обработчиках не должны закрывать приложение.
    $script:StartupComplete = $true
})

# ============================================================
#  14. Стартовая инициализация данных
# ============================================================

$backupState = 'exists'
$backupError = ''
try {
    $backupState = Initialize-HostsBackup
} catch {
    $backupState = 'error'
    $backupError = $_.Exception.Message
}

$profilesError = ''
try {
    Ensure-ProfilesDirectory
} catch {
    $profilesError = $_.Exception.Message
}

Refresh-All
Update-BackupState

if ($backupState -eq 'created') {
    Set-Status -Message "Создана резервная копия оригинального hosts: hosts.bak" -Kind 'Success'
} elseif ($backupState -eq 'exists') {
    Set-Status -Message 'Готово. Резервная копия hosts.bak на месте.' -Kind 'Info'
} else {
    Set-Status -Message "Не удалось создать резервную копию: $backupError" -Kind 'Warning'
}

if (-not [string]::IsNullOrWhiteSpace($profilesError)) {
    Set-Status -Message "Папка профилей недоступна: $profilesError" -Kind 'Warning'
}

$script:StatusRight.Text = 'Clear-DnsClientCache выполняется автоматически'
$script:Window.Title = "Hosts Manager · $env:COMPUTERNAME"

# ============================================================
#  15. Запуск
# ============================================================

try {
    [void]$script:Window.ShowDialog()
} finally {
    Restore-HostConsole
}
