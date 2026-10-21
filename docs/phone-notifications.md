# Phone notifications

Agents open **Notifications → Phone alerts** or their account menu's **Phone notifications**. On iPhone, Safari's Share → Add to Home Screen step comes first. Open the saved app, sign in, and explicitly enable notifications. iOS 16.4 or newer is required. No permission prompt runs automatically.

Closed deals and chat are enabled by default, alongside leads, requests, callbacks, announcements, team updates, and billing updates. Each device has category choices and a self-test button. Existing inbox category mutes and conversation mutes still apply. Previews show the chat sender and message text, or the deal agent, agency, carrier, policy type, monthly premium and annual premium. Photos/GIFs show a caption and files show a filename, without private storage paths. Client records and policy numbers are excluded. iPhone preview settings still apply.

## Production configuration

The existing Vercel production project needs:

- `WEB_PUSH_PUBLIC_KEY`: VAPID public key, readable configuration.
- `WEB_PUSH_PRIVATE_KEY`: matching VAPID private key, stored as a production Secret. Never put this in the repository, client code, logs, or a preview environment.
- `WEB_PUSH_ENABLED=true`: production only.
- Existing `SUPABASE_SECRET_KEY` and `CRON_SECRET` are reused without copying or retrieving them.

Generate a keypair once with the pinned `web-push` dependency. Retain it across releases so existing subscriptions continue to work. The public GET configuration response exposes only the public key and availability. Preview deployments cannot send pushes.

Apply `supabase/migrations/20261021162327_iphone_push_notifications.sql` before deploying. Also apply `20261021190229_faster_phone_notification_previews.sql` for readable previews and the service-only wake throttle. This creates private device and delivery tables plus service-only RPCs; it does not modify existing notification permissions. The migration has already been applied to MAIN and recovery for this release.

## Delivery and access

After a successful channel/group/direct chat send, resource share, or closed-deal save, the browser makes a nonblocking authenticated `wake` request with keepalive. The server immediately collects and sends eligible alerts using high urgency; it returns no recipient data to the sender. Sender push enrollment is not required. Per-user two-second throttling coalesces writes with a short client retry. Vercel also runs `/api/notifications/push-maintenance` every minute using the existing cron credential as fallback when a tab closes or a request fails. Other event types retain the scheduled scan. Provider/network/Focus settings can delay delivery; seconds are the target, not a guarantee. Events are collected from the same permission-scoped source as the inbox. General chat activity is grouped to the latest unread message per conversation at collection time. Each closed deal is a separate event. Only events after device enrollment and within the latest hour are eligible; there is no initial history flood.

The dispatcher rechecks current account, session, category, chat membership and agency access before claiming a message. It leases up to 30 deliveries, sends five concurrently, retries transient failures up to five attempts, disables expired endpoints on 404/410, and retains delivery metadata for seven days. Notification tags collapse retries on the device. Network acknowledgement failures can still produce a retried alert; delivery is not an exactly-once guarantee.

The server allows only known Apple, Google, and Mozilla push service hosts and never follows redirects. Push contents are encrypted by `web-push@3.6.7`; the VAPID key signs requests. Payloads use Apple's declarative format with a service worker fallback. The worker does not cache pages, API responses, tokens, or leads.

Tapping an alert opens an opaque delivery link. The API rechecks the signed-in user's current access before returning a destination. Existing active dialer calls prevent navigation until they can safely be left. Explicit sign-out removes the subscription; revoked/deleted sessions and inactive users lose delivery eligibility.

## Validation

- `node tests/portal-push.cjs`: API authentication/ownership, endpoint validation, encrypted requests, declarative payload, no redirects, acknowledgements, test targeting and cron authorization.
- `node tests/portal-push-dom.cjs` (requires jsdom): iPhone setup, permission gesture, category defaults, test/disable, denied permission, safe deep links, active calls, logout, account switching and worker clicks.
- `tests/portal-push.sql`: rolled-back database fixtures for isolation, scope, permitted previews, hidden content, wake throttling, deduplication, leases, access changes, preferences, sign-out and endpoint expiration.
- Existing notification and portal navigation DOM suites continue to pass.

Final device validation must use a real iPhone: install, sign in, enable, send a test, lock the phone, and confirm arrival and tap-through. Also check one permitted chat and deal, then a muted conversation and a foreign-agency event. Focus, notification permissions and network availability remain controlled by the phone.

References: https://webkit.org/blog/13878/web-push-for-web-apps-on-ios-and-ipados/ and https://webkit.org/blog/16535/meet-declarative-web-push/
