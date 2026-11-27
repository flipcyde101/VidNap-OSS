using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;

// A bounded collector for trusted, hash-verified metadata/probe tools. Not a
// sandbox: like the existing runner, process creation precedes job assignment.
public sealed class VidNapBackendProcess : IDisposable {
    readonly object gate = new object();
    readonly StringBuilder stdout = new StringBuilder(), stderr = new StringBuilder();
    Process process;
    IntPtr job;
    Timer timer;
    Stopwatch elapsed;
    int outLimit, errLimit, timeout, ended, exitCode;
    bool exited, disposed, drainTimedOut;
    long exitAt;
    string errorCode;
    public string StandardOutput { get { lock(gate) return stdout.ToString(); } }
    public string StandardError { get { lock(gate) return stderr.ToString(); } }
    public string ErrorCode { get { lock(gate) return errorCode; } }
    public bool DrainTimedOut { get { lock(gate) return drainTimedOut; } }
    public int ProcessId { get { return process == null ? 0 : process.Id; } }
    public double ElapsedSeconds { get { return elapsed == null ? 0 : elapsed.Elapsed.TotalSeconds; } }
    public int ExitCode { get { lock(gate) { if(!exited) throw new InvalidOperationException("VIDNAP_PROCESS_RUNNING"); return exitCode; } } }
    public bool IsComplete {
        get {
            Observe(null);
            lock(gate) {
                if(!exited) return false;
                if(ended == 2) return true;
                if(elapsed.ElapsedMilliseconds - exitAt < 2000) return false;
                drainTimedOut=true;
                if(errorCode == null) errorCode="VIDNAP_PROCESS_DRAIN_TIMEOUT";
                return true;
            }
        }
    }

    public void Start(ProcessStartInfo info, int stdoutLimit, int stderrLimit, int timeoutMilliseconds) {
        if(disposed || process != null) throw new InvalidOperationException("VIDNAP_PROCESS_REUSE");
        if(info == null || stdoutLimit < 1 || stdoutLimit > 16*1024*1024 || stderrLimit < 1 || stderrLimit > 1024*1024 || timeoutMilliseconds < 1)
            throw new ArgumentException("VIDNAP_PROCESS_OPTIONS");
        outLimit=stdoutLimit; errLimit=stderrLimit; timeout=timeoutMilliseconds;
        job=CreateJobObject(IntPtr.Zero,null);
        if(job == IntPtr.Zero) throw new InvalidOperationException("VIDNAP_PROCESS_JOB");
        try {
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits=new JOBOBJECT_EXTENDED_LIMIT_INFORMATION(); limits.BasicLimitInformation.LimitFlags=0x2000;
            if(!SetInformationJobObject(job,9,ref limits,(uint)Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)))) throw new InvalidOperationException("VIDNAP_PROCESS_JOB");
            info.UseShellExecute=false; info.CreateNoWindow=true; info.WindowStyle=ProcessWindowStyle.Hidden;
            info.RedirectStandardOutput=true; info.RedirectStandardError=true;
            info.StandardOutputEncoding=new UTF8Encoding(false,true); info.StandardErrorEncoding=new UTF8Encoding(false,true);
            process=new Process(); process.StartInfo=info;
            if(!process.Start()) throw new InvalidOperationException("VIDNAP_PROCESS_START");
            if(!AssignProcessToJobObject(job,process.Handle)) { try { process.Kill(); } catch {} throw new InvalidOperationException("VIDNAP_PROCESS_JOB"); }
            elapsed=Stopwatch.StartNew();
            ThreadPool.QueueUserWorkItem(delegate { Pump(process.StandardOutput,stdout,outLimit,"VIDNAP_PROCESS_OUTPUT_LIMIT"); });
            ThreadPool.QueueUserWorkItem(delegate { Pump(process.StandardError,stderr,errLimit,"VIDNAP_PROCESS_STDERR_LIMIT"); });
            timer=new Timer(Observe,null,0,100);
        } catch { Dispose(); throw; }
    }
    void Pump(StreamReader reader,StringBuilder output,int limit,string limitCode) {
        char[] buffer=new char[4096];
        try {
            int n;
            while((n=reader.Read(buffer,0,buffer.Length)) > 0) {
                lock(gate) {
                    int available=limit-output.Length;
                    output.Append(buffer,0,Math.Min(n,available));
                    if(n > available) { Fail(limitCode); break; }
                }
            }
        } catch { lock(gate) { if(!disposed && errorCode == null) Fail("VIDNAP_PROCESS_READ"); } }
        finally { lock(gate) ended++; }
    }
    void Fail(string code) {
        if(errorCode == null) errorCode=code;
        if(job != IntPtr.Zero) TerminateJobObject(job,1);
        try { if(process != null && !process.HasExited) process.Kill(); } catch {}
    }
    void Observe(object ignored) {
        lock(gate) {
            if(disposed || process == null || elapsed == null || exited) return;
            try {
                if(process.HasExited) {
                    exitCode=process.ExitCode; exited=true; exitAt=elapsed.ElapsedMilliseconds;
                    if(job != IntPtr.Zero) TerminateJobObject(job,1);
                } else if(elapsed.ElapsedMilliseconds >= timeout) Fail("VIDNAP_PROCESS_TIMEOUT");
            } catch { Fail("VIDNAP_PROCESS_OBSERVE"); }
        }
    }
    public void Cancel() { lock(gate) { if(!exited && !disposed) Fail("VIDNAP_PROCESS_CANCELLED"); } }
    public void Dispose() {
        lock(gate) {
            if(disposed) return;
            if(!exited) Fail("VIDNAP_PROCESS_DISPOSED");
            disposed=true;
            if(timer != null) timer.Dispose();
            if(job != IntPtr.Zero) { CloseHandle(job); job=IntPtr.Zero; }
        }
        if(process != null) { try { process.WaitForExit(2000); } catch {} }
        Stopwatch drain=Stopwatch.StartNew();
        while(ended < 2 && drain.ElapsedMilliseconds < 2000 && elapsed != null) Thread.Sleep(10);
        if(process != null) process.Dispose();
        GC.SuppressFinalize(this);
    }
    ~VidNapBackendProcess() { if(job != IntPtr.Zero) CloseHandle(job); }
    [StructLayout(LayoutKind.Sequential)] struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
        public long PerProcessUserTimeLimit,PerJobUserTimeLimit; public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize,MaximumWorkingSetSize; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass,SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)] struct IO_COUNTERS { public ulong ReadOperationCount,WriteOperationCount,OtherOperationCount,ReadTransferCount,WriteTransferCount,OtherTransferCount; }
    [StructLayout(LayoutKind.Sequential)] struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation; public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit,JobMemoryLimit,PeakProcessMemoryUsed,PeakJobMemoryUsed;
    }
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr attributes,string name);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job,int infoClass,ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info,uint size);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateJobObject(IntPtr job,uint code);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
}
