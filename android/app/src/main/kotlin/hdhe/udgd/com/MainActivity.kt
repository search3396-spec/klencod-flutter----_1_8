package hdhe.udgd.com

import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (!Python.isStarted()) {
            Python.start(AndroidPlatform(this))
        }
        val py = Python.getInstance().getModule("runner")
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bot_ide/python")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "start" -> result.success(
                            py.callAttr("start", call.argument<String>("path")).toBoolean()
                        )
                        "stop" -> {
                            py.callAttr("stop")
                            result.success(true)
                        }
                        "poll" -> result.success(py.callAttr("poll").toString())
                        "isRunning" -> result.success(py.callAttr("is_running").toBoolean())
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("PY", e.message, null)
                }
            }
    }
}