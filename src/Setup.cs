// NotepadRedirect-Setup.exe: self-contained installer.
// Embeds the release zip (payload.zip), extracts it to a temp folder and runs Install.ps1 / Uninstall.ps1
// with Windows PowerShell. Elevation comes from setup.manifest (requireAdministrator).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Text;

static class Setup
{
    class Options
    {
        public string Editor;
        public string EditorPath;
        public string EditorArgs;
        public string PrintArgs;
        public bool? RemoveStoreNotepad;
        public bool Uninstall;
        public bool Quiet;
        public bool Help;
    }

    const string Usage =
@"NotepadRedirect-Setup {0}: open Notepad++ (or another editor) whenever Notepad is launched.

Usage: NotepadRedirect-Setup.exe [options]
  (no options)              interactive: choose the editor from a menu
  --editor <name>           NotepadPlusPlus (default), VSCode, SublimeText, Notepad3 or Custom
  --editor-path <path>      editor executable (required with Custom)
  --editor-args <template>  open arguments, {{file}} = quoted path (default from the preset)
  --print-args <template>   arguments for Notepad's /p print
  --keep-store-notepad      do not uninstall the Windows 11 Store Notepad
                            (default: remove it, otherwise its Start menu entry bypasses the redirect)
  --uninstall               remove the redirect
  --quiet                   no prompts (for scripts / Intune / GPO)
  --help                    this text

Exit code 0 = success.";

    static int Main(string[] argv)
    {
        Options o;
        try { o = Parse(argv); }
        catch (ArgumentException ex) { Console.Error.WriteLine(ex.Message); Console.Error.WriteLine("Run with --help for usage."); return 64; }
        if (o.Help) { Console.WriteLine(Usage, BuildInfo.Version); return 0; }

        bool interactive = !o.Quiet && argv.Length == 0;
        string work = Path.Combine(Path.GetTempPath(), "NotepadWin11Replacement-setup-" + Guid.NewGuid().ToString("N"));
        int code;
        try
        {
            Console.WriteLine("NotepadRedirect-Setup " + BuildInfo.Version);
            Extract(work);

            if (o.Uninstall)
            {
                code = RunPowerShell(Script(Path.Combine(work, "Uninstall.ps1"), new List<string>()));
            }
            else
            {
                if (interactive && !Prompt(o, work)) { code = 1; }
                else code = RunPowerShell(Script(Path.Combine(work, "Install.ps1"), InstallArgs(o)));
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("Setup failed: " + ex.Message);
            code = 1;
        }
        finally
        {
            try { Directory.Delete(work, true); } catch { }
        }

        Console.WriteLine(code == 0 ? "Done." : "Failed (exit code " + code + ").");
        if (interactive)
        {
            Console.Write("Press Enter to close...");
            Console.ReadLine();
        }
        return code;
    }

    static Options Parse(string[] a)
    {
        var o = new Options();
        for (int i = 0; i < a.Length; i++)
        {
            string arg = a[i].ToLowerInvariant();
            switch (arg)
            {
                case "--editor": o.Editor = Value(a, ref i); break;
                case "--editor-path": o.EditorPath = Value(a, ref i); break;
                case "--editor-args": o.EditorArgs = Value(a, ref i); break;
                case "--print-args": o.PrintArgs = Value(a, ref i); break;
                case "--keep-store-notepad": o.RemoveStoreNotepad = false; break;
                case "--uninstall": o.Uninstall = true; break;
                case "--quiet": case "/quiet": case "/q": o.Quiet = true; break;
                case "--help": case "-h": case "/?": o.Help = true; break;
                default: throw new ArgumentException("Unknown option: " + a[i]);
            }
        }
        return o;
    }

    static string Value(string[] a, ref int i)
    {
        if (i + 1 >= a.Length) throw new ArgumentException(a[i] + " needs a value.");
        return a[++i];
    }

    // Interactive menu; editor list comes from Install.ps1 -ListEditors (single source of truth).
    static bool Prompt(Options o, string work)
    {
        string listing = CapturePowerShell(Script(Path.Combine(work, "Install.ps1"), new List<string> { "-ListEditors" }));
        var keys = new List<string>();
        Console.WriteLine();
        Console.WriteLine("Which editor should open instead of Notepad?");
        foreach (string line in listing.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries))
        {
            string[] f = line.Split('\t');
            if (f.Length < 2) continue;
            keys.Add(f[0]);
            string state = f[0] == "Custom" ? "(enter a path)" : (f.Length > 2 && f[2].Length > 0 ? "installed: " + f[2] : "not found");
            Console.WriteLine("  {0}. {1,-20} {2}", keys.Count, f[1], state);
        }
        if (keys.Count == 0) throw new InvalidOperationException("Could not read the editor list:\n" + listing);

        Console.Write("Choice [1]: ");
        string choice = (Console.ReadLine() ?? "").Trim();
        int n = 1;
        if (choice.Length > 0 && (!int.TryParse(choice, out n) || n < 1 || n > keys.Count))
        {
            Console.WriteLine("Invalid choice.");
            return false;
        }
        o.Editor = keys[n - 1];
        if (o.Editor == "Custom")
        {
            Console.Write("Editor executable path: ");
            o.EditorPath = (Console.ReadLine() ?? "").Trim().Trim('"');
        }

        Console.Write("Uninstall the Windows 11 Store Notepad so its Start menu entry can't bypass the redirect? [Y/n]: ");
        string yn = (Console.ReadLine() ?? "").Trim().ToLowerInvariant();
        o.RemoveStoreNotepad = !(yn == "n" || yn == "no");
        Console.WriteLine();
        return true;
    }

    static List<string> InstallArgs(Options o)
    {
        var args = new List<string>();
        if (o.Editor != null) { args.Add("-Editor"); args.Add(Quote(o.Editor)); }
        if (o.EditorPath != null) { args.Add("-EditorPath"); args.Add(Quote(o.EditorPath)); }
        if (o.EditorArgs != null) { args.Add("-EditorArgs"); args.Add(Quote(o.EditorArgs)); }
        if (o.PrintArgs != null) { args.Add("-EditorPrintArgs"); args.Add(Quote(o.PrintArgs)); }
        if (o.RemoveStoreNotepad ?? true) args.Add("-RemoveStoreNotepad");
        return args;
    }

    // PowerShell single-quoted literal: no expansion; ' is escaped as ''.
    static string Quote(string s) { return "'" + s.Replace("'", "''") + "'"; }

    // All streams are merged into stdout (*>&1) and errors are written with Write-Output: when stderr
    // is redirected, Windows PowerShell serialises host/progress records to it as CLIXML.
    static string Script(string ps1, List<string> args)
    {
        return "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'; " +
               "try { & " + Quote(ps1) + " " + string.Join(" ", args) + " *>&1 | Out-Host; exit 0 } " +
               "catch { Write-Output ('ERROR: ' + $_); exit 1 }";
    }

    static ProcessStartInfo PowerShell(string script)
    {
        string encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
        var psi = new ProcessStartInfo(
            Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"),
            // -OutputFormat Text: plain text even when our stdout is a pipe (Intune/GPO logs), not CLIXML.
            "-NoProfile -NonInteractive -ExecutionPolicy Bypass -OutputFormat Text -EncodedCommand " + encoded);
        psi.UseShellExecute = false;
        psi.RedirectStandardError = true;
        return psi;
    }

    static int RunPowerShell(string script)
    {
        string unused;
        return Run(script, false, out unused);
    }

    static string CapturePowerShell(string script)
    {
        string output;
        Run(script, true, out output);
        return output;
    }

    static int Run(string script, bool captureStdout, out string stdout)
    {
        var psi = PowerShell(script);
        psi.RedirectStandardOutput = captureStdout;
        var stderr = new StringBuilder();
        using (var p = new Process())
        {
            p.StartInfo = psi;
            p.ErrorDataReceived += (s, e) => { if (e.Data != null) lock (stderr) stderr.AppendLine(e.Data); };
            p.Start();
            p.BeginErrorReadLine();
            stdout = captureStdout ? p.StandardOutput.ReadToEnd() : null;
            p.WaitForExit();

            // Drop the CLIXML noise (progress/host records); anything else is a real error.
            foreach (string line in stderr.ToString().Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries))
                if (!line.StartsWith("#< CLIXML") && !line.StartsWith("<Objs")) Console.Error.WriteLine(line);
            return p.ExitCode;
        }
    }

    static void Extract(string work)
    {
        Directory.CreateDirectory(work);
        using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.zip"))
        {
            if (s == null) throw new InvalidOperationException("payload.zip is missing from this build.");
            using (var zip = new ZipArchive(s, ZipArchiveMode.Read))
            {
                foreach (var entry in zip.Entries)
                {
                    string target = Path.GetFullPath(Path.Combine(work, entry.FullName));
                    if (!target.StartsWith(work + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                        throw new InvalidOperationException("Unsafe path in payload: " + entry.FullName);
                    if (entry.Name.Length == 0) { Directory.CreateDirectory(target); continue; }
                    Directory.CreateDirectory(Path.GetDirectoryName(target));
                    entry.ExtractToFile(target, true);
                }
            }
        }
    }
}
