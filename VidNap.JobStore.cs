using System;
using System.IO;
using System.Text;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;

public sealed class VidNapJobStoreResult {
    public string Json { get; internal set; }
    public long Generation { get; internal set; }
    public bool RecoveredFromBackup { get; internal set; }
    public string ErrorCode { get; internal set; }
}

// Two authenticated snapshots, serialized by an exclusive file handle. DPAPI
// binds ciphertext to this Windows user. It is not a cross-account backup.
public static class VidNapJobStore {
    const int Limit = 4 * 1024 * 1024;
    static readonly byte[] Magic = Encoding.ASCII.GetBytes("VNJS1");
    static readonly byte[] Entropy = Encoding.UTF8.GetBytes("VidNap.JobStore.Schema1");
    static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);
    static Exception Error(string code) { return new InvalidOperationException(code); }
    public static bool IsPrivatePrincipal(string currentUserSid, string principalSid) {
        return !String.IsNullOrEmpty(currentUserSid) && !String.IsNullOrEmpty(principalSid) &&
            (principalSid == currentUserSid || principalSid == "S-1-5-18" || principalSid == "S-1-5-32-544");
    }

    static string Validate(string path) {
        try {
            if (String.IsNullOrEmpty(path) || path.Length < 4 || path[1] != ':' || path[2] != '\\' ||
                Char.ToUpperInvariant(path[0]) != 'D' || path.IndexOfAny(new char[] {'*','?','"','<','>','|'}) >= 0 ||
                path.IndexOf(':', 2) >= 0) throw Error("VIDNAP_STORE_PATH");
            string full = Path.GetFullPath(path);
            string name = Path.GetFileName(full);
            if (name.Length == 0 || name.TrimEnd(' ', '.') != name ||
                System.Text.RegularExpressions.Regex.IsMatch(name, @"^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)", System.Text.RegularExpressions.RegexOptions.IgnoreCase)) throw Error("VIDNAP_STORE_PATH");
            string dir = Path.GetDirectoryName(full);
            if (!Directory.Exists(dir)) throw Error("VIDNAP_STORE_PATH");
            for (DirectoryInfo current = new DirectoryInfo(dir); current != null; current = current.Parent) {
                if ((current.Attributes & FileAttributes.ReparsePoint) != 0 ||
                    current.Name.StartsWith("OneDrive", StringComparison.OrdinalIgnoreCase)) throw Error("VIDNAP_STORE_PATH");
            }
            CheckLeaf(full);
            AuthorizationRuleCollection rules = Directory.GetAccessControl(dir).GetAccessRules(true, true, typeof(SecurityIdentifier));
            string owner;
            using (WindowsIdentity current = WindowsIdentity.GetCurrent()) owner = current.User.Value;
            foreach (FileSystemAccessRule rule in rules) {
                string sid = rule.IdentityReference.Value;
                if (rule.AccessControlType == AccessControlType.Allow && !IsPrivatePrincipal(owner, sid)) throw Error("VIDNAP_STORE_PATH");
            }
            return full;
        } catch (InvalidOperationException) { throw; }
          catch { throw Error("VIDNAP_STORE_PATH"); }
    }
    static void CheckLeaf(string path) {
        if (Directory.Exists(path) || (File.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0))
            throw Error("VIDNAP_STORE_PATH");
    }
    static FileStream Lock(string path) {
        CheckLeaf(path + ".lock");
        try { return new FileStream(path + ".lock", FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
        catch (IOException) { throw Error("VIDNAP_STORE_BUSY"); }
    }
    static VidNapJobStoreResult Decode(string path) {
        if (!File.Exists(path)) return new VidNapJobStoreResult { Generation = 0 };
        CheckLeaf(path);
        byte[] bytes;
        try {
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read)) {
                if (stream.Length > Limit + 65536 || stream.Length < 9) return new VidNapJobStoreResult { ErrorCode = "VIDNAP_STORE_CORRUPT" };
                bytes = new byte[(int)stream.Length]; int offset = 0;
                while (offset < bytes.Length) { int n = stream.Read(bytes, offset, bytes.Length - offset); if (n == 0) throw new EndOfStreamException(); offset += n; }
            }
            for (int i = 0; i < Magic.Length; i++) if (bytes[i] != Magic[i]) return new VidNapJobStoreResult { ErrorCode = "VIDNAP_STORE_SCHEMA" };
            int length = BitConverter.ToInt32(bytes, 5);
            if (length != bytes.Length - 9) return new VidNapJobStoreResult { ErrorCode = "VIDNAP_STORE_CORRUPT" };
            byte[] cipher = new byte[length]; Buffer.BlockCopy(bytes, 9, cipher, 0, length);
            byte[] plain = ProtectedData.Unprotect(cipher, Entropy, DataProtectionScope.CurrentUser);
            try {
                if (plain.Length < 9 || plain.Length > Limit + 8) throw new InvalidDataException();
                long generation = BitConverter.ToInt64(plain, 0);
                if (generation < 1) throw new InvalidDataException();
                return new VidNapJobStoreResult { Generation = generation, Json = Utf8.GetString(plain, 8, plain.Length - 8) };
            } finally { Array.Clear(plain, 0, plain.Length); }
        } catch { return new VidNapJobStoreResult { ErrorCode = "VIDNAP_STORE_CORRUPT" }; }
    }
    public static VidNapJobStoreResult Read(string path) {
        path = Validate(path);
        // Taking the same lock prevents racing the current/previous rename pair.
        using (FileStream held = Lock(path)) {
            VidNapJobStoreResult current = Decode(path);
            if (current.ErrorCode == "VIDNAP_STORE_SCHEMA") return current;
            if (current.ErrorCode == null && current.Generation > 0) return current;
            string backup = path + ".previous"; CheckLeaf(backup);
            VidNapJobStoreResult old = Decode(backup);
            if (old.ErrorCode == null && old.Generation > 0) {
                old.RecoveredFromBackup = true; old.ErrorCode = "VIDNAP_STORE_RECOVERY_REQUIRED"; return old;
            }
            if (current.Generation == 0 && current.ErrorCode == null && File.Exists(backup))
                return new VidNapJobStoreResult { ErrorCode = old.ErrorCode == "VIDNAP_STORE_SCHEMA" ? "VIDNAP_STORE_SCHEMA" : "VIDNAP_STORE_RECOVERY_REQUIRED" };
            return current;
        }
    }
    static byte[] Encode(string json, long generation) {
        if (json == null || Utf8.GetByteCount(json) > Limit) throw Error("VIDNAP_STORE_LIMIT");
        byte[] text = Utf8.GetBytes(json), plain = new byte[text.Length + 8];
        Buffer.BlockCopy(BitConverter.GetBytes(generation), 0, plain, 0, 8); Buffer.BlockCopy(text, 0, plain, 8, text.Length);
        try {
            byte[] cipher = ProtectedData.Protect(plain, Entropy, DataProtectionScope.CurrentUser);
            byte[] result = new byte[cipher.Length + 9]; Buffer.BlockCopy(Magic, 0, result, 0, 5);
            Buffer.BlockCopy(BitConverter.GetBytes(cipher.Length), 0, result, 5, 4); Buffer.BlockCopy(cipher, 0, result, 9, cipher.Length); return result;
        } finally { Array.Clear(text, 0, text.Length); Array.Clear(plain, 0, plain.Length); }
    }
    static string Stage(string path, byte[] bytes) {
        string temp = path + ".writing-" + Guid.NewGuid().ToString("N");
        using (FileStream file = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough)) {
            file.Write(bytes, 0, bytes.Length); file.Flush(true);
        }
        return temp;
    }
    public static long Write(string path, string json, long expectedGeneration) {
        path = Validate(path);
        if (json == null || Utf8.GetByteCount(json) > Limit) throw Error("VIDNAP_STORE_LIMIT");
        using (FileStream held = Lock(path)) {
            VidNapJobStoreResult current = Decode(path); string backup = path + ".previous"; CheckLeaf(backup);
            if (current.ErrorCode != null || (current.Generation == 0 && File.Exists(backup))) throw Error("VIDNAP_STORE_RECOVERY_REQUIRED");
            if (current.Generation != expectedGeneration) throw Error("VIDNAP_STORE_CONFLICT");
            if (File.Exists(backup) && Decode(backup).ErrorCode != null) throw Error("VIDNAP_STORE_RECOVERY_REQUIRED");
            long next = checked(current.Generation + 1); string temp = Stage(path, Encode(json, next));
            try { if (current.Generation == 0) File.Move(temp, path); else File.Replace(temp, path, backup, false); }
            finally { if (File.Exists(temp)) File.Delete(temp); }
            return next;
        }
    }
    static string Hash(string path) {
        using (SHA256 sha = SHA256.Create()) using (FileStream file = File.OpenRead(path))
            return BitConverter.ToString(sha.ComputeHash(file)).Replace("-", "");
    }
    public static void Recover(string path, string expectedBackupSha256) {
        path = Validate(path);
        using (FileStream held = Lock(path)) {
            string backup = path + ".previous"; CheckLeaf(backup);
            VidNapJobStoreResult old = Decode(backup), current = Decode(path);
            if (current.Generation > 0 && current.ErrorCode == null) throw Error("VIDNAP_STORE_CONFLICT");
            if (current.ErrorCode == "VIDNAP_STORE_SCHEMA") throw Error("VIDNAP_STORE_SCHEMA");
            if (old.ErrorCode != null || old.Generation < 1 || !String.Equals(Hash(backup), expectedBackupSha256, StringComparison.OrdinalIgnoreCase)) throw Error("VIDNAP_STORE_RECOVERY_REQUIRED");
            string temp = Stage(path, File.ReadAllBytes(backup));
            try {
                if (File.Exists(path)) File.Replace(temp, path, path + ".corrupt-" + Guid.NewGuid().ToString("N"), false);
                else File.Move(temp, path);
            } finally { if (File.Exists(temp)) File.Delete(temp); }
        }
    }
}
