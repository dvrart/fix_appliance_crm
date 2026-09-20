package com.example.fix_appliance_crm

import android.os.Handler
import android.os.Looper
import android.util.Log
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.SetOptions
import java.util.concurrent.atomic.AtomicBoolean

object CrmCallActions {
    @JvmStatic
    fun decline(parentCallSid: String, completion: Runnable) {
        if (!Regex("CA[0-9a-fA-F]{32}").matches(parentCallSid)) {
            completion.run()
            return
        }
        val handler = Handler(Looper.getMainLooper())
        val finished = AtomicBoolean(false)
        val finish = Runnable {
            if (finished.compareAndSet(false, true)) completion.run()
        }
        handler.postDelayed(finish, 2500)
        try {
            FirebaseFirestore.getInstance()
                .document("companies/fix_appliance_ca/calls/$parentCallSid")
                .set(mapOf("declineNoAi" to true, "handoffToAi" to false), SetOptions.merge())
                .addOnCompleteListener { task ->
                    if (!task.isSuccessful) Log.w("CrmCallActions", "Decline disposition was not acknowledged")
                    handler.removeCallbacks(finish)
                    finish.run()
                }
        } catch (error: Exception) {
            Log.w("CrmCallActions", "Cannot save decline disposition: ${error.javaClass.simpleName}")
            handler.removeCallbacks(finish)
            finish.run()
        }
    }
}
