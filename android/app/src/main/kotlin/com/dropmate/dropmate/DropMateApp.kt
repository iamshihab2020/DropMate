package com.dropmate.dropmate

import android.app.Application
import android.content.Context
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * One Flutter engine for the whole process. The activity attaches to it; the foreground
 * service keeps the process (and so the Dart server) alive when the UI is closed.
 */
class DropMateApp : Application() {
    companion object {
        const val ENGINE_ID = "main"

        fun engine(context: Context): FlutterEngine {
            FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { return it }
            val app = context.applicationContext
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(app)
            loader.ensureInitializationComplete(app, null)
            val engine = FlutterEngine(app)
            Bridge.attach(app, engine)
            engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
            FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
            return engine
        }
    }
}
