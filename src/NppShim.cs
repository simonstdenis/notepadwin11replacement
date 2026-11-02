// npp-shim: registered as the IFEO "Debugger" for notepad.exe.
// Windows launches it as:  npp-shim.exe <original notepad command line>
// It drops the original notepad image token, translates Notepad switches,
// and opens the file in Notepad++.
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: System.Reflection.AssemblyTitle("Notepad -> Notepad++ redirector")]
[assembly: System.Reflection.AssemblyVersion("1.0.0.0")]

static class NppShim
{
    const string ConfigKey = @"SOFTWARE\NotepadWin11Replacement";
    const string DefaultNpp = @"C:\Program Files\Notepad++\notepad++.exe";

    [STAThread]
    static int Main()
    {
        string raw = Environment.CommandLine;
        string nppArgs = "";
        try
        {
            int i = 0;
            SkipToken(raw, ref i);                 // npp-shim.exe itself
            string original = SkipToken(raw, ref i); // notepad.exe / WindowsApps\...\Notepad.exe
            string rest = raw.Substring(Math.Min(i, raw.Length)).Trim();

            nppArgs = BuildNppArgs(rest);
            string npp = GetNppPath();
            Log(raw, original, npp + " " + nppArgs);

            if (Environment.GetEnvironmentVariable("NPP_SHIM_DRYRUN") == "1")
                return 0;

            if (!File.Exists(npp))
            {
                MessageBox.Show("Notepad++ was not found at:\n" + npp +
                    "\n\nReinstall Notepad++ or run Uninstall.ps1.", "Notepad redirect",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 2;
            }

            var psi = new ProcessStartInfo(npp, nppArgs);
            psi.UseShellExecute = false;
            psi.WorkingDirectory = Environment.CurrentDirectory;
            Process.Start(psi);
            return 0;
        }
        catch (Exception ex)
        {
            Log(raw, "", "ERROR " + ex);
            return 1;
        }
    }

    // Notepad semantics: optional switches, then everything left is ONE file name
    // (spaces allowed without quotes).
    static string BuildNppArgs(string rest)
    {
        bool print = false;
        while (rest.Length > 0)
        {
            string sw = PeekSwitch(rest);
            if (sw == null) break;
            string upper = sw.ToUpperInvariant();
            if (upper == "/P") print = true;
            else if (upper == "/PT") print = true; // /PT file printer driver port -> keep file only
            else if (upper != "/A" && upper != "/W" && upper != "/.SETUP") break;
            rest = rest.Substring(sw.Length).TrimStart();
            if (upper == "/PT")
            {
                int j = 0;
                rest = SkipToken(rest, ref j);
            }
        }

        string file = rest.Trim();
        if (file.Length >= 2 && file[0] == '"')
        {
            int close = file.IndexOf('"', 1);
            file = close > 0 ? file.Substring(1, close - 1) : file.Substring(1);
        }
        if (file.Length == 0) return "";

        try { file = Path.GetFullPath(file); } catch { /* keep as given */ }
        string quoted = "\"" + file + "\"";
        return print ? "-quickPrint " + quoted : quoted;
    }

    static string PeekSwitch(string s)
    {
        if (s.Length < 2 || s[0] != '/') return null;
        int end = 1;
        while (end < s.Length && !char.IsWhiteSpace(s[end])) end++;
        return s.Substring(0, end);
    }

    // Windows-style token: "quoted token" or bare token up to whitespace.
    static string SkipToken(string s, ref int i)
    {
        while (i < s.Length && char.IsWhiteSpace(s[i])) i++;
        int start = i;
        if (i < s.Length && s[i] == '"')
        {
            i++;
            while (i < s.Length && s[i] != '"') i++;
            string tok = s.Substring(start + 1, i - start - 1);
            if (i < s.Length) i++;
            return tok;
        }
        while (i < s.Length && !char.IsWhiteSpace(s[i])) i++;
        return s.Substring(start, i - start);
    }

    static string GetNppPath()
    {
        using (var k = Registry.LocalMachine.OpenSubKey(ConfigKey))
        {
            var v = k == null ? null : k.GetValue("NotepadPlusPlusPath") as string;
            return string.IsNullOrEmpty(v) ? DefaultNpp : v;
        }
    }

    static void Log(string raw, string original, string launched)
    {
        try
        {
            string dir = Path.Combine(Environment.GetFolderPath(
                Environment.SpecialFolder.LocalApplicationData), "NotepadWin11Replacement");
            Directory.CreateDirectory(dir);
            string log = Path.Combine(dir, "shim.log");
            if (File.Exists(log) && new FileInfo(log).Length > 256 * 1024)
            {
                File.Copy(log, log + ".old", true);
                File.Delete(log);
            }
            File.AppendAllText(log, string.Format("{0:o}\traw={1}\toriginal={2}\tlaunch={3}{4}",
                DateTime.Now, raw, original, launched, Environment.NewLine), Encoding.UTF8);
        }
        catch { }
    }
}
