package xyz.danihami.recuerdame

import android.app.Application
import android.content.Intent
import android.util.Log
import com.gdelataillade.alarm.services.AlarmRingingLiveData

/**
 * Con el celular desbloqueado y en uso, Android reduce la alarma a un banner:
 * la notificación de pantalla completa solo abre la app si está bloqueado.
 * Para un adulto mayor el banner no basta, así que al empezar a sonar abrimos
 * la pantalla nosotros. Android solo lo permite con "Mostrar sobre otras apps".
 */
class App : Application() {
    override fun onCreate() {
        super.onCreate()
        // ponytail: depende de una clase interna del plugin `alarm`; si la quitan,
        // programar una alarma propia en paralelo que abra la actividad.
        AlarmRingingLiveData.instance.observeForever { sonando ->
            if (!sonando) return@observeForever
            val abrir = packageManager.getLaunchIntentForPackage(packageName) ?: return@observeForever
            try {
                startActivity(abrir.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            } catch (e: Exception) {
                Log.w("Recuerdame", "No se pudo abrir la pantalla de alarma", e)
            }
        }
    }
}
