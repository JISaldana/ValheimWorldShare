using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        string scriptPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "launch_valheim_drive.ps1");
        if (!File.Exists(scriptPath))
        {
            MessageBox.Show(
                "No se encontro launch_valheim_drive.ps1 junto al ejecutable.\r\n" + scriptPath,
                "Valheim World Share",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return;
        }

        try
        {
            Process? process = Process.Start(new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + scriptPath + "\"",
                WorkingDirectory = AppDomain.CurrentDomain.BaseDirectory,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            });
            if (process is null)
            {
                throw new InvalidOperationException("No se pudo iniciar PowerShell.");
            }
            using (process)
            {
                process.WaitForExit();
            }
        }
        catch (Exception error)
        {
            MessageBox.Show(error.Message, "Valheim World Share", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
