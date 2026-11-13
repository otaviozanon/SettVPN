using System;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Management.Automation;
using System.Management.Automation.Runspaces;

class SettVPNLauncher
{
    static string TempDir = Path.Combine(Path.GetTempPath(), "SettVPN");
    static string AppDir = Path.Combine(TempDir, "app");
    static Mutex InstanceMutex;
    static EventWaitHandle ActivateEvent;

    static string[] ScriptResources = new[]
    {
        "SettVPN_Full.ps1",
        "SettVPN_Gui.ps1",
        "settvpn.ico"
    };

    static string V2RayResource = "v2ray.exe";
    static string WintunResource = "wintun.dll";
    static string GeoIpResource = "geoip.bin";

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

        try
        {
            // O binario extraido roda elevado no modo TUN: um arquivo trocado em
            // repouso no %TEMP% nao pode passar. Hash, nao tamanho.
            using (MemoryStream buffered = new MemoryStream())
            {
                src.CopyTo(buffered);
                buffered.Position = 0;

                string expected;
                using (System.Security.Cryptography.SHA256 sha = System.Security.Cryptography.SHA256.Create())
                {
                    expected = Convert.ToBase64String(sha.ComputeHash(buffered));
                }
                buffered.Position = 0;

                if (File.Exists(dest))
                {
                    string actual = null;
                    try
                    {
                        using (FileStream fs = new FileStream(dest, FileMode.Open, FileAccess.Read, FileShare.Read))
                        using (System.Security.Cryptography.SHA256 sha = System.Security.Cryptography.SHA256.Create())
                        {
                            actual = Convert.ToBase64String(sha.ComputeHash(fs));
                        }
                    }
                    catch
                    {
                    }
                    if (actual == expected)
                    {
                        return true;
                    }
                }

                using (FileStream fs = new FileStream(dest, FileMode.Create, FileAccess.Write))
                {
                    buffered.CopyTo(fs);
                }
                return true;
            }
        }
        catch
        {
            return false;
        }
    }

    [STAThread]
    static void Main()
    {
        bool createdNew;
        InstanceMutex = new Mutex(true, "SettVPN_SingleInstance_Mutex", out createdNew);
        if (!createdNew)
        {
            // Segunda instancia: so avisa a primeira para trazer a janela de volta.
            try
            {
                using (EventWaitHandle ev = EventWaitHandle.OpenExisting("SettVPN_Activate"))
                {
                    ev.Set();
                }
            }
            catch
            {
            }
            return;
        }

        try
        {
            ActivateEvent = new EventWaitHandle(false, EventResetMode.AutoReset, "SettVPN_Activate");
        }
        catch
        {
        }

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

        using (Stream wintun = GetResourceStream(WintunResource))
        {
            if (!ExtractTo(wintun, Path.Combine(TempDir, "wintun.dll")))
            {
                return;
            }
        }

        using (Stream geoip = GetResourceStream(GeoIpResource))
        {
            if (!ExtractTo(geoip, Path.Combine(TempDir, "geoip.bin")))
            {
                return;
            }
        }

        string script = Path.Combine(AppDir, "SettVPN_Full.ps1");
        if (!File.Exists(script))
        {
            return;
        }

        try
        {
            string exePath = Assembly.GetExecutingAssembly().Location;
            Environment.SetEnvironmentVariable("SETTVPN_EXE", exePath, EnvironmentVariableTarget.Process);
        }
        catch
        {
        }

        try
        {
            using (Runspace runspace = RunspaceFactory.CreateRunspace())
            {
                runspace.ApartmentState = ApartmentState.STA;
                runspace.Open();

                using (PowerShell ps = PowerShell.Create())
                {
                    ps.Runspace = runspace;
                    ps.AddScript("& '" + script + "'");
                    ps.Invoke();
                }
            }
        }
        catch
        {
        }
    }
}
