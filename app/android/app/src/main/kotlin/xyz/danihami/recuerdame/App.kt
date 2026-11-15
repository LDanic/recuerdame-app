package xyz.danihami.recuerdame

import android.app.Application
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.provider.Settings
import android.util.Log
import com.gdelataillade.alarm.alarm.AlarmService
import com.gdelataillade.alarm.services.AlarmRingingLiveData

/**
 * Decide qué hacer cuando empieza a sonar algo:
 * - Nivel Notificación con el celular en silencio: se calla y queda un aviso sin sonido.
 * - Si la persona tiene "en grande" para ese nivel: con el celular en uso Android solo
 *   mostraría un banner, así que abrimos [AlarmaActivity] (exige "Mostrar sobre otras apps").
 */
class App : Application() {
    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CANAL, "Recordatorios en silencio", NotificationManager.IMPORTANCE_DEFAULT))
        // ponytail: depende de clases del plugin `alarm` (AlarmRingingLiveData, AlarmService);
        // si cambian al actualizarlo, revisar aquí y en Alarmas.kt.
        AlarmRingingLiveData.instance.observeForever { sonando ->
            if (sonando) AlarmService.ringingAlarmIds.forEach(::alSonar)
        }
    }

    private fun alSonar(id: Int) {
        val (titulo, cuerpo) = Alarmas.texto(this, id) ?: ("Recuérdame" to "")
        if (Alarmas.debeCallar(this, id)) {
            Alarmas.detener(this, id, repeticiones = false)
            avisoSilencioso(id, titulo, cuerpo)
            return
        }
        if (!Alarmas.enGrande(id) || !Settings.canDrawOverlays(this)) return
        try {
            startActivity(Intent(this, AlarmaActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(AlarmService.EXTRA_ALARM_ID, id)
                .putExtra(AlarmService.EXTRA_ALARM_BODY, cuerpo))
        } catch (e: Exception) {
            Log.w("Recuerdame", "No se pudo abrir la pantalla de alarma", e)
        }
    }

    private fun avisoSilencioso(id: Int, titulo: String, cuerpo: String) {
        val abrir = packageManager.getLaunchIntentForPackage(packageName)
        val toque = PendingIntent.getActivity(this, id, abrir, PendingIntent.FLAG_IMMUTABLE)
        val aviso = Notification.Builder(this, CANAL)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(titulo)
            .setContentText(cuerpo)
            .setContentIntent(toque)
            .setAutoCancel(true)
            .build()
        try {
            getSystemService(NotificationManager::class.java).notify(id, aviso)
        } catch (e: SecurityException) {
            Log.w("Recuerdame", "Sin permiso de notificaciones", e)
        }
    }

    companion object {
        const val CANAL = "silencio"
    }
}
