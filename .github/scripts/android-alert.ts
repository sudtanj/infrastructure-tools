// Alerts for the owner from the emulator scripts (eraspace.ts, blibli.ts,
// pinedrama.ts): each is logged as a workflow warning and, when ALERT_FILE is
// set (by android-emulator-session.sh), queued there; the workflow sends the
// queue to Telegram at the end of the run.

import { appendFileSync } from "node:fs";

export function alert(message: string) {
  console.log(`::warning::${message}`);
  const file = process.env.ALERT_FILE;
  if (file) appendFileSync(file, `${message}\n`);
}

// Labels of a login or sign-up button (Indonesian and English).
export const LOGIN_LABEL = /^(masuk|login|log in|sign in|daftar|sign up|masuk\s*\/\s*daftar|masuk atau daftar)$/i;
// Activity names of a login screen, from `dumpsys window`'s mCurrentFocus.
export const LOGIN_ACTIVITY = /login|signin|sign_in|auth/i;
