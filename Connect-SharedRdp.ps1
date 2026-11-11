#Requires -Version 5.1
<#
.SYNOPSIS
    Shows who is on a shared Remote Desktop machine before you connect, without
    disturbing them. Then connect, ask them, watch, or wait until it's free.

.DESCRIPTION
    With a shared account, connecting silently disconnects whoever is working:
    Windows only asks the signed-in person first when the incoming account is a
    different one. This script reads the machine's session list through the
    Remote Desktop Services API (the same data quser shows). Reading it never
    touches the session, so nobody is disconnected or prompted by the check.

    Statuses:
      FREE          nobody signed in (or no session for the shared account)
      DISCONNECTED  nobody watching; their apps are still running
      LOCKED        still connected, screen locked
      IDLE          connected and unlocked, no input for -IdleMinutes or more
      IN USE        input within the last -IdleMinutes
      BUSY          a -BusyProcess (for example a test runner) runs in the session
      CONNECTING    someone is signing in, or the session is changing state
      UNKNOWN       the check failed; the reason is shown

    Each status also shows who: the name and IP address of the computer they
    connected from, and when they signed in.

    For a window instead of the console, run SharedRdp-Dashboard.ps1 from the
    same folder; it uses this script for its checks.

    FREE, or DISCONNECTED for longer than -RecentDisconnectMinutes: Remote
    Desktop starts right away. Anything else, you choose:
      Connect anyway  take over (they are disconnected; their apps keep running)
      Ask them        a Yes/No box in their session; connects if they click Yes
      Watch           a view-only shadow window (needs admin rights by default)
      Notify me       re-check every -PollSeconds and pop up when it's free
      Refresh, Quit

.PARAMETER ComputerName
    One or more machines, as host or host:port. With several, you get a table
    and pick one; Enter takes the suggested free machine.

.PARAMETER RdpFile
    An .rdp file to connect with. Its "full address" is used when -ComputerName
    is omitted, and its "username" tells the script which account is shared.
    Together with -ComputerName it acts as a template (the host is set with /v:).

.PARAMETER UserName
    The shared account, for example LAB-07\tester. Only that account's session
    counts as the one you would take over; other sessions are listed for
    information. Defaults to the .rdp file's username, then -Credential's.

.PARAMETER Credential
    Account used for the check only (not for the Remote Desktop sign-in).
    Checking as the shared account itself usually works without extra
    permissions, because you are then looking at your own account's session.
    A bare user name means a local account on the target. When the target
    rejects the account or its password, "Notify me" stops instead of trying
    it again and again, which could lock the account out.

.PARAMETER StatusOnly
    Report only: outputs one object per machine (pipe it to Format-List *,
    ConvertTo-Json, a chat bot, ...). Nothing is started.

.PARAMETER IdleMinutes
    No input for this long turns IN USE into IDLE. Default 5.

.PARAMETER RecentDisconnectMinutes
    A session disconnected more recently than this asks before connecting,
    because its owner may be coming back. 0 never asks. Default 15.

.PARAMETER BusyProcess
    Process names that mean "automation is running" (wildcards allowed, .exe
    optional), for example TestExecute, vstest.console, robot*.

.PARAMETER AskTimeoutSeconds
    How long "Ask them" waits for an answer. Default 60.

.PARAMETER PollSeconds
    How often "Notify me when free" re-checks. Default 30.

.PARAMETER NoConsentPrompt
    "Watch" without asking the other person; works only if Group Policy allows it.

.PARAMETER MstscArgument
    Extra mstsc.exe arguments, for example '/f' or '/multimon'.

.PARAMETER SkipPortCheck
    Skip the quick TCP 445/135 reachability test that runs before each check.

.PARAMETER LogPath
    Also append every log line to this file, with timestamps: everything -Verbose
    shows, plus warnings and each status found. Useful for "Notify me" runs and
    for sending someone the details of a failed check.

.EXAMPLE
    .\Connect-SharedRdp.ps1 LAB-07

.EXAMPLE
    .\Connect-SharedRdp.ps1 -RdpFile \\fileserver\rdp\LAB-07.rdp

.EXAMPLE
    .\Connect-SharedRdp.ps1 LAB-01,LAB-02,LAB-03 -StatusOnly

.EXAMPLE
    .\Connect-SharedRdp.ps1 LAB-01,LAB-02,LAB-03 -RdpFile .\lab-template.rdp

    Lists the three machines and connects to the one you pick.

.EXAMPLE
    .\Connect-SharedRdp.ps1 LAB-07 -Credential LAB-07\tester -BusyProcess TestExecute,vstest.console

.EXAMPLE
    .\Connect-SharedRdp.ps1 192.168.222.90 -StatusOnly -Verbose -LogPath .\rdp-check.log

    Shows every step of the check (name resolution, port tests, the account
    used, the raw session data or the full error) and keeps it in a log file.

.NOTES
    Runs on Windows with Windows PowerShell 5.1 or PowerShell 7.

    One-time setup on each shared machine (as an administrator):
      - Windows 10/11 refuse remote session queries unless AllowRemoteRPC is 1:
          Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name AllowRemoteRPC -Value 1
      - The query uses SMB named pipes, so TCP 445 must be reachable from the
        people who check, e.g. the "File and Printer Sharing (SMB-In)" rule.
      - Another account's sessions can only be queried with the "Query
        Information" permission on the RDP listener; members of Remote Desktop
        Users have it by default.

    When a check fails, the status is UNKNOWN, the Detail column shows the
    Windows error message and code, and a warning says what to fix. Add -Verbose
    to see every step, and -LogPath to keep it in a file.

    "Ask them" needs the Message permission when the session belongs to another
    account (administrators have it); checking as the shared account avoids that.
    "Watch" runs mstsc /shadow, which by default needs administrator rights and
    the other person's consent. Through an RD Gateway the check can't reach the
    machine. Windows 7 and Server 2008 R2 report the lock state inverted.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string[]] $ComputerName,

    [string] $RdpFile,

    [string] $UserName,

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [switch] $StatusOnly,

    [ValidateRange(1, 1440)]
    [int] $IdleMinutes = 5,

    [ValidateRange(0, 10080)]
    [int] $RecentDisconnectMinutes = 15,

    [string[]] $BusyProcess = @(),

    [ValidateRange(10, 600)]
    [int] $AskTimeoutSeconds = 60,

    [ValidateRange(5, 3600)]
    [int] $PollSeconds = 30,

    [switch] $NoConsentPrompt,

    [string[]] $MstscArgument = @(),

    [switch] $SkipPortCheck,

    [string] $LogPath
)

$script:ScriptVersion = '1.5'

#region Native layer (Remote Desktop Services API)

$script:NativeSource = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security;

// The namespace changes with the code, because a PowerShell session keeps the
// first compiled copy of a type and cannot load a changed one under that name.
namespace SharedRdpV2
{
    public sealed class SessionRecord
    {
        public int SessionId;
        public string WinStationName = "";
        public int State = -1;              // WTS_CONNECTSTATE_CLASS
        public int Flags = -1;              // 0 = locked, 1 = unlocked, -1 = unknown
        public bool HasInfoEx;
        public string UserName = "";
        public string DomainName = "";
        public long LogonTime;              // FILETIME (UTC); 0 = not reported
        public long ConnectTime;
        public long DisconnectTime;
        public long LastInputTime;
        public long CurrentTime;            // the target's clock when queried
        public string ClientName = "";
        public string ClientAddress = "";
        public int ProtocolType = -1;       // 0 = console, 2 = RDP
        public int HorizontalResolution;
        public int VerticalResolution;
        public string Problems = "";
    }

    public sealed class ProcessRecord
    {
        public int SessionId;
        public int ProcessId;
        public string Name = "";
    }

    public static class Wts
    {
        const int WTSUserName = 5;
        const int WTSDomainName = 7;
        const int WTSClientName = 10;
        const int WTSClientAddress = 14;
        const int WTSClientDisplay = 15;
        const int WTSClientProtocolType = 16;
        const int WTSSessionInfoEx = 25;

        const int MB_YESNO = 0x4;
        const int MB_ICONQUESTION = 0x20;
        const int MB_DEFBUTTON2 = 0x100;
        const int MB_SETFOREGROUND = 0x10000;
        const int MB_TOPMOST = 0x40000;

        [StructLayout(LayoutKind.Sequential)]
        struct WTS_SESSION_INFO
        {
            public int SessionId;
            public IntPtr pWinStationName;
            public int State;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct WTS_PROCESS_INFO
        {
            public int SessionId;
            public int ProcessId;
            public IntPtr pProcessName;
            public IntPtr pUserSid;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct WTSINFOEX_LEVEL1
        {
            public int SessionId;
            public int SessionState;
            public int SessionFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 33)] public string WinStationName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 21)] public string UserName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 18)] public string DomainName;
            public long LogonTime;
            public long ConnectTime;
            public long DisconnectTime;
            public long LastInputTime;
            public long CurrentTime;
            public int IncomingBytes;
            public int OutgoingBytes;
            public int IncomingFrames;
            public int OutgoingFrames;
            public int IncomingCompressedBytes;
            public int OutgoingCompressedBytes;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct WTSINFOEX
        {
            public int Level;
            public WTSINFOEX_LEVEL1 Data;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct WTS_CLIENT_ADDRESS
        {
            public int AddressFamily;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 20)] public byte[] Address;
        }

        [DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "WTSOpenServerW")]
        static extern IntPtr WTSOpenServer(string serverName);

        [DllImport("wtsapi32.dll")]
        static extern void WTSCloseServer(IntPtr server);

        [DllImport("wtsapi32.dll", SetLastError = true, EntryPoint = "WTSEnumerateSessionsW")]
        static extern bool WTSEnumerateSessions(IntPtr server, int reserved, int version, out IntPtr sessionInfo, out int count);

        [DllImport("wtsapi32.dll", SetLastError = true, EntryPoint = "WTSQuerySessionInformationW")]
        static extern bool WTSQuerySessionInformation(IntPtr server, int sessionId, int infoClass, out IntPtr buffer, out int bytesReturned);

        [DllImport("wtsapi32.dll", SetLastError = true, EntryPoint = "WTSEnumerateProcessesW")]
        static extern bool WTSEnumerateProcesses(IntPtr server, int reserved, int version, out IntPtr processInfo, out int count);

        [DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "WTSSendMessageW")]
        static extern bool WTSSendMessage(IntPtr server, int sessionId, string title, int titleLength, string message, int messageLength, int style, int timeout, out int response, bool wait);

        [DllImport("wtsapi32.dll")]
        static extern void WTSFreeMemory(IntPtr memory);

        public static SessionRecord[] GetSessions(string server, string domain, string user, SecureString password)
        {
            using (Impersonation.Begin(domain, user, password))
            {
                IntPtr handle = OpenServer(server);
                try
                {
                    IntPtr buffer;
                    int count;
                    if (!WTSEnumerateSessions(handle, 0, 1, out buffer, out count))
                    {
                        int error = Marshal.GetLastWin32Error();
                        throw Errors.Wrap(error, "WTSEnumerateSessions on " + Describe(server));
                    }
                    SessionRecord[] records;
                    try { records = ParseSessionList(buffer, count); }
                    finally { WTSFreeMemory(buffer); }
                    foreach (SessionRecord r in records) FillDetails(handle, r);
                    return records;
                }
                finally { CloseServer(handle); }
            }
        }

        public static ProcessRecord[] GetProcesses(string server, string domain, string user, SecureString password)
        {
            using (Impersonation.Begin(domain, user, password))
            {
                IntPtr handle = OpenServer(server);
                try
                {
                    IntPtr buffer;
                    int count;
                    if (!WTSEnumerateProcesses(handle, 0, 1, out buffer, out count))
                    {
                        int error = Marshal.GetLastWin32Error();
                        throw Errors.Wrap(error, "WTSEnumerateProcesses on " + Describe(server));
                    }
                    try { return ParseProcessList(buffer, count); }
                    finally { WTSFreeMemory(buffer); }
                }
                finally { CloseServer(handle); }
            }
        }

        // Shows a Yes/No box in the session and waits for the answer.
        // Returns 6 (Yes), 7 (No) or 32000 (timed out).
        public static int AskSession(string server, int sessionId, string title, string message, int timeoutSeconds, string domain, string user, SecureString password)
        {
            if (title == null) title = "";
            if (message == null) message = "";
            if (timeoutSeconds < 1) timeoutSeconds = 1;
            using (Impersonation.Begin(domain, user, password))
            {
                IntPtr handle = OpenServer(server);
                try
                {
                    int response;
                    int style = MB_YESNO | MB_ICONQUESTION | MB_DEFBUTTON2 | MB_SETFOREGROUND | MB_TOPMOST;
                    // The length parameters are in bytes, not characters.
                    if (!WTSSendMessage(handle, sessionId, title, title.Length * 2, message, message.Length * 2, style, timeoutSeconds, out response, true))
                    {
                        int error = Marshal.GetLastWin32Error();
                        throw Errors.Wrap(error, "WTSSendMessage to session " + sessionId + " on " + Describe(server));
                    }
                    return response;
                }
                finally { CloseServer(handle); }
            }
        }

        static bool IsLocal(string server)
        {
            if (string.IsNullOrEmpty(server)) return true;
            string s = server.Trim();
            return s == "." || s == "127.0.0.1" || s == "::1"
                || string.Equals(s, "localhost", StringComparison.OrdinalIgnoreCase)
                || string.Equals(s, Environment.MachineName, StringComparison.OrdinalIgnoreCase);
        }

        static IntPtr OpenServer(string server)
        {
            if (IsLocal(server)) return IntPtr.Zero;    // WTS_CURRENT_SERVER_HANDLE
            IntPtr handle = WTSOpenServer(server);
            if (handle == IntPtr.Zero)
            {
                int error = Marshal.GetLastWin32Error();
                throw Errors.Wrap(error, "WTSOpenServer for " + server);
            }
            return handle;
        }

        static string Describe(string server)
        {
            return IsLocal(server) ? "this computer" : server;
        }

        static void CloseServer(IntPtr handle)
        {
            if (handle != IntPtr.Zero) WTSCloseServer(handle);
        }

        static int Query(IntPtr handle, int sessionId, int infoClass, out IntPtr buffer, out int bytes)
        {
            if (WTSQuerySessionInformation(handle, sessionId, infoClass, out buffer, out bytes)) return 0;
            int error = Marshal.GetLastWin32Error();
            buffer = IntPtr.Zero;
            bytes = 0;
            return error == 0 ? -1 : error;
        }

        static void Free(IntPtr buffer)
        {
            if (buffer != IntPtr.Zero) WTSFreeMemory(buffer);
        }

        static string QueryString(IntPtr handle, int sessionId, int infoClass)
        {
            IntPtr buffer;
            int bytes;
            if (Query(handle, sessionId, infoClass, out buffer, out bytes) != 0) return null;
            try { return buffer == IntPtr.Zero ? null : Marshal.PtrToStringUni(buffer); }
            finally { Free(buffer); }
        }

        static void AddProblem(SessionRecord r, string what, int code)
        {
            string p = what + " (" + code + ")";
            r.Problems = string.IsNullOrEmpty(r.Problems) ? p : r.Problems + "; " + p;
        }

        static void FillDetails(IntPtr handle, SessionRecord r)
        {
            IntPtr buffer;
            int bytes;
            int error = Query(handle, r.SessionId, WTSSessionInfoEx, out buffer, out bytes);
            bool haveEx = false;
            if (error == 0)
            {
                try { haveEx = ApplyInfoEx(buffer, bytes, r); }
                finally { Free(buffer); }
                if (!haveEx) AddProblem(r, "session info size", bytes);
            }
            else
            {
                AddProblem(r, "session info", error);
            }
            if (!haveEx)
            {
                string s = QueryString(handle, r.SessionId, WTSUserName);
                if (s != null) r.UserName = s;
                s = QueryString(handle, r.SessionId, WTSDomainName);
                if (s != null) r.DomainName = s;
            }
            if (string.IsNullOrEmpty(r.UserName)) return;     // nobody signed in to this one

            string name = QueryString(handle, r.SessionId, WTSClientName);
            if (name != null) r.ClientName = name;

            if (Query(handle, r.SessionId, WTSClientAddress, out buffer, out bytes) == 0)
            {
                try { r.ClientAddress = ParseClientAddress(buffer, bytes) ?? ""; }
                finally { Free(buffer); }
            }
            if (Query(handle, r.SessionId, WTSClientProtocolType, out buffer, out bytes) == 0)
            {
                try { if (buffer != IntPtr.Zero && bytes >= 2) r.ProtocolType = Marshal.ReadInt16(buffer) & 0xFFFF; }
                finally { Free(buffer); }
            }
            if (Query(handle, r.SessionId, WTSClientDisplay, out buffer, out bytes) == 0)
            {
                try { ApplyDisplay(buffer, bytes, r); }
                finally { Free(buffer); }
            }
        }

        internal static SessionRecord[] ParseSessionList(IntPtr buffer, int count)
        {
            List<SessionRecord> list = new List<SessionRecord>();
            if (buffer == IntPtr.Zero || count <= 0) return list.ToArray();
            int size = Marshal.SizeOf(typeof(WTS_SESSION_INFO));
            for (int i = 0; i < count; i++)
            {
                IntPtr item = new IntPtr(buffer.ToInt64() + (long)i * size);
                WTS_SESSION_INFO info = (WTS_SESSION_INFO)Marshal.PtrToStructure(item, typeof(WTS_SESSION_INFO));
                SessionRecord r = new SessionRecord();
                r.SessionId = info.SessionId;
                r.State = info.State;
                if (info.pWinStationName != IntPtr.Zero) r.WinStationName = Marshal.PtrToStringUni(info.pWinStationName) ?? "";
                list.Add(r);
            }
            return list.ToArray();
        }

        internal static ProcessRecord[] ParseProcessList(IntPtr buffer, int count)
        {
            List<ProcessRecord> list = new List<ProcessRecord>();
            if (buffer == IntPtr.Zero || count <= 0) return list.ToArray();
            int size = Marshal.SizeOf(typeof(WTS_PROCESS_INFO));
            for (int i = 0; i < count; i++)
            {
                IntPtr item = new IntPtr(buffer.ToInt64() + (long)i * size);
                WTS_PROCESS_INFO info = (WTS_PROCESS_INFO)Marshal.PtrToStructure(item, typeof(WTS_PROCESS_INFO));
                ProcessRecord p = new ProcessRecord();
                p.SessionId = info.SessionId;
                p.ProcessId = info.ProcessId;
                if (info.pProcessName != IntPtr.Zero) p.Name = Marshal.PtrToStringUni(info.pProcessName) ?? "";
                list.Add(p);
            }
            return list.ToArray();
        }

        internal static bool ApplyInfoEx(IntPtr buffer, int bytes, SessionRecord r)
        {
            if (buffer == IntPtr.Zero || bytes < Marshal.SizeOf(typeof(WTSINFOEX))) return false;
            WTSINFOEX info = (WTSINFOEX)Marshal.PtrToStructure(buffer, typeof(WTSINFOEX));
            if (info.Level != 1) return false;
            WTSINFOEX_LEVEL1 d = info.Data;
            r.HasInfoEx = true;
            r.State = d.SessionState;
            r.Flags = d.SessionFlags;
            r.UserName = d.UserName ?? "";
            r.DomainName = d.DomainName ?? "";
            if (string.IsNullOrEmpty(r.WinStationName)) r.WinStationName = d.WinStationName ?? "";
            r.LogonTime = d.LogonTime;
            r.ConnectTime = d.ConnectTime;
            r.DisconnectTime = d.DisconnectTime;
            r.LastInputTime = d.LastInputTime;
            r.CurrentTime = d.CurrentTime;
            return true;
        }

        internal static string ParseClientAddress(IntPtr buffer, int bytes)
        {
            if (buffer == IntPtr.Zero || bytes < Marshal.SizeOf(typeof(WTS_CLIENT_ADDRESS))) return null;
            WTS_CLIENT_ADDRESS a = (WTS_CLIENT_ADDRESS)Marshal.PtrToStructure(buffer, typeof(WTS_CLIENT_ADDRESS));
            return FormatAddress(a.AddressFamily, a.Address);
        }

        // The IP address starts two bytes into Address, for IPv4 and IPv6 alike
        // (see the remarks on WTS_CLIENT_ADDRESS).
        public static string FormatAddress(int family, byte[] a)
        {
            if (a == null || a.Length < 18) return null;
            if (family == 2)                // AF_INET
            {
                if (a[2] == 0 && a[3] == 0 && a[4] == 0 && a[5] == 0) return null;
                return string.Format("{0}.{1}.{2}.{3}", a[2], a[3], a[4], a[5]);
            }
            if (family == 23)               // AF_INET6
            {
                byte[] b = new byte[16];
                Array.Copy(a, 2, b, 0, 16);
                bool empty = true;
                foreach (byte x in b) { if (x != 0) { empty = false; break; } }
                if (empty) return null;
                return new System.Net.IPAddress(b).ToString();
            }
            return null;
        }

        internal static void ApplyDisplay(IntPtr buffer, int bytes, SessionRecord r)
        {
            if (buffer == IntPtr.Zero || bytes < 12) return;
            r.HorizontalResolution = Marshal.ReadInt32(buffer, 0);
            r.VerticalResolution = Marshal.ReadInt32(buffer, 4);
        }
    }

    // Like "runas /netonly": the given credentials are used only for network
    // access (the RPC calls to the target), on this thread, until disposed.
    internal sealed class Impersonation : IDisposable
    {
        IntPtr token = IntPtr.Zero;
        bool active;

        Impersonation() { }

        internal static Impersonation Begin(string domain, string user, SecureString password)
        {
            Impersonation imp = new Impersonation();
            if (string.IsNullOrEmpty(user)) return imp;
            if (domain != null && domain.Length == 0) domain = null;
            IntPtr secret = IntPtr.Zero;
            try
            {
                if (password != null) secret = Marshal.SecureStringToGlobalAllocUnicode(password);
                // LOGON32_LOGON_NEW_CREDENTIALS (9) with LOGON32_PROVIDER_WINNT50 (3)
                if (!NativeAuth.LogonUser(user, domain, secret, 9, 3, out imp.token))
                {
                    int error = Marshal.GetLastWin32Error();
                    throw Errors.Wrap(error, "LogonUser for " + (domain == null ? user : domain + "\\" + user));
                }
            }
            finally
            {
                if (secret != IntPtr.Zero) Marshal.ZeroFreeGlobalAllocUnicode(secret);
            }
            if (!NativeAuth.ImpersonateLoggedOnUser(imp.token))
            {
                int error = Marshal.GetLastWin32Error();
                imp.Dispose();
                throw Errors.Wrap(error, "ImpersonateLoggedOnUser");
            }
            imp.active = true;
            return imp;
        }

        public void Dispose()
        {
            if (active)
            {
                NativeAuth.RevertToSelf();
                active = false;
            }
            if (token != IntPtr.Zero)
            {
                NativeAuth.CloseHandle(token);
                token = IntPtr.Zero;
            }
        }
    }

    // Win32 errors that name the step that failed, e.g.
    // "WTSEnumerateSessions on LAB-07 failed: Access is denied." (NativeErrorCode 5).
    // Callers read Marshal.GetLastWin32Error() first, before anything else can reset it.
    internal static class Errors
    {
        internal static Win32Exception Wrap(int code, string step)
        {
            string text = new Win32Exception(code).Message;
            return new Win32Exception(code, step + " failed: " + text);
        }
    }

    internal static class NativeAuth
    {
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "LogonUserW")]
        internal static extern bool LogonUser(string user, string domain, IntPtr password, int logonType, int logonProvider, out IntPtr token);

        [DllImport("advapi32.dll", SetLastError = true)]
        internal static extern bool ImpersonateLoggedOnUser(IntPtr token);

        [DllImport("advapi32.dll", SetLastError = true)]
        internal static extern bool RevertToSelf();

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool CloseHandle(IntPtr handle);
    }
}
'@

function Initialize-Native {
    if (-not ('SharedRdpV2.Wts' -as [type])) {
        Add-Type -TypeDefinition $script:NativeSource -Language CSharp -ErrorAction Stop
    }
}

function Get-RawSessions {
    param([string] $ComputerName, [System.Management.Automation.PSCredential] $Credential)
    $c = ConvertTo-NativeCredential -Credential $Credential -ComputerName $ComputerName
    if ($c.User) {
        $signIn = $c.User
        if ($c.Domain) { $signIn = '{0}\{1}' -f $c.Domain, $c.User }
        Write-CheckLog -Message ('{0}: network sign-in as {1} with the password given' -f $ComputerName, $signIn)
    }
    [SharedRdpV2.Wts]::GetSessions($ComputerName, $c.Domain, $c.User, $c.Password)
}

function Get-RawProcesses {
    param([string] $ComputerName, [System.Management.Automation.PSCredential] $Credential)
    $c = ConvertTo-NativeCredential -Credential $Credential -ComputerName $ComputerName
    [SharedRdpV2.Wts]::GetProcesses($ComputerName, $c.Domain, $c.User, $c.Password)
}

function Send-AskMessage {
    param([string] $ComputerName, [int] $SessionId, [string] $Title, [string] $Message, [int] $TimeoutSeconds, [System.Management.Automation.PSCredential] $Credential)
    $c = ConvertTo-NativeCredential -Credential $Credential -ComputerName $ComputerName
    [SharedRdpV2.Wts]::AskSession($ComputerName, $SessionId, $Title, $Message, $TimeoutSeconds, $c.Domain, $c.User, $c.Password)
}

#endregion

#region Helpers

function Test-IsWindows {
    if ($PSVersionTable.PSVersion.Major -le 5) { return $true }
    return [bool](Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue)
}

function Test-IsLocalName {
    param([string] $Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $true }
    $n = $Name.Trim()
    return ($n -eq '.' -or $n -eq 'localhost' -or $n -eq '127.0.0.1' -or $n -eq '::1' -or $n -eq [Environment]::MachineName)
}

function Get-NetbiosGuess {
    # For a local account on the target: "lab07.corp.local" -> "lab07".
    param([string] $ComputerName)
    $ip = $null
    if ([System.Net.IPAddress]::TryParse($ComputerName, [ref] $ip)) { return $ComputerName }
    return ($ComputerName -split '\.')[0]
}

function ConvertTo-NativeCredential {
    param([System.Management.Automation.PSCredential] $Credential, [string] $ComputerName)
    if ($null -eq $Credential -or $Credential -eq [System.Management.Automation.PSCredential]::Empty) {
        return [pscustomobject]@{ Domain = $null; User = $null; Password = $null }
    }
    $name = $Credential.UserName
    $domain = $null
    $user = $name
    if ($name -match '^(?<d>[^\\]+)\\(?<u>.+)$') {
        $domain = $Matches['d']
        $user = $Matches['u']
    }
    elseif ($name -notlike '*@*') {
        $domain = Get-NetbiosGuess -ComputerName $ComputerName
    }
    if ($domain -eq '.') { $domain = Get-NetbiosGuess -ComputerName $ComputerName }
    return [pscustomobject]@{ Domain = $domain; User = $user; Password = $Credential.Password }
}

function Get-SystemSessionMeaning {
    # What a session without a signed-in user is, in plain words.
    param([string] $Name, [int] $State)
    if ($Name -eq 'Services') { return 'where Windows services run; never a person' }
    if ($State -eq 6) { return 'the Remote Desktop listener; it waits for incoming connections' }
    if ($Name -like 'Console*') {
        if ($State -eq 1) { return 'the machine''s own screen and keyboard, showing the sign-in screen' }
        return 'the machine''s own screen and keyboard; nobody signed in'
    }
    if ($State -eq 1 -or $State -eq 2) { return 'someone is connecting over Remote Desktop and has not signed in yet' }
    if ($State -eq 5) { return 'a spare session kept ready for the next connection' }
    if ($State -eq 4) { return 'a session that is closing after sign-out' }
    if ($State -ge 7) { return 'a session that is starting up or closing' }
    return 'nobody signed in'
}

function ConvertTo-TargetCredential {
    # The -Credential account with the domain part the session query uses: a bare
    # user name means a local account on the target (HOST\user).
    param([System.Management.Automation.PSCredential] $Credential, [string] $ComputerName)
    if ($null -eq $Credential -or $Credential -eq [System.Management.Automation.PSCredential]::Empty) { return $null }
    $c = ConvertTo-NativeCredential -Credential $Credential -ComputerName $ComputerName
    $name = [string] $c.User
    if ($c.Domain) { $name = '{0}\{1}' -f $c.Domain, $c.User }
    return (New-Object System.Management.Automation.PSCredential -ArgumentList $name, $Credential.Password)
}

function Get-UserLeaf {
    param([string] $Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    $leaf = ($Name.Trim() -split '\\')[-1]
    return ($leaf -split '@')[0]
}

function Split-HostPort {
    param([string] $Address)
    $a = $Address.Trim()
    if ($a -match '^\[(?<h>[^\]]+)\](:(?<p>\d+))?$') {
        return [pscustomobject]@{ Host = $Matches['h']; Port = $Matches['p'] }
    }
    if ($a -match '^(?<h>[^:]+):(?<p>\d+)$') {
        return [pscustomobject]@{ Host = $Matches['h']; Port = $Matches['p'] }
    }
    return [pscustomobject]@{ Host = $a; Port = $null }
}

function Format-MstscHost {
    # mstsc reads /v:host:port, so a bare IPv6 address goes in brackets.
    param([string] $Address)
    $a = ([string] $Address).Trim()
    $ip = $null
    if ($a.Contains(':') -and -not $a.StartsWith('[') -and [System.Net.IPAddress]::TryParse($a, [ref] $ip) -and
        $ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
        return ('[{0}]' -f $a)
    }
    return $a
}

function Test-SignInRejected {
    # True for the Win32 errors that mean the machine or its domain refused the
    # account or its password. Trying the same password again cannot help, and
    # every try counts toward the account's lockout threshold.
    param($Code)
    if ($null -eq $Code) { return $false }
    return (@(86, 1244, 1312, 1326, 1327, 1328, 1329, 1330, 1331, 1385, 1907, 1909) -contains [int] $Code)
}

function ConvertFrom-FileTime {
    param([long] $Value)
    if ($Value -le 0) { return $null }
    try { return [DateTime]::FromFileTimeUtc($Value) } catch { return $null }
}

function Format-Duration {
    param([TimeSpan] $Span)
    if ($Span -lt [TimeSpan]::Zero) { $Span = [TimeSpan]::Zero }
    if ($Span.TotalSeconds -lt 60) { return ('{0} s' -f [int][Math]::Floor($Span.TotalSeconds)) }
    if ($Span.TotalMinutes -lt 60) { return ('{0} min' -f [int][Math]::Floor($Span.TotalMinutes)) }
    if ($Span.TotalHours -lt 24) { return ('{0} h {1} min' -f [int][Math]::Floor($Span.TotalHours), $Span.Minutes) }
    return ('{0} d {1} h' -f $Span.Days, $Span.Hours)
}

function Get-StateName {
    param([int] $State)
    $names = @('Active', 'Connected', 'ConnectQuery', 'Shadow', 'Disconnected', 'Idle', 'Listen', 'Reset', 'Down', 'Init')
    if ($State -ge 0 -and $State -lt $names.Count) { return $names[$State] }
    return ('State{0}' -f $State)
}

function Get-StatusRank {
    param([string] $Status)
    switch ($Status) {
        'Busy'         { return 7 }
        'InUse'        { return 6 }
        'Connecting'   { return 5 }
        'Idle'         { return 4 }
        'Locked'       { return 3 }
        'Disconnected' { return 2 }
        'Free'         { return 1 }
    }
    return 0
}

function Get-StatusLabel {
    param([string] $Status)
    switch ($Status) {
        'Free'         { return 'FREE' }
        'Disconnected' { return 'DISCONNECTED' }
        'Locked'       { return 'LOCKED' }
        'Idle'         { return 'IDLE' }
        'InUse'        { return 'IN USE' }
        'Busy'         { return 'BUSY' }
        'Connecting'   { return 'CONNECTING' }
    }
    return 'UNKNOWN'
}

function Get-StatusColor {
    param([string] $Status)
    switch ($Status) {
        'Free'         { return 'Green' }
        'Disconnected' { return 'Cyan' }
        'Locked'       { return 'Yellow' }
        'Idle'         { return 'Yellow' }
        'InUse'        { return 'Red' }
        'Busy'         { return 'Magenta' }
        'Connecting'   { return 'Red' }
    }
    return 'DarkYellow'
}

function Get-StatusAdvice {
    param([string] $Status)
    switch ($Status) {
        'Free'         { return 'Connecting starts a new session for this account.' }
        'Disconnected' { return 'Nobody is watching; their apps are still running and you will pick up their desktop.' }
        'Locked'       { return 'They stepped away but are still connected; connecting cuts their window off.' }
        'Idle'         { return 'Connected and unlocked, but no input for a while; ask first.' }
        'InUse'        { return 'Someone is working right now; connecting cuts them off without warning.' }
        'Busy'         { return 'Automation is running in this session; connecting may break it.' }
        'Connecting'   { return 'Someone is signing in right now.' }
    }
    return 'The check failed, so nobody knows whether the machine is in use.'
}

function Get-Win32Code {
    param($ErrorRecord)
    $ex = $ErrorRecord.Exception
    while ($null -ne $ex) {
        if ($ex -is [System.ComponentModel.Win32Exception]) { return $ex.NativeErrorCode }
        $ex = $ex.InnerException
    }
    return $null
}

function Get-FailureHint {
    # What to do about a Win32 error from the session API, in plain words. With
    # -Gui the advice names the dashboard's Account field instead of -Credential.
    param($Code, [string] $Operation = 'Query', [bool] $HasCredential = $false, [string] $CheckingAs = '', [bool] $Gui = $false)
    $as = ''
    if ($CheckingAs) { $as = 'You checked as {0}. ' -f $CheckingAs }
    $localAccount = (-not $HasCredential -and $CheckingAs -match '^([^\\]+)\\' -and $Matches[1] -eq [Environment]::MachineName)
    $signInFix = 'Use -Credential with an account that machine knows, typically the shared account as HOST\user.'
    if ($HasCredential) { $signInFix = 'Check the -Credential user name and password; for a local account on that machine use HOST\user.' }
    $asShared = 'running with -Credential set to the shared account'
    $useShared = 'use -Credential with the shared account'
    $useAccount = 'Use -Credential with an account on that machine, typically the shared account: -Credential <machine name>\<user>.'
    if ($Gui) {
        $signInFix = 'Type an account that machine knows, typically the shared account, and its password.'
        if ($HasCredential) { $signInFix = 'Check the account name and password; a bare name such as Administrator means a local account on that machine.' }
        $asShared = 'checking as the shared account'
        $useShared = 'check as the shared account'
        $useAccount = 'Type an account on that machine, typically the shared account, and its password.'
    }
    switch ($Code) {
        5 {
            if ($Operation -eq 'Ask') {
                return ('Messaging a session of another account needs the Message permission on that machine (administrators have it); {0} avoids that.' -f $asShared)
            }
            return ('{0}On Windows 10/11 the target needs AllowRemoteRPC=1, and the checking account needs permission to query sessions there: members of Remote Desktop Users have it, otherwise {1}.' -f $as, $useShared)
        }
        { Test-SignInRejected -Code $_ } {
            return ('{0}That machine did not accept this sign-in. {1}' -f $as, $signInFix)
        }
        { $_ -in 1717, 1722, 1723, 1726, 1727, 1745, 1753 } {
            return 'The machine answers on the network, but its Remote Desktop session service did not answer the remote query. On Windows 10/11 set AllowRemoteRPC=1 on it, make sure Remote Desktop is enabled there, and that its firewall allows File and Printer Sharing (SMB-In). Through an RD Gateway this check cannot work.'
        }
        { $_ -in 2, 50, 120 } {
            return 'The machine accepted the connection but has no Remote Desktop session service to query. Make sure it runs Windows with Remote Desktop enabled; on Windows 10/11 also set AllowRemoteRPC=1.'
        }
        { $_ -in 53, 59, 64, 67, 121, 1203, 1225, 1231, 1232 } {
            return 'Connecting over SMB failed: the name does not resolve, or TCP 445 is blocked on the way.'
        }
        { $_ -in 1265, 1311, 1351, 1355, 1789, 1825, 1908 } {
            return ('{0}Authentication failed before the query reached the machine. With an IP address Windows can only use NTLM; try its host name instead. {1}' -f $as, $signInFix)
        }
        1219 {
            return 'You already have a connection to that machine under another user name (for example a mapped drive or an open share). Disconnect it, or check with the same account.'
        }
        259 {
            $why = 'The machine accepted the connection but listed no sessions at all. Windows leaves out every session the caller may not query, so this account is not allowed to see any session there.'
            if ($HasCredential) {
                return ('{0} Use the shared account or a member of Remote Desktop Users or Administrators on that machine; on Windows 10/11 also check that AllowRemoteRPC is 1 there.' -f $why)
            }
            $whose = $as
            if ($localAccount) { $whose = 'You checked as {0}, a local account of this PC; the other machine either does not know it or maps it to an account with no rights there. ' -f $CheckingAs }
            return ('{0} {1}{2} If that also lists nothing, set AllowRemoteRPC=1 there.' -f $why, $whose, $useAccount)
        }
    }
    return ''
}

function Get-FailureText {
    # Turns an error into: Reason (one line for tables), Text (step, reason and fix) and Code.
    param(
        $ErrorRecord,
        [ValidateSet('Query', 'Processes', 'Ask')] [string] $Operation = 'Query',
        [hashtable] $Settings = @{}
    )
    $code = Get-Win32Code -ErrorRecord $ErrorRecord
    $inner = $ErrorRecord.Exception
    while ($null -ne $inner.InnerException) { $inner = $inner.InnerException }
    $message = ([string] $inner.Message).Trim().TrimEnd('.')
    if ($null -ne $code) {
        $system = ([string] (New-Object System.ComponentModel.Win32Exception -ArgumentList ([int] $code)).Message).Trim().TrimEnd('.')
        if ($code -eq 259) { $system = 'no sessions visible to this account' }
        $reason = '{0} (error {1})' -f $system, $code
        $text = '{0} (error {1})' -f $message, $code
    }
    else {
        # Not a Windows API error: show the exception type so it can be reported.
        $reason = '{0}: {1}' -f $inner.GetType().Name, $message
        $text = $reason
    }
    $hasCredential = ($null -ne $Settings.Credential -and $Settings.Credential -ne [System.Management.Automation.PSCredential]::Empty)
    $hint = Get-FailureHint -Code $code -Operation $Operation -HasCredential $hasCredential -CheckingAs ([string] $Settings.CheckingAs) -Gui ([bool] $Settings.Gui)
    if ($hint) { $text = '{0}. {1}' -f $text, $hint }
    return [pscustomobject]@{ Code = $code; Reason = $reason; Hint = $hint; Text = $text }
}

function Format-ExceptionChain {
    param($ErrorRecord)
    $parts = @()
    $ex = $ErrorRecord.Exception
    while ($null -ne $ex) {
        $native = ''
        if ($ex -is [System.ComponentModel.Win32Exception]) { $native = ', Win32 error {0}' -f $ex.NativeErrorCode }
        $parts += ('{0} (HRESULT 0x{1:X8}{2}): {3}' -f $ex.GetType().FullName, $ex.HResult, $native, $ex.Message)
        $ex = $ex.InnerException
    }
    $chain = $parts -join ' <- inner: '
    if ($ErrorRecord.ScriptStackTrace) { $chain += ' | ' + (($ErrorRecord.ScriptStackTrace -split "`r?`n") -join ' / ') }
    return $chain
}

function Format-FileTimeForLog {
    param([long] $Value)
    $t = ConvertFrom-FileTime -Value $Value
    if ($null -eq $t) { return '-' }
    return $t.ToString('yyyy-MM-dd HH:mm:ss') + 'Z'
}

function Write-CheckLog {
    # Verbose and Warning lines go to their PowerShell streams; with -LogPath
    # every line is also appended to the file. 'File' lines go only to the file.
    param([ValidateSet('Verbose', 'Warning', 'File')] [string] $Level = 'Verbose', [string] $Message = '')
    if ($Level -eq 'Verbose') { Write-Verbose $Message }
    elseif ($Level -eq 'Warning') { Write-Warning $Message }
    $path = Get-Variable -Name LogFile -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($path) {
        $line = '{0:yyyy-MM-dd HH:mm:ss.fff}  {1,-7}  {2}' -f (Get-Date), $Level.ToUpper(), $Message
        try { Add-Content -LiteralPath $path -Value $line -Encoding UTF8 -ErrorAction Stop }
        catch {
            Write-Warning ('Could not write to the log file {0}: {1}. Logging to the file is now off.' -f $path, $_.Exception.Message)
            $script:LogFile = $null
        }
    }
}

function Add-DefaultView {
    param([Parameter(Mandatory = $true)] $Object, [string[]] $Property)
    $set = New-Object System.Management.Automation.PSPropertySet('DefaultDisplayPropertySet', [string[]] $Property)
    $members = [System.Management.Automation.PSMemberInfo[]] @($set)
    $Object | Add-Member -MemberType MemberSet -Name PSStandardMembers -Value $members -Force
    return $Object
}

#endregion

#region Status model

function ConvertTo-SessionView {
    param(
        [Parameter(Mandatory = $true)] $Raw,
        [int] $IdleMinutes = 5,
        [string[]] $BusyNames = @()
    )
    $now = ConvertFrom-FileTime -Value $Raw.CurrentTime
    if ($null -eq $now) { $now = [DateTime]::UtcNow }
    $logon = ConvertFrom-FileTime -Value $Raw.LogonTime
    $connectedAt = ConvertFrom-FileTime -Value $Raw.ConnectTime
    $lastInput = ConvertFrom-FileTime -Value $Raw.LastInputTime
    $disconnectedAt = ConvertFrom-FileTime -Value $Raw.DisconnectTime

    # Windows reports no last-input time for console sessions. A last input that
    # isn't later than the latest connect can't tell "untouched" from "not
    # updated", so it is treated as unknown rather than shown as idle.
    $idle = $null
    $idleNote = 'idle time not reported'
    if ($null -ne $lastInput) {
        if ($null -ne $connectedAt -and $lastInput -le $connectedAt.AddSeconds(5)) {
            $idleNote = 'no input recorded since they connected {0} ago' -f (Format-Duration -Span ($now - $connectedAt))
        }
        else {
            $idle = $now - $lastInput
            if ($idle -lt [TimeSpan]::Zero) { $idle = [TimeSpan]::Zero }
        }
    }
    $locked = $null
    if ($Raw.HasInfoEx) {
        if ($Raw.Flags -eq 0) { $locked = $true }
        elseif ($Raw.Flags -eq 1) { $locked = $false }
    }

    $disconnectedFor = $null
    $status = 'Connecting'
    $detail = ''
    switch ([int] $Raw.State) {
        0 {
            if ($locked -eq $true) {
                $status = 'Locked'
                $detail = 'screen locked'
                if ($null -ne $idle) { $detail = 'screen locked, idle {0}' -f (Format-Duration -Span $idle) }
            }
            elseif ($null -eq $idle) {
                $status = 'InUse'
                $detail = 'active ({0})' -f $idleNote
            }
            elseif ($idle.TotalMinutes -lt $IdleMinutes) {
                $status = 'InUse'
                $detail = 'last input {0} ago' -f (Format-Duration -Span $idle)
            }
            else {
                $status = 'Idle'
                $detail = 'idle {0}' -f (Format-Duration -Span $idle)
            }
        }
        3 {
            $status = 'InUse'
            $detail = 'shadowing another session'
        }
        4 {
            $status = 'Disconnected'
            $detail = 'disconnected'
            if ($null -ne $disconnectedAt) {
                $disconnectedFor = $now - $disconnectedAt
                if ($disconnectedFor -lt [TimeSpan]::Zero) { $disconnectedFor = [TimeSpan]::Zero }
                $detail = 'disconnected {0} ago' -f (Format-Duration -Span $disconnectedFor)
            }
        }
        default {
            $status = 'Connecting'
            $detail = 'signing in or changing state ({0})' -f (Get-StateName -State $Raw.State)
        }
    }

    $busy = @($BusyNames | Where-Object { $_ })
    if ($busy.Count -gt 0) {
        $status = 'Busy'
        $detail = 'automation running: {0}; {1}' -f ($busy -join ', '), $detail
    }

    # Windows reports protocol 0 ("console") for every session without a client,
    # so a disconnected Remote Desktop session would look like the console. The
    # station name tells them apart: "Console", "RDP-Tcp#N", or empty when disconnected.
    $station = [string] $Raw.WinStationName
    $protocol = ''
    if ($station -like 'Console*') { $protocol = 'Console' }
    elseif ($station -like 'RDP-Tcp*' -or [int] $Raw.ProtocolType -eq 2) { $protocol = 'RDP' }
    elseif ([int] $Raw.ProtocolType -eq 1) { $protocol = 'ICA' }
    $resolution = ''
    if ($Raw.HorizontalResolution -gt 0 -and $Raw.VerticalResolution -gt 0) {
        $resolution = '{0}x{1}' -f $Raw.HorizontalResolution, $Raw.VerticalResolution
    }
    $user = [string] $Raw.UserName
    if ($Raw.DomainName) { $user = '{0}\{1}' -f $Raw.DomainName, $Raw.UserName }
    $logonLocal = $null
    $signedInFor = $null
    if ($null -ne $logon) {
        $logonLocal = $logon.ToLocalTime()
        $signedInFor = $now - $logon
        if ($signedInFor -lt [TimeSpan]::Zero) { $signedInFor = [TimeSpan]::Zero }
    }
    $disconnectLocal = $null
    if ($null -ne $disconnectedAt) { $disconnectLocal = $disconnectedAt.ToLocalTime() }
    $lastInputLocal = $null
    if ($null -ne $lastInput) { $lastInputLocal = $lastInput.ToLocalTime() }
    $stateName = Get-StateName -State $Raw.State
    $rank = Get-StatusRank -Status $status

    return [pscustomobject]@{
        SessionId       = [int] $Raw.SessionId
        UserName        = [string] $Raw.UserName
        User            = $user
        State           = $stateName
        Status          = $status
        Detail          = $detail
        Locked          = $locked
        IdleTime        = $idle
        IdleNote        = $idleNote
        DisconnectedFor = $disconnectedFor
        DisconnectTime  = $disconnectLocal
        LastInputTime   = $lastInputLocal
        LogonTime       = $logonLocal
        SignedInFor     = $signedInFor
        WinStationName  = $station
        Client          = [string] $Raw.ClientName
        ClientAddress   = [string] $Raw.ClientAddress
        Protocol        = $protocol
        Resolution      = $resolution
        BusyProcesses   = $busy
        Problems        = [string] $Raw.Problems
        Rank            = $rank
    }
}

function Format-Who {
    param($Session)
    if ($null -eq $Session) { return '' }
    if ($Session.Protocol -eq 'Console') { return ('{0}, at the console' -f $Session.User) }
    $from = ''
    if ($Session.Client) { $from = $Session.Client }
    elseif ($Session.ClientAddress) { $from = $Session.ClientAddress }
    if ($from) { return ('{0} @ {1}' -f $Session.User, $from) }
    return [string] $Session.User
}

function New-HostResult {
    param([string] $ComputerName, [string] $TargetUser)
    $checkedAt = Get-Date
    $result = [pscustomobject]@{
        PSTypeName    = 'SharedRdp.HostStatus'
        ComputerName  = $ComputerName
        Status        = 'Unknown'
        Detail        = ''
        Who           = ''
        User          = ''
        Client        = ''
        ClientAddress = ''
        SessionId     = $null
        Session       = $null
        OtherSessions  = @()
        Sessions       = @()
        SystemSessions = @()
        TargetUser    = $TargetUser
        Error         = ''
        ErrorCode     = $null
        Notes         = @()
        CheckedAt     = $checkedAt
        CheckedAs     = ''
        DurationMs    = $null
    }
    return (Add-DefaultView -Object $result -Property ComputerName, Status, Detail, Who)
}

function New-UnknownResult {
    param($Target, [string] $Reason, [string] $Text, $Code = $null)
    $result = New-HostResult -ComputerName $Target.Name -TargetUser $Target.TargetUser
    $result.Status = 'Unknown'
    $result.Detail = $Reason
    $result.Error = $Text
    $result.ErrorCode = $Code
    return $result
}

function Resolve-HostStatus {
    param(
        [Parameter(Mandatory = $true)] [string] $ComputerName,
        [object[]] $Sessions = @(),
        [string] $TargetUser
    )
    $result = New-HostResult -ComputerName $ComputerName -TargetUser $TargetUser
    $withUser = @($Sessions | Where-Object { $null -ne $_ -and $_.UserName })
    $leaf = Get-UserLeaf -Name $TargetUser
    if ($leaf) {
        $mine = @($withUser | Where-Object { $_.UserName -eq $leaf })
        $others = @($withUser | Where-Object { $_.UserName -ne $leaf })
    }
    else {
        $mine = $withUser
        $others = @()
    }
    $result.Sessions = $withUser
    $result.OtherSessions = $others
    if ($mine.Count -eq 0) {
        $result.Status = 'Free'
        if ($others.Count -gt 0) { $result.Detail = 'no session for {0}; other accounts are signed in' -f $leaf }
        else { $result.Detail = 'nobody signed in' }
        if (@($others | Where-Object { $_.State -eq 'Active' }).Count -gt 0) {
            $result.Notes = @($result.Notes) + 'another account is connected; on Windows 10/11 only one session can be connected at a time, so Windows would ask them to make room'
        }
        return $result
    }
    $pick = @($mine | Sort-Object -Property Rank -Descending)[0]
    $result.Status = $pick.Status
    $result.Detail = $pick.Detail
    $result.Session = $pick
    $result.SessionId = $pick.SessionId
    $result.User = $pick.User
    $result.Client = $pick.Client
    $result.ClientAddress = $pick.ClientAddress
    $result.Who = Format-Who -Session $pick
    return $result
}

function Test-TcpPort {
    # 'open' when one of the addresses accepts a connection on the port, or else
    # why not: 'no answer', or the error of the last address tried. Each address
    # gets a socket of its own family: the default TcpClient of Windows
    # PowerShell 5.1 is IPv4 only, so it could never reach an IPv6 address.
    param([System.Net.IPAddress[]] $Address, [int] $Port, [int] $TimeoutMs = 1500)
    $why = 'no address to try'
    foreach ($ip in @($Address | Where-Object { $null -ne $_ } | Select-Object -First 4)) {
        $client = $null
        try {
            $client = New-Object System.Net.Sockets.TcpClient -ArgumentList $ip.AddressFamily
            $attempt = $client.BeginConnect($ip, $Port, $null, $null)
            if ($attempt.AsyncWaitHandle.WaitOne($TimeoutMs)) {
                $client.EndConnect($attempt)
                return 'open'
            }
            $why = 'no answer'
        }
        catch {
            $why = $_.Exception.GetBaseException().Message.Trim()
        }
        finally {
            if ($null -ne $client) { $client.Close() }
        }
    }
    return $why
}

function Test-QueryReachable {
    param([string] $HostName)
    $ok = [pscustomobject]@{ Ok = $true; Reason = ''; Text = '' }
    if (Test-IsLocalName -Name $HostName) {
        Write-CheckLog -Message ('{0}: this computer, no network check needed' -f $HostName)
        return $ok
    }
    try {
        $addresses = @([System.Net.Dns]::GetHostAddresses($HostName))
        Write-CheckLog -Message ('{0}: resolves to {1}' -f $HostName, (@($addresses | ForEach-Object { $_.IPAddressToString }) -join ', '))
    }
    catch {
        Write-CheckLog -Message ('{0}: name resolution failed: {1}' -f $HostName, (Format-ExceptionChain -ErrorRecord $_))
        return [pscustomobject]@{ Ok = $false; Reason = 'name not found'; Text = ("Can't resolve '{0}': {1}" -f $HostName, $_.Exception.GetBaseException().Message) }
    }
    foreach ($port in 445, 135) {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $state = Test-TcpPort -Address $addresses -Port $port
        Write-CheckLog -Message ('{0}: TCP {1} {2} ({3} ms)' -f $HostName, $port, $state, $watch.ElapsedMilliseconds)
        if ($state -eq 'open') { return $ok }
    }
    return [pscustomobject]@{
        Ok     = $false
        Reason = 'TCP 445 and 135 closed or filtered'
        Text   = ("Can't reach {0} on TCP 445 (SMB) or 135 (RPC), which the check needs. Make sure it's on and its firewall allows File and Printer Sharing (SMB-In). Through an RD Gateway this check can't work." -f $HostName)
    }
}

function Get-BusySessionMap {
    param([string] $ComputerName, [System.Management.Automation.PSCredential] $Credential, [string[]] $Pattern)
    $map = @{}
    $patterns = @($Pattern | Where-Object { $_ } | ForEach-Object { $_ -replace '\.exe$', '' })
    if ($patterns.Count -eq 0) { return $map }
    $all = @(Get-RawProcesses -ComputerName $ComputerName -Credential $Credential)
    Write-CheckLog -Message ('{0}: {1} processes listed, looking for {2}' -f $ComputerName, $all.Count, ($patterns -join ', '))
    foreach ($p in $all) {
        if ($null -eq $p -or -not $p.Name) { continue }
        $base = $p.Name -replace '\.exe$', ''
        foreach ($pat in $patterns) {
            if ($base -like $pat) {
                $key = [int] $p.SessionId
                if (-not $map.ContainsKey($key)) { $map[$key] = New-Object System.Collections.Generic.List[string] }
                if (-not $map[$key].Contains([string] $p.Name)) { $map[$key].Add([string] $p.Name) }
                Write-CheckLog -Message ('{0}: busy process {1} (PID {2}) in session {3}' -f $ComputerName, $p.Name, $p.ProcessId, $key)
                break
            }
        }
    }
    return $map
}

function Get-HostStatus {
    param([Parameter(Mandatory = $true)] $Target, [Parameter(Mandatory = $true)] [hashtable] $Settings)
    $total = [System.Diagnostics.Stopwatch]::StartNew()
    if ($Settings.SkipPortCheck) {
        Write-CheckLog -Message ('{0}: port check skipped' -f $Target.QueryHost)
    }
    else {
        $reach = Test-QueryReachable -HostName $Target.QueryHost
        if (-not $reach.Ok) {
            if (-not $Settings.Gui -and $reach.Reason -like 'TCP*') { $reach.Text += ' Use -SkipPortCheck to try anyway.' }
            $result = New-UnknownResult -Target $Target -Reason $reach.Reason -Text $reach.Text
            $result.CheckedAs = [string] $Settings.CheckingAs
            $result.DurationMs = $total.ElapsedMilliseconds
            Write-CheckLog -Message ('{0}: UNKNOWN - {1}' -f $Target.Name, $reach.Text)
            return $result
        }
    }
    Write-CheckLog -Message ('{0}: querying sessions as {1}' -f $Target.QueryHost, $Settings.CheckingAs)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $raw = @(Get-RawSessions -ComputerName $Target.QueryHost -Credential $Settings.Credential)
    }
    catch {
        $failure = Get-FailureText -ErrorRecord $_ -Operation Query -Settings $Settings
        Write-CheckLog -Message ('{0}: session query failed after {1} ms: {2}' -f $Target.QueryHost, $watch.ElapsedMilliseconds, (Format-ExceptionChain -ErrorRecord $_))
        Write-CheckLog -Message ('{0}: UNKNOWN - {1}' -f $Target.Name, $failure.Text)
        $result = New-UnknownResult -Target $Target -Reason $failure.Reason -Text $failure.Text -Code $failure.Code
        $result.CheckedAs = [string] $Settings.CheckingAs
        $result.DurationMs = $total.ElapsedMilliseconds
        return $result
    }
    Write-CheckLog -Message ('{0}: {1} sessions in {2} ms' -f $Target.QueryHost, $raw.Count, $watch.ElapsedMilliseconds)
    foreach ($r in $raw) {
        if ($null -eq $r) { continue }
        $who = '(nobody: {0})' -f (Get-SystemSessionMeaning -Name $r.WinStationName -State $r.State)
        if ($r.UserName) { $who = '"{0}\{1}"' -f $r.DomainName, $r.UserName }
        Write-CheckLog -Message ('{0}:   session {1} "{2}" state={3} user={4} lockFlag={5} logon={6} connect={7} disconnect={8} lastInput={9} now={10} client="{11}" address="{12}" protocol={13} display={14}x{15} problems="{16}"' -f
            $Target.QueryHost, $r.SessionId, $r.WinStationName, (Get-StateName -State $r.State), $who, $r.Flags,
            (Format-FileTimeForLog -Value $r.LogonTime), (Format-FileTimeForLog -Value $r.ConnectTime), (Format-FileTimeForLog -Value $r.DisconnectTime),
            (Format-FileTimeForLog -Value $r.LastInputTime), (Format-FileTimeForLog -Value $r.CurrentTime),
            $r.ClientName, $r.ClientAddress, $r.ProtocolType, $r.HorizontalResolution, $r.VerticalResolution, $r.Problems)
    }
    $busy = @{}
    $notes = @()
    if (@($Settings.BusyProcess | Where-Object { $_ }).Count -gt 0) {
        try {
            $busy = Get-BusySessionMap -ComputerName $Target.QueryHost -Credential $Settings.Credential -Pattern $Settings.BusyProcess
        }
        catch {
            $failure = Get-FailureText -ErrorRecord $_ -Operation Processes -Settings $Settings
            $notes += ('busy check skipped: {0}' -f $failure.Reason)
            Write-CheckLog -Level Warning -Message ('{0}: busy check skipped: {1}' -f $Target.QueryHost, $failure.Text)
            Write-CheckLog -Message ('{0}: process list failed: {1}' -f $Target.QueryHost, (Format-ExceptionChain -ErrorRecord $_))
        }
    }
    $views = @()
    foreach ($r in $raw) {
        if ($null -eq $r -or -not $r.UserName) { continue }
        $names = @()
        if ($busy.ContainsKey([int] $r.SessionId)) { $names = @($busy[[int] $r.SessionId]) }
        $views += ConvertTo-SessionView -Raw $r -IdleMinutes $Settings.IdleMinutes -BusyNames $names
    }
    # Sessions nobody is signed in to: services, the console's sign-in screen, the
    # listener, or someone connecting who has not signed in yet.
    $system = @()
    foreach ($r in $raw) {
        if ($null -eq $r -or $r.UserName) { continue }
        $system += [pscustomobject]@{
            SessionId = [int] $r.SessionId
            Name      = [string] $r.WinStationName
            State     = Get-StateName -State $r.State
            Meaning   = Get-SystemSessionMeaning -Name $r.WinStationName -State $r.State
        }
    }
    $arriving = @($system | Where-Object { $_.Name -notlike 'Console*' -and $_.Name -ne 'Services' -and ($_.State -eq 'Connected' -or $_.State -eq 'ConnectQuery') })
    $result = Resolve-HostStatus -ComputerName $Target.Name -Sessions $views -TargetUser $Target.TargetUser
    $result.SystemSessions = $system
    if ($arriving.Count -gt 0) {
        $notes += ('someone is connecting over Remote Desktop right now (session {0}) and has not signed in yet' -f (($arriving | ForEach-Object { $_.SessionId }) -join ', '))
        if ($result.Status -eq 'Free') {
            $result.Status = 'Connecting'
            $result.Detail = 'someone is at the Remote Desktop sign-in screen'
        }
    }
    $result.Notes = @($result.Notes) + $notes
    $result.CheckedAs = [string] $Settings.CheckingAs
    $result.DurationMs = $total.ElapsedMilliseconds
    $whoPart = ''
    if ($result.Who) { $whoPart = ' - ' + $result.Who }
    Write-CheckLog -Message ('{0}: {1} - {2}{3}' -f $Target.Name, (Get-StatusLabel -Status $result.Status), $result.Detail, $whoPart)
    return $result
}

function Get-XmlChildText {
    param($Node, [string] $Name)
    if ($null -eq $Node) { return '' }
    foreach ($child in @($Node.ChildNodes)) {
        if ($child.LocalName -eq $Name) { return [string] $child.InnerText }
    }
    return ''
}

function Get-LastClientMap {
    # Client addresses per session ID, newest first, from the target's Remote
    # Desktop session log (TerminalServices-LocalSessionManager/Operational:
    # 21 sign-in, 24 disconnect, 25 reconnect). Windows forgets the client of a
    # disconnected session; this log keeps it until the log wraps. Reading it
    # remotely needs the target's "Remote Event Log Management" firewall rules and
    # an account that may read its logs (Administrators or Event Log Readers).
    param([string] $ComputerName, [System.Management.Automation.PSCredential] $Credential, [int] $MaxEvents = 3000)
    $query = @{
        FilterHashtable = @{ LogName = 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'; Id = 21, 24, 25 }
        MaxEvents       = $MaxEvents
        ErrorAction     = 'Stop'
    }
    if (-not (Test-IsLocalName -Name $ComputerName)) {
        $query.ComputerName = $ComputerName
        # Get-WinEvent takes -Credential only together with -ComputerName.
        $networkCredential = ConvertTo-TargetCredential -Credential $Credential -ComputerName $ComputerName
        if ($null -ne $networkCredential) { $query.Credential = $networkCredential }
    }
    Write-CheckLog -Message ('{0}: reading the Remote Desktop session log (newest {1} sign-in, disconnect and reconnect events)' -f $ComputerName, $MaxEvents)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $events = @()
    try {
        $events = @(Get-WinEvent @query)
    }
    catch {
        if ([string] $_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') {
            Write-CheckLog -Message ('{0}: the session log has no sign-in, disconnect or reconnect events' -f $ComputerName)
            return @{}
        }
        throw
    }
    $map = @{}
    foreach ($e in $events) {
        $data = $null
        try {
            $doc = [xml] $e.ToXml()
            foreach ($node in @($doc.DocumentElement.ChildNodes)) {
                if ($node.LocalName -eq 'UserData') { $data = $node.FirstChild }
            }
        }
        catch { continue }
        if ($null -eq $data) { continue }
        $id = 0
        if (-not [int]::TryParse((Get-XmlChildText -Node $data -Name 'SessionID'), [ref] $id)) { continue }
        $address = Get-XmlChildText -Node $data -Name 'Address'
        if (-not $address) { continue }
        if (-not $map.ContainsKey($id)) { $map[$id] = New-Object System.Collections.Generic.List[object] }
        $map[$id].Add([pscustomobject]@{
            SessionId = $id
            Time      = $e.TimeCreated
            EventId   = [int] $e.Id
            User      = Get-XmlChildText -Node $data -Name 'User'
            Address   = $address
        })
    }
    Write-CheckLog -Message ('{0}: {1} events in {2} ms; client addresses for sessions {3}' -f $ComputerName, $events.Count, $watch.ElapsedMilliseconds, (@($map.Keys | Sort-Object) -join ', '))
    return $map
}

function Find-LastClient {
    # The newest logged client of a session: same session ID, same user, and not
    # older than the session's own sign-in (session IDs are reused).
    param($Map, $Session)
    if ($null -eq $Map -or $null -eq $Session) { return $null }
    $key = [int] $Session.SessionId
    if (-not $Map.ContainsKey($key)) { return $null }
    $leaf = Get-UserLeaf -Name $Session.User
    foreach ($entry in $Map[$key]) {
        if ($null -ne $Session.LogonTime -and $entry.Time -lt $Session.LogonTime.AddMinutes(-2)) { continue }
        if ($leaf -and $entry.User -and (Get-UserLeaf -Name $entry.User) -ne $leaf) { continue }
        return $entry
    }
    return $null
}

#endregion

#region Display and choices

function Write-Field {
    param([string] $Label, [string] $Text, [string] $Color = '')
    $line = '  {0,-9} {1}' -f $Label, $Text
    if ($Color) { Write-Host $line -ForegroundColor $Color } else { Write-Host $line }
}

function Show-HostStatus {
    param([Parameter(Mandatory = $true)] $Result)
    Write-Host ''
    Write-Host ('{0}  ' -f $Result.ComputerName) -NoNewline
    Write-Host (Get-StatusLabel -Status $Result.Status) -ForegroundColor (Get-StatusColor -Status $Result.Status) -NoNewline
    if ($Result.Detail) { Write-Host ('  {0}' -f $Result.Detail) } else { Write-Host '' }
    if ($Result.Status -eq 'Unknown' -and $Result.Error) { Write-Field -Label 'Why' -Text $Result.Error -Color DarkYellow }

    $s = $Result.Session
    if ($null -ne $s) {
        $text = '{0}, {1}' -f $s.SessionId, $s.User
        if ($s.Protocol) { $text += ', ' + $s.Protocol }
        if ($null -ne $s.LogonTime) { $text += (', signed in {0:yyyy-MM-dd HH:mm}' -f $s.LogonTime) }
        Write-Field -Label 'Session' -Text $text
        $from = @()
        if ($s.Protocol -eq 'Console') { $from += 'at the physical console' }
        if ($s.Client) { $from += $s.Client }
        if ($s.ClientAddress) { $from += $s.ClientAddress }
        if ($s.Resolution) { $from += $s.Resolution }
        if ($from.Count -eq 0) {
            if ($s.Status -eq 'Disconnected') { $from += 'not kept by Windows after a disconnect' }
            else { $from += '(not reported)' }
        }
        $label = 'From'
        if ($s.Status -eq 'Disconnected') { $label = 'Last from' }
        Write-Field -Label $label -Text ($from -join '   ')
        if ($s.Problems) { Write-Field -Label 'Note' -Text ('some details unavailable: {0}' -f $s.Problems) -Color DarkGray }
    }
    foreach ($o in @($Result.OtherSessions)) {
        Write-Field -Label 'Also' -Text ('{0} (session {1}): {2}' -f $o.User, $o.SessionId, $o.Detail) -Color DarkGray
    }
    foreach ($n in @($Result.Notes)) {
        if ($n) { Write-Field -Label 'Note' -Text $n -Color DarkGray }
    }
    Write-Host ('  -> {0}' -f (Get-StatusAdvice -Status $Result.Status)) -ForegroundColor Gray
}

function Get-AutoAction {
    param([Parameter(Mandatory = $true)] $Result, [int] $RecentDisconnectMinutes = 15)
    if ($Result.Status -eq 'Free') { return 'Connect' }
    if ($Result.Status -eq 'Disconnected') {
        $s = $Result.Session
        if ($null -ne $s -and $null -ne $s.DisconnectedFor -and $s.DisconnectedFor.TotalMinutes -ge $RecentDisconnectMinutes) { return 'Connect' }
    }
    return 'Prompt'
}

function Get-MenuFor {
    param([Parameter(Mandatory = $true)] $Result)
    switch ($Result.Status) {
        'Unknown'      { return [pscustomobject]@{ Options = @('Connect', 'Refresh', 'Quit'); Default = 'Quit' } }
        'Disconnected' { return [pscustomobject]@{ Options = @('ConnectNow', 'Refresh', 'Quit'); Default = 'ConnectNow' } }
        'Busy'         { return [pscustomobject]@{ Options = @('Connect', 'Watch', 'Notify', 'Refresh', 'Quit'); Default = 'Notify' } }
        'Connecting'   { return [pscustomobject]@{ Options = @('Connect', 'Notify', 'Refresh', 'Quit'); Default = 'Notify' } }
    }
    return [pscustomobject]@{ Options = @('Connect', 'Ask', 'Watch', 'Notify', 'Refresh', 'Quit'); Default = 'Ask' }
}

function Read-Choice {
    param([string[]] $Option, [string] $Default, [string] $Message = 'What now?')
    $text = @{
        Connect    = @('&Connect anyway', 'Take over now. They are disconnected; their apps keep running.')
        ConnectNow = @('&Connect', 'Connect now.')
        Ask        = @('&Ask them', 'Show a Yes/No box in their session and wait for the answer.')
        Watch      = @('&Watch', 'Open a view-only shadow window (needs admin rights by default).')
        Notify     = @('&Notify me when free', 'Re-check regularly and pop up when the machine is free.')
        Refresh    = @('&Refresh', 'Check again.')
        Quit       = @('&Quit', 'Do nothing.')
    }
    $choices = New-Object 'System.Collections.ObjectModel.Collection[System.Management.Automation.Host.ChoiceDescription]'
    foreach ($o in $Option) {
        $choices.Add((New-Object System.Management.Automation.Host.ChoiceDescription -ArgumentList $text[$o][0], $text[$o][1]))
    }
    $index = [Array]::IndexOf($Option, $Default)
    if ($index -lt 0) { $index = 0 }
    try { $picked = $Host.UI.PromptForChoice('', $Message, $choices, $index) }
    catch { return 'Quit' }
    if ($picked -lt 0 -or $picked -ge $Option.Count) { return 'Quit' }
    return $Option[$picked]
}

function Read-Line {
    param([string] $Prompt)
    return (Read-Host -Prompt $Prompt)
}

function Show-Popup {
    param([string] $Text, [string] $Title)
    try {
        $shell = New-Object -ComObject WScript.Shell
        # 4 = Yes/No buttons, 64 = information icon, 4096 = stays on top
        $answer = $shell.Popup($Text, 0, $Title, 4 + 64 + 4096)
        if ($answer -eq 6) { return 'Yes' }
        return 'No'
    }
    catch {
        $typed = Read-Line -Prompt ('{0} [Y/n]' -f $Text)
        if ($typed -match '^\s*n') { return 'No' }
        return 'Yes'
    }
}

function Test-QuitKey {
    try {
        while ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Q -or $key.Key -eq [ConsoleKey]::Escape) { return $true }
        }
    }
    catch {
        # No console to read keys from (input redirected): only Ctrl+C stops.
        return $false
    }
    return $false
}

function Wait-OrQuit {
    param([int] $Seconds)
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-QuitKey) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

#endregion

#region Actions

function Start-Rdp {
    param([Parameter(Mandatory = $true)] $Target, [string[]] $ExtraArgument = @())
    $parts = New-Object System.Collections.Generic.List[string]
    if ($Target.RdpFile) { $parts.Add(('"{0}"' -f $Target.RdpFile)) }
    if (-not $Target.RdpFile -or $Target.OverrideHost) { $parts.Add(('/v:{0}' -f (Format-MstscHost -Address $Target.Name))) }
    foreach ($a in @($ExtraArgument)) { if ($a) { $parts.Add([string] $a) } }
    $line = $parts -join ' '
    Write-Host ('Starting Remote Desktop: mstsc {0}' -f $line) -ForegroundColor DarkGray
    Write-CheckLog -Level File -Message ('Starting Remote Desktop: mstsc {0}' -f $line)
    Start-Process -FilePath 'mstsc.exe' -ArgumentList $line
}

function Start-Shadow {
    param([Parameter(Mandatory = $true)] $Target, [int] $SessionId, [switch] $NoConsentPrompt)
    $line = '/v:{0} /shadow:{1}' -f (Format-MstscHost -Address $Target.QueryHost), $SessionId
    if ($NoConsentPrompt) { $line += ' /noConsentPrompt' }
    Write-Host ('Opening a view-only window: mstsc {0}' -f $line) -ForegroundColor DarkGray
    Write-CheckLog -Level File -Message ('Opening a view-only window: mstsc {0}' -f $line)
    Start-Process -FilePath 'mstsc.exe' -ArgumentList $line
}

function Get-AskMessage {
    # The Yes/No box shown in the other person's session.
    param([int] $TimeoutSeconds = 60)
    $requester = '{0} on {1}' -f [Environment]::UserName, [Environment]::MachineName
    $message = ("{0} wants to use this remote session.`n`n" +
        "Yes: let them take over now. Your window disconnects; your apps keep running.`n" +
        "No: keep working.`n`n" +
        "If you don't answer within {1} seconds, they may connect anyway.") -f $requester, $TimeoutSeconds
    return [pscustomobject]@{ Title = 'Remote Desktop: takeover request'; Message = $message }
}

function Invoke-AskTakeover {
    param([Parameter(Mandatory = $true)] $Target, [Parameter(Mandatory = $true)] $Result, [Parameter(Mandatory = $true)] [hashtable] $Settings)
    $ask = Get-AskMessage -TimeoutSeconds $Settings.AskTimeoutSeconds
    if ($Result.Status -eq 'Locked') {
        Write-Host 'Their screen is locked, so they will probably not see the request until they are back.' -ForegroundColor Yellow
    }
    Write-Host ('Asking {0} (session {1}); waiting up to {2} s for an answer...' -f $Result.User, $Result.SessionId, $Settings.AskTimeoutSeconds)
    try {
        $response = Send-AskMessage -ComputerName $Target.QueryHost -SessionId $Result.SessionId -Title $ask.Title -Message $ask.Message -TimeoutSeconds $Settings.AskTimeoutSeconds -Credential $Settings.Credential
    }
    catch {
        $failure = Get-FailureText -ErrorRecord $_ -Operation Ask -Settings $Settings
        Write-Host ("Couldn't send the request: {0}" -f $failure.Text) -ForegroundColor Yellow
        Write-CheckLog -Level File -Message ("Couldn't send the request: {0}" -f $failure.Text)
        Write-CheckLog -Message ('Ask failed: {0}' -f (Format-ExceptionChain -ErrorRecord $_))
        return 'Failed'
    }
    Write-CheckLog -Message ('Ask: session {0} on {1} answered with code {2} (6 = Yes, 7 = No, 32000 = timed out)' -f $Result.SessionId, $Target.QueryHost, $response)
    switch ([int] $response) {
        6     { return 'Yes' }
        7     { return 'No' }
        32000 { return 'Timeout' }
    }
    return 'Unknown'
}

function Wait-UntilFree {
    param([Parameter(Mandatory = $true)] $Target, [Parameter(Mandatory = $true)] [hashtable] $Settings)
    Write-Host ('Watching {0}: checking every {1} s. Press Q to stop.' -f $Target.Name, $Settings.PollSeconds)
    $lastStatus = ''
    while ($true) {
        if (Wait-OrQuit -Seconds $Settings.PollSeconds) {
            Write-Host 'Stopped watching.'
            return 'Stopped'
        }
        $st = Get-HostStatus -Target $Target -Settings $Settings
        if ($st.Status -eq 'Unknown' -and $st.Status -ne $lastStatus) {
            Write-CheckLog -Level Warning -Message ('{0}: {1}' -f $Target.Name, $st.Error)
        }
        if ($st.Status -ne $lastStatus) {
            Write-Host ('{0:HH:mm:ss}  {1}  {2}' -f (Get-Date), (Get-StatusLabel -Status $st.Status), $st.Detail)
            $lastStatus = $st.Status
        }
        if ($st.Status -eq 'Unknown' -and (Test-SignInRejected -Code $st.ErrorCode)) {
            # Every further try with this password would count toward a lockout.
            $stop = 'Stopped watching: {0} does not accept this sign-in, and trying it again could lock the account out.' -f $Target.Name
            Write-Host $stop -ForegroundColor Yellow
            Write-CheckLog -Level File -Message $stop
            return 'Quit'
        }
        if ($st.Status -eq 'Free' -or $st.Status -eq 'Disconnected') {
            try { [Console]::Beep(880, 250) } catch { Write-Verbose 'This console cannot beep.' }
            $label = (Get-StatusLabel -Status $st.Status).ToLower()
            $answer = Show-Popup -Text ('{0} is {1} ({2}). Connect now?' -f $Target.Name, $label, $st.Detail) -Title 'Shared Remote Desktop'
            if ($answer -eq 'Yes') { return 'Connect' }
            return 'Quit'
        }
    }
}

function Invoke-HostFlow {
    param([Parameter(Mandatory = $true)] $Target, [Parameter(Mandatory = $true)] [hashtable] $Settings)
    if ($Target.Gateway) {
        Write-Host ('Note: this connection goes through RD Gateway {0}; the check needs direct access to the machine and may fail.' -f $Target.Gateway) -ForegroundColor DarkGray
    }
    if ($Settings.CheckingAs) { Write-Host ('Checking {0} as {1}...' -f $Target.Name, $Settings.CheckingAs) -ForegroundColor DarkGray }
    while ($true) {
        $st = Get-HostStatus -Target $Target -Settings $Settings
        Show-HostStatus -Result $st
        $auto = Get-AutoAction -Result $st -RecentDisconnectMinutes $Settings.RecentDisconnectMinutes
        Write-CheckLog -Message ('{0}: status {1}, next step {2}' -f $Target.Name, $st.Status, $auto)
        if ($auto -eq 'Connect') {
            Start-Rdp -Target $Target -ExtraArgument $Settings.MstscArgument
            return 'Connected'
        }
        $menu = Get-MenuFor -Result $st
        $choice = Read-Choice -Option $menu.Options -Default $menu.Default
        Write-CheckLog -Level File -Message ('{0}: chose {1}' -f $Target.Name, $choice)
        switch ($choice) {
            { $_ -eq 'Connect' -or $_ -eq 'ConnectNow' } {
                Start-Rdp -Target $Target -ExtraArgument $Settings.MstscArgument
                return 'Connected'
            }
            'Ask' {
                $answer = Invoke-AskTakeover -Target $Target -Result $st -Settings $Settings
                if ($answer -eq 'Yes') {
                    Write-Host 'They said yes. Connecting...' -ForegroundColor Green
                    Start-Rdp -Target $Target -ExtraArgument $Settings.MstscArgument
                    return 'Connected'
                }
                if ($answer -eq 'No') { Write-Host 'They want to keep working.' -ForegroundColor Yellow }
                if ($answer -eq 'Timeout') { Write-Host ('No answer within {0} s.' -f $Settings.AskTimeoutSeconds) -ForegroundColor Yellow }
            }
            'Watch' {
                Start-Shadow -Target $Target -SessionId $st.SessionId -NoConsentPrompt:([bool] $Settings.NoConsentPrompt)
            }
            'Notify' {
                $outcome = Wait-UntilFree -Target $Target -Settings $Settings
                if ($outcome -eq 'Connect') {
                    Start-Rdp -Target $Target -ExtraArgument $Settings.MstscArgument
                    return 'Connected'
                }
                if ($outcome -eq 'Quit') { return 'Quit' }
            }
            'Refresh' { }
            default { return 'Quit' }
        }
    }
}

function Get-SuggestedIndex {
    param([object[]] $Result)
    for ($i = 0; $i -lt $Result.Count; $i++) {
        if ($Result[$i].Status -eq 'Free') { return $i }
    }
    $best = -1
    $bestAge = [TimeSpan]::MinValue
    for ($i = 0; $i -lt $Result.Count; $i++) {
        $r = $Result[$i]
        if ($r.Status -ne 'Disconnected' -or $null -eq $r.Session) { continue }
        $age = $r.Session.DisconnectedFor
        if ($null -eq $age) { $age = [TimeSpan]::Zero }
        if ($age -gt $bestAge) {
            $best = $i
            $bestAge = $age
        }
    }
    return $best
}

function Select-Target {
    param([Parameter(Mandatory = $true)] [object[]] $Target, [Parameter(Mandatory = $true)] [hashtable] $Settings)
    $results = @()
    foreach ($t in $Target) {
        Write-Host ('Checking {0}...' -f $t.Name) -ForegroundColor DarkGray
        $results += Get-HostStatus -Target $t -Settings $Settings
    }
    $rows = @()
    for ($i = 0; $i -lt $results.Count; $i++) {
        $r = $results[$i]
        $label = Get-StatusLabel -Status $r.Status
        $rows += [pscustomobject]@{
            '#'    = $i + 1
            Host   = $r.ComputerName
            Status = $label
            Detail = $r.Detail
            Who    = $r.Who
        }
    }
    $rows | Format-Table -AutoSize | Out-Host
    foreach ($r in $results) {
        if ($r.Status -eq 'Unknown') { Write-CheckLog -Level Warning -Message ('{0}: {1}' -f $r.ComputerName, $r.Error) }
    }
    $suggest = Get-SuggestedIndex -Result $results
    $prompt = 'Connect to which one? Number, or Q to quit'
    if ($suggest -ge 0) {
        $prompt = 'Connect to which one? Number, Enter for {0} ({1}), or Q to quit' -f ($suggest + 1), $results[$suggest].ComputerName
    }
    while ($true) {
        $answer = Read-Line -Prompt $prompt
        if ($null -eq $answer) { return $null }
        if ($answer -match '^\s*q') { return $null }
        if ([string]::IsNullOrWhiteSpace($answer)) {
            if ($suggest -ge 0) { return $Target[$suggest] }
            continue
        }
        $n = 0
        if ([int]::TryParse($answer.Trim(), [ref] $n) -and $n -ge 1 -and $n -le $Target.Count) { return $Target[$n - 1] }
        Write-Host 'Enter one of the numbers in the list.' -ForegroundColor Yellow
    }
}

function Read-RdpFile {
    param([Parameter(Mandatory = $true)] [string] $Path)
    $info = [pscustomobject]@{ Address = ''; UserName = ''; Gateway = ''; GatewayUsage = -1 }
    foreach ($line in @(Get-Content -LiteralPath $Path)) {
        if ($line -match '^\s*full address:s:(.+?)\s*$') { $info.Address = $Matches[1] }
        elseif ($line -match '^\s*username:s:(.+?)\s*$') { $info.UserName = $Matches[1] }
        elseif ($line -match '^\s*gatewayhostname:s:(.+?)\s*$') { $info.Gateway = $Matches[1] }
        elseif ($line -match '^\s*gatewayusagemethod:i:(\d+)') { $info.GatewayUsage = [int] $Matches[1] }
    }
    return $info
}

function Resolve-Targets {
    param([string[]] $ComputerName, [string] $RdpFile, [string] $UserName, [System.Management.Automation.PSCredential] $Credential)
    $rdp = $null
    $rdpPath = ''
    if ($RdpFile) {
        if (-not (Test-Path -LiteralPath $RdpFile -PathType Leaf)) { throw ('RDP file not found: {0}' -f $RdpFile) }
        $rdpPath = (Resolve-Path -LiteralPath $RdpFile).ProviderPath
        $rdp = Read-RdpFile -Path $rdpPath
    }
    # "LAB-01,LAB-02" arrives as one string when the script runs via powershell.exe -File.
    $names = @($ComputerName | Where-Object { $_ } | ForEach-Object { $_ -split '[,;\s]+' } | Where-Object { $_ })
    $override = ($names.Count -gt 0)
    if (-not $override) {
        if ($null -ne $rdp -and $rdp.Address) { $names = @($rdp.Address) }
        else { throw 'Give -ComputerName, or an -RdpFile that has a "full address" line.' }
    }
    $targetUser = ''
    if ($UserName) { $targetUser = $UserName }
    elseif ($null -ne $rdp -and $rdp.UserName) { $targetUser = $rdp.UserName }
    elseif ($null -ne $Credential -and $Credential -ne [System.Management.Automation.PSCredential]::Empty) { $targetUser = $Credential.UserName }
    $gateway = ''
    if ($null -ne $rdp -and $rdp.Gateway -and $rdp.GatewayUsage -ne 0 -and $rdp.GatewayUsage -ne 4) { $gateway = $rdp.Gateway }
    foreach ($n in $names) {
        $split = Split-HostPort -Address $n
        [pscustomobject]@{
            Name         = $n
            QueryHost    = $split.Host
            RdpFile      = $rdpPath
            OverrideHost = $override
            TargetUser   = $targetUser
            Gateway      = $gateway
        }
    }
}

function Get-CheckingIdentity {
    param([System.Management.Automation.PSCredential] $Credential)
    if ($null -ne $Credential -and $Credential -ne [System.Management.Automation.PSCredential]::Empty) {
        return ('{0} (from -Credential)' -f $Credential.UserName)
    }
    try { return [System.Security.Principal.WindowsIdentity]::GetCurrent().Name }
    catch { return [Environment]::UserName }
}

#endregion

# Dot-sourcing loads the functions without running anything.
if ($MyInvocation.InvocationName -ne '.') {
    if (-not (Test-IsWindows)) {
        Write-Error 'This script needs Windows: it uses the Remote Desktop Services API and mstsc.exe.'
        exit 1
    }
    $script:LogFile = $null
    if ($LogPath) {
        $script:LogFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogPath)
        $logFolder = Split-Path -Parent $script:LogFile
        if ($logFolder -and -not (Test-Path -LiteralPath $logFolder)) {
            try { $null = New-Item -ItemType Directory -Path $logFolder -Force -ErrorAction Stop }
            catch { Write-Warning ('Could not create the folder for the log file: {0}' -f $_.Exception.Message) }
        }
        Write-Host ('Logging to {0}' -f $script:LogFile) -ForegroundColor DarkGray
    }
    $shown = foreach ($key in $PSBoundParameters.Keys) {
        $value = $PSBoundParameters[$key]
        if ($value -is [System.Management.Automation.PSCredential]) { $value = '{0} (password not logged)' -f $value.UserName }
        elseif ($value -is [array]) { $value = $value -join ',' }
        '{0}={1}' -f $key, $value
    }
    Write-CheckLog -Message ('Connect-SharedRdp {0} on PowerShell {1} ({2}, {3}-bit), {4}' -f $script:ScriptVersion, $PSVersionTable.PSVersion, $PSVersionTable.PSEdition, ([IntPtr]::Size * 8), [Environment]::OSVersion.VersionString)
    Write-CheckLog -Message ('Parameters: {0}' -f ($shown -join '; '))
    try {
        Initialize-Native
    }
    catch {
        $loadError = 'Could not load the Remote Desktop Services API wrapper: {0}' -f (Format-ExceptionChain -ErrorRecord $_)
        Write-CheckLog -Level File -Message $loadError
        Write-Error $loadError
        exit 1
    }
    $settings = @{
        Credential              = $Credential
        IdleMinutes             = $IdleMinutes
        RecentDisconnectMinutes = $RecentDisconnectMinutes
        BusyProcess             = @($BusyProcess | Where-Object { $_ } | ForEach-Object { $_ -split '[,;\s]+' } | Where-Object { $_ })
        AskTimeoutSeconds       = $AskTimeoutSeconds
        PollSeconds             = $PollSeconds
        NoConsentPrompt         = [bool] $NoConsentPrompt
        MstscArgument           = @($MstscArgument)
        SkipPortCheck           = [bool] $SkipPortCheck
        CheckingAs              = (Get-CheckingIdentity -Credential $Credential)
    }
    Write-CheckLog -Message ('Checking as {0}' -f $settings.CheckingAs)
    try {
        $targets = @(Resolve-Targets -ComputerName $ComputerName -RdpFile $RdpFile -UserName $UserName -Credential $Credential)
    }
    catch {
        Write-CheckLog -Level File -Message $_.Exception.Message
        Write-Error $_.Exception.Message
        exit 1
    }
    foreach ($t in $targets) {
        Write-CheckLog -Message ('Target {0}: query host {1}, shared account "{2}", rdp file "{3}", gateway "{4}"' -f $t.Name, $t.QueryHost, $t.TargetUser, $t.RdpFile, $t.Gateway)
    }
    if ($StatusOnly) {
        foreach ($t in $targets) {
            $result = Get-HostStatus -Target $t -Settings $settings
            if ($result.Status -eq 'Unknown') { Write-CheckLog -Level Warning -Message ('{0}: {1}' -f $result.ComputerName, $result.Error) }
            $result
        }
        return
    }
    $chosen = $targets[0]
    if ($targets.Count -gt 1) { $chosen = Select-Target -Target $targets -Settings $settings }
    if ($null -ne $chosen) {
        $outcome = Invoke-HostFlow -Target $chosen -Settings $settings
        Write-CheckLog -Message ('Done: {0}' -f $outcome)
    }
}
