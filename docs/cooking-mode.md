# Cooking Mode

## Recipe and Focus views

Start or resume a local Cooking session from Recipe Detail. Recipe view shows ingredients, serving controls and all steps, with section navigation. Wide layouts separate ingredients and instructions. Focus shows one current step with Previous/Next controls. Both use the same saved position and completion state; switching views never marks completion.

Completing an unchecked step marks it and selects the next incomplete step after it, skipping completed successors. This also applies to out-of-order completion. If no successor remains, the position stays at the completed step without wrapping. Unchecking leaves position unchanged, and Make current step remains available. All steps complete is an explicit state; finishing the session is always a separate action. Recipe view does not force-scroll away from the current section.

## Sessions and reset

A session holds a stable recipe snapshot, original yield, serving multiplier, checks and current position. Downloaded recipe changes do not silently replace an active snapshot. Progress survives navigation/restart and works offline.

Finish Cooking is available in overflow and at the end. With active timers, choose Keep timers running, Stop timers or Cancel. Reset Progress confirms before clearing ingredient/step checks and returning to the first step; it preserves snapshot, servings and timers.

Restart with Updated Recipe appears only when the downloaded recipe fingerprint differs. Confirmation explains that the newest snapshot replaces it, checks reset and servings return to original yield. Existing timers retain their old session association and remain available in the timer panel. The canonical recipe is unchanged.

## Servings and preparation

Scaling uses exact rational arithmetic for supported leading quantities and fractions, preserving original text. Ambiguous quantities, packaging descriptions, unsupported units and unparseable yields remain unchanged. This is not a general unit converter. Show original and Reset to original make adjustments inspectable.

Recipe Detail ingredient checks are separate local preparation state, not Cooking completion. They persist per account/recipe, use normalized text plus duplicate occurrence, and discard ambiguous checks after ingredient changes. Headings are not checkable. Clear ingredient checks appears only when needed. Neither kind of check is uploaded to Nextcloud.

## Timers and Android

Timers persist target timestamps rather than counting database ticks. Pause/resume, restart and rename are local. Reopening reconciles elapsed timers; clock changes can affect wall-clock completion. Multiple timers may belong to different sessions. No server request is needed to run a timer.

Notifications are optional. Permission denial does not prevent local timers. Android exact-alarm special access can improve delivery precision; without it, inexact scheduling may be delayed. Battery policy, force-stop and device settings can delay or suppress alerts. Timer state remains available in the app. Reboot receivers restore scheduled notifications when Android permits; physical-device testing is necessary.

Optional screen-awake behavior applies only while Cooking is visible and is released when the app backgrounds or leaves the route. Text-size preferences, timers, servings and sessions are local-only, independent of recipe synchronization.
