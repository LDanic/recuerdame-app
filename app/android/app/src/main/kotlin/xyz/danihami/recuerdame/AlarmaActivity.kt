package xyz.danihami.recuerdame

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.lifecycle.Observer
import com.gdelataillade.alarm.alarm.AlarmService
import com.gdelataillade.alarm.services.AlarmRingingLiveData
import java.text.DateFormat
import java.util.Date

/**
 * Pantalla de la alarma, nativa a propósito: abre al instante aunque Flutter no haya
 * arrancado (tras reiniciar, con el celular lento) y nunca deja al usuario sin cómo
 * apagarla. Las teclas de volumen equivalen a "Más tarde".
 *
 * La abre el plugin `alarm` (acción RING) o [App] cuando el celular está en uso.
 */
class AlarmaActivity : Activity() {
    private var id = 0
    private var sono = false
    private val alCambiar = Observer<Boolean> { sonando ->
        if (sonando) sono = true else if (sono) finish()  // se apagó sola o desde la notificación
    }

    override fun onCreate(estado: Bundle?) {
        super.onCreate(estado)
        setShowWhenLocked(true)
        setTurnScreenOn(true)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        AlarmRingingLiveData.instance.observeForever(alCambiar)
        mostrar(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        mostrar(intent)
    }

    override fun onDestroy() {
        AlarmRingingLiveData.instance.removeObserver(alCambiar)
        super.onDestroy()
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN || keyCode == KeyEvent.KEYCODE_VOLUME_UP) {
            masTarde()
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    private fun mostrar(i: Intent) {
        id = i.getIntExtra(AlarmService.EXTRA_ALARM_ID, 0).takeIf { it != 0 }
            ?: AlarmService.ringingAlarmIds.firstOrNull() ?: 0
        if (id == 0 || Alarmas.debeCallar(this, id)) return finish()
        val cuerpo = i.getStringExtra(AlarmService.EXTRA_ALARM_BODY) ?: Alarmas.texto(this, id)?.second ?: ""
        setContentView(vista(cuerpo))
    }

    private fun entendido() {
        Alarmas.anotar(this, id, "acked")
        Alarmas.detener(this, id, repeticiones = true)
        finish()
    }

    private fun masTarde() {
        // Solo calla este intento: la siguiente repetición sonará a su hora.
        Alarmas.anotar(this, id, "snoozed")
        Alarmas.detener(this, id, repeticiones = false)
        finish()
    }

    private fun vista(cuerpo: String): View {
        val dp = resources.displayMetrics.density
        fun texto(t: String, sp: Float, negrita: Boolean = false, color: Int = Color.BLACK) = TextView(this).apply {
            text = t
            textSize = sp
            gravity = Gravity.CENTER
            setTextColor(color)
            if (negrita) setTypeface(typeface, Typeface.BOLD)
        }
        fun boton(t: String, sp: Float, alto: Int, fondo: Int, letra: Int, accion: () -> Unit) = Button(this).apply {
            text = t
            textSize = sp
            isAllCaps = false
            setTextColor(letra)
            background = GradientDrawable().apply {
                cornerRadius = 24 * dp
                setColor(fondo)
                setStroke((3 * dp).toInt(), Color.rgb(46, 125, 50))
            }
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, (alto * dp).toInt())
                .apply { topMargin = (20 * dp).toInt() }
            setOnClickListener { accion() }
        }
        val relleno = { View(this).apply { layoutParams = LinearLayout.LayoutParams(0, 0, 1f) } }
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.WHITE)
            val m = (24 * dp).toInt()
            setPadding(m, m * 2, m, m)
            addView(relleno())
            addView(texto(DateFormat.getTimeInstance(DateFormat.SHORT).format(Date()), 56f, negrita = true))
            addView(texto(cuerpo, 30f).apply { setPadding(0, m, 0, 0) })
            addView(relleno())
            addView(boton("✔  ENTENDIDO", 32f, 110, Color.rgb(46, 125, 50), Color.WHITE, ::entendido))
            addView(boton("⏰  Más tarde", 24f, 72, Color.WHITE, Color.rgb(27, 94, 32), ::masTarde))
            addView(texto("Las teclas de volumen también hacen «Más tarde»", 16f, color = Color.DKGRAY)
                .apply { setPadding(0, m / 2, 0, 0) })
        }
    }
}
