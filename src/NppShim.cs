// npp-shim: registered as the IFEO "Debugger" for notepad.exe.
// Windows launches it as:  npp-shim.exe <original notepad command line>
// It drops the original notepad image token, translates Notepad switches,
// and opens the file in the configured editor (Notepad++ by default).
//
// Configuration (HKLM\SOFTWARE\NotepadWin11Replacement, written by Install.ps1):
//   EditorPath       full path to the editor executable
//   EditorArgs       argument template when a file is given, "{file}" = quoted full path (default: {file})
//   EditorPrintArgs  argument template for /p and /pt (default: EditorArgs, i.e. just open the file)
//   EditorNoFileArgs arguments when Notepad was started without a file (default: none)
// Installs from before EditorPath existed only have NotepadPlusPlusPath; that still works.
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: System.Reflection.AssemblyTitle("Notepad -> alternative editor redirector")]
[assembly: System.Reflection.AssemblyVersion("1.1.0.0")]

static class NppShim
{
    const string ConfigKey = @"SOFTWARE\NotepadWin11Replacement";
    const string DefaultNpp = @"C:\Program Files\Notepad++\notepad++.exe";

    class EditorConfig
    {
        public string Path;
        public string Args = "{file}";
        public string PrintArgs;
        public string NoFileArgs = "";
    }

    [STAThread]
    static int Main()
    {
        string raw = Environment.CommandLine;
        try
        {
            int i = 0;
            SkipToken(raw, ref i);                 // npp-shim.exe itself
            string original = SkipToken(raw, ref i); // notepad.exe / WindowsApps\...\Notepad.exe
            string rest = raw.Substring(Math.Min(i, raw.Length)).Trim();

            bool dryRun = Environment.GetEnvironmentVariable("NPP_SHIM_DRYRUN") == "1";
            EditorConfig editor = LoadConfig(dryRun);

            bool print;
            string file = ParseNotepadArgs(rest, out print);
            string args = BuildEditorArgs(editor, file, print);
            Log(raw, original, editor.Path, args);

            if (dryRun)
                return 0;

            // The editor must never be notepad.exe: IFEO would send it straight back here.
            if (string.Equals(Path.GetFileName(editor.Path), "notepad.exe", StringComparison.OrdinalIgnoreCase))
            {
                ShowError("The configured editor is notepad.exe, which would loop back to this redirector:\n" + editor.Path);
                return 3;
            }
            if (!File.Exists(editor.Path))
            {
                ShowError("The configured editor was not found:\n" + editor.Path +
                    "\n\nReinstall it, re-run Install.ps1 -Editor ..., or run Uninstall.ps1.");
                return 2;
            }

            var psi = new ProcessStartInfo(editor.Path, args);
            psi.UseShellExecute = false;
            psi.WorkingDirectory = Environment.CurrentDirectory;
            Process.Start(psi);
            return 0;
        }
        catch (Exception ex)
        {
            Log(raw, "", "", "ERROR " + ex);
            return 1;
        }
    }

    // Notepad semantics: optional switches, then everything left is ONE file name
    // (spaces allowed without quotes). Returns "" when no file was given.
    static string ParseNotepadArgs(string rest, out bool print)
    {
        print = false;
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
        return file;
    }

    static string BuildEditorArgs(EditorConfig editor, string file, bool print)
    {
        if (file.Length == 0) return editor.NoFileArgs;
        string template = print && !string.IsNullOrEmpty(editor.PrintArgs) ? editor.PrintArgs : editor.Args;
        return template.Replace("{file}", "\"" + file + "\"").Trim();
    }

    static EditorConfig LoadConfig(bool dryRun)
    {
        var cfg = new EditorConfig();

        // Test hook (Test.ps1): dry-run never launches anything, so the editor may come from the
        // environment instead of the registry. Unset variables keep the built-in defaults.
        string testPath = Environment.GetEnvironmentVariable("NPP_SHIM_EDITOR_PATH");
        if (dryRun && testPath != null)
        {
            cfg.Path = testPath;
            cfg.Args = Environment.GetEnvironmentVariable("NPP_SHIM_EDITOR_ARGS") ?? cfg.Args;
            cfg.PrintArgs = Environment.GetEnvironmentVariable("NPP_SHIM_EDITOR_PRINTARGS");
            cfg.NoFileArgs = Environment.GetEnvironmentVariable("NPP_SHIM_EDITOR_NOFILEARGS") ?? cfg.NoFileArgs;
            return cfg;
        }

        using (var k = Registry.LocalMachine.OpenSubKey(ConfigKey))
        {
            string path = Get(k, "EditorPath");
            if (path != null)
            {
                cfg.Path = path;
                cfg.Args = Get(k, "EditorArgs") ?? cfg.Args;
                cfg.PrintArgs = Get(k, "EditorPrintArgs");
                cfg.NoFileArgs = Get(k, "EditorNoFileArgs") ?? cfg.NoFileArgs;
            }
            else
            {
                // Pre-1.1 install: Notepad++ only.
                cfg.Path = Get(k, "NotepadPlusPlusPath") ?? DefaultNpp;
                cfg.PrintArgs = "-quickPrint {file}";
            }
        }
        return cfg;
    }

    static string Get(RegistryKey k, string name)
    {
        var v = k == null ? null : k.GetValue(name) as string;
        return string.IsNullOrEmpty(v) ? null : v;
    }

    static void ShowError(string message)
    {
        MessageBox.Show(message, "Notepad redirect", MessageBoxButtons.OK, MessageBoxIcon.Error);
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

    static void Log(string raw, string original, string editor, string args)
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
            File.AppendAllText(log, string.Format("{0:o}\traw={1}\toriginal={2}\teditor={3}\targs={4}{5}",
                DateTime.Now, raw, original, editor, args, Environment.NewLine), Encoding.UTF8);
        }
        catch { }
    }
}
