# Step Squad 👟

A motivational step-count feed for friends and family. Create a squad, invite your people, and watch everyone's progress through the day: a live leaderboard, milestone and goal shout-outs, and one-tap cheers.

Steps come from **Apple Health** through an iOS Shortcut, because Apple Health doesn't share data with websites. Data is stored in **Supabase**.

Try it without any setup: open `index.html?demo=1` for a demo with pretend friends who keep walking.

## Files

| File | What it is |
| --- | --- |
| `index.html` | The whole app (works on phones; add it to your Home Screen) |
| `config.js` | Your Supabase URL and anon key |
| `supabase/schema.sql` | Database tables, security rules, and the Shortcut endpoint |

## Setup (about 15 minutes, one time)

### 1. Create the Supabase project
1. Sign up at [supabase.com](https://supabase.com) and create a new project (the free tier is fine).
2. Open **SQL Editor**, paste in all of `supabase/schema.sql`, and click **Run**.
3. Under **Project Settings → API**, copy the **Project URL** and the **anon / publishable** key into `config.js`. Never use the **service_role** / secret key here.

Sign-in uses email + password, which works the same in Safari and from the Home Screen. New accounts get one confirmation email by default. For a small family squad you can skip that under **Authentication → Sign In / Providers → Email → Confirm email**: turn it off and people are signed in as soon as they create an account.

### 2. Host the page
Any static host works. With GitHub Pages: repo **Settings → Pages → Deploy from branch → `main` / root**. The app is then at `https://<you>.github.io/Ruhlin-applications/step-squad/`.

Back in Supabase, under **Authentication → URL Configuration**, set **Site URL** to that address and add it to **Redirect URLs**. Confirmation and password-reset links bring people back there.

> Supabase's built-in email sender only sends a few emails per hour, and its templates can't be edited. That's fine for a family squad. For more, connect your own SMTP server under Authentication → SMTP.

### 3. Connect Apple Health (each person, on their iPhone)

**One-tap setup (recommended).** Build the Shortcut once yourself (steps below), then share it so everyone else just taps **Add the Shortcut** in the app:
1. In Shortcuts, long-press the shortcut → **Duplicate**. In the copy, replace your token in the `p_token` field with the text `PASTE_TOKEN`. That keeps your own token out of the shared copy.
2. Open the copy → tap its name at the top → **Set Up Shortcut → Import Questions → ＋**, and pick the `p_token` value. Set the question to "Paste your Step Squad token".
3. Tap **Share → Copy iCloud Link**, and put that link in `config.js` as `shortcutUrl`.

The app's **Add the Shortcut** button then copies each person's token and opens the link; they paste once when asked.

**Building it by hand:**
Open the app → **🍎 Apple Health sync**. It shows your personal URL, key, and secret token, each with a copy button, plus these steps:

1. **Shortcuts** app → **＋** → name it `Sync Step Squad`.
2. **Find Health Samples**: Type is `Steps`, Start Date is `Today`, Group By `Day`.
3. **Calculate Statistics** → `Sum` of Health Samples.
4. **Format Date** → Current Date, custom format `yyyy-MM-dd`.
5. **Get Contents of URL** → the URL, Method `POST`, header `apikey` = key, JSON body:
   `p_token` (Text) = your token, `p_steps` (Number) = Statistics, `p_day` (Text) = Formatted Date.
6. Run it once and allow Health access.
7. **Automation** tab → **Time of Day** → Run Immediately → `Sync Step Squad`. Add a few through the day. An **App** automation (e.g. "when Instagram is opened") is a good way to sync more often.

Notes:
- iOS keeps Health data locked while the phone is locked, so a timed sync that runs then may be skipped. Syncs triggered while you're using the phone are the most reliable.
- Check the number against the Health app the first time. If you wear an Apple Watch and the total is too high, add a filter **Source is \<your iPhone\>**.
- The token works like a password for submitting steps. If it leaks, use **Reset my token** in the app.

## How it works

- **Squads**: anyone can create one and gets a 6-character invite code. Share links (`?join=CODE`) join automatically after sign-in.
- **Feed**: each sync records your day's total. Gains of 250+ steps post an update, and crossing 5k/10k/15k… or your personal goal posts a shout-out. Cheers (👏🔥💪🎉🚀) go into the feed too.
- **Privacy**: row level security means you only ever see people who share a squad with you. Tokens are stored apart from profiles and can't be read by anyone else.
- **Live updates** come through Supabase Realtime, with a 60-second refresh as backup.
