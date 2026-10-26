package com.carsentinel.carunit

import android.app.Application

/**
 * 进程级入口。目前只做一件事：让 ServiceController 的 StateFlow 在 UI 之前就存在。
 */
class CarSentinelApp : Application() {
    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    companion object {
        @Volatile
        var instance: CarSentinelApp? = null
            private set
    }
}
