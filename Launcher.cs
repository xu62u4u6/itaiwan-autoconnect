using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Windows.Forms;
public class Launcher {
    public static readonly string[] RuntimeFiles={"Wifi.cs","Core.ps1","Auth.ps1","Portal.ps1","AppCore.ps1","ITaiwan.ps1","Tray.ps1","Manage.ps1","README.md"};
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct StartupInfo {
        public uint Size;public string Reserved,Desktop,Title;public uint X,Y,XSize,YSize,XCount,YCount,Fill,Flags;
        public ushort ShowWindow,ReservedSize;public IntPtr ReservedData,Input,Output,Error;
    }
    [StructLayout(LayoutKind.Sequential)] struct ProcessInfo {public IntPtr Process,Thread;public uint ProcessId,ThreadId;}
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcess(string app,StringBuilder command,IntPtr pa,IntPtr ta,bool inherit,uint flags,IntPtr env,string directory,ref StartupInfo startup,out ProcessInfo info);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr handle);
    static void Log(string root,string message){try{string p=Path.Combine(root,"launcher.log");if(File.Exists(p)&&new FileInfo(p).Length>1048576){if(File.Exists(p+".old"))File.Delete(p+".old");File.Move(p,p+".old");}File.AppendAllText(p,DateTime.UtcNow.ToString("o")+" "+message+Environment.NewLine,Encoding.UTF8);}catch{}}
    public static byte[] EmbeddedFile(string name){using(var s=typeof(Launcher).Assembly.GetManifestResourceStream(name)){if(s==null)throw new InvalidOperationException("Packaged runtime missing: "+name);using(var m=new MemoryStream()){s.CopyTo(m);return m.ToArray();}}}
    // Only missing code is restored. No settings or secrets are embedded. One repair/file/lifetime.
    public static void RepairMissing(string root,HashSet<string> repaired){foreach(string name in RuntimeFiles){
        string path=Path.Combine(root,name);if(File.Exists(path))continue;
        if(repaired.Contains(name))throw new IOException("程式檔案再次被移除："+name+"。請檢查移除或隔離紀錄。");
        byte[] bytes=EmbeddedFile(name);string temp=path+".restore-"+Guid.NewGuid().ToString("N");
        try{File.WriteAllBytes(temp,bytes);if(!File.Exists(path))File.Move(temp,path);using(var sha=SHA256.Create()){if(Convert.ToBase64String(sha.ComputeHash(File.ReadAllBytes(path)))!=Convert.ToBase64String(sha.ComputeHash(bytes)))throw new IOException("修復檔案驗證失敗："+name);}repaired.Add(name);Log(root,"Restored missing runtime: "+name);}
        finally{if(File.Exists(temp))File.Delete(temp);}
    }}
    static Process StartDetached(string app,string arguments,string root){
        // No console, no inherited standard handles. SW_HIDE would hide the first GUI window.
        var startup=new StartupInfo{Size=(uint)Marshal.SizeOf(typeof(StartupInfo)),Flags=0x100};ProcessInfo info;
        if(!CreateProcess(app,new StringBuilder("\""+app+"\" "+arguments),IntPtr.Zero,IntPtr.Zero,false,0x08000000,IntPtr.Zero,root,ref startup,out info))throw new Win32Exception(Marshal.GetLastWin32Error());
        try{return Process.GetProcessById((int)info.ProcessId);}finally{CloseHandle(info.Thread);CloseHandle(info.Process);}
    }
    static bool Busy(string name){using(var m=new Mutex(false,name)){bool owned=false;try{try{owned=m.WaitOne(0);}catch(AbandonedMutexException){owned=true;}return !owned;}finally{if(owned)m.ReleaseMutex();}}}
    static bool Stopping(string root){return File.Exists(Path.Combine(root,"stop.flag"))||File.Exists(Path.Combine(root,"tray-stop.flag"));}
    static string TestRoot(string path){string root=Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar);string temp=Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar)+Path.DirectorySeparatorChar;if(!root.StartsWith(temp,StringComparison.OrdinalIgnoreCase)||!Path.GetFileName(root).StartsWith("ITaiwanLauncherTest-",StringComparison.Ordinal))throw new ArgumentException("Tests require an isolated temporary directory.");return root;}
    static void TestChild(string root){
        var f=new Form{Text="iTaiwan isolated launcher test",Width=240,Height=100,ShowInTaskbar=false};var t=new System.Windows.Forms.Timer{Interval=150};
        f.Shown+=(s,e)=>{File.WriteAllText(Path.Combine(root,"test-window-visible.txt"),(f.Visible && IsWindowVisible(f.Handle)).ToString());f.Hide();};
        t.Tick+=(s,e)=>{File.WriteAllText(Path.Combine(root,"test-child.txt"),Process.GetCurrentProcess().Id.ToString());if(File.Exists(Path.Combine(root,"test-crash.flag"))){File.Delete(Path.Combine(root,"test-crash.flag"));Environment.Exit(9);}if(Stopping(root)){t.Stop();f.Close();}};
        t.Start();try{Application.Run(f);}finally{t.Dispose();f.Dispose();}
    }
    [STAThread] static void Main(string[] args){
        string root=AppDomain.CurrentDomain.BaseDirectory;bool test=args.Length==2&&args[0]=="--integration-test",child=args.Length==2&&args[0]=="--test-child",background=args.Length==1&&args[0]=="--background";
        try{
            if(test||child)root=TestRoot(args[1]);if(child){TestChild(root);return;}
            string ps=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),@"WindowsPowerShell\v1.0\powershell.exe");
            if(Path.GetFileName(Application.ExecutablePath).Equals("Setup.exe",StringComparison.OrdinalIgnoreCase)){
                RepairMissing(root,new HashSet<string>(StringComparer.OrdinalIgnoreCase));using(var p=StartDetached(ps,"-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File \""+Path.Combine(root,"Manage.ps1")+"\" -Action Install",root)){}return;
            }
            string data=test?root:Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"ITaiwanAutoConnect");Directory.CreateDirectory(data);
            string sid=WindowsIdentity.GetCurrent().User.Value,suffix=test?"-Test-"+Path.GetFileName(root):"";
            using(var singleton=new Mutex(false,"Local\\ITaiwanLauncher-"+sid+suffix)){
                bool owned=false;try{
                    try{owned=singleton.WaitOne(0);}catch(AbandonedMutexException){owned=true;}
                    if(!owned){if(!background)File.WriteAllText(Path.Combine(data,"open-window.flag"),"open");return;}
                    File.Delete(Path.Combine(data,"stop.flag"));File.Delete(Path.Combine(data,"tray-stop.flag"));if(!background)File.WriteAllText(Path.Combine(data,"open-window.flag"),"open");
                    File.Delete(Path.Combine(data,"launcher-error.txt"));Log(data,"Launcher started v4.4.");var repaired=new HashSet<string>(StringComparer.OrdinalIgnoreCase);var restarts=new List<DateTime>();Process running=null;
                    try{while(!Stopping(data)){
                        try{RepairMissing(root,repaired);}catch(Exception ex){Log(data,"Recovery stopped: "+ex.Message);File.WriteAllText(Path.Combine(data,"launcher-error.txt"),ex.Message);break;}
                        bool alive=running!=null&&!running.HasExited;
                        if(!alive&&(test||!Busy("Local\\ITaiwanTray-"+sid+suffix))){
                            DateTime now=DateTime.UtcNow;restarts.RemoveAll(x=>(now-x).TotalMinutes>=10);
                            if(restarts.Count<3&&(restarts.Count==0||(now-restarts[restarts.Count-1]).TotalSeconds>=(test?1:30))){
                                if(running!=null)running.Dispose();string app=test?Application.ExecutablePath:ps;
                                string arguments=test?"--test-child \""+root+"\"":"-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File \""+Path.Combine(root,"Tray.ps1")+"\"";
                                running=StartDetached(app,arguments,root);restarts.Add(now);Log(data,"Started tray PID "+running.Id);
                            }
                        }
                        Thread.Sleep(test?150:1000);
                    }}finally{if(running!=null)running.Dispose();Log(data,"Launcher stopped.");}
                }finally{if(owned)singleton.ReleaseMutex();}
            }
        }catch(Exception ex){Log(root,"Launcher failed: "+ex.GetType().Name);MessageBox.Show(ex.Message,"iTaiwan",MessageBoxButtons.OK,MessageBoxIcon.Error);}
    }
}
