using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;

class SettVPNLauncher
{
    static string TempDir = Path.Combine(Path.GetTempPath(), "SettVPN");
    static string AppDir = Path.Combine(TempDir, "app");

    static string[] ScriptResources = new[]
    {
        "SettVPN_Full.ps1",
        "SettVPN_Gui.ps1",
        "settvpn.ico"
    };

    static string V2RayResource = "v2ray.exe";

    static Stream GetResourceStream(string suffix)
    {
        Assembly asm = Assembly.GetExecutingAssembly();
        foreach (string name in asm.GetManifestResourceNames())
        {
            if (name.EndsWith(suffix, StringComparison.OrdinalIgnoreCase))
            {
                return asm.GetManifestResourceStream(name);
            }
        }
        return null;
    }

    static bool ExtractTo(Stream src, string dest)
    {
        if (src == null)
        {
            return false;
        }

        if (File.Exists(dest))
        {
            FileInfo fi = new FileInfo(dest);
            if (fi.Length == src.Length)
            {
                return true;
            }
        }

        try
        {
            using (FileStream fs = new FileStream(dest, FileMode.Create, FileAccess.Write))
            {
                src.CopyTo(fs);
            }
            return true;
        }
        catch
        {
            return false;
        }
    }

    static void Main()
    {
        try
        {
            Directory.CreateDirectory(AppDir);
        }
        catch
        {
            return;
        }

        foreach (string name in ScriptResources)
        {
            using (Stream s = GetResourceStream(name))
            {
                if (!ExtractTo(s, Path.Combine(AppDir, name)))
                {
                    return;
                }
            }
        }

        using (Stream v2 = GetResourceStream(V2RayResource))
        {
            if (!ExtractTo(v2, Path.Combine(TempDir, "v2ray.exe")))
            {
                return;
            }
        }

        string script = Path.Combine(AppDir, "SettVPN_Full.ps1");
        if (!File.Exists(script))
        {
            return;
        }

        var psi = new ProcessStartInfo();
        psi.FileName = "powershell.exe";
        psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"";
        psi.WorkingDirectory = AppDir;
        psi.CreateNoWindow = true;
        psi.UseShellExecute = false;

        try
        {
            Process.Start(psi);
        }
        catch
        {
        }
    }
}
