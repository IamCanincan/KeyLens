import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import java.io.File;
import java.io.FileOutputStream;
import java.lang.reflect.Method;

/**
 * 用 PackageManager 取「应用自己的图标」，渲染成 PNG。
 *
 * 为什么要它：桌面缓存（launcher3 的 app_icons.db）里只有**有启动器入口**的应用，
 * GMS / GSF / WebView / AR Core 这类后台组件在里面一行都没有，界面只能退成首字块。
 * 它们的图标确实存在（APK 的 applicationInfo.icon），而资源名在 Google 的包被混淆过
 * （实测 WebView 的 base.apk 里是 res/j_ 这种名字），按文件名抠图不可行、解析
 * resources.arsc 又不划算。app_process 里调 PackageManager 是唯一能拿到正确结果的路，
 * 它顺带把自适应图标也渲染好了。
 *
 * 只依赖公开 API；ActivityThread.systemMain()/getSystemContext() 是隐藏 API，
 * 走反射（app_process 不受 hidden-api 限制，实测可调用）。
 *
 * 用法：app_process -Djava.class.path=<dex> /system/bin IconDump <pkg[,pkg..]> <outDir> [size]
 * 输出：每成功一个打印一行  <pkg>\t<label>\ticons/<pkg>.png
 */
public class IconDump {
    public static void main(String[] args) {
        if (args.length < 2) {
            System.err.println("usage: IconDump pkg[,pkg..] outDir [size]");
            return;
        }
        int size = 192;
        if (args.length >= 3) {
            try { size = Integer.parseInt(args[2]); } catch (Throwable ignored) { }
        }
        Context ctx;
        try {
            ctx = systemContext();
        } catch (Throwable t) {
            System.err.println("fatal: 拿不到系统 Context: " + chain(t));
            return;
        }
        if (ctx == null) { System.err.println("fatal: Context 为空"); return; }
        PackageManager pm = ctx.getPackageManager();
        String[] pkgs = args[0].split(",");
        for (int i = 0; i < pkgs.length; i++) {
            String p = pkgs[i];
            if (p.length() == 0) continue;
            try {
                ApplicationInfo ai = pm.getApplicationInfo(p, 0);
                Drawable d = ai.loadIcon(pm);
                if (d == null) continue;
                Bitmap bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888);
                Canvas c = new Canvas(bmp);
                d.setBounds(0, 0, size, size);
                d.draw(c);
                FileOutputStream fos = new FileOutputStream(new File(args[1], p + ".png"));
                bmp.compress(Bitmap.CompressFormat.PNG, 100, fos);
                fos.close();
                bmp.recycle();
                CharSequence lab = ai.loadLabel(pm);
                String l = lab == null ? "" : lab.toString().replace('\t', ' ').replace('\n', ' ');
                System.out.println(p + "\t" + l + "\ticons/" + p + ".png");
            } catch (Throwable t) {
                // 单个包失败不影响其它包：界面上那一行会退回首字块
            }
        }
    }

    private static String chain(Throwable t) {
        StringBuilder sb = new StringBuilder();
        for (Throwable c = t; c != null; c = c.getCause()) {
            sb.append(c.getClass().getName()).append(": ").append(c.getMessage()).append(" | ");
        }
        return sb.toString();
    }

    private static Context systemContext() throws Exception {
        // systemMain() 内部要 new Handler()，而 app_process 的 main 线程默认没有 Looper
        // （实测报 "Can t create handler inside thread ... that has not called Looper.prepare()"）
        Class<?> looper = Class.forName("android.os.Looper");
        looper.getMethod("prepareMainLooper").invoke(null);
        Class<?> at = Class.forName("android.app.ActivityThread");
        Method systemMain = at.getMethod("systemMain");
        Object thread = systemMain.invoke(null);
        Method getSystemContext = at.getMethod("getSystemContext");
        return (Context) getSystemContext.invoke(thread);
    }
}
