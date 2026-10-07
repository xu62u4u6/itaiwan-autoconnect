using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace ITaiwan {
    public class Adapter {
        public Guid Id;
        public string Description;
        public int State;
        public string Ssid;
        public string ClientMac;
    }
    public static class Wifi {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct InterfaceInfo {
            public Guid Id;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Description;
            public int State;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct Ssid {
            public uint Length;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)] public byte[] Bytes;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct Association {
            public Ssid Ssid;
            public int BssType;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 6)] public byte[] Bssid;
            public int PhyType;
            public uint PhyIndex, Signal, RxRate, TxRate;
        }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct Connection {
            public int State, Mode;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Profile;
            public Association Association;
            public int SecurityEnabled, OneXEnabled, Authentication, Cipher;
        }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct ConnectParameters {
            public int Mode;
            [MarshalAs(UnmanagedType.LPWStr)] public string Profile;
            public IntPtr Ssid, BssidList;
            public int BssType;
            public uint Flags;
        }
        [DllImport("wlanapi.dll")] static extern uint WlanOpenHandle(uint version, IntPtr reserved, out uint negotiated, out IntPtr handle);
        [DllImport("wlanapi.dll")] static extern uint WlanCloseHandle(IntPtr handle, IntPtr reserved);
        [DllImport("wlanapi.dll")] static extern uint WlanEnumInterfaces(IntPtr handle, IntPtr reserved, out IntPtr list);
        [DllImport("wlanapi.dll")] static extern void WlanFreeMemory(IntPtr memory);
        [DllImport("wlanapi.dll")] static extern uint WlanQueryInterface(IntPtr handle, ref Guid id, int opcode, IntPtr reserved, out uint size, out IntPtr data, out int valueType);
        [DllImport("wlanapi.dll", CharSet = CharSet.Unicode)] static extern uint WlanSetProfile(IntPtr handle, ref Guid id, uint flags, string xml, string security, bool overwrite, IntPtr reserved, out uint reason);
        [DllImport("wlanapi.dll", CharSet = CharSet.Unicode)] static extern uint WlanConnect(IntPtr handle, ref Guid id, ref ConnectParameters parameters, IntPtr reserved);
        static void Check(uint code, string operation) {
            if (code != 0) throw new Win32Exception((int)code, operation + " failed (" + code + "). " + new Win32Exception((int)code).Message);
        }
        static IntPtr Open() {
            uint version; IntPtr handle;
            Check(WlanOpenHandle(2, IntPtr.Zero, out version, out handle), "WlanOpenHandle");
            return handle;
        }
        static string PhysicalAddress(Guid id) {
            try {
                foreach (var nic in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces()) {
                    Guid nicId;
                    if (Guid.TryParse(nic.Id, out nicId) && nicId == id) return nic.GetPhysicalAddress().ToString().ToUpperInvariant();
                }
            } catch { }
            return "";
        }
        public static Adapter[] Snapshot() {
            IntPtr handle = Open(), list = IntPtr.Zero;
            try {
                Check(WlanEnumInterfaces(handle, IntPtr.Zero, out list), "WlanEnumInterfaces");
                int count = Marshal.ReadInt32(list);
                var result = new List<Adapter>();
                int stride = Marshal.SizeOf(typeof(InterfaceInfo));
                for (int i = 0; i < count; i++) {
                    var info = (InterfaceInfo)Marshal.PtrToStructure(IntPtr.Add(list, 8 + i * stride), typeof(InterfaceInfo));
                    var adapter = new Adapter { Id = info.Id, Description = info.Description, State = info.State, Ssid = "" };
                    if (info.State == 1) {
                        IntPtr data = IntPtr.Zero; uint size; int valueType;
                        try {
                            // wlan_intf_opcode_current_connection = 7.
                            Check(WlanQueryInterface(handle, ref info.Id, 7, IntPtr.Zero, out size, out data, out valueType), "WlanQueryInterface (check Windows Location access if error 5)");
                            if (size < Marshal.SizeOf(typeof(Connection))) throw new InvalidOperationException("Incomplete WLAN connection data.");
                            var conn = (Connection)Marshal.PtrToStructure(data, typeof(Connection));
                            adapter.Ssid = Encoding.UTF8.GetString(conn.Association.Ssid.Bytes, 0, (int)Math.Min(conn.Association.Ssid.Length, 32u));
                            adapter.ClientMac = PhysicalAddress(info.Id);
                        } finally { if (data != IntPtr.Zero) WlanFreeMemory(data); }
                    }
                    result.Add(adapter);
                }
                return result.ToArray();
            } finally {
                if (list != IntPtr.Zero) WlanFreeMemory(list);
                WlanCloseHandle(handle, IntPtr.Zero);
            }
        }
        public static void Connect(Guid id) {
            // Separate, per-user manual profile: Windows will not autonomously prefer it.
            const string xml = "<?xml version=\"1.0\"?><WLANProfile xmlns=\"http://www.microsoft.com/networking/WLAN/profile/v1\"><name>iTaiwan-AutoConnect</name><SSIDConfig><SSID><hex>6954616977616E</hex><name>iTaiwan</name></SSID></SSIDConfig><connectionType>ESS</connectionType><connectionMode>manual</connectionMode><MSM><security><authEncryption><authentication>open</authentication><encryption>none</encryption><useOneX>false</useOneX></authEncryption></security></MSM></WLANProfile>";
            IntPtr handle = Open();
            try {
                uint reason;
                Check(WlanSetProfile(handle, ref id, 2, xml, null, true, IntPtr.Zero, out reason), "WlanSetProfile, reason=" + reason);
                var parameters = new ConnectParameters { Mode = 0, Profile = "iTaiwan-AutoConnect", BssType = 1 };
                Check(WlanConnect(handle, ref id, ref parameters, IntPtr.Zero), "WlanConnect");
                // Success means the request was accepted. Snapshot must confirm association later.
            } finally { WlanCloseHandle(handle, IntPtr.Zero); }
        }
    }
}
