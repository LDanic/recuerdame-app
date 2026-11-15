package xyz.danihami.recuerdame

import android.content.ComponentName
import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Canal `recuerdame/sistema`: marca del celular y ajustes propios de cada marca (guías de §6). */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "recuerdame/sistema").setMethodCallHandler { llamada, r ->
            when (llamada.method) {
                "fabricante" -> r.success(Build.MANUFACTURER.lowercase())
                "modelo" -> r.success("${Build.MANUFACTURER} ${Build.MODEL}")
                "abrir" -> r.success(try {
                    startActivity(Intent().setComponent(
                        ComponentName(llamada.argument<String>("paquete")!!, llamada.argument<String>("clase")!!))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    true
                } catch (e: Exception) {
                    false  // esa pantalla no existe en esta versión del sistema
                })
                else -> r.notImplemented()
            }
        }
    }
}
