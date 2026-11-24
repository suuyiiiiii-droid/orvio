using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Windows;

namespace T1Controller;

public partial class SetupGuide : Window
{
    private sealed record Step(string Title, string Detail, string Command, string? SettingsUri);

    private static readonly Step[] Steps =
    [
        new("连接遥控器",
            "T1 使用 USB 接收器。小米遥控器请在「蓝牙和设备」中完成配对，再回到此窗口。",
            "打开蓝牙设置", "ms-settings:bluetooth"),
        new("允许麦克风",
            "在「隐私和安全性 → 麦克风」开启麦克风访问，并允许桌面应用访问。如果系统单独显示 Orvio，也请开启该应用。返回后可在语音页按住试录。",
            "打开麦克风设置", "ms-settings:privacy-microphone"),
        new("配置离线转写",
            "在语音页选择麦克风。如果当前安装包没有附带本地模型，再选择 whisper-cli 和多语种模型。",
            "前往语音设置", null)
    ];

    private readonly Func<string> connectionStatus;
    private readonly Func<bool> voiceReady;
    private int index;
    internal bool OpenVoiceSettings { get; private set; }

    internal SetupGuide(Func<string> connectionStatus, Func<bool> voiceReady)
    {
        this.connectionStatus = connectionStatus;
        this.voiceReady = voiceReady;
        InitializeComponent();
        ShowStep();
    }

    private void ShowStep()
    {
        var step = Steps[index];
        StepTitle.Text = $"{index + 1} / {Steps.Length} · {step.Title}";
        StepDetail.Text = step.Detail;
        OpenSettings.Content = step.Command;
        BackButton.IsEnabled = index > 0;
        NextButton.Content = index == Steps.Length - 1 ? "完成" : "下一步";
        RefreshStatus(null, EventArgs.Empty);
    }

    private void RefreshStatus(object? sender, EventArgs args)
    {
        StepState.Text = index switch
        {
            0 => connectionStatus(),
            1 => "麦克风访问状态以系统设置和试录结果为准。",
            _ => voiceReady() ? "已找到本地中文识别程序和模型。" : "还没有找到可用的本地识别程序和模型。"
        };
        StepState.Visibility = StepState.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private void OpenSettingsPage(object sender, RoutedEventArgs args)
    {
        if (Steps[index].SettingsUri is not { } uri)
        {
            OpenVoiceSettings = true;
            DialogResult = true;
            return;
        }
        try
        {
            Process.Start(new ProcessStartInfo(uri) { UseShellExecute = true })?.Dispose();
        }
        catch (Win32Exception)
        {
            StepState.Text = "无法打开设置。请从「开始 → 设置」按上方路径进入。";
            StepState.Visibility = Visibility.Visible;
        }
    }

    private void Back(object sender, RoutedEventArgs args)
    {
        if (index > 0) index--;
        ShowStep();
    }

    private void Next(object sender, RoutedEventArgs args)
    {
        if (index + 1 == Steps.Length) DialogResult = true;
        else
        {
            index++;
            ShowStep();
        }
    }
}
