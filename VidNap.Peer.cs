using System;
using System.Runtime.InteropServices;
using System.Security.Principal;

// A loopback listener is reachable by other local Windows users. Check the
// owning client process, not just the address or a secret in a URL.
public static class VidNapPreviewPeer {
    [DllImport("iphlpapi.dll", SetLastError=true)]
    static extern uint GetExtendedTcpTable(IntPtr table, ref int size, bool order, int family, int kind, uint reserved);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr OpenProcess(uint access, bool inherit, uint id);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);
    [StructLayout(LayoutKind.Sequential)]
    struct Row { public uint state, localAddress, localPort, remoteAddress, remotePort, pid; }
    static int Port(uint n) { return (int)(((n & 255) << 8) | ((n >> 8) & 255)); }
    public static bool IsCurrentUser(int clientPort, int serverPort) {
        if(clientPort < 1 || clientPort > 65535 || serverPort < 1 || serverPort > 65535) return false;
        IntPtr buffer=IntPtr.Zero;
        try {
            int size=0;
            if(GetExtendedTcpTable(IntPtr.Zero,ref size,false,2,5,0)!=122 || size < 4 || size > 64*1024*1024) return false;
            buffer=Marshal.AllocHGlobal(size);
            if(GetExtendedTcpTable(buffer,ref size,false,2,5,0)!=0) return false;
            int count=Marshal.ReadInt32(buffer), stride=Marshal.SizeOf(typeof(Row));
            if(count < 0 || count > (size-4)/stride) return false;
            string owner;
            using(var current=WindowsIdentity.GetCurrent()) owner=current.User.Value;
            for(int i=0;i<count;i++) {
                var row=(Row)Marshal.PtrToStructure(IntPtr.Add(buffer,4+i*stride),typeof(Row));
                if(row.localAddress!=0x0100007f || row.remoteAddress!=0x0100007f || Port(row.localPort)!=clientPort || Port(row.remotePort)!=serverPort) continue;
                IntPtr process=OpenProcess(0x1000,false,row.pid), token=IntPtr.Zero;
                if(process==IntPtr.Zero) return false;
                try {
                    if(!OpenProcessToken(process,8,out token)) return false;
                    using(var identity=new WindowsIdentity(token)) return identity.User!=null && identity.User.Value==owner;
                } finally { if(token!=IntPtr.Zero) CloseHandle(token); CloseHandle(process); }
            }
        } catch { return false; }
        finally { if(buffer!=IntPtr.Zero) Marshal.FreeHGlobal(buffer); }
        return false;
    }
}
