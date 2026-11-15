package xyz.danihami.recuerdame

import android.app.NotificationManager
import android.content.Context
import android.media.AudioManager
import com.gdelataillade.alarm.api.AlarmApiImpl
import com.gdelataillade.alarm.services.AlarmStorage
import java.io.File

/**
 * Lo que el celular decide a la hora de sonar, sin Flutter: así la alarma se puede
 * atender aunque el motor de Flutter tarde en arrancar (p. ej. justo tras reiniciar).
 *
 * El id de cada alarma lo arma `lib/agenda.dart`: bits 0-2 = intento (repetición),
 * bit 3 = nivel Notificación, bit 4 = abrir en grande con el celular en uso,
 * bits 5+ = la ocurrencia (recordatorio + hora + aviso previo).
 */
object Alarmas {
    fun esNotificacion(id: Int) = (id shr 3) and 1 == 1
    fun enGrande(id: Int) = (id shr 4) and 1 == 1
    private fun ocurrencia(id: Int) = id shr 5

    /** El nivel Notificación respeta el modo silencio y el No molestar. */
    fun debeCallar(context: Context, id: Int): Boolean {
        if (!esNotificacion(id)) return false
        val audio = context.getSystemService(AudioManager::class.java)
        val avisos = context.getSystemService(NotificationManager::class.java)
        return audio.ringerMode != AudioManager.RINGER_MODE_NORMAL ||
            avisos.currentInterruptionFilter > NotificationManager.INTERRUPTION_FILTER_ALL
    }

    /** Título y texto de la alarma, mientras siga guardada. */
    fun texto(context: Context, id: Int): Pair<String, String>? =
        AlarmStorage(context).getSavedAlarms().firstOrNull { it.id == id }
            ?.notificationSettings?.let { it.title to it.body }

    /** Detiene esta alarma; con [repeticiones], también las que faltan de la misma ocurrencia. */
    fun detener(context: Context, id: Int, repeticiones: Boolean) {
        val ids = if (!repeticiones) listOf(id)
        else AlarmStorage(context).getSavedAlarms().map { it.id }.filter { ocurrencia(it) == ocurrencia(id) } + id
        val api = AlarmApiImpl(context)
        for (x in ids.distinct()) api.stopAlarm(x.toLong()) {}
    }

    /** Deja constancia para que Flutter la envíe al servidor (la recoge `lib/agenda.dart`). */
    fun anotar(context: Context, id: Int, tipo: String) {
        val carpeta = File(context.filesDir, "acciones").apply { mkdirs() }
        val ahora = System.currentTimeMillis()
        val tmp = File(carpeta, "$ahora-$id.tmp")
        tmp.writeText("""{"id":$id,"type":"$tipo","at":$ahora}""")
        tmp.renameTo(File(carpeta, "$ahora-$id.json"))  // Flutter nunca ve un archivo a medias
    }
}
