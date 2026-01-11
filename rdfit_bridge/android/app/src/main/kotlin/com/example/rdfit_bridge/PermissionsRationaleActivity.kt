package com.example.rdfit_bridge

import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity

/**
 * Activity to show Health Connect permissions rationale.
 * This is required by Health Connect to explain why the app needs health permissions.
 */
class PermissionsRationaleActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Simply finish and let the user see the permissions dialog
        // In a production app, you might show a custom rationale screen here
        finish()
    }
}
