# App Store Connect: what to enter

Drafts for each App Store Connect field. Items marked **TODO** need a decision first.

## App information

| Field | Value |
|---|---|
| Name (30 chars max) | DoDo. If App Store Connect says it's taken, use **DoDo: To-Do List** |
| Subtitle (30 chars max) | Your top 3 on the Lock Screen |
| Bundle ID | com.drewbomar.today |
| SKU | today-ios-1 |
| Primary category | Productivity |
| Secondary category | Lifestyle |
| Price | Free |
| Availability | All countries |

The name under the icon on the Home Screen is set separately (`CFBundleDisplayName` in `project.yml`, "DoDo"), so it stays "DoDo" even if the store name is longer.

## Version 1.0

**Promotional text** (170 chars max; can change without a new review)

> Keep today's most important tasks in front of you. Your top three sit on the Lock Screen, and you can tick them off without opening the app.

**Description**

> A to-do list built around one idea: the things you need to do today should be the first thing you see.
>
> ON YOUR LOCK SCREEN
> Your top three unfinished tasks appear as a card on the Lock Screen. Tap the circle to complete one, and the next task slides up. When today's list is done, the card offers your long-term goals instead.
>
> PLAN YOUR DAYS
> • Drag to set priority. The top three are what the Lock Screen shows.
> • Unfinished tasks carry over to tomorrow, marked as overdue.
> • Repeat tasks every day or on chosen weekdays.
> • Plan tasks for a future date. They appear at the top of that day's list.
> • Keep a separate long-term list for goals without a date.
>
> LOOK BACK
> Browse past days to see what you got done and what carried over.
>
> PRIVATE BY DESIGN
> No account, no servers, no tracking. Your tasks stay on your iPhone.

**Keywords** (100 chars max, comma-separated, no spaces needed)

> todo,to-do,lock screen,live activity,checklist,tasks,daily,planner,reminders,habits,goals,focus

**Support URL:** https://drew-bomar.github.io/dodo/support
**Marketing URL:** https://drew-bomar.github.io/dodo/ (optional)
**Privacy Policy URL:** https://drew-bomar.github.io/dodo/privacy

**Copyright:** 2026 Drew Bomar

## App Privacy

- Data collection: **No, we do not collect data from this app.**

## Age rating

Answer **None** / **No** to every question, which gives a 4+ rating.

## Export compliance

Already answered in the app (`ITSAppUsesNonExemptEncryption = NO`), so App Store Connect won't ask.

## App Review notes

> No account or sign-in is needed.
>
> To see the Lock Screen feature:
> 1. Add a few tasks on the main screen.
> 2. Tap the gear (top right) and turn on "Show on Lock Screen". Confirm the alert.
> 3. Lock the device. A card with the top three tasks appears on the Lock Screen. Tap a circle to complete a task.
>
> Live Activities run up to 8 hours, so the app starts a fresh card at noon each day (iOS 26 scheduled start) and whenever it's opened.

## Screenshots

Required: the 6.9" iPhone size (1320 × 2868 portrait). Apple scales these down for smaller iPhones.
An iPhone 14 screenshot is 1170 × 2532, which isn't an accepted size, so take them on an iPhone 17 Pro Max simulator.

`scripts/screenshots.sh` fills the simulator with sample data and takes the in-app shots; `scripts/screenshots.sh lock` takes the Lock Screen shot after you lock the simulator in Device Hub.

Suggested shots, 3 to 5:
1. Lock Screen with the card showing three tasks
2. Today's list with overdue labels and the long-term section
3. A future day with planned tasks
4. A past day's history
5. The task editor with repeat options
