using System.Threading;
using System.Windows;

namespace T1Controller;

public partial class App : Application
{
    private Mutex? instance;

    protected override void OnStartup(StartupEventArgs args)
    {
        base.OnStartup(args);
        instance = new Mutex(initiallyOwned: true, @"Local\T1Controller", out var first);
        if (!first)
        {
            MessageBox.Show("Orvio已运行，可以从系统托盘打开设置。", "Orvio");
            Shutdown();
            return;
        }
        MainWindow = new MainWindow();
        MainWindow.Show();
    }

    protected override void OnExit(ExitEventArgs args)
    {
        instance?.Dispose();
        base.OnExit(args);
    }
}
