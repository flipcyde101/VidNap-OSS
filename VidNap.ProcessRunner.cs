using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

// Windows/.NET Framework 4 compatible. Each run owns a kill-on-close Job Object.
// Process.Start precedes AssignProcessToJobObject: there is a small assignment
// race. This is lifecycle containment for trusted executables, not a sandbox for
// hostile executables. Assignment failure terminates the root and fails closed.
public sealed class VidNapProcessRunner : IDisposable
{
    public readonly ConcurrentQueue<string> Output = new ConcurrentQueue<string>();
    private readonly int outputLimit;
    private readonly object outputGate = new object();
    private Process process;
    private IntPtr job;
    private int streamsEnded;
    private int exitCode;
    private bool exited;
    private bool disposed;
    private long exitTimestamp;
    private const int DrainMilliseconds = 2000;

    public VidNapProcessRunner() : this(2048) { }
    public VidNapProcessRunner(int maxOutputLines)
    {
        if (maxOutputLines < 1) throw new ArgumentOutOfRangeException("maxOutputLines");
        outputLimit = maxOutputLines;
    }

    public void Start(ProcessStartInfo info)
    {
        if (disposed) throw new ObjectDisposedException("VidNapProcessRunner");
        if (info == null) throw new ArgumentNullException("info");
        if (process != null && !IsComplete) throw new InvalidOperationException("A run is still active.");
        ReleaseRun();
        string discarded;
        while (Output.TryDequeue(out discarded)) { }
        streamsEnded = 0;
        exited = false;
        exitTimestamp = 0;
        job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw NativeError("CreateJobObject");
        try
        {
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            limits.BasicLimitInformation.LimitFlags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION))))
                throw NativeError("SetInformationJobObject");
            info.UseShellExecute = false;
            info.RedirectStandardOutput = true;
            info.RedirectStandardError = true;
            info.CreateNoWindow = true;
            process = new Process();
            process.StartInfo = info;
            process.OutputDataReceived += Receive;
            process.ErrorDataReceived += Receive;
            if (!process.Start()) throw new InvalidOperationException("The process did not start.");
            if (!AssignProcessToJobObject(job, process.Handle))
            {
                Exception error = NativeError("AssignProcessToJobObject");
                try { process.Kill(); } catch { }
                throw error;
            }
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
        }
        catch
        {
            if (job != IntPtr.Zero) TerminateJobObject(job, 1);
            if (process != null) { try { if (!process.HasExited) process.Kill(); } catch { } }
            ReleaseRun();
            throw;
        }
    }

    private void Receive(object sender, DataReceivedEventArgs e)
    {
        lock (outputGate)
        {
            // A timed-out stream callback from the previous run must not affect
            // either the EOF count or the log of a later run.
            if (!Object.ReferenceEquals(sender, process)) return;
            if (e.Data == null) { Interlocked.Increment(ref streamsEnded); return; }
            // Bound retained log memory, including very long individual lines.
            string line = e.Data.Length > 16384 ? e.Data.Substring(0, 16384) + " [truncated]" : e.Data;
            Output.Enqueue(line);
            string discarded;
            while (Output.Count > outputLimit && Output.TryDequeue(out discarded)) { }
        }
    }

    private void ObserveExit()
    {
        if (process == null || exited) return;
        if (!process.HasExited) return;
        exitCode = process.ExitCode;
        exited = true;
        exitTimestamp = Stopwatch.GetTimestamp();
        // Children must not keep inherited pipe handles open indefinitely once
        // the command root has finished. Termination does not discard buffered data.
        if (job != IntPtr.Zero) TerminateJobObject(job, 1);
    }

    public bool HasExited { get { ObserveExit(); return process != null && exited; } }
    public bool IsRunning { get { return process != null && !HasExited; } }
    public int ExitCode
    {
        get { if (!HasExited) throw new InvalidOperationException("The process has not exited."); return exitCode; }
    }
    public bool OutputComplete { get { return Interlocked.CompareExchange(ref streamsEnded, 0, 0) >= 2; } }
    public bool IsComplete { get { return CompletionState != "Pending"; } }
    // Snapshot the deadline before EOF, then let consumers retain this result.
    public string CompletionState
    {
        get
        {
            if (!HasExited) return "Pending";
            bool deadlineReached = (Stopwatch.GetTimestamp() - exitTimestamp) * 1000.0 / Stopwatch.Frequency >= DrainMilliseconds;
            if (OutputComplete) return "Complete";
            return deadlineReached ? "TimedOut" : "Pending";
        }
    }

    public void Stop()
    {
        if (process == null) return;
        if (job != IntPtr.Zero) TerminateJobObject(job, 1);
        try { if (!process.HasExited) process.Kill(); } catch (InvalidOperationException) { }
        ObserveExit();
    }

    // Compatibility only: call after HasExited, and not on a UI thread. Normal
    // UI code should poll IsComplete instead. This method never waits indefinitely.
    public void WaitForOutput()
    {
        if (!HasExited) return;
        Stopwatch timer = Stopwatch.StartNew();
        while (!IsComplete && timer.ElapsedMilliseconds < DrainMilliseconds) Thread.Sleep(10);
    }

    private void ReleaseRun()
    {
        if (job != IntPtr.Zero) { CloseHandle(job); job = IntPtr.Zero; }
        if (process != null)
        {
            process.OutputDataReceived -= Receive;
            process.ErrorDataReceived -= Receive;
            process.Dispose();
            process = null;
        }
    }
    public void Dispose()
    {
        if (disposed) return;
        try { Stop(); } finally { ReleaseRun(); disposed = true; }
        GC.SuppressFinalize(this);
    }
    ~VidNapProcessRunner() { if (job != IntPtr.Zero) CloseHandle(job); }

    private static Exception NativeError(string operation)
    { return new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), operation + " failed"); }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    { public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount; }
    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateJobObject(IntPtr job, uint exitCode);
    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);
}
